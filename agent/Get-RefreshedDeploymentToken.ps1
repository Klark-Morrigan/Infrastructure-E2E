<#
.NOTES
    Dot-sourced by Start-E2EAgent.ps1 and called from Invoke-E2EAgentLoop.
    Kept in its own file so the near-expiry refresh decision is unit-testable
    in isolation (see Get-RefreshedDeploymentToken.Tests.ps1).
#>

# ---------------------------------------------------------------------------
# Get-RefreshedDeploymentToken
#   Returns a deployment token guaranteed valid for at least the next
#   5 minutes, re-minting only when the current one is inside that window.
#
#   GitHub App installation tokens live exactly 1 hour. The polling loop
#   refreshes at the top of each tick, but a single lifecycle run
#   (provision -> users -> register -> verify -> teardown) can itself
#   outlast the remaining lifetime, so the token that was fresh when the
#   run started can be expired by the time the terminal status is posted -
#   surfacing as a 401 on the success/failure write. Calling this helper
#   immediately before those posts closes that gap. The conditional keeps
#   a short run (token still comfortably valid) from minting needlessly.
# ---------------------------------------------------------------------------
function Get-RefreshedDeploymentToken {
    [CmdletBinding()]
    param(
        # The token currently in hand. Returned unchanged when still valid.
        [Parameter(Mandatory)]
        [psobject] $TokenResult,

        [Parameter(Mandatory)]
        [int] $AppId,

        # E2E installation ID - the refresh must re-authenticate against the
        # same installation (deployments:write) the original token used.
        [Parameter(Mandatory)]
        [int] $InstallationId,

        [Parameter(Mandatory)]
        [string] $PrivateKeyPath
    )

    # ExpiresAt may be a DateTime (ConvertFrom-Json auto-converts ISO 8601)
    # or a string. A direct cast handles both; Parse with the default
    # culture fails when DateTime.ToString() uses a locale-specific format.
    $expiry = [DateTimeOffset] $TokenResult.ExpiresAt
    if ($expiry.UtcDateTime -ge [DateTime]::UtcNow.AddMinutes(5)) {
        return $TokenResult
    }

    Write-Host 'Token nearing expiry - refreshing ...' -ForegroundColor Yellow
    return Get-GitHubAppToken `
        -AppId          $AppId `
        -InstallationId $InstallationId `
        -PrivateKeyPath $PrivateKeyPath
}
