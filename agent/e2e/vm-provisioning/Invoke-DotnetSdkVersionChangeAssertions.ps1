<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-DotnetSdkVersionChangeAssertions
#   Asserts that a 'version' change in dotnetSdk produced a clean swap on
#   the VM, not a sticky parallel install. The reconciler should have:
#     V1 - removed every /opt/dotnet-{previousResolvedVersion}* dir.
#     V2 - removed every dotnetSdk-{previousResolvedVersion}*.json manifest.
#     V3 - left exactly one dotnetSdk-*.json manifest behind, whose
#          basename references the new resolved version.
#     V4 - re-pointed /usr/local/bin/dotnet at a binary under the new
#          install dir (readlink -f resolves through the symlink).
#
#   The caller is expected to follow this with a full
#   Invoke-DotnetSdkInstallAssertions pass against the new version, which
#   covers the positive install side (DOTNET_ROOT, PATH, dotnet --version).
#   This function focuses on the "old side cleaned up + symlink re-targeted"
#   guarantees that the install assertions cannot prove on their own.
#
#   Mirror of Invoke-JdkVersionChangeAssertions; uses *resolved* version
#   strings (e.g. '10.0.100') rather than requested pins because the
#   dotnet install dir and manifest are keyed off the resolved version.
# ---------------------------------------------------------------------------

function Invoke-DotnetSdkVersionChangeAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,

        # Shared install prefix, e.g. '/opt/dotnet-'. Used for the
        # cleanup glob.
        [Parameter(Mandatory)] [string] $InstallPrefix,

        # The resolver's previous concrete pin (e.g. '10.0.100'). The
        # install dir and manifest basename embed this resolved version,
        # so the cleanup check uses the exact resolved string.
        [Parameter(Mandatory)] [string] $PreviousResolvedVersion,

        # The resolver's new concrete pin (e.g. '11.0.100'). The remaining
        # manifest's basename must contain this substring so we
        # distinguish the new manifest from a left-behind old one.
        [Parameter(Mandatory)] [string] $NewResolvedVersion
    )

    # V1) Old install dir glob produces zero matches.
    $oldGlob = "$InstallPrefix$PreviousResolvedVersion"
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'shopt -s nullglob; " +
                   "arr=( ${oldGlob}* ); echo `${#arr[@]}'")
    if ($result.ExitStatus -ne 0) {
        throw "Old install-dir glob check failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $count = [int]($result.Output.Trim())
    if ($count -ne 0) {
        throw "Old dotnet SDK install dir still present on $VmName " +
            "(expected 0 under '${oldGlob}*', got $count). " +
            "Version change did not uninstall the previous version."
    }
    Write-Host "  [OK] V1: no ${oldGlob}* directories remain" `
        -ForegroundColor Green

    # V2 + V3) Manifest accounting. ls -1 the provider glob: every line
    #          is a current manifest. Exactly one should remain, and its
    #          basename should reference the new version (not the old).
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("ls -1 /var/lib/infra-provisioner/manifests/" +
                   "dotnetSdk-*.json")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest listing failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $paths = @(($result.Output -split "`n") | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object { $_.Trim() })
    if ($paths.Count -ne 1) {
        throw "Expected exactly one dotnetSdk manifest on $VmName after " +
            "version change, found $($paths.Count): $($paths -join ', '). " +
            "Version change left stale manifest(s) behind."
    }
    $manifestBasename = Split-Path -Leaf $paths[0]
    if ($manifestBasename -notmatch [regex]::Escape($NewResolvedVersion)) {
        throw "Remaining manifest on $VmName does not reference the new " +
            "version '$NewResolvedVersion' (got '$manifestBasename'). " +
            "Version change left the old manifest in place."
    }
    Write-Host ("  [OK] V2+V3: one manifest remains, references new " +
        "version: $manifestBasename") -ForegroundColor Green

    # V4) /usr/local/bin/dotnet symlink target resolved with readlink -f
    #     must live under the new install dir's prefix.
    $newPrefix = "$InstallPrefix$NewResolvedVersion"
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  'readlink -f /usr/local/bin/dotnet'
    if ($result.ExitStatus -ne 0) {
        throw "readlink /usr/local/bin/dotnet failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $target = $result.Output.Trim()
    if (-not $target.StartsWith($newPrefix)) {
        throw "/usr/local/bin/dotnet on $VmName still points outside the " +
            "new install ('$target', expected prefix '$newPrefix'). " +
            "Version change did not re-point the binary symlink."
    }
    Write-Host "  [OK] V4: /usr/local/bin/dotnet -> $target" -ForegroundColor Green
}
