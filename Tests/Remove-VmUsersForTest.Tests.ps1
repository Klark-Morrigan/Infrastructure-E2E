BeforeAll {
    # Dot-source the dispatcher directly. It has no module imports of its
    # own; Pester runs in a fresh runspace per file.
    . "$PSScriptRoot\..\agent\e2e\vm-users\Remove-VmUsersForTest.ps1"

    # The dispatcher reads $script:E2ETestSecretSuffix, which production
    # sets via Initialize-E2EEnvironment.ps1 (the bootstrap that dot-sources
    # the agent's per-step scripts into one shared script scope). Unit tests
    # bypass the bootstrap, so the variable would be unset at lookup time
    # and StrictMode would turn the read into a RuntimeException. Seed it
    # here; the value is never observed (the fixture remove-users.ps1
    # scripts ignore -SecretSuffix because they have no param block).
    $script:E2ETestSecretSuffix = 'TEST'

    # Shared fixture - VmDef + Entry shapes the dispatcher only forwards.
    # Neither is touched by either flow today (both read everything from
    # the vault) but they are mandatory params so production callers
    # cannot drift away from passing them.
    $Script:VmDef = [PSCustomObject]@{
        vmName    = 'e2e-test-1'
        ipAddress = '192.168.101.10'
        username  = 'op'
        password  = 'p'
    }
    $Script:Entry = [ordered]@{ vmName = 'e2e-test-1'; users = @() }
}

Describe 'Remove-VmUsersForTest' {

    # ------------------------------------------------------------------
    Context 'UsersFlow=custom-powershell' {
    # ------------------------------------------------------------------

        BeforeEach {
            # The PowerShell remove-users script is invoked via call
            # operator against an interpolated path. We cannot Mock
            # an arbitrary external exe with Pester directly, but we
            # can shadow the script call by intercepting the path -
            # use a UsersPath that points at a real fixture script
            # the test creates, then assert its side effect.
            $Script:UsersPath = Join-Path $TestDrive 'Vm-Users'
            New-Item -Path "$Script:UsersPath\hyper-v\ubuntu" -ItemType Directory -Force | Out-Null
            # Marker file the fixture script writes - asserting its
            # presence proves the dispatcher reached the remove call.
            $Script:Marker = Join-Path $TestDrive 'remove-users-ran.txt'
        }

        It 'invokes remove-users.ps1 from UsersPath' {
            # The fixture must explicitly exit 0 so $LASTEXITCODE is set
            # for this invocation rather than carrying over a previous
            # test's value - .ps1 scripts that fall off the end leave
            # $LASTEXITCODE untouched.
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\remove-users.ps1" `
                -Value "Set-Content -Path '$Script:Marker' -Value ran; exit 0"

            Remove-VmUsersForTest `
                -UsersFlow 'custom-powershell' `
                -UsersPath $Script:UsersPath `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry

            Test-Path -LiteralPath $Script:Marker | Should -BeTrue
        }

        It 'throws with the exit code when remove-users.ps1 fails' {
            # exit inside a dot-script propagates to $LASTEXITCODE for
            # the call-operator path the dispatcher uses.
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\remove-users.ps1" `
                -Value 'exit 7'

            { Remove-VmUsersForTest `
                -UsersFlow 'custom-powershell' `
                -UsersPath $Script:UsersPath `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry
            } | Should -Throw '*exited 7*'
        }

        It 'does not invoke wsl' {
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\remove-users.ps1" `
                -Value 'exit 0'
            # Shadow wsl - if the dispatcher reaches it the test fails
            # with the marker. Function shadowing takes precedence over
            # the native exe in PowerShell's command resolution.
            function wsl { Set-Content -Path "$TestDrive\wsl-ran.txt" -Value yes }

            Remove-VmUsersForTest `
                -UsersFlow 'custom-powershell' `
                -UsersPath $Script:UsersPath `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry

            Test-Path -LiteralPath "$TestDrive\wsl-ran.txt" | Should -BeFalse
        }
    }

    # ------------------------------------------------------------------
    Context 'UsersFlow=ansible' {
    # ------------------------------------------------------------------

        BeforeEach {
            $Script:AnsiblePath = Join-Path $TestDrive 'Ansible'
            New-Item -Path $Script:AnsiblePath -ItemType Directory -Force | Out-Null
            $Script:UsersPath   = Join-Path $TestDrive 'Vm-Users'
        }

        It 'invokes wsl with the WslDistro targeting remove-users.sh from AnsiblePath' {
            $Script:Captured    = [System.Collections.Generic.List[string]]::new()
            $Script:CapturedCwd = $null
            # Function shadow for wsl. $args captures all unparsed tokens
            # so we can assert the full surface, not just presence. The
            # dispatcher anchors cwd via Push-Location instead of
            # `wsl --cd`, so we capture (Get-Location) at call time to
            # assert it equals AnsiblePath.
            function wsl {
                foreach ($a in $args) { $Script:Captured.Add([string]$a) }
                $Script:CapturedCwd  = (Get-Location).Path
                $global:LASTEXITCODE = 0
            }

            Remove-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -AnsiblePath $Script:AnsiblePath `
                -WslDistro   'Ubuntu-24.04' `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry

            # PowerShell consumes the literal '--' arg separator before
            # forwarding to a PS function shadow, so $args does not see
            # it - but production wsl.exe (a native exe) does receive
            # the '--' verbatim. Assert the surrounding tokens only.
            $joined = $Script:Captured -join ' '
            $joined | Should -Match '^-d Ubuntu-24\.04(\s+--)?\s+\./ops/remove-users\.sh$'
            $Script:CapturedCwd | Should -Be $Script:AnsiblePath
        }

        It 'throws when AnsiblePath is missing' {
            { Remove-VmUsersForTest `
                -UsersFlow 'ansible' `
                -UsersPath $Script:UsersPath `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry
            } | Should -Throw '*requires -AnsiblePath*'
        }

        It 'throws when WslDistro is missing' {
            { Remove-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -AnsiblePath $Script:AnsiblePath `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry
            } | Should -Throw '*requires -WslDistro*'
        }

        It 'throws with the exit code when remove-users.sh fails' {
            function wsl { $global:LASTEXITCODE = 9 }

            { Remove-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -AnsiblePath $Script:AnsiblePath `
                -WslDistro   'Ubuntu-24.04' `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry
            } | Should -Throw '*exited 9*'
        }

        It 'does not invoke remove-users.ps1' {
            function wsl { $global:LASTEXITCODE = 0 }
            # Drop a poisoned remove-users.ps1 - if the dispatcher reaches
            # it the test fails loudly.
            New-Item -Path "$Script:UsersPath\hyper-v\ubuntu" -ItemType Directory -Force | Out-Null
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\remove-users.ps1" `
                -Value 'throw "ansible flow must not invoke PS remove-users"'

            { Remove-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -AnsiblePath $Script:AnsiblePath `
                -WslDistro   'Ubuntu-24.04' `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry
            } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'invalid UsersFlow' {
    # ------------------------------------------------------------------

        It 'rejects unknown values at parameter binding time' {
            { Remove-VmUsersForTest `
                -UsersFlow 'legacy' `
                -UsersPath 'C:\unused' `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry
            } | Should -Throw '*ValidateSet*'
        }
    }
}
