<#
.SYNOPSIS
    Installs and imports every PowerShell module the Infrastructure-E2E agent
    needs.

.DESCRIPTION
    Centralised so Initialize-E2EEnvironment.ps1 (and any other E2E entry
    point) can dot-source one file instead of repeating the install/import
    block. Intentionally not a function: dot-sourcing imports every required
    module into the caller's scope.

    Step 1 - NuGet provider: PowerShellGet uses it to download from PSGallery.

    Step 2 - Common.PowerShell: the chicken-and-egg case. It supplies
             Invoke-ModuleInstall used by every install below, so it cannot
             install itself - the inline guard is unavoidable.

    Step 3 - Everything else flows through Invoke-ModuleInstall.

.NOTES
    Initialize-E2EEnvironment.ps1 is the broader "set up the E2E session"
    script (provider registration, etc.) and dot-sources this file first.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Install-PowerShellCommonWithRetry
#   The chicken-and-egg case: Invoke-ModuleInstall (which has retry built
#   in) lives inside Common.PowerShell, so it cannot be used to install
#   Common.PowerShell itself. A small inline retry wrapper here covers
#   that single bootstrap call. All later Invoke-ModuleInstall calls below
#   get retry for free.
#
#   Defaults mirror Invoke-ModuleInstall's: 6 attempts, exponential 10 s ->
#   20 -> 40 -> 80 -> 160, capped at 300 s (5 min). Total wait ~5 min
#   before giving up - long enough to ride out a transient PSGallery
#   resolution blip, short enough that a real outage fails the run.
# ---------------------------------------------------------------------------
function Install-PowerShellCommonWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Version] $MinimumVersion,
        [int] $MaxAttempts         = 6,
        [int] $InitialDelaySeconds = 10,
        [int] $MaxDelaySeconds     = 300
    )
    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            # -ErrorAction Stop promotes PSGallery "Unable to resolve
            # package source" (a non-terminating error by default) to a
            # terminating one so the catch block can retry it.
            Install-Module Common.PowerShell `
                -MinimumVersion $MinimumVersion `
                -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning (
                "Install-Module Common.PowerShell failed " +
                "(attempt $attempt/$MaxAttempts): " +
                "$($_.Exception.Message). Retrying in ${delay}s ..."
            )
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
        }
    }
}

# Step 1 - NuGet provider
$_nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_nuget -or $_nuget.Version -lt [Version]'2.8.5.201') {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Scope CurrentUser -Force -ForceBootstrap | Out-Null
}

# Step 2 - Common.PowerShell (chicken-and-egg bootstrap).
#
# The 6.2.0 floor is the first version that ships Assert-WslHasBash,
# called from Start-E2EAgent.ps1 to fail-fast when the named WSL distro
# does not have bash. An older 6.x in CurrentUser's module path would
# pass a looser version check and the agent would crash mid-startup
# with `The term 'Assert-WslHasBash' is not recognized`. Both the
# Get-Module gate and the Install-Module pin must move in lockstep -
# the gate decides whether to reinstall; the pin decides what to fetch.
$_common = Get-Module -ListAvailable -Name Common.PowerShell |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'7.0.0') {
    Install-PowerShellCommonWithRetry -MinimumVersion '7.0.0'
    # Re-query so the comparison below uses the freshly installed version.
    $_common = Get-Module -ListAvailable -Name Common.PowerShell |
        Sort-Object Version -Descending | Select-Object -First 1
}
# Reload only when the loaded state differs from the target (multiple
# versions live, or wrong version live). Mirrors the conditional in
# Invoke-ModuleInstall - inlined here because the bootstrap installs
# the very module that defines that function.
$_loaded = @(Get-Module -Name Common.PowerShell)
if ($_loaded.Count -ne 1 -or $_loaded[0].Version -ne $_common.Version) {
    if ($_loaded) { $_loaded | Remove-Module -Force }
    Import-Module Common.PowerShell -Force -ErrorAction Stop
}

# Step 3 - Everything else
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '3.0.1'
# 1.1.0 carries Get-PendingDeployment's -CreatedSince cutoff, which the
# polling loop relies on to avoid the N+1 status fan-out that exhausted the
# GitHub API rate limit. Pin the minimum so the agent never runs on an older
# copy that would crash-loop on 403.
Invoke-ModuleInstall -ModuleName 'Infrastructure.GitHub'  -MinimumVersion '1.1.0'
Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV'  -MinimumVersion '0.11.0'
# Infrastructure.Wsl supplies Invoke-WslShell + Assert-Wsl2Ready /
# Assert-WslHasBash. The agent's Ansible flow needs all three (one
# shell into WSL per playbook run, plus the readiness gates from
# Initialize-E2EEnvironment).
Invoke-ModuleInstall -ModuleName 'Infrastructure.Wsl'     -MinimumVersion '0.1.0'
