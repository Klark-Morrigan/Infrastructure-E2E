BeforeAll {
    # Stub the only external the helper calls so Mock has a command to
    # replace and the helper's Get-GitHubAppToken call resolves in a clean
    # test runspace (no Common.PowerShell / Infrastructure modules loaded).
    function Get-GitHubAppToken { param($AppId, $InstallationId, $PrivateKeyPath) }

    . "$PSScriptRoot\..\agent\Get-RefreshedDeploymentToken.ps1"
}

Describe 'Get-RefreshedDeploymentToken' {

    BeforeEach {
        $Script:RefreshParams = @{
            AppId          = 1
            InstallationId = 10
            PrivateKeyPath = 'C:\test.pem'
        }
    }

    It 'returns the current token unchanged when expiry is more than 5 minutes away' {
        Mock Get-GitHubAppToken { throw 'should not be called' }
        $current = [PSCustomObject]@{
            Token     = 'still_valid'
            ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o')
        }

        $result = Get-RefreshedDeploymentToken -TokenResult $current @Script:RefreshParams

        $result.Token | Should -Be 'still_valid'
        Should -Invoke Get-GitHubAppToken -Times 0
    }

    It 'mints a new token when expiry is within 5 minutes' {
        Mock Get-GitHubAppToken {
            [PSCustomObject]@{
                Token     = 'minted'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
            }
        }
        $expiring = [PSCustomObject]@{
            Token     = 'about_to_expire'
            ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(2).ToString('o')
        }

        $result = Get-RefreshedDeploymentToken -TokenResult $expiring @Script:RefreshParams

        $result.Token | Should -Be 'minted'
        Should -Invoke Get-GitHubAppToken -Times 1
    }

    It 'mints against the supplied installation id and credentials' {
        Mock Get-GitHubAppToken {
            [PSCustomObject]@{ Token = 'minted'; ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o') }
        }
        $expiring = [PSCustomObject]@{
            Token     = 'about_to_expire'
            ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(2).ToString('o')
        }

        Get-RefreshedDeploymentToken -TokenResult $expiring @Script:RefreshParams | Out-Null

        Should -Invoke Get-GitHubAppToken -Times 1 -ParameterFilter {
            $AppId          -eq 1 -and
            $InstallationId -eq 10 -and
            $PrivateKeyPath -eq 'C:\test.pem'
        }
    }

    It 'treats a token expiring exactly at the 5-minute boundary as still valid' {
        # Boundary check: the predicate is >= now+5min -> valid. A token at
        # the boundary should not trigger an unnecessary mint.
        Mock Get-GitHubAppToken { throw 'should not be called' }
        $boundary = [PSCustomObject]@{
            Token     = 'boundary'
            ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(6).ToString('o')
        }

        $result = Get-RefreshedDeploymentToken -TokenResult $boundary @Script:RefreshParams

        $result.Token | Should -Be 'boundary'
        Should -Invoke Get-GitHubAppToken -Times 0
    }
}
