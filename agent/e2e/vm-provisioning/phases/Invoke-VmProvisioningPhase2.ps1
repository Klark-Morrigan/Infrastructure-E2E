<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell, the assertion helpers, and the shared
    orchestrator helpers are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase2
#   Phase 2 - uninstall-via-null on VM1, add VM2 (no javaDevKit), then
#   re-add javaDevKit on VM1 with a different version.
#
#   Sub-phase 2a (first provision):
#     - VM1 entry has javaDevKit = $null (explicit JSON null). This is
#       one of the two reconciler-era "ensure none" signals - the legacy
#       'uninstall: true' sub-field was deleted in feature 42. (Note:
#       dropping the javaDevKit field entirely means "skip this provider",
#       NOT "uninstall" - see Get-JdkDesiredVersions for the rationale.
#       That's why we use explicit null here rather than omitting the
#       field; phase 3b exercises the @() form for symmetry.)
#     - VM2 added with no javaDevKit (field absent => skip provider; the
#       freshly created VM has nothing to skip, so the end state is
#       "no JDK").
#     - One provision run executes both changes - the regression-catching
#       shape: a JDK removal on VM1 must not leak any JDK step onto a
#       freshly created VM2 in the same run.
#
#   Sub-phase 2b (second provision):
#     - VM1 entry gains javaDevKit = { temurin / $JdkReinstallVersion }.
#     - VM2 entry unchanged.
#     - Proves the reconciler installs from scratch when desired moves
#       from empty -> a single version (the "reinstall after removal"
#       scenario from feature 42's plan).
#
#   VM1's `files` array is carried forward unchanged from phase 1 across
#   both sub-phases so the bulk-files plan's idempotence assertion still
#   has snapshot data to validate against. envVars narrow to one entry
#   in 2a (forces a content-change rewrite, so the mtime-advance check
#   below has signal) and stay narrowed in 2b (no churn there).
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def,
        [Parameter(Mandatory)] [PSCustomObject] $Vm2Def
    )

    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Phase 2a: rewriting VmProvisionerConfig - VM1 javaDevKit=$null + dotnetSdk=$null + add VM2 ...' `
        -ForegroundColor Magenta

    # 2a) VM1 entry: javaDevKit = $null (explicit JSON null is the
    # "ensure none installed" signal in the reconciler contract;
    # ConvertTo-Json renders $null as JSON null which the validator
    # accepts and Get-JdkDesiredVersions maps to @()).
    $vm1Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    $vm1Entry.javaDevKit = $null
    # dotnetSdk = $null follows the same contract as javaDevKit: explicit
    # JSON null = "ensure none installed". The dotnet provider's
    # Get-DesiredVersions then returns @() and the reconciler drives the
    # uninstall path.
    $vm1Entry.dotnetSdk = $null
    # Carry the phase-1 files array forward unchanged so the bulk + single
    # idempotence assertions below have something to validate against.
    $vm1Entry.files = @(
        [ordered]@{
            source = $script:FileTransferSource
            target = $script:FileTransferTarget
        },
        [ordered]@{
            pattern   = $script:BulkFileTransferPattern
            targetDir = $script:BulkFileTransferTargetDir
        }
    )
    # envVars: narrow to one entry. BAR_VAR is dropped so the
    # transport's desired-vs-existing compare sees a content
    # difference - the block must be rewritten (proves the
    # skip-unchanged path does not falsely skip a real change).
    $vm1Entry.envVars = [ordered]@{
        blockName = $script:EnvVarsBlockName
        entries   = @(
            [ordered]@{ name = $script:EnvVarsFooHome.Name; value = $script:EnvVarsFooHome.Value }
        )
    }

    # VM2 entry: no javaDevKit, no files. Plain VM creation so we can
    # observe that no JDK step touched it (B-assertions).
    $vm2Entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm2Def.vmName `
        -IpAddress $Vm2Def.ipAddress `
        -Password  $Vm2Def.password

    Write-VmProvisionerConfig -Entries @($vm1Entry, $vm2Entry)

    Write-Host 'Phase 2a: provisioning (uninstall via absent on VM1, create VM2) ...' `
        -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1" -SecretSuffix $script:E2ETestSecretSuffix

    Write-Host "Phase 2a: verifying uninstall-via-absent on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm1Def
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            -InstallPrefix $script:JdkInstallPrefix

        Invoke-DotnetSdkUninstallAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            -InstallPrefix $script:DotnetInstallPrefix

        # dotnetTools entry was dropped from VM1's JSON in this phase
        # (the SDK is being uninstalled, so co-tenanted tools must go
        # too). Asserts the walker / provider combination left no
        # orphaned store dir, symlink, or manifest behind. This is the
        # E2E backing for plan step 7 step 4's "regression guard for the
        # walker" - a future regression that left tool manifests behind
        # after a parent SDK uninstall would fail U3.
        Invoke-DotnetToolsUninstallAssertions `
            -SshClient $sshClient `
            -VmName    $Vm1Def.vmName `
            -ToolId    $script:DotnetToolId `
            -Command   $script:DotnetToolCommand

        # Idempotence: re-run the file-transfer assertions on the
        # re-provisioned VM. The phase-1 snapshots assert that nothing
        # externally visible about the file targets changed across the
        # re-provision (file contents and mode), per the bulk-files plan.
        Invoke-FileTransferAssertions `
            -SshClient    $sshClient `
            -VmName       $Vm1Def.vmName `
            -SourcePath   $script:FileTransferSource `
            -TargetPath   $script:FileTransferTarget `
            -ExpectedHash $script:Phase1SingleSha | Out-Null

        Invoke-BulkFileTransferAssertions `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            -SourceDir     $script:BulkFileTransferSourceDir `
            -TargetDir     $script:BulkFileTransferTargetDir `
            -BaseNames     $script:BulkFileTransferBaseNames `
            -ExpectedShas  $script:Phase1BulkShas | Out-Null

        # envVars: E1, E2, E3 (MARKER survived), E4' (FOO_HOME still in
        # the block, BAR_VAR's removed). The function also re-checks
        # pam_env (E5) for the still-present FOO_HOME, which doubles
        # as a regression guard: a transport bug that broke the file
        # mid-rewrite would show up as a missing pam_env value here.
        Invoke-EnvVarsAppliedAssertions `
            -SshClient          $sshClient `
            -VmName             $Vm1Def.vmName `
            -BlockName          $script:EnvVarsBlockName `
            -ExpectedEntries    @($script:EnvVarsFooHome) `
            -ExpectedMarkerLine $script:EnvVarsMarkerLine

        # Explicitly check BAR_VAR is gone from any line (E4'). The
        # applied-assertions function only checks that the entries we
        # passed in are present; absence of removed entries is the
        # complementary half.
        Assert-EtcEnvironmentLineAbsent `
            -SshClient $sshClient -VmName $Vm1Def.vmName `
            -Pattern   "^$($script:EnvVarsBarVar.Name)="

        # E6: file mtime advanced versus phase 1's snapshot. Proves the
        # transport rewrote the block (BAR_VAR removal forced the
        # desired != existing branch).
        Assert-EtcEnvironmentMtimeAdvanced `
            -SshClient $sshClient -VmName $Vm1Def.vmName
    }

    Write-Host "Phase 2a: verifying VM2 has no JDK / dotnet artifacts ($($Vm2Def.vmName)) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm2Def
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-NoDotnetSdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
    }

    # ------------------------------------------------------------------
    # 2b) Re-add javaDevKit on VM1 (reinstall scenario).
    # ------------------------------------------------------------------
    Write-Host '' -ForegroundColor Magenta
    Write-Host "Phase 2b: rewriting VmProvisionerConfig - VM1 re-adds JDK $($script:JdkReinstallVersion) + dotnet SDK $($script:DotnetReinstallResolvedVersion) ..." `
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
    # Reinstall the dotnet SDK on the *other* channel/version so the
    # reconciler must drive a fresh install (empty -> single version)
    # for both providers in the same run.
    $vm1Entry.dotnetSdk = [ordered]@{
        channel = $script:DotnetReinstallChannel
        version = $script:DotnetReinstallResolvedVersion
    }
    # Re-co-tenant the same tool at its initial pin. Phase 3a then
    # version-changes it to $DotnetToolReinstallVersion alongside the
    # SDK version-change so the swap is observable in a single
    # provision run.
    $vm1Entry.dotnetTools = @(
        [ordered]@{
            id      = $script:DotnetToolId
            version = $script:DotnetToolInitialVersion
        }
    )
    # files + envVars carry forward unchanged from 2a so the only diff
    # the reconciler sees is the new javaDevKit field. No mtime-advance
    # assertion here (envVars block content unchanged - the transport
    # legitimately skips the rewrite).
    $vm1Entry.files = @(
        [ordered]@{
            source = $script:FileTransferSource
            target = $script:FileTransferTarget
        },
        [ordered]@{
            pattern   = $script:BulkFileTransferPattern
            targetDir = $script:BulkFileTransferTargetDir
        }
    )
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

    Write-Host 'Phase 2b: provisioning (re-add JDK on VM1) ...' `
        -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1" -SecretSuffix $script:E2ETestSecretSuffix

    Write-Host "Phase 2b: verifying JDK $($script:JdkReinstallVersion) + dotnet SDK $($script:DotnetReinstallResolvedVersion) reinstalled on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName
        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkReinstallVersion `
            -InstallPrefix    $script:JdkInstallPrefix

        Invoke-DotnetSdkInstallAssertions `
            -SshClient       $sshClient `
            -VmName          $Vm1Def.vmName `
            -ResolvedVersion $script:DotnetReinstallResolvedVersion `
            -InstallPrefix   $script:DotnetInstallPrefix

        Invoke-DotnetToolsInstallAssertions `
            -SshClient   $sshClient `
            -VmName      $Vm1Def.vmName `
            -ToolId      $script:DotnetToolId `
            -ToolVersion $script:DotnetToolInitialVersion `
            -Command     $script:DotnetToolCommand
    }

    Write-Host "Phase 2b: re-verifying VM2 has no JDK / dotnet artifacts ($($Vm2Def.vmName)) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm2Def -Assertions {
        param($sshClient)
        Invoke-NoJdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
        Invoke-NoDotnetSdkVmAssertions -SshClient $sshClient -VmName $Vm2Def.vmName
    }
}
