<#
.NOTES
    Do not run this file directly. Dot-source it after Infrastructure.Common
    and Infrastructure.Secrets are loaded (Start-E2EAgent.ps1 handles this
    via Invoke-RunnerLifecycleTest -> this file).
#>

. "$PSScriptRoot\..\vm-provisioning\Invoke-VmProvisioningTest.ps1"

# ---------------------------------------------------------------------------
# Get-E2EUsersTestEntry
#   Returns the fixed test VmUsersConfig entry used by both setup (written
#   to the vault) and assertions (checked on the VM) so the two are always
#   consistent.
#
#   Fixed constants only - no operator-specific values. vmName matches the
#   test provisioner entry ('e2e-test') written by Invoke-VmProvisioningSetup.
# ---------------------------------------------------------------------------

function Get-E2EUsersTestEntry {
    return [ordered]@{
        vmName = 'e2e-test'
        groups = @(
            @{ groupName = 'e2e-group' }
        )
        users  = @(
            [ordered]@{
                username     = 'e2euser'
                shell        = '/bin/bash'
                homeDir      = '/home/e2euser'
                groups       = @('e2e-group')
                sudoersRules = @('e2euser ALL=(ALL) NOPASSWD: /usr/bin/ls')
            }
        )
    }
}

# ---------------------------------------------------------------------------
# Invoke-VmUsersSetup
#   Writes a test-scoped VmUsersConfig to the VmUsers vault, provisions the
#   VM via Invoke-VmProvisioningSetup, then reconciles users by calling
#   create-users.ps1 from Infrastructure-Vm-Users.
#
#   The vault entry is authoritative for the duration of the test -
#   create-users.ps1 reads from it. Writing it here means no credentials or
#   test config appear in source code or git history.
#
#   Returns the vmDef from Invoke-VmProvisioningSetup so higher-layer tests
#   can open SSH sessions for their own assertions.
#
#   Teardown counterpart: Invoke-VmUsersTeardown.
# ---------------------------------------------------------------------------

