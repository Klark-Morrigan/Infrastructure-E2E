<#
.NOTES
    Do not run this file directly. Dot-source it after Infrastructure.Common
    and Infrastructure.Secrets are loaded (Start-E2EAgent.ps1 handles this
    via Invoke-RunnerLifecycleTest -> Invoke-VmUsersTest -> this file).
#>

# Posh-SSH is loaded for its bundled Renci.SshNet.dll. Posh-SSH's own
# cmdlets are not used - ConnectionInfoGenerator in Posh-SSH 3.x drops
# algorithm entries, breaking KEX against OpenSSH 9.x (Ubuntu 24.04).
# SSH.NET is used directly via Invoke-SshClientCommand (Infrastructure.Common).
Invoke-ModuleInstall -ModuleName 'Posh-SSH'

# Assertion helpers. Each lives in its own file so they can be unit-tested in
# isolation and so this file stays focused on setup/teardown/orchestration.
. "$PSScriptRoot\Invoke-NoLeftoverTestVmsAssertions.ps1"
. "$PSScriptRoot\Invoke-VmReadyAssertions.ps1"
. "$PSScriptRoot\Invoke-StaticNetworkAssertions.ps1"
. "$PSScriptRoot\Invoke-JdkInstallAssertions.ps1"
. "$PSScriptRoot\Invoke-JdkUninstallAssertions.ps1"
. "$PSScriptRoot\Invoke-JdkNoopAssertions.ps1"
. "$PSScriptRoot\Invoke-JdkVersionChangeAssertions.ps1"
. "$PSScriptRoot\Invoke-NoJdkVmAssertions.ps1"
. "$PSScriptRoot\Invoke-FileTransferAssertions.ps1"
. "$PSScriptRoot\Invoke-BulkFileTransferAssertions.ps1"
. "$PSScriptRoot\Invoke-EnvVarsAppliedAssertions.ps1"
. "$PSScriptRoot\Invoke-EnvVarsRemovedAssertions.ps1"

# ---------------------------------------------------------------------------
# Test scenario constants
#
# The provisioning E2E runs as a four-phase scenario over two VMs so the
# install / uninstall / re-install / deprovision lifecycle is covered in one
# run. VM identities are pinned for the whole scenario - only VM1's
# javaDevKit block changes between phases. See
# docs/dev/implementation/06 - jdk uninstall flag/plan.md (step 4) for the
# decisions behind this shape.
#
# VM2 carries no javaDevKit in any phase - it is the "blast-radius witness"
# that proves a JDK step on VM1 cannot leak to VM2 in the same provision run.
#
# Declared at script scope BEFORE the phase / verification files are
# dot-sourced because those files reference these via $script:*.
# ---------------------------------------------------------------------------
$script:Vm1Name             = 'e2e-test-1'
$script:Vm2Name             = 'e2e-test-2'

# JDK pins. Two distinct major versions so the reconciler must observably
# uninstall the old dir on a version change (different /opt/jdk-temurin-*
# dir, different java -version prefix). Used across the scenarios:
#   - Phase 1   : install   $JdkInitialVersion
#   - Phase 2a  : drop field (uninstall via absent)
#   - Phase 2b  : reinstall $JdkReinstallVersion
#   - Phase 3a  : version change   $JdkReinstallVersion -> $JdkInitialVersion
#   - Phase 3b  : remove via @()   (uninstall via empty list)
$script:JdkTestVendor       = 'temurin'
$script:JdkInitialVersion   = '21'
$script:JdkReinstallVersion = '17'
$script:JdkInstallPrefix    = "/opt/jdk-$script:JdkTestVendor-"

# Snapshot captured by phase 1 after the install assertions pass and
# consumed by the phase-1 no-op rerun assertion. Declared here (not
# inside Phase 1) so it survives the dot-source / function-scope
# boundary.
$script:Phase1JdkSnapshot = $null

# File-transfer fixture. Resolved from $PSScriptRoot so the absolute path is
# computed on whichever workstation runs the test rather than being hard-
# coded. The target lives under /opt/e2e-fixtures/ so it does not collide
# with any real provisioner-managed path. Exercised in phases 1 and 2 on
# VM1 - phase 1 covers initial Copy-VmFiles dispatch alongside the JDK
# install, phase 2 covers the idempotence guarantee on re-provision.
$script:FileTransferSource = Join-Path $PSScriptRoot 'fixtures\file-transfer-fixture.txt'
$script:FileTransferTarget = '/opt/e2e-fixtures/file-transfer-fixture.txt'

