<#
.SYNOPSIS
    Run the VM users E2E test directly, without the polling agent.

.DESCRIPTION
    Bootstraps the required modules, then calls Invoke-VmUsersTest.
    Use this for on-demand test runs that do not need a GitHub deployment
    signal (local debugging, first-time verification).

    VmProvisionerConfig and VmUsersConfig are written to their respective
    vaults at runtime and removed in the finally block - no manual vault
    setup is required before running this script.

    Prerequisites:
      - PowerShell 7+.
      - Common.PowerShell >= 1.3.3 installed (or will be installed here).
      - Infrastructure.Secrets installed.
      - Run as Administrator (Hyper-V cmdlets require elevation).

.EXAMPLE
    # Run with all defaults (workstation has ExternalSwitch-Shared bound
    # to the 'Ethernet' adapter; router upstream IP 192.168.101.20).
    .\agent\e2e\vm-users\Start-VmUsersTest.ps1

.EXAMPLE
    # Override the router's upstream IP if 192.168.101.20 is already in use.
    .\agent\e2e\vm-users\Start-VmUsersTest.ps1 -RouterExternalIp 192.168.100.50 `
        -ExternalGateway 192.168.100.1
#>

[CmdletBinding()]
param(
    # Absolute path to the Infrastructure-Vm-Provisioner repo root.
    [string] $ProvisionerPath = 'C:\a_Code\Infrastructure-Vm-Provisioner',

    # Absolute path to the Infrastructure-Vm-Users repo root.
    [string] $UsersPath = 'C:\a_Code\Infrastructure-Vm-Users',

    # Selects the create-users implementation. Default 'ansible' so the
    # post-feature-02 primary path runs with no extra flags; pass
    # 'custom-powershell' to keep validating the original Vm-Users flow.
    # Both flows are permanent first-class peers - neither is legacy.
    [ValidateSet('custom-powershell', 'ansible')]
    [string] $UsersFlow = 'ansible',

    # Absolute path to the Infrastructure-VM-Ansible repo root. Required
    # when -UsersFlow ansible (the default); ignored otherwise. The
    # dispatcher fails fast when it is missing under UsersFlow=ansible.
    [string] $AnsiblePath = 'C:\a_Code\Infrastructure-VM-Ansible',

    # Name of the WSL distro the Ansible bridge runs inside. Required
    # when -UsersFlow ansible (the default); ignored otherwise. Passed
    # via `wsl -d <name>` so the test does not depend on the
    # workstation's WSL default (which Docker Desktop silently
    # changes to its no-bash 'docker-desktop' engine distro).
    [string] $WslDistro = 'Ubuntu-24.04',

    # Ubuntu version to provision (router + workload VMs).
    [string] $UbuntuVersion = '24.04',

    # DNS resolver the router VM forwards downstream queries to.
    # ext0 itself DHCPs from the host's External-vSwitch upstream;
    # see Start-VmProvisioningTest.ps1 for the rationale.
    [string] $Dns = '8.8.8.8',

    # Host's External vSwitch the router's upstream NIC attaches to.
    [string] $ExternalSwitchName = 'ExternalSwitch-Shared',

    # Physical adapter the External vSwitch binds to when created.
    [string] $ExternalAdapterName = 'Ethernet',

    # Workstation path for Hyper-V VM config files.
    [string] $VmConfigPath = 'E:\a_VMs\Hyper-V\Config',

    # Workstation path for the test VHDX files.
    [string] $VhdPath = 'E:\a_VMs\Hyper-V\Disks'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\..\Initialize-E2EEnvironment.ps1"

# Dot-source the test script after Common.PowerShell is loaded because
# the test depends on Invoke-SshClientCommand and Invoke-ModuleInstall
# from it.
. "$PSScriptRoot\Invoke-VmUsersTest.ps1"

Invoke-VmUsersTest -Config ([PSCustomObject]@{
    ProvisionerPath = $ProvisionerPath
    UsersPath       = $UsersPath
    UsersFlow       = $UsersFlow
    AnsiblePath     = $AnsiblePath
    WslDistro       = $WslDistro
    TestVm          = [PSCustomObject]@{
        ubuntuVersion       = $UbuntuVersion
        dns                 = $Dns
        externalSwitchName  = $ExternalSwitchName
        externalAdapterName = $ExternalAdapterName
        vmConfigPath        = $VmConfigPath
        vhdPath             = $VhdPath
    }
})
