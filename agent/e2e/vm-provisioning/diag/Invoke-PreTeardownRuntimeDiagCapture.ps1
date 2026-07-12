<#
.NOTES
    Do not run this file directly. Dot-sourced by phases\Invoke-VmProvisioningTeardown.ps1
    so the pre-teardown snapshot lives next to the teardown function
    that consumes it (which in turn is dot-sourced by the top-level
    Invoke-VmProvisioningTest.ps1 orchestrator).
#>

# ---------------------------------------------------------------------------
# Invoke-PreTeardownRuntimeDiagCapture
#   Snapshots every VM in the current VmProvisionerConfig via the
#   provisioner's Invoke-VmRuntimeDiag helper (host-side + best-effort
#   guest-side via SSH). Called from Invoke-VmProvisioningTeardown
#   BEFORE deprovision.ps1 destroys the VMs, so a failed E2E run
#   leaves a per-VM runtime-diag.log artifact next to console.log
#   under <vmConfigPath>/diagnostics/ - the operator does not have
#   to SSH into a torn-down VM to learn why the assertion phase
#   failed.
#
#   Workload VMs get _RouterVm stamped here so the helper's
#   New-VmSshClientWithJump dispatch takes the jump-through-router
#   branch automatically.
#
#   Every stage is wrapped so teardown survives a degraded host:
#     - Helper files missing      -> skip, log warning, return
#     - Vault read fails          -> skip, log warning, return
#     - Per-VM Invoke fails       -> log, continue to next VM
#   The function never throws.
# ---------------------------------------------------------------------------

function Invoke-PreTeardownRuntimeDiagCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    $diagRoot     = Join-Path $Config.ProvisionerPath 'hyper-v\ubuntu\PowerShell\common\diag'
    $networkRoot  = Join-Path $Config.ProvisionerPath 'hyper-v\ubuntu\PowerShell\common\network'
    $diagScript   = Join-Path $diagRoot    'Invoke-VmRuntimeDiag.ps1'
    $folderScript = Join-Path $diagRoot    'Get-VmDiagFolder.ps1'
    $ipScript     = Join-Path $networkRoot 'Get-VmAdapterIPv4.ps1'

    foreach ($p in @($folderScript, $ipScript, $diagScript)) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            Write-Host "[diag] pre-teardown capture skipped: helper missing ($p)" `
                -ForegroundColor Yellow
            return
        }
    }

    try {
        . $folderScript
        . $ipScript
        . $diagScript
    } catch {
        Write-Host "[diag] pre-teardown capture skipped: failed to load helpers: $($_.Exception.Message)" `
            -ForegroundColor Yellow
        return
    }

    # The current VM list lives in the vault entry the test wrote.
    # No fall-back to in-memory state because callers (test + teardown)
    # may be in different processes / scopes; the vault is the SSOT.
    $vms = $null
    try {
        $secretName = Get-E2ESecretName 'VmProvisionerConfig'
        $json       = Get-Secret -Vault VmProvisioner -Name $secretName -AsPlainText -ErrorAction Stop
        $vms        = $json | ConvertFrom-Json
    } catch {
        Write-Host "[diag] pre-teardown capture skipped: cannot read VmProvisionerConfig from vault: $($_.Exception.Message)" `
            -ForegroundColor Yellow
        return
    }

    if (-not $vms) {
        Write-Host "[diag] pre-teardown capture skipped: VmProvisionerConfig is empty" `
            -ForegroundColor Yellow
        return
    }

    # Stamp _RouterVm on workloads so the helper's
    # New-VmSshClientWithJump dispatch takes the jump-through-router
    # branch automatically. Mirrors provision.ps1 step 7. Workload
    # entries written by Write-VmProvisionerConfig do not all carry
    # a 'kind' field (the schema treats it as router-only), so use
    # PSObject.Properties to read it safely under Strict-Mode and
    # default missing values to 'workload'.
    function Get-VmKind {
        param([object] $Vm)
        if ($Vm.PSObject.Properties['kind']) { $Vm.kind } else { 'workload' }
    }

    $routerVm = @($vms | Where-Object { (Get-VmKind $_) -eq 'router' } |
                  Select-Object -First 1)[0]
    if ($routerVm) {
        foreach ($vm in $vms) {
            if ((Get-VmKind $vm) -ne 'router') {
                $vm | Add-Member -NotePropertyName _RouterVm `
                                  -NotePropertyValue $routerVm -Force
            }
        }
    }

    Write-Host "Capturing pre-teardown runtime diagnostics ..." -ForegroundColor Magenta
    foreach ($vm in $vms) {
        try {
            $folder = Invoke-VmRuntimeDiag -Vm $vm -VmConfigPath $vm.vmConfigPath
            Write-Host "  [diag] $($vm.vmName) -> $folder" -ForegroundColor DarkGray
        } catch {
            Write-Host "  [diag] $($vm.vmName) snapshot failed: $($_.Exception.Message)" `
                -ForegroundColor Yellow
        }
    }
}
