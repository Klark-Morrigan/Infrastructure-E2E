<#
.NOTES
    Dot-sourced by Start-E2EAgent.ps1's restart handler. Kept in its own
    file so the crash-routing is unit-testable in isolation.
#>

# ---------------------------------------------------------------------------
# Resolve-AgentCrashAction
#   Decides how the restart handler should react to a caught crash, with no
#   side effects so the routing is testable. Composes the two crash
#   classifiers and returns the chosen action:
#
#     Backoff  - a GitHub rate-limit crash. DelaySeconds is the reset-aware
#                wait from Get-RateLimitBackoffDelay; the caller sleeps it
#                then resumes.
#     Stop     - a non-self-healing auth failure (401, or a permission 403).
#                The caller stops the agent so the operator fixes the
#                credentials / Owner.
#     Restart  - anything else (transient/structural). DelaySeconds is the
#                flat restart pause.
#
#   Order matters: rate-limit is checked first because a rate-limit response
#   is also a 403, and Test-GitHubAuthError deliberately excludes those - so
#   classifying rate-limit up front keeps a throttled run on the Backoff path
#   instead of mistaking it for a permission denial.
# ---------------------------------------------------------------------------

function Resolve-AgentCrashAction {
    [CmdletBinding()]
    param(
        # The terminating error caught by the restart handler ($_).
        [Parameter(Mandatory)]
        $ErrorRecord,

        # Flat pause (seconds) before a plain restart. Injectable so tests
        # do not hard-code the historical 60s.
        [Parameter()]
        [int] $RestartDelaySeconds = 60
    )

    $backoffSeconds = Get-RateLimitBackoffDelay -ErrorRecord $ErrorRecord
    if ($backoffSeconds -gt 0) {
        return [PSCustomObject]@{ Action = 'Backoff'; DelaySeconds = $backoffSeconds }
    }

    if (Test-GitHubAuthError -ErrorRecord $ErrorRecord) {
        return [PSCustomObject]@{ Action = 'Stop'; DelaySeconds = 0 }
    }

    [PSCustomObject]@{ Action = 'Restart'; DelaySeconds = $RestartDelaySeconds }
}
