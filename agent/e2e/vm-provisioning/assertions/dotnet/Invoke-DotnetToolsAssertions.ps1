<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Dotnet-tools E2E assertions. The provisioner-side acquirer + DotnetToolsProvider
# (Infrastructure-Vm-Provisioner feature 43, steps 3-6) install global .NET tools
# system-wide under /usr/local/share/dotnet/tools/ with per-command symlinks
# under /usr/local/bin/ and a manifest at
# /var/lib/infra-provisioner/manifests/dotnetTools-{id}-{rawVersion}.json.
#
# This file ships three assertion helpers - install, version-change, removed -
# that mirror the JDK and dotnet SDK assertion files. The interleaved
# integration into phases 1-3 (rather than a standalone four-provision
# scenario) covers:
#
#   - Plan step 1 (install)                       -> phase 1   install assertion
#   - Plan step 4 (regression: no orphan manifests
#     after parent SDK is removed)                -> phase 2a  + phase 3b
#   - Plan step 2 (version change)                -> phase 3a  version-change assertion
#
# Plan step 3 (tools removed while SDK is retained) is intentionally NOT covered
# at E2E level because the existing phase shape has no slot where the SDK stays
# pinned while only dotnetTools is emptied, and inserting one would mean a fifth
# CI provision for a property the provider's Uninstall-Version unit tests already
# guarantee (the provider never touches /opt/dotnet-* or the SDK manifest). The
# walker-orphans regression guard the missing E2E was meant to back up is still
# enforced by phase 2a / phase 3b's "no dotnetTools-*.json leftover" check.
# ---------------------------------------------------------------------------

# Manifest store path. Hardcoded here (not derived from a provisioner-side
# constant) because the E2E agent is a separate process tree and has no
# load-bearing reason to import the provisioner module just for this string.
$script:DotnetToolsManifestStore = '/var/lib/infra-provisioner/manifests'

# tools-root is the public contract of the provider; changing it would break
# every existing manifest's ownedPaths. Hardcoded for the same reason as the
# manifest store path above.
$script:DotnetToolsRoot          = '/usr/local/share/dotnet/tools'

# ---------------------------------------------------------------------------
# Invoke-DotnetToolsInstallAssertions
#   Asserts that a single dotnetTools entry installed cleanly on the VM:
#     I1 - .store dir for {id}/{version} present under the tools root.
#     I2 - /usr/local/bin/{Command} is a symlink that resolves to a shim
#          under the tools root (the shim file lives at $toolsRoot/{cmd},
#          NOT inside .store - see DotnetToolsProvider.Install-Version.ps1).
#     I3 - Invoking the tool via the symlink (non-login bash -c, the shape
#          systemd/sshd-exec uses) exits 0 and reports the expected version.
#     I4 - A dotnetTools-{id}-{rawVersion}.json manifest is present and
#          (after JSON parse) records id, rawVersion, and the expected
#          ownedSymlinks entry.
#     I5 - The parent dotnetSdk manifest's children array references the
#          tool manifest path (walker contract from feature 42 Phase A).
#
#   The version-comparison strategy is `--version` exact-match because the
#   plan pins specific reportgenerator releases. Throws on the first failure
#   with a message naming the VM and the observed value.
# ---------------------------------------------------------------------------

