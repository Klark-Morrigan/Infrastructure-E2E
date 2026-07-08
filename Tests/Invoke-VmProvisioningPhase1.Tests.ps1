BeforeAll {
    # ----------------------------------------------------------------------
    # Shared timing doubles (New-/Measure-TimingSpan, the bare Import-Timing
    # SpanTree each test Mocks, and New-ImportedTreeDouble). The Common.Power
    # Shell timing surface is not installed in this unit runspace; the fixture
    # header documents the contract they reproduce. The REAL Measure-Child
    # ProcessTimingSpan (both the part span this test drives and the nested
    # 'provision toolchains' span the phase adds) comes from dot-sourcing the
    # provisioning chain below.
    # ----------------------------------------------------------------------
    . "$PSScriptRoot\support\TimingSpanTestDoubles.ps1"

    # The chain's only top-level side effect is an Invoke-ModuleInstall for
    # Posh-SSH at dot-source time. Stub it so loading the file under test does
    # not reach the network (same as Invoke-RunnerLifecycleTest.Tests).
    function Invoke-ModuleInstall { param($ModuleName) }

    # E2ETestSecretSuffix normally comes from Initialize-E2EEnvironment, which
    # is not in the dot-sourced chain; the phase reads it via Invoke-Provisioner
    # ForPhase (Mocked here, but the constant is referenced at parse scope).
    $script:E2ETestSecretSuffix = 'TEST'

    # Dot-source the provisioning chain: this pulls in the REAL phase
    # orchestration (Invoke-VmProvisioningPhase1), the shared helpers it calls
    # (Get-ToolchainPhaseContext, New-VmEntryBase, ...), the $script:* scenario
    # constants, and - since E2 - Measure-ChildProcessTimingSpan. Only the leaf
    # shell-outs are Mocked per-test.
    . "$PSScriptRoot\..\agent\e2e\vm-provisioning\Invoke-VmProvisioningTest.ps1"
}

