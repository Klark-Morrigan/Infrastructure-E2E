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
. "$PSScriptRoot\Invoke-JdkInstallAssertions.ps1"

# File-transfer assertion helper. Same rationale as the JDK helper above:
# isolated for unit-testability and to keep this file focused.
. "$PSScriptRoot\Invoke-FileTransferAssertions.ps1"

# Fixed test VM identity. Shared between Setup (writes vault) and the
# teardown verification (looks up the VM by name) so there is one source
# of truth for the test VM name.
$script:TestVmName         = 'e2e-test'

# JDK test pin. Hard-coded so the assertion is stable across operator
# workstations - whatever the latest Temurin GA build of feature release 21
# is at provision time, the prefix "21" still matches the reported version.
# The host-side JDK cache (Step 3 of the JDK plan) amortises the Adoptium
# download across runs once the lockfile is present.
$script:JdkTestVendor      = 'temurin'
$script:JdkTestVersion     = '21'
$script:JdkInstallPrefix   = "/opt/jdk-$script:JdkTestVendor-"

# File-transfer fixture. Resolved from $PSScriptRoot so the absolute path is
# computed on whichever workstation runs the test rather than being hard-
# coded. The target lives under /opt/e2e-fixtures/ so it does not collide
# with any real provisioner-managed path.
$script:FileTransferSource = Join-Path $PSScriptRoot 'fixtures\file-transfer-fixture.txt'
$script:FileTransferTarget = '/opt/e2e-fixtures/file-transfer-fixture.txt'

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
#   Standalone provisioning E2E test for the manual runner
#   (Start-VmProvisioningTest.ps1). Pairs Setup with Teardown so an operator
#   can exercise the provisioning layer in isolation.
#
#   This wrapper deliberately does NOT add assertions of its own - all
#   provisioning-layer post-conditions live in Invoke-VmProvisioningSetup so
#   the workflow path (Start-E2EAgent -> Invoke-RunnerLifecycleTest ->
#   Invoke-VmUsersTest -> Setup) gets the same guarantees. The only
#   wrapper-only checks are the teardown post-conditions, since the lifecycle
#   path runs Teardown via its own outer finally and verifies it elsewhere.
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
    try {
        Invoke-VmProvisioningSetup -Config $Config | Out-Null
    }
    finally {
        Invoke-VmProvisioningTeardown -Config $Config
    }
}