function Invoke-DotnetToolsInstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,

        # NuGet package id, e.g. 'dotnet-reportgenerator-globaltool'. Same
        # string the VM JSON's dotnetTools[].id field carries.
        [Parameter(Mandatory)] [string] $ToolId,

        # Exact pinned version, e.g. '5.4.4'. Matched against `--version`
        # output (exact equality) and used to derive both the .store path
        # and the manifest filename.
        [Parameter(Mandatory)] [string] $ToolVersion,

        # Command name the tool installs - same string DotnetToolsProvider
        # records under manifest.commands and under /usr/local/bin/{cmd}.
        [Parameter(Mandatory)] [string] $Command
    )

    $storeDir    = "$($script:DotnetToolsRoot)/.store/$ToolId/$ToolVersion"
    $shimPath    = "$($script:DotnetToolsRoot)/$Command"
    $symlinkPath = "/usr/local/bin/$Command"
    $manifestPath = "$($script:DotnetToolsManifestStore)/dotnetTools-$ToolId-$ToolVersion.json"

    # I1) .store dir present. test -d is the cheapest probe.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -d ''$storeDir'' && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Store-dir probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $state = $result.Output.Trim()
    if ($state -ne 'present') {
        throw "Expected $storeDir present on $VmName, probe reported '$state'. " +
            "DotnetToolsProvider.Install-Version did not produce the .store entry."
    }
    Write-Host "  [OK] I1: store dir present: $storeDir" -ForegroundColor Green

    # I2) /usr/local/bin/{cmd} symlink resolves to the tools-root shim. The
    #     shim file is what `dotnet tool install --tool-path` writes at the
    #     tools-root; the .store/ dir holds the assembly that the shim loads.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -L ''$symlinkPath'' && readlink -f ''$symlinkPath'' || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Symlink probe for $symlinkPath failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $resolved = $result.Output.Trim()
    if ($resolved -eq 'absent') {
        throw "Symlink $symlinkPath missing on $VmName. Non-login shells " +
            "(systemd, sshd command exec) cannot find the tool."
    }
    if ($resolved -ne $shimPath) {
        throw "Symlink $symlinkPath on $VmName resolved to '$resolved', " +
            "expected '$shimPath'. The shim is the only valid target."
    }
    Write-Host "  [OK] I2: $symlinkPath -> $shimPath" -ForegroundColor Green

    # I3) Tool launches under the apphost. `bash -c` is a non-login
    #     non-interactive shell - the shape systemd units and
    #     `ssh user@host command` use - which is exactly the case the
    #     /usr/local/bin/ symlink is for. A regression that puts the
    #     tool only on the login-shell PATH (e.g. profile.d only) would
    #     fail here, as would a regression that breaks
    #     /etc/dotnet/install_location and stops the apphost from
    #     finding the runtime.
    #
    #     Probe shape: invoke the tool with NO arguments and check that
    #     it did NOT exit 131. Exit 131 is the apphost's
    #         "You must install .NET to run this application"
    #     code, which is exactly the load-bearing failure this assertion
    #     guards against. Any other exit code means the apphost found
    #     the runtime and handed control to the tool's main entry point,
    #     even if the tool then complained about missing required args.
    #     Banner-based version probing is intentionally NOT done here:
    #     not every tool prints a startup banner with no args
    #     (reportgenerator 5.x prints only timestamped log lines), and
    #     the right-version check is already covered by I1 / I4 / I5.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c '$Command 2>&1'"
    if ($result.ExitStatus -eq 131) {
        throw "$Command on $VmName failed with apphost exit 131 " +
            "(`"must install .NET`"). The runtime-discovery hint at " +
            "/etc/dotnet/install_location is missing or stale - the " +
            "apphost cannot find the SDK install dir. Output: " +
            $result.Output
    }
    Write-Host ("  [OK] I3: $Command launched under the apphost " +
        "(exit $($result.ExitStatus))") -ForegroundColor Green

    # I4) Manifest present. The manifest is the reconciler's truth source;
    #     missing means uninstall and version-change cannot work.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -f ''$manifestPath'' && sudo cat ''$manifestPath'' || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Manifest probe for $manifestPath failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $manifestRaw = $result.Output
    if ($manifestRaw.Trim() -eq 'absent') {
        throw "Manifest $manifestPath missing on $VmName. The reconciler's " +
            "truth source for the tool install is gone."
    }
    $manifest = $null
    try {
        $manifest = $manifestRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Manifest at $manifestPath on $VmName is not valid JSON: $_"
    }
    if ($manifest.id -ne $ToolId) {
        throw "Manifest at $manifestPath on $VmName has id '$($manifest.id)', " +
            "expected '$ToolId'."
    }
    if ($manifest.rawVersion -ne $ToolVersion) {
        throw "Manifest at $manifestPath on $VmName has rawVersion " +
            "'$($manifest.rawVersion)', expected '$ToolVersion'."
    }
    # ownedSymlinks is the load-bearing field for Uninstall-Version; if it
    # is missing or empty the next uninstall will leave /usr/local/bin/
    # entries orphaned.
    $symlinkTargets = @($manifest.ownedSymlinks | ForEach-Object { $_.path })
    if ($symlinkTargets -notcontains $symlinkPath) {
        throw "Manifest at $manifestPath on $VmName does not record " +
            "ownedSymlinks entry '$symlinkPath'. Got: $($symlinkTargets -join ', ')"
    }
    Write-Host "  [OK] I4: manifest present and well-formed" -ForegroundColor Green

    # I5) Parent SDK manifest's children array references this tool's
    #     manifest path (walker contract). The SDK manifest filename
    #     embeds the SDK's resolved version, so we glob and pick the
    #     single match.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'ls -1 $($script:DotnetToolsManifestStore)/" +
                   "dotnetSdk-*.json'")
    if ($result.ExitStatus -ne 0) {
        throw "SDK manifest listing failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $sdkManifestPaths = @(($result.Output -split "`n") | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object { $_.Trim() })
    if ($sdkManifestPaths.Count -ne 1) {
        throw "Expected exactly one dotnetSdk manifest on $VmName, " +
            "found $($sdkManifestPaths.Count): $($sdkManifestPaths -join ', ')."
    }
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "sudo cat '$($sdkManifestPaths[0])'"
    if ($result.ExitStatus -ne 0) {
        throw "Reading SDK manifest $($sdkManifestPaths[0]) failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $sdkManifest = $null
    try {
        $sdkManifest = $result.Output | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "SDK manifest at $($sdkManifestPaths[0]) on $VmName is not " +
            "valid JSON: $_"
    }
    $childManifestPaths = @($sdkManifest.children | ForEach-Object {
        if ($_ -is [string]) { $_ } else { $_.manifestPath }
    })
    if ($childManifestPaths -notcontains $manifestPath) {
        throw "SDK manifest at $($sdkManifestPaths[0]) on $VmName does not " +
            "reference child manifest '$manifestPath'. " +
            "children: $($childManifestPaths -join ', '). " +
            "Walker will not be able to dispatch this child on parent uninstall."
    }
    Write-Host "  [OK] I5: parent SDK manifest references child manifest" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Invoke-DotnetToolsVersionChangeAssertions
#   Asserts that flipping a dotnetTools entry's `version` produced a clean
#   swap (not a parallel install):
#     V1 - Old .store/{id}/{previous}/ dir is gone.
#     V2 - New .store/{id}/{new}/ dir is present.
#     V3 - Old manifest file is gone; new manifest file is present.
#     V4 - /usr/local/bin/{cmd} symlink is still present (the shim filename
#          is stable across versions, so version-change does NOT retarget
#          the symlink - it overwrites the shim in place. A regression that
#          deletes the symlink during the old uninstall and forgets to
#          recreate it would fail here).
#
#   Caller is expected to follow this with Invoke-DotnetToolsInstallAssertions
#   against the new version, which covers --version output + manifest contents
#   + the parent's children array.
# ---------------------------------------------------------------------------

function Invoke-DotnetToolsVersionChangeAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $ToolId,
        [Parameter(Mandatory)] [string] $PreviousVersion,
        [Parameter(Mandatory)] [string] $NewVersion,
        [Parameter(Mandatory)] [string] $Command
    )

    $oldStore        = "$($script:DotnetToolsRoot)/.store/$ToolId/$PreviousVersion"
    $newStore        = "$($script:DotnetToolsRoot)/.store/$ToolId/$NewVersion"
    $oldManifest     = "$($script:DotnetToolsManifestStore)/dotnetTools-$ToolId-$PreviousVersion.json"
    $newManifest     = "$($script:DotnetToolsManifestStore)/dotnetTools-$ToolId-$NewVersion.json"
    $symlinkPath     = "/usr/local/bin/$Command"

    # V1) Old .store entry gone.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -d ''$oldStore'' && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Old store-dir probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $state = $result.Output.Trim()
    if ($state -ne 'absent') {
        throw "Old .store dir still present on $VmName ($oldStore). " +
            "Version change did not uninstall the previous tool version."
    }
    Write-Host "  [OK] V1: old store dir removed ($oldStore)" -ForegroundColor Green

    # V2) New .store entry present.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -d ''$newStore'' && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "New store-dir probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $state = $result.Output.Trim()
    if ($state -ne 'present') {
        throw "New .store dir not present on $VmName ($newStore). " +
            "Version change uninstalled the old version but did not install " +
            "the new one."
    }
    Write-Host "  [OK] V2: new store dir present ($newStore)" -ForegroundColor Green

    # V3) Old manifest gone, new manifest present. Both checks at once via
    #     two probes so the diagnostic names which side failed.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -f ''$oldManifest'' && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Old manifest probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    if ($result.Output.Trim() -ne 'absent') {
        throw "Old manifest still present on $VmName ($oldManifest). " +
            "Next reconciliation will re-attempt teardown of an already-gone tool."
    }
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -f ''$newManifest'' && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "New manifest probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    if ($result.Output.Trim() -ne 'present') {
        throw "New manifest not present on $VmName ($newManifest). " +
            "Version change did not write the new truth-source record."
    }
    Write-Host "  [OK] V3: manifest swap clean ($oldManifest -> $newManifest)" `
        -ForegroundColor Green

    # V4) Symlink still present. The shim filename is stable across
    #     versions, so version-change overwrites the shim in place rather
    #     than retargeting the symlink. A regression that removes the
    #     symlink during the old uninstall and forgets to recreate it (the
    #     install path's idempotence makes this easy to miss) would fail
    #     here.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -L ''$symlinkPath'' && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Symlink probe for $symlinkPath failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    if ($result.Output.Trim() -ne 'present') {
        throw "Symlink $symlinkPath gone on $VmName after version change. " +
            "Non-login shells will lose access to the tool."
    }
    Write-Host "  [OK] V4: symlink survives version change ($symlinkPath)" `
        -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Invoke-DotnetToolsUninstallAssertions