Describe 'Invoke-VmProvisioningPhase1 toolchains child span' {

    BeforeEach {
        Remove-Item Env:TIMING_TREE_OUTPUT_PATH -ErrorAction SilentlyContinue

        Mock Write-Host {}

        # Config + VM def carrying only the fields the (mostly Mocked) phase
        # reads before its early ansible-flow return: New-VmEntryBase reads
        # TestVm.ubuntuVersion / vmConfigPath / vhdPath and the VM identity;
        # Get-ToolchainPhaseContext reads ToolchainsFlow / WslDistro.
        $script:config = [pscustomobject]@{
            ProvisionerPath = 'C:\fake\Vm-Provisioner'
            ToolchainsFlow  = 'ansible'
            WslDistro       = 'Ubuntu-24.04'
            TestVm          = [pscustomobject]@{
                ubuntuVersion = '24.04'
                vmConfigPath  = 'C:\fake\vmconfig'
                vhdPath       = 'C:\fake\vhd'
            }
        }
        $script:vm1Def = [pscustomobject]@{
            vmName    = 'e2e-test-1'
            ipAddress = '10.99.0.10'
            password  = 'pw'
            _RouterVm = [pscustomobject]@{}
        }

        # Leaf boundaries the phase crosses, all Mocked so no real work runs.
        # The two exporting children write a distinguishable marker to whichever
        # opt-in path is active when they run, so the Import mock can hand back
        # the right subtree for each.
        Mock Write-VmProvisionerConfig { }
        Mock Resolve-RouterIpFromKvp   { }
        Mock Invoke-WithVmSshClient    { }   # skips all SSH-side assertions
        Mock Invoke-ProvisionerForPhase {
            Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value 'provision.ps1'
        }
        Mock Set-VmToolchainsForTest {
            Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value 'toolchains'
        }

        # Route each import to the subtree matching the marker the child wrote,
        # so provision.ps1's export and the toolchains export are told apart.
        Mock Import-TimingSpanTree {
            param([string] $Path)
            switch ((Get-Content -LiteralPath $Path -Raw).Trim()) {
                'provision.ps1' { New-ImportedTreeDouble -ChildNames @('boot VM', 'install JDK') }
                'toolchains'    { New-ImportedTreeDouble -ChildNames @('run jdk role', 'run dotnet role') }
                default         { $null }
            }
        }
    }

    It 'grafts the provision and toolchains exports under their own child spans' {
        # Drive the phase exactly as Invoke-VmUsersSetup does: inside the
        # 'provisioning Phase 1' part span, threading the same tree in.
        $tree = New-TimingSpanTree -RootName 'run'
        Measure-ChildProcessTimingSpan -Tree $tree -Name 'provisioning Phase 1' -Action {
            Invoke-VmProvisioningPhase1 -Config $script:config -Vm1Def $script:vm1Def -Tree $tree
        }

        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'provisioning Phase 1' }

        # Each shell-out nests under its OWN child span so their exports land on
        # separate output paths - no shared-path clobber. Ansible flow: real
        # provision + toolchains, and no no-op rerun (the phase returns before
        # it).
        $partChildNames = @($part.Children | ForEach-Object { $_.Name })
        $partChildNames | Should -Contain 'provision'
        $partChildNames | Should -Contain 'provision toolchains'

        $provision = $part.Children | Where-Object { $_.Name -eq 'provision' }
        @($provision.Children | ForEach-Object { $_.Name }) |
            Should -Be @('boot VM', 'install JDK')

        $toolchains = $part.Children | Where-Object { $_.Name -eq 'provision toolchains' }
        @($toolchains.Children | ForEach-Object { $_.Name }) |
            Should -Be @('run jdk role', 'run dotnet role')
    }

    It 'nests provision, an empty toolchains span, and the no-op rerun under custom-powershell' {
        # custom-powershell: the dispatcher shells out to nothing, so the
        # toolchains span renders empty; the phase then runs the no-op
        # idempotency rerun as its OWN span, kept separate from the real
        # provision so the rerun's tree never clobbers it (the bug this split
        # fixes).
        $script:config.ToolchainsFlow = 'custom-powershell'
        Mock Set-VmToolchainsForTest { }

        $tree = New-TimingSpanTree -RootName 'run'
        Measure-ChildProcessTimingSpan -Tree $tree -Name 'provisioning Phase 1' -Action {
            Invoke-VmProvisioningPhase1 -Config $script:config -Vm1Def $script:vm1Def -Tree $tree
        }

        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'provisioning Phase 1' }

        # Real provision, empty toolchains, and the separately-spanned rerun.
        @($part.Children | ForEach-Object { $_.Name }) |
            Should -Be @('provision', 'provision toolchains', 'provision (no-op rerun)')

        $toolchains = $part.Children | Where-Object { $_.Name -eq 'provision toolchains' }
        $toolchains.Children.Count | Should -Be 0

        # Both the real provision and the rerun keep their own grafted tree -
        # proof neither overwrote the other.
        $provision = $part.Children | Where-Object { $_.Name -eq 'provision' }
        @($provision.Children | ForEach-Object { $_.Name }) |
            Should -Be @('boot VM', 'install JDK')

        $rerun = $part.Children | Where-Object { $_.Name -eq 'provision (no-op rerun)' }
        @($rerun.Children | ForEach-Object { $_.Name }) |
            Should -Be @('boot VM', 'install JDK')
    }

    It 'marks provision toolchains Failed but still keeps the provision span when the driver throws' {
        # Failure path: the toolchains driver throws AFTER the provision span has
        # already exported. The nested wrap must restore the outer path so the
        # real provision's grafted tree survives - proof the restore fires on the
        # throw path too.
        Mock Set-VmToolchainsForTest { throw 'toolchains boom' }

        $tree = New-TimingSpanTree -RootName 'run'
        {
            Measure-ChildProcessTimingSpan -Tree $tree -Name 'provisioning Phase 1' -Action {
                Invoke-VmProvisioningPhase1 -Config $script:config -Vm1Def $script:vm1Def -Tree $tree
            }
        } | Should -Throw '*toolchains boom*'

        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'provisioning Phase 1' }
        $part.Status | Should -Be 'Failed'

        $toolchains = $part.Children | Where-Object { $_.Name -eq 'provision toolchains' }
        $toolchains.Status | Should -Be 'Failed'

        # The real provision span completed before the throw and kept its tree.
        $provision = $part.Children | Where-Object { $_.Name -eq 'provision' }
        $provision.Status | Should -Be 'OK'
        @($provision.Children | ForEach-Object { $_.Name }) |
            Should -Be @('boot VM', 'install JDK')
    }
}
