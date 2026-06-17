<#
.NOTES
    Dot-sourced by Start-E2EAgent.ps1's restart handler. Kept in its own
    file so the crash-backoff policy is unit-testable in isolation and the
    agent script stays focused on the polling loop and bootstrap.
#>

# ---------------------------------------------------------------------------
# Get-RateLimitBackoffDelay
#   Decides how long (in seconds) the agent's restart handler should sleep
#   after a crash.
#   A GitHub rate-limit exhaustion (HTTP 429, or a 403 whose body names the
#   rate limit) is transient but only clears when GitHub's rolling window
#   resets - up to an hour away. A flat 60s restart would just crash-loop
#   against an empty budget, so this returns a longer, reset-aware delay for
#   rate-limit crashes and 0 for everything else (the caller then uses its
#   normal short restart).
#
#   Discrimination is by message text / 429 status, NOT a blanket 403:
#   GitHub also returns 403 for genuine permission failures, and those must
#   keep crashing loudly rather than be silently parked for the window.
#
#   Reset timing prefers GitHub's machine-readable headers (x-ratelimit-reset
#   epoch, or retry-after seconds) and falls back to a fixed default when the
#   response carries no usable header. Header reading is defensive - the
#   container shape varies across PowerShell/.NET versions - so any failure
#   degrades to the default rather than throwing inside the crash handler.
# ---------------------------------------------------------------------------

function Get-RateLimitBackoffDelay {
    [CmdletBinding()]
    param(
        # The terminating error caught by the restart handler ($_).
        [Parameter(Mandatory)]
        $ErrorRecord,

        # Wait used when the crash is rate-limit related but the response
        # exposes no machine-readable reset time.
        [Parameter()]
        [int] $DefaultBackoffSeconds = 900,

        # Hard ceiling so a malformed reset header can never park the agent
        # for longer than the rolling-window length.
        [Parameter()]
        [int] $MaxBackoffSeconds = 3600
    )

    $exception = $ErrorRecord.Exception

    # The HTTP response is only present when the crash came from
    # Invoke-RestMethod (PS7 surfaces it as HttpResponseException.Response).
    # Every hop is guarded: plain exceptions and the test doubles omit it.
    $response = $null
    if ($exception.PSObject.Properties['Response']) { $response = $exception.Response }

    $statusCode = $null
    if ($response -and $response.PSObject.Properties['StatusCode']) {
        $statusCode = [int] $response.StatusCode
    }

    # 429 is always a rate limit; a message naming the rate limit covers
    # GitHub's primary ("rate limit exceeded") and secondary ("secondary
    # rate limit") 403 responses. A bare 403 is left to crash normally.
    $message     = [string] $exception.Message
    $isRateLimit = ($statusCode -eq 429) -or ($message -imatch 'rate limit')
    if (-not $isRateLimit) { return 0 }

    $delay = $DefaultBackoffSeconds
    try {
        if ($response -and $response.PSObject.Properties['Headers'] -and $response.Headers) {
            # retry-after wins when present (it is the explicit, already-
            # relative wait GitHub returns for secondary limits); otherwise
            # derive the wait from the absolute x-ratelimit-reset epoch.
            $resetValues = $null
            if ($response.Headers.TryGetValues('x-ratelimit-reset', [ref] $resetValues)) {
                $resetEpoch = [long] ($resetValues | Select-Object -First 1)
                $resetTime  = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch)
                $delay      = [int] ($resetTime - [DateTimeOffset]::UtcNow).TotalSeconds
            }
            $retryValues = $null
            if ($response.Headers.TryGetValues('retry-after', [ref] $retryValues)) {
                $delay = [int] ($retryValues | Select-Object -First 1)
            }
        }
    }
    catch {
        # Header container was not the shape we expected - use the default.
        $delay = $DefaultBackoffSeconds
    }

    # Small buffer so we resume just after the window opens; then clamp so a
    # stale or negative reset cannot starve or over-park the agent.
    $delay += 5
    if ($delay -lt 1)                  { $delay = $DefaultBackoffSeconds }
    if ($delay -gt $MaxBackoffSeconds) { $delay = $MaxBackoffSeconds }
    return $delay
}
