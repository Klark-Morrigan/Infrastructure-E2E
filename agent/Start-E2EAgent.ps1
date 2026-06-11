<#
.SYNOPSIS
    Polls GitHub for pending E2E deployments and runs the full test suite.

.PARAMETER RuntimeHours
    Total number of hours the agent will run before terminating cleanly.
    Defaults to 1. The agent may overshoot by up to TimeoutMinutes (the
    per-session polling window) because the check only fires at session
    boundaries.

.DESCRIPTION
    Reads configuration from the E2EConfig vault, acquires a short-lived
    GitHub App token, then polls the deployments API on a fixed interval
    until a pending deployment is found or the timeout expires.

    When a deployment is found the agent:
      1. Posts 'in_progress' status so the workflow's status poll sees work begin.
      2. Runs Invoke-RunnerLifecycleTest (provisions VM, sets up users, registers
         and verifies the GitHub Actions runner, tears everything down).
      3. Posts 'success' or 'failure' depending on the outcome.
      4. Immediately re-polls so any queued pending deployments are drained
         before sleeping again.

    The agent runs indefinitely - use Ctrl+C to stop it. If a structural error
    occurs (vault unreachable, GitHub API failure), the loop restarts after a
    60-second pause so transient failures do not require operator intervention.

    The token is refreshed automatically when it is within 5 minutes of expiry
    so a long poll wait does not produce a stale-token failure mid-test.

    Prerequisites:
      - setup-secrets.ps1 has been run to populate the E2EConfig vault.
      - PowerShell.Common >= 1.3.3 installed (or will be installed here).
      - Infrastructure.Secrets installed.

.EXAMPLE
    .\agent\Start-E2EAgent.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int] $RuntimeHours = 1,

    # Required. The agent's own persistent config is read as
    # `E2EConfig-<Suffix>`. Operator launches pass `Production`. The
    # agent's lifecycle-internal test fixtures (VmProvisionerConfig,
    # VmUsersConfig, GitHubRunnersConfig) use a separate `E2E` suffix
    # so they're isolated from the operator's persistent vault
    # entries even if the operator runs production workflows on the
    # same workstation.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Invoke-E2EAgentLoop
#   Core polling loop. Runs until $Deadline, processing every pending
#   deployment in the order returned by Get-PendingDeployment (oldest
#   first). After each deployment (pass or fail) the loop re-polls
#   immediately to drain the queue before sleeping again.
#
#   Lifecycle test failures do not propagate - the deployment is marked
#   'failure' on GitHub and polling resumes. Structural errors (token
#   refresh, GitHub API) propagate to the caller for restart handling.
#
#   Isolated from the vault-reading bootstrap so it can be unit-tested
#   without a real vault. $Deadline is injectable for tests; production
#   code passes [DateTime]::MinValue and lets the function compute it
#   from $TimeoutMinutes.
# ---------------------------------------------------------------------------

