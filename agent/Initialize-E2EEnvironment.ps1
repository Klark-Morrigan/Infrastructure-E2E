<#
.NOTES
    Dot-source this file from every E2E entry-point script (Start-E2EAgent.ps1,
    Start-*Test.ps1) to ensure a consistent E2E session before any
    Infrastructure.* function is called.

    Concerns of this script: the runtime environment that wraps the modules
    (SecretStore provider registration, anything else session-wide).

    Module install / import is delegated to Install-ModuleDependencies.ps1
    so the dependency list lives in one place for this repo.
#>

. "$PSScriptRoot\Install-ModuleDependencies.ps1"

Use-MicrosoftPowerShellSecretStoreProvider
