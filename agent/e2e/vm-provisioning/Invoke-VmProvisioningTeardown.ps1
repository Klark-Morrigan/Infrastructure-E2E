<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Invoke-VmTeardownAssertions.ps1 (called at the end of this
    function).
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningTeardown
#   Destroys the test VM(s), removes the test VmProvisionerConfig from the
#   vault, then verifies the teardown post-conditions via
#   Invoke-VmTeardownAssertions. Always called from a finally block so
#   cleanup runs regardless of test outcome.
#
#   deprovision.ps1 reads the current VmProvisionerConfig and destroys
#   every VM listed there. The standalone scenario rewrites that config
#   to include both VM1 and VM2 by phase 3, so a phase-2-or-later failure
#   still tears down both. deprovision.ps1 is itself idempotent - safe
#   to run even if provision.ps1 failed part-way through and no VM was
#   created.
#
#   The assertion call lives inside this function rather than at every
#   caller so no caller can run teardown and forget to verify. Failure-
#   path callers wrap this whole function in try/catch + Write-Warning
#   so an assertion failure on a partial-state teardown surfaces as a
#   warning rather than masking the original error.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningTeardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    Write-Host 'Deprovisioning VM(s) ...' -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\deprovision.ps1"

    Write-Host 'Removing test VmProvisionerConfig from vault ...' -ForegroundColor Magenta
    Remove-Secret -Vault VmProvisioner -Name VmProvisionerConfig

    Invoke-VmTeardownAssertions -Config $Config
}
