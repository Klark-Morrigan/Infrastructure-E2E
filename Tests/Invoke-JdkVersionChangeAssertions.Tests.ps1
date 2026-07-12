BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\jdk\Invoke-JdkVersionChangeAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Green-path answers for a clean 17 -> 21 swap under one engine layout.
    function New-JdkVersionChangeRules {
        param([string] $ManifestPath, [string] $NewJavaPath)
        @(
            @{ Match = '*shopt -s nullglob*';               Output = '0' }
            @{ Match = '*ls -1*';                           Output = $ManifestPath }
            @{ Match = 'readlink -f /usr/local/bin/java*';  Output = $NewJavaPath }
        )
    }
}

Describe 'Invoke-JdkVersionChangeAssertions' {

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

    It 'probes the PowerShell reconciler store and jdk-temurin prefix by default' {
        $script:SshRules = New-JdkVersionChangeRules `
            -ManifestPath '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.6+7.json' `
            -NewJavaPath  '/opt/jdk-temurin-21.0.6+7/bin/java'

        { Invoke-JdkVersionChangeAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' `
            -PreviousRequestedVersion '17' -NewRequestedVersion '21' } |
            Should -Not -Throw

        # V1 cleanup glob carries the prefix + old version; V2/V3 the store.
        @($script:IssuedCommands -like '*arr=( /opt/jdk-temurin-17* )*').Count |
            Should -Be 1
        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/infra-provisioner/manifests/javaDevKit-*.json*'
        ).Count | Should -Be 1
    }

    It 'probes the common-ansible store and plain jdk prefix when overridden' {
        $script:SshRules = New-JdkVersionChangeRules `
            -ManifestPath '/var/lib/common-ansible/toolchains/manifests/jdk-21.0.6+7.json' `
            -NewJavaPath  '/opt/jdk-21.0.6+7/bin/java'

        { Invoke-JdkVersionChangeAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' `
            -PreviousRequestedVersion '17' -NewRequestedVersion '21' `
            -InstallPrefix      '/opt/jdk-' `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'jdk-' } | Should -Not -Throw

        @($script:IssuedCommands -like '*arr=( /opt/jdk-17* )*').Count |
            Should -Be 1
        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/common-ansible/toolchains/manifests/jdk-*.json*'
        ).Count | Should -Be 1
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*javaDevKit*').Count        | Should -Be 0
        @($script:IssuedCommands -like '*jdk-temurin*').Count       | Should -Be 0
    }
}
