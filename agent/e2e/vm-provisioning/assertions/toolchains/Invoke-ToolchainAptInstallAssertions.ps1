<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-ToolchainAptInstallAssertions
#   Asserts the section-2 ("vm-downloaded") toolchain the Common-Ansible
#   toolchain_apt role installed landed correctly on the VM. Section 2 has no
#   host staging, file server, or manifest - apt is itself the installed-state
#   truth source - so the end state is probed directly rather than through a
#   manifest store the way the section-1 jdk / dotnet assertions do.
#
#   Per declared package:
#     A1 - the package's command is on the NON-LOGIN PATH. Non-login is the
#          case that matters: CI steps arrive as 'ssh user@host command' and
#          systemd units, neither of which sources /etc/profile.d.
#     A2 - 'dpkg-query' reports EXACTLY the pinned version. Equality, not a
#          prefix match: the whole point of the section-2 pin is that a
#          re-provision converges on that build, so a drifted-ahead package
#          is a failure, not an upgrade.
#     A3 - the tool actually runs. Presence on PATH plus a dpkg version says
#          the archive unpacked; it does not say the binary works against
#          this VM's libc / interpreter. Each package therefore carries its
#          own smoke recipe and the expected marker in its output.
#
#   The smoke recipe rides on the package declaration rather than living in a
#   per-tool branch here, so this function stays package-agnostic: adding a
#   fourth apt tool to the scenario is a new declaration, not an edit to the
#   assertion. See $script:ToolchainAptPackages in Invoke-VmProvisioningTest.ps1
#   for the declarations this consumes.
#
#   Throws on the first failure with a message naming the VM, the package,
#   and the observed value. The outer try/finally in Invoke-VmProvisioningTest
#   still runs teardown.
# ---------------------------------------------------------------------------

function Invoke-ToolchainAptInstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # The declared section-2 packages. Each entry carries:
        #   Name         - the apt package name (also the dpkg-query key).
        #   Version      - the exact apt pin dpkg-query must report back.
        #   Command      - the executable the package puts on PATH.
        #   SmokeCommand - a shell command proving the tool runs.
        #   SmokePattern - regex the smoke output must match.
        [Parameter(Mandatory)]
        [object[]] $Packages
    )

    foreach ($package in $Packages) {
        # A1) Command resolvable in a non-login shell.
        $result = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "bash -c 'command -v $($package.Command)'"
        if ($result.ExitStatus -ne 0) {
            throw "command -v $($package.Command) (non-login shell) failed on " +
                "$VmName (exit $($result.ExitStatus)): $($result.Error)"
        }
        $commandPath = $result.Output.Trim()
        if ([string]::IsNullOrEmpty($commandPath)) {
            throw "$($package.Command) is not on the non-login PATH on $VmName. " +
                "The toolchain_apt role did not install $($package.Name)."
        }
        Write-Host "  [OK] non-login PATH $($package.Command): $commandPath" `
            -ForegroundColor Green

        # A2) dpkg-query reports the exact pin. -W with a bare ${Version}
        #     format keeps the output a single token with no trailing
        #     newline noise to strip around.
        $result = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   ("dpkg-query -W -f='`${Version}' " + $package.Name)
        if ($result.ExitStatus -ne 0) {
            throw "dpkg-query for $($package.Name) failed on $VmName " +
                "(exit $($result.ExitStatus)): $($result.Error)"
        }
        $installedVersion = $result.Output.Trim()
        if ($installedVersion -ne $package.Version) {
            throw "Unexpected $($package.Name) version on $VmName " +
                "(expected the pin '$($package.Version)', got " +
                "'$installedVersion'). The apt pin did not win."
        }
        Write-Host "  [OK] $($package.Name) pinned at $installedVersion" `
            -ForegroundColor Green

        # A3) Smoke run. Both the exit status and the marker are checked -
        #     a tool that exits 0 while printing nothing recognisable is
        #     as much a regression as one that fails outright.
        $result = Invoke-SshClientCommand `
            -SshClient $SshClient -Command $package.SmokeCommand
        if ($result.ExitStatus -ne 0) {
            throw "Smoke run of $($package.Name) failed on $VmName " +
                "(exit $($result.ExitStatus)). stdout: $($result.Output)  " +
                "stderr: $($result.Error)"
        }
        $smokeOutput = $result.Output.Trim()
        if ($smokeOutput -notmatch $package.SmokePattern) {
            throw "Smoke run of $($package.Name) on $VmName did not match " +
                "'$($package.SmokePattern)'. Output: $smokeOutput"
        }
        $firstLine = ($smokeOutput -split "`n" | Select-Object -First 1).Trim()
        Write-Host "  [OK] $($package.Name) smoke run: $firstLine" `
            -ForegroundColor Green
    }
}
