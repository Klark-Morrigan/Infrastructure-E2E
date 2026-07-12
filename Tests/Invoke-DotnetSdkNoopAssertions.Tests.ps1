BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\dotnet\Invoke-DotnetSdkNoopAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # stat output for one manifest-store layout: install dir, profile
    # snippet, manifest - the three artifacts the snapshot parses by
    # path shape.
    function New-DotnetStatOutput {
        param([string] $ManifestPath)
        @(
            '/opt/dotnet-8.0.100 1111'
            '/etc/profile.d/dotnet.sh 2222'
            "$ManifestPath 3333"
        ) -join "`n"
    }
}

Describe 'Get-DotnetSdkArtifactSnapshot' {

    BeforeEach {
        Mock Write-Host {}
        $script:IssuedCommands = @()
        Mock Invoke-SshClientCommand {
            $script:IssuedCommands += $Command
            return New-SshResult $script:StatOutput
        }
    }

    It 'stats the PowerShell reconciler manifest store by default' {
        $script:StatOutput = New-DotnetStatOutput `
            -ManifestPath '/var/lib/infra-provisioner/manifests/dotnetSdk-8.0.100.json'

        $snapshot = Get-DotnetSdkArtifactSnapshot -SshClient ([object]::new()) `
            -VmName 'vm1' -InstallPrefix '/opt/dotnet-'

        @($script:IssuedCommands -like ('*stat -c*/opt/dotnet-* ' +
            '*/var/lib/infra-provisioner/manifests/dotnetSdk-*.json*')
        ).Count | Should -Be 1
        $snapshot.ManifestPath | Should -Be `
            '/var/lib/infra-provisioner/manifests/dotnetSdk-8.0.100.json'
    }

    It 'stats the common-ansible manifest store when overridden' {
        $script:StatOutput = New-DotnetStatOutput `
            -ManifestPath '/var/lib/common-ansible/toolchains/manifests/dotnet_sdk-8.0.100.json'

        $snapshot = Get-DotnetSdkArtifactSnapshot -SshClient ([object]::new()) `
            -VmName 'vm1' -InstallPrefix '/opt/dotnet-' `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'dotnet_sdk-'

        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*dotnetSdk-*').Count        | Should -Be 0
        # ManifestPath populated proves the parse honoured the override
        # store (a stale hardcoded store would leave it null and throw).
        $snapshot.ManifestPath | Should -Be `
            '/var/lib/common-ansible/toolchains/manifests/dotnet_sdk-8.0.100.json'
    }
}

Describe 'Invoke-DotnetSdkNoopAssertions' {

    BeforeEach {
        Mock Write-Host {}
        Mock Invoke-SshClientCommand { return New-SshResult $script:StatOutput }
    }

    It 'passes when both snapshots agree under the common-ansible layout' {
        $script:StatOutput = New-DotnetStatOutput `
            -ManifestPath '/var/lib/common-ansible/toolchains/manifests/dotnet_sdk-8.0.100.json'
        $ansibleParams = @{
            SshClient          = [object]::new()
            VmName             = 'vm1'
            InstallPrefix      = '/opt/dotnet-'
            ManifestStoreDir   = '/var/lib/common-ansible/toolchains/manifests'
            ManifestFilePrefix = 'dotnet_sdk-'
        }
        $previous = Get-DotnetSdkArtifactSnapshot @ansibleParams

        { Invoke-DotnetSdkNoopAssertions @ansibleParams -PreviousSnapshot $previous } |
            Should -Not -Throw
    }

    It 'fails when the manifest mtime moved under the default layout' {
        $script:StatOutput = New-DotnetStatOutput `
            -ManifestPath '/var/lib/infra-provisioner/manifests/dotnetSdk-8.0.100.json'
        $previous = Get-DotnetSdkArtifactSnapshot -SshClient ([object]::new()) `
            -VmName 'vm1' -InstallPrefix '/opt/dotnet-'

        # Re-stat with an advanced manifest mtime - the no-op branch was
        # not taken, so the assertion must throw.
        $script:StatOutput = $script:StatOutput -replace ' 3333', ' 4444'

        { Invoke-DotnetSdkNoopAssertions -SshClient ([object]::new()) -VmName 'vm1' `
            -InstallPrefix '/opt/dotnet-' -PreviousSnapshot $previous } |
            Should -Throw '*touched manifest*'
    }
}
