<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Get-DotnetSdkArtifactSnapshot
#   Snapshots the mtimes of the three .NET SDK artifacts the reconciler owns
#   on a VM (install dir, profile.d script, manifest file). Used in pairs:
#   once before a no-op re-provision, once after; equality across both
#   snapshots proves the reconciler took the no-op branch and did not
#   touch the existing install.
#
#   Mirror of Get-JdkArtifactSnapshot - any behavioural change here likely
#   needs to apply there too. Differences vs JDK:
#     - install dir prefix is '/opt/dotnet-' (no vendor segment).
#     - profile.d script is /etc/profile.d/dotnet.sh.
#     - manifest glob is dotnetSdk-*.json.
# ---------------------------------------------------------------------------

function Get-DotnetSdkArtifactSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,

        # Install prefix, e.g. '/opt/dotnet-'. Resolved to a concrete
        # install dir via a glob below.
        [Parameter(Mandatory)] [string] $InstallPrefix
    )

    # One-shot stat across the three known globs. stat prints
    # '<name> <epoch>' per line; ordering by argv keeps the parse
    # position-independent. stat exits non-zero if any glob expands to
    # zero matches, which surfaces as ExitStatus below.
    $cmd = (
        "stat -c '%n %Y' ${InstallPrefix}* " +
            "/etc/profile.d/dotnet.sh " +
            "/var/lib/infra-provisioner/manifests/dotnetSdk-*.json"
    )

    $result = Invoke-SshClientCommand -SshClient $SshClient -Command $cmd
    if ($result.ExitStatus -ne 0) {
        throw "dotnet SDK artifact snapshot failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }

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
        elseif ($path -eq '/etc/profile.d/dotnet.sh') {
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
            throw "dotnet SDK artifact snapshot on $VmName missing '$k'. " +
                "Raw output: $($result.Output)"
        }
    }

    return [PSCustomObject] $snapshot
}

# ---------------------------------------------------------------------------
# Invoke-DotnetSdkNoopAssertions
#   Asserts that a re-provision with an unchanged 'dotnetSdk' field did
#   not disturb the existing install. Given a pre-rerun snapshot, takes
#   a fresh snapshot and asserts all three artifact mtimes match
#   exactly. Equality on the install dir's mtime is the strongest
#   signal - any re-extract or atomic dir swap would advance it.
# ---------------------------------------------------------------------------

function Invoke-DotnetSdkNoopAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $InstallPrefix,

        # Snapshot from Get-DotnetSdkArtifactSnapshot taken before the
        # no-op provision run. Must have come from the same VM.
        [Parameter(Mandatory)] [PSCustomObject] $PreviousSnapshot
    )

    $now = Get-DotnetSdkArtifactSnapshot `
        -SshClient $SshClient -VmName $VmName -InstallPrefix $InstallPrefix

    if ($now.InstallDir -ne $PreviousSnapshot.InstallDir) {
        throw "Install dir changed across no-op rerun on $VmName " +
            "(was '$($PreviousSnapshot.InstallDir)', now '$($now.InstallDir)')."
    }
    if ($now.ManifestPath -ne $PreviousSnapshot.ManifestPath) {
        throw "Manifest path changed across no-op rerun on $VmName " +
            "(was '$($PreviousSnapshot.ManifestPath)', now '$($now.ManifestPath)')."
    }

    $checks = @(
        @{ Name = 'install dir';         Was = $PreviousSnapshot.InstallMtime;
           Now = $now.InstallMtime  },
        @{ Name = 'profile.d/dotnet.sh'; Was = $PreviousSnapshot.ProfileMtime;
           Now = $now.ProfileMtime  },
        @{ Name = 'manifest';            Was = $PreviousSnapshot.ManifestMtime;
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
