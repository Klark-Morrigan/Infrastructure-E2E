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
      - PowerShell.Common >= 1.3.3 installed (or will be installed here).
      - Infrastructure.Secrets installed.
      - Run as Administrator (Hyper-V cmdlets require elevation).

.EXAMPLE
    # Run with all defaults (standard VmLAN setup):
    .\agent\e2e\vm-users\Start-VmUsersTest.ps1

.EXAMPLE
    # Override the VM IP if the default is already in use:
    .\agent\e2e\vm-users\Start-VmUsersTest.ps1 -IpAddress 192.168.101.11
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
. "$PSScriptRoot\Invoke-VmUsersTest.ps1"

Invoke-VmUsersTest -Config ([PSCustomObject]@{
    ProvisionerPath = $ProvisionerPath
    UsersPath       = $UsersPath
    UsersFlow       = $UsersFlow
    AnsiblePath     = $AnsiblePath
    WslDistro       = $WslDistro
    TestVm          = [PSCustomObject]@{
        ubuntuVersion = $UbuntuVersion
        ipAddress     = $IpAddress
        subnetMask    = $SubnetMask
        gateway       = $Gateway
        dns           = $Dns
        vmConfigPath  = $VmConfigPath
        vhdPath       = $VhdPath
    }
})
