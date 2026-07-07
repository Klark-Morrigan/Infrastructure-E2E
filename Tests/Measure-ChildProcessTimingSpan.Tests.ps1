BeforeAll {
    # ----------------------------------------------------------------------
    # Shared timing doubles (New-/Measure-TimingSpan, the bare Import-Timing
    # SpanTree each test Mocks, and New-ImportedTreeDouble). The Common.Power
    # Shell timing surface is not installed in this unit runspace; the fixture
    # header documents the contract they reproduce.
    # ----------------------------------------------------------------------
    . "$PSScriptRoot\support\TimingSpanTestDoubles.ps1"

    . "$PSScriptRoot\..\agent\e2e\timing\Measure-ChildProcessTimingSpan.ps1"
}

Describe 'Measure-ChildProcessTimingSpan' {

    BeforeEach {
        # Ensure no ambient opt-in leaks in from a previous test or the host
        # session; the helper's restore logic is asserted separately. WSLENV is
        # cleared too so the /p forwarding assertions start from a known state.
        Remove-Item Env:TIMING_TREE_OUTPUT_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
    }

    It 'grafts the child export spans under the correct part node' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { New-ImportedTreeDouble -ChildNames @('boot VM', 'install JDK') }

        Measure-ChildProcessTimingSpan -Tree $tree -Name 'provisioning Phase 1' -Action {
            # Stand in for the child export: write a file at the opt-in path so
            # the helper's Test-Path guard passes and Import runs.
            Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value '{}'
        }

        # The imported children land under the part span, not the root.
        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'provisioning Phase 1' }
        @($part.Children | ForEach-Object { $_.Name }) | Should -Be @('boot VM', 'install JDK')
        $tree.Root.Children.Count | Should -Be 1
    }

    It 'imports from the per-invocation temp path the child was told to write' {
        $tree = New-TimingSpanTree -RootName 'run'
        $script:seenOptIn = $null
        Mock Import-TimingSpanTree {
            param([string] $Path)
            $script:importedPath = $Path
            New-ImportedTreeDouble -ChildNames @('x')
        }

        Measure-ChildProcessTimingSpan -Tree $tree -Name 'p' -Action {
            $script:seenOptIn = $env:TIMING_TREE_OUTPUT_PATH
            Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value '{}'
        }

        # The path handed to the child is exactly the path Import reads back.
        $script:importedPath | Should -Be $script:seenOptIn
    }

    It 'leaves the part childless and never imports when the child wrote no file' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { }

        # Action shells out but the child (no emitter yet) writes nothing.
        Measure-ChildProcessTimingSpan -Tree $tree -Name 'reconcile users' -Action { }

        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'reconcile users' }
        $part.Children.Count | Should -Be 0
        Should -Invoke Import-TimingSpanTree -Times 0
    }

    It 'deletes the child temp file after grafting' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { New-ImportedTreeDouble -ChildNames @('c') }
        $script:tempPath = $null

        Measure-ChildProcessTimingSpan -Tree $tree -Name 'p' -Action {
            $script:tempPath = $env:TIMING_TREE_OUTPUT_PATH
            Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value '{}'
        }

        Test-Path -LiteralPath $script:tempPath | Should -BeFalse
    }

    It 'restores the prior TIMING_TREE_OUTPUT_PATH after the part returns' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { }
        $env:TIMING_TREE_OUTPUT_PATH = 'prior-sentinel'

        try {
            Measure-ChildProcessTimingSpan -Tree $tree -Name 'p' -Action {
                # The helper overrode the opt-in with a fresh temp path for the
                # duration of the call; the child sees that, not the sentinel.
                $env:TIMING_TREE_OUTPUT_PATH | Should -Not -Be 'prior-sentinel'
            }
            $env:TIMING_TREE_OUTPUT_PATH | Should -Be 'prior-sentinel'
        }
        finally {
            Remove-Item Env:TIMING_TREE_OUTPUT_PATH -ErrorAction SilentlyContinue
        }
    }

    It 'still grafts the partial export and cleans up when the action throws' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { New-ImportedTreeDouble -ChildNames @('partial') }
        $script:tempPath = $null

        {
            Measure-ChildProcessTimingSpan -Tree $tree -Name 'p' -Action {
                $script:tempPath = $env:TIMING_TREE_OUTPUT_PATH
                # Child exported before crashing.
                Set-Content -LiteralPath $env:TIMING_TREE_OUTPUT_PATH -Value '{}'
                throw 'child boom'
            }
        } | Should -Throw '*child boom*'

        # The failing part is marked and still carries the child's partial depth.
        $part = $tree.Root.Children | Where-Object { $_.Name -eq 'p' }
        $part.Status | Should -Be 'Failed'
        @($part.Children | ForEach-Object { $_.Name }) | Should -Be @('partial')
        # Temp file removed on the throw path too.
        Test-Path -LiteralPath $script:tempPath | Should -BeFalse
    }

    # ----------------------------------------------------------------------
    # E3: bridge the opt-in across the WSL boundary so bash children under
    # `wsl -- ...` can see and path-translate TIMING_TREE_OUTPUT_PATH.
    # ----------------------------------------------------------------------

    It 'forwards TIMING_TREE_OUTPUT_PATH/p in WSLENV during the wrapped action' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { }
        $script:seenWslEnv = $null

        Measure-ChildProcessTimingSpan -Tree $tree -Name 'p' -Action {
            $script:seenWslEnv = $env:WSLENV
        }

        # The /p flag path-translates the Windows temp path to /mnt/c/... for
        # the bash child; without the entry the var is invisible inside WSL.
        $script:seenWslEnv | Should -Match 'TIMING_TREE_OUTPUT_PATH/p'
    }

    It 'removes WSLENV afterwards when it did not exist before' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { }

        Measure-ChildProcessTimingSpan -Tree $tree -Name 'p' -Action { }

        # BeforeEach cleared WSLENV, so a $null prior means it is removed, not
        # left as an empty string.
        Test-Path Env:WSLENV | Should -BeFalse
    }

    It 'restores a pre-existing WSLENV to its prior value afterwards' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { }
        $env:WSLENV = 'SECRET_SUFFIX/u'

        try {
            Measure-ChildProcessTimingSpan -Tree $tree -Name 'p' -Action {
                # The forwarding is appended to, not clobbering, the prior value.
                $env:WSLENV | Should -Match 'SECRET_SUFFIX/u'
                $env:WSLENV | Should -Match 'TIMING_TREE_OUTPUT_PATH/p'
            }
            $env:WSLENV | Should -Be 'SECRET_SUFFIX/u'
        }
        finally {
            Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
        }
    }

    It 'does not duplicate the WSLENV entry when a wrap is nested' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { }
        $script:innerWslEnv = $null

        Measure-ChildProcessTimingSpan -Tree $tree -Name 'outer' -Action {
            # A nested part (e.g. E2's 'provision toolchains' inside
            # 'provisioning Phase 1') must not stack a second entry.
            Measure-ChildProcessTimingSpan -Tree $tree -Name 'inner' -Action {
                $script:innerWslEnv = $env:WSLENV
            }
        }

        $entryCount = ([regex]::Matches($script:innerWslEnv, 'TIMING_TREE_OUTPUT_PATH/p')).Count
        $entryCount | Should -Be 1
    }

    It 'restores WSLENV on the throw path too' {
        $tree = New-TimingSpanTree -RootName 'run'
        Mock Import-TimingSpanTree { }
        $env:WSLENV = 'SECRET_SUFFIX/u'

        try {
            {
                Measure-ChildProcessTimingSpan -Tree $tree -Name 'p' -Action {
                    throw 'child boom'
                }
            } | Should -Throw '*child boom*'

            $env:WSLENV | Should -Be 'SECRET_SUFFIX/u'
        }
        finally {
            Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
        }
    }
}
