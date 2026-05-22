<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Infrastructure.Common, the assertion helpers, and the shared
    orchestrator helpers (New-VmEntryBase, Write-VmProvisionerConfig,
    Invoke-WithVmSshClient) are loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmProvisioningPhase1
#   Phase 1 - install JDK 21 on VM1 (plus single-file and bulk-pattern
#   file-transfer fixtures).
#
#   Single-VM VmProvisionerConfig so the baseline install path is
#   isolated from any multi-VM interaction. The mixed files array (one
#   single entry + one bulk entry) exercises per-entry dispatch in
#   Invoke-VmPostProvisioning end-to-end. Phase 2 re-provisions the same
#   VM with the same files array to assert idempotence (file contents
#   and mode unchanged), so the VM-side SHA-256s are captured here into
#   $script:Phase1*Shas and consumed there.
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
    & "$($Config.ProvisionerPath)\hyper-v\ubuntu\provision.ps1"

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
    }
}