function Invoke-VmUsersSetup {
    [CmdletBinding()]
    param(
        # Config object from Start-E2EAgent.ps1.
        # Must include ProvisionerPath, UsersPath, and TestVm.
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    # VmUsersConfig must be a JSON array - ConvertFrom-VmUsersConfigJson
    # rejects a bare object.
    Write-Host 'Writing test VmUsersConfig to vault ...' -ForegroundColor Cyan
    Set-Secret `
        -Vault  VmUsers `
        -Name   VmUsersConfig `
        -Secret (ConvertTo-Json @(Get-E2EUsersTestEntry) -Depth 5 -Compress)

    $vmDef = Invoke-VmProvisioningSetup -Config $Config

    Write-Host 'Reconciling users ...' -ForegroundColor Cyan
    & "$($Config.UsersPath)\hyper-v\ubuntu\create-users.ps1"

    # Verify SSH is reachable after create-users.ps1 returns. create-users.ps1
    # pings the VM and silently skips it with Write-Warning when ping fails -
    # it exits 0 regardless. Without this check, a skipped VM produces
    # misleading "user not found" errors in the assertion phase rather than
    # a clear setup failure here.
    Write-Host "Verifying SSH reachable after user reconciliation: $($vmDef.ipAddress) ..." `
        -ForegroundColor Cyan
    $auth     = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                    $vmDef.username, $vmDef.password)
    $connInfo = [Renci.SshNet.ConnectionInfo]::new(
                    $vmDef.ipAddress, $vmDef.username, @($auth))
    $setupSshClient = $null
    try {
        $setupSshClient = [Renci.SshNet.SshClient]::new($connInfo)
        $setupSshClient.Connect()
        Write-Host '  [OK] VM reachable via SSH after user reconciliation.' `
            -ForegroundColor Green
    }
    catch {
        throw "VM at $($vmDef.ipAddress) unreachable via SSH after create-users.ps1 - " +
            "users may not have been reconciled. Inner: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $setupSshClient) {
            if ($setupSshClient.IsConnected) { $setupSshClient.Disconnect() }
            $setupSshClient.Dispose()
        }
    }

    return $vmDef
}

# ---------------------------------------------------------------------------
# Invoke-VmUsersTeardown
#   Removes OS users via remove-users.ps1, asserts removal on the VM via
#   SSH, removes VmUsersConfig from the vault, then destroys the VM via
#   Invoke-VmProvisioningTeardown. Always called from a finally block so
#   cleanup runs regardless of test outcome.
#
#   Order rationale:
#     1. remove-users.ps1 runs first - VM must be alive and both vaults
#        must still contain their entries (the script reads both).
#     2. SSH assertions run next - VM is still alive, OS state is checkable.
#     3. VmUsersConfig is removed from the vault - script no longer needed.
#     4. Invoke-VmProvisioningTeardown destroys the VM and removes
#        VmProvisionerConfig. Network teardown also happens here.
# ---------------------------------------------------------------------------

function Invoke-VmUsersTeardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config,

        # SSH credentials for the VM - needed to assert OS state after
        # remove-users.ps1 runs, while the VM is still alive.
        [Parameter(Mandatory)]
        [PSCustomObject] $VmDef
    )

    Write-Host 'Removing users ...' -ForegroundColor Cyan
    & "$($Config.UsersPath)\hyper-v\ubuntu\remove-users.ps1"

    # Assert users, home directories, sudoers files, and declared groups are
    # gone - while the VM is still alive. This must run before
    # Invoke-VmProvisioningTeardown destroys the VM.
    Write-Host "Verifying user removal: $($VmDef.vmName) at $($VmDef.ipAddress) ..." `
        -ForegroundColor Cyan

    $auth      = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                     $VmDef.username, $VmDef.password)
    $connInfo  = [Renci.SshNet.ConnectionInfo]::new(
                     $VmDef.ipAddress, $VmDef.username, @($auth))
    $sshClient = $null

    try {
        $sshClient = [Renci.SshNet.SshClient]::new($connInfo)
        $sshClient.Connect()

        $entry = Get-E2EUsersTestEntry

        foreach ($user in $entry.users) {
            $username = $user.username

            # User account must be gone. userdel removes the account and, on
            # Ubuntu, the primary group named after the user automatically.
            $result = Invoke-SshClientCommand `
                -SshClient $sshClient `
                -Command   "id '$username'"
            if ($result.ExitStatus -eq 0) {
                throw "Teardown incomplete: user '$username' still exists on $($VmDef.vmName)."
            }
            Write-Host "  [OK] user '$username' removed." -ForegroundColor Green

            # Home directory must be gone. userdel -r removes it along with
            # the account; a surviving directory means -r was not applied.
            $result = Invoke-SshClientCommand `
                -SshClient $sshClient `
                -Command   "test -d '$($user.homeDir)' && echo exists || echo absent"
            if (($result.Output -join '').Trim() -ne 'absent') {
                throw "Teardown incomplete: home dir '$($user.homeDir)' " +
                    "still exists on $($VmDef.vmName)."
            }
            Write-Host "  [OK] home dir '$($user.homeDir)' removed." -ForegroundColor Green

            # Sudoers file must be gone when rules were declared.
            $sudoersRules = @($user.sudoersRules)
            if ($sudoersRules.Count -gt 0) {
                $sudoersPath  = "/etc/sudoers.d/$username"
                $result       = Invoke-SshClientCommand `
                    -SshClient $sshClient `
                    -Command   "sudo test -f '$sudoersPath' && echo exists || echo absent"
                if (($result.Output -join '').Trim() -ne 'absent') {
                    throw "Teardown incomplete: sudoers file '$sudoersPath' " +
                        "still exists on $($VmDef.vmName)."
                }
                Write-Host "  [OK] sudoers file for '$username' removed." -ForegroundColor Green
            }
        }

        # Declared groups must be gone. groupdel runs after all users are
        # removed so no members block deletion.
        foreach ($group in $entry.groups) {
            $groupName = $group.groupName
            $result    = Invoke-SshClientCommand `
                -SshClient $sshClient `
                -Command   "getent group '$groupName'"
            if ($result.ExitStatus -eq 0) {
                throw "Teardown incomplete: group '$groupName' still exists on $($VmDef.vmName)."
            }
            Write-Host "  [OK] group '$groupName' removed." -ForegroundColor Green
        }
    }
    finally {
        if ($null -ne $sshClient) {
            if ($sshClient.IsConnected) { $sshClient.Disconnect() }
            $sshClient.Dispose()
        }
    }

    Write-Host 'Removing test VmUsersConfig from vault ...' -ForegroundColor Cyan
    Remove-Secret -Vault VmUsers -Name VmUsersConfig

    Invoke-VmProvisioningTeardown -Config $Config
}

