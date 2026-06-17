BeforeAll {
    # Source the helper from its own file - it now lives apart from the agent
    # script, so the test no longer has to dot-source Start-E2EAgent.ps1 (nor
    # satisfy its mandatory -SecretSuffix) just to reach this one function.
    . "$PSScriptRoot\..\agent\Get-RateLimitBackoffDelay.ps1"

    # Builds an ErrorRecord-shaped double. The helper only ever reads
    # .Exception.Message, .Exception.Response.StatusCode, and
    # .Exception.Response.Headers, so a PSCustomObject graph is enough and
    # keeps the test free of real HttpResponseException construction.
    function New-ErrorRecordDouble {
        param(
            [string]    $Message,
            [int]       $StatusCode = -1,   # -1 => no Response object at all
            [hashtable] $Headers           # header-name -> value, optional
        )

        if ($StatusCode -lt 0) {
            return [PSCustomObject]@{ Exception = [PSCustomObject]@{ Message = $Message } }
        }

        $response = [PSCustomObject]@{ StatusCode = $StatusCode }

        if ($PSBoundParameters.ContainsKey('Headers')) {
            $headerObject = [PSCustomObject]@{ Map = $Headers }
            # Mimic HttpResponseHeaders.TryGetValues(name, out values): set the
            # [ref] target and return whether the header was present.
            $headerObject | Add-Member -MemberType ScriptMethod -Name TryGetValues -Value {
                param($name, $values)
                if ($this.Map.ContainsKey($name)) {
                    $values.Value = @($this.Map[$name])
                    return $true
                }
                return $false
            }
            $response | Add-Member -MemberType NoteProperty -Name Headers -Value $headerObject
        }

        [PSCustomObject]@{
            Exception = [PSCustomObject]@{ Message = $Message; Response = $response }
        }
    }
}

Describe 'Get-RateLimitBackoffDelay' {

    # ------------------------------------------------------------------
    Context 'non-rate-limit crashes' {
    # ------------------------------------------------------------------

        It 'returns 0 for an ordinary error with no HTTP response' {
            $err = New-ErrorRecordDouble -Message 'disk full'
            Get-RateLimitBackoffDelay -ErrorRecord $err | Should -Be 0
        }

        It 'returns 0 for a bare 403 that does not name the rate limit' {
            # GitHub also returns 403 for permission failures; those must keep
            # crashing loudly rather than be parked for the rolling window.
            $err = New-ErrorRecordDouble `
                -Message 'Resource not accessible by integration' -StatusCode 403
            Get-RateLimitBackoffDelay -ErrorRecord $err | Should -Be 0
        }
    }

    # ------------------------------------------------------------------
    Context 'rate-limit crashes without machine-readable reset' {
    # ------------------------------------------------------------------

        It 'backs off the default when a 403 body names the rate limit' {
            $err = New-ErrorRecordDouble `
                -Message 'Response status code does not indicate success: 403 (rate limit exceeded).' `
                -StatusCode 403
            # Default + 5s buffer.
            Get-RateLimitBackoffDelay -ErrorRecord $err -DefaultBackoffSeconds 100 |
                Should -Be 105
        }

        It 'treats a 429 as a rate limit even when the message is generic' {
            $err = New-ErrorRecordDouble -Message 'Too Many Requests' -StatusCode 429
            Get-RateLimitBackoffDelay -ErrorRecord $err -DefaultBackoffSeconds 100 |
                Should -Be 105
        }
    }

    # ------------------------------------------------------------------
    Context 'rate-limit crashes with reset headers' {
    # ------------------------------------------------------------------

        It 'honours retry-after (seconds-to-wait) plus the buffer' {
            $err = New-ErrorRecordDouble -Message 'secondary rate limit' -StatusCode 403 `
                -Headers @{ 'retry-after' = '300' }
            Get-RateLimitBackoffDelay -ErrorRecord $err | Should -Be 305
        }

        It 'derives the wait from the x-ratelimit-reset epoch' {
            $resetEpoch = [DateTimeOffset]::UtcNow.AddSeconds(120).ToUnixTimeSeconds()
            $err = New-ErrorRecordDouble -Message 'rate limit exceeded' -StatusCode 403 `
                -Headers @{ 'x-ratelimit-reset' = "$resetEpoch" }

            $delay = Get-RateLimitBackoffDelay -ErrorRecord $err
            # ~120s until reset, plus the 5s buffer, allowing for clock drift
            # between building the epoch and reading it back.
            $delay | Should -BeGreaterThan 110
            $delay | Should -BeLessThan 135
        }

        It 'clamps an oversized reset to MaxBackoffSeconds' {
            $err = New-ErrorRecordDouble -Message 'rate limit exceeded' -StatusCode 403 `
                -Headers @{ 'retry-after' = '99999' }
            Get-RateLimitBackoffDelay -ErrorRecord $err -MaxBackoffSeconds 3600 |
                Should -Be 3600
        }
    }
}
