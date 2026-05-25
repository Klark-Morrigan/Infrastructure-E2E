<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-JdkUninstallAssertions
#   Asserts the JDK removal path applied by the reconciler's JdkProvider
#   (feature 42) after the operator drops the 'javaDevKit' field from the
#   VM JSON (or sets it to null / @()). The legacy uninstall flag was
#   superseded by feature 42 - removal is now expressed as a desired-state
#   change in the JSON, not a sticky flag.
#
#   Checks:
#     A1 - /opt/jdk-{vendor}-* glob produces no matches.
#     A2 - /etc/profile.d/jdk.sh does not exist.
#     A3 - JAVA_HOME no longer set in a login shell.
#     A4 - 'java' no longer on PATH for login OR non-login shells. Non-login
#          matters because the install path used /usr/local/bin symlinks
#          that survive a login-shell-only cleanup.
#     A5 - No stale /usr/local/bin symlinks pointing into the removed
#          /opt/jdk-{vendor}-* directory.
#     A6 - No javaDevKit-*.json manifest under
#          /var/lib/infra-provisioner/manifests/. The manifest is the
#          reconciler's truth source; a leftover here would cause the
#          next reconciliation to re-uninstall (or fail) on already-gone
#          artifacts.
#
#   Throws on the first failure with a message naming the VM and the
#   observed value. The outer try/finally in Invoke-VmProvisioningTest still
#   runs teardown.
#
#   $InstallPrefix is passed in so the caller decides what vendor prefix is
#   expected on disk (symmetric with Invoke-JdkInstallAssertions).
# ---------------------------------------------------------------------------

function Invoke-JdkUninstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # Expected on-disk install prefix, e.g. '/opt/jdk-temurin-'. Used
        # for the glob check (A1) and the symlink-target check (A5).
        [Parameter(Mandatory)]
        [string] $InstallPrefix
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

    # A2) Profile snippet gone. test -e prints 'present' / 'absent' so a
    #     non-zero exit from test -e itself is not conflated with "still
    #     there".
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -e /etc/profile.d/jdk.sh && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Profile-snippet probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $profileState = $result.Output.Trim()
    if ($profileState -ne 'absent') {
        throw "/etc/profile.d/jdk.sh still present on $VmName " +
            "(probe reported '$profileState')."
    }
    Write-Host '  [OK] A2: /etc/profile.d/jdk.sh removed' -ForegroundColor Green

    # A3) JAVA_HOME no longer set in a login shell. Login shell so the
    #     check covers any rc-file mechanism that might have re-exported
    #     JAVA_HOME beyond /etc/profile.d/jdk.sh.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  'bash -lc ''echo "${JAVA_HOME:-unset}"'''
    if ($result.ExitStatus -ne 0) {
        throw "JAVA_HOME probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $javaHome = $result.Output.Trim()
    if ($javaHome -ne 'unset') {
        throw "JAVA_HOME still set on $VmName (got '$javaHome', expected 'unset')."
    }
    Write-Host '  [OK] A3: JAVA_HOME unset in login shell' -ForegroundColor Green

    # A4) 'java' off PATH for both shell types. Login shell catches profile
    #     wiring; non-login catches the /usr/local/bin symlink path used by
    #     the installer. '|| true' so a missing 'java' (the desired state)
    #     does not propagate non-zero through to ExitStatus.
    foreach ($shellTag in @('login', 'non-login')) {
        $cmd = if ($shellTag -eq 'login') {
            'bash -lc ''command -v java || true'''
        } else {
            'bash -c ''command -v java || true'''
        }
        $result = Invoke-SshClientCommand -SshClient $SshClient -Command $cmd
        if ($result.ExitStatus -ne 0) {
            throw "'java' lookup ($shellTag shell) failed on $VmName " +
                "(exit $($result.ExitStatus)): $($result.Error)"
        }
        $resolved = $result.Output.Trim()
        if (-not [string]::IsNullOrEmpty($resolved)) {
            throw "'java' still on PATH for $shellTag shell on $VmName " +
                "(resolved to '$resolved')."
        }
        Write-Host "  [OK] A4: java absent from $shellTag PATH" `
            -ForegroundColor Green
    }

    # A5) No /usr/local/bin symlinks pointing into the removed install dir.
    #     find with -lname matches the symlink target text directly, so
    #     orphaned symlinks (whose targets no longer exist) are still
    #     visible - which is exactly the state Uninstall-Jdk must avoid.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("find /usr/local/bin -maxdepth 1 -type l " +
                   "-lname '${InstallPrefix}*'")
    if ($result.ExitStatus -ne 0) {
        throw "Stale-symlink check failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $staleLinks = $result.Output.Trim()
    if (-not [string]::IsNullOrEmpty($staleLinks)) {
        throw "Stale /usr/local/bin symlinks still point into $InstallPrefix* " +
            "on ${VmName}: $staleLinks"
    }
    Write-Host '  [OK] A5: no stale /usr/local/bin symlinks' -ForegroundColor Green

    # A6) No leftover manifest. ls -1 on the provider-scoped glob: exit 0 +
    #     empty output = removed, exit 2 (no match) also = removed. Any
    #     printed path is a leak.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'ls -1 /var/lib/infra-provisioner/manifests/" +
                   "javaDevKit-*.json 2>/dev/null || true'")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest leftover probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $leftover = $result.Output.Trim()
    if (-not [string]::IsNullOrEmpty($leftover)) {
        throw "Leftover JDK manifest(s) on ${VmName}: $leftover. " +
            "The reconciler's truth source still claims an install - the " +
            "next reconciliation will re-attempt teardown."
    }
    Write-Host '  [OK] A6: no javaDevKit-*.json manifest leftover' `
        -ForegroundColor Green
}