# Bulk-file (pattern) fixture. Three tiny .jar files with distinguishable
# content land under /opt/ci-jars via Copy-VmFilesByPattern. Mirrors the
# CI-classpath use case that motivated the bulk form. Phase 1 places them,
# phase 2 re-provisions to assert idempotence. Basenames are the
# discriminator the assertions match against; their contents differ so a
# partial-copy bug surfaces as a per-file SHA-256 mismatch naming the
# offender.
$script:BulkFileTransferSourceDir = Join-Path $PSScriptRoot 'fixtures\jars'
$script:BulkFileTransferPattern   = Join-Path $PSScriptRoot 'fixtures\jars\*.jar'
$script:BulkFileTransferTargetDir = '/opt/ci-jars'
$script:BulkFileTransferBaseNames = @('a.jar', 'b.jar', 'c.jar')

# envVars fixture. Single managed block 'e2e-ci' carried across all
# three phases on VM1: phase 1 writes two entries, phase 2 narrows to
# one, phase 3 sets entries:[] to exercise block removal. The
# MARKER_OUTSIDE line is seeded by phase 1 AFTER its first
# provision.ps1 returns (the VM does not exist before that) and is
# checked by phases 2 and 3 to prove lines outside the managed block
# survive re-writes and removal. See
# docs/dev/implementation/08 - env vars/plan.md step 5 for the
# decisions behind this shape.
$script:EnvVarsBlockName  = 'e2e-ci'
$script:EnvVarsFooHome    = [PSCustomObject]@{ Name = 'FOO_HOME'; Value = '/opt/foo' }
$script:EnvVarsBarVar     = [PSCustomObject]@{ Name = 'BAR_VAR';  Value = 'baz' }
$script:EnvVarsMarkerName = 'MARKER_OUTSIDE'
$script:EnvVarsMarkerLine = "$($script:EnvVarsMarkerName)=`"untouched`""

# Phase 2's E6 assertion compares /etc/environment's mtime against this
# snapshot, taken at the end of phase 1 AFTER the marker is seeded so
# the seed write itself does not leak into the "did the transport
# rewrite the block?" signal.
$script:EnvVarsPhase1Mtime = $null

# ---------------------------------------------------------------------------
# Internal helpers
#
# Stay in this file (rather than in their own Public-style files) because
# they are orchestrator-level glue: each is used by multiple phases and
# none of them are independently meaningful outside the four-phase
# scenario this module defines.
# ---------------------------------------------------------------------------

# 18 random bytes -> 24-char base64. Strong enough for an ephemeral test VM;
# never stored anywhere except the VmProvisioner vault for the test duration.
function New-VmProvisioningPassword {
    return [Convert]::ToBase64String(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(18))
}

# VM2's IP is derived from VM1's by incrementing the last octet. Keeps the
# operator config (E2EConfig.TestVm.ipAddress) single-valued - the test
# scenario decides VM2's address, the operator does not pin it.
function Get-SecondaryVmIpAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $PrimaryIpAddress
    )

    $octets = $PrimaryIpAddress.Split('.')
    if ($octets.Count -ne 4) {
        throw "Cannot derive secondary IP - '$PrimaryIpAddress' is not a dotted-quad."
    }
    $last = [int] $octets[3]
    if ($last -ge 254) {
        throw "Cannot derive secondary IP - last octet of '$PrimaryIpAddress' " +
            "is $last; incrementing would leave the /24."
    }
    $octets[3] = [string]($last + 1)
    return ($octets -join '.')
}

# Builds the common VM entry shape. The javaDevKit and files blocks are
# layered on top by callers so each phase can compose the entry it needs
# without duplicating the boilerplate fields.
function New-VmEntryBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $IpAddress,
        [Parameter(Mandatory)] [string] $Password
    )

    return [ordered]@{
        vmName        = $VmName
        cpuCount      = 2
        ramGB         = 2
        diskGB        = 20
        ubuntuVersion = $Config.TestVm.ubuntuVersion
        username      = 'e2eadmin'
        password      = $Password
        ipAddress     = $IpAddress
        subnetMask    = $Config.TestVm.subnetMask
        gateway       = $Config.TestVm.gateway
        dns           = $Config.TestVm.dns
        vmConfigPath  = $Config.TestVm.vmConfigPath
        vhdPath       = $Config.TestVm.vhdPath
        switchName    = 'E2E-VmLAN'
        natName       = 'E2E-VmLAN-NAT'
    }
}

# VmProvisionerConfig must be a JSON array - ConvertFrom-VmConfigJson
# rejects a bare object. Centralised so the JSON depth, the Set-Secret
# parameters, and the array-wrapping live in one place across all phases.
function Write-VmProvisionerConfig {
    [CmdletBinding()]
    param(
        # Array of ordered dictionaries / PSCustomObjects, one per VM.
        [Parameter(Mandatory)]
        [object[]] $Entries
    )

    Set-Secret `
        -Vault  VmProvisioner `
        -Name   VmProvisionerConfig `
        -Secret (ConvertTo-Json $Entries -Depth 5 -Compress)
}

