<#
.SYNOPSIS
    Polls GitHub for a pending E2E deployment and runs the full test suite.

.DESCRIPTION
    Reads configuration from the E2EConfig vault, acquires a short-lived
    GitHub App token, then polls the deployments API on a fixed interval
    until a pending deployment is found or the timeout expires.

    When a deployment is found the agent:
      1. Posts 'in_progress' status so the workflow's status poll sees work begin.
      2. Runs Invoke-RunnerLifecycleTest (provisions VM, sets up users, registers
         and verifies the GitHub Actions runner, tears everything down).
      3. Posts 'success' or 'failure' depending on the outcome.

    The token is refreshed automatically when it is within 5 minutes of expiry
    so a long poll wait does not produce a stale-token failure mid-test.

    Prerequisites:
      - setup-secrets.ps1 has been run to populate the E2EConfig vault.
      - Infrastructure.Common >= 1.3.3 installed (or will be installed here).
      - Infrastructure.Secrets installed.

.EXAMPLE
    .\agent\Start-E2EAgent.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Invoke-E2EAgentLoop
#   Core polling logic. Isolated from the vault-reading bootstrap so it
#   can be unit-tested without a real vault.
#
#   $Deadline is injectable for unit tests; production code always passes
#   [DateTime]::MinValue and lets the function compute it from $TimeoutMinutes.
#   This avoids real-clock dependency in tests without adding a test-only
#   abstraction layer to the function signature.
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
        # Passed to the lifecycle test so it can acquire an actions:write token.
        [Parameter(Mandatory)]
        [int] $RunnersInstallationId,

        # Local path to the GitHub App RSA private key (.pem).
        [Parameter(Mandatory)]
        [string] $PrivateKeyPath,

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

    Write-Host "E2E agent started. Polling '$Environment' in $Owner/$Repo." `
        -ForegroundColor Cyan
    Write-Host "Poll interval: ${PollIntervalSeconds}s   Timeout: ${TimeoutMinutes}min" `
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
        $expiry = [DateTimeOffset]::Parse($tokenResult.ExpiresAt)
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
                Set-DeploymentStatus `
                    -Token        $tokenResult.Token `
                    -Owner        $Owner `
                    -Repo         $Repo `
                    -DeploymentId $deployment.id `
                    -State        'failure' `
                    -Description  $_.Exception.Message

                Write-Host "E2E tests failed: $($_.Exception.Message)" `
                    -ForegroundColor Red
                throw
            }

            return
        }

        $remaining = [Math]::Max(0, [int]($Deadline - [DateTime]::UtcNow).TotalMinutes)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No pending deployment. " `
            + "${remaining}min remaining. Waiting ${PollIntervalSeconds}s ..." `
            -ForegroundColor DarkGray

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-Host "Agent timed out after $TimeoutMinutes minutes - no deployment found." `
        -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Script body
#   The guard below prevents this block from running when Start-E2EAgent.ps1
#   is dot-sourced by Pester tests. Tests only need Invoke-E2EAgentLoop above.
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {

    # Bootstrap Infrastructure.Common - the only install that cannot use
    # Invoke-ModuleInstall because it IS Invoke-ModuleInstall's module.
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Scope CurrentUser -Force -ForceBootstrap | Out-Null
    $_common = Get-Module -ListAvailable -Name Infrastructure.Common |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $_common -or $_common.Version -lt [Version]'1.3.3') {
        Install-Module Infrastructure.Common -Scope CurrentUser -Force
    }
    Import-Module Infrastructure.Common -Force -ErrorAction Stop

    Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '2.1.0'

    Use-MicrosoftPowerShellSecretStoreProvider

    # Dot-source the lifecycle test so Invoke-RunnerLifecycleTest is available
    # to the loop function above. This must happen after Infrastructure.Common
    # is loaded because the lifecycle test depends on it.
    . "$PSScriptRoot\e2e\runner-lifecycle\Invoke-RunnerLifecycleTest.ps1"

    # ---------------------------------------------------------------------------
    # Read E2EConfig from vault
    #
    # Expected JSON shape:
    # {
    #   "AppId":                 123456,
    #   "PrivateKeyPath":        "C:\\certs\\my-app.private-key.pem",
    #   "E2EInstallationId":     111111,
    #   "RunnersInstallationId": 222222,
    #   "Owner":                 "my-org",
    #   "Repo":                  "Infrastructure-E2E",
    #   "Environment":           "e2e-workstation",
    #   "PollIntervalSeconds":   30,
    #   "TimeoutMinutes":        60
    # }
    # ---------------------------------------------------------------------------

    Write-Host 'Reading E2EConfig from vault ...' -ForegroundColor Cyan

    $configJson = Get-InfrastructureSecret -VaultName 'E2EConfig' -SecretName 'E2EConfig'
    $config     = $configJson | ConvertFrom-Json

    Invoke-E2EAgentLoop `
        -AppId                 $config.AppId `
        -E2EInstallationId     $config.E2EInstallationId `
        -RunnersInstallationId $config.RunnersInstallationId `
        -PrivateKeyPath        $config.PrivateKeyPath `
        -Owner                 $config.Owner `
        -Repo                  $config.Repo `
        -Environment           $config.Environment `
        -PollIntervalSeconds   $config.PollIntervalSeconds `
        -TimeoutMinutes        $config.TimeoutMinutes
}
