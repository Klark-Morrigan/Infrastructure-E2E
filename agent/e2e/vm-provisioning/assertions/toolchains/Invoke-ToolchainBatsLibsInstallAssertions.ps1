<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-ToolchainBatsLibsInstallAssertions
#   Asserts the section-2 ("vm-downloaded") bats helper libraries the
#   Common-Ansible toolchain_bats_libs role baked onto the VM landed
#   correctly. Unlike the apt packages, these are GitHub-tarball libraries
#   apt cannot serve; the role writes each into <base>/<name>/ with a
#   .installed-v<version> marker as its idempotence key, so the end state is
#   probed on disk directly rather than through dpkg.
#
#   Per declared library:
#     A1 - <base>/<name>/load.bash exists (the entrypoint bats_load_library
#          resolves).
#     A2 - the .installed-v<version> marker exists, proving the exact pin was
#          baked. The marker name encodes the version, so a drifted build
#          fails here even when load.bash is present - the same equality bar
#          the apt assertion holds via dpkg.
#   Once, across all declared libraries:
#     A3 - a real bats run loads every declared library (in declaration
#          order, so a dependent like bats-assert follows bats-support) and
#          passes. Presence on disk is not loadability; a truncated extract
#          would pass A1/A2 but fail here.
#
#   Throws on the first failure naming the VM, the library, and the observed
#   value. The outer try/finally in Invoke-VmProvisioningTest still runs
#   teardown.
# ---------------------------------------------------------------------------

function Invoke-ToolchainBatsLibsInstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # The declared section-2 bats libraries. Each entry carries:
        #   Name    - the bats-core library name (also the <base>/<name>
        #             directory and the bats_load_library argument).
        #   Version - the exact tag the .installed-v marker must report.
        [Parameter(Mandatory)]
        [object[]] $Libraries,

        # The base the role installs libraries under, matching the role's
        # toolchain_bats_libs_base_dir default.
        [string] $BaseDir = '/usr/lib'
    )

    foreach ($library in $Libraries) {
        $libDir = "$BaseDir/$($library.Name)"

        # A1) load.bash present - the file bats_load_library sources.
        $result = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   ("bash -c 'test -f $libDir/load.bash && echo present " +
                        "|| echo absent'")
        if ($result.ExitStatus -ne 0) {
            throw "load.bash probe for $($library.Name) failed on $VmName " +
                "(exit $($result.ExitStatus)): $($result.Error)"
        }
        if ($result.Output.Trim() -ne 'present') {
            throw "$libDir/load.bash is missing on $VmName. The " +
                "toolchain_bats_libs role did not install $($library.Name)."
        }
        Write-Host "  [OK] A1 load.bash present: $libDir/load.bash" `
            -ForegroundColor Green

        # A2) The exact-version marker the role writes last on a successful
        #     install. Its name encodes the pin, so this doubles as the
        #     "converged on the declared version" check.
        $marker = "$libDir/.installed-v$($library.Version)"
        $result = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   ("bash -c 'test -f $marker && echo present || echo absent'")
        if ($result.ExitStatus -ne 0) {
            throw "version-marker probe for $($library.Name) failed on " +
                "$VmName (exit $($result.ExitStatus)): $($result.Error)"
        }
        if ($result.Output.Trim() -ne 'present') {
            throw "Expected $($library.Name) pinned at $($library.Version) on " +
                "$VmName, but $marker is absent. The exact-version pin did " +
                "not win."
        }
        Write-Host "  [OK] A2 $($library.Name) pinned at $($library.Version)" `
            -ForegroundColor Green
    }

    # A3) Loadability. Build a .bats whose setup loads every declared library
    #     in order (bats_load_library only works inside a bats run), plus a
    #     trivial passing test. Base64 the body so the multi-line file crosses
    #     SSH without quoting hazards. BATS_LIB_PATH points at the base dir,
    #     exactly as a CI consumer resolves the baked libraries. rc 0 with a
    #     passing TAP line proves every declared library sourced cleanly.
    $loadLines = ($Libraries | ForEach-Object {
        "  bats_load_library $($_.Name)"
    }) -join "`n"
    $batsBody = "setup() {`n$loadLines`n}`n`n" +
        "@test `"baked bats libraries load`" {`n  true`n}`n"
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($batsBody))
    $batsFile = '/tmp/e2e-bats-libload.bats'
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   ("bash -c `"echo '$encoded' | base64 -d > $batsFile && " +
                    "BATS_LIB_PATH='$BaseDir' bats --tap $batsFile`"")
    if ($result.ExitStatus -ne 0) {
        throw "Loading the baked bats libraries failed on $VmName " +
            "(exit $($result.ExitStatus)). stdout: $($result.Output)  " +
            "stderr: $($result.Error)"
    }
    # A failing test prints "not ok 1 ..." which itself contains "ok 1", so a
    # bare substring check would pass it. Require the TAP pass line at the
    # start of a line AND reject any "not ok".
    if ($result.Output -notmatch '(?m)^ok 1\b' -or $result.Output -match 'not ok') {
        throw "The baked bats libraries did not load into a bats run on " +
            "$VmName. Output: $($result.Output)"
    }
    Write-Host '  [OK] A3 all declared libraries load into a bats run' `
        -ForegroundColor Green
}
