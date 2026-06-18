BeforeAll {
    # Source the decision helper and the two classifiers it composes, so the
    # routing is exercised end-to-end (real precedence, not mocks).
    . "$PSScriptRoot\..\agent\Get-RateLimitBackoffDelay.ps1"
    . "$PSScriptRoot\..\agent\Test-GitHubAuthError.ps1"
    . "$PSScriptRoot\..\agent\Resolve-AgentCrashAction.ps1"

    # ErrorRecord-shaped double. StatusCode = -1 means "no Response object".
    function New-ErrorRecordDouble {
        param(
            [string] $Message,
            [int]    $StatusCode = -1
        )
        if ($StatusCode -lt 0) {
            return [PSCustomObject]@{ Exception = [PSCustomObject]@{ Message = $Message } }
        }
        [PSCustomObject]@{
            Exception = [PSCustomObject]@{
                Message  = $Message
                Response = [PSCustomObject]@{ StatusCode = $StatusCode }
            }
        }
    }
}

Describe 'Resolve-AgentCrashAction' {

    # ------------------------------------------------------------------
    Context 'rate-limit crashes -> Backoff' {
    # ------------------------------------------------------------------

        It 'routes a 429 to Backoff with a positive delay' {
            $err = New-ErrorRecordDouble -Message 'Too Many Requests' -StatusCode 429
            $action = Resolve-AgentCrashAction -ErrorRecord $err
            $action.Action       | Should -Be 'Backoff'
            $action.DelaySeconds | Should -BeGreaterThan 0
        }

        It 'routes a 403 rate-limit to Backoff, NOT Stop (precedence over auth)' {
            # A rate-limit response is also a 403; rate-limit must be classified
            # first so a throttled run backs off instead of stopping as "auth".
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 403 (rate limit exceeded).' `
                -StatusCode 403
            (Resolve-AgentCrashAction -ErrorRecord $err).Action | Should -Be 'Backoff'
        }
    }

    # ------------------------------------------------------------------
    Context 'auth crashes -> Stop' {
    # ------------------------------------------------------------------

        It 'routes a 401 to Stop' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 401 (Unauthorized).' `
                -StatusCode 401
            (Resolve-AgentCrashAction -ErrorRecord $err).Action | Should -Be 'Stop'
        }

        It 'routes a permission 403 (not rate limit) to Stop' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 403 (Forbidden).' `
                -StatusCode 403
            (Resolve-AgentCrashAction -ErrorRecord $err).Action | Should -Be 'Stop'
        }
    }

    # ------------------------------------------------------------------
    Context 'other crashes -> Restart' {
    # ------------------------------------------------------------------

        It 'routes a generic error to Restart with the default 60s delay' {
            $err = New-ErrorRecordDouble -Message 'disk full'
            $action = Resolve-AgentCrashAction -ErrorRecord $err
            $action.Action       | Should -Be 'Restart'
            $action.DelaySeconds | Should -Be 60
        }

        It 'routes a 404 to Restart' {
            $err = New-ErrorRecordDouble -Message 'Not Found' -StatusCode 404
            (Resolve-AgentCrashAction -ErrorRecord $err).Action | Should -Be 'Restart'
        }

        It 'honours an injected RestartDelaySeconds' {
            $err = New-ErrorRecordDouble -Message 'disk full'
            $action = Resolve-AgentCrashAction -ErrorRecord $err -RestartDelaySeconds 5
            $action.Action       | Should -Be 'Restart'
            $action.DelaySeconds | Should -Be 5
        }
    }
}
