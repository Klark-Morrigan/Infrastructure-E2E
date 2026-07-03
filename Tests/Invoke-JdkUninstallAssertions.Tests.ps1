BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\jdk\Invoke-JdkUninstallAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Green-path answers describing a VM with the JDK fully removed. The
    # same rules hold for both engine layouts - the probes differ only in
    # the paths they embed, which the tests assert on via IssuedCommands.
    function New-JdkUninstallRules {
        @(
            @{ Match = '*shopt -s nullglob*';   Output = '0' }
            @{ Match = '*test -e*';             Output = 'absent' }
            @{ Match = '*JAVA_HOME*';           Output = 'unset' }
            @{ Match = '*command -v java*';     Output = '' }
            @{ Match = '*find /usr/local/bin*'; Output = '' }
            @{ Match = '*ls -1*';               Output = '' }
        )
    }
}

Describe 'Invoke-JdkUninstallAssertions' {

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
        $script:SshRules = New-JdkUninstallRules
    }

    It 'probes the PowerShell reconciler store and jdk-temurin prefix by default' {
        { Invoke-JdkUninstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' } | Should -Not -Throw

        # A1 glob and A5 symlink scan carry the install prefix; A6 the store.
        @($script:IssuedCommands -like '*arr=( /opt/jdk-temurin-* )*').Count |
            Should -Be 1
        @($script:IssuedCommands -like "*-lname '/opt/jdk-temurin-*").Count |
            Should -Be 1
        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/infra-provisioner/manifests/javaDevKit-*.json*'
        ).Count | Should -Be 1
    }

    It 'probes the common-ansible store and plain jdk prefix when overridden' {
        { Invoke-JdkUninstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' `
            -InstallPrefix      '/opt/jdk-' `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'jdk-' } | Should -Not -Throw

        @($script:IssuedCommands -like '*arr=( /opt/jdk-* )*').Count |
            Should -Be 1
        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/common-ansible/toolchains/manifests/jdk-*.json*'
        ).Count | Should -Be 1
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*javaDevKit*').Count        | Should -Be 0
        @($script:IssuedCommands -like '*jdk-temurin*').Count       | Should -Be 0
    }
}
