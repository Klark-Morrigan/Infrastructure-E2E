BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\dotnet\Invoke-DotnetSdkVersionChangeAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Green-path answers for a clean 8.0.100 -> 9.0.100 swap under one
    # manifest-store layout.
    function New-DotnetSdkVersionChangeRules {
        param([string] $ManifestPath)
        @(
            @{ Match = '*shopt -s nullglob*';                Output = '0' }
            @{ Match = '*ls -1*';                            Output = $ManifestPath }
            @{ Match  = 'readlink -f /usr/local/bin/dotnet*'
               Output = '/opt/dotnet-9.0.100/dotnet' }
        )
    }
}

Describe 'Invoke-DotnetSdkVersionChangeAssertions' {

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
    }

    It 'probes the PowerShell reconciler manifest store by default' {
        $script:SshRules = New-DotnetSdkVersionChangeRules `
            -ManifestPath '/var/lib/infra-provisioner/manifests/dotnetSdk-9.0.100.json'

        { Invoke-DotnetSdkVersionChangeAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -InstallPrefix '/opt/dotnet-' `
            -PreviousResolvedVersion '8.0.100' -NewResolvedVersion '9.0.100' } |
            Should -Not -Throw

        @($script:IssuedCommands -like '*arr=( /opt/dotnet-8.0.100* )*').Count |
            Should -Be 1
        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/infra-provisioner/manifests/dotnetSdk-*.json*'
        ).Count | Should -Be 1
    }

    It 'probes the common-ansible manifest store when overridden' {
        $script:SshRules = New-DotnetSdkVersionChangeRules `
            -ManifestPath '/var/lib/common-ansible/toolchains/manifests/dotnet_sdk-9.0.100.json'

        { Invoke-DotnetSdkVersionChangeAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -InstallPrefix '/opt/dotnet-' `
            -PreviousResolvedVersion '8.0.100' -NewResolvedVersion '9.0.100' `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'dotnet_sdk-' } | Should -Not -Throw

        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/common-ansible/toolchains/manifests/dotnet_sdk-*.json*'
        ).Count | Should -Be 1
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*dotnetSdk-*').Count        | Should -Be 0
    }
}
