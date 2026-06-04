<#
.NOTES
    Do not run this file directly. Dot-source it after PowerShell.Common
    and Infrastructure.Secrets are loaded (Start-E2EAgent.ps1 handles this
    via Invoke-RunnerLifecycleTest -> this file).
#>

. "$PSScriptRoot\..\vm-provisioning\Invoke-VmProvisioningTest.ps1"

# Re-verification helper used after phases 2 and 3 to confirm a
# re-provision did not disturb user / group state.
. "$PSScriptRoot\Invoke-VmUsersStillIntactAssertions.ps1"

# Create-side dispatcher: selects custom-powershell vs ansible based on
# $Config.UsersFlow. Replaces the inline create-users.ps1 invocation that
# used to live in Invoke-VmUsersSetup.
. "$PSScriptRoot\Set-VmUsersForTest.ps1"

# Remove-side dispatcher: symmetric peer of Set-VmUsersForTest, selecting
# the same UsersFlow. Replaces the inline remove-users.ps1 invocation
# that used to live in Invoke-VmUsersTeardown. Lets the Ansible
# remove-users.sh path (feature 03 of Infrastructure-VM-Ansible) run
# under UsersFlow=ansible while custom-powershell keeps the legacy
# Vm-Users path as a first-class peer.
. "$PSScriptRoot\Remove-VmUsersForTest.ps1"

# ---------------------------------------------------------------------------
# Assert-VmUsersStillIntact
#   Opens a fresh SSH session to the VM and re-asserts that every user
#   and group declared in $Entry is still present. Pairs with
#   Invoke-VmUsersStillIntactAssertions; this wrapper just owns the
#   connection lifecycle so callers between provisioning phases do not
#   re-implement the connect/dispose pattern.
#
#   Used by:
#     - Invoke-VmUsersTest (standalone vm-users E2E) after phases 2 and 3.
#     - Invoke-RunnerLifecycleTest after phases 2 and 3.
# ---------------------------------------------------------------------------

function Assert-VmUsersStillIntact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $VmDef,
        [Parameter(Mandatory)] [object]         $Entry
    )

    Write-Host "Re-asserting users on $($VmDef.vmName) ..." -ForegroundColor Magenta

    $sshClient = $null
    try {
        $sshClient = New-VmSshClient `
                         -IpAddress $VmDef.ipAddress `
                         -Username  $VmDef.username `
                         -Password  $VmDef.password

        Invoke-VmUsersStillIntactAssertions `
            -SshClient $sshClient `
            -VmName    $VmDef.vmName `
            -Entry     $Entry
    }
    finally {
        if ($null -ne $sshClient) {
            if ($sshClient.IsConnected) { $sshClient.Disconnect() }
            $sshClient.Dispose()
        }
    }
}

# ---------------------------------------------------------------------------
# Get-E2EUsersTestEntry
#   Returns the fixed test VmUsersConfig entry used by both setup (written
#   to the vault) and assertions (checked on the VM) so the two are always
#   consistent.
#
#   Fixed constants only - no operator-specific values. vmName matches the
#   test provisioner entry ('e2e-test-1') written by Invoke-VmProvisioningSetup.
# ---------------------------------------------------------------------------

