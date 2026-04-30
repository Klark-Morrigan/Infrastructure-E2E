BeforeAll {
    # Stub every external function the loop calls so tests never hit real
    # infrastructure. All stubs are overridden by Mocks inside each Context.
    function Get-GitHubAppToken         { param($AppId, $InstallationId, $PrivateKeyPath) }
    function Get-PendingDeployment      { param($Token, $Owner, $Repo, $Environment) }
    function Set-DeploymentStatus       { param($Token, $Owner, $Repo, $DeploymentId, $State, $Description, $LogUrl) }
    function Invoke-RunnerLifecycleTest { param($Config) }

    . "$PSScriptRoot\..\agent\Start-E2EAgent.ps1"
}

Describe 'Invoke-E2EAgentLoop' {

    BeforeAll {
        # Shared parameters. Deadline is set well in the future so tests that
        # exit via a found deployment are unambiguous. PollIntervalSeconds=0
        # removes Start-Sleep latency. Tests controlling timeout inject their
        # own Deadline via Clone() + override.
        $Script:BaseParams = @{
            AppId                 = 1
            E2EInstallationId     = 10
            RunnersInstallationId = 20
            PrivateKeyPath        = 'C:\test.pem'
            ProvisionerPath       = 'C:\test\provisioner'
            TestVm                = [PSCustomObject]@{
                ubuntuVersion = '24.04'
                ipAddress     = '192.168.100.200'
                subnetMask    = 24
                gateway       = '192.168.100.1'
                dns           = '8.8.8.8'
                vmConfigPath  = 'E:\a_VMs\Hyper-V\Config'
                vhdPath       = 'E:\a_VMs\Hyper-V\Disks'
            }
            Owner                 = 'org'
            Repo                  = 'repo'
            Environment           = 'e2e-workstation'
            PollIntervalSeconds   = 0
            TimeoutMinutes        = 60
            Deadline              = [DateTime]::UtcNow.AddMinutes(60)
        }

        # Token with expiry safely in the future - used wherever the refresh
        # path is NOT under test.
        $Script:FreshToken = [PSCustomObject]@{
            Token     = 'tok'
            ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
        }
    }

    # ------------------------------------------------------------------
    Context 'token acquisition' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Get-GitHubAppToken { $Script:FreshToken }
            # Return a deployment so the loop exits after one tick; this
            # context only cares that the startup token fetch happened.
            Mock Get-PendingDeployment  { [PSCustomObject]@{ id = 1 } }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}
        }

        It 'acquires a token on startup with the correct credentials' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-GitHubAppToken -Times 1 -ParameterFilter {
                $AppId          -eq 1            -and
                $InstallationId -eq 10           -and
                $PrivateKeyPath -eq 'C:\test.pem'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'deployment found on first poll' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Get-GitHubAppToken     { $Script:FreshToken }
            Mock Get-PendingDeployment  { [PSCustomObject]@{ id = 42 } }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}
        }

        It 'posts in_progress before running the lifecycle test' {
            $Script:_statusOrder = [System.Collections.Generic.List[string]]::new()
            Mock Set-DeploymentStatus   { $Script:_statusOrder.Add($State) }
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_statusOrder[0] | Should -Be 'in_progress'
        }

        It 'posts in_progress before invoking the lifecycle test, not after' {
            # The status order test above only compares status calls to each other.
            # This test captures both Set-DeploymentStatus and Invoke-RunnerLifecycleTest
            # in a single timeline to verify the cross-function ordering constraint.
            $Script:_callOrder = [System.Collections.Generic.List[string]]::new()
            Mock Set-DeploymentStatus       { $Script:_callOrder.Add("status:$State") }
            Mock Invoke-RunnerLifecycleTest { $Script:_callOrder.Add('lifecycle') }

            Invoke-E2EAgentLoop @Script:BaseParams

            $inProgressIdx = $Script:_callOrder.IndexOf('status:in_progress')
            $lifecycleIdx  = $Script:_callOrder.IndexOf('lifecycle')
            $inProgressIdx | Should -BeLessThan $lifecycleIdx
        }

        It 'calls the lifecycle test with app credentials, repo paths, and VM config' {
            $Script:_config = $null
            Mock Invoke-RunnerLifecycleTest { $Script:_config = $Config }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_config.AppId                   | Should -Be 1
            $Script:_config.RunnersInstallationId   | Should -Be 20
            $Script:_config.PrivateKeyPath          | Should -Be 'C:\test.pem'
            $Script:_config.ProvisionerPath         | Should -Be 'C:\test\provisioner'
            $Script:_config.TestVm.ipAddress        | Should -Be '192.168.100.200'
        }

        It 'posts success after the lifecycle test passes' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 42 -and $State -eq 'success'
            }
        }

        It 'posts success after the lifecycle test completes, not before' {
            # Complements the in_progress ordering test: success must follow the
            # lifecycle test. Posting success before Invoke-RunnerLifecycleTest would
            # mean GitHub shows the deployment as succeeded before we know the outcome.
            $Script:_callOrder2 = [System.Collections.Generic.List[string]]::new()
            Mock Set-DeploymentStatus       { $Script:_callOrder2.Add("status:$State") }
            Mock Invoke-RunnerLifecycleTest { $Script:_callOrder2.Add('lifecycle') }

            Invoke-E2EAgentLoop @Script:BaseParams

            $lifecycleIdx = $Script:_callOrder2.IndexOf('lifecycle')
            $successIdx   = $Script:_callOrder2.IndexOf('status:success')
            $lifecycleIdx | Should -BeLessThan $successIdx
        }

        It 'uses the deployment id in all status calls' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter { $DeploymentId -eq 42 }
        }

        It 'posts deployment status to the correct owner and repo' {
            # A bug that hard-codes the wrong owner or repo would post status
            # to a different repository; the deployment-id checks alone cannot
            # catch this because the mock accepts any parameters.
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $Owner -eq 'org' -and $Repo -eq 'repo'
            }
        }

        It 'calls Get-PendingDeployment with the correct owner, repo, environment, and token' {
            # A bug that hard-codes any of these values would not be caught by
            # the invocation-count checks in other tests.
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-PendingDeployment -ParameterFilter {
                $Token       -eq 'tok'              -and
                $Owner       -eq 'org'              -and
                $Repo        -eq 'repo'             -and
                $Environment -eq 'e2e-workstation'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'deployment found after several null polls' {
    # ------------------------------------------------------------------

        BeforeEach {
            $script:_pollCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_pollCount++
                if ($script:_pollCount -ge 3) { return [PSCustomObject]@{ id = 7 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {}
        }

        It 'calls Get-PendingDeployment until a deployment is found' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-PendingDeployment -Times 3
        }

        It 'posts success on the deployment that was eventually found' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 7 -and $State -eq 'success'
            }
        }
    }

    # ------------------------------------------------------------------
    Context 'lifecycle test failure' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment { [PSCustomObject]@{ id = 5 } }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest { throw 'runner service failed to start' }
        }

        It 'posts failure status when the lifecycle test throws' {
            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Throw

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 5 -and $State -eq 'failure'
            }
        }

        It 'includes the exception message in the failure description' {
            $Script:_desc = $null
            Mock Set-DeploymentStatus { if ($State -eq 'failure') { $Script:_desc = $Description } }

            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Throw

            $Script:_desc | Should -Be 'runner service failed to start'
        }

        It 'rethrows the exception after posting failure' {
            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Throw 'runner service failed to start'
        }

        It 'does not post success when the lifecycle test throws' {
            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Throw

            Should -Invoke Set-DeploymentStatus -Times 0 -ParameterFilter { $State -eq 'success' }
        }
    }

    # ------------------------------------------------------------------
    Context 'timeout' {
    # ------------------------------------------------------------------

        BeforeEach {
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment { $null }
            Mock Set-DeploymentStatus {}
        }

        It 'exits without error when the deadline is already past' {
            $params = $Script:BaseParams.Clone()
            $params['Deadline'] = [DateTime]::UtcNow.AddMinutes(-1)

            { Invoke-E2EAgentLoop @params } | Should -Not -Throw
        }

        It 'does not post any deployment status when no deployment was found before timeout' {
            $params = $Script:BaseParams.Clone()
            $params['Deadline'] = [DateTime]::UtcNow.AddMinutes(-1)

            Invoke-E2EAgentLoop @params

            Should -Invoke Set-DeploymentStatus -Times 0
        }

        It 'does not poll for deployments when the deadline is already past' {
            # Verifies the while guard is respected - a bug that called
            # Get-PendingDeployment unconditionally before the loop would be missed
            # by the Set-DeploymentStatus check alone.
            $params = $Script:BaseParams.Clone()
            $params['Deadline'] = [DateTime]::UtcNow.AddMinutes(-1)

            Invoke-E2EAgentLoop @params

            Should -Invoke Get-PendingDeployment -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'token refresh' {
    # ------------------------------------------------------------------

        It 'refreshes the token when ExpiresAt is within 5 minutes' {
            $expiringToken = [PSCustomObject]@{
                Token     = 'expiring_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')
            }
            $refreshedToken = [PSCustomObject]@{
                Token     = 'refreshed_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
            }

            $script:_tokenCallCount = 0
            Mock Get-GitHubAppToken {
                $script:_tokenCallCount++
                if ($script:_tokenCallCount -eq 1) { return $expiringToken }
                return $refreshedToken
            }
            Mock Get-PendingDeployment  { [PSCustomObject]@{ id = 1 } }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # Called twice: once at startup, once for the near-expiry refresh.
            Should -Invoke Get-GitHubAppToken -Times 2
        }

        It 'refreshes using the E2E installation ID, not the runners installation ID' {
            # The refresh must re-authenticate against the E2E installation
            # (deployments:write) not the GitHubRunners installation (actions:write).
            # Mixing them up returns a token with the wrong permission scope.
            $expiringToken = [PSCustomObject]@{
                Token     = 'expiring_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')
            }

            $script:_installationIds = [System.Collections.Generic.List[int]]::new()
            Mock Get-GitHubAppToken {
                $script:_installationIds.Add($InstallationId)
                [PSCustomObject]@{
                    Token     = 'tok'
                    ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
                }
            }
            # Override: first call returns expiring token to trigger a refresh
            $script:_tokenCallCount2 = 0
            Mock Get-GitHubAppToken {
                $script:_tokenCallCount2++
                $script:_installationIds.Add($InstallationId)
                if ($script:_tokenCallCount2 -eq 1) { return $expiringToken }
                return [PSCustomObject]@{ Token = 'tok'; ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o') }
            }
            Mock Get-PendingDeployment  { [PSCustomObject]@{ id = 1 } }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # Both the startup and the refresh call must use E2EInstallationId (10).
            $script:_installationIds | ForEach-Object { $_ | Should -Be 10 }
        }

        It 'uses the refreshed token for subsequent API calls' {
            # Verifies that the re-assignment $tokenResult = Get-GitHubAppToken ...
            # actually takes effect. A bug that calls Get-GitHubAppToken without
            # capturing the result would keep passing the expiring token.
            $expiringToken = [PSCustomObject]@{
                Token     = 'expiring_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')
            }
            $refreshedToken = [PSCustomObject]@{
                Token     = 'refreshed_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
            }

            $script:_callCount = 0
            Mock Get-GitHubAppToken {
                $script:_callCount++
                if ($script:_callCount -eq 1) { return $expiringToken }
                return $refreshedToken
            }
            Mock Get-PendingDeployment  { [PSCustomObject]@{ id = 1 } }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-PendingDeployment -ParameterFilter { $Token -eq 'refreshed_tok' }
        }

        It 'does not refresh the token when ExpiresAt is more than 5 minutes away' {
            Mock Get-GitHubAppToken     { $Script:FreshToken }  # ExpiresAt = +55min
            Mock Get-PendingDeployment  { [PSCustomObject]@{ id = 1 } }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # Called only once at startup - no refresh needed.
            Should -Invoke Get-GitHubAppToken -Times 1
        }
    }
}
