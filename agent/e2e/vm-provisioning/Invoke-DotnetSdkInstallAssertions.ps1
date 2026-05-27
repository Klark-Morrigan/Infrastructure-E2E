<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-DotnetSdkInstallAssertions
#   Asserts the .NET SDK path applied by the reconciler's DotnetSdkProvider
#   landed correctly on the VM:
#     - DOTNET_ROOT is set under /opt/dotnet-* in a login shell.
#     - 'dotnet' is on PATH for both login (bash -lc) and non-login (bash -c)
#       shells. Non-login matters because 'ssh user@host command' and systemd
#       services run as non-login shells.
#     - 'dotnet --version' exits 0 and reports the resolved SDK version.
#       Resolver-exact match here (not prefix) because dotnet's --version
#       output is just the SDK build (e.g. '10.0.100') with no surrounding
#       text.
#     - DOTNET_CLI_TELEMETRY_OPTOUT is set to 1 in a login shell - the
#       opt-out is per-shell so the provisioner writes it into profile.d.
#     - A manifest file exists under /var/lib/infra-provisioner/manifests/
#       matching dotnetSdk-*.json. The manifest is the reconciler's truth
#       source for "what is installed"; an install that left no manifest
#       cannot be uninstalled or version-changed by future runs.
#
#   Throws on the first failure with a message naming the VM and the observed
#   value. The outer try/finally in Invoke-VmProvisioningTest still runs
#   teardown.
#
#   Mirror of Invoke-JdkInstallAssertions - any behavioural change here likely
#   needs to apply there too. Differences from the JDK assertions:
#     - Single binary symlink (dotnet driver), not per-binary.
#     - DOTNET_ROOT (not JAVA_HOME) is the env var the SDK uses to locate
#       shared frameworks.
#     - Extra telemetry-opt-out check.
# ---------------------------------------------------------------------------

