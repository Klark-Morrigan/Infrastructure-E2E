<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-JdkUninstallAssertions
#   Asserts the JDK removal path applied by Uninstall-Jdk + the dispatch in
#   Invoke-VmPostProvisioning emptied the install dir, dropped the profile
#   snippet, and pruned stale /usr/local/bin symlinks on the VM:
#     A1 - /opt/jdk-{vendor}-* glob produces no matches.
#     A2 - /etc/profile.d/jdk.sh does not exist.
#     A3 - JAVA_HOME no longer set in a login shell.
#     A4 - 'java' no longer on PATH for login OR non-login shells. Non-login
#          matters because the install path used /usr/local/bin symlinks
#          that survive a login-shell-only cleanup.
#     A5 - No stale /usr/local/bin symlinks pointing into the removed
#          /opt/jdk-{vendor}-* directory.
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
}
