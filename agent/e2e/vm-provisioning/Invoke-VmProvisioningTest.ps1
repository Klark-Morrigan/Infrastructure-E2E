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
    if ($null -ne (Get-VM -Name 'e2e-test' -ErrorAction SilentlyContinue)) {
        throw ("Leftover VM 'e2e-test' found in Hyper-V. A previous test " +
            "run did not complete teardown. Remove it manually " +
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
        vmName        = 'e2e-test'
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
    }

    # VmProvisionerConfig must be a JSON array - ConvertFrom-VmConfigJson
    # rejects a bare object.
    Write-Host 'Writing test VmProvisionerConfig to vault ...' -ForegroundColor Cyan
    Set-Secret `
        -Vault  VmProvisioner `
        -Name   VmProvisionerConfig `
        -Secret (ConvertTo-Json @($vmEntry) -Depth 5 -Compress)

    Write-Host 'Provisioning VM ...' -ForegroundColor Cyan
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1"

    # Return a vmDef consistent with what ConvertFrom-VmConfigJson produces
    # so the SSH block below and higher-layer tests can connect directly.
    return [PSCustomObject]$vmEntry
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

    Write-Host 'Deprovisioning VM ...' -ForegroundColor Cyan
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\deprovision.ps1"

    Write-Host 'Removing test VmProvisionerConfig from vault ...' -ForegroundColor Cyan
    Remove-Secret -Vault VmProvisioner -Name VmProvisionerConfig
}

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningTest
#   Standalone provisioning E2E test. Provisions the VM, asserts SSH
#   reachability, then tears down. Higher-layer tests call the setup and
#   teardown functions directly instead of using this wrapper.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    $vmDef = Invoke-VmProvisioningSetup -Config $Config

    try {
        Write-Host "Verifying SSH: $($vmDef.vmName) at $($vmDef.ipAddress) ..." `
            -ForegroundColor Cyan

        # Security note: SSH.NET accepts any host key by default. This is
        # acceptable on a private Hyper-V network with statically provisioned
        # IPs. Do NOT use on untrusted networks.
        $auth     = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                        $vmDef.username, $vmDef.password)
        $connInfo = [Renci.SshNet.ConnectionInfo]::new(
                        $vmDef.ipAddress, $vmDef.username, @($auth))
        $sshClient = $null

        try {
            $sshClient = [Renci.SshNet.SshClient]::new($connInfo)
            $sshClient.Connect()

            # Assert hostname matches vmName - confirms cloud-init applied the
            # correct system identity, not just that SSH opened.
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

            # Assert cloud-init completed without errors - confirms all
            # user-data modules (packages, users, network) ran to completion.
            $result = Invoke-SshClientCommand `
                -SshClient $sshClient -Command 'cloud-init status --wait'
            if ($result.ExitStatus -ne 0) {
                throw "cloud-init did not complete successfully on " +
                    "$($vmDef.vmName) (exit $($result.ExitStatus)): " +
                    "$($result.Error)"
            }
            Write-Host "  [OK] cloud-init: $($result.Output.Trim())" `
                -ForegroundColor Green

            # Assert root filesystem is accessible and not full.
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
        }
        finally {
            if ($null -ne $sshClient) {
                if ($sshClient.IsConnected) { $sshClient.Disconnect() }
                $sshClient.Dispose()
            }
        }
    }
    finally {
        Invoke-VmProvisioningTeardown -Config $Config

        Write-Host 'Verifying teardown ...' -ForegroundColor Cyan

        # Assert VM was removed from Hyper-V.
        if ($null -ne (Get-VM -Name $vmDef.vmName -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: VM '$($vmDef.vmName)' still exists in Hyper-V."
        }
        Write-Host '  [OK] VM removed from Hyper-V.' -ForegroundColor Green

        # Assert vault entry was removed.
        if ($null -ne (Get-SecretInfo -Vault VmProvisioner -Name VmProvisionerConfig `
                -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: VmProvisionerConfig still present in vault."
        }
        Write-Host '  [OK] VmProvisionerConfig removed from vault.' -ForegroundColor Green

        # Assert E2E-VmLAN switch and NAT are removed. No guard needed -
        # E2E-VmLAN is exclusive to this test so no other VMs can be attached.
        if ($null -ne (Get-VMSwitch -Name 'E2E-VmLAN' -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: E2E-VmLAN switch still exists."
        }
        if ($null -ne (Get-NetNat -Name 'E2E-VmLAN-NAT' -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: E2E-VmLAN-NAT rule still exists."
        }
        Write-Host '  [OK] E2E-VmLAN switch and NAT removed.' -ForegroundColor Green
    }
}
