<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-NoJdkVmAssertions
#   The "blast-radius witness" assertion block for a VM that must remain
#   JDK-free across phases where another VM in the same provision run is
#   having its JDK installed, uninstalled, or replaced. A regression that
#   leaked a JDK step to the wrong VM would only fire here:
#     B1 - SSH is reachable and 'hostname' returns the expected vmName.
#     B2 - cloud-init finished cleanly (status 'done', exit 0).
#     B3 - No JDK artifacts: no /opt/jdk-* dir, no /etc/profile.d/jdk.sh,
#          and no javaDevKit-*.json manifest under the reconciler store.
#
#   B1 also doubles as proof that VM2 was created at all in the phase that
#   added it - a regression that quietly skipped VM2's provisioning would
#   surface as a connection failure before any B-assertion ran.
#
#   Throws on the first failure with a message naming the VM and the
#   observed value. The outer try/finally in Invoke-VmProvisioningTest still
#   runs teardown.
# ---------------------------------------------------------------------------

function Invoke-NoJdkVmAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    # B1) Hostname matches vmName. SSH reachability itself is implicit -
    #     the caller had to open $SshClient before this function ran.
    $result = Invoke-SshClientCommand -SshClient $SshClient -Command 'hostname'
    if ($result.ExitStatus -ne 0) {
        throw "hostname failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $actualHostname = $result.Output.Trim()
    if ($actualHostname -ne $VmName) {
        throw "Hostname mismatch on $VmName " +
            "(expected '$VmName', got '$actualHostname')."
    }
    Write-Host "  [OK] B1: hostname is $actualHostname" -ForegroundColor Green

    # B2) cloud-init done. --wait blocks until completion so a still-running
    #     init does not produce a confusing 'running' state.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'cloud-init status --wait'
    if ($result.ExitStatus -ne 0) {
        throw "cloud-init did not complete cleanly on $VmName " +
            "(exit $($result.ExitStatus)). stdout: $($result.Output)  " +
            "stderr: $($result.Error)"
    }
    Write-Host "  [OK] B2: cloud-init $($result.Output.Trim())" `
        -ForegroundColor Green

    # B3a) No /opt/jdk-* directory. Same nullglob technique as the uninstall
    #      assertion - the count must be 0.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'shopt -s nullglob; arr=( /opt/jdk-* ); echo `${#arr[@]}'"
    if ($result.ExitStatus -ne 0) {
        throw "/opt/jdk-* probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $matchCount = [int]($result.Output.Trim())
    if ($matchCount -ne 0) {
        throw "Unexpected JDK install dir(s) on $VmName " +
            "(expected 0 under /opt/jdk-*, got $matchCount). " +
            "A JDK step leaked from another VM in the same provision run."
    }
    Write-Host '  [OK] B3a: no /opt/jdk-* directories' -ForegroundColor Green

    # B3b) No /etc/profile.d/jdk.sh.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -e /etc/profile.d/jdk.sh && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Profile-snippet probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $state = $result.Output.Trim()
    if ($state -ne 'absent') {
        throw "Unexpected /etc/profile.d/jdk.sh on $VmName (state '$state'). " +
            "A JDK step leaked from another VM in the same provision run."
    }
    Write-Host '  [OK] B3b: no /etc/profile.d/jdk.sh' -ForegroundColor Green

    # B3c) No javaDevKit-*.json manifest under the reconciler store. A leak
    #      here means the reconciler ran with stale state on the witness
    #      VM, which would cause unsolicited teardown attempts on its
    #      next reconciliation.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'ls -1 /var/lib/infra-provisioner/manifests/" +
                   "javaDevKit-*.json 2>/dev/null || true'")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest leak probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $leftover = $result.Output.Trim()
    if (-not [string]::IsNullOrEmpty($leftover)) {
        throw "Unexpected javaDevKit manifest(s) on ${VmName}: $leftover. " +
            "A JDK reconciliation step leaked from another VM in the same " +
            "provision run."
    }
    Write-Host '  [OK] B3c: no javaDevKit manifest leftover' `
        -ForegroundColor Green
}
