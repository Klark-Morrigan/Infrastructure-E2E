BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\jdk\Invoke-JdkNoopAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # stat output for one engine layout: install dir, profile snippet,
    # manifest - the three artifacts the snapshot parses positionally by
    # path shape.
    function New-JdkStatOutput {
        param([string] $InstallDir, [string] $ManifestPath)
        @(
            "$InstallDir 1111"
            '/etc/profile.d/jdk.sh 2222'
            "$ManifestPath 3333"
        ) -join "`n"
    }
}

Describe 'Get-JdkArtifactSnapshot' {

    BeforeEach {
        Mock Write-Host {}
        $script:IssuedCommands = @()
        Mock Invoke-SshClientCommand {
            $script:IssuedCommands += $Command
            return New-SshResult $script:StatOutput
        }
    }

    It 'stats the PowerShell reconciler layout by default' {
        $script:StatOutput = New-JdkStatOutput `
            -InstallDir   '/opt/jdk-temurin-21.0.6+7' `
            -ManifestPath '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.6+7.json'

        $snapshot = Get-JdkArtifactSnapshot -SshClient ([object]::new()) -VmName 'vm1'

        # The stat command embeds the default prefix and store glob, and the
        # parse recognises the manifest line via the default store dir.
        @($script:IssuedCommands -like ('*stat -c*/opt/jdk-temurin-* ' +
            '*/var/lib/infra-provisioner/manifests/javaDevKit-*.json*')
        ).Count | Should -Be 1
        $snapshot.InstallDir   | Should -Be '/opt/jdk-temurin-21.0.6+7'
        $snapshot.ManifestPath | Should -Be `
            '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.6+7.json'
    }

    It 'stats the common-ansible layout when overridden' {
        $script:StatOutput = New-JdkStatOutput `
            -InstallDir   '/opt/jdk-21.0.6+7' `
            -ManifestPath '/var/lib/common-ansible/toolchains/manifests/jdk-21.0.6+7.json'

        $snapshot = Get-JdkArtifactSnapshot -SshClient ([object]::new()) `
            -VmName 'vm1' `
            -InstallPrefix      '/opt/jdk-' `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'jdk-'

        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*javaDevKit*').Count        | Should -Be 0
        # ManifestPath populated proves the parse honoured the override
        # store (a stale hardcoded store would leave it null and throw).
        $snapshot.InstallDir   | Should -Be '/opt/jdk-21.0.6+7'
        $snapshot.ManifestPath | Should -Be `
            '/var/lib/common-ansible/toolchains/manifests/jdk-21.0.6+7.json'
    }
}

Describe 'Invoke-JdkNoopAssertions' {

    BeforeEach {
        Mock Write-Host {}
        Mock Invoke-SshClientCommand { return New-SshResult $script:StatOutput }
    }

    It 'passes when both snapshots agree under the common-ansible layout' {
        $script:StatOutput = New-JdkStatOutput `
            -InstallDir   '/opt/jdk-21.0.6+7' `
            -ManifestPath '/var/lib/common-ansible/toolchains/manifests/jdk-21.0.6+7.json'
        $ansibleParams = @{
            SshClient          = [object]::new()
            VmName             = 'vm1'
            InstallPrefix      = '/opt/jdk-'
            ManifestStoreDir   = '/var/lib/common-ansible/toolchains/manifests'
            ManifestFilePrefix = 'jdk-'
        }
        $previous = Get-JdkArtifactSnapshot @ansibleParams

        { Invoke-JdkNoopAssertions @ansibleParams -PreviousSnapshot $previous } |
            Should -Not -Throw
    }

    It 'fails when the manifest mtime moved under the default layout' {
        $script:StatOutput = New-JdkStatOutput `
            -InstallDir   '/opt/jdk-temurin-21.0.6+7' `
            -ManifestPath '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.6+7.json'
        $previous = Get-JdkArtifactSnapshot -SshClient ([object]::new()) -VmName 'vm1'

        # Re-stat with an advanced manifest mtime - the no-op branch was
        # not taken, so the assertion must throw.
        $script:StatOutput = $script:StatOutput -replace ' 3333', ' 4444'

        { Invoke-JdkNoopAssertions -SshClient ([object]::new()) -VmName 'vm1' `
            -PreviousSnapshot $previous } | Should -Throw '*touched manifest*'
    }
}
