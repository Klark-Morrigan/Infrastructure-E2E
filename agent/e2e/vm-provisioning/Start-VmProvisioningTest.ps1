<#
.SYNOPSIS
    Run the VM provisioning E2E test directly, without the polling agent.

.DESCRIPTION
    Bootstraps the required modules, then calls Invoke-VmProvisioningTest.
    Use this for on-demand test runs that do not need a GitHub deployment
    signal (local debugging, first-time verification).

    VmProvisionerConfig is written to the vault at runtime by
    Invoke-VmProvisioningSetup and removed in its finally block - no
    manual vault setup is required before running this script.

    Prerequisites:
      - PowerShell 7+.
      - PowerShell.Common >= 1.3.3 installed (or will be installed here).
      - Infrastructure.Secrets installed.
      - Run as Administrator (Hyper-V cmdlets require elevation).

.EXAMPLE
    # Run with all defaults (workstation has ExternalSwitch-Shared bound
    # to the 'Ethernet' adapter; router upstream IP 192.168.101.20).
    .\agent\e2e\vm-provisioning\Start-VmProvisioningTest.ps1

.EXAMPLE
    # Override the router's upstream IP if 192.168.101.20 is already in use.
    .\agent\e2e\vm-provisioning\Start-VmProvisioningTest.ps1 `
        -RouterExternalIp 192.168.100.50 -ExternalGateway 192.168.100.1
#>

[CmdletBinding()]
param(
    # Absolute path to the Infrastructure-Vm-Provisioner repo root.
    [string] $ProvisionerPath = 'C:\a_Code\Infrastructure-Vm-Provisioner',

    # Ubuntu version to provision (router + workload VMs).
    [string] $UbuntuVersion = '24.04',

    # Static IP for the router VM on the upstream LAN. Workload VMs use
    # internal private IPs (10.99.0.10 / .11) - only the router needs an
    # operator-supplied upstream address.
    [string] $RouterExternalIp = '192.168.101.20',

    # Upstream LAN CIDR prefix length.
    [int] $ExternalSubnetMask = 24,

    # Upstream LAN gateway IP (router's default route).
    [string] $ExternalGateway = '192.168.101.1',

    # DNS resolver the router VM forwards downstream queries to.
    [string] $Dns = '8.8.8.8',

    # Host's External vSwitch the router's upstream NIC attaches to.
    # Created on demand if absent (bound to -ExternalAdapterName).
    [string] $ExternalSwitchName = 'ExternalSwitch-Shared',

    # Physical adapter the External vSwitch binds to when created.
    # Ignored at runtime if the switch already exists.
    [string] $ExternalAdapterName = 'Ethernet',

    # Workstation path for Hyper-V VM config files.
    [string] $VmConfigPath = 'E:\a_VMs\Hyper-V\Config',

    # Workstation path for the test VHDX files.
    [string] $VhdPath = 'E:\a_VMs\Hyper-V\Disks'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\Initialize-E2EEnvironment.ps1"

# Dot-source the test script after PowerShell.Common is loaded because the
# test depends on Invoke-SshClientCommand and Invoke-ModuleInstall from it.
. "$PSScriptRoot\Invoke-VmProvisioningTest.ps1"

Invoke-VmProvisioningTest -Config ([PSCustomObject]@{
    ProvisionerPath = $ProvisionerPath
    TestVm          = [PSCustomObject]@{
        ubuntuVersion       = $UbuntuVersion
        routerExternalIp    = $RouterExternalIp
        externalSubnetMask  = $ExternalSubnetMask
        externalGateway     = $ExternalGateway
        dns                 = $Dns
        externalSwitchName  = $ExternalSwitchName
        externalAdapterName = $ExternalAdapterName
        vmConfigPath        = $VmConfigPath
        vhdPath             = $VhdPath
    }
})
