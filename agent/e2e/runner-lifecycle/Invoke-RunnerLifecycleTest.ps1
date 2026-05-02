<#
.NOTES
    Do not run this file directly. Dot-source it after Infrastructure.Common
    and Infrastructure.Secrets are loaded (Start-E2EAgent.ps1 handles this).
#>

. "$PSScriptRoot\..\vm-users\Invoke-VmUsersTest.ps1"

# ---------------------------------------------------------------------------
# Get-E2ERunnerUsersEntry
#   Returns the VmUsersConfig entry for the runner lifecycle test. Extends
#   the base users entry (from Get-E2EUsersTestEntry) with:
#     - e2edeploy  - SSH deploy user that installs and registers the runner.
#                    Must have a password so Read-VmDeployPasswords can index
#                    it; full passwordless sudo so register-runners.ps1 can
#                    run config.sh as the runner user and svc.sh as root.
#     - e2erunner  - Service user that owns the runner binary and systemd
#                    unit. No password (service account, no interactive
#                    login needed).
#
#   DeployPassword is generated fresh per test run by
#   Invoke-RunnerLifecycleSetup so the credential never lives in source code
#   or a config file.
# ---------------------------------------------------------------------------

function Get-E2ERunnerUsersEntry {
    # SSH.NET PasswordAuthenticationMethod and the VmUsersConfig JSON schema
    # both require plain strings. The password is generated once per test
    # run, never written to source or disk, and discarded when the VM is
    # destroyed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'DeployPassword')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DeployPassword
    )

    $base = Get-E2EUsersTestEntry

    return [ordered]@{
        vmName = $base.vmName
        groups = @($base.groups)
        users  = @(
            # Preserve the base test user (e2euser) from the users layer.
            @($base.users)[0],
            # Deploy user: SSH access + passwordless sudo so register-runners.ps1
            # can run config.sh as e2erunner and svc.sh as root without a TTY.
            [ordered]@{
                username     = 'e2edeploy'
                shell        = '/bin/bash'
                homeDir      = '/home/e2edeploy'
                groups       = @()
                sudoersRules = @('e2edeploy ALL=(ALL) NOPASSWD: ALL')
                password     = $DeployPassword
            },
            # Runner service user: owns runner files and the systemd unit.
            [ordered]@{
                username = 'e2erunner'
                shell    = '/bin/bash'
                homeDir  = '/home/e2erunner'
                groups   = @()
            }
        )
    }
}

# ---------------------------------------------------------------------------
# Get-E2ERunnersConfigEntry
#   Returns the GitHubRunnersConfig array written to the GitHubRunners vault
#   by Invoke-RunnerLifecycleSetup. The runner registers against the repo
#   whose name is the last path component of Config.RunnersPath - the same
#   convention used when cloning the repo (directory name == repo name).
# ---------------------------------------------------------------------------

function Get-E2ERunnersConfigEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    $runnersRepo = Split-Path $Config.RunnersPath -Leaf

    return @(
        [ordered]@{
            vmName         = 'e2e-test'
            ipAddress      = $Config.TestVm.ipAddress
            deployUsername = 'e2edeploy'
            runnerUsername = 'e2erunner'
            githubUrl      = "https://github.com/$($Config.Owner)/$runnersRepo"
            runnerName     = 'e2e-runner'
            runnerLabels   = @('e2e', 'self-hosted', 'linux')
        }
    )
}

# ---------------------------------------------------------------------------
# Invoke-RunnerLifecycleSetup
#   Brings up the full lifecycle stack:
#     1. Generate a throw-away deploy password (never stored in source).
#     2. Write GitHubRunnersConfig to the GitHubRunners vault.
#     3. Provision the VM and create users via Invoke-VmUsersSetup (extended
#        entry includes e2edeploy and e2erunner on top of the base users).
#     4. Acquire a short-lived GitHub App token for the runners installation.
#     5. Call register-runners.ps1 with the non-interactive -Token flag.
#
#   Returns a PSCustomObject with VmDef, RunnersToken, and Entry so the
#   caller can open SSH sessions for assertions and pass state to teardown.
#
#   Teardown counterpart: Invoke-RunnerLifecycleTeardown.
# ---------------------------------------------------------------------------

