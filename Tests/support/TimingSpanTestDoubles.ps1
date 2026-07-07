<#
.NOTES
    Shared Pester doubles for the Common.PowerShell N-level timing surface
    (New-/Measure-TimingSpan, Import-TimingSpanTree), which is NOT installed in
    the unit runspace. Dot-source this from a test file's BeforeAll to get one
    authoritative copy instead of hand-copying the fixture per file - the three
    timing suites (Invoke-RunnerLifecycleTest, Measure-ChildProcessTimingSpan,
    Invoke-VmProvisioningPhase1) all consume it, so a fix (e.g. the StrictMode
    guard below) lands once rather than drifting across copies.

    Deliberately not named *.Tests.ps1 so the unit-test discovery
    (Get-UnitTestFiles) does not try to run it as a suite.

    The doubles reproduce only the contract the instrumentation relies on:
    find-or-create by name-within-parent, push/pop nesting, sticky-Failed
    re-throw, and pass-through of the timed action's output. The exhaustive
    timing semantics (elapsed accumulation, percent-of-parent, rendering) live
    in Common.PowerShell.Tests; here they are a fixture.
#>

# Root/node carry ElapsedMs so the shape matches the real surface for suites
# that inspect it; suites that ignore the field are unaffected.
function New-TimingSpanTree {
    param(
        [Parameter(Mandatory)] [string] $RootName,
        [string] $Source
    )
    $root = [pscustomobject]@{
        Name      = $RootName
        Status    = 'Running'
        ElapsedMs = 0
        Source    = $Source
        Children  = [System.Collections.Generic.List[object]]::new()
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
    # Select-Object -First 1 (not @(...)[0]) so an as-yet-unseen name yields
    # $null rather than tripping StrictMode's out-of-bounds-index guard - the
    # canonical runner (scripts/Run-Tests.ps1) runs Pester under
    # Set-StrictMode -Version Latest.
    $node   = $parent.Children | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $node) {
        $node = [pscustomobject]@{
            Name      = $Name
            Status    = 'Running'
            ElapsedMs = 0
            Source    = $Source
            Children  = [System.Collections.Generic.List[object]]::new()
        }
        [void] $parent.Children.Add($node)
    }
    $Tree.Stack.Push($node)
    try {
        & $Action
        if ($node.Status -ne 'Failed') { $node.Status = 'OK' }
    }
    catch {
        # Sticky-Failed + re-throw: mirrors the real verb so a mid-run failure
        # leaves the failing span marked and the exception intact.
        $node.Status = 'Failed'
        throw
    }
    finally {
        $Tree.Stack.Pop() | Out-Null
    }
}

# Bare declaration so each suite attaches its own Mock. The graft helper only
# reaches it when the child actually wrote a file (its Test-Path guard), so a
# suite can also assert it was never invoked.
function Import-TimingSpanTree { param([string] $Path) }

# Builds an imported-root double whose Children carry the given names - the
# shape Import-TimingSpanTree hands back for the graft.
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
