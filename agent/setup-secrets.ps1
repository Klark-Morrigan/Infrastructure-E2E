#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Stores the E2EConfig secret in the local SecretStore vault.

.DESCRIPTION
    One-time setup script. Run this before starting the E2E agent or any
    individual test script. Idempotent - safe to re-run to update the
    stored config.

.PARAMETER ConfigFile
    Path to a JSON file matching the E2EConfig schema. See README for the
    full field reference and an example.

.EXAMPLE
    .\agent\setup-secrets.ps1 -ConfigFile C:\private\e2e-config.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ConfigFile
)

. "$PSScriptRoot\Initialize-E2EEnvironment.ps1"

Initialize-MicrosoftPowerShellSecretStoreVault `
    -VaultName  'E2EConfig' `
    -SecretName 'E2EConfig' `
    @PSBoundParameters `
    -Validate {
        param($json)
        $config = $json | ConvertFrom-Json

        Assert-RequiredProperties -Object $config -Properties @(
            'AppId',
            'PrivateKeyPath',
            'E2EInstallationId',
            'RunnersInstallationId',
            'Owner',
            'Repo',
            'Environment',
            'PollIntervalSeconds',
            'TimeoutMinutes',
            'ProvisionerPath',
            'TestVm'
        ) -Context 'E2EConfig'

        Assert-RequiredProperties -Object $config.TestVm -Properties @(
            'ubuntuVersion',
            'ipAddress',
            'subnetMask',
            'gateway',
            'dns',
            'vmConfigPath',
            'vhdPath'
        ) -Context 'E2EConfig.TestVm'

        if (-not (Test-Path $config.PrivateKeyPath)) {
            throw "Private key file not found: $($config.PrivateKeyPath)"
        }
    }
