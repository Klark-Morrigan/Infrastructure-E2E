<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common, the assertion helpers, and the shared
    orchestrator helpers are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase3
#   Phase 3 - re-install JDK 17 on VM1, VM2 unchanged.
#
#   Rewrites VmProvisionerConfig with VM1.javaDevKit = temurin/17 (uninstall
#   removed) and VM2 unchanged from phase 2. Proves an operator can flip a
#   VM from "no JDK" back to "JDK installed" without rebuilding it, and
#   re-checks the VM2 witness to confirm the second JDK step in the run did
#   not leak across either.
#
#   The phase-1 /opt/jdk-temurin-21* dir may legitimately still exist on
#   disk - the install step is dir-scoped, not vendor-scoped, and multi-JDK
#   coexistence is out of scope for this feature. Assertions therefore
#   check that JDK 17 is the *active* install (JAVA_HOME, java -version)
#   without asserting on JDK 21's absence.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def,
        [Parameter(Mandatory)] [PSCustomObject] $Vm2Def
    )

    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Phase 3: rewriting VmProvisionerConfig - VM1 reinstall (17), VM2 unchanged ...' `
        -ForegroundColor Magenta

    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    $vm1Entry.javaDevKit = [ordered]@{
        vendor  = $script:JdkTestVendor
        version = $script:JdkReinstallVersion
    }

    $vm2Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm2Def.vmName `
        -IpAddress $Vm2Def.ipAddress `
        -Password  $Vm2Def.password

    Write-VmProvisionerConfig -Entries @($vm1Entry, $vm2Entry)

    Write-Host 'Phase 3: provisioning (install JDK 17 on VM1) ...' `
        -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1"

    Write-Host "Phase 3: verifying JDK 17 install on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkReinstallVersion `
            -InstallPrefix    $script:JdkInstallPrefix
    }

    Write-Host "Phase 3: re-verifying VM2 has no JDK artifacts ($($Vm2Def.vmName)) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
        param($sshClient)
        Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
    }
}
