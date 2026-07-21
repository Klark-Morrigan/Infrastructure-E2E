BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\toolchains\Invoke-ToolchainAptInstallAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # One declared package in the shape the phase files pass in.
    function New-TestPackage {
        param(
            [string] $Name    = 'shellcheck',
            [string] $Version = '0.9.0-1'
        )
        [PSCustomObject]@{
            Name         = $Name
            Version      = $Version
            Command      = $Name
            SmokeCommand = "$Name --version"
            SmokePattern = 'version:\s*0\.9\.0'
        }
    }

    # Green-path answers for every probe the assertions make. Rule order
    # matters: the dpkg-query probe and the smoke probe both mention the
    # package name, so they are matched on their distinguishing verb.
    function New-AptInstallRules {
        param(
            [string] $CommandPath      = '/usr/bin/shellcheck',
            [string] $InstalledVersion = '0.9.0-1',
            [string] $SmokeOutput      = 'ShellCheck - shell script analysis tool
version: 0.9.0'
        )
        @(
            @{ Match = '*command -v*';  Output = $CommandPath }
            @{ Match = 'dpkg-query*';   Output = $InstalledVersion }
            @{ Match = '*--version*';   Output = $SmokeOutput }
        )
    }
}

Describe 'Invoke-ToolchainAptInstallAssertions' {

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

    It 'passes when the package is on PATH at its pin and smokes clean' {
        $script:SshRules = New-AptInstallRules

        { Invoke-ToolchainAptInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Packages @(New-TestPackage) } | Should -Not -Throw

        # The PATH probe must run in a NON-login shell - the shape CI steps
        # and systemd units see.
        @($script:IssuedCommands -like "bash -c 'command -v shellcheck'"
        ).Count | Should -Be 1
    }

    It 'rejects a package missing from the non-login PATH' {
        $script:SshRules = New-AptInstallRules -CommandPath ''

        { Invoke-ToolchainAptInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Packages @(New-TestPackage) } |
            Should -Throw '*not on the non-login PATH*'
    }

    It 'rejects a drifted-ahead version rather than accepting the upgrade' {
        # The apt pin must WIN on a re-provision; a newer installed build is a
        # failure, not a pass - so this is equality, not a prefix match.
        $script:SshRules = New-AptInstallRules -InstalledVersion '0.10.0-1'

        { Invoke-ToolchainAptInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Packages @(New-TestPackage) } |
            Should -Throw '*The apt pin did not win*'
    }

    It 'rejects a smoke run whose output misses the expected marker' {
        # Exit 0 with unrecognisable output is as much a regression as a
        # non-zero exit - a shim on PATH would pass the first two probes.
        $script:SshRules = New-AptInstallRules -SmokeOutput 'not a version banner'

        { Invoke-ToolchainAptInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Packages @(New-TestPackage) } |
            Should -Throw '*did not match*'
    }

    It 'probes every declared package, not just the first' {
        $script:SshRules = New-AptInstallRules

        $packages = @(
            (New-TestPackage -Name 'shellcheck'),
            (New-TestPackage -Name 'bats' -Version '0.9.0-1')
        )
        { Invoke-ToolchainAptInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -Packages $packages } | Should -Not -Throw

        @($script:IssuedCommands -like '*shellcheck*').Count | Should -Be 3
        @($script:IssuedCommands -like '*bats*').Count       | Should -Be 3
    }
}
