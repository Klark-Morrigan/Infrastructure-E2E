BeforeAll {
    # ----------------------------------------------------------------------
    # Timing surface (Common.PowerShell) is not installed in this unit runspace,
    # so New-/Measure-TimingSpan are stubbed. The doubles are shared with the
    # other timing suites via one fixture (see the file's header for the
    # contract they reproduce); this suite only needs the tree + span doubles.
    # ----------------------------------------------------------------------
    . "$PSScriptRoot\support\TimingSpanTestDoubles.ps1"

    # ----------------------------------------------------------------------
    # Agent-shared helpers + module cmdlets the runner-lifecycle chain calls
    # but does not itself define. Stubbed at file scope so Pester's Mock can
    # attach to them per-test. New-VmSshClientWithJump returns a disposable
    # session shape; Invoke-SshClientCommand / Invoke-GitHubApi are re-Mocked
    # per-test with the responses each call site needs.
    # ----------------------------------------------------------------------
    function Get-E2ESecretName { param([string] $BaseName) "$BaseName-TEST" }
    function Set-Secret        { param($Vault, $Name, $Secret) }
    function Remove-Secret     { param($Vault, $Name, $ErrorAction) }
    function Get-SecretInfo    { param($Vault, $Name, $ErrorAction) }
    function Get-GitHubAppToken {
        param($AppId, $InstallationId, $PrivateKeyPath, $Repositories, $Permissions)
    }
    function Invoke-GitHubApi        { param($Token, $Endpoint) }
    function New-VmSshClientWithJump { param($Vm) }
    function Invoke-SshClientCommand { param($SshClient, $Command, $ErrorAction) }

    # The chain's only top-level side effect is an Invoke-ModuleInstall for
    # Posh-SSH at dot-source time. Stub it to a no-op so loading the file
    # under test does not reach the network.
    function Invoke-ModuleInstall { param($ModuleName) }

    # Script-scoped constants the chain reads. The provisioning file sets
    # Vm1* on dot-source; E2ETestSecretSuffix normally comes from
    # Initialize-E2EEnvironment, which is not in the dot-sourced chain.
    $script:E2ETestSecretSuffix = 'TEST'

    # Dot-source the runner-lifecycle chain. This pulls in the real
    # orchestration functions (Setup, VmUsersSetup, the phases, teardown)
    # whose span-wrapping is the behaviour under test; only their leaf
    # shell-outs are Mocked per-test.
    . "$PSScriptRoot\..\agent\e2e\runner-lifecycle\Invoke-RunnerLifecycleTest.ps1"

    # A disposable SSH-session double: carries a Client and a no-op Dispose so
    # the connect/dispose pattern in the verify + DNS-wait blocks runs clean.
    function New-FakeSshSession {
        $session = [pscustomobject]@{ Client = [pscustomobject]@{} }
        $session | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        return $session
    }
}

