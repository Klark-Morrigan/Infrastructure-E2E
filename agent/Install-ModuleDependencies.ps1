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

    Step 2 - Infrastructure.Common: the chicken-and-egg case. It supplies
             Invoke-ModuleInstall used by every install below, so it cannot
             install itself - the inline guard is unavoidable.

    Step 3 - Everything else flows through Invoke-ModuleInstall.

.NOTES
    Initialize-E2EEnvironment.ps1 is the broader "set up the E2E session"
    script (provider registration, etc.) and dot-sources this file first.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Step 1 - NuGet provider
$_nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_nuget -or $_nuget.Version -lt [Version]'2.8.5.201') {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
        -Scope CurrentUser -Force -ForceBootstrap | Out-Null
}

# Step 2 - Infrastructure.Common (chicken-and-egg bootstrap)
$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'4.0.0') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force -AllowClobber
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

# Step 3 - Everything else
Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '3.0.1'
Invoke-ModuleInstall -ModuleName 'Infrastructure.GitHub'  -MinimumVersion '0.2.0'
Invoke-ModuleInstall -ModuleName 'Infrastructure.HyperV'  -MinimumVersion '0.2.0'
