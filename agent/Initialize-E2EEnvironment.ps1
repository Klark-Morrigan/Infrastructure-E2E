<#
.NOTES
    Dot-source this file from every E2E entry-point script (Start-E2EAgent.ps1,
    Start-*Test.ps1) to ensure a consistent module environment before any
    Infrastructure.* function is called.

    Infrastructure.Common must be bootstrapped manually here because it provides
    Invoke-ModuleInstall - the helper used for every subsequent module install.
    It cannot install itself.
#>

$_common = Get-Module -ListAvailable -Name Infrastructure.Common |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $_common -or $_common.Version -lt [Version]'2.1.0') {
    Install-Module Infrastructure.Common -Scope CurrentUser -Force
}
Import-Module Infrastructure.Common -Force -ErrorAction Stop

Invoke-ModuleInstall -ModuleName 'Infrastructure.Secrets' -MinimumVersion '3.0.0'

Use-MicrosoftPowerShellSecretStoreProvider
