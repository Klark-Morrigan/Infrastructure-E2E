<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after the script-scope test scenario constants are defined.
#>

# ---------------------------------------------------------------------------
# Invoke-NoLeftoverTestVmsAssertions
#   Pre-flight check: fails before any vault write if either test VM is
#   still in Hyper-V from a previous run. provision.ps1 silently skips
#   existing VMs, so without this guard the fresh passwords pinned in
#   Setup would not match the old VMs' credentials and every subsequent
#   SSH call would get "Permission denied (password)".
#
#   Both VMs are checked because the scenario provisions both starting in
#   phase 2 - a leftover VM2 from a failed prior run would still trip
#   later phases even though the standalone wrapper's phase 1 only
#   touches VM1.
#
#   The remediation hint in the throw message points the operator at
#   deprovision.ps1 rather than at manual Get-VM / Remove-VM steps so
#   the cache + switch + NAT are cleaned up together.
# ---------------------------------------------------------------------------

function Invoke-NoLeftoverTestVmsAssertions {
    [CmdletBinding()]
    param()

    foreach ($vmName in @($script:Vm1Name, $script:Vm2Name)) {
        if ($null -ne (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            throw ("Leftover VM '$vmName' found in Hyper-V. A previous " +
                "test run did not complete teardown. Remove it manually " +
                "(deprovision.ps1) before retrying.")
        }
    }
}