Describe 'Invoke-RunnerLifecycleTest timing tree' {

    BeforeEach {
        # Minimal Config carrying only what the (mostly Mocked) call tree
        # reads: repo owner/paths for config-entry construction and the flow
        # selectors the dispatchers forward.
        $script:config = [PSCustomObject]@{
            Owner                  = 'Klark-Morrigan'
            RunnersPath            = 'C:\fake\GitHubRunners'
            UsersPath              = 'C:\fake\Vm-Users'
            ProvisionerPath        = 'C:\fake\Vm-Provisioner'
            RunnersFlow            = 'custom-powershell'
            UsersFlow              = 'custom-powershell'
            WslDistro              = $null
            AppId                  = '123'
            RunnersInstallationId  = '456'
            PrivateKeyPath         = 'C:\fake\key.pem'
            # Diagnostics root source: the outer finally resolves
            # <TestVm.vmConfigPath>/diagnostics to place the timing artifact.
            TestVm                 = [pscustomobject]@{ vmConfigPath = 'C:\fake\vmconfig' }
        }

        # Fake VM def the provisioning setup hands back; _SecondaryVm is read
        # by the phase-2/3 orchestration.
        $script:fakeVmDef = [pscustomobject]@{
            vmName       = 'e2e-test-1'
            ipAddress    = '10.99.0.10'
            _SecondaryVm = [pscustomobject]@{ vmName = 'e2e-test-2' }
        }

        # --- Leaf shell-outs / infra: all Mocked so no real work happens. ---
        Mock Invoke-VmProvisioningSetup   { $script:fakeVmDef }
        Mock Invoke-VmProvisioningPhase1  { }
        Mock Invoke-VmProvisioningPhase2  { }
        Mock Invoke-VmProvisioningPhase3  { }
        Mock Set-VmUsersForTest           { }
        Mock Set-VmRunnersForTest         { }
        Mock Assert-VmUsersStillIntact    { }
        Mock Assert-RunnerStillOnline     { }
        Mock Invoke-RunnerLifecycleTeardown { }
        # End-of-run emission is exercised by its own suite
        # (Publish-E2ETimingReport.Tests). Here it is a no-op so these tests
        # stay focused on the assembled tree shape; the finally still calls it
        # on every path, which the two assertions below guard.
        Mock Publish-E2ETimingReport      { }

        Mock Set-Secret        { }
        Mock Remove-Secret     { }
        Mock Get-SecretInfo    { $null }     # vault entries removed -> post-conditions pass
        Mock Get-GitHubAppToken { [pscustomobject]@{ Token = 'ghs_TESTTOKEN' } }
        Mock Start-Sleep       { }

        Mock New-VmSshClientWithJump { New-FakeSshSession }
        Mock Invoke-SshClientCommand {
            param($SshClient, $Command, $ErrorAction)
            # DNS-readiness probe in Invoke-VmUsersSetup.
            if ($Command -like '*getent hosts*') {
                return [pscustomobject]@{ Output = @('ok'); ExitStatus = 0 }
            }
            # Runner unit name lookup: a single matching unit line.
            if ($Command -like '*list-unit-files*') {
                return [pscustomobject]@{
                    Output     = @('actions.runner.owner-repo.e2e-runner.service enabled')
                    ExitStatus = 0
                }
            }
            # Service liveness.
            if ($Command -like '*is-active*') {
                return [pscustomobject]@{ Output = @('active'); ExitStatus = 0 }
            }
            return [pscustomobject]@{ Output = @(''); ExitStatus = 0 }
        }
        # Runner shows up online on the first poll.
        Mock Invoke-GitHubApi {
            [pscustomobject]@{
                runners = @([pscustomobject]@{ name = 'e2e-runner'; status = 'online' })
            }
        }
    }

    It 'builds the expected phase and part tree on a full mocked run' {
        $tree = New-TimingSpanTree -RootName 'runner-lifecycle'

        Invoke-RunnerLifecycleTest -Config $script:config -Tree $tree

        # Top-level phases in orchestration order.
        $phaseNames = @($tree.Root.Children | ForEach-Object { $_.Name })
        $phaseNames | Should -Be @(
            'Setup',
            'Register runners',
            'Verify online',
            'Phase 2 + reassert',
            'Phase 3 + reassert',
            'Teardown'
        )

        # Setup fans out into the two shell-out parts (provision, reconcile).
        $setup     = $tree.Root.Children | Where-Object { $_.Name -eq 'Setup' }
        $partNames = @($setup.Children | ForEach-Object { $_.Name })
        $partNames | Should -Be @('provisioning Phase 1', 'reconcile users')

        # Every span completed OK on the success path.
        foreach ($phase in $tree.Root.Children) {
            $phase.Status | Should -Be 'OK'
        }
        foreach ($part in $setup.Children) {
            $part.Status | Should -Be 'OK'
        }

        # The report + rolling artifact fire once on the success path, with
        # the diagnostics root resolved from the run's vmConfigPath.
        Should -Invoke Publish-E2ETimingReport -Times 1 -Exactly -ParameterFilter {
            $Tree -eq $tree -and
            $DiagnosticsRoot -eq (Join-Path $script:config.TestVm.vmConfigPath 'diagnostics')
        }
    }

    It 'marks the failing span Failed and stops the tree at the failure' {
        # Registration blows up mid-run.
        Mock Set-VmRunnersForTest { throw 'register boom' }

        $tree = New-TimingSpanTree -RootName 'runner-lifecycle'

        { Invoke-RunnerLifecycleTest -Config $script:config -Tree $tree } |
            Should -Throw '*register boom*'

        $byName = @{}
        foreach ($child in $tree.Root.Children) { $byName[$child.Name] = $child }

        # Setup ran and passed before the failure.
        $byName['Setup'].Status          | Should -Be 'OK'
        # The failing phase is recorded and flagged.
        $byName['Register runners'].Status | Should -Be 'Failed'
        # Nothing past the failure ran.
        $byName.ContainsKey('Verify online')      | Should -BeFalse
        $byName.ContainsKey('Phase 2 + reassert') | Should -BeFalse
        # Teardown still fires (best-effort cleanup path) so the run always
        # contributes a Teardown span.
        $byName.ContainsKey('Teardown') | Should -BeTrue
        $byName['Teardown'].Status      | Should -Be 'OK'

        # The report + rolling artifact still fire on the failure path, so a
        # failed run shows where the time went up to the failure point.
        Should -Invoke Publish-E2ETimingReport -Times 1 -Exactly -ParameterFilter {
            $Tree -eq $tree
        }
    }

    It 'nests the Setup parts under Setup, not under the root' {
        # Guards the context threading: the provision / reconcile spans must
        # attach under the current 'Setup' node (threaded via -Tree through
        # Invoke-RunnerLifecycleSetup -> Invoke-VmUsersSetup), never as
        # top-level siblings of the phases.
        $tree = New-TimingSpanTree -RootName 'runner-lifecycle'

        Invoke-RunnerLifecycleTest -Config $script:config -Tree $tree

        $rootNames = @($tree.Root.Children | ForEach-Object { $_.Name })
        $rootNames | Should -Not -Contain 'provisioning Phase 1'
        $rootNames | Should -Not -Contain 'reconcile users'
    }
}
