<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common, the assertion helpers, and the shared
    orchestrator helpers are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase2
#   Phase 2 - uninstall on VM1, add VM2 (no javaDevKit).
#
#   Rewrites VmProvisionerConfig with VM1.javaDevKit.uninstall = true AND
#   adds VM2 (no javaDevKit). One provision run executes both changes -
#   that is the regression-catching shape: a JDK uninstall on VM1 must not
#   leak any JDK step onto a freshly created VM2 in the same run.
#
#   Assertions are issued before phase 3 edits the JSON so a phase-2 bug is
#   not masked by a passing phase 3.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def,
        [Parameter(Mandatory)] [PSCustomObject] $Vm2Def
    )

    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Phase 2: rewriting VmProvisionerConfig - VM1 uninstall + add VM2 ...' `
        -ForegroundColor Magenta

    # VM1 entry: identity pinned (vmName/ip/credentials unchanged), only the
    # javaDevKit block flips to the uninstall shape. vendor + version stay
    # required by the schema even when uninstall=true (see plan step 1).
    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    $vm1Entry.javaDevKit = [ordered]@{
        vendor    = $script:JdkTestVendor
        version   = $script:JdkInitialVersion
        uninstall = $true
    }

    # VM2 entry: no javaDevKit, no files. Plain VM creation so we can
    # observe that no JDK step touched it (B-assertions).
    $vm2Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm2Def.vmName `
        -IpAddress $Vm2Def.ipAddress `
        -Password  $Vm2Def.password

    Write-VmProvisionerConfig -Entries @($vm1Entry, $vm2Entry)

    Write-Host 'Phase 2: provisioning (uninstall on VM1, create VM2) ...' `
        -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1"

    Write-Host "Phase 2: verifying uninstall on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            -InstallPrefix $script:JdkInstallPrefix
    }

    Write-Host "Phase 2: verifying VM2 has no JDK artifacts ($($Vm2Def.vmName)) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
        param($sshClient)
        Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
    }
}