# Builds the VM1 + VM2 vmDefs once, up front. Passwords are generated
# here so each phase's rewrite of VmProvisionerConfig reuses the same
# credentials - changing them mid-scenario would invalidate prior
# phases' SSH sessions. VM2's IP is derived from VM1's so the operator
# only pins one IP in E2EConfig.
function New-PinnedVmDefinitions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    $vm1Def = [PSCustomObject](New-VmEntryBase `
        -Config    $Config `
        -VmName    $script:Vm1Name `
        -IpAddress $Config.TestVm.ipAddress `
        -Password  (New-VmProvisioningPassword))

    $vm2Def = [PSCustomObject](New-VmEntryBase `
        -Config    $Config `
        -VmName    $script:Vm2Name `
        -IpAddress (Get-SecondaryVmIpAddress -PrimaryIpAddress $Config.TestVm.ipAddress) `
        -Password  (New-VmProvisioningPassword))

    return [PSCustomObject]@{ Vm1 = $vm1Def; Vm2 = $vm2Def }
}

# Opens an SSH client to a VM, runs the supplied script block with the
# client as its sole argument, and disposes the client regardless of
# outcome. Centralises the connect / try / finally / dispose pattern so
# each phase does not redo it inline.
function Invoke-WithVmSshClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $VmDef,
        [Parameter(Mandatory)] [scriptblock] $Assertions
    )

    $sshClient = $null
    try {
        $sshClient = New-VmSshClient `
                         -IpAddress $VmDef.ipAddress `
                         -Username  $VmDef.username `
                         -Password  $VmDef.password
        & $Assertions $sshClient
    }
    finally {
        if ($null -ne $sshClient) {
            if ($sshClient.IsConnected) { $sshClient.Disconnect() }
            $sshClient.Dispose()
        }
    }
}

# Seeds an out-of-block sentinel line on the VM and snapshots the
# resulting /etc/environment mtime. Used by phase 1 (after the first
# managed-block write) so phases 2 and 3 can assert (a) the line
# survives subsequent re-runs and (b) phase 2's re-write actually
# updates the file. Uses tee -a under sudo so the append is atomic
# from the operator's perspective; the line lands after the END
# marker, so it is unambiguously outside the managed block.
function Set-VmEnvironmentMarkerAndSnapshotMtime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName
    )

    # Idempotence: append only when the line is not already there, so
    # a re-run of phase 1 (e.g. during local debugging) does not
    # accumulate duplicate marker lines.
    $append = "grep -Fxq '$($script:EnvVarsMarkerLine)' /etc/environment || " +
        "echo '$($script:EnvVarsMarkerLine)' | sudo tee -a /etc/environment >/dev/null"
    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $append
    if ($result.ExitStatus -ne 0) {
        throw "Failed to seed MARKER_OUTSIDE on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }

    # mtime as Unix epoch seconds - phase 2 compares numerically, so we
    # avoid timezone surprises that string timestamps would introduce.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "stat -c '%Y' /etc/environment"
    if ($result.ExitStatus -ne 0) {
        throw "stat -c %Y on /etc/environment failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $script:EnvVarsPhase1Mtime = [int64]$result.Output.Trim()
    Write-Host "  [seed] MARKER_OUTSIDE in place; /etc/environment mtime=$($script:EnvVarsPhase1Mtime)" `
        -ForegroundColor Magenta
}

