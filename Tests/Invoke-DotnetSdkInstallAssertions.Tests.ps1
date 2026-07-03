BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\dotnet\Invoke-DotnetSdkInstallAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Green-path answers for every probe the install assertions make,
    # derived from one manifest-store layout. Rule order matters: the
    # non-login PATH probe contains both 'command -v dotnet' and
    # 'readlink', so the readlink rule must be evaluated first.
    function New-DotnetSdkInstallRules {
        param([string] $DotnetRoot, [string] $ManifestPath)
        @(
            @{ Match = '*readlink -f*';                Output = "$DotnetRoot/dotnet" }
            @{ Match = '*command -v dotnet*';          Output = "$DotnetRoot/dotnet" }
            @{ Match = '*DOTNET_CLI_TELEMETRY_OPTOUT*'; Output = '1' }
            @{ Match = '*DOTNET_ROOT*';                Output = $DotnetRoot }
            @{ Match = 'dotnet --version*';            Output = '8.0.100' }
            @{ Match = '*install_location*';           Output = $DotnetRoot }
            @{ Match = '*ls -1*';                      Output = $ManifestPath }
        )
    }
}

Describe 'Invoke-DotnetSdkInstallAssertions' {

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
        $script:SshRules = New-DotnetSdkInstallRules `
            -DotnetRoot   '/opt/dotnet-8.0.100' `
            -ManifestPath '/var/lib/infra-provisioner/manifests/dotnetSdk-8.0.100.json'

        { Invoke-DotnetSdkInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ResolvedVersion '8.0.100' `
            -InstallPrefix '/opt/dotnet-' } | Should -Not -Throw

        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/infra-provisioner/manifests/dotnetSdk-*.json*'
        ).Count | Should -Be 1
    }

    It 'probes the common-ansible manifest store when overridden' {
        $script:SshRules = New-DotnetSdkInstallRules `
            -DotnetRoot   '/opt/dotnet-8.0.100' `
            -ManifestPath '/var/lib/common-ansible/toolchains/manifests/dotnet_sdk-8.0.100.json'

        { Invoke-DotnetSdkInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ResolvedVersion '8.0.100' `
            -InstallPrefix      '/opt/dotnet-' `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'dotnet_sdk-' } | Should -Not -Throw

        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/common-ansible/toolchains/manifests/dotnet_sdk-*.json*'
        ).Count | Should -Be 1
        # No probe may keep pointing at the reconciler layout.
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*dotnetSdk-*').Count        | Should -Be 0
    }
}
