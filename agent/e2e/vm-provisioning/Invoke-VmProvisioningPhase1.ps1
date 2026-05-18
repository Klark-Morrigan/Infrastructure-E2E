<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common, the assertion helpers, and the shared
    orchestrator helpers (New-VmEntryBase, Write-VmProvisionerConfig,
    Invoke-WithVmSshClient) are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase1
#   Phase 1 - install JDK 21 on VM1 (plus the file-transfer fixture).
#
#   Single-VM VmProvisionerConfig so the baseline install path is
#   isolated from any multi-VM interaction. The file-transfer fixture is
#   only exercised here - the goal is to confirm Copy-VmFiles dispatch
#   still works alongside the JDK install, not to re-cover it in every
#   phase.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def
    )

    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Phase 1: writing single-VM VmProvisionerConfig (VM1 + JDK 21) ...' `
        -ForegroundColor Magenta

    $entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    $entry.javaDevKit = [ordered]@{
        vendor  = $script:JdkTestVendor
        version = $script:JdkInitialVersion
    }
    $entry.files = @(
        [ordered]@{
            source = $script:FileTransferSource
            target = $script:FileTransferTarget
        }
    )

    Write-VmProvisionerConfig -Entries @($entry)

    Write-Host 'Phase 1: provisioning VM1 ...' -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1"

    Write-Host "Phase 1: verifying post-conditions on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)

        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName

        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkInitialVersion `
            -InstallPrefix    $script:JdkInstallPrefix

        Invoke-FileTransferAssertions `
            -SshClient  $sshClient `
            -VmName     $Vm1Def.vmName `
            -SourcePath $script:FileTransferSource `
            -TargetPath $script:FileTransferTarget
    }
}
