BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\toolchains\Invoke-NoToolchainsVmAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Only .Name is read by the witness; the rest of the declaration shape is
    # carried so the tests pass the same objects the phases do.
    $script:TestPackages = @(
        [PSCustomObject]@{ Name = 'shellcheck'; Version = '0.9.0-1' },
        [PSCustomObject]@{ Name = 'bats';       Version = '1.10.0-1' }
    )

    # Green-path (clean-VM) answers for every leak probe.
    function New-CleanVmRules {
        param(
            [string] $DpkgStatus  = '',
            [string] $DockerPath  = '',
            [string] $KeyringState = 'absent'
        )
        @(
            @{ Match = 'dpkg-query*';          Output = $DpkgStatus }
            @{ Match = '*command -v docker*';  Output = $DockerPath }
            @{ Match = '*docker.asc*';         Output = $KeyringState }
        )
    }
}

Describe 'Invoke-NoToolchainsVmAssertions' {

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

    It 'passes on a VM that declared no toolchains block' {
        $script:SshRules = New-CleanVmRules

        { Invoke-NoToolchainsVmAssertions -SshClient ([object]::new()) `
            -VmName 'vm2' -Packages $script:TestPackages } | Should -Not -Throw

        # Every declared package must be probed - a witness that checked only
        # the first would miss a partial leak.
        @($script:IssuedCommands -like 'dpkg-query*shellcheck*').Count |
            Should -Be 1
        @($script:IssuedCommands -like 'dpkg-query*bats*').Count | Should -Be 1
    }

    It 'tolerates dpkg-query reporting a package it has never heard of' {
        # An unknown package is the normal clean-VM answer: the probe appends
        # '|| true' so it stays green and returns empty output.
        $script:SshRules = New-CleanVmRules -DpkgStatus ''

        { Invoke-NoToolchainsVmAssertions -SshClient ([object]::new()) `
            -VmName 'vm2' -Packages $script:TestPackages } | Should -Not -Throw
    }

    It 'catches a section-2 apt package that leaked onto the witness VM' {
        $script:SshRules = New-CleanVmRules -DpkgStatus 'install ok installed'

        { Invoke-NoToolchainsVmAssertions -SshClient ([object]::new()) `
            -VmName 'vm2' -Packages $script:TestPackages } |
            Should -Throw '*leaked from another VM*'
    }

    It 'does not mistake a removed-but-known package for an install' {
        # 'deinstall ok config-files' is dpkg's leftover-config state - the
        # package is not installed, so the witness must stay green.
        $script:SshRules = New-CleanVmRules -DpkgStatus 'deinstall ok config-files'

        { Invoke-NoToolchainsVmAssertions -SshClient ([object]::new()) `
            -VmName 'vm2' -Packages $script:TestPackages } | Should -Not -Throw
    }

    It 'catches a docker CLI that leaked onto the witness VM' {
        $script:SshRules = New-CleanVmRules -DockerPath '/usr/bin/docker'

        { Invoke-NoToolchainsVmAssertions -SshClient ([object]::new()) `
            -VmName 'vm2' -Packages $script:TestPackages } |
            Should -Throw '*Unexpected docker CLI*'
    }

    It 'catches the narrower leak where only the docker apt repo was set up' {
        # The engine install never got far enough to put a CLI on PATH, so the
        # keyring probe is the only one that fires.
        $script:SshRules = New-CleanVmRules -KeyringState 'present'

        { Invoke-NoToolchainsVmAssertions -SshClient ([object]::new()) `
            -VmName 'vm2' -Packages $script:TestPackages } |
            Should -Throw "*apt repo setup leaked*"
    }
}
