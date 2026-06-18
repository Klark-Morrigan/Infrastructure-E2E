<#
.NOTES
    Dot-sourced by Start-E2EAgent.ps1's restart handler. Kept in its own
    file so the crash-classification is unit-testable in isolation.
#>

# ---------------------------------------------------------------------------
# Test-GitHubAuthError
#   True when a caught error is a GitHub auth/authorization failure that will
#   not self-heal on retry: HTTP 401 (bad/expired credentials, or a wrong
#   Owner that no longer resolves), or a 403 that is NOT a rate-limit
#   response (a permission denial). The restart handler stops on these
#   instead of retrying every 60s, which would just burn the API budget
#   against a config error until the rate limit trips.
#
#   Rate-limit 403s are excluded here: they are transient and the caller
#   routes them to the reset-aware backoff (Get-RateLimitBackoffDelay)
#   before this check, so a 403 reaching here is a permission denial.
#
#   Status is read from the HttpResponseException's Response (PS7); when
#   that is not reachable the message text is the fallback. Every hop is
#   guarded so a non-HTTP error simply returns false.
# ---------------------------------------------------------------------------

function Test-GitHubAuthError {
    [CmdletBinding()]
    param(
        # The terminating error caught by the restart handler ($_).
        [Parameter(Mandatory)]
        $ErrorRecord
    )

    $exception = $ErrorRecord.Exception

    $response = $null
    if ($exception.PSObject.Properties['Response']) { $response = $exception.Response }

    $statusCode = $null
    if ($response -and $response.PSObject.Properties['StatusCode']) {
        $statusCode = [int] $response.StatusCode
    }

    $message = [string] $exception.Message

    # 401 is always auth. A 403 counts only when it does not name the rate
    # limit (those are handled upstream as transient).
    if ($statusCode -eq 401) { return $true }
    if ($statusCode -eq 403 -and $message -inotmatch 'rate limit') { return $true }

    # Fallback when the status code is not reachable on the exception.
    if ($message -imatch '401 \(Unauthorized\)') { return $true }
    if ($message -imatch '403 \(Forbidden\)' -and $message -inotmatch 'rate limit') {
        return $true
    }

    return $false
}
