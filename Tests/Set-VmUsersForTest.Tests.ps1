BeforeAll {
    # Dot-source the dispatcher directly. It has no module imports of its
    # own; Pester runs in a fresh runspace per file.
    . "$PSScriptRoot\..\agent\e2e\vm-users\Set-VmUsersForTest.ps1"

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

Describe 'Set-VmUsersForTest' {

    # ------------------------------------------------------------------
    Context 'UsersFlow=custom-powershell' {
    # ------------------------------------------------------------------

        BeforeEach {
            # The PowerShell create-users script is invoked via call
            # operator against an interpolated path. We cannot Mock
            # an arbitrary external exe with Pester directly, but we
            # can shadow the script call by intercepting the path -
            # use a UsersPath that points at a real fixture script
            # the test creates, then assert its side effect.
            $Script:UsersPath = Join-Path $TestDrive 'Vm-Users'
            New-Item -Path "$Script:UsersPath\hyper-v\ubuntu" -ItemType Directory -Force | Out-Null
            # Marker file the fixture script writes - asserting its
            # presence proves the dispatcher reached the create call.
            $Script:Marker = Join-Path $TestDrive 'create-users-ran.txt'
        }

        It 'invokes create-users.ps1 from UsersPath' {
            # The fixture must explicitly exit 0 so $LASTEXITCODE is set
            # for this invocation rather than carrying over a previous
            # test's value - .ps1 scripts that fall off the end leave
            # $LASTEXITCODE untouched.
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\create-users.ps1" `
                -Value "Set-Content -Path '$Script:Marker' -Value ran; exit 0"

            Set-VmUsersForTest `
                -UsersFlow 'custom-powershell' `
                -UsersPath $Script:UsersPath `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry

            Test-Path -LiteralPath $Script:Marker | Should -BeTrue
        }

        It 'throws with the exit code when create-users.ps1 fails' {
            # exit inside a dot-script propagates to $LASTEXITCODE for
            # the call-operator path the dispatcher uses.
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\create-users.ps1" `
                -Value 'exit 7'

            { Set-VmUsersForTest `
                -UsersFlow 'custom-powershell' `
                -UsersPath $Script:UsersPath `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry
            } | Should -Throw '*exited 7*'
        }

        It 'does not invoke wsl' {
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\create-users.ps1" `
                -Value 'exit 0'
            # Shadow wsl - if the dispatcher reaches it the test fails
            # with the marker. Function shadowing takes precedence over
            # the native exe in PowerShell's command resolution.
            function wsl { Set-Content -Path "$TestDrive\wsl-ran.txt" -Value yes }

            Set-VmUsersForTest `
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

        It 'invokes wsl --cd AnsiblePath -- ./ops/create-users.sh' {
            $Script:Captured = [System.Collections.Generic.List[string]]::new()
            # Function shadow for wsl. $args captures all unparsed tokens
            # so we can assert the full surface, not just presence.
            function wsl {
                foreach ($a in $args) { $Script:Captured.Add([string]$a) }
                $global:LASTEXITCODE = 0
            }

            Set-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -AnsiblePath $Script:AnsiblePath `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry

            # PowerShell consumes the literal '--' arg separator before
            # forwarding to a PS function shadow, so $args does not see
            # it - but production wsl.exe (a native exe) does receive
            # the '--' verbatim. Assert the surrounding tokens only.
            $joined = $Script:Captured -join ' '
            $joined | Should -Match '^--cd .+Ansible(\s+--)?\s+\./ops/create-users\.sh$'
        }

        It 'throws when AnsiblePath is missing' {
            { Set-VmUsersForTest `
                -UsersFlow 'ansible' `
                -UsersPath $Script:UsersPath `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry
            } | Should -Throw '*requires -AnsiblePath*'
        }

        It 'throws with the exit code when create-users.sh fails' {
            function wsl { $global:LASTEXITCODE = 9 }

            { Set-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -AnsiblePath $Script:AnsiblePath `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry
            } | Should -Throw '*exited 9*'
        }

        It 'does not invoke create-users.ps1' {
            function wsl { $global:LASTEXITCODE = 0 }
            # Drop a poisoned create-users.ps1 - if the dispatcher reaches
            # it the test fails loudly.
            New-Item -Path "$Script:UsersPath\hyper-v\ubuntu" -ItemType Directory -Force | Out-Null
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\create-users.ps1" `
                -Value 'throw "ansible flow must not invoke PS create-users"'

            { Set-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -AnsiblePath $Script:AnsiblePath `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry
            } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'invalid UsersFlow' {
    # ------------------------------------------------------------------

        It 'rejects unknown values at parameter binding time' {
            { Set-VmUsersForTest `
                -UsersFlow 'legacy' `
                -UsersPath 'C:\unused' `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry
            } | Should -Throw '*ValidateSet*'
        }
    }
}
