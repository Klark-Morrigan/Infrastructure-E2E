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
        # Shared parameters. PollIntervalSeconds=0 removes Start-Sleep latency.
        # Deadline is intentionally absent here - set fresh each test by the
        # BeforeEach below so the loop does not spin for hours once the
        # deployment mock starts returning $null.
        # AnsiblePath points at a real directory because the loop now
        # validates the path exists at startup when UsersFlow=ansible
        # (the default). Tests that exercise the validation override it.
        $Script:AnsiblePath = $TestDrive

        $Script:BaseParams = @{
            AppId                 = 1
            E2EInstallationId     = 10
            RunnersInstallationId = 20
            PrivateKeyPath        = 'C:\test.pem'
            ProvisionerPath       = 'C:\test\provisioner'
            UsersPath             = 'C:\test\users'
            UsersFlow             = 'ansible'
            AnsiblePath           = $Script:AnsiblePath
            RunnersPath           = 'C:\test\runners'
            HostTarballCachePath  = 'C:\test\tarball-cache'
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
        }

        # Token with expiry safely in the future - used wherever the refresh
        # path is NOT under test.
        $Script:FreshToken = [PSCustomObject]@{
            Token     = 'tok'
            ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o')
        }
    }

    BeforeEach {
        # Refresh the deadline for every test. Without this, after a deployment
        # is processed and the mock starts returning $null, the loop would spin
        # until the far-future deadline set in BeforeAll - effectively hanging.
        # 500ms is long enough for one synchronous processing cycle and short
        # enough that null-spinning does not meaningfully slow the test suite.
        $Script:BaseParams['Deadline'] = [DateTime]::UtcNow.AddMilliseconds(500)
    }

    # ------------------------------------------------------------------
    Context 'token acquisition' {
    # ------------------------------------------------------------------

        BeforeEach {
            $script:_taCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            # Return a deployment on the first poll so the token-acquisition
            # assertion is reachable, then null so the loop exits at deadline.
            Mock Get-PendingDeployment {
                $script:_taCount++
                if ($script:_taCount -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
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
            $script:_dfpCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            # Return the deployment once, then null so the loop exits at deadline.
            Mock Get-PendingDeployment {
                $script:_dfpCount++
                if ($script:_dfpCount -eq 1) { return [PSCustomObject]@{ id = 42 } }
                return $null
            }
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
            $Script:_config.UsersPath               | Should -Be 'C:\test\users'
            $Script:_config.UsersFlow               | Should -Be 'ansible'
            $Script:_config.AnsiblePath             | Should -Be $Script:AnsiblePath
            $Script:_config.RunnersPath             | Should -Be 'C:\test\runners'
            $Script:_config.HostTarballCachePath    | Should -Be 'C:\test\tarball-cache'
            $Script:_config.Owner            | Should -Be 'org'
            $Script:_config.TestVm.ipAddress | Should -Be '192.168.100.200'
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
                # Return the deployment exactly on call 3, null for all others.
                if ($script:_pollCount -eq 3) { return [PSCustomObject]@{ id = 7 } }
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
            $script:_lfCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_lfCount++
                if ($script:_lfCount -eq 1) { return [PSCustomObject]@{ id = 5 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest { throw 'runner service failed to start' }
        }

        It 'posts failure status when the lifecycle test throws' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 5 -and $State -eq 'failure'
            }
        }

        It 'includes the exception message in the failure description' {
            $Script:_desc = $null
            Mock Set-DeploymentStatus { if ($State -eq 'failure') { $Script:_desc = $Description } }

            Invoke-E2EAgentLoop @Script:BaseParams

            $Script:_desc | Should -Be 'runner service failed to start'
        }

        It 'does not post success when the lifecycle test throws' {
            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -Times 0 -ParameterFilter { $State -eq 'success' }
        }

        It 'does not throw and continues polling after a lifecycle test failure' {
            # The operator sees the failure via the GitHub deployment status.
            # The agent must not crash - it continues to drain any queued
            # deployments and picks up new ones after the failure.
            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'queue drain - multiple pending deployments' {
    # ------------------------------------------------------------------

        It 'processes a second deployment after the first succeeds' {
            $script:_qdCount = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_qdCount++
                if ($script:_qdCount -eq 1) { return [PSCustomObject]@{ id = 10 } }
                if ($script:_qdCount -eq 2) { return [PSCustomObject]@{ id = 11 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 10 -and $State -eq 'success'
            }
            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 11 -and $State -eq 'success'
            }
        }

        It 'processes a second deployment after the first fails' {
            $script:_qdCount2 = 0
            $script:_qdLifecycle = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_qdCount2++
                if ($script:_qdCount2 -eq 1) { return [PSCustomObject]@{ id = 20 } }
                if ($script:_qdCount2 -eq 2) { return [PSCustomObject]@{ id = 21 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {
                $script:_qdLifecycle++
                if ($script:_qdLifecycle -eq 1) { throw 'first test failed' }
            }

            { Invoke-E2EAgentLoop @Script:BaseParams } | Should -Not -Throw

            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 20 -and $State -eq 'failure'
            }
            Should -Invoke Set-DeploymentStatus -ParameterFilter {
                $DeploymentId -eq 21 -and $State -eq 'success'
            }
        }

        It 'continues polling after processing a deployment instead of exiting' {
            $script:_qdCount3 = 0
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment {
                $script:_qdCount3++
                if ($script:_qdCount3 -eq 1) { return [PSCustomObject]@{ id = 30 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # More than one call means the loop re-polled after the deployment
            # was processed rather than returning immediately.
            $script:_qdCount3 | Should -BeGreaterThan 1
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
    Context 'UsersFlow / AnsiblePath plumbing' {
    # ------------------------------------------------------------------

        It 'defaults UsersFlow to ansible when callers do not pass one' {
            # Once feature 02 ships, the Ansible flow is the primary path.
            # A regression that re-flips the default to custom-powershell
            # would silently route every test session through the older
            # flow - this assertion fails such a regression at unit time.
            $Script:_def_config = $null
            Mock Get-GitHubAppToken { $Script:FreshToken }
            $script:_defCount = 0
            Mock Get-PendingDeployment {
                $script:_defCount++
                if ($script:_defCount -eq 1) { return [PSCustomObject]@{ id = 99 } }
                return $null
            }
            Mock Set-DeploymentStatus {}
            Mock Invoke-RunnerLifecycleTest { $Script:_def_config = $Config }

            # Clone BaseParams and strip UsersFlow so the default kicks in.
            $params = $Script:BaseParams.Clone()
            $params.Remove('UsersFlow')

            Invoke-E2EAgentLoop @params

            $Script:_def_config.UsersFlow | Should -Be 'ansible'
        }

        It "throws at startup when UsersFlow='ansible' and AnsiblePath is missing" {
            # No mocks reachable: the validation runs before the polling
            # loop starts, so no token / deployment calls happen.
            $params = $Script:BaseParams.Clone()
            $params.Remove('AnsiblePath')

            { Invoke-E2EAgentLoop @params } | Should -Throw '*requires -AnsiblePath*'
        }

        It "throws at startup when AnsiblePath does not exist on disk" {
            $params = $Script:BaseParams.Clone()
            $params['AnsiblePath'] = 'C:\definitely\not\a\real\path-XYZ-12345'

            { Invoke-E2EAgentLoop @params } |
                Should -Throw '*does not exist*'
        }

        It "does not require AnsiblePath when UsersFlow='custom-powershell'" {
            Mock Get-GitHubAppToken { $Script:FreshToken }
            Mock Get-PendingDeployment { $null }
            Mock Set-DeploymentStatus {}

            $params = $Script:BaseParams.Clone()
            $params['UsersFlow'] = 'custom-powershell'
            $params.Remove('AnsiblePath')

            { Invoke-E2EAgentLoop @params } | Should -Not -Throw
        }

        It "rejects unknown UsersFlow values at parameter binding time" {
            $params = $Script:BaseParams.Clone()
            $params['UsersFlow'] = 'legacy'

            { Invoke-E2EAgentLoop @params } | Should -Throw '*ValidateSet*'
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
            $script:_trCount = 0
            Mock Get-PendingDeployment {
                $script:_trCount++
                if ($script:_trCount -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # Called twice: once at startup, once for the near-expiry refresh.
            Should -Invoke Get-GitHubAppToken -Times 2
        }

        It 'refreshes using the E2E installation ID' {
            # The refresh must re-authenticate against the E2E installation
            # (deployments:write). Using the wrong installation ID would return
            # a token without deployments:write and break status posting.
            $expiringToken = [PSCustomObject]@{
                Token     = 'expiring_tok'
                ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(3).ToString('o')
            }

            $script:_installationIds = [System.Collections.Generic.List[int]]::new()
            $script:_tokenCallCount2 = 0
            Mock Get-GitHubAppToken {
                $script:_tokenCallCount2++
                $script:_installationIds.Add($InstallationId)
                if ($script:_tokenCallCount2 -eq 1) { return $expiringToken }
                return [PSCustomObject]@{ Token = 'tok'; ExpiresAt = [DateTimeOffset]::UtcNow.AddMinutes(55).ToString('o') }
            }
            $script:_trCount2 = 0
            Mock Get-PendingDeployment {
                $script:_trCount2++
                if ($script:_trCount2 -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
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
            $script:_trCount3 = 0
            Mock Get-PendingDeployment {
                $script:_trCount3++
                if ($script:_trCount3 -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            Should -Invoke Get-PendingDeployment -ParameterFilter { $Token -eq 'refreshed_tok' }
        }

        It 'does not refresh the token when ExpiresAt is more than 5 minutes away' {
            $script:_trCount4 = 0
            Mock Get-GitHubAppToken     { $Script:FreshToken }  # ExpiresAt = +55min
            Mock Get-PendingDeployment  {
                $script:_trCount4++
                if ($script:_trCount4 -eq 1) { return [PSCustomObject]@{ id = 1 } }
                return $null
            }
            Mock Set-DeploymentStatus   {}
            Mock Invoke-RunnerLifecycleTest {}

            Invoke-E2EAgentLoop @Script:BaseParams

            # Called only once at startup - no refresh needed.
            Should -Invoke Get-GitHubAppToken -Times 1
        }
    }
}