function Invoke-RunnerLifecycleSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    # Generate a random deploy password per test run. Hex GUID - no special
    # chars that could confuse chpasswd or SSH.NET.
    $deployPassword = [System.Guid]::NewGuid().ToString('N')
    $entry          = Get-E2ERunnerUsersEntry -DeployPassword $deployPassword

    # Write GitHubRunnersConfig first so register-runners.ps1 finds it.
    Write-Host 'Writing test GitHubRunnersConfig to vault ...' -ForegroundColor Cyan
    $runnersEntries = Get-E2ERunnersConfigEntry -Config $Config
    Set-Secret `
        -Vault  GitHubRunners `
        -Name   GitHubRunnersConfig `
        -Secret (ConvertTo-Json $runnersEntries -Depth 5 -Compress)

    # Provision VM, create all users (base + e2edeploy + e2erunner).
    $vmDef = Invoke-VmUsersSetup -Config $Config -Entry $entry

    # Mint a token scoped to Infrastructure-GitHubRunners with administration:write
    # only. Scoping to one repo and one permission prevents the token from
    # touching the other repos the installation covers, even if the app declares
    # broader permissions.
    Write-Host 'Acquiring GitHub App token for runner registration ...' `
        -ForegroundColor Cyan
    $runnersRepo = Split-Path $Config.RunnersPath -Leaf
    $tokenResult = Get-GitHubAppToken `
        -AppId          $Config.AppId `
        -InstallationId $Config.RunnersInstallationId `
        -PrivateKeyPath $Config.PrivateKeyPath `
        -Repositories   @($runnersRepo) `
        -Permissions    @{ administration = 'write' }

    return [PSCustomObject]@{
        VmDef        = $vmDef
        RunnersToken = $tokenResult.Token
        Entry        = $entry
    }
}

# ---------------------------------------------------------------------------
# Invoke-RunnerLifecycleTeardown
#   Tears down the full lifecycle stack in reverse order:
#     1. Deregister runners from GitHub and remove runner files via
#        deregister-runners.ps1 (-Force ensures cleanup even when the runner
#        service is down after a mid-test failure).
#     2. Remove OS users and VM via Invoke-VmUsersTeardown (extended entry).
#     3. Remove GitHubRunnersConfig from the vault.
#
#   Order rationale:
#     - Deregister first: runner service and GitHub registration are removed
#       while the VM is still alive so deregister-runners.ps1 can use SSH.
#     - VmUsersTeardown second: VM is still alive for OS-level assertions,
#       then destroyed.
#     - Vault cleanup last: vault entries are valid until all dependents are
#       gone.
# ---------------------------------------------------------------------------

function Invoke-RunnerLifecycleTeardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config,

        [Parameter(Mandatory)]
        [PSCustomObject] $VmDef,

        # Token acquired during setup. Valid for 1 hour; test runs are
        # expected to complete well within that window.
        [Parameter(Mandatory)]
        [string] $RunnersToken,

        # Full VmUsersConfig entry (base + deploy + runner users). Passed to
        # Invoke-VmUsersTeardown so it can assert all users are gone.
        [Parameter(Mandatory)]
        [object] $Entry
    )

    Write-Host 'Deregistering runners ...' -ForegroundColor Cyan
    # -Force: if the runner service crashed mid-test, -Force removes the
    # GitHub registration via the API without SSH access.
    & "$($Config.RunnersPath)\hyper-v\ubuntu\deregister-runners.ps1" `
        -Token $RunnersToken `
        -Force

    $configEntry = Get-E2ERunnersConfigEntry -Config $Config
    $runnerName  = $configEntry[0].runnerName

    # Assert runner service is gone and runner directory is removed - while
    # the VM is still alive so we can SSH in. Must run before
    # Invoke-VmUsersTeardown destroys the VM.
    Write-Host "Verifying runner deregistration: $($VmDef.vmName) at $($VmDef.ipAddress) ..." `
        -ForegroundColor Cyan

    $auth      = [Renci.SshNet.PasswordAuthenticationMethod]::new(
                     $VmDef.username, $VmDef.password)
    $connInfo  = [Renci.SshNet.ConnectionInfo]::new(
                     $VmDef.ipAddress, $VmDef.username, @($auth))
    $sshClient = $null

    try {
        $sshClient = [Renci.SshNet.SshClient]::new($connInfo)
        $sshClient.Connect()

        # Runner service unit must be gone. deregister-runners.ps1 runs
        # svc.sh uninstall which removes the unit file.
        $nameResult  = Invoke-SshClientCommand `
            -SshClient $sshClient `
            -Command   ("systemctl list-unit-files --no-legend " +
                        "--type=service 'actions.runner.*' " +
                        "| grep -F '.$runnerName.'")
        $serviceLine = ($nameResult.Output -join '').Trim()
        if ($serviceLine) {
            throw ("Teardown incomplete: runner service for '$runnerName' " +
                "still installed on $($VmDef.vmName): $serviceLine")
        }
        Write-Host "  [OK] runner service removed from $($VmDef.vmName)." `
            -ForegroundColor Green

        # Runner directory must be gone. deregister-runners.ps1 removes
        # files via Remove-RunnerFiles after config.sh remove.
        $runnerDir   = "/home/e2erunner/runners/$runnerName"
        $dirResult   = Invoke-SshClientCommand `
            -SshClient $sshClient `
            -Command   "test -d '$runnerDir' && echo exists || echo absent"
        if (($dirResult.Output -join '').Trim() -ne 'absent') {
            throw ("Teardown incomplete: runner directory '$runnerDir' " +
                "still exists on $($VmDef.vmName).")
        }
        Write-Host "  [OK] runner directory removed from $($VmDef.vmName)." `
            -ForegroundColor Green
    }
    finally {
        if ($null -ne $sshClient) {
            if ($sshClient.IsConnected) { $sshClient.Disconnect() }
            $sshClient.Dispose()
        }
    }

    # Assert runner is no longer registered on GitHub. This must succeed
    # whether the VM was reachable or not (-Force handles the unreachable case).
    Write-Host 'Verifying runner deregistered from GitHub API ...' -ForegroundColor Cyan
    $githubUrl    = $configEntry[0].githubUrl
    $parts        = $githubUrl.TrimEnd('/') -split '/'
    $apiOwner     = $parts[-2]
    $apiRepo      = $parts[-1]
    $response     = Invoke-GitHubApi `
        -Token    $RunnersToken `
        -Endpoint "repos/$apiOwner/$apiRepo/actions/runners?per_page=100"
    $registration = @($response.runners) |
        Where-Object { $_.name -eq $runnerName } |
        Select-Object -First 1
    if ($null -ne $registration) {
        throw ("Teardown incomplete: runner '$runnerName' still registered " +
            "on GitHub (status: $($registration.status)).")
    }
    Write-Host "  [OK] runner '$runnerName' removed from GitHub." -ForegroundColor Green

    Invoke-VmUsersTeardown -Config $Config -VmDef $VmDef -Entry $Entry

    Write-Host 'Removing test GitHubRunnersConfig from vault ...' -ForegroundColor Cyan
    Remove-Secret -Vault GitHubRunners -Name GitHubRunnersConfig
}

