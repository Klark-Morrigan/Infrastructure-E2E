<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after PowerShell.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-BulkFileTransferAssertions
#   Asserts that every file matching a host wildcard requested via the
#   VmProvisionerConfig 'files' array (bulk form: { pattern, targetDir })
#   landed on the VM intact under TargetDir:
#     - exactly $BaseNames.Count *.jar files are present (C1 - count)
#     - each expected basename exists (C1 - names)
#     - every matched file is owned root:root (C2)
#     - every matched file has mode 0644 (C3)
#     - each landed file's SHA-256 equals the SHA-256 of the host source
#       under SourceDir/<basename> (C4)
#
#   When -ExpectedShas is supplied, additionally asserts each VM-side
#   SHA-256 equals the snapshot value, proving idempotence across a
#   re-provision (C6 in the bulk plan).
#
#   Returns a hashtable basename -> SHA-256 (upper hex) so the caller can
#   capture a phase-1 snapshot and pass it back in on phase 2.
#
#   Each failure throws with a message naming the VM and the observed
#   value. The outer try/finally in Invoke-VmProvisioningTest still runs
#   teardown.
#
#   Why this is separate from Invoke-FileTransferAssertions: the bulk path
#   needs count / per-basename presence checks (C1) and a per-file iteration
#   that the single-file helper has no notion of. Keeping the two helpers
#   apart lets each stay focused and independently unit-testable.
# ---------------------------------------------------------------------------

function Invoke-BulkFileTransferAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # Host directory containing the source files (one per BaseName).
        [Parameter(Mandatory)]
        [string] $SourceDir,

        # Absolute Linux directory the bulk entry's pattern targeted.
        [Parameter(Mandatory)]
        [string] $TargetDir,

        # Basenames expected under TargetDir on the VM. Order does not
        # matter; the helper sorts before comparing.
        [Parameter(Mandatory)]
        [string[]] $BaseNames,

        # Optional snapshot of VM-side hashes from a prior phase. When
        # supplied, each VM-side SHA-256 must equal $ExpectedShas[$base]
        # as well as the host SHA-256 - that is the idempotence assertion.
        [hashtable] $ExpectedShas
    )

    # ----- C1a: exact count of *.jar files under TargetDir ---------------
    # 2>/dev/null swallows the "no such file" stderr if TargetDir is
    # missing - the count of 0 then triggers a clear assertion error
    # rather than a stat / sha256sum cascade later.
    $expectedCount = $BaseNames.Count
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'ls $TargetDir/*.jar 2>/dev/null | wc -l'"
    if ($result.ExitStatus -ne 0) {
        throw "Bulk-transfer count probe failed on $VmName for '$TargetDir' " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $actualCount = [int]($result.Output.Trim())
    if ($actualCount -ne $expectedCount) {
        throw "Bulk-transfer count mismatch on $VmName under '$TargetDir'. " +
            "Expected $expectedCount .jar files, found $actualCount."
    }
    Write-Host "  [OK] bulk count: $actualCount .jar file(s) under $TargetDir" `
        -ForegroundColor Green

    # ----- C1b: every expected basename is present ----------------------
    # Single ls; compare against the expected list so a missing/extra
    # file produces a useful error rather than a generic count mismatch
    # (count could match if a stray file replaced an expected one).
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'cd $TargetDir && ls -1 *.jar'"
    if ($result.ExitStatus -ne 0) {
        throw "Bulk-transfer listing failed on $VmName for '$TargetDir' " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $actualNames = $result.Output.Trim() -split "`n" |
                   ForEach-Object { $_.Trim() } |
                   Where-Object   { $_ -ne '' } |
                   Sort-Object
    $expectedNames = $BaseNames | Sort-Object
    if (-not ($actualNames -join ',' -ceq ($expectedNames -join ','))) {
        throw "Bulk-transfer basenames mismatch on $VmName under '$TargetDir'. " +
            "Expected '$($expectedNames -join ',')', got '$($actualNames -join ',')'."
    }
    Write-Host "  [OK] bulk basenames present: $($actualNames -join ', ')" `
        -ForegroundColor Green

    # ----- C2 + C3: owner / mode uniformly root:root, 0644 --------------
    # sort -u collapses identical lines; if every file is policy-compliant
    # the result is exactly one line. Any deviation (a single off-mode
    # file) produces a second line and surfaces here before per-file SHA
    # work.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'stat -c %U:%G $TargetDir/*.jar | sort -u'"
    if ($result.ExitStatus -ne 0) {
        throw "stat (owner) on '$TargetDir/*.jar' failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $owners = $result.Output.Trim()
    if ($owners -ne 'root:root') {
        throw "Bulk-transfer owner mismatch on $VmName under '$TargetDir'. " +
            "Expected 'root:root' uniformly, got '$owners'."
    }
    Write-Host "  [OK] bulk owner uniform: root:root" -ForegroundColor Green

    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'stat -c %a $TargetDir/*.jar | sort -u'"
    if ($result.ExitStatus -ne 0) {
        throw "stat (mode) on '$TargetDir/*.jar' failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $modes = $result.Output.Trim()
    if ($modes -ne '644') {
        throw "Bulk-transfer mode mismatch on $VmName under '$TargetDir'. " +
            "Expected '644' uniformly, got '$modes'."
    }
    Write-Host "  [OK] bulk mode uniform: 644" -ForegroundColor Green

    # ----- C4 + optional C6: per-file SHA-256 vs host (and snapshot) ----
    # Per-file rather than concatenated so a mismatch names the offender;
    # a partial-copy bug that left, say, only b.jar truncated would
    # otherwise hide behind a "files differ" message with no pointer.
    $actualShas = @{}
    foreach ($base in $BaseNames) {
        $hostPath = Join-Path $SourceDir $base
        $expectedHash = (Get-FileHash -Path $hostPath -Algorithm SHA256).Hash.ToUpperInvariant()

        $vmPath = "$TargetDir/$base"
        $result = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command  "sha256sum '$vmPath' | awk '{print `$1}'"
        if ($result.ExitStatus -ne 0) {
            throw "sha256sum on '$vmPath' failed on $VmName " +
                "(exit $($result.ExitStatus)): $($result.Error)"
        }
        $actualHash = $result.Output.Trim().ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "Bulk-transfer content mismatch on $VmName for '$vmPath'. " +
                "Expected SHA-256 $expectedHash (host '$hostPath'), got $actualHash."
        }

        # Idempotence (C6): if the caller passed a prior-phase snapshot,
        # the VM-side hash must also equal the snapshot value. Since host
        # files are not edited between phases this is transitively true
        # when C4 passes, but asserting it explicitly catches a transport
        # bug that, on a re-provision, somehow left a stale-but-different
        # file behind that still happened to differ from the host.
        if ($null -ne $ExpectedShas) {
            if (-not $ExpectedShas.ContainsKey($base)) {
                throw "Idempotence snapshot on $VmName is missing '$base'. " +
                    "Snapshot keys: '$($ExpectedShas.Keys -join ',')'."
            }
            $snapshotHash = ([string]$ExpectedShas[$base]).ToUpperInvariant()
            if ($actualHash -ne $snapshotHash) {
                throw "Bulk-transfer idempotence broken on $VmName for '$vmPath'. " +
                    "Phase-1 SHA-256 $snapshotHash, observed $actualHash."
            }
        }

        $actualShas[$base] = $actualHash
        Write-Host "  [OK] $base SHA-256 matches host source." -ForegroundColor Green
    }

    return $actualShas
}
