<#
.NOTES
    Do not run this file directly. Dot-source it after Common.PowerShell is
    loaded (Invoke-VmProvisioningTest.ps1 does this; the vm-users and
    runner-lifecycle chains inherit it transitively through that file).
#>

# ---------------------------------------------------------------------------
# Measure-ChildProcessTimingSpan
#   Times a part that shells out to a child process AND grafts the child's
#   own timing tree under the part's span, so an opaque shell-out (provision,
#   user reconcile, runner registration) renders with its internal breakdown
#   instead of a single flat bar (feature 88 C2).
#
#   The parent/child handoff is the neutral $env:TIMING_TREE_OUTPUT_PATH
#   opt-in: this wrapper points it at a fresh per-invocation temp file before
#   the shell-out, and a child that honours the opt-in (Section D/E emitters)
#   writes its exported tree there. After the action returns, the child's
#   subtree is imported and its top-level spans become the children of this
#   part's node.
#
#   For a bash child under WSL the opt-in also has to cross the WSL boundary:
#   a Windows env var is invisible inside `wsl -- ...` unless its name is
#   listed in WSLENV, and a path value is unusable there without the /p
#   translation flag. This wrapper appends TIMING_TREE_OUTPUT_PATH/p to WSLENV
#   for the duration of the action so the bash emitters (register-runners.sh,
#   create-users.sh, provision-toolchains.sh) write the very file the parent
#   then imports; the pwsh children ignore WSLENV and are unaffected. Doing
#   the forwarding here - once, in the wrapper that owns the opt-in variable -
#   covers every bash child, present and future, with no per-shell-out edits
#   (feature 88 E3).
#
#   The graft is graceful by design. Until a given child ships its emitter -
#   and for any child that crashes before exporting - no file is written, so
#   the part is simply timed with no children and no error. Each child deepens
#   the report the moment its emitter lands, with no change here.
#
#   Cleanup runs on both the success and failure paths: the env var is
#   restored to its prior value (so a sibling part never inherits a stale
#   path) and the temp file is deleted (its contents already live in memory
#   as the grafted subtree).
# ---------------------------------------------------------------------------

function Measure-ChildProcessTimingSpan {
    [CmdletBinding()]
    param(
        # Timing context (New-TimingSpanTree). The part span attaches under
        # its current node, exactly as a plain Measure-TimingSpan would.
        [Parameter(Mandatory)]
        $Tree,

        # Part span name; unique within the current node's children.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # The shell-out to time. Any child it launches inherits the
        # TIMING_TREE_OUTPUT_PATH set below and may export into it.
        [Parameter(Mandatory)]
        [scriptblock] $Action,

        # Optional provenance tag forwarded to the part node on creation.
        [string] $Source
    )

    # Fresh per-invocation temp file. A unique name keeps sequential parts
    # from reading each other's export, and lets the graft below distinguish
    # "this child wrote nothing" (absent) from a real subtree.
    $childTreePath = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("e2e-timing-{0}.json" -f [System.Guid]::NewGuid().ToString('N'))

    # Save and set the child opt-in. Restored in finally so the path does not
    # leak into a sibling part's shell-out. Neutral name - the child does not
    # know the E2E orchestrator is its consumer (production stays test-agnostic).
    $priorOutputPath              = $env:TIMING_TREE_OUTPUT_PATH
    $env:TIMING_TREE_OUTPUT_PATH  = $childTreePath

    # Forward the opt-in across the WSL boundary. The name must be listed in
    # WSLENV to reach a `wsl -- ...` child at all, and the /p flag path-
    # translates the Windows temp path (under C:) to /mnt/c/... so the bash
    # child writes the same file imported below. Saved and restored in the same
    # finally as the path. Guarded against duplication so a nested wrap does not
    # stack the entry, mirroring the GH_TOKEN/u forwarding in Set-VmRunnersForTest.
    $priorWslEnv = $env:WSLENV
    if ($env:WSLENV) {
        if ($env:WSLENV -notlike '*TIMING_TREE_OUTPUT_PATH*') {
            $env:WSLENV = "$env:WSLENV`:TIMING_TREE_OUTPUT_PATH/p"
        }
    }
    else {
        $env:WSLENV = 'TIMING_TREE_OUTPUT_PATH/p'
    }

    # Resolve the parent up front: Measure-TimingSpan mints the part node as a
    # child of the current node, so after it returns (or throws) the node is
    # found here by name. Captured before the call so the finally graft works
    # on the failure path too, where the action's rethrow skips straight past.
    $parent = $Tree.Stack.Peek()

    try {
        Measure-TimingSpan -Tree $Tree -Name $Name -Action $Action -Source $Source
    }
    finally {
        # Restore the env vars first. A $null prior value means the variable
        # did not exist before, so remove it rather than leaving an empty
        # string. WSLENV is restored alongside the path so the per-invocation
        # forwarding never accumulates across sibling parts.
        if ($null -eq $priorOutputPath) {
            Remove-Item Env:TIMING_TREE_OUTPUT_PATH -ErrorAction SilentlyContinue
        }
        else {
            $env:TIMING_TREE_OUTPUT_PATH = $priorOutputPath
        }

        if ($null -eq $priorWslEnv) {
            Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
        }
        else {
            $env:WSLENV = $priorWslEnv
        }

        # Graft the child's exported subtree under the part node. Only import
        # when the child actually wrote a file: absence is the normal state
        # until the emitter ships, and skipping Import-TimingSpanTree there
        # avoids a misleading "no timing file" warning on every clean run.
        # A file that exists but is corrupt still routes through Import's
        # defensive path ($null + warning), so a half-written export cannot
        # break the report.
        if (Test-Path -LiteralPath $childTreePath -PathType Leaf) {
            $childTree = Import-TimingSpanTree -Path $childTreePath
            $partNode  = @($parent.Children | Where-Object { $_.Name -eq $Name })[0]
            if ($null -ne $childTree -and $null -ne $partNode) {
                foreach ($childSpan in $childTree.Children) {
                    [void] $partNode.Children.Add($childSpan)
                }
            }
            # The subtree is now in memory as the part's children; the file is
            # spent.
            Remove-Item -LiteralPath $childTreePath -Force -ErrorAction SilentlyContinue
        }
    }
}
