BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\toolchains\Invoke-DockerInstallAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Green-path answers for every probe the assertions make.
    function New-DockerInstallRules {
        param(
            [string] $DockerPath   = '/usr/bin/docker',
            [string] $ServiceState = 'active',
            [int]    $ServiceExit  = 0,
            [int]    $DockerPsExit = 0
        )
        # Every rule carries an explicit ExitStatus so the mock never has to
        # infer one from an absent key.
        @(
            @{ Match  = '*command -v docker*'
               Output = $DockerPath;   ExitStatus = 0 }
            @{ Match  = 'systemctl is-active*'
               Output = $ServiceState; ExitStatus = $ServiceExit }
            @{ Match  = 'sudo docker ps'
               Output = '';            ExitStatus = $DockerPsExit }
        )
    }
}

Describe 'Invoke-DockerInstallAssertions' {

    BeforeEach {
        # Silence the [OK] progress lines; the tests assert on the issued
        # probes and the throw/no-throw outcome, not on console output.
        Mock Write-Host {}
        $script:IssuedCommands = @()
        Mock Invoke-SshClientCommand {
            $script:IssuedCommands += $Command
            foreach ($rule in $script:SshRules) {
                if ($Command -like $rule.Match) {
                    return New-SshResult `
                        -Output $rule.Output -ExitStatus $rule.ExitStatus
                }
            }
            return New-SshResult ''
        }
    }

    It 'passes when the CLI is on PATH, the service is active, and the socket answers' {
        $script:SshRules = New-DockerInstallRules

        { Invoke-DockerInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' } | Should -Not -Throw

        # The socket probe must run as root: this flow installs the daemon but
        # deliberately grants no VM-admin group membership, so an unprivileged
        # 'docker ps' would go red for a correct implementation.
        @($script:IssuedCommands -like 'sudo docker ps').Count | Should -Be 1
    }

    It 'rejects a missing docker CLI' {
        $script:SshRules = New-DockerInstallRules -DockerPath ''

        { Invoke-DockerInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' } |
            Should -Throw '*not on the non-login PATH*'
    }

    It 'rejects an installed engine whose service never came up' {
        $script:SshRules = New-DockerInstallRules `
            -ServiceState 'failed' -ServiceExit 3

        { Invoke-DockerInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' } |
            Should -Throw "*service is not active*"
    }

    It 'rejects an active service whose daemon socket does not answer' {
        # The wedged-daemon case: 'is-active' is green but the CLI cannot
        # complete a round-trip.
        $script:SshRules = New-DockerInstallRules -DockerPsExit 1

        { Invoke-DockerInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' } |
            Should -Throw '*sudo docker ps failed*'
    }

    It 'probes the service name it was given' {
        $script:SshRules = New-DockerInstallRules

        { Invoke-DockerInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ServiceName 'docker-custom' } | Should -Not -Throw

        @($script:IssuedCommands -like 'systemctl is-active docker-custom'
        ).Count | Should -Be 1
    }
}