#   Asserts the tool removal path produced no orphans:
#     U1 - .store entries for the tool (any version) are gone.
#     U2 - /usr/local/bin/{cmd} symlink removed.
#     U3 - No dotnetTools-*.json manifest remains for the tool id (across
#          any version - guards the orphan-after-walker case the plan's
#          step 7 step 4 regression guard cares about).
#
#   ToolVersion is optional: when supplied, U3 asserts no manifest with
#   that exact rawVersion remains; when omitted, U3 asserts no manifest
#   for the id remains across any version.
# ---------------------------------------------------------------------------

function Invoke-DotnetToolsUninstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $ToolId,
        [Parameter(Mandatory)] [string] $Command
    )

    $storeRoot   = "$($script:DotnetToolsRoot)/.store/$ToolId"
    $symlinkPath = "/usr/local/bin/$Command"

    # U1) No .store entry left under the tool's id (any version). test -d
    #     on the parent id-dir: dotnet tool uninstall removes the
    #     per-version subdir, but a regression that left the parent dir
    #     behind would be a noisy soft leak.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -e ''$storeRoot'' && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Store-root probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    if ($result.Output.Trim() -ne 'absent') {
        throw "Store entry for $ToolId still present on $VmName ($storeRoot). " +
            "Uninstall did not clean up the tool's .store entry."
    }
    Write-Host "  [OK] U1: no store entry for $ToolId" -ForegroundColor Green

    # U2) Symlink gone. test -L matches even if the target is missing,
    #     which is the orphan state Uninstall-Version explicitly avoids
    #     (it removes the symlink only when its target still points into
    #     the tools dir).
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -L ''$symlinkPath'' && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Symlink probe for $symlinkPath failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    if ($result.Output.Trim() -ne 'absent') {
        throw "Symlink $symlinkPath still present on $VmName. Uninstall " +
            "left the /usr/local/bin/ entry orphaned."
    }
    Write-Host "  [OK] U2: symlink removed ($symlinkPath)" -ForegroundColor Green

    # U3) No dotnetTools-*.json manifest left for the id. The glob
    #     embeds the id so a manifest for a sibling tool (none in this
    #     scenario, but cheap to be specific) is not falsely flagged.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'ls -1 $($script:DotnetToolsManifestStore)/" +
                   "dotnetTools-$ToolId-*.json 2>/dev/null || true'")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest leftover probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $leftover = $result.Output.Trim()
    if (-not [string]::IsNullOrEmpty($leftover)) {
        throw "Leftover dotnetTools manifest(s) on ${VmName}: $leftover. " +
            "The walker (or the explicit tool uninstall path) left orphan " +
            "manifests behind - the next reconciliation will fail on a " +
            "tool whose .store entry no longer exists."
    }
    Write-Host "  [OK] U3: no dotnetTools-$ToolId-*.json manifest leftover" `
        -ForegroundColor Green
}
