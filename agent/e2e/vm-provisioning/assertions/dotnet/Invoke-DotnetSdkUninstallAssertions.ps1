<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-DotnetSdkUninstallAssertions
#   Asserts the .NET SDK removal path applied by the reconciler's
#   DotnetSdkProvider after the operator drops the 'dotnetSdk' field from
#   the VM JSON (or sets it to null / @()). Mirror of
#   Invoke-JdkUninstallAssertions.
#
#   Checks:
#     A1 - /opt/dotnet-* glob produces no matches.
#     A2 - /etc/profile.d/dotnet.sh does not exist.
#     A3 - DOTNET_ROOT no longer set in a login shell.
#     A4 - 'dotnet' no longer on PATH for login OR non-login shells. Non-login
#          matters because the install path used a /usr/local/bin/dotnet
#          symlink that survives a login-shell-only cleanup.
#     A5 - /usr/local/bin/dotnet symlink is gone (not just orphaned). The
#          install only ever creates one symlink, so this is a presence
#          check rather than a target-prefix scan.
#     A6 - No '<manifest-file-prefix>*.json' manifest under the manifest
#          store. The manifest is the engine's truth source; a leftover
#          here would cause the next reconciliation to re-uninstall (or
#          fail) on already-gone artefacts.
#
#   The manifest store dir and filename prefix are engine parameters with
#   PowerShell-reconciler defaults (symmetric with
#   Invoke-DotnetSdkInstallAssertions).
#
#   Throws on the first failure with a message naming the VM and the
#   observed value. The outer try/finally in Invoke-VmProvisioningTest still
#   runs teardown.
# ---------------------------------------------------------------------------

function Invoke-DotnetSdkUninstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # Expected on-disk install prefix, e.g. '/opt/dotnet-'. Used for
        # the glob check (A1).
        [Parameter(Mandatory)]
        [string] $InstallPrefix,

        # Manifest store directory, no trailing slash.
        [string] $ManifestStoreDir = '/var/lib/infra-provisioner/manifests',

        # Manifest filename prefix; the store is probed with the glob
        # '<prefix>*.json'. The Ansible engine passes 'dotnet_sdk-'.
        [string] $ManifestFilePrefix = 'dotnetSdk-'
    )

    # A1) Install dir gone. shopt -s nullglob so 'ls -d' on an empty glob
    #     does not emit the literal pattern - the count must be 0.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'shopt -s nullglob; " +
                   "arr=( ${InstallPrefix}* ); echo `${#arr[@]}'")
    if ($result.ExitStatus -ne 0) {
        throw "Install-dir glob check failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $matchCount = [int]($result.Output.Trim())
    if ($matchCount -ne 0) {
        throw "Install dirs still present on $VmName " +
            "(expected 0 matches under '$InstallPrefix*', got $matchCount)."
    }
    Write-Host "  [OK] A1: no $InstallPrefix* directories remain" `
        -ForegroundColor Green

    # A2) Profile snippet gone.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -e /etc/profile.d/dotnet.sh && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Profile-snippet probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $profileState = $result.Output.Trim()
    if ($profileState -ne 'absent') {
        throw "/etc/profile.d/dotnet.sh still present on $VmName " +
            "(probe reported '$profileState')."
    }
    Write-Host '  [OK] A2: /etc/profile.d/dotnet.sh removed' -ForegroundColor Green

    # A3) DOTNET_ROOT no longer set in a login shell. Login shell so the
    #     check covers any rc-file mechanism that might have re-exported
    #     DOTNET_ROOT beyond /etc/profile.d/dotnet.sh.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  'bash -lc ''echo "${DOTNET_ROOT:-unset}"'''
    if ($result.ExitStatus -ne 0) {
        throw "DOTNET_ROOT probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $dotnetRoot = $result.Output.Trim()
    if ($dotnetRoot -ne 'unset') {
        throw "DOTNET_ROOT still set on $VmName (got '$dotnetRoot', expected 'unset')."
    }
    Write-Host '  [OK] A3: DOTNET_ROOT unset in login shell' -ForegroundColor Green

    # A4) 'dotnet' off PATH for both shell types. '|| true' so a missing
    #     'dotnet' (the desired state) does not propagate non-zero through
    #     to ExitStatus.
    foreach ($shellTag in @('login', 'non-login')) {
        $cmd = if ($shellTag -eq 'login') {
            'bash -lc ''command -v dotnet || true'''
        } else {
            'bash -c ''command -v dotnet || true'''
        }
        $result = Invoke-SshClientCommand -SshClient $SshClient -Command $cmd
        if ($result.ExitStatus -ne 0) {
            throw "'dotnet' lookup ($shellTag shell) failed on $VmName " +
                "(exit $($result.ExitStatus)): $($result.Error)"
        }
        $resolved = $result.Output.Trim()
        if (-not [string]::IsNullOrEmpty($resolved)) {
            throw "'dotnet' still on PATH for $shellTag shell on $VmName " +
                "(resolved to '$resolved')."
        }
        Write-Host "  [OK] A4: dotnet absent from $shellTag PATH" `
            -ForegroundColor Green
    }

    # A5) /usr/local/bin/dotnet symlink gone. test -L matches a symlink
    #     even if its target is missing - exactly the orphan state the
    #     uninstall must avoid leaving behind.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -L /usr/local/bin/dotnet && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Symlink probe for /usr/local/bin/dotnet failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $linkState = $result.Output.Trim()
    if ($linkState -ne 'absent') {
        throw "/usr/local/bin/dotnet symlink still present on $VmName " +
            "(probe reported '$linkState')."
    }
    Write-Host '  [OK] A5: /usr/local/bin/dotnet symlink removed' `
        -ForegroundColor Green

    # A5b) /etc/dotnet/install_location is gone. A leftover file would
    #      point the apphost at the now-deleted /opt/dotnet-<version>
    #      and break any subsequent dotnet-tool invocation. The parent
    #      /etc/dotnet/ dir is intentionally left behind (shared with
    #      other tooling); only the file is removed.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -e /etc/dotnet/install_location && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "/etc/dotnet/install_location probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $locState = $result.Output.Trim()
    if ($locState -ne 'absent') {
        throw "/etc/dotnet/install_location still present on $VmName " +
            "(probe reported '$locState'). The apphost runtime-discovery " +
            "hint outlived its SDK install."
    }
    Write-Host '  [OK] A5b: /etc/dotnet/install_location removed' `
        -ForegroundColor Green

    # A6) No leftover manifest. Any printed path is a leak.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'ls -1 $ManifestStoreDir/" +
                   "$ManifestFilePrefix*.json 2>/dev/null || true'")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest leftover probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $leftover = $result.Output.Trim()
    if (-not [string]::IsNullOrEmpty($leftover)) {
        throw "Leftover dotnet SDK manifest(s) on ${VmName}: $leftover. " +
            "The engine's truth source still claims an install - the " +
            "next reconciliation will re-attempt teardown."
    }
    Write-Host "  [OK] A6: no $ManifestFilePrefix*.json manifest leftover" `
        -ForegroundColor Green
}