# ---------------------------------------------------------------------------
# Invoke-VmUsersTest
#   E2E test covering VM provisioning and user setup. Provisions the VM,
#   reconciles users, asserts each expected user and group exists on the
#   VM via SSH, then tears down regardless of outcome. Higher-layer tests
#   call the setup and teardown functions directly instead of this wrapper.
# ---------------------------------------------------------------------------

function Invoke-VmUsersTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    $vmDef = Invoke-VmUsersSetup -Config $Config

    try {
        Write-Host "Verifying users: $($vmDef.vmName) at $($vmDef.ipAddress) ..." `
            -ForegroundColor Cyan

        # Security note: SSH.NET accepts any host key by default. This is
        # acceptable on a private Hyper-V network with statically provisioned
        # IPs. Do NOT use on untrusted networks.
        $auth      = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                         $vmDef.username, $vmDef.password)
        $connInfo  = [Renci.SshNet.ConnectionInfo]::new(
                         $vmDef.ipAddress, $vmDef.username, @($auth))
        $sshClient = $null

        try {
            $sshClient = [Renci.SshNet.SshClient]::new($connInfo)
            $sshClient.Connect()

            $entry = Get-E2EUsersTestEntry

            # Assert each declared group exists on the VM.
            foreach ($group in $entry.groups) {
                $groupName = $group.groupName
                $result    = Invoke-SshClientCommand `
                    -SshClient $sshClient `
                    -Command   "getent group '$groupName'"
                if ($result.ExitStatus -ne 0) {
                    throw "Group '$groupName' not found on $($vmDef.vmName)."
                }
                Write-Host "  [OK] group '$groupName' exists." -ForegroundColor Green
            }

            # Assert each user exists, has the correct shell, is a member of
            # all declared supplementary groups, and has a sudoers file when
            # rules are declared.
            foreach ($user in $entry.users) {
                $username = $user.username
                $shell    = $user.shell

                # User must exist.
                $result = Invoke-SshClientCommand `
                    -SshClient $sshClient `
                    -Command   "id '$username'"
                if ($result.ExitStatus -ne 0) {
                    throw "User '$username' not found on $($vmDef.vmName)."
                }
                Write-Host "  [OK] user '$username' exists." -ForegroundColor Green

                # Shell must match the declared value.
                $passwdResult = Invoke-SshClientCommand `
                    -SshClient $sshClient `
                    -Command   "getent passwd '$username'"
                $actualShell  = (($passwdResult.Output -join '').Trim() -split ':')[6]
                if ($actualShell -ne $shell) {
                    throw "User '$username' on $($vmDef.vmName): " +
                        "shell '$actualShell' does not match expected '$shell'."
                }
                Write-Host "  [OK] user '$username' shell: $shell" -ForegroundColor Green

                # Each declared supplementary group must appear in the user's
                # group list. 'id -Gn' includes the primary group (same name as
                # username on Ubuntu) so declared supplementary groups can be
                # checked without stripping the primary.
                $userGroups = @($user.groups)
                if ($userGroups.Count -gt 0) {
                    $gnResult     = Invoke-SshClientCommand `
                        -SshClient $sshClient `
                        -Command   "id -Gn '$username'"
                    $actualGroups = @(
                        ($gnResult.Output -join '').Trim() -split '\s+')
                    foreach ($g in $userGroups) {
                        if ($actualGroups -notcontains $g) {
                            throw "User '$username' on $($vmDef.vmName) " +
                                "is not a member of group '$g'."
                        }
                        Write-Host "  [OK] user '$username' in group '$g'." `
                            -ForegroundColor Green
                    }
                }

                # Home directory must exist. useradd -m creates it; a missing
                # directory means cloud-init or useradd did not run correctly.
                $result = Invoke-SshClientCommand `
                    -SshClient $sshClient `
                    -Command   "test -d '$($user.homeDir)' && echo exists || echo absent"
                if (($result.Output -join '').Trim() -ne 'exists') {
                    throw "Home directory '$($user.homeDir)' for '$username' " +
                        "not found on $($vmDef.vmName)."
                }
                Write-Host "  [OK] user '$username' home dir: $($user.homeDir)" `
                    -ForegroundColor Green

                # Sudoers file must exist when rules are declared. Checking for
                # file presence is sufficient - syntax is validated by
                # Invoke-SudoersReconciliation via visudo before writing.
                $sudoersRules = @($user.sudoersRules)
                if ($sudoersRules.Count -gt 0) {
                    $sudoersPath  = "/etc/sudoers.d/$username"
                    $existsResult = Invoke-SshClientCommand `
                        -SshClient $sshClient `
                        -Command   "sudo test -f '$sudoersPath' && echo exists || echo absent"
                    if (($existsResult.Output -join '').Trim() -ne 'exists') {
                        throw "Sudoers file '$sudoersPath' not found on $($vmDef.vmName)."
                    }
                    Write-Host "  [OK] sudoers file for '$username' exists." `
                        -ForegroundColor Green
                }
            }
        }
        finally {
            if ($null -ne $sshClient) {
                if ($sshClient.IsConnected) { $sshClient.Disconnect() }
                $sshClient.Dispose()
            }
        }
    }
    finally {
        Invoke-VmUsersTeardown -Config $Config -VmDef $vmDef

        Write-Host 'Verifying teardown ...' -ForegroundColor Cyan

        # Assert VM was removed from Hyper-V.
        if ($null -ne (Get-VM -Name $vmDef.vmName -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: VM '$($vmDef.vmName)' still exists in Hyper-V."
        }
        Write-Host '  [OK] VM removed from Hyper-V.' -ForegroundColor Green

        # Assert VmProvisionerConfig vault entry was removed.
        if ($null -ne (Get-SecretInfo -Vault VmProvisioner -Name VmProvisionerConfig `
                -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: VmProvisionerConfig still present in vault."
        }
        Write-Host '  [OK] VmProvisionerConfig removed from vault.' -ForegroundColor Green

        # Assert VmUsersConfig vault entry was removed.
        if ($null -ne (Get-SecretInfo -Vault VmUsers -Name VmUsersConfig `
                -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: VmUsersConfig still present in vault."
        }
        Write-Host '  [OK] VmUsersConfig removed from vault.' -ForegroundColor Green

        # Assert E2E-VmLAN switch and NAT are removed.
        if ($null -ne (Get-VMSwitch -Name 'E2E-VmLAN' -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: E2E-VmLAN switch still exists."
        }
        if ($null -ne (Get-NetNat -Name 'E2E-VmLAN-NAT' -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: E2E-VmLAN-NAT rule still exists."
        }
        Write-Host '  [OK] E2E-VmLAN switch and NAT removed.' -ForegroundColor Green
    }
}
