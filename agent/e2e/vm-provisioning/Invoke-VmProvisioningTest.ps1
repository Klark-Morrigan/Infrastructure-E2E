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

# JDK assertion helper. Kept in its own file so it can be unit-tested in
# isolation and so this file stays focused on setup/teardown/orchestration.
. "$PSScriptRoot\Invoke-JdkInstallAssertions.ps1"

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

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningSetup
#   Generates a random VM admin password, writes a test-scoped
#   VmProvisionerConfig to the VmProvisioner vault, then runs provision.ps1.
#
#   The vault entry is authoritative for the duration of the test - it is
#   what provision.ps1 and deprovision.ps1 read. Writing it here means no
#   credentials appear in source code or git history.
#
#   Returns a vmDef object (vmName, ipAddress, username, password) so
#   higher-layer tests can open SSH sessions for their own assertions.
#
#   Teardown counterpart: Invoke-VmProvisioningTeardown.
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

    # Fail before writing anything if a leftover VM exists. provision.ps1
    # silently skips existing VMs, so without this guard the fresh password
    # written below would not match the old VM's credentials and every
    # subsequent SSH call (create-users.ps1, assertions) would get
    # "Permission denied (password)".
    if ($null -ne (Get-VM -Name $script:TestVmName -ErrorAction SilentlyContinue)) {
        throw ("Leftover VM '$script:TestVmName' found in Hyper-V. A previous " +
            "test run did not complete teardown. Remove it manually " +
            "(deprovision.ps1) before retrying.")
    }

    # 18 random bytes -> 24-character base64 string. Strong enough for an
    # ephemeral test VM; never stored anywhere except the vault below.
    $password = [Convert]::ToBase64String(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(18))

    # vmName, cpuCount, ramGB, diskGB, username are fixed test constants -
    # they do not vary between workstations and contain no sensitive values.
    # Operator-specific fields (IP, gateway, paths) come from Config.TestVm.
    $vmEntry = [ordered]@{
        vmName        = $script:TestVmName
        cpuCount      = 2
        ramGB         = 2
        diskGB        = 20
        ubuntuVersion = $Config.TestVm.ubuntuVersion
        username      = 'e2eadmin'
        password      = $password
        ipAddress     = $Config.TestVm.ipAddress
        subnetMask    = $Config.TestVm.subnetMask
        gateway       = $Config.TestVm.gateway
        dns           = $Config.TestVm.dns
        vmConfigPath  = $Config.TestVm.vmConfigPath
        vhdPath       = $Config.TestVm.vhdPath
        switchName    = 'E2E-VmLAN'
        natName       = 'E2E-VmLAN-NAT'
        # Always-on JDK install. Exercised by the assertion block in
        # Invoke-VmProvisioningTest. Surfaced on the returned vmDef so the
        # assertion can read $vmDef.javaDevKit.version without re-parsing
        # the vault.
        javaDevKit    = [ordered]@{
            vendor  = $script:JdkTestVendor
            version = $script:JdkTestVersion
        }
    }

    # VmProvisionerConfig must be a JSON array - ConvertFrom-VmConfigJson
    # rejects a bare object.
    Write-Host 'Writing test VmProvisionerConfig to vault ...' -ForegroundColor Magenta
    Set-Secret `
        -Vault  VmProvisioner `
        -Name   VmProvisionerConfig `
        -Secret (ConvertTo-Json @($vmEntry) -Depth 5 -Compress)

    Write-Host 'Provisioning VM ...' -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1"

    $vmDef = [PSCustomObject]$vmEntry

    # cloud-init must have finished before the JDK assertions run - the JDK
    # tarball is extracted and /etc/profile.d/jdk.sh is written by cloud-init
    # runcmd, not by provision.ps1. provision.ps1's "SSH reachable" signal
    # comes earlier than cloud-init completion.
    Write-Host "Verifying provisioning post-conditions on $($vmDef.vmName) ..." `
        -ForegroundColor Magenta
    $sshClient = $null
    try {
        $sshClient = New-VmSshClient `
                         -IpAddress $vmDef.ipAddress `
                         -Username  $vmDef.username `
                         -Password  $vmDef.password

        $result = Invoke-SshClientCommand `
            -SshClient $sshClient -Command 'cloud-init status --wait'
        if ($result.ExitStatus -ne 0) {
            throw "cloud-init did not complete successfully on " +
                "$($vmDef.vmName) (exit $($result.ExitStatus)). " +
                "stdout: $($result.Output)  stderr: $($result.Error)"
        }
        Write-Host "  [OK] cloud-init: $($result.Output.Trim())" `
            -ForegroundColor Green

        # Hostname matches vmName - confirms cloud-init applied the correct
        # system identity, not just that SSH opened.
        $result = Invoke-SshClientCommand -SshClient $sshClient -Command 'hostname'
        if ($result.ExitStatus -ne 0) {
            throw "hostname failed on $($vmDef.vmName) " +
                "(exit $($result.ExitStatus)): $($result.Error)"
        }
        $actualHostname = $result.Output.Trim()
        if ($actualHostname -ne $vmDef.vmName) {
            throw "Hostname mismatch: expected '$($vmDef.vmName)', " +
                "got '$actualHostname'."
        }
        Write-Host "  [OK] hostname: $actualHostname" -ForegroundColor Green

        # Root filesystem is accessible and not full.
        $result = Invoke-SshClientCommand -SshClient $sshClient -Command 'df /'
        if ($result.ExitStatus -ne 0) {
            throw "df / failed on $($vmDef.vmName) " +
                "(exit $($result.ExitStatus)): $($result.Error)"
        }
        # Parse use% from the second line of df output (e.g. '23%').
        $usePct = [int](($result.Output -split '\s+' |
            Where-Object { $_ -match '^\d+%$' }) -replace '%')
        if ($usePct -ge 90) {
            throw "Root filesystem on $($vmDef.vmName) is ${usePct}% full."
        }
        Write-Host "  [OK] root filesystem: ${usePct}% used" -ForegroundColor Green

        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $vmDef.vmName `
            -RequestedVersion $vmDef.javaDevKit.version `
            -InstallPrefix    $script:JdkInstallPrefix
    }
    finally {
        if ($null -ne $sshClient) {
            if ($sshClient.IsConnected) { $sshClient.Disconnect() }
            $sshClient.Dispose()
        }
    }

    return $vmDef
}

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningTeardown
#   Destroys the test VM and removes the test VmProvisionerConfig from the
#   vault. Always called from a finally block so cleanup runs regardless of
#   test outcome.
#
#   deprovision.ps1 is idempotent - safe to run even if provision.ps1 failed
#   part-way through and no VM was created.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningTeardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    Write-Host 'Deprovisioning VM ...' -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\deprovision.ps1"

    Write-Host 'Removing test VmProvisionerConfig from vault ...' -ForegroundColor Magenta
    Remove-Secret -Vault VmProvisioner -Name VmProvisionerConfig
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

    # Setup wrapped in try/finally so Teardown still runs if any of the
    # provisioning-layer assertions inside Setup throw after the VM was
    # created. deprovision.ps1 is idempotent so a partial-Setup teardown
    # is safe.
    try {
        Invoke-VmProvisioningSetup -Config $Config | Out-Null
    }
    finally {
        Invoke-VmProvisioningTeardown -Config $Config

        Write-Host 'Verifying teardown ...' -ForegroundColor Magenta

        # Use the script-level constant rather than $vmDef.vmName so the
        # check still works when Setup threw before returning.
        if ($null -ne (Get-VM -Name $script:TestVmName -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: VM '$script:TestVmName' still exists in Hyper-V."
        }
        Write-Host '  [OK] VM removed from Hyper-V.' -ForegroundColor Green

        if ($null -ne (Get-SecretInfo -Vault VmProvisioner -Name VmProvisionerConfig `
                -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: VmProvisionerConfig still present in vault."
        }
        Write-Host '  [OK] VmProvisionerConfig removed from vault.' -ForegroundColor Green

        # E2E-VmLAN switch + NAT are exclusive to this test so no guard is
        # needed - any leftover here means teardown failed.
        if ($null -ne (Get-VMSwitch -Name 'E2E-VmLAN' -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: E2E-VmLAN switch still exists."
        }
        if ($null -ne (Get-NetNat -Name 'E2E-VmLAN-NAT' -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: E2E-VmLAN-NAT rule still exists."
        }
        Write-Host '  [OK] E2E-VmLAN switch and NAT removed.' -ForegroundColor Green
    }
}
