BeforeAll {
    # ----------------------------------------------------------------------
    # The Common.PowerShell timing + retention surface is not installed in
    # this unit runspace, so the three primitives Publish-E2ETimingReport
    # orchestrates are stubbed as bare declarations for Pester's Mock to
    # attach to. Publish's own job is to sequence them with the right
    # arguments (report, then artifact, then prune) and to place the
    # artifact under timing/; the primitives' own behaviour (rendering,
    # serialisation, oldest-pruned/newest-kept retention) is covered by
    # Common.PowerShell.Tests.
    # ----------------------------------------------------------------------
    function Write-TimingSpanReport { param($Tree) }
    function Export-TimingSpanTree  { param($Tree, [string] $Path) }
    function Limit-RetainedItem {
        param([string] $Directory, [string] $Filter, [int] $MaxItems, [switch] $FileOnly)
    }

    . "$PSScriptRoot\..\agent\e2e\timing\Publish-E2ETimingReport.ps1"

    # A per-file temp diagnostics root so the timing/ folder is created and
    # asserted against a real path without touching the workstation's real
    # diagnostics tree. Removed in AfterAll.
    $script:diagRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
        ("e2e-timing-report-{0}" -f [System.Guid]::NewGuid().ToString('N'))
}

AfterAll {
    if (Test-Path -LiteralPath $script:diagRoot) {
        Remove-Item -LiteralPath $script:diagRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Publish-E2ETimingReport' {

    BeforeEach {
        # A stand-in timing context. Publish only passes it through to the
        # (mocked) report + export primitives, so its shape is immaterial here.
        $script:tree = [pscustomobject]@{ Root = [pscustomobject]@{ Name = 'run' } }

        Mock Write-TimingSpanReport { }
        Mock Export-TimingSpanTree  { }
        Mock Limit-RetainedItem     { }
    }

    It 'renders the console report for the given tree' {
        Publish-E2ETimingReport -Tree $script:tree -DiagnosticsRoot $script:diagRoot

        Should -Invoke Write-TimingSpanReport -Times 1 -Exactly `
            -ParameterFilter { $Tree -eq $script:tree }
    }

    It 'writes the JSON artifact under a timing/ folder in the diagnostics root' {
        Publish-E2ETimingReport -Tree $script:tree -DiagnosticsRoot $script:diagRoot

        $expectedDir = Join-Path $script:diagRoot 'timing'
        Should -Invoke Export-TimingSpanTree -Times 1 -Exactly -ParameterFilter {
            # Same tree, and a .json file that lives directly under timing/.
            $Tree -eq $script:tree -and
            (Split-Path $Path -Parent) -eq $expectedDir -and
            $Path -like '*.json'
        }
    }

    It 'creates the timing/ folder when it does not yet exist' {
        # Export is mocked, so only Publish's own New-Item can create the dir.
        $timingDir = Join-Path $script:diagRoot 'timing'
        if (Test-Path -LiteralPath $timingDir) {
            Remove-Item -LiteralPath $timingDir -Recurse -Force
        }

        Publish-E2ETimingReport -Tree $script:tree -DiagnosticsRoot $script:diagRoot

        Test-Path -LiteralPath $timingDir -PathType Container | Should -BeTrue
    }

    It 'prunes the timing/ folder to the retention window' {
        Publish-E2ETimingReport -Tree $script:tree `
            -DiagnosticsRoot $script:diagRoot -MaxItems 7

        # Retention is requested against the JSON artifacts only, bounded to
        # the passed window; the pruning mechanics themselves are
        # Limit-RetainedItem's own contract (Common.PowerShell.Tests).
        $expectedDir = Join-Path $script:diagRoot 'timing'
        Should -Invoke Limit-RetainedItem -Times 1 -Exactly -ParameterFilter {
            $Directory -eq $expectedDir -and
            $Filter    -eq '*.json'     -and
            $MaxItems  -eq 7            -and
            $FileOnly.IsPresent
        }
    }

    It 'defaults the retention window when -MaxItems is omitted' {
        Publish-E2ETimingReport -Tree $script:tree -DiagnosticsRoot $script:diagRoot

        # A positive default keeps the rolling window bounded without the
        # caller having to name a size on every run.
        Should -Invoke Limit-RetainedItem -Times 1 -Exactly -ParameterFilter {
            $MaxItems -gt 0
        }
    }
}
