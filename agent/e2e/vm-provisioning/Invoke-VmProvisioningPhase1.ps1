<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after PowerShell.Common, the assertion helpers, and the shared
    orchestrator helpers (New-VmEntryBase, Write-VmProvisionerConfig,
    Invoke-WithVmSshClient) are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase1
#   Phase 1 - install JDK 21 on VM1 (plus single-file and bulk-pattern
#   file-transfer fixtures), then re-provision with the same JSON to
#   prove the reconciler's no-op branch.
#
#   Single-VM VmProvisionerConfig so the baseline install path is
#   isolated from any multi-VM interaction. The mixed files array (one
#   single entry + one bulk entry) exercises per-entry dispatch in
#   Invoke-VmPostProvisioning end-to-end. Phase 2 re-provisions the same
#   VM with the same files array to assert idempotence (file contents
#   and mode unchanged), so the VM-side SHA-256s are captured here into
#   $script:Phase1*Shas and consumed there.
#
#   The no-op rerun at the end snapshots the JDK artifact mtimes after the
#   first provision, calls provision.ps1 again with the SAME JSON, and
#   asserts the mtimes did not move. A regression where the JdkProvider
#   re-extracts unconditionally would only fail here.
# ---------------------------------------------------------------------------

function Invoke-VmProvisioningPhase1 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [Parameter(Mandatory)] [PSCustomObject] $Vm1Def
    )

    Write-Host '' -ForegroundColor Magenta
    Write-Host "Phase 1: writing single-VM VmProvisionerConfig (VM1 + JDK $($script:JdkInitialVersion) + dotnet SDK $($script:DotnetInitialResolvedVersion)) ..." `
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
    # Co-tenant the dotnet SDK on VM1 from phase 1. Running JDK +
    # dotnetSdk through the same provision exercises the reconciler's
    # multi-provider dispatch order (JdkProvider then DotnetSdkProvider
    # per Get-Providers) and proves the two providers do not interfere
    # with each other's manifest writes.
    $entry.dotnetSdk = [ordered]@{
        channel = $script:DotnetInitialChannel
        version = $script:DotnetInitialResolvedVersion
    }
    # Co-tenant a single .NET global tool from phase 1. Together with
    # dotnetSdk above this drives DotnetToolsProvider end-to-end through
    # the nested-provider walker contract: SDK installs first, then the
    # tool installs against the host-prefetched .nupkg, and the SDK
    # manifest's children array gains a reference to the tool manifest.
    $entry.dotnetTools = @(
        [ordered]@{
            id      = $script:DotnetToolId
            version = $script:DotnetToolInitialVersion
        }
    )
    # Mixed files array: one single entry + one bulk entry. JSON order is
    # preserved by the per-entry dispatch in Invoke-VmPostProvisioning;
    # asserting both forms in one provision run covers the "mixed dispatch"
    # acceptance criterion from docs/dev/implementation/07 - ci jars.
    $entry.files = @(
        [ordered]@{
            source = $script:FileTransferSource
            target = $script:FileTransferTarget
        },
        [ordered]@{
            pattern   = $script:BulkFileTransferPattern
            targetDir = $script:BulkFileTransferTargetDir
        }
    )
    # envVars: write a managed block with two entries. Phases 2 / 3
    # narrow this to one entry and then to empty - the three states
    # cover write / re-write / remove on the same VM.
    $entry.envVars = [ordered]@{
        blockName = $script:EnvVarsBlockName
        entries   = @(
            [ordered]@{ name = $script:EnvVarsFooHome.Name; value = $script:EnvVarsFooHome.Value },
            [ordered]@{ name = $script:EnvVarsBarVar.Name;  value = $script:EnvVarsBarVar.Value }
        )
    }

    Write-VmProvisionerConfig -Entries @($entry)

    Write-Host 'Phase 1: provisioning VM1 ...' -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1" -SecretSuffix $script:E2ETestSecretSuffix

    Write-Host "Phase 1: verifying post-conditions on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)

        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName

        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm1Def

        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkInitialVersion `
            -InstallPrefix    $script:JdkInstallPrefix

        Invoke-DotnetSdkInstallAssertions `
            -SshClient       $sshClient `
            -VmName          $Vm1Def.vmName `
            -ResolvedVersion $script:DotnetInitialResolvedVersion `
            -InstallPrefix   $script:DotnetInstallPrefix

        # Tool install assertions follow the SDK install assertions
        # because I5 reads the parent SDK manifest - the SDK assertions
        # have already verified that manifest is present and well-formed
        # at this point.
        Invoke-DotnetToolsInstallAssertions `
            -SshClient   $sshClient `
            -VmName      $Vm1Def.vmName `
            -ToolId      $script:DotnetToolId `
            -ToolVersion $script:DotnetToolInitialVersion `
            -Command     $script:DotnetToolCommand

        # Capture VM-side SHA-256s so phase 2 can assert idempotence by
        # snapshot. Helpers also assert C2-C5 (single) / C1-C4 (bulk)
        # against the host source on the way past.
        $script:Phase1SingleSha = Invoke-FileTransferAssertions `
            -SshClient  $sshClient `
            -VmName     $Vm1Def.vmName `
            -SourcePath $script:FileTransferSource `
            -TargetPath $script:FileTransferTarget

        $script:Phase1BulkShas = Invoke-BulkFileTransferAssertions `
            -SshClient $sshClient `
            -VmName    $Vm1Def.vmName `
            -SourceDir $script:BulkFileTransferSourceDir `
            -TargetDir $script:BulkFileTransferTargetDir `
            -BaseNames $script:BulkFileTransferBaseNames

        # envVars: E1, E2, E4, E5. -ExpectedMarkerLine is intentionally
        # omitted here because the marker is seeded AFTER these
        # assertions pass - VM1 does not exist before phase 1 so there
        # is no opportunity to seed it pre-provision (see
        # docs/dev/implementation/08 - env vars/plan.md step 5).
        Invoke-EnvVarsAppliedAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -BlockName        $script:EnvVarsBlockName `
            -ExpectedEntries  @($script:EnvVarsFooHome, $script:EnvVarsBarVar)

        # Seed MARKER_OUTSIDE outside the managed block and snapshot
        # the resulting mtime. Phases 2 and 3 use both: phase 2 to
        # assert the re-write left the marker alone AND advanced the
        # mtime, phase 3 to assert removal left the marker alone.
        Set-VmEnvironmentMarkerAndSnapshotMtime `
            -SshClient $sshClient -VmName $Vm1Def.vmName

        # Snapshot the JDK artifacts AFTER the install assertions pass
        # so the no-op rerun below can prove the reconciler did not
        # touch them.
        $script:Phase1JdkSnapshot = Get-JdkArtifactSnapshot `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            -InstallPrefix $script:JdkInstallPrefix

        # Same snapshot for the dotnet SDK so the no-op rerun proves
        # the DotnetSdkProvider also took the diff's no-op branch.
        $script:Phase1DotnetSnapshot = Get-DotnetSdkArtifactSnapshot `
            -SshClient     $sshClient `
            -VmName        $Vm1Def.vmName `
            -InstallPrefix $script:DotnetInstallPrefix
    }

    # No-op rerun. Same VmProvisionerConfig already on disk - the
    # reconciler must take the diff's no-op branch for every artifact.
    Write-Host 'Phase 1: re-provisioning VM1 with unchanged JSON (no-op) ...' `
        -ForegroundColor Magenta
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1" -SecretSuffix $script:E2ETestSecretSuffix

    Write-Host "Phase 1: verifying no-op rerun did not touch JDK / dotnet artifacts ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)
        Invoke-JdkNoopAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -InstallPrefix    $script:JdkInstallPrefix `
            -PreviousSnapshot $script:Phase1JdkSnapshot

        Invoke-DotnetSdkNoopAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -InstallPrefix    $script:DotnetInstallPrefix `
            -PreviousSnapshot $script:Phase1DotnetSnapshot
    }
}
