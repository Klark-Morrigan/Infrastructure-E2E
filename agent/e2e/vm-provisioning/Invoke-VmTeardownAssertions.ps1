<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after the script-scope test scenario constants are defined.
#>

# ---------------------------------------------------------------------------
# Invoke-VmTeardownAssertions
#   Asserts that the deprovision step actually achieved what it set out
#   to do. Called by Invoke-VmProvisioningTeardown at the end of its run
#   so the two are guaranteed to fire together - no caller can run
#   teardown and forget to verify it.
#
#   Verifies:
#     - All three VMs (router + VM1 + VM2) are gone from Hyper-V.
#     - Per-VM disk artifacts ({vmName}.vhdx under vhdPath,
#       {vmName}-seed.iso under vmConfigPath) are gone for each.
#     - The host-side JDK cache (tarball + lockfile for the versions used
#       in phases 1 and 3) is still present under vhdPath - the cache is
#       host-owned, not VM-owned, so deprovision must not touch it.
#     - The per-environment Private switch is gone (exclusive to this
#       test, so a leftover means teardown failed).
#     - The External vSwitch is still present - host-shared resource
#       that other consumers / non-test VMs attach to.
#
#   VM identities and paths come from script-scope constants + $Config, so
#   this function still works when Setup threw before any vmDef existed.
#
#   Best-effort failure-path callers of Teardown wrap it in try/catch and
#   Write-Warning on failure, so an assertion failure here surfaces as
#   a warning rather than masking the original error.
# ---------------------------------------------------------------------------

function Invoke-VmTeardownAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Config
    )

    Write-Host '' -ForegroundColor Magenta
    Write-Host 'Verifying teardown ...' -ForegroundColor Magenta

    # VMs gone from Hyper-V. Use the script-level names rather than $vmDef
    # so the check still works when phase 1 threw before returning a vmDef.
    foreach ($vmName in @($script:RouterVmName, $script:Vm1Name, $script:Vm2Name)) {
        if ($null -ne (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            throw "Teardown incomplete: VM '$vmName' still exists in Hyper-V."
        }
        Write-Host "  [OK] VM removed from Hyper-V: $vmName" -ForegroundColor Green
    }

    # Per-VM disk artifacts gone. {vmName}.vhdx lives under vhdPath;
    # {vmName}-seed.iso lives under vmConfigPath (see provisioner's
    # Invoke-DiskImageAcquisition.ps1 and generate-seed-iso.ps1). Both
    # are addressed by name so this check works even when a Setup throw
    # left no $vmDef behind.
    foreach ($vmName in @($script:RouterVmName, $script:Vm1Name, $script:Vm2Name)) {
        $vhdxPath = Join-Path $Config.TestVm.vhdPath "$vmName.vhdx"
        if (Test-Path -LiteralPath $vhdxPath) {
            throw "Teardown incomplete: VHDX still present at '$vhdxPath'."
        }
        $seedIsoPath = Join-Path $Config.TestVm.vmConfigPath "$vmName-seed.iso"
        if (Test-Path -LiteralPath $seedIsoPath) {
            throw "Teardown incomplete: seed ISO still present at '$seedIsoPath'."
        }
        Write-Host "  [OK] disk artifacts removed for $vmName" -ForegroundColor Green
    }

    # JDK cache must survive deprovision - it is host-owned, keyed by
    # {vendor, requestedVersion}, and may be shared by other VMs. The
    # cache files are named jdk-{vendor}-{version}-linux-x64.{tar.gz,lock.json}
    # per Invoke-JdkAcquisition.ps1's cache layout.
    foreach ($version in @($script:JdkInitialVersion, $script:JdkReinstallVersion)) {
        $cacheKey = "jdk-$script:JdkTestVendor-$version-linux-x64"
        $tarball  = Join-Path $Config.TestVm.vhdPath "$cacheKey.tar.gz"
        $lock     = Join-Path $Config.TestVm.vhdPath "$cacheKey.lock.json"
        if (-not (Test-Path -LiteralPath $tarball)) {
            throw "JDK cache regression: tarball missing at '$tarball'. " +
                "Deprovision must not touch the host-side cache."
        }
        if (-not (Test-Path -LiteralPath $lock)) {
            throw "JDK cache regression: lockfile missing at '$lock'. " +
                "Deprovision must not touch the host-side cache."
        }
        Write-Host "  [OK] JDK cache intact for $cacheKey" -ForegroundColor Green
    }

    # VmProvisionerConfig removed from the vault.
    $provisionerSecretName = Get-E2ESecretName 'VmProvisionerConfig'
    if ($null -ne (Get-SecretInfo -Vault VmProvisioner -Name $provisionerSecretName `
            -ErrorAction SilentlyContinue)) {
        throw "Teardown incomplete: $provisionerSecretName still present in vault."
    }
    Write-Host "  [OK] $provisionerSecretName removed from vault." -ForegroundColor Green

    # Per-environment Private switch is exclusive to this test (no
    # operator workload attaches to PrivateSwitch-E2E) so no guard is
    # needed - any leftover means teardown failed.
    if ($null -ne (Get-VMSwitch -Name $script:PrivateSwitchName `
            -ErrorAction SilentlyContinue)) {
        throw "Teardown incomplete: Private switch '$script:PrivateSwitchName' " +
            "still exists."
    }
    Write-Host "  [OK] Private switch removed: $script:PrivateSwitchName" `
        -ForegroundColor Green

    # External vSwitch must survive teardown - it is host-shared (other
    # consumers / non-test VMs attach to it) and was not created by
    # this test in the first place when the operator pre-staged it.
    # provision.ps1 also takes the "reuse existing External switch"
    # path when one already exists, so removing it here would be a
    # regression even if it had been created by an earlier test run.
    if ($null -eq (Get-VMSwitch -Name $Config.TestVm.externalSwitchName `
            -ErrorAction SilentlyContinue)) {
        throw "Host shared resource regression: External vSwitch " +
            "'$($Config.TestVm.externalSwitchName)' was removed by teardown."
    }
    Write-Host "  [OK] External vSwitch intact: $($Config.TestVm.externalSwitchName)" `
        -ForegroundColor Green
}