# E6 helper: asserts /etc/environment's mtime advanced past the phase-1
# snapshot. The transport's skip-unchanged path would leave the mtime
# stale; phase 2 changes the block content (BAR_VAR removed) so a
# stale mtime indicates either the transport never ran or the file
# was not actually rewritten.
function Assert-EtcEnvironmentMtimeAdvanced {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName
    )

    if ($null -eq $script:EnvVarsPhase1Mtime) {
        throw "Assert-EtcEnvironmentMtimeAdvanced: phase 1 did not snapshot " +
            "an mtime - phases ran out of order."
    }
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "stat -c '%Y' /etc/environment"
    if ($result.ExitStatus -ne 0) {
        throw "stat -c %Y on /etc/environment failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $now = [int64]$result.Output.Trim()
    if ($now -le $script:EnvVarsPhase1Mtime) {
        throw "/etc/environment mtime did not advance on $VmName " +
            "(phase 1 snapshot $($script:EnvVarsPhase1Mtime), now $now). " +
            "Transport likely skipped the write - block contents may be stale."
    }
    Write-Host "  [OK] /etc/environment mtime advanced ($($script:EnvVarsPhase1Mtime) -> $now)" `
        -ForegroundColor Green
}

# Phase functions. One file per phase so each is independently reviewable
# and unit-testable. They reach back into the orchestrator helpers above
# (New-VmEntryBase, Write-VmProvisionerConfig, Invoke-WithVmSshClient) and
# the $script:* constants, so the dot-sources MUST come after the helper
# and constant definitions in this file.
. "$PSScriptRoot\Invoke-VmProvisioningPhase1.ps1"
. "$PSScriptRoot\Invoke-VmProvisioningPhase2.ps1"
. "$PSScriptRoot\Invoke-VmProvisioningPhase3.ps1"

# Teardown assertions must be defined before Teardown, because
# Invoke-VmProvisioningTeardown calls Invoke-VmTeardownAssertions at the
# end of its run.
. "$PSScriptRoot\Invoke-VmTeardownAssertions.ps1"
. "$PSScriptRoot\Invoke-VmProvisioningTeardown.ps1"

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningSetup
#   Pre-flight only: imports Hyper-V, asserts both test VMs are absent,
#   and pins both VM identities (vmName, ipAddress, credentials).
#   Returns the VM1 vmDef with VM2's vmDef attached as the '_SecondaryVm'
#   NoteProperty so downstream callers can drive each phase with the
#   same pinned identity. Underscore prefix marks it as an internal
#   handoff field - external consumers should treat it as opaque.
#
#   NO provisioning happens here. Each phase (1, 2, 3) is one VmProvisioner
#   config write + one provision.ps1 invocation + its assertions; Phase 1
#   is the operator's first provision of the scenario, and callers invoke
#   it explicitly right after Setup. Keeping Setup provisioning-free
#   matches the symmetry across phases and means a caller that doesn't
#   yet want a VM up (e.g. a future test that only exercises validation)
#   can still use Setup.
#
#   Teardown counterpart: Invoke-VmProvisioningTeardown (which calls
#   Invoke-VmTeardownAssertions at the end of its own run).
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningSetup {
    [CmdletBinding()]
    param(
        # Config object from Start-E2EAgent.ps1.
        # Must include ProvisionerPath and TestVm (see E2EConfig vault shape).
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    # Hyper-V module is not auto-imported in the agent session - provision.ps1
    # loads it only inside its own child process. Import it explicitly so
    # Get-VM below is available.
    Import-Module Hyper-V -ErrorAction Stop

    Invoke-NoLeftoverTestVmsAssertions

    $vmDefs = New-PinnedVmDefinitions -Config $Config

    Add-Member -InputObject $vmDefs.Vm1 `
        -MemberType NoteProperty -Name '_SecondaryVm' -Value $vmDefs.Vm2 -Force

    return $vmDefs.Vm1
}

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningTest
#   Standalone four-phase provisioning E2E for the manual runner
#   (Start-VmProvisioningTest.ps1). Drives the phases directly because
#   the provisioning-only test has no users / runner layers to inject
#   between phases.
#
#   The lifecycle path (Start-E2EAgent -> Invoke-RunnerLifecycleTest ->
#   Invoke-VmUsersTest) calls Invoke-VmProvisioningSetup itself, runs
#   its users / runner setup on the freshly provisioned VM1, then drives
#   phases 2-3 with the same helpers used here - re-asserting users +
#   runner intact between phases.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    # Wrapped in try/finally so Teardown (with its embedded
    # Invoke-VmTeardownAssertions call) still runs if any phase throws
    # after a VM was created. deprovision.ps1 is idempotent so a partial
    # teardown is safe.
    $vm1Def = $null
    try {
        $vm1Def = Invoke-VmProvisioningSetup -Config $Config
        $vm2Def = $vm1Def._SecondaryVm

        Invoke-VmProvisioningPhase1 -Config $Config -Vm1Def $vm1Def
        Invoke-VmProvisioningPhase2 -Config $Config -Vm1Def $vm1Def -Vm2Def $vm2Def
        Invoke-VmProvisioningPhase3 -Config $Config -Vm1Def $vm1Def -Vm2Def $vm2Def
    }
    finally {
        Invoke-VmProvisioningTeardown -Config $Config
    }
}
