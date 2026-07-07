<#
.NOTES
    Do not run this file directly. Dot-source it after Common.PowerShell is
    loaded (the runner-lifecycle chain does this via Invoke-RunnerLifecycleTest.ps1).
#>

# Default count of timing JSON artifacts to retain in the timing/ folder.
# The rolling artifact exists so successive runs can be compared to spot a
# regression; a couple of dozen runs is enough history for that without
# letting the folder grow without bound. Retention reuses the shared
# Limit-RetainedItem pruner rather than a bespoke sweep.
$script:TimingArtifactRetentionCount = 20

# ---------------------------------------------------------------------------
# Publish-E2ETimingReport
#   End-of-run emission of the assembled timing tree (feature 88 C3), called
#   from Invoke-RunnerLifecycleTest's outer finally on every exit path -
#   success, failure, and best-effort cleanup - so a failed or hung run still
#   shows where the time went up to the failure point.
#
#   Three steps over the shared Common.PowerShell timing primitives:
#     1. Write-TimingSpanReport - the human-facing console block.
#     2. Export-TimingSpanTree  - the machine-readable rolling JSON artifact,
#        written under <DiagnosticsRoot>/timing/<timestamp>.json so all
#        artifacts for a run stay side by side (next to runtime-diag.log /
#        console.log).
#     3. Limit-RetainedItem     - prune old JSON artifacts to -MaxItems,
#        keeping the rolling window bounded.
#
#   The caller wraps this in a best-effort guard: a diagnostics write must
#   never mask the run's real outcome, so failures here are warned, not
#   thrown. This function itself stays straightforward (the three steps in
#   order) and leaves that guard to the orchestrator boundary.
# ---------------------------------------------------------------------------

function Publish-E2ETimingReport {
    [CmdletBinding()]
    param(
        # Timing context (New-TimingSpanTree) assembled over the run. Rendered
        # to the console and serialised to the JSON artifact.
        [Parameter(Mandatory)]
        $Tree,

        # The run's diagnostics root (typically <vmConfigPath>/diagnostics).
        # The timing/ artifact folder is created under it.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DiagnosticsRoot,

        # Rolling-window size: keep at most this many JSON artifacts.
        [int] $MaxItems = $script:TimingArtifactRetentionCount
    )

    # 1. Console report first so it prints even if the artifact write below
    #    fails - the report is the primary deliverable, the artifact secondary.
    Write-TimingSpanReport -Tree $Tree

    # 2. Rolling JSON artifact under <DiagnosticsRoot>/timing/. Export requires
    #    the parent directory to exist, so create it up front (idempotent).
    $timingDir = Join-Path $DiagnosticsRoot 'timing'
    if (-not (Test-Path -LiteralPath $timingDir)) {
        New-Item -ItemType Directory -Path $timingDir -Force | Out-Null
    }

    # Sortable, collision-resistant filename: a numeric timestamp down to the
    # millisecond so two runs in the same second still get distinct files and
    # lexical order matches chronological order. The specifiers are numeric,
    # so the rendered name is culture-invariant and ASCII per house style.
    $timestamp    = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $artifactPath = Join-Path $timingDir "$timestamp.json"
    Export-TimingSpanTree -Tree $Tree -Path $artifactPath

    # 3. Prune old artifacts to the rolling window. -FileOnly so only the JSON
    #    files are considered; the pruning mechanics (oldest dropped, newest
    #    kept by LastWriteTime) are Limit-RetainedItem's own contract.
    Limit-RetainedItem -Directory $timingDir -Filter '*.json' -MaxItems $MaxItems -FileOnly
}