function Get-E2EUsersTestEntry {
    return [ordered]@{
        vmName = 'e2e-test-1'
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
        [PSCustomObject] $Config,

        # Optional VmUsersConfig entry override. Defaults to
        # Get-E2EUsersTestEntry when not provided. Higher-layer tests
        # (e.g. runner lifecycle) pass an extended entry that adds
        # deploy and runner service users on top of the base set.
        [Parameter()]
        [object] $Entry = $null
    )

    if ($null -eq $Entry) {
        $Entry = Get-E2EUsersTestEntry
    }

    # VmUsersConfig must be a JSON array - ConvertFrom-VmUsersConfigJson
    # rejects a bare object.
    Write-Host 'Writing test VmUsersConfig to vault ...' -ForegroundColor Magenta
    Set-Secret `
        -Vault  VmUsers `
        -Name   (Get-E2ESecretName 'VmUsersConfig') `
        -Secret (ConvertTo-Json @($Entry) -Depth 5 -Compress)

    # Setup is provisioning-free (pre-check + identity pin). Phase 1 is
    # the explicit first provision that brings VM1 up with the baseline
    # JDK 21 install + file-transfer fixture - users layer needs the VM
    # alive before it can SSH in to reconcile users.
    $vmDef = Invoke-VmProvisioningSetup -Config $Config
    Invoke-VmProvisioningPhase1 -Config $Config -Vm1Def $vmDef

    Write-Host "Reconciling users via '$($Config.UsersFlow)' flow ..." -ForegroundColor Magenta
    # $Config carries UsersFlow + AnsiblePath + WslDistro from
    # Start-E2EAgent / Start-VmUsersTest. AnsiblePath and WslDistro
    # are optional in the dispatcher and ignored unless
    # UsersFlow=ansible; the agent-loop validates their presence at
    # startup so a missing value fails before the VM is built.
    Set-VmUsersForTest `
        -UsersFlow   $Config.UsersFlow `
        -UsersPath   $Config.UsersPath `
        -AnsiblePath $Config.AnsiblePath `
        -WslDistro   $Config.WslDistro `
        -VmDef       $vmDef `
        -Entry       $Entry

    # Verify SSH is reachable after create-users.ps1 returns. create-users.ps1
    # pings the VM and silently skips it with Write-Warning when ping fails -
    # it exits 0 regardless. Without this check, a skipped VM produces
    # misleading "user not found" errors in the assertion phase rather than
    # a clear setup failure here.
    Write-Host "Verifying SSH reachable after user reconciliation: $($vmDef.ipAddress) ..." `
        -ForegroundColor Magenta
    $setupSshClient   = $null
    $dnsReady         = $false
    $dnsDiagnostics   = $null
    try {
        $setupSshClient = New-VmSshClient `
                              -IpAddress $vmDef.ipAddress `
                              -Username  $vmDef.username `
                              -Password  $vmDef.password
        Write-Host '  [OK] VM reachable via SSH after user reconciliation.' `
            -ForegroundColor Green

        # systemd-resolved can lag behind SSH availability on freshly
        # provisioned VMs. Poll until github.com resolves before returning
        # so downstream steps (curl download) do not hit a DNS failure.
        Write-Host '  Waiting for DNS ...' -ForegroundColor Magenta
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $r = Invoke-SshClientCommand `
                -SshClient   $setupSshClient `
                -Command     'getent hosts github.com' `
                -ErrorAction Stop
            if ($r.ExitStatus -eq 0) { $dnsReady = $true; break }
            Start-Sleep -Seconds 5
        }
        if ($dnsReady) {
            Write-Host '  [OK] DNS ready.' -ForegroundColor Green
        }
        else {
            # Capture diagnostics while the SSH session is still open so
            # the operator can distinguish the three usual root causes
            # without re-attaching: (a) systemd-resolved not ready,
            # (b) upstream unreachable (NAT/gateway), (c) resolver
            # misconfigured. One SSH round-trip; bash 'true' between
            # commands keeps a single failing section from masking the
            # rest. timeout caps any command that itself hangs.
            $diagCmd = @'
echo "--- resolvectl status ---"
timeout 5 resolvectl status || true
echo "--- ping 8.8.8.8 ---"
timeout 5 ping -c 1 -W 2 8.8.8.8 || true
echo "--- ping gateway ---"
timeout 5 ping -c 1 -W 2 "$(ip route | awk '/default/ {print $3; exit}')" || true
echo "--- journalctl -u systemd-resolved (last 20) ---"
sudo journalctl -u systemd-resolved -n 20 --no-pager || true
'@
            # Same CRLF trap that bit Copy-VmFiles: a Windows PowerShell
            # here-string sends \r\n line endings and remote bash treats
            # the trailing \r as part of the token (e.g. 'true\r' is an
            # unknown command). Normalise to LF before sending.
            $diagCmd = $diagCmd -replace "`r`n", "`n"
            $diagResult = Invoke-SshClientCommand `
                -SshClient $setupSshClient -Command $diagCmd
            $dnsDiagnostics = $diagResult.Output
        }
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

    if (-not $dnsReady) {
        throw ("VM at $($vmDef.ipAddress): DNS not ready after 60 seconds - " +
            "github.com unresolvable.`nDiagnostics:`n$dnsDiagnostics")
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
        [PSCustomObject] $VmDef,

        # Optional VmUsersConfig entry override used to determine which
        # users and groups to assert are gone. Defaults to
        # Get-E2EUsersTestEntry when not provided.
        [Parameter()]
        [object] $Entry = $null
    )

    if ($null -eq $Entry) {
        $Entry = Get-E2EUsersTestEntry
    }

    try {
        Write-Host "Removing users via '$($Config.UsersFlow)' flow ..." -ForegroundColor Magenta
        # $Config carries UsersFlow + AnsiblePath + WslDistro from
        # Start-E2EAgent / Start-VmUsersTest, same chain that feeds the
        # create-side dispatcher above. AnsiblePath / WslDistro are
        # validated at agent startup so a misconfigured session fails
        # before any VM is built; the dispatcher re-checks them here as
        # belt-and-braces.
        Remove-VmUsersForTest `
            -UsersFlow   $Config.UsersFlow `
            -UsersPath   $Config.UsersPath `
            -AnsiblePath $Config.AnsiblePath `
            -WslDistro   $Config.WslDistro `
            -VmDef       $VmDef `
            -Entry       $Entry

        # Assert users, home directories, sudoers files, and declared groups are
        # gone - while the VM is still alive. This must run before
        # Invoke-VmProvisioningTeardown destroys the VM.
        Write-Host "Verifying user removal: $($VmDef.vmName) at $($VmDef.ipAddress) ..." `
            -ForegroundColor Magenta

        $sshClient = $null

        try {
            $sshClient = New-VmSshClient `
                             -IpAddress $VmDef.ipAddress `
                             -Username  $VmDef.username `
                             -Password  $VmDef.password

            foreach ($user in $Entry.users) {
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
                # sudoersRules is optional in the config schema; guard the
                # property access to avoid strict-mode errors when absent.
                # @() in an if-expression yields $null - initialise separately.
                $rawRules     = $user.PSObject.Properties['sudoersRules']
                $sudoersRules = @()
                if ($null -ne $rawRules) { $sudoersRules = @($rawRules.Value) }
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
            foreach ($group in $Entry.groups) {
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

        Write-Host 'Removing test VmUsersConfig from vault ...' -ForegroundColor Magenta
        Remove-Secret -Vault VmUsers -Name (Get-E2ESecretName 'VmUsersConfig')
    }
    finally {
        # Always deprovision the VM even if user removal or assertions failed.
        # A failed userdel must not leave a live VM behind.
        Invoke-VmProvisioningTeardown -Config $Config
    }
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

    $vmDef     = $null
    $succeeded = $false

    try {
        $vmDef = Invoke-VmUsersSetup -Config $Config

        Write-Host "Verifying users: $($vmDef.vmName) at $($vmDef.ipAddress) ..." `
            -ForegroundColor Magenta

        $sshClient = $null

        try {
            $sshClient = New-VmSshClient `
                             -IpAddress $vmDef.ipAddress `
                             -Username  $vmDef.username `
                             -Password  $vmDef.password

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
                # sudoersRules is optional; guard the access under strict mode.
                # @() in an if-expression yields $null - initialise separately.
                $rawRules     = $user.PSObject.Properties['sudoersRules']
                $sudoersRules = @()
                if ($null -ne $rawRules) { $sudoersRules = @($rawRules.Value) }
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

        # Now that users are verified on a fresh VM1, run the JDK
        # re-provision phases against the same VM with users in place,
        # and re-assert users are intact after each phase. This catches
        # any regression where a re-provision step inadvertently touches
        # user state.
        $vm2Def = $vmDef._SecondaryVm
        $entry  = Get-E2EUsersTestEntry

        Invoke-VmProvisioningPhase2 -Config $Config -Vm1Def $vmDef -Vm2Def $vm2Def
        Assert-VmUsersStillIntact -Config $Config -VmDef $vmDef -Entry $entry

        Invoke-VmProvisioningPhase3 -Config $Config -Vm1Def $vmDef -Vm2Def $vm2Def
        Assert-VmUsersStillIntact -Config $Config -VmDef $vmDef -Entry $entry

        $succeeded = $true
    }
    catch {
        Write-Host "E2E test error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    finally {
        if ($succeeded) {
            # Invoke-VmUsersTeardown calls Invoke-VmProvisioningTeardown
            # which now also runs Invoke-VmTeardownAssertions internally,
            # so provisioning-layer teardown post-conditions (both VMs
            # gone, per-VM disk artifacts gone, host-side JDK cache
            # intact, switch + NAT removed, VmProvisionerConfig vault
            # entry gone) are verified by the time this returns.
            Invoke-VmUsersTeardown -Config $Config -VmDef $vmDef

            # Assert VmUsersConfig vault entry was removed. Users-layer-
            # specific teardown post-condition; everything else is
            # covered by Invoke-VmTeardownAssertions above.
            $usersSecretName = Get-E2ESecretName 'VmUsersConfig'
            if ($null -ne (Get-SecretInfo -Vault VmUsers -Name $usersSecretName `
                    -ErrorAction SilentlyContinue)) {
                throw "Teardown incomplete: $usersSecretName still present in vault."
            }
            Write-Host "  [OK] $usersSecretName removed from vault." -ForegroundColor Green
        }
        else {
            # Best-effort deprovisioning when setup or assertions failed.
            # Wrapped in try/catch so cleanup errors do not mask the original
            # test failure.
            Write-Host 'Test did not complete - running best-effort deprovisioning ...' `
                -ForegroundColor Yellow
            try {
                Invoke-VmProvisioningTeardown -Config $Config
            }
            catch {
                Write-Warning "Deprovisioning after failure: $($_.Exception.Message)"
            }
            try {
                Remove-Secret -Vault VmUsers -Name (Get-E2ESecretName 'VmUsersConfig') -ErrorAction SilentlyContinue
            }
            catch {}
        }
    }
}