function Invoke-DotnetSdkInstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # The resolver's concrete pin (e.g. '10.0.100'). dotnet --version
        # reports this exactly; no prefix gymnastics like JDK needs because
        # the resolver always lands on a feature-band build.
        [Parameter(Mandatory)]
        [string] $ResolvedVersion,

        # Expected on-disk install prefix, e.g. '/opt/dotnet-'. Both
        # DOTNET_ROOT and the resolved 'dotnet' binary must live under this.
        [Parameter(Mandatory)]
        [string] $InstallPrefix
    )

    # 1) DOTNET_ROOT under a login shell - confirms /etc/profile.d/dotnet.sh
    #    written by the install was sourced.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'bash -lc ''echo $DOTNET_ROOT'''
    if ($result.ExitStatus -ne 0) {
        throw "echo \$DOTNET_ROOT failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $dotnetRoot = $result.Output.Trim()
    if ([string]::IsNullOrEmpty($dotnetRoot) -or
        -not $dotnetRoot.StartsWith($InstallPrefix)) {
        throw "Unexpected DOTNET_ROOT on $VmName" +
            " (expected prefix '$InstallPrefix', got '$dotnetRoot')."
    }
    Write-Host "  [OK] DOTNET_ROOT: $dotnetRoot" -ForegroundColor Green

    # 2a) 'dotnet' on PATH for login shells.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'bash -lc ''command -v dotnet'''
    if ($result.ExitStatus -ne 0) {
        throw "command -v dotnet (login shell) failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $dotnetPathLogin = $result.Output.Trim()
    $expectedBin     = "$dotnetRoot/dotnet"
    if ($dotnetPathLogin -ne $expectedBin) {
        throw "dotnet on login PATH for $VmName resolved to '$dotnetPathLogin'," +
            " expected '$expectedBin'."
    }
    Write-Host "  [OK] login PATH dotnet: $dotnetPathLogin" -ForegroundColor Green

    # 2b) 'dotnet' on PATH for non-login shells - the case that breaks first
    #     if dotnet.sh is wired only into login shells. The install reaches
    #     non-login shells via the /usr/local/bin/dotnet symlink; readlink -f
    #     follows it to the real install location for the prefix check.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command 'bash -c ''p=$(command -v dotnet) && readlink -f "$p"'''
    if ($result.ExitStatus -ne 0) {
        throw "command -v dotnet (non-login shell) failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $dotnetPathNonLogin = $result.Output.Trim()
    if (-not $dotnetPathNonLogin.StartsWith($InstallPrefix)) {
        throw "dotnet on non-login PATH for $VmName resolved (after symlink " +
            "follow) to '$dotnetPathNonLogin', expected a path under " +
            "'$InstallPrefix'."
    }
    Write-Host "  [OK] non-login PATH dotnet: $dotnetPathNonLogin" `
        -ForegroundColor Green

    # 3) 'dotnet --version' - prints exactly the resolved SDK build. Exact
    #    match because the resolver pins the feature-band build host-side
    #    and the manifest records the same string.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'dotnet --version'
    if ($result.ExitStatus -ne 0) {
        throw "dotnet --version failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $reportedVersion = $result.Output.Trim()
    if ($reportedVersion -ne $ResolvedVersion) {
        throw "dotnet --version on $VmName reported '$reportedVersion', " +
            "expected '$ResolvedVersion'."
    }
    Write-Host "  [OK] dotnet --version: $reportedVersion" -ForegroundColor Green

    # 4) Telemetry opt-out flag wired into profile.d. Unattended CI VMs
    #    have no operator to consent to telemetry; a regression that drops
    #    the export would silently re-enable it.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command 'bash -lc ''echo $DOTNET_CLI_TELEMETRY_OPTOUT'''
    if ($result.ExitStatus -ne 0) {
        throw "echo \$DOTNET_CLI_TELEMETRY_OPTOUT failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $telemetryOptOut = $result.Output.Trim()
    if ($telemetryOptOut -ne '1') {
        throw "DOTNET_CLI_TELEMETRY_OPTOUT on $VmName is '$telemetryOptOut'," +
            " expected '1'. profile.d/dotnet.sh was not sourced or was rewritten."
    }
    Write-Host "  [OK] DOTNET_CLI_TELEMETRY_OPTOUT=1" -ForegroundColor Green

    # 4b) /etc/dotnet/install_location points at the install dir. This
    #     is Microsoft's documented apphost runtime-discovery hint for
    #     SDKs installed outside /usr/share/dotnet, and the only thing
    #     that lets `dotnet tool` shims invoked from a non-login shell
    #     (sshd command exec, systemd, cron) find the runtime. A
    #     regression that drops the write surfaces here as either a
    #     missing file or a stale path pointing at a now-gone install.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  'sudo cat /etc/dotnet/install_location'
    if ($result.ExitStatus -ne 0) {
        throw "Reading /etc/dotnet/install_location failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error). The apphost " +
            "runtime-discovery hint is missing - dotnet tool shims will " +
            "fail with 'You must install .NET to run this application'."
    }
    $installLocation = $result.Output.Trim()
    if ($installLocation -ne $dotnetRoot) {
        throw "/etc/dotnet/install_location on $VmName is '$installLocation', " +
            "expected '$dotnetRoot' (the DOTNET_ROOT value already verified " +
            "above). The runtime-discovery hint is out of sync with the " +
            "active install."
    }
    Write-Host "  [OK] /etc/dotnet/install_location: $installLocation" `
        -ForegroundColor Green

    # 5) Manifest file present under the reconciler store. ls -1 of the
    #    provider-scoped glob: exit 0 + one or more lines = manifest(s)
    #    written; exit 2 (no match) = the install path skipped the
    #    manifest write, which is the regression this check guards.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'ls -1 /var/lib/infra-provisioner/manifests/" +
                   "dotnetSdk-*.json 2>/dev/null'")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest glob probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $manifestPaths = ($result.Output -split "`n" | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object { $_.Trim() })
    if (@($manifestPaths).Count -lt 1) {
        throw "No dotnet SDK manifest file under " +
            "/var/lib/infra-provisioner/manifests/ on $VmName. " +
            "The reconciler's truth source is missing - uninstall and " +
            "version-change paths will not work on the next run."
    }
    Write-Host "  [OK] manifest present: $($manifestPaths -join ', ')" `
        -ForegroundColor Green
}
