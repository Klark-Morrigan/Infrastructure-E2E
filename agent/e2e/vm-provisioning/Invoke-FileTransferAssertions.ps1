<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-FileTransferAssertions
#   Asserts that a host file requested via the VmProvisionerConfig 'files'
#   array landed on the VM intact:
#     - exists at the requested target path
#     - byte-for-byte identical to the host source (SHA-256)
#     - owned by root:root and mode 0644 (the policy enforced by
#       Invoke-VmPostProvisioning for the 'files' step)
#
#   Throws on the first failure with a message naming the VM and the
#   observed value. The outer try/finally in Invoke-VmProvisioningTest
#   still runs teardown.
#
#   $SourcePath / $TargetPath are passed in so this function stays
#   self-contained and unit-testable - the caller decides what fixture
#   was requested and where it should have landed.
#
#   When -ExpectedHash is supplied, additionally asserts the VM-side
#   SHA-256 equals that value - the idempotence assertion for a re-
#   provision (C7 in the bulk-files plan). Returns the observed VM-side
#   SHA-256 (upper hex) so the caller can capture a phase-1 snapshot and
#   pass it back in on phase 2.
# ---------------------------------------------------------------------------

function Invoke-FileTransferAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # Host path of the fixture that was placed into the 'files' array.
        [Parameter(Mandatory)]
        [string] $SourcePath,

        # Absolute Linux path the fixture was requested to land at.
        [Parameter(Mandatory)]
        [string] $TargetPath,

        # Optional snapshot of the VM-side hash from a prior phase. When
        # supplied, the observed hash must equal it - idempotence (C7).
        [string] $ExpectedHash
    )

    # 1) Existence. A missing file would also fail the hash check, but a
    #    targeted check produces a clearer error than "sha256sum: No such
    #    file or directory" surfaced through stderr.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "test -f '$TargetPath'"
    if ($result.ExitStatus -ne 0) {
        throw "File-transfer target '$TargetPath' missing on $VmName " +
            "(test -f exit $($result.ExitStatus))."
    }
    Write-Host "  [OK] target exists: $TargetPath" -ForegroundColor Green

    # 2) Content equality via SHA-256. Computed host-side with the .NET
    #    provider (Get-FileHash) and VM-side with sha256sum. Hex is case-
    #    insensitive so normalise both to upper case before comparing.
    $expectedHash = (Get-FileHash -Path $SourcePath -Algorithm SHA256).Hash.ToUpperInvariant()

    # awk picks the hash field; sha256sum prints "<hex>  <path>".
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "sha256sum '$TargetPath' | awk '{print `$1}'"
    if ($result.ExitStatus -ne 0) {
        throw "sha256sum on '$TargetPath' failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $actualHash = $result.Output.Trim().ToUpperInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "File-transfer content mismatch on $VmName for '$TargetPath'. " +
            "Expected SHA-256 $expectedHash, got $actualHash."
    }
    Write-Host "  [OK] SHA-256 matches host source." -ForegroundColor Green

    # 3) Ownership and mode. Invoke-VmPostProvisioning forces every
    #    'files' entry to root:root / 0644 - assert the policy held end
    #    to end. Single stat call returns both for one round trip.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "stat -c '%U:%G %a' '$TargetPath'"
    if ($result.ExitStatus -ne 0) {
        throw "stat on '$TargetPath' failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $parts = $result.Output.Trim() -split '\s+'
    $owner = $parts[0]
    $mode  = $parts[1]
    if ($owner -ne 'root:root') {
        throw "File-transfer owner mismatch on $VmName for '$TargetPath'. " +
            "Expected 'root:root', got '$owner'."
    }
    if ($mode -ne '644') {
        throw "File-transfer mode mismatch on $VmName for '$TargetPath'. " +
            "Expected '644', got '$mode'."
    }
    Write-Host "  [OK] owner=$owner mode=$mode" -ForegroundColor Green

    # 4) Idempotence: if the caller supplied a phase-1 snapshot, the
    #    observed hash must still equal it. Transitively guaranteed by
    #    step 2 when the host file is unchanged, but asserting it
    #    explicitly catches a transport bug that, on a re-provision,
    #    left a stale-but-different file behind.
    if ($PSBoundParameters.ContainsKey('ExpectedHash') -and $ExpectedHash) {
        if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
            throw "File-transfer idempotence broken on $VmName for '$TargetPath'. " +
                "Phase-1 SHA-256 $ExpectedHash, observed $actualHash."
        }
        Write-Host "  [OK] SHA-256 matches phase-1 snapshot." -ForegroundColor Green
    }

    return $actualHash
}
