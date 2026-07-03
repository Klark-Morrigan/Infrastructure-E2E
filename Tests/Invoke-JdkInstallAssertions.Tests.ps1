BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\jdk\Invoke-JdkInstallAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Green-path answers for every probe the install assertions make,
    # derived from one engine layout. Rule order matters: the non-login
    # PATH probe contains both 'command -v java' and 'readlink', so the
    # readlink rule must be evaluated first.
    function New-JdkInstallRules {
        param([string] $JavaHome, [string] $ManifestPath)
        @(
            @{ Match = '*readlink -f*';     Output = "$JavaHome/bin/java" }
            @{ Match = '*command -v java*'; Output = "$JavaHome/bin/java" }
            @{ Match = '*JAVA_HOME*';       Output = $JavaHome }
            @{ Match = 'java -version*';    Output = 'openjdk version "21.0.6" 2025-01-21' }
            @{ Match = '*ls -1*';           Output = $ManifestPath }
        )
    }
}

Describe 'Invoke-JdkInstallAssertions' {

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
        $script:SshRules = New-JdkInstallRules `
            -JavaHome     '/opt/jdk-temurin-21.0.6+7' `
            -ManifestPath '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.6+7.json'

        { Invoke-JdkInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -RequestedVersion '21' } | Should -Not -Throw

        # The manifest probe must target the reconciler defaults.
        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/infra-provisioner/manifests/javaDevKit-*.json*'
        ).Count | Should -Be 1
    }

    It 'probes the common-ansible store and plain jdk prefix when overridden' {
        $script:SshRules = New-JdkInstallRules `
            -JavaHome     '/opt/jdk-21.0.6+7' `
            -ManifestPath '/var/lib/common-ansible/toolchains/manifests/jdk-21.0.6+7.json'

        { Invoke-JdkInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -RequestedVersion '21' `
            -InstallPrefix      '/opt/jdk-' `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'jdk-' } | Should -Not -Throw

        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/common-ansible/toolchains/manifests/jdk-*.json*'
        ).Count | Should -Be 1
        # No probe may keep pointing at the reconciler layout.
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*javaDevKit*').Count        | Should -Be 0
    }

    It 'rejects a JAVA_HOME outside the default jdk-temurin prefix' {
        # Ansible-layout install dir under reconciler-default expectations:
        # the default prefix must still be enforced when nothing is passed.
        $script:SshRules = New-JdkInstallRules `
            -JavaHome     '/opt/jdk-21.0.6+7' `
            -ManifestPath '/var/lib/infra-provisioner/manifests/javaDevKit-21.0.6+7.json'

        { Invoke-JdkInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -RequestedVersion '21' } |
            Should -Throw '*Unexpected JAVA_HOME*'
    }
}
