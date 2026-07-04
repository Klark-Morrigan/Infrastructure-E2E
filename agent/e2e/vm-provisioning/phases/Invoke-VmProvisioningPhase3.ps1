<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell, the assertion helpers, and the shared
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

    $tcx = Get-ToolchainPhaseContext -Config $Config
    $jdkParams        = $tcx.Params.Jdk
    $sdkParams        = $tcx.Params.Sdk
    $toolParams       = $tcx.Params.Tools
    $toolInstallExtra = $tcx.Params.ToolInstallExtra

    # 3a version-changes VM1 to JDK 21 + dotnet SDK 8.0.100 + the tool at
    # its reinstall pin. 3b removes every toolchain (reconciler: @() empty
    # lists; ansible: an empty desired state -> set-difference uninstall).
    $toolchainsDesired3a = New-ToolchainDesiredState `
        -JdkVersions       @($script:JdkInitialVersion) `
        -DotnetSdkVersions @([ordered]@{
            channel = $script:DotnetInitialChannel
            version = $script:DotnetInitialResolvedVersion
        }) `
        -DotnetToolsTools  @([ordered]@{
            id      = $script:DotnetToolId
            version = $script:DotnetToolReinstallVersion
        })
    $toolchainsDesired3b = New-ToolchainDesiredState

    Write-Host '' -ForegroundColor Magenta
    Write-Host ("Phase 3a: rewriting VmProvisionerConfig - VM1 changes JDK " +
                "$($script:JdkReinstallVersion) -> $($script:JdkInitialVersion) and " +
                "dotnet SDK $($script:DotnetReinstallResolvedVersion) -> $($script:DotnetInitialResolvedVersion) ...") `
        -ForegroundColor Magenta

    # 3a) VM1 entry: bump javaDevKit.version + dotnetSdk version. Both
    # are changed in the same provision run so the reconciler must
    # observably uninstall+install for each provider without the two
    # interfering. Everything else is unchanged.
    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Reconciler flow only: version-change the toolchain blocks in place.
    # Under ansible the blocks stay off the entry and the 3a desired state
    # drives the same swap via provision-toolchains.sh below.
    if (-not $tcx.IsAnsible) {
        $vm1Entry.javaDevKit = [ordered]@{
            vendor  = $script:JdkTestVendor
            version = $script:JdkInitialVersion
        }
        $vm1Entry.dotnetSdk = [ordered]@{
            channel = $script:DotnetInitialChannel
            version = $script:DotnetInitialResolvedVersion
        }
        # dotnetTools version flips from $DotnetToolInitialVersion (installed
        # by phase 2b) to $DotnetToolReinstallVersion at the same time as the
        # SDK version-change. Running both swaps in one provision run
        # exercises the walker on the SDK uninstall side (which must
        # dispatch the existing tool's Uninstall-Version before tearing
        # down the SDK so the SDK install dir is empty by the time it is
        # removed). After the SDK reinstall the tool provider then installs
        # the new tool version under the new SDK.
        $vm1Entry.dotnetTools = @(
            [ordered]@{
                id      = $script:DotnetToolId
                version = $script:DotnetToolReinstallVersion
            }
        )
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
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\PowerShell\provision.ps1" -SecretSuffix $script:E2ETestSecretSuffix

    # Ansible flow: drive the version-change via the 3a desired state (no-op
    # under custom-powershell, which swapped inside provision.ps1).
    Set-VmToolchainsForTest `
        -ToolchainsFlow  $tcx.Flow `
        -ProvisionerPath $Config.ProvisionerPath `
        -DesiredState    $toolchainsDesired3a `
        -WslDistro       $tcx.WslDistro

    Write-Host "Phase 3a: verifying version change on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm1Def
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName

        # Old-side cleanup + symlink re-target.
        Invoke-JdkVersionChangeAssertions `
            -SshClient                $sshClient `
            -VmName                   $Vm1Def.vmName `
            -PreviousRequestedVersion $script:JdkReinstallVersion `
            -NewRequestedVersion      $script:JdkInitialVersion `
            @jdkParams

        # New-side install (JAVA_HOME, PATH, java -version, manifest
        # present). Together with VersionChange's V1-V4 this covers the
        # full swap contract.
        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkInitialVersion `
            @jdkParams

        # Same swap pair for the dotnet SDK.
        Invoke-DotnetSdkVersionChangeAssertions `
            -SshClient                $sshClient `
            -VmName                   $Vm1Def.vmName `
            -PreviousResolvedVersion  $script:DotnetReinstallResolvedVersion `
            -NewResolvedVersion       $script:DotnetInitialResolvedVersion `
            @sdkParams

        Invoke-DotnetSdkInstallAssertions `
            -SshClient       $sshClient `
            -VmName          $Vm1Def.vmName `
            -ResolvedVersion $script:DotnetInitialResolvedVersion `
            @sdkParams

        # Old store gone + new store present + manifest swap + symlink
        # survives. The plain "install assertion against the new tool
        # version" pass below covers --version output, manifest contents,
        # and (reconciler flow) the parent SDK's children array referencing
        # the new tool manifest.
        Invoke-DotnetToolsVersionChangeAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -ToolId           $script:DotnetToolId `
            -PreviousVersion  $script:DotnetToolInitialVersion `
            -NewVersion       $script:DotnetToolReinstallVersion `
            -Command          $script:DotnetToolCommand `
            @toolParams

        Invoke-DotnetToolsInstallAssertions `
            -SshClient   $sshClient `
            -VmName      $Vm1Def.vmName `
            -ToolId      $script:DotnetToolId `
            -ToolVersion $script:DotnetToolReinstallVersion `
            -Command     $script:DotnetToolCommand `
            @toolParams @toolInstallExtra
    }

    # ------------------------------------------------------------------
    # 3b) Remove via empty list. javaDevKit = @() is the explicit
    # "ensure none" contract (companion to "drop the field" exercised
    # in 2a); envVars.entries = @() drives the managed-block removal.
    # ------------------------------------------------------------------
    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Phase 3b: rewriting VmProvisionerConfig - VM1 javaDevKit = @() + dotnetSdk = @() + envVars empty ...' `
        -ForegroundColor Magenta

    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Reconciler flow only: explicit empty lists are the "ensure none"
    # signal (distinct from 2a's explicit $null so both ensure-none
    # contracts are exercised). dotnetTools = @() combined with dotnetSdk =
    # @() exercises the composite tear-down: the tool provider goes first
    # per Get-Providers order, leaving the SDK's children array empty by the
    # time the SDK uninstall fires - the path plan step 7 step 4's
    # regression guard cares about (orphan manifest leftover would fail U3).
    # Under ansible the blocks stay off the entry and the empty 3b desired
    # state drives the uninstall via provision-toolchains.sh below.
    if (-not $tcx.IsAnsible) {
        $vm1Entry.javaDevKit  = @()
        $vm1Entry.dotnetSdk   = @()
        $vm1Entry.dotnetTools = @()
    }
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
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\PowerShell\provision.ps1" -SecretSuffix $script:E2ETestSecretSuffix

    # Ansible flow: drive the uninstall via the empty 3b desired state (no-op
    # under custom-powershell, which uninstalled inside provision.ps1).
    Set-VmToolchainsForTest `
        -ToolchainsFlow  $tcx.Flow `
        -ProvisionerPath $Config.ProvisionerPath `
        -DesiredState    $toolchainsDesired3b `
        -WslDistro       $tcx.WslDistro

    Write-Host "Phase 3b: verifying remove-via-empty on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            @jdkParams

        Invoke-DotnetSdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            @sdkParams

        Invoke-DotnetToolsUninstallAssertions `
            -SshClient $sshClient `
            -VmName    $Vm1Def.vmName `
            -ToolId    $script:DotnetToolId `
            -Command   $script:DotnetToolCommand `
            @toolParams

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

    # VM2 "no leak" witness - reconciler-only (see the phase 2 notes): under
    # ansible the driver reconciles globally, so VM2 is not a per-VM
    # isolation witness. Skip the whole SSH round-trip.
    if (-not $tcx.IsAnsible) {
        Write-Host ("Phase 3b: re-verifying VM2 has no JDK / dotnet " +
            "artifacts ($($Vm2Def.vmName)) ...") -ForegroundColor Magenta
        Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
            param($sshClient)
            Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
            Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm2Def
            Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
            Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
            Invoke-NoDotnetSdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        }
    }
}
