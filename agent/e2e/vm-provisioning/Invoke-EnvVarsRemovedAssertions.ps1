<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after PowerShell.Common (for Invoke-SshClientCommand) is loaded and
    after Invoke-EnvVarsAppliedAssertions.ps1 (for the shared mode/owner and
    line-number helpers).
#>

# ---------------------------------------------------------------------------
# Invoke-EnvVarsRemovedAssertions
#   Asserts that an empty-entries re-provision removed the managed envVars
#   block cleanly:
#     - BEGIN / END markers are gone (E7)
#     - the entries that lived inside the block are gone (E8)
#     - /etc/environment ownership / mode preserved (E1)
#     - out-of-block marker line still present (E3)
#
#   Used by phase 3, where VmProvisionerConfig sets `envVars.entries: []`
#   - the operator's explicit "remove the managed block" intent per
#   problem.md - Out of Scope.
#
#   The "names that were in the block are gone" check matches by the
#   bare `NAME=` prefix rather than the full quoted line, so an
#   accidental rewrite that quoted differently (e.g. without escaping)
#   would still surface as a failure - we want every variant gone, not
#   just the one we previously asserted.
# ---------------------------------------------------------------------------

function Invoke-EnvVarsRemovedAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,

        # The block name that USED to be present. Used for the BEGIN /
        # END marker absence check - phase 3 must remove THIS block, not
        # just any block.
        [Parameter(Mandatory)] [string] $RemovedBlockName,

        # Names that used to live inside the block. Each must no longer
        # appear at the start of any line in /etc/environment.
        [Parameter(Mandatory)] [string[]] $RemovedEntryNames,

        # The seeded out-of-block line whose preservation we are also
        # checking on this re-run.
        [Parameter(Mandatory)] [string] $ExpectedMarkerLine
    )

    # 1) Mode / ownership unchanged - the removal path uses the same
    #    atomic mv as the write path, so root:root 0644 must still hold.
    Assert-EtcEnvironmentOwnershipAndMode -SshClient $SshClient -VmName $VmName

    # 2) BEGIN / END markers absent (E7). grep -c returns 1 only when at
    #    least one match exists; absence is exit 1 with empty stdout.
    foreach ($marker in @("# BEGIN $RemovedBlockName", "# END $RemovedBlockName")) {
        Assert-EtcEnvironmentLineAbsent `
            -SshClient $SshClient -VmName $VmName -Marker $marker
    }
    Write-Host "  [OK] block '$RemovedBlockName' markers removed" -ForegroundColor Green

    # 3) Each formerly-managed entry is gone (E8). Match by the
    #    `^NAME=` prefix, so any quoting variant of the value still
    #    counts as "present" if it leaked.
    foreach ($name in $RemovedEntryNames) {
        Assert-EtcEnvironmentLineAbsent `
            -SshClient $SshClient -VmName $VmName `
            -Pattern   "^$name="
    }
    Write-Host "  [OK] removed entries absent: $($RemovedEntryNames -join ', ')" `
        -ForegroundColor Green

    # 4) Out-of-block marker still present (E3 in phase 3). The block
    #    removal path runs a strip-then-write pass; this assertion
    #    catches a bug where the strip accidentally took the marker
    #    line with it.
    $markerLine = Get-EtcEnvironmentLineNumber `
        -SshClient $SshClient -VmName $VmName -Line $ExpectedMarkerLine
    Write-Host "  [OK] out-of-block line still present (line $markerLine)" `
        -ForegroundColor Green
}

# Helper: assert a line / pattern does NOT match anywhere in
# /etc/environment. Used both for fixed-string marker absence and
# regex-prefix absence of formerly-managed entries.
#
# Either -Marker (fixed string, exact full-line match) or -Pattern
# (regex, anywhere on a line) must be supplied. Splitting the two
# avoids quoting confusion at the grep level.
function Assert-EtcEnvironmentLineAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [string] $Marker,
        [string] $Pattern
    )

    if ($Marker -and $Pattern) {
        throw "Assert-EtcEnvironmentLineAbsent: pass either -Marker or -Pattern, not both."
    }
    if (-not $Marker -and -not $Pattern) {
        throw "Assert-EtcEnvironmentLineAbsent: -Marker or -Pattern is required."
    }

    if ($Marker) {
        $cmd  = "grep -c -Fx '$Marker' /etc/environment"
        $what = "marker '$Marker'"
    } else {
        $cmd  = "grep -c -E '$Pattern' /etc/environment"
        $what = "pattern '$Pattern'"
    }

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $cmd
    $count = if ($result.ExitStatus -eq 0) { [int]$result.Output.Trim() }
             elseif ($result.ExitStatus -eq 1) { 0 }
             else { throw "grep on $what failed on $VmName " +
                    "(exit $($result.ExitStatus)): $($result.Error)" }
    if ($count -ne 0) {
        throw "$what still present on $VmName ($count occurrence(s) in " +
            "/etc/environment; expected 0)."
    }
}
