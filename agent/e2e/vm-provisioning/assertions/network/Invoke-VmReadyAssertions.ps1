<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmReadyAssertions
#   Baseline "VM is up and healthy" assertion block. Run by every phase
#   that newly creates or re-runs against a VM, before any
#   phase-specific JDK / users / runner assertions, so a stuck cloud-init
#   or a full disk surfaces with a clear message instead of a confusing
#   downstream failure.
#
#   Checks:
#     - cloud-init finished cleanly (status: done, exit 0). Uses
#       'cloud-init status --wait' so a still-running init blocks here
#       rather than producing a misleading 'running' state.
#     - hostname matches the expected vmName - confirms cloud-init
#       applied the correct system identity, not just that SSH opened.
#     - root filesystem is accessible and not >= 90% full.
#
#   Throws on the first failure with a message naming the VM and the
#   observed value. The outer try/finally in the calling test still
#   runs teardown.
# ---------------------------------------------------------------------------

function Invoke-VmReadyAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName
    )

    # cloud-init must have finished before any post-condition assertions
    # run - the JDK tarball is extracted by cloud-init runcmd, not by
    # provision.ps1. provision.ps1's "SSH reachable" signal comes earlier.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'cloud-init status --wait'
    if ($result.ExitStatus -ne 0) {
        throw "cloud-init did not complete successfully on " +
            "$VmName (exit $($result.ExitStatus)). " +
            "stdout: $($result.Output)  stderr: $($result.Error)"
    }
    Write-Host "  [OK] cloud-init: $($result.Output.Trim())" -ForegroundColor Green

    # Hostname matches vmName - confirms cloud-init applied the correct
    # system identity, not just that SSH opened.
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
    Write-Host "  [OK] hostname: $actualHostname" -ForegroundColor Green

    # Root filesystem is accessible and not full.
    $result = Invoke-SshClientCommand -SshClient $SshClient -Command 'df /'
    if ($result.ExitStatus -ne 0) {
        throw "df / failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $usePct = [int](($result.Output -split '\s+' |
        Where-Object { $_ -match '^\d+%$' }) -replace '%')
    if ($usePct -ge 90) {
        throw "Root filesystem on $VmName is ${usePct}% full."
    }
    Write-Host "  [OK] root filesystem: ${usePct}% used" -ForegroundColor Green
}
