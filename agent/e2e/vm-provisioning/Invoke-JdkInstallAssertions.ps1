<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-JdkInstallAssertions
#   Asserts the JDK path applied by Invoke-JdkAcquisition + cloud-init landed
#   correctly on the VM:
#     - JAVA_HOME is set under /opt/jdk-temurin-* in a login shell.
#     - 'java' is on PATH for both login (bash -lc) and non-login (bash -c)
#       shells. The non-login check matters because 'ssh user@host command'
#       and systemd services run as non-login shells.
#     - 'java -version' exits 0 and reports a build whose prefix matches the
#       requested version. Prefix match (not equality) because the resolver
#       legitimately upgrades "21" to a concrete build like "21.0.6+7".
#     - A manifest file exists under /var/lib/infra-provisioner/manifests/
#       matching javaDevKit-*.json. The manifest is the reconciler's truth
#       source for "what is installed"; an install that left no manifest
#       cannot be uninstalled or version-changed by future runs.
#
#   Throws on the first failure with a message naming the VM and the observed
#   value. The outer try/finally in Invoke-VmProvisioningTest still runs
#   teardown.
#
#   $InstallPrefix is passed in (rather than read from a script-scope global)
#   so this function is self-contained and unit-testable in isolation - the
#   caller decides what vendor prefix is expected on disk.
# ---------------------------------------------------------------------------

function Invoke-JdkInstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # The operator-requested version string from the vault entry's
        # javaDevKit.version. Used as the prefix the reported build must match.
        [Parameter(Mandatory)]
        [string] $RequestedVersion,

        # Expected on-disk install prefix, e.g. '/opt/jdk-temurin-'. Both
        # JAVA_HOME and the resolved 'java' binary must live under this.
        [Parameter(Mandatory)]
        [string] $InstallPrefix
    )

    # 1) JAVA_HOME under a login shell - confirms /etc/profile.d/jdk.sh
    #    written by cloud-init was sourced.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'bash -lc ''echo $JAVA_HOME'''
    if ($result.ExitStatus -ne 0) {
        throw "echo \$JAVA_HOME failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $javaHome = $result.Output.Trim()
    if ([string]::IsNullOrEmpty($javaHome) -or
        -not $javaHome.StartsWith($InstallPrefix)) {
        throw "Unexpected JAVA_HOME on $VmName" +
            " (expected prefix '$InstallPrefix', got '$javaHome')."
    }
    Write-Host "  [OK] JAVA_HOME: $javaHome" -ForegroundColor Green

    # 2a) 'java' on PATH for login shells.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'bash -lc ''command -v java'''
    if ($result.ExitStatus -ne 0) {
        throw "command -v java (login shell) failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $javaPathLogin = $result.Output.Trim()
    $expectedBin   = "$javaHome/bin/java"
    if ($javaPathLogin -ne $expectedBin) {
        throw "java on login PATH for $VmName resolved to '$javaPathLogin'," +
            " expected '$expectedBin'."
    }
    Write-Host "  [OK] login PATH java: $javaPathLogin" -ForegroundColor Green

    # 2b) 'java' on PATH for non-login shells - the case that breaks first
    #     if jdk.sh is wired only into login shells. The implementation may
    #     reach non-login shells via /usr/local/bin symlinks (which is what
    #     the provisioner does), so command -v's return value is a symlink
    #     path. readlink -f follows it to the real install location for
    #     the prefix check.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command 'bash -c ''p=$(command -v java) && readlink -f "$p"'''
    if ($result.ExitStatus -ne 0) {
        throw "command -v java (non-login shell) failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $javaPathNonLogin = $result.Output.Trim()
    if (-not $javaPathNonLogin.StartsWith($InstallPrefix)) {
        throw "java on non-login PATH for $VmName resolved (after symlink " +
            "follow) to '$javaPathNonLogin', expected a path under " +
            "'$InstallPrefix'."
    }
    Write-Host "  [OK] non-login PATH java: $javaPathNonLogin" `
        -ForegroundColor Green

    # 3) 'java -version' - java writes to stderr, so redirect to stdout for
    #    the prefix check. Prefix match defends the operator-requested
    #    version, not the resolver's concrete pin (which lives in the host
    #    lockfile).
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'java -version 2>&1'
    if ($result.ExitStatus -ne 0) {
        throw "java -version failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $versionOutput = $result.Output.Trim()
    # Anchor the prefix check inside the openjdk version "..." string so
    # "21" cannot accidentally match "2025-01-21" in the build date line.
    # Pattern: version "<requested>(.|+|") - i.e. either an exact match or
    # a deeper-granularity build whose prefix still equals the request.
    $versionPattern = 'version\s+"' +
        [regex]::Escape($RequestedVersion) + '(\.|\+|")'
    if ($versionOutput -notmatch $versionPattern) {
        throw "java -version on $VmName did not report requested version " +
            "'$RequestedVersion'. Output: $versionOutput"
    }
    $firstLine = ($versionOutput -split "`n" | Select-Object -First 1).Trim()
    Write-Host "  [OK] java -version reports '$RequestedVersion': $firstLine" `
        -ForegroundColor Green

    # 4) Manifest file present under the reconciler store. ls -1 of the
    #    provider-scoped glob: exit 0 + one or more lines = manifest(s)
    #    written; exit 2 (no match) = the install path skipped the
    #    manifest write, which is the regression this check guards.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'ls -1 /var/lib/infra-provisioner/manifests/" +
                   "javaDevKit-*.json 2>/dev/null'")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest glob probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $manifestPaths = ($result.Output -split "`n" | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object { $_.Trim() })
    if (@($manifestPaths).Count -lt 1) {
        throw "No JDK manifest file under " +
            "/var/lib/infra-provisioner/manifests/ on $VmName. " +
            "The reconciler's truth source is missing - uninstall and " +
            "version-change paths will not work on the next run."
    }
    Write-Host "  [OK] manifest present: $($manifestPaths -join ', ')" `
        -ForegroundColor Green
}
