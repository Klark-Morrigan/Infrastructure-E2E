<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-NoToolchainsVmAssertions
#   The "blast-radius witness" for sections 2 and 3, mirroring what
#   Invoke-NoJdkVmAssertions does for section 1. VM2 declares no `toolchains`
#   block, so the playbook's per-host selectattr must resolve it to an empty
#   taxonomy: the toolchain_apt role runs as a no-op and the docker role is
#   skipped by its baseImage gate. A regression that widened either - dispatch
#   built from the whole config array instead of this host's entry, or a gate
#   that read any host's baseImage - would install VM1's tools onto VM2 and
#   fire only here.
#
#     W1 - none of the section-2 apt packages are in the installed state.
#     W2 - the docker CLI is absent from PATH.
#     W3 - the docker role's apt keyring was never dropped. Catches the
#          narrower leak where the repo setup ran on this host but the engine
#          install did not get far enough to satisfy W2.
#
#   Reachability and cloud-init health are NOT re-probed here - the phases
#   call this alongside Invoke-NoJdkVmAssertions, which already asserts both
#   (its B1 / B2) on the same VM in the same block.
#
#   Throws on the first failure with a message naming the VM and the observed
#   value. The outer try/finally in Invoke-VmProvisioningTest still runs
#   teardown.
# ---------------------------------------------------------------------------

function Invoke-NoToolchainsVmAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # The section-2 packages VM1 declares. Only .Name is read; the same
        # declaration list the install assertions consume is passed so the
        # witness can never fall out of step with what is being installed
        # next door.
        [Parameter(Mandatory)]
        [object[]] $Packages,

        # The docker role's keyring path, matching the role's
        # docker_apt_keyring_path default.
        [string] $DockerKeyringPath = '/etc/apt/keyrings/docker.asc'
    )

    # W1) No section-2 package installed. dpkg-query exits 1 for a package it
    #     has never heard of, so '|| true' keeps the probe itself green and
    #     turns "unknown" into empty output; the assertion is on the reported
    #     status, which is 'install ok installed' only for a real install.
    #     The ${Status} format token stays single-quoted so the remote shell
    #     hands it to dpkg-query instead of expanding it to nothing.
    foreach ($package in $Packages) {
        $result = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   ("dpkg-query -W -f='`${Status}' " +
                        "$($package.Name) 2>/dev/null || true")
        if ($result.ExitStatus -ne 0) {
            throw "dpkg-query leak probe for $($package.Name) failed on " +
                "$VmName (exit $($result.ExitStatus)): $($result.Error)"
        }
        $status = $result.Output.Trim()
        if ($status -eq 'install ok installed') {
            throw "Unexpected $($package.Name) install on ${VmName}: it " +
                "declared no toolchains block. A section-2 apt step leaked " +
                "from another VM in the same provision run."
        }
        Write-Host "  [OK] W1: no $($package.Name) installed" `
            -ForegroundColor Green
    }

    # W2) No docker CLI. '|| true' so an absent binary is empty output rather
    #     than a non-zero exit this function would misreport as a probe fault.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command "bash -c 'command -v docker || true'"
    if ($result.ExitStatus -ne 0) {
        throw "docker leak probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $dockerPath = $result.Output.Trim()
    if (-not [string]::IsNullOrEmpty($dockerPath)) {
        throw "Unexpected docker CLI on ${VmName}: $dockerPath. It declared " +
            "no toolchains block - a section-3 step leaked from another VM " +
            "in the same provision run."
    }
    Write-Host '  [OK] W2: no docker CLI on PATH' -ForegroundColor Green

    # W3) No docker apt keyring.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command   ("bash -c 'test -e $DockerKeyringPath && echo present " +
                    "|| echo absent'")
    if ($result.ExitStatus -ne 0) {
        throw "Docker keyring leak probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $state = $result.Output.Trim()
    if ($state -ne 'absent') {
        throw "Unexpected $DockerKeyringPath on $VmName (state '$state'). " +
            "The docker role's apt repo setup leaked from another VM in the " +
            "same provision run."
    }
    Write-Host "  [OK] W3: no $DockerKeyringPath" -ForegroundColor Green
}
