<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Get-JdkArtifactSnapshot
#   Snapshots the mtimes of the three JDK artifacts the reconciler owns on
#   a VM (install dir, profile.d script, manifest file). Used in pairs:
#   once before a no-op re-provision, once after; equality across both
#   snapshots proves the reconciler took the no-op branch and did not
#   touch the existing install.
#
#   Failure mode this guards against: a regression where the JdkProvider
#   re-extracts the tarball / re-writes the profile.d script / re-writes
#   the manifest unconditionally instead of consulting the diff plan.
#   Such a regression would still pass install + uninstall assertions but
#   would burn cycles and risk partial-failure recovery loops.
#
#   Returns a PSCustomObject with %Y epoch seconds for each artifact, plus
#   the resolved install dir + manifest path so a future snapshot does
#   not need to re-glob.
# ---------------------------------------------------------------------------

function Get-JdkArtifactSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,

        # Same vendor-prefix convention as the install/uninstall helpers,
        # e.g. '/opt/jdk-temurin-'. Resolved to a concrete install dir via
        # a glob below.
        [Parameter(Mandatory)] [string] $InstallPrefix
    )

    # One-shot stat across the three known globs. stat prints
    # '<name> <epoch>' per line; ordering by argv keeps the parse
    # position-independent. stat exits non-zero if any glob expands to
    # zero matches, which surfaces as ExitStatus below.
    $cmd = (
        "stat -c '%n %Y' ${InstallPrefix}* " +
            "/etc/profile.d/jdk.sh " +
            "/var/lib/infra-provisioner/manifests/javaDevKit-*.json"
    )

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $cmd
    if ($result.ExitStatus -ne 0) {
        throw "JDK artifact snapshot failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }

    # Parse: each line is "<path> <epoch>". The install-dir line is the
    # one starting with $InstallPrefix; manifest line starts with the
    # store prefix; profile.d line is exact-match.
    $snapshot = [ordered]@{
        InstallDir = $null; ManifestPath = $null
        InstallMtime = $null; ProfileMtime = $null; ManifestMtime = $null
    }
    foreach ($line in ($result.Output -split "`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        $lastSpace = $trimmed.LastIndexOf(' ')
        $path  = $trimmed.Substring(0, $lastSpace)
        $mtime = [int64] $trimmed.Substring($lastSpace + 1)
        if ($path.StartsWith($InstallPrefix)) {
            $snapshot.InstallDir   = $path
            $snapshot.InstallMtime = $mtime
        }
        elseif ($path -eq '/etc/profile.d/jdk.sh') {
            $snapshot.ProfileMtime = $mtime
        }
        elseif ($path.StartsWith('/var/lib/infra-provisioner/manifests/')) {
            $snapshot.ManifestPath  = $path
            $snapshot.ManifestMtime = $mtime
        }
    }
    foreach ($k in 'InstallDir', 'ManifestPath', 'InstallMtime',
                   'ProfileMtime', 'ManifestMtime') {
        if ($null -eq $snapshot[$k]) {
            throw "JDK artifact snapshot on $VmName missing '$k'. " +
                "Raw output: $($result.Output)"
        }
    }

    return [PSCustomObject] $snapshot
}

# ---------------------------------------------------------------------------
# Invoke-JdkNoopAssertions
#   Asserts that a re-provision with an unchanged 'javaDevKit' field did
#   not disturb the existing install. Given a pre-rerun snapshot, takes
#   a fresh snapshot and asserts all three artifact mtimes match
#   exactly. Equality on the install dir's mtime is the strongest
#   signal - any re-extract or atomic dir swap would advance it.
# ---------------------------------------------------------------------------

function Invoke-JdkNoopAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $InstallPrefix,

        # Snapshot from Get-JdkArtifactSnapshot taken before the no-op
        # provision run. Must have come from the same VM.
        [Parameter(Mandatory)] [PSCustomObject] $PreviousSnapshot
    )

    $now = Get-JdkArtifactSnapshot `
        -SshClient $SshClient -VmName $VmName -InstallPrefix $InstallPrefix

    # Install dir identity also must not change - a regression that
    # uninstalled + re-installed under the same version pin would still
    # land at the same path *only* if the resolver pinned identically,
    # which is not guaranteed. Equality of the path itself catches the
    # rare case where it changed even though the version did not.
    if ($now.InstallDir -ne $PreviousSnapshot.InstallDir) {
        throw "Install dir changed across no-op rerun on $VmName " +
            "(was '$($PreviousSnapshot.InstallDir)', now '$($now.InstallDir)')."
    }
    if ($now.ManifestPath -ne $PreviousSnapshot.ManifestPath) {
        throw "Manifest path changed across no-op rerun on $VmName " +
            "(was '$($PreviousSnapshot.ManifestPath)', now '$($now.ManifestPath)')."
    }

    $checks = @(
        @{ Name = 'install dir';      Was = $PreviousSnapshot.InstallMtime;
           Now = $now.InstallMtime  },
        @{ Name = 'profile.d/jdk.sh'; Was = $PreviousSnapshot.ProfileMtime;
           Now = $now.ProfileMtime  },
        @{ Name = 'manifest';         Was = $PreviousSnapshot.ManifestMtime;
           Now = $now.ManifestMtime }
    )
    foreach ($c in $checks) {
        if ($c.Now -ne $c.Was) {
            throw "No-op rerun touched $($c.Name) on $VmName " +
                "(mtime was $($c.Was), now $($c.Now)). Reconciler did " +
                "not take the no-op branch."
        }
        Write-Host "  [OK] no-op: $($c.Name) mtime unchanged ($($c.Was))" `
            -ForegroundColor Green
    }
}
