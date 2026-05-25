<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common, the assertion helpers, and the shared
    orchestrator helpers are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase3
#   Phase 3 - version change on VM1 (JDK reinstall -> initial), then
#   remove-via-empty on VM1.
#
#   Sub-phase 3a (first provision):
#     - VM1's javaDevKit.version flips from $JdkReinstallVersion (installed
#       by phase 2b) to $JdkInitialVersion. The reconciler must uninstall
#       the old install dir + manifest and install the new one in the
#       same provision run.
#
#   Sub-phase 3b (second provision):
#     - VM1's javaDevKit becomes an explicit empty list (the "ensure
#       none via @()" contract) and envVars.entries becomes empty as
#       well (the existing managed-block removal scenario, retained
#       from the pre-reconciler phase 3).
#
#   VM2 is unchanged across both sub-phases and is re-checked at the end
#   to confirm two more JDK steps on VM1 (one change, one remove) did
#   not leak across.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def,
        [Parameter(Mandatory)] [PSCustomObject] $Vm2Def
    )

    Write-Host '' -ForegroundColor Magenta
    Write-Host "Phase 3a: rewriting VmProvisionerConfig - VM1 changes JDK $($script:JdkReinstallVersion) -> $($script:JdkInitialVersion) ..." `
        -ForegroundColor Magenta

    # 3a) VM1 entry: bump javaDevKit.version. Everything else unchanged
    # so the only diff the reconciler sees is the version field.
    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    $vm1Entry.javaDevKit = [ordered]@{
        vendor  = $script:JdkTestVendor
        version = $script:JdkInitialVersion
    }
    # envVars unchanged from phase 2b - still narrowed to FOO_HOME so
    # no spurious managed-block diff masks the JDK change.
    $vm1Entry.envVars = [ordered]@{
        blockName = $script:EnvVarsBlockName
        entries   = @(
            [ordered]@{ name = $script:EnvVarsFooHome.Name; value = $script:EnvVarsFooHome.Value }
        )
    }

    $vm2Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm2Def.vmName `
        -IpAddress $Vm2Def.ipAddress `
        -Password  $Vm2Def.password

    Write-VmProvisionerConfig -Entries @($vm1Entry, $vm2Entry)

    Write-Host 'Phase 3a: provisioning (version change on VM1) ...' `
        -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1"

    Write-Host "Phase 3a: verifying version change on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm1Def

        # Old-side cleanup + symlink re-target.
        Invoke-JdkVersionChangeAssertions `
            -SshClient                $sshClient `
            -VmName                   $Vm1Def.vmName `
            -InstallPrefix            $script:JdkInstallPrefix `
            -PreviousRequestedVersion $script:JdkReinstallVersion `
            -NewRequestedVersion      $script:JdkInitialVersion

        # New-side install (JAVA_HOME, PATH, java -version, manifest
        # present). Together with VersionChange's V1-V4 this covers the
        # full swap contract.
        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkInitialVersion `
            -InstallPrefix    $script:JdkInstallPrefix
    }

    # ------------------------------------------------------------------
    # 3b) Remove via empty list. javaDevKit = @() is the explicit
    # "ensure none" contract (companion to "drop the field" exercised
    # in 2a); envVars.entries = @() drives the managed-block removal.
    # ------------------------------------------------------------------
    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Phase 3b: rewriting VmProvisionerConfig - VM1 javaDevKit = @() + envVars empty ...' `
        -ForegroundColor Magenta

    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Explicit empty list - the "ensure none" signal. Distinct from 2a
    # (which dropped the field entirely) so both removal contracts
    # are exercised in one run.
    $vm1Entry.javaDevKit = @()
    $vm1Entry.envVars = [ordered]@{
        blockName = $script:EnvVarsBlockName
        entries   = @()
    }

    $vm2Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm2Def.vmName `
        -IpAddress $Vm2Def.ipAddress `
        -Password  $Vm2Def.password

    Write-VmProvisionerConfig -Entries @($vm1Entry, $vm2Entry)

    Write-Host 'Phase 3b: provisioning (uninstall via empty list on VM1) ...' `
        -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1"

    Write-Host "Phase 3b: verifying remove-via-empty on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            -InstallPrefix $script:JdkInstallPrefix

        # envVars: E7 (markers gone), E8 (formerly-managed entries
        # gone), E1 (mode unchanged), E3 (MARKER_OUTSIDE still
        # present). Names listed explicitly (not derived from the
        # phase-1 fixtures) so a future fixture rename does not
        # silently weaken the assertion.
        Invoke-EnvVarsRemovedAssertions `
            -SshClient          $sshClient `
            -VmName             $Vm1Def.vmName `
            -RemovedBlockName   $script:EnvVarsBlockName `
            -RemovedEntryNames  @($script:EnvVarsFooHome.Name, $script:EnvVarsBarVar.Name) `
            -ExpectedMarkerLine $script:EnvVarsMarkerLine
    }

    Write-Host "Phase 3b: re-verifying VM2 has no JDK artifacts ($($Vm2Def.vmName)) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm2Def
        Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
    }
}
