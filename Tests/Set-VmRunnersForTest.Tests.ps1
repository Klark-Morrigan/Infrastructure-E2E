BeforeAll {
    # Dot-source the dispatcher directly. It has no module imports of its
    # own; Pester runs in a fresh runspace per file.
    . "$PSScriptRoot\..\agent\e2e\runner-lifecycle\Set-VmRunnersForTest.ps1"

    # Shared fixture - VmDef + Entry shapes the dispatcher only forwards.
    # Neither is touched by either flow today (both scripts read everything
    # from the vault) but they are mandatory params so production callers
    # cannot drift away from passing them.
    $Script:VmDef = [PSCustomObject]@{
        vmName    = 'e2e-test-1'
        ipAddress = '192.168.101.10'
        username  = 'op'
        password  = 'p'
    }
    $Script:Entry = @(
        [ordered]@{ vmName = 'e2e-test-1'; runnerName = 'e2e-runner' }
    )
    $Script:Token        = 'ghs_TESTTOKEN'
    $Script:SecretSuffix = 'TEST'
}

Describe 'Set-VmRunnersForTest' {

    # ------------------------------------------------------------------
    Context 'RunnersFlow=custom-powershell' {
    # ------------------------------------------------------------------

        BeforeEach {
            # The PowerShell register-runners script is invoked via call
            # operator against an interpolated path. We cannot Mock an
            # arbitrary external exe with Pester directly, but we can
            # shadow the script call by intercepting the path - use a
            # RunnersPath that points at a real fixture script the test
            # creates, then assert its side effect.
            $Script:RunnersPath = Join-Path $TestDrive 'GitHubRunners'
            New-Item -Path "$Script:RunnersPath\hyper-v\ubuntu" `
                     -ItemType Directory -Force | Out-Null
            # Marker file the fixture script writes - asserting its
            # presence proves the dispatcher reached the register call.
            $Script:Marker = Join-Path $TestDrive 'register-runners-ran.txt'
        }

        It 'invokes register-runners.ps1 from RunnersPath' {
            # The fixture must explicitly exit 0 so $LASTEXITCODE is set
            # for this invocation rather than carrying over a previous
            # test's value - .ps1 scripts that fall off the end leave
            # $LASTEXITCODE untouched.
            Set-Content `
                -Path  "$Script:RunnersPath\hyper-v\ubuntu\register-runners.ps1" `
                -Value @'
param($Token, $SecretSuffix)
Set-Content -Path ([Environment]::GetEnvironmentVariable('MARKER_PATH')) `
    -Value "$Token|$SecretSuffix"
exit 0
'@
            $env:MARKER_PATH = $Script:Marker
            try {
                Set-VmRunnersForTest `
                    -RunnersFlow  'custom-powershell' `
                    -RunnersPath  $Script:RunnersPath `
                    -Token        $Script:Token `
                    -SecretSuffix $Script:SecretSuffix `
                    -VmDef        $Script:VmDef `
                    -Entry        $Script:Entry
            }
            finally {
                Remove-Item Env:MARKER_PATH -ErrorAction SilentlyContinue
            }

            Test-Path -LiteralPath $Script:Marker | Should -BeTrue
            (Get-Content -LiteralPath $Script:Marker -Raw).Trim() |
                Should -Be "$Script:Token|$Script:SecretSuffix"
        }

        It 'throws with the exit code when register-runners.ps1 fails' {
            Set-Content `
                -Path  "$Script:RunnersPath\hyper-v\ubuntu\register-runners.ps1" `
                -Value 'exit 7'

            { Set-VmRunnersForTest `
                -RunnersFlow  'custom-powershell' `
                -RunnersPath  $Script:RunnersPath `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry
            } | Should -Throw '*exited 7*'
        }

        It 'does not invoke wsl' {
            Set-Content `
                -Path  "$Script:RunnersPath\hyper-v\ubuntu\register-runners.ps1" `
                -Value 'exit 0'
            # Shadow wsl - if the dispatcher reaches it the test fails
            # with the marker. Function shadowing takes precedence over
            # the native exe in PowerShell's command resolution.
            function wsl { Set-Content -Path "$TestDrive\wsl-ran.txt" -Value yes }

            Set-VmRunnersForTest `
                -RunnersFlow  'custom-powershell' `
                -RunnersPath  $Script:RunnersPath `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry

            Test-Path -LiteralPath "$TestDrive\wsl-ran.txt" | Should -BeFalse
        }
    }

    # ------------------------------------------------------------------
    Context 'RunnersFlow=ansible' {
    # ------------------------------------------------------------------

        BeforeEach {
            $Script:AnsiblePath = Join-Path $TestDrive 'Ansible'
            New-Item -Path $Script:AnsiblePath -ItemType Directory -Force | Out-Null
            $Script:RunnersPath = Join-Path $TestDrive 'GitHubRunners'
        }

        It 'invokes wsl with the WslDistro targeting register-runners.sh from AnsiblePath' {
            $Script:Captured       = [System.Collections.Generic.List[string]]::new()
            $Script:CapturedCwd    = $null
            $Script:CapturedToken  = $null
            # Function shadow for wsl. $args captures all unparsed tokens
            # so we can assert the full surface, not just presence. The
            # dispatcher anchors cwd via Push-Location, so we capture
            # (Get-Location) at call time to assert it equals
            # AnsiblePath. GH_TOKEN must be set when wsl is invoked
            # (the bridge consumes it via env).
            function wsl {
                foreach ($a in $args) { $Script:Captured.Add([string]$a) }
                $Script:CapturedCwd   = (Get-Location).Path
                $Script:CapturedToken = $env:GH_TOKEN
                $global:LASTEXITCODE = 0
            }

            Set-VmRunnersForTest `
                -RunnersFlow  'ansible' `
                -RunnersPath  $Script:RunnersPath `
                -AnsiblePath  $Script:AnsiblePath `
                -WslDistro    'Ubuntu-24.04' `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry

            # PowerShell consumes the literal '--' arg separator before
            # forwarding to a PS function shadow, so $args does not see
            # it - but production wsl.exe (a native exe) does receive
            # the '--' verbatim. Assert the surrounding tokens only.
            $joined = $Script:Captured -join ' '
            $joined | Should -Match '^-d Ubuntu-24\.04(\s+--)?\s+\./ops/register-runners\.sh$'
            $Script:CapturedCwd   | Should -Be $Script:AnsiblePath
            $Script:CapturedToken | Should -Be $Script:Token
        }

        It 'clears GH_TOKEN from the agent env after a successful run' {
            function wsl { $global:LASTEXITCODE = 0 }

            $env:GH_TOKEN = $null
            Set-VmRunnersForTest `
                -RunnersFlow  'ansible' `
                -RunnersPath  $Script:RunnersPath `
                -AnsiblePath  $Script:AnsiblePath `
                -WslDistro    'Ubuntu-24.04' `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry

            (Test-Path Env:GH_TOKEN) | Should -BeFalse
        }

        It 'clears GH_TOKEN from the agent env even when the bridge throws' {
            function wsl { $global:LASTEXITCODE = 9 }

            { Set-VmRunnersForTest `
                -RunnersFlow  'ansible' `
                -RunnersPath  $Script:RunnersPath `
                -AnsiblePath  $Script:AnsiblePath `
                -WslDistro    'Ubuntu-24.04' `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry
            } | Should -Throw '*exited 9*'

            (Test-Path Env:GH_TOKEN) | Should -BeFalse
        }

        It 'throws when AnsiblePath is missing' {
            { Set-VmRunnersForTest `
                -RunnersFlow  'ansible' `
                -RunnersPath  $Script:RunnersPath `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry
            } | Should -Throw '*requires -AnsiblePath*'
        }

        It 'throws when WslDistro is missing' {
            { Set-VmRunnersForTest `
                -RunnersFlow  'ansible' `
                -RunnersPath  $Script:RunnersPath `
                -AnsiblePath  $Script:AnsiblePath `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry
            } | Should -Throw '*requires -WslDistro*'
        }

        It 'does not invoke register-runners.ps1' {
            function wsl { $global:LASTEXITCODE = 0 }
            # Drop a poisoned register-runners.ps1 - if the dispatcher
            # reaches it the test fails loudly.
            New-Item -Path "$Script:RunnersPath\hyper-v\ubuntu" `
                     -ItemType Directory -Force | Out-Null
            Set-Content `
                -Path  "$Script:RunnersPath\hyper-v\ubuntu\register-runners.ps1" `
                -Value 'throw "ansible flow must not invoke PS register-runners"'

            { Set-VmRunnersForTest `
                -RunnersFlow  'ansible' `
                -RunnersPath  $Script:RunnersPath `
                -AnsiblePath  $Script:AnsiblePath `
                -WslDistro    'Ubuntu-24.04' `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry
            } | Should -Not -Throw
        }
    }

    # ------------------------------------------------------------------
    Context 'invalid RunnersFlow' {
    # ------------------------------------------------------------------

        It 'rejects unknown values at parameter binding time' {
            { Set-VmRunnersForTest `
                -RunnersFlow  'legacy' `
                -RunnersPath  'C:\unused' `
                -Token        $Script:Token `
                -SecretSuffix $Script:SecretSuffix `
                -VmDef        $Script:VmDef `
                -Entry        $Script:Entry
            } | Should -Throw '*ValidateSet*'
        }
    }
}
