BeforeAll {
    # Stub Limit-RetainedItem (Common.PowerShell module export). The
    # ansible flow calls it before writing each new verbose log;
    # tests cover wsl dispatch, not retention behaviour, so a no-op
    # keeps them focused. The real function has dedicated tests in
    # the Common.PowerShell repo.
    function Limit-RetainedItem {
        param($Directory, $Filter, $MaxItems, $MaxAgeDays, [switch] $FileOnly)
    }

    . "$PSScriptRoot\..\agent\e2e\vm-users\Set-VmUsersForTest.ps1"

    # The dispatcher reads $script:E2ETestSecretSuffix, which production
    # sets via Initialize-E2EEnvironment.ps1 (the bootstrap that dot-sources
    # the agent's per-step scripts into one shared script scope). Unit tests
    # bypass the bootstrap, so the variable would be unset at lookup time
    # and StrictMode would turn the read into a RuntimeException. Seed it
    # here; the value is never observed (the fixture create-users.ps1
    # scripts ignore -SecretSuffix because they have no param block).
    $script:E2ETestSecretSuffix = 'TEST'

    # Shared fixture - VmDef + Entry shapes the dispatcher only forwards.
    # Neither is touched by either flow today (both read everything from
    # the vault) but they are mandatory params so production callers
    # cannot drift away from passing them.
    $Script:VmDef = [PSCustomObject]@{
        vmName       = 'e2e-test-1'
        ipAddress    = '192.168.101.10'
        username     = 'op'
        password     = 'p'
        # Required by the ansible flow's verbose-log capture (the
        # dispatcher writes <vmConfigPath>/diagnostics/ansible/
        # <timestamp>-create-users.log so the per-VM diag root
        # picks up the transcript too). The custom-powershell flow
        # ignores it. TestDrive scopes the path to the running
        # test so the file vanishes when Pester tears down.
        vmConfigPath = 'TestDrive:\Hyper-V\Config'
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
            New-Item -Path "$Script:UsersPath\hyper-v\ubuntu\PowerShell" -ItemType Directory -Force | Out-Null
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
                -Path  "$Script:UsersPath\hyper-v\ubuntu\PowerShell\create-users.ps1" `
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
                -Path  "$Script:UsersPath\hyper-v\ubuntu\PowerShell\create-users.ps1" `
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
                -Path  "$Script:UsersPath\hyper-v\ubuntu\PowerShell\create-users.ps1" `
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
            # UsersPath is the wrapper's owner repo and the ansible flow's
            # Push-Location target, so it must exist on disk.
            $Script:UsersPath   = Join-Path $TestDrive 'Vm-Users'
            New-Item -Path $Script:UsersPath -ItemType Directory -Force | Out-Null
        }

        It 'invokes wsl with the WslDistro targeting create-users.sh from UsersPath' {
            $Script:Captured     = [System.Collections.Generic.List[string]]::new()
            $Script:CapturedCwd  = $null
            # Function shadow for wsl. $args captures all unparsed tokens
            # so we can assert the full surface, not just presence. The
            # dispatcher anchors cwd via Push-Location instead of
            # `wsl --cd`, so we capture (Get-Location) at call time and
            # assert it equals UsersPath (the wrapper's owner repo). The
            # wrapper self-resolves the Common-Ansible substrate, so no
            # COMMON_ANSIBLE_ROOT is set or forwarded here.
            function wsl {
                foreach ($a in $args) { $Script:Captured.Add([string]$a) }
                $Script:CapturedCwd    = (Get-Location).Path
                $global:LASTEXITCODE   = 0
            }

            Set-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -WslDistro   'Ubuntu-24.04' `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry

            # PowerShell consumes the literal '--' arg separator before
            # forwarding to a PS function shadow, so $args does not see
            # it - but production wsl.exe (a native exe) does receive
            # the '--' verbatim. Assert the surrounding tokens only.
            $joined = $Script:Captured -join ' '
            $joined | Should -Match '^-d Ubuntu-24\.04(\s+--)?\s+\./hyper-v/ubuntu/Ansible/ops/create-users\.sh(\s+-vvv)?$'
            $Script:CapturedCwd    | Should -Be $Script:UsersPath
        }

        It 'throws with the exit code when create-users.sh fails' {
            function wsl { $global:LASTEXITCODE = 9 }

            { Set-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
                -WslDistro   'Ubuntu-24.04' `
                -VmDef       $Script:VmDef `
                -Entry       $Script:Entry
            } | Should -Throw '*exited 9*'
        }

        It 'does not invoke create-users.ps1' {
            function wsl { $global:LASTEXITCODE = 0 }
            # Drop a poisoned create-users.ps1 - if the dispatcher reaches
            # it the test fails loudly.
            New-Item -Path "$Script:UsersPath\hyper-v\ubuntu\PowerShell" -ItemType Directory -Force | Out-Null
            Set-Content `
                -Path  "$Script:UsersPath\hyper-v\ubuntu\PowerShell\create-users.ps1" `
                -Value 'throw "ansible flow must not invoke PS create-users"'

            { Set-VmUsersForTest `
                -UsersFlow   'ansible' `
                -UsersPath   $Script:UsersPath `
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
            { Set-VmUsersForTest `
                -UsersFlow 'legacy' `
                -UsersPath 'C:\unused' `
                -VmDef     $Script:VmDef `
                -Entry     $Script:Entry
            } | Should -Throw '*ValidateSet*'
        }
    }
}
