BeforeAll {
    # ----------------------------------------------------------------------
    # Timing doubles. The Common.PowerShell timing surface is not installed in
    # this unit runspace, so New-/Measure-TimingSpan and Import-TimingSpanTree
    # are stubbed. The New-/Measure- doubles reproduce the find-or-create by
    # name-within-parent + push/pop nesting the helper relies on (same fixture
    # as Invoke-RunnerLifecycleTest.Tests); Import-TimingSpanTree is stubbed as
    # a bare declaration so each test Mocks the child export it needs. Real
    # timing semantics are covered by Common.PowerShell.Tests.
    # ----------------------------------------------------------------------
    function New-TimingSpanTree {
        param(
            [Parameter(Mandatory)] [string] $RootName,
            [string] $Source
        )
        $root = [pscustomobject]@{
            Name     = $RootName
            Status   = 'Running'
            Source   = $Source
            Children = [System.Collections.Generic.List[object]]::new()
        }
        $ctx = [pscustomobject]@{
            Root  = $root
            Stack = [System.Collections.Generic.Stack[object]]::new()
        }
        $ctx.Stack.Push($root)
        return $ctx
    }

    function Measure-TimingSpan {
        param(
            [Parameter(Mandatory)] $Tree,
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] [scriptblock] $Action,
            [string] $Source
        )
        $parent = $Tree.Stack.Peek()
        $node   = @($parent.Children | Where-Object { $_.Name -eq $Name })[0]
        if (-not $node) {
            $node = [pscustomobject]@{
                Name     = $Name
                Status   = 'Running'
                Source   = $Source
                Children = [System.Collections.Generic.List[object]]::new()
            }
            [void] $parent.Children.Add($node)
        }
        $Tree.Stack.Push($node)
        try {
            & $Action
            if ($node.Status -ne 'Failed') { $node.Status = 'OK' }
        }
        catch {
            $node.Status = 'Failed'
            throw
        }
        finally {
            $Tree.Stack.Pop() | Out-Null
        }
    }

    # Bare declaration so each test attaches its own Mock. The helper only
    # reaches this when the action actually wrote a file (its Test-Path guard),
    # so the absent-file test can assert it was never invoked.
    function Import-TimingSpanTree { param([string] $Path) }

    . "$PSScriptRoot\..\agent\e2e\timing\Measure-ChildProcessTimingSpan.ps1"

    # Builds an imported-root double whose Children carry the given names -
    # the shape Import-TimingSpanTree hands back for the graft.
    function New-ImportedTreeDouble {
        param([string[]] $ChildNames)
        $children = [System.Collections.Generic.List[object]]::new()
        foreach ($name in $ChildNames) {
            $children.Add([pscustomobject]@{
                Name     = $name
                Children = [System.Collections.Generic.List[object]]::new()
            })
        }
        return [pscustomobject]@{ Name = 'child-root'; Children = $children }
    }
}

Describe 'Measure-ChildProcessTimingSpan' {

    BeforeEach {
        # Ensure no ambient opt-in leaks in from a previous test or the host
        # session; the helper's restore logic is asserted separately.
        Remove-Item Env:TIMING_TREE_OUTPUT_PATH -ErrorAction SilentlyContinue
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
}
