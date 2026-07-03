<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-JdkVersionChangeAssertions
#   Asserts that a 'version' change in javaDevKit produced a clean swap on
#   the VM, not a sticky parallel install. The engine should have:
#     V1 - removed every {installPrefix}{previousVersion}* dir.
#     V2 - removed every {manifestFilePrefix}{previousVersion}*.json manifest.
#     V3 - left exactly one {manifestFilePrefix}*.json manifest behind,
#          whose basename references the new version.
#     V4 - re-pointed /usr/local/bin/java at a binary under the new
#          install dir (readlink -f resolves through the symlink).
#
#   The caller is expected to follow this with a full Invoke-JdkInstallAssertions
#   pass against the new version, which covers the positive install side
#   (JAVA_HOME, PATH, java -version). This function focuses on the
#   "old side cleaned up + symlink re-targeted" guarantees that the
#   install assertions cannot prove on their own.
# ---------------------------------------------------------------------------

function Invoke-JdkVersionChangeAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,

        # The operator's previous-version pin (e.g. '17'). Concatenated
        # onto $InstallPrefix to form the cleanup glob. Substring match
        # (not exact) because the resolver expands '17' to '17.0.x+y'.
        [Parameter(Mandatory)] [string] $PreviousRequestedVersion,

        # The operator's new-version pin (e.g. '21'). The remaining
        # manifest's basename must contain this substring so we
        # distinguish the new manifest from a left-behind old one.
        [Parameter(Mandatory)] [string] $NewRequestedVersion,

        # Prefix shared by both old and new install dirs; used for the
        # cleanup glob. The Ansible engine passes '/opt/jdk-'.
        [string] $InstallPrefix = '/opt/jdk-temurin-',

        # Manifest store directory, no trailing slash.
        [string] $ManifestStoreDir = '/var/lib/infra-provisioner/manifests',

        # Manifest filename prefix; the store is probed with the glob
        # '<prefix>*.json'. The Ansible engine passes 'jdk-'.
        [string] $ManifestFilePrefix = 'javaDevKit-'
    )

    # V1) Old install dir glob produces zero matches.
    $oldGlob = "$InstallPrefix$PreviousRequestedVersion"
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
        throw "Old JDK install dir still present on $VmName " +
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
        -Command  ("ls -1 $ManifestStoreDir/" +
                   "$ManifestFilePrefix*.json")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest listing failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $paths = @(($result.Output -split "`n") | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object { $_.Trim() })
    if ($paths.Count -ne 1) {
        throw "Expected exactly one $ManifestFilePrefix*.json manifest on " +
            "$VmName after version change, " +
            "found $($paths.Count): $($paths -join ', '). " +
            "Version change left stale manifest(s) behind."
    }
    $manifestBasename = Split-Path -Leaf $paths[0]
    if ($manifestBasename -notmatch [regex]::Escape($NewRequestedVersion)) {
        throw "Remaining manifest on $VmName does not reference the new " +
            "version '$NewRequestedVersion' (got '$manifestBasename'). " +
            "Version change left the old manifest in place."
    }
    Write-Host ("  [OK] V2+V3: one manifest remains, references new " +
        "version: $manifestBasename") -ForegroundColor Green

    # V4) /usr/local/bin/java symlink target resolved with readlink -f
    #     must live under the new install dir's vendor+version prefix.
    $newPrefix = "$InstallPrefix$NewRequestedVersion"
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  'readlink -f /usr/local/bin/java'
    if ($result.ExitStatus -ne 0) {
        throw "readlink /usr/local/bin/java failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $target = $result.Output.Trim()
    if (-not $target.StartsWith($newPrefix)) {
        throw "/usr/local/bin/java on $VmName still points outside the " +
            "new install ('$target', expected prefix '$newPrefix'). " +
            "Version change did not re-point the binary symlink."
    }
    Write-Host "  [OK] V4: /usr/local/bin/java -> $target" -ForegroundColor Green
}
