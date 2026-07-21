<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-DockerInstallAssertions
#   Asserts the section-3 ("base-image / daemon") toolchain the Common-Ansible
#   docker role installed is present AND running on the VM. Section 3 is a
#   presence gate rather than a version list - a `docker` entry in the config's
#   toolchains.baseImage switches the whole daemon on - so these checks are
#   about the daemon being usable, not about a pinned build:
#     D1 - the docker CLI is on the non-login PATH (the shape CI steps and
#          systemd units see).
#     D2 - 'systemctl is-active docker' reports 'active'. Installing the
#          engine packages is not the same as the service coming up; a unit
#          that failed to start would still leave D1 green.
#     D3 - 'sudo docker ps' exits 0, i.e. the CLI can actually reach the
#          daemon socket. A daemon that is "active" but wedged fails here.
#
#   D3 deliberately probes AS ROOT rather than as the VM admin user. The
#   provisioning flow installs the daemon but leaves docker_group_members
#   empty on purpose: the runner service user is owned by the GitHubRunners
#   config, not this provisioner secret, so socket access for a non-root user
#   is granted by that repo's own flow. Asserting VM-admin group membership
#   here would assert a grant this flow is not responsible for, and would go
#   red for a correct implementation.
#
#   Throws on the first failure with a message naming the VM and the observed
#   value. The outer try/finally in Invoke-VmProvisioningTest still runs
#   teardown.
# ---------------------------------------------------------------------------

function Invoke-DockerInstallAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName,

        # The systemd unit the docker role enables. Parameterised (rather than
        # a literal) to mirror the role's own docker_service_name knob, so a
        # consumer running a non-default unit can reuse these checks.
        [string] $ServiceName = 'docker'
    )

    # D1) CLI on the non-login PATH.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command "bash -c 'command -v docker'"
    if ($result.ExitStatus -ne 0) {
        throw "command -v docker (non-login shell) failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $dockerPath = $result.Output.Trim()
    if ([string]::IsNullOrEmpty($dockerPath)) {
        throw "docker is not on the non-login PATH on $VmName. The docker " +
            "role did not install the engine."
    }
    Write-Host "  [OK] non-login PATH docker: $dockerPath" -ForegroundColor Green

    # D2) Service active. is-active exits non-zero for every non-active state,
    #     so the exit status alone is the assertion; the output is reported
    #     back for diagnosis ('inactive' vs 'failed' vs 'activating').
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command "systemctl is-active $ServiceName"
    if ($result.ExitStatus -ne 0) {
        throw "$ServiceName service is not active on $VmName " +
            "(exit $($result.ExitStatus), state " +
            "'$($result.Output.Trim())'): $($result.Error)"
    }
    Write-Host "  [OK] $ServiceName service: $($result.Output.Trim())" `
        -ForegroundColor Green

    # D3) Daemon reachable. 'docker ps' is the cheapest command that requires
    #     a real round-trip to the socket, so it fails on a wedged daemon that
    #     D2 would still call active.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'sudo docker ps'
    if ($result.ExitStatus -ne 0) {
        throw "sudo docker ps failed on $VmName " +
            "(exit $($result.ExitStatus)). The daemon is not reachable over " +
            "its socket. stdout: $($result.Output)  stderr: $($result.Error)"
    }
    Write-Host '  [OK] sudo docker ps reached the daemon' -ForegroundColor Green
}