# ---------------------------------------------------------------------------
# Invoke-RunnerLifecycleTest
#   Full E2E test covering provisioning, user setup, and runner lifecycle.
#   Sets up the stack via Invoke-RunnerLifecycleSetup, asserts:
#     1. Runner systemd service is active on the VM (SSH check).
#     2. Runner appears online in the GitHub API.
#   Then tears down regardless of outcome.
# ---------------------------------------------------------------------------

function Invoke-RunnerLifecycleTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    $vmDef        = $null
    $runnersToken = $null
    $entry        = $null
    $succeeded    = $false

    try {
        $setup        = Invoke-RunnerLifecycleSetup -Config $Config
        $vmDef        = $setup.VmDef
        $runnersToken = $setup.RunnersToken
        $entry        = $setup.Entry

        # Registration starts here - $runnersToken is already assigned so the
        # finally block can call deregister-runners.ps1 even if this fails
        # mid-way (e.g. config.sh succeeds but svc.sh fails).
        Write-Host 'Registering runners ...' -ForegroundColor Cyan
        & "$($Config.RunnersPath)\hyper-v\ubuntu\register-runners.ps1" `
            -Token $runnersToken

        $configEntry = Get-E2ERunnersConfigEntry -Config $Config
        $runnerName  = $configEntry[0].runnerName

        Write-Host "Verifying runner service: $($vmDef.vmName) at $($vmDef.ipAddress) ..." `
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

            # Resolve the full systemd unit name. svc.sh names it
            # 'actions.runner.{owner}-{repo}.{runnerName}.service'.
            # Matching on '.$runnerName.' avoids false positives when
            # one runner name is a prefix of another.
            $nameResult = Invoke-SshClientCommand `
                -SshClient $sshClient `
                -Command   ("systemctl list-unit-files --no-legend " +
                            "--type=service 'actions.runner.*' " +
                            "| grep -F '.$runnerName.'")
            $serviceLine = ($nameResult.Output -join '').Trim()
            if (-not $serviceLine) {
                throw ("Runner service for '$runnerName' not found on " +
                    "$($vmDef.vmName) - svc.sh may not have run.")
            }
            $serviceName = ($serviceLine -split '\s+')[0]
            Write-Host "  [OK] runner service installed: $serviceName" `
                -ForegroundColor Green

            $activeResult = Invoke-SshClientCommand `
                -SshClient $sshClient `
                -Command   "systemctl is-active '$serviceName'"
            if (($activeResult.Output -join '').Trim() -ne 'active') {
                throw ("Runner service '$serviceName' is not active on " +
                    "$($vmDef.vmName). " +
                    "Check: journalctl -u '$serviceName'")
            }
            Write-Host '  [OK] runner service active.' -ForegroundColor Green
        }
        finally {
            if ($null -ne $sshClient) {
                if ($sshClient.IsConnected) { $sshClient.Disconnect() }
                $sshClient.Dispose()
            }
        }

        # Assert runner online via GitHub API.
        # Invoke-GitHubApi is provided by Infrastructure.Common.
        Write-Host 'Verifying runner online via GitHub API ...' -ForegroundColor Cyan
        $githubUrl = $configEntry[0].githubUrl
        $parts     = $githubUrl.TrimEnd('/') -split '/'
        $apiOwner  = $parts[-2]
        $apiRepo   = $parts[-1]

        $response   = Invoke-GitHubApi `
            -Token    $runnersToken `
            -Endpoint "repos/$apiOwner/$apiRepo/actions/runners?per_page=100"
        $registration = @($response.runners) |
            Where-Object { $_.name -eq $runnerName } |
            Select-Object -First 1

        if ($null -eq $registration) {
            throw "Runner '$runnerName' not found in GitHub API for $githubUrl."
        }
        if ($registration.status -ne 'online') {
            throw ("Runner '$runnerName' status is '$($registration.status)', " +
                "expected 'online'.")
        }
        Write-Host "  [OK] runner '$runnerName' online in GitHub." -ForegroundColor Green

        $succeeded = $true
    }
    finally {
        if ($succeeded) {
            Invoke-RunnerLifecycleTeardown `
                -Config       $Config `
                -VmDef        $vmDef `
                -RunnersToken $runnersToken `
                -Entry        $entry

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

            # Assert GitHubRunnersConfig vault entry was removed.
            if ($null -ne (Get-SecretInfo -Vault GitHubRunners -Name GitHubRunnersConfig `
                    -ErrorAction SilentlyContinue)) {
                throw "Teardown incomplete: GitHubRunnersConfig still present in vault."
            }
            Write-Host '  [OK] GitHubRunnersConfig removed from vault.' -ForegroundColor Green

            # Assert E2E-VmLAN switch and NAT are removed.
            if ($null -ne (Get-VMSwitch -Name 'E2E-VmLAN' -ErrorAction SilentlyContinue)) {
                throw "Teardown incomplete: E2E-VmLAN switch still exists."
            }
            if ($null -ne (Get-NetNat -Name 'E2E-VmLAN-NAT' -ErrorAction SilentlyContinue)) {
                throw "Teardown incomplete: E2E-VmLAN-NAT rule still exists."
            }
            Write-Host '  [OK] E2E-VmLAN switch and NAT removed.' -ForegroundColor Green
        }
        else {
            Write-Host 'Test did not complete - running best-effort cleanup ...' `
                -ForegroundColor Yellow

            # Deregister first if we got a token - removes GitHub registration
            # and runner files while the VM may still be alive.
            if ($runnersToken) {
                try {
                    & "$($Config.RunnersPath)\hyper-v\ubuntu\deregister-runners.ps1" `
                        -Token $runnersToken `
                        -Force
                }
                catch {
                    Write-Warning "Best-effort deregistration failed: $($_.Exception.Message)"
                }
            }

            try { Invoke-VmProvisioningTeardown -Config $Config }
            catch { Write-Warning "Best-effort deprovisioning failed: $($_.Exception.Message)" }

            try { Remove-Secret -Vault VmUsers -Name VmUsersConfig -ErrorAction SilentlyContinue }
            catch {}

            try { Remove-Secret -Vault GitHubRunners -Name GitHubRunnersConfig -ErrorAction SilentlyContinue }
            catch {}
        }
    }
}
