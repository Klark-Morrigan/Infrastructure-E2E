<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1.

    Depends on:
      - assertions\Invoke-VmTeardownAssertions.ps1
            (post-teardown verifier; dot-sourced by the orchestrator
            before this file - see Invoke-VmProvisioningTest.ps1's
            dot-source block).
      - diag\Invoke-PreTeardownRuntimeDiagCapture.ps1
            (snapshots every VM before deprovision destroys it -
            dot-sourced by this file directly so the dependency is
            colocated with its sole consumer).
#>

. "$PSScriptRoot\..\diag\Invoke-PreTeardownRuntimeDiagCapture.ps1"

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningTeardown
#   Destroys the test VM(s), removes the test VmProvisionerConfig from the
#   vault, then verifies the teardown post-conditions via
#   Invoke-VmTeardownAssertions. Always called from a finally block so
#   cleanup runs regardless of test outcome.
#
#   Before deprovision destroys the VMs we capture a runtime snapshot
#   (host-side + best-effort guest-side) via the provisioner's
#   Invoke-VmRuntimeDiag helper. The whole point of THIS hook is that
#   teardown always runs, including on assertion-phase failure, so a
#   stale VM does not have to be left around for an operator to SSH
#   into - the per-VM runtime-diag.log sits next to console.log
#   under <vmConfigPath>/diagnostics/ regardless of how the test
#   ended. The capture function lives in
#   diag\Invoke-PreTeardownRuntimeDiagCapture.ps1 so it can be
#   tested in isolation; it is best-effort - if the helper is
#   missing, the vault is unreadable, or a per-VM SSH open fails,
#   the snapshot is skipped and teardown continues - teardown MUST
#   NOT depend on diag.
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

    Invoke-PreTeardownRuntimeDiagCapture -Config $Config

    Write-Host 'Deprovisioning VM(s) ...' -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\deprovision.ps1" -SecretSuffix $script:E2ETestSecretSuffix

    Write-Host 'Removing test VmProvisionerConfig from vault ...' -ForegroundColor Magenta
    Remove-Secret -Vault VmProvisioner -Name (Get-E2ESecretName 'VmProvisionerConfig')

    Invoke-VmTeardownAssertions -Config $Config
}
