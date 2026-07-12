BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\dotnet\Invoke-DotnetSdkUninstallAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Green-path answers describing a VM with the SDK fully removed. The
    # same rules hold for both manifest-store layouts - the probes differ
    # only in the paths they embed, asserted via IssuedCommands.
    function New-DotnetSdkUninstallRules {
        @(
            @{ Match = '*shopt -s nullglob*';  Output = '0' }
            @{ Match = '*test -e*';            Output = 'absent' }
            @{ Match = '*DOTNET_ROOT*';        Output = 'unset' }
            @{ Match = '*command -v dotnet*';  Output = '' }
            @{ Match = '*test -L*';            Output = 'absent' }
            @{ Match = '*ls -1*';              Output = '' }
        )
    }
}

Describe 'Invoke-DotnetSdkUninstallAssertions' {

    BeforeEach {
        # Silence the [OK] progress lines; the tests assert on the issued
        # probes and the throw/no-throw outcome, not on console output.
        Mock Write-Host {}
        $script:IssuedCommands = @()
        Mock Invoke-SshClientCommand {
            $script:IssuedCommands += $Command
            foreach ($rule in $script:SshRules) {
                if ($Command -like $rule.Match) { return New-SshResult $rule.Output }
            }
            return New-SshResult ''
        }
        $script:SshRules = New-DotnetSdkUninstallRules
    }

    It 'probes the PowerShell reconciler manifest store by default' {
        { Invoke-DotnetSdkUninstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -InstallPrefix '/opt/dotnet-' } | Should -Not -Throw

        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/infra-provisioner/manifests/dotnetSdk-*.json*'
        ).Count | Should -Be 1
    }

    It 'probes the common-ansible manifest store when overridden' {
        { Invoke-DotnetSdkUninstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -InstallPrefix '/opt/dotnet-' `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'dotnet_sdk-' } | Should -Not -Throw

        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/common-ansible/toolchains/manifests/dotnet_sdk-*.json*'
        ).Count | Should -Be 1
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*dotnetSdk-*').Count        | Should -Be 0
    }
}
