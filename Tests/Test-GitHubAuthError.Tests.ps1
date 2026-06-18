BeforeAll {
    # Source the helper from its own file - no need to drag in Start-E2EAgent.ps1.
    . "$PSScriptRoot\..\agent\Test-GitHubAuthError.ps1"

    # ErrorRecord-shaped double. The helper only reads .Exception.Message and
    # .Exception.Response.StatusCode, so a PSCustomObject graph suffices.
    # StatusCode = -1 means "no Response object" (a non-HTTP error).
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

Describe 'Test-GitHubAuthError' {

    # ------------------------------------------------------------------
    Context 'auth failures (true)' {
    # ------------------------------------------------------------------

        It 'returns true for a 401' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 401 (Unauthorized).' `
                -StatusCode 401
            Test-GitHubAuthError -ErrorRecord $err | Should -BeTrue
        }

        It 'returns true for a 403 that is not a rate limit (permission denial)' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 403 (Forbidden).' `
                -StatusCode 403
            Test-GitHubAuthError -ErrorRecord $err | Should -BeTrue
        }
    }

    # ------------------------------------------------------------------
    Context 'non-auth failures (false)' {
    # ------------------------------------------------------------------

        It 'returns false for a 403 rate-limit response (handled upstream as transient)' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 403 (rate limit exceeded).' `
                -StatusCode 403
            Test-GitHubAuthError -ErrorRecord $err | Should -BeFalse
        }

        It 'returns false for a 429 (rate limit, not auth)' {
            $err = New-ErrorRecordDouble -Message 'Too Many Requests' -StatusCode 429
            Test-GitHubAuthError -ErrorRecord $err | Should -BeFalse
        }

        It 'returns false for a 404' {
            $err = New-ErrorRecordDouble -Message 'Not Found' -StatusCode 404
            Test-GitHubAuthError -ErrorRecord $err | Should -BeFalse
        }

        It 'returns false for a non-HTTP error with no response' {
            $err = New-ErrorRecordDouble -Message 'disk full'
            Test-GitHubAuthError -ErrorRecord $err | Should -BeFalse
        }
    }

    # ------------------------------------------------------------------
    Context 'message fallback when the status code is unreachable' {
    # ------------------------------------------------------------------

        It 'recognises a 401 from the message text alone' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 401 (Unauthorized).'
            Test-GitHubAuthError -ErrorRecord $err | Should -BeTrue
        }

        It 'recognises a permission 403 from the message text alone' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 403 (Forbidden).'
            Test-GitHubAuthError -ErrorRecord $err | Should -BeTrue
        }

        It 'does not treat a 403 rate-limit message as auth' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 403 (rate limit exceeded).'
            Test-GitHubAuthError -ErrorRecord $err | Should -BeFalse
        }
    }
}