function Invoke-E2EAgentLoop {
    [CmdletBinding()]
    param(
        # GitHub App credentials - used to obtain both the deployment token
        # (E2EInstallationId) and passed through to the lifecycle test for
        # runner token acquisition (RunnersInstallationId).
        [Parameter(Mandatory)]
        [int] $AppId,

        # Installation ID for the Infrastructure-E2E repo.
        # Used to obtain a token with deployments:write permission.
        [Parameter(Mandatory)]
        [int] $E2EInstallationId,

        # Installation ID for the Infrastructure-GitHubRunners repo.
        # Passed to the lifecycle test so it can mint a token scoped to
        # administration:write on that repo only.
        [Parameter(Mandatory)]
        [int] $RunnersInstallationId,

        # Local path to the GitHub App RSA private key (.pem).
        [Parameter(Mandatory)]
        [string] $PrivateKeyPath,

        # Absolute path to the Infrastructure-Vm-Provisioner repo root on
        # the workstation. Passed to the lifecycle test so it can call
        # provision.ps1 and deprovision.ps1.
        [Parameter(Mandatory)]
        [string] $ProvisionerPath,

        # Absolute path to the Infrastructure-Vm-Users repo root on the
        # workstation. Passed to the lifecycle test so it can call
        # create-users.ps1 (when UsersFlow=custom-powershell) and
        # remove-users.ps1 (always - the teardown half stays on the
        # Vm-Users path for both flows until feature 03 ships).
        [Parameter(Mandatory)]
        [string] $UsersPath,

        # Selects which create-users implementation the test layer
        # dispatches to. 'ansible' is the post-feature-02 default;
        # 'custom-powershell' opts back in to the original Vm-Users path
        # for parallel validation. Both are permanent first-class peers.
        [Parameter()]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $UsersFlow = 'ansible',

        # Selects which register-runners implementation the runner
        # lifecycle test dispatches to. 'custom-powershell' (the current
        # default) keeps invoking Infrastructure-GitHubRunners'
        # register-runners.ps1. 'ansible' opts in to
        # Infrastructure-VM-Ansible's ops/register-runners.sh. The
        # default stays on custom-powershell for one full release cycle
        # while the Ansible path validates on real hardware; the
        # default-flip happens in a follow-up bump.
        [Parameter()]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $RunnersFlow = 'custom-powershell',

        # Absolute path to the Infrastructure-VM-Ansible repo root on the
        # workstation. Required when either UsersFlow=ansible (the users
        # flow default) or RunnersFlow=ansible. Both flows share the same
        # repo and the same WSL distro because the one Infrastructure-
        # VM-Ansible checkout houses ops/create-users.sh,
        # ops/register-runners.sh, and ops/_run-playbook.sh. The loop
        # validates the path exists below before the first VM is built
        # so a misconfigured agent fails at startup, not mid-test.
        [Parameter()]
        [string] $AnsiblePath,

        # Name of the WSL distro to run the Ansible bridge inside. Passed
        # via `wsl -d <name>` so the agent does not depend on the
        # workstation's WSL default - Docker Desktop's installer silently
        # changes the default to its no-bash `docker-desktop` engine
        # distro, which broke this code path until the explicit -d was
        # added. Required when UsersFlow=ansible (the default).
        [Parameter()]
        [string] $WslDistro,

        # Absolute path to the Infrastructure-GitHubRunners repo root on
        # the workstation. Passed to the lifecycle test so it can call
        # register-runners.ps1 and deregister-runners.ps1.
        [Parameter(Mandatory)]
        [string] $RunnersPath,

        # Local directory on the workstation where the actions/runner tarball
        # is cached between test runs. Passed to the lifecycle test so it can
        # pre-seed the VM cache without downloading through the Hyper-V NAT.
        [Parameter(Mandatory)]
        [string] $HostTarballCachePath,

        # Operator-specific VM config for the E2E test VM. Contains the
        # workstation-specific values (IP, gateway, paths) that cannot be
        # hardcoded. Written to the VmProvisioner vault at test startup.
        [Parameter(Mandatory)]
        [PSCustomObject] $TestVm,

        # GitHub organisation or user that owns the E2E repo.
        [Parameter(Mandatory)]
        [string] $Owner,

        # Name of the E2E repository (without the owner prefix).
        [Parameter(Mandatory)]
        [string] $Repo,

        # Deployment environment name to poll.
        # Must match the 'environment' field set when the workflow creates
        # the deployment.
        [Parameter(Mandatory)]
        [string] $Environment,

        # Seconds to wait between polls when no deployment is found.
        [Parameter(Mandatory)]
        [int] $PollIntervalSeconds,

        # Maximum minutes to poll before giving up and exiting cleanly.
        [Parameter(Mandatory)]
        [int] $TimeoutMinutes,

        # Injectable deadline for unit tests. Pass [DateTime]::MinValue
        # (the default) to have the function compute it from $TimeoutMinutes.
        [Parameter()]
        [DateTime] $Deadline = [DateTime]::MinValue
    )

    if ($Deadline -eq [DateTime]::MinValue) {
        $Deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    }

    # Fail-fast: validate AnsiblePath and WslDistro at startup so a
    # misconfigured session does not build a VM and only then discover
    # the bridge is unreachable. custom-powershell ignores both; only
    # the ansible flow on either layer needs them.
    #
    # WslDistro is verified up-front via Assert-WslHasBash from
    # PowerShell.Common - that catches the docker-desktop-default trap
    # (no bash) named in the parameter docs, and surfaces a
    # WslMissingBash: error with a remediation hint instead of letting
    # the bridge fail mid-test with a sparse-PATH error.
    $ansibleFlows = @()
    if ($UsersFlow   -eq 'ansible') { $ansibleFlows += 'UsersFlow' }
    if ($RunnersFlow -eq 'ansible') { $ansibleFlows += 'RunnersFlow' }
    if ($ansibleFlows.Count -gt 0) {
        $flowList = $ansibleFlows -join '/'
        if (-not $AnsiblePath) {
            throw "${flowList}='ansible' requires -AnsiblePath."
        }
        if (-not (Test-Path -LiteralPath $AnsiblePath -PathType Container)) {
            throw "AnsiblePath '$AnsiblePath' does not exist or is not a directory."
        }
        if (-not $WslDistro) {
            throw "${flowList}='ansible' requires -WslDistro."
        }
        Assert-WslHasBash -DistroName $WslDistro
    }

    # Derive display value from the resolved Deadline so injected deadlines
    # (e.g. in tests) show accurate output rather than the TimeoutMinutes param.
    $totalMinutes = [int]($Deadline - [DateTime]::UtcNow).TotalMinutes

    Write-Host "E2E agent started. Polling '$Environment' in $Owner/$Repo." `
        -ForegroundColor Cyan
    Write-Host "Poll interval: ${PollIntervalSeconds}s   Timeout: ${totalMinutes}min" `
        -ForegroundColor Cyan

    # Acquire the initial deployment token. The token lasts 1 hour; the
    # refresh block inside the loop handles long poll waits near that boundary.
    $tokenResult = Get-GitHubAppToken `
        -AppId          $AppId `
        -InstallationId $E2EInstallationId `
        -PrivateKeyPath $PrivateKeyPath

    while ([DateTime]::UtcNow -lt $Deadline) {
        # Refresh the deployment token if fewer than 5 minutes remain.
        # GitHub rejects tokens past their expiry, so proactive refresh
        # prevents a mid-poll authentication failure.
        # ExpiresAt may be a DateTime (ConvertFrom-Json auto-converts ISO 8601)
        # or a string. A direct cast handles both; Parse with the default
        # culture fails when DateTime.ToString() uses locale-specific format.
        $expiry = [DateTimeOffset] $tokenResult.ExpiresAt
        if ($expiry.UtcDateTime -lt [DateTime]::UtcNow.AddMinutes(5)) {
            Write-Host 'Token nearing expiry - refreshing ...' -ForegroundColor Yellow
            $tokenResult = Get-GitHubAppToken `
                -AppId          $AppId `
                -InstallationId $E2EInstallationId `
                -PrivateKeyPath $PrivateKeyPath
        }

        $deployment = Get-PendingDeployment `
            -Token       $tokenResult.Token `
            -Owner       $Owner `
            -Repo        $Repo `
            -Environment $Environment

        if ($null -ne $deployment) {
            Write-Host "Deployment $($deployment.id) found - running E2E tests ..." `
                -ForegroundColor Green

            # Sourced per deployment so test-code edits land in the
            # next iteration without a process restart. PowerShell
            # binds function defs at dot-source time and does not
            # reload them on its own.
            . "$PSScriptRoot\e2e\runner-lifecycle\Invoke-RunnerLifecycleTest.ps1"

            Set-DeploymentStatus `
                -Token        $tokenResult.Token `
                -Owner        $Owner `
                -Repo         $Repo `
                -DeploymentId $deployment.id `
                -State        'in_progress' `
                -Description  'E2E tests running'

            try {
                Invoke-RunnerLifecycleTest -Config ([PSCustomObject]@{
                    AppId                 = $AppId
                    RunnersInstallationId = $RunnersInstallationId
                    PrivateKeyPath        = $PrivateKeyPath
                    ProvisionerPath       = $ProvisionerPath
                    UsersPath             = $UsersPath
                    UsersFlow             = $UsersFlow
                    AnsiblePath           = $AnsiblePath
                    WslDistro             = $WslDistro
                    RunnersPath           = $RunnersPath
                    RunnersFlow           = $RunnersFlow
                    HostTarballCachePath  = $HostTarballCachePath
                    Owner                 = $Owner
                    TestVm                = $TestVm
                })

                Set-DeploymentStatus `
                    -Token        $tokenResult.Token `
                    -Owner        $Owner `
                    -Repo         $Repo `
                    -DeploymentId $deployment.id `
                    -State        'success' `
                    -Description  'All E2E tests passed'

                Write-Host 'E2E tests passed.' -ForegroundColor Green
            }
            catch {
                # GitHub caps deployment status descriptions at 140 characters.
                $msg = $_.Exception.Message
                $description = if ($msg.Length -gt 140) { $msg.Substring(0, 137) + '...' } else { $msg }

                try {
                    Set-DeploymentStatus `
                        -Token        $tokenResult.Token `
                        -Owner        $Owner `
                        -Repo         $Repo `
                        -DeploymentId $deployment.id `
                        -State        'failure' `
                        -Description  $description
                }
                catch {
                    Write-Host "Warning: failed to post failure status to GitHub: $($_.Exception.Message)" `
                        -ForegroundColor Yellow
                }

                Write-Host "E2E tests failed: $msg" -ForegroundColor Red
                continue
            }

            continue
        }

        $remaining = [Math]::Max(0, [int]($Deadline - [DateTime]::UtcNow).TotalMinutes)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No pending deployment. " `
            + "${remaining}min remaining. Waiting ${PollIntervalSeconds}s ..." `
            -ForegroundColor DarkGray

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-Host "Agent timed out after $totalMinutes minutes - no deployment found." `
        -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Script body
