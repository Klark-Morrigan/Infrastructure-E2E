<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell, the assertion helpers, and the shared
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

    # Toolchain engine for this run (reconciler default, or ansible from
    # the deployment payload). $tcx bundles the flow, the branch boolean,
    # the engine-specific assertion params, and the WSL distro.
    $tcx = Get-ToolchainPhaseContext -Config $Config
    # Splat-ready engine params for this phase's assertions (reconciler
    # defaults under custom-powershell; the common-ansible store + prefix
    # under ansible). Splatting needs simple variables, hence the locals.
    $jdkParams        = $tcx.Params.Jdk
    $sdkParams        = $tcx.Params.Sdk
    $toolParams       = $tcx.Params.Tools
    $toolInstallExtra = $tcx.Params.ToolInstallExtra

    $entry = New-VmEntryBase `
        -Config    $Config `
        -VmName    $Vm1Def.vmName `
        -IpAddress $Vm1Def.ipAddress `
        -Password  $Vm1Def.password
    # Toolchain blocks: JDK 21 + dotnet SDK 8.0.100 + one global tool. The same
    # per-VM desired state feeds both engines - custom-powershell installs them
    # via provision.ps1's reconciler; ansible leaves them for
    # provision-toolchains.sh (provision.ps1 runs -SkipToolchains). Both read
    # these fields from VmProvisionerConfig.
    $entry.javaDevKit = [ordered]@{
        vendor  = $script:JdkTestVendor
        version = $script:JdkInitialVersion
    }
    # Co-tenant the dotnet SDK on VM1 from phase 1. Running JDK + dotnetSdk
    # through the same provision exercises the reconciler's multi-provider
    # dispatch order (JdkProvider then DotnetSdkProvider per Get-Providers) and
    # proves the two providers do not interfere with each other's manifest
    # writes.
    $entry.dotnetSdk = [ordered]@{
        channel = $script:DotnetInitialChannel
        version = $script:DotnetInitialResolvedVersion
    }
    # Co-tenant a single .NET global tool from phase 1. Together with dotnetSdk
    # above this drives DotnetToolsProvider end-to-end through the
    # nested-provider walker contract: SDK installs first, then the tool
    # installs against the host-prefetched .nupkg, and the SDK manifest's
    # children array gains a reference to the tool manifest.
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

    Write-Host 'Phase 1: provisioning router + VM1 ...' -ForegroundColor Magenta
    Invoke-ProvisionerForPhase -Config $Config -Tcx $tcx

    # provision.ps1 ran in its own scope and the discovered router IP
    # never made it back to the test's local _RouterVm reference. Look
    # it up again via Hyper-V KVP so the workload SSH jump (this phase's
    # post-condition checks below, and phases 2 / 3 - the same Vm1Def
    # carries forward) has a populated ipAddress to dial.
    Resolve-RouterIpFromKvp -RouterVmDef $Vm1Def._RouterVm

    # Under the ansible flow, install the toolchains via
    # provision-toolchains.sh now that provision.ps1 has brought the router
    # + VM1 up (it reads the same javaDevKit / dotnetSdk / dotnetTools fields
    # from VmProvisionerConfig). A no-op under custom-powershell (the reconciler
    # already installed them inside provision.ps1 above).
    Set-VmToolchainsForTest `
        -ToolchainsFlow  $tcx.Flow `
        -ProvisionerPath $Config.ProvisionerPath `
        -WslDistro       $tcx.WslDistro

    # Router-side white-box checks (forwarding, nftables/dnsmasq, NAT
    # rules, priv0 IP) are no longer asserted here: provision.ps1's
    # Assert-RouterReady runs them during provisioning and fails the run
    # if the router is not ready, so this suite inherits that coverage by
    # invoking provision.ps1 above rather than re-probing the router.

    Write-Host "Phase 1: verifying post-conditions on $($Vm1Def.vmName) ..." `
        -ForegroundColor Magenta
    Invoke-WithVmSshClient -VmDef $Vm1Def -Assertions {
        param($sshClient)

        Invoke-VmReadyAssertions -SshClient $sshClient -VmName $Vm1Def.vmName

        Invoke-StaticNetworkAssertions -SshClient $sshClient -VmDef $Vm1Def

        # Egress through the router. Runs before any opt-in install
        # assertion so a network regression surfaces before JDK /
        # dotnet failures that depend on the same egress.
        Invoke-EgressAssertions -SshClient $sshClient -VmName $Vm1Def.vmName

        Invoke-JdkInstallAssertions `
            -SshClient        $sshClient `
            -VmName           $Vm1Def.vmName `
            -RequestedVersion $script:JdkInitialVersion `
            @jdkParams

        Invoke-DotnetSdkInstallAssertions `
            -SshClient       $sshClient `
            -VmName          $Vm1Def.vmName `
            -ResolvedVersion $script:DotnetInitialResolvedVersion `
            @sdkParams

        # Tool install assertions follow the SDK install assertions
        # because I5 reads the parent SDK manifest (reconciler flow) - the
        # SDK assertions have already verified that manifest is present and
        # well-formed at this point. Under ansible, @toolInstallExtra carries
        # -SkipReconcilerManifestSchema so the content + walker checks (which
        # that engine does not produce) are bypassed.
        Invoke-DotnetToolsInstallAssertions `
            -SshClient   $sshClient `
            -VmName      $Vm1Def.vmName `
            -ToolId      $script:DotnetToolId `
            -ToolVersion $script:DotnetToolInitialVersion `
            -Command     $script:DotnetToolCommand `
            @toolParams @toolInstallExtra

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
        # touch them. Reconciler-only: the no-op rerun probes provision.ps1's
        # diff branch, but under ansible provision.ps1 runs -SkipToolchains so
        # the reconciler never touches toolchains and there is no no-op branch
        # to probe. Capture the snapshots only when they will be consumed.
        if (-not $tcx.IsAnsible) {
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
    }

    # No-op rerun. Same VmProvisionerConfig already on disk - the
    # reconciler must take the diff's no-op branch for every artifact. This
    # asserts a property of the PowerShell reconciler (re-provision does not
    # re-extract unchanged toolchains); under ansible provision.ps1 runs
    # -SkipToolchains, so re-running it never touches toolchains and there is
    # no equivalent no-op branch to probe - the
    # ansible flow is done after its install assertions above.
    if ($tcx.IsAnsible) { return }

    Write-Host 'Phase 1: re-provisioning VM1 with unchanged JSON (no-op) ...' `
        -ForegroundColor Magenta
    Invoke-ProvisionerForPhase -Config $Config -Tcx $tcx

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
