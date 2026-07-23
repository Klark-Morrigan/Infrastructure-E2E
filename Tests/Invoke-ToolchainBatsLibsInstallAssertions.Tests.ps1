BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\toolchains\Invoke-ToolchainBatsLibsInstallAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # One declared library in the shape the phase files pass in.
    function New-TestLibrary {
        param(
            [string] $Name    = 'bats-support',
            [string] $Version = '0.3.0'
        )
        [PSCustomObject]@{ Name = $Name; Version = $Version }
    }

    # Green-path answers for every probe the assertions make. The three probe
    # families are matched on their distinguishing substring: the load.bash
    # existence test (A1), the .installed-v marker test (A2), and the bats
    # loadability run (A3).
    function New-BatsLibsInstallRules {
        param(
            [string] $LoadBashState = 'present',
            [string] $MarkerState   = 'present',
            [string] $BatsRunOutput = 'ok 1 baked bats libraries load'
        )
        @(
            @{ Match = '*load.bash*';    Output = $LoadBashState }
            @{ Match = '*.installed-v*'; Output = $MarkerState }
            @{ Match = '*bats --tap*';   Output = $BatsRunOutput }
        )
    }
}

Describe 'Invoke-ToolchainBatsLibsInstallAssertions' {

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

    It 'passes when load.bash and the version marker exist and the library loads' {
        $script:SshRules = New-BatsLibsInstallRules

        { Invoke-ToolchainBatsLibsInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Libraries @(New-TestLibrary) } | Should -Not -Throw

        # The loadability probe resolves the library through BATS_LIB_PATH set
        # to the base dir, exactly as a CI consumer would.
        @($script:IssuedCommands -like "*BATS_LIB_PATH='/usr/lib'*").Count |
            Should -Be 1
    }

    It 'rejects a library whose load.bash is missing' {
        $script:SshRules = New-BatsLibsInstallRules -LoadBashState 'absent'

        { Invoke-ToolchainBatsLibsInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Libraries @(New-TestLibrary) } |
            Should -Throw '*load.bash is missing*'
    }

    It 'rejects a missing exact-version marker rather than accepting the install' {
        # The marker name encodes the pin; its absence means the declared
        # version did not converge, so this is the batsLibs equivalent of the
        # apt pin-did-not-win check.
        $script:SshRules = New-BatsLibsInstallRules -MarkerState 'absent'

        { Invoke-ToolchainBatsLibsInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Libraries @(New-TestLibrary) } |
            Should -Throw '*exact-version pin did not win*'
    }

    It 'rejects a library that is on disk but fails to load into a bats run' {
        # A truncated extract would pass A1/A2 (load.bash and marker present)
        # yet fail to source - the loadability run is what catches it.
        $script:SshRules = New-BatsLibsInstallRules -BatsRunOutput 'not ok 1 broken'

        { Invoke-ToolchainBatsLibsInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Libraries @(New-TestLibrary) } |
            Should -Throw '*did not load into a bats run*'
    }

    It 'probes every declared library, not just the first' {
        $script:SshRules = New-BatsLibsInstallRules

        $libraries = @(
            (New-TestLibrary -Name 'bats-support' -Version '0.3.0'),
            (New-TestLibrary -Name 'bats-assert'  -Version '2.1.0')
        )
        { Invoke-ToolchainBatsLibsInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Libraries $libraries } | Should -Not -Throw

        @($script:IssuedCommands -like '*bats-support/load.bash*').Count |
            Should -Be 1
        @($script:IssuedCommands -like '*bats-assert/load.bash*').Count |
            Should -Be 1
    }
}
