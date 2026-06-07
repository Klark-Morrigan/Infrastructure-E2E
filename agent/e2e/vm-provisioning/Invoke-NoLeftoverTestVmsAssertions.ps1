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
#   All three VMs (router + VM1 + VM2) are checked. The router is
#   minted at Setup and stays up across phases; VM1 enters at phase 1;
#   VM2 enters at phase 2 - a leftover VM from any of them would still
#   trip later phases. The router check also catches the case where a
#   prior aborted run left the per-environment Private switch in a
#   stale state with the router still attached.
#
#   The remediation hint in the throw message points the operator at
#   deprovision.ps1 rather than at manual Get-VM / Remove-VM steps so
#   the per-env Private switch + the legacy NetNat cleanup are
#   handled together.
# ---------------------------------------------------------------------------

function Invoke-NoLeftoverTestVmsAssertions {
    [CmdletBinding()]
    param()

    foreach ($vmName in @($script:RouterVmName, $script:Vm1Name, $script:Vm2Name)) {
        if ($null -ne (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            throw ("Leftover VM '$vmName' found in Hyper-V. A previous " +
                "test run did not complete teardown. Remove it manually " +
                "(deprovision.ps1) before retrying.")
        }
    }
}
