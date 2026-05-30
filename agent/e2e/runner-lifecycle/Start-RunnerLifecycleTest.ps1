<#
.SYNOPSIS
    Run the runner lifecycle E2E test directly, without the polling agent.

.DESCRIPTION
    Bootstraps the required modules, then calls Invoke-RunnerLifecycleTest.
    Use this for on-demand test runs that do not need a GitHub deployment
    signal (local debugging, first-time verification).

    VmProvisionerConfig, VmUsersConfig, and GitHubRunnersConfig are written
    to their respective vaults at runtime and removed in the finally block -
    no manual vault setup is required before running this script.

    Prerequisites:
      - PowerShell 7+.
      - PowerShell.Common >= 1.3.3 installed (or will be installed here).
      - Infrastructure.Secrets installed.
      - Run as Administrator (Hyper-V cmdlets require elevation).
      - GitHub App private key (.pem) accessible at PrivateKeyPath.

.EXAMPLE
    # Run with all defaults (standard VmLAN setup):
    .\agent\e2e\runner-lifecycle\Start-RunnerLifecycleTest.ps1 `
        -AppId 123456 `
        -RunnersInstallationId 222222 `
        -PrivateKeyPath C:\certs\my-app.private-key.pem `
        -Owner my-org

.EXAMPLE
    # Override the VM IP if the default is already in use:
    .\agent\e2e\runner-lifecycle\Start-RunnerLifecycleTest.ps1 `
        -AppId 123456 `
        -RunnersInstallationId 222222 `
        -PrivateKeyPath C:\certs\my-app.private-key.pem `
        -Owner my-org `
        -IpAddress 192.168.101.11
#>

[CmdletBinding()]
param(
    # GitHub App ID. Used to mint a token for runner registration.
    [Parameter(Mandatory)]
    [int] $AppId,

    # GitHub App installation ID for Infrastructure-GitHubRunners.
    # Used to scope the runner registration token to administration:write
    # on that repo only.
    [Parameter(Mandatory)]
    [int] $RunnersInstallationId,

    # Absolute path to the GitHub App RSA private key (.pem).
    [Parameter(Mandatory)]
    [string] $PrivateKeyPath,

    # GitHub organisation or user that owns the runners repo.
    [Parameter(Mandatory)]
    [string] $Owner,

    # Absolute path to the Infrastructure-Vm-Provisioner repo root.
    [string] $ProvisionerPath = 'C:\a_Code\Infrastructure-Vm-Provisioner',

    # Absolute path to the Infrastructure-Vm-Users repo root.
    [string] $UsersPath = 'C:\a_Code\Infrastructure-Vm-Users',

    # Absolute path to the Infrastructure-GitHubRunners repo root.
    [string] $RunnersPath = 'C:\a_Code\Infrastructure-GitHubRunners',

    # Local directory where the actions/runner tarball is cached between
    # test runs to avoid downloading through the Hyper-V NAT each time.
    [string] $HostTarballCachePath = 'C:\cache\github-runners',

    # Ubuntu version to provision.
    [string] $UbuntuVersion = '24.04',

    # Static IP to assign to the test VM on the dedicated E2E-VmLAN subnet.
    [string] $IpAddress = '192.168.101.10',

    # E2E-VmLAN CIDR prefix length.
    [int] $SubnetMask = 24,

    # E2E-VmLAN gateway IP.
    [string] $Gateway = '192.168.101.1',

    # DNS server for the test VM.
    [string] $Dns = '8.8.8.8',

    # Workstation path for Hyper-V VM config files.
    [string] $VmConfigPath = 'E:\a_VMs\Hyper-V\Config',

    # Workstation path for the test VM VHDX.
    [string] $VhdPath = 'E:\a_VMs\Hyper-V\Disks'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\Initialize-E2EEnvironment.ps1"

# Dot-source the test script after PowerShell.Common is loaded because
# the test depends on Invoke-SshClientCommand and Invoke-ModuleInstall
# from it.
. "$PSScriptRoot\Invoke-RunnerLifecycleTest.ps1"

Invoke-RunnerLifecycleTest -Config ([PSCustomObject]@{
    AppId                 = $AppId
    RunnersInstallationId = $RunnersInstallationId
    PrivateKeyPath        = $PrivateKeyPath
    Owner                 = $Owner
    ProvisionerPath       = $ProvisionerPath
    UsersPath             = $UsersPath
    RunnersPath           = $RunnersPath
    HostTarballCachePath  = $HostTarballCachePath
    TestVm                = [PSCustomObject]@{
        ubuntuVersion = $UbuntuVersion
        ipAddress     = $IpAddress
        subnetMask    = $SubnetMask
        gateway       = $Gateway
        dns           = $Dns
        vmConfigPath  = $VmConfigPath
        vhdPath       = $VhdPath
    }
})
