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
    [string] $ConfigFile,

    # Required. The secret is written as `E2EConfig-<Suffix>`. Operator
    # runs pass `Production`; ephemeral fixtures pass their own label.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SecretSuffix
)

. "$PSScriptRoot\Initialize-E2EEnvironment.ps1"

# Forward the secret-store cmdlet only the params it knows about.
$initParams = @{}
foreach ($k in 'ConfigFile') {
    if ($PSBoundParameters.ContainsKey($k)) {
        $initParams[$k] = $PSBoundParameters[$k]
    }
}

Initialize-MicrosoftPowerShellSecretStoreVault `
    -VaultName  'E2EConfig' `
    -SecretName "E2EConfig-$SecretSuffix" `
    @initParams `
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
            'UsersPath',
            'RunnersPath',
            'HostTarballCachePath',
            'TestVm'
        ) -Context 'E2EConfig'

        Assert-RequiredProperties -Object $config.TestVm -Properties @(
            'ubuntuVersion',
            'dns',
            'externalSwitchName',
            'externalAdapterName',
            # Pinned-static router upstream. Required so the run does
            # not silently fall back to DHCP - DHCP-mode collides via
            # shared MAC at the AP on bridged Wi-Fi, and silently
            # breaks across Wi-Fi network changes on Internal+ICS
            # (memories: hyperv-external-switch-wifi,
            # hyperv-internal-plus-ics).
            'routerExternalIp',
            'routerExternalGateway',
            'vmConfigPath',
            'vhdPath'
        ) -Context 'E2EConfig.TestVm'

        if (-not (Test-Path $config.PrivateKeyPath)) {
            throw "Private key file not found: $($config.PrivateKeyPath)"
        }
    }