#   The guard below prevents this block from running when Start-E2EAgent.ps1
#   is dot-sourced by Pester tests. Tests only need Invoke-E2EAgentLoop above.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {

    . "$PSScriptRoot\Initialize-E2EEnvironment.ps1"

    # ---------------------------------------------------------------------------
    # Read E2EConfig from vault
    #
    # Expected JSON shape:
    # {
    #   "AppId":               123456,
    #   "PrivateKeyPath":      "C:\\certs\\my-app.private-key.pem",
    #   "E2EInstallationId":   111111,
    #   "RunnersInstallationId": 222222,
    #   "Owner":               "my-org",
    #   "Repo":                "Infrastructure-E2E",
    #   "Environment":         "e2e-workstation",
    #   "PollIntervalSeconds": 30,
    #   "TimeoutMinutes":      10,
    #   "ProvisionerPath":     "C:\\a_Code\\Infrastructure-Vm-Provisioner",
    #   "UsersPath":           "C:\\a_Code\\Infrastructure-Vm-Users",
    #   "RunnersPath":         "C:\\a_Code\\Infrastructure-GitHubRunners",
    #   "RunnersFlow":         "custom-powershell",
    #   "HostTarballCachePath": "C:\\cache\\github-runners",
    #   "TestVm": {
    #     "ubuntuVersion":       "24.04",
    #     "dns":                 "8.8.8.8",
    #     "externalSwitchName":  "ExternalSwitch-Shared",
    #     "externalAdapterName": "Ethernet",
    #     "vmConfigPath":        "E:\\a_VMs\\Hyper-V\\Config",
    #     "vhdPath":             "E:\\a_VMs\\Hyper-V\\Disks"
    #   }
    # }
    #
    # The router VM the test provisions in front of every workload VM
    # (feature 53 topology) takes its upstream IP from DHCP - whatever
    # LAN the host's External vSwitch is bridged to. No operator IP
    # values to pin in TestVm; the orchestrator discovers the router's
    # actual IP via Hyper-V KVP after boot. Workload VMs sit on
    # PrivateSwitch-E2E at 10.99.0.10 / 10.99.0.11 (constants chosen
    # by the test fixture, not operator config). `dns` is dnsmasq's
    # upstream forwarder on the router; `externalSwitchName` /
    # `externalAdapterName` configure the host-side vSwitch.
    # ---------------------------------------------------------------------------

    $e2eSecretName = "E2EConfig-$SecretSuffix"
    Write-Host "Reading $e2eSecretName from vault ..." -ForegroundColor Cyan

    $configJson = Get-InfrastructureSecret -VaultName 'E2EConfig' -SecretName $e2eSecretName
    $config     = $configJson | ConvertFrom-Json

    $globalDeadline = [DateTime]::UtcNow.AddHours($RuntimeHours)
    Write-Host ("Agent will terminate after $RuntimeHours hour(s) " +
        "at $($globalDeadline.ToString('HH:mm:ss')) UTC.") -ForegroundColor Cyan

    # Each iteration is one polling session (TimeoutMinutes long). The global
    # deadline is checked at session boundaries so the agent stops without
    # operator intervention. PipelineStoppedException (Ctrl+C) is re-thrown
    # so the operator can also stop it early.
    # UsersFlow / RunnersFlow / AnsiblePath / WslDistro are optional in
    # the vault payload so older E2EConfig files do not need a re-write
    # to keep working. When absent, Invoke-E2EAgentLoop's defaults
    # (UsersFlow=ansible, RunnersFlow=custom-powershell) apply, and
    # WslDistro has no default - if either flow is 'ansible' the loop
    # fail-fasts with a named error so the operator adds it to the vault
    # rather than the agent guessing. Strict mode requires guarded
    # property access.
    $vaultUsersFlow   = $null
    $vaultRunnersFlow = $null
    $vaultAnsiblePath = $null
    $vaultWslDistro   = $null
    if ($config.PSObject.Properties['UsersFlow'])   { $vaultUsersFlow   = $config.UsersFlow }
    if ($config.PSObject.Properties['RunnersFlow']) { $vaultRunnersFlow = $config.RunnersFlow }
    if ($config.PSObject.Properties['AnsiblePath']) { $vaultAnsiblePath = $config.AnsiblePath }
    if ($config.PSObject.Properties['WslDistro'])   { $vaultWslDistro   = $config.WslDistro }

    while ([DateTime]::UtcNow -lt $globalDeadline) {
        try {
            $loopParams = @{
                AppId                 = $config.AppId
                E2EInstallationId     = $config.E2EInstallationId
                RunnersInstallationId = $config.RunnersInstallationId
                PrivateKeyPath        = $config.PrivateKeyPath
                ProvisionerPath       = $config.ProvisionerPath
                UsersPath             = $config.UsersPath
                RunnersPath           = $config.RunnersPath
                HostTarballCachePath  = $config.HostTarballCachePath
                TestVm                = $config.TestVm
                Owner                 = $config.Owner
                Repo                  = $config.Repo
                Environment           = $config.Environment
                PollIntervalSeconds   = $config.PollIntervalSeconds
                TimeoutMinutes        = $config.TimeoutMinutes
            }
            if ($vaultUsersFlow)   { $loopParams['UsersFlow']   = $vaultUsersFlow }
            if ($vaultRunnersFlow) { $loopParams['RunnersFlow'] = $vaultRunnersFlow }
            if ($vaultAnsiblePath) { $loopParams['AnsiblePath'] = $vaultAnsiblePath }
            if ($vaultWslDistro)   { $loopParams['WslDistro']   = $vaultWslDistro }

            Invoke-E2EAgentLoop @loopParams
        }
        catch [System.Management.Automation.PipelineStoppedException] {
            throw
        }
        catch {
            Write-Host "Agent crashed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'Restarting in 60 seconds ...' -ForegroundColor Yellow
            Start-Sleep -Seconds 60
        }
    }

    Write-Host "Global runtime of $RuntimeHours hour(s) elapsed. Agent stopping." `
        -ForegroundColor Yellow
}
