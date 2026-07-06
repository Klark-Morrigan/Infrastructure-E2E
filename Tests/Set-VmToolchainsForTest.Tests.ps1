BeforeAll {
    # The dispatcher no longer touches a vault: the ansible flow reads its
    # desired state from VmProvisionerConfig (written by the phase), so a plain
    # dot-source with no secret-cmdlet stubs is enough. Pester runs each file in
    # a fresh runspace.
    . "$PSScriptRoot\..\agent\e2e\vm-provisioning\Set-VmToolchainsForTest.ps1"
}

Describe 'Set-VmToolchainsForTest' {

    BeforeEach {
        Mock Write-Host {}
        $Script:ProvisionerPath = Join-Path $TestDrive 'Vm-Provisioner'
        New-Item -Path $Script:ProvisionerPath -ItemType Directory -Force | Out-Null
    }

    # ------------------------------------------------------------------
    Context 'ToolchainsFlow=custom-powershell' {
    # ------------------------------------------------------------------

        It 'returns without invoking wsl (the reconciler already ran inside provision.ps1)' {
            $Script:wslRan = $false
            function wsl { $Script:wslRan = $true; $global:LASTEXITCODE = 0 }

            Set-VmToolchainsForTest `
                -ToolchainsFlow  'custom-powershell' `
                -ProvisionerPath $Script:ProvisionerPath

            $Script:wslRan | Should -BeFalse
        }
    }

    # ------------------------------------------------------------------
    Context 'ToolchainsFlow=ansible' {
    # ------------------------------------------------------------------

        It 'drives provision-toolchains.sh from ProvisionerPath (desired state comes from VmProvisionerConfig)' {
            $Script:Captured    = [System.Collections.Generic.List[string]]::new()
            $Script:CapturedCwd = $null
            function wsl {
                foreach ($a in $args) { $Script:Captured.Add([string]$a) }
                $Script:CapturedCwd  = (Get-Location).Path
                $global:LASTEXITCODE = 0
            }

            Set-VmToolchainsForTest `
                -ToolchainsFlow  'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -WslDistro       'Ubuntu-24.04'

            # `--` is consumed by PowerShell before a function shadow; assert
            # the surrounding tokens, and that cwd anchored at ProvisionerPath.
            $joined = $Script:Captured -join ' '
            $joined | Should -Match '^-d Ubuntu-24\.04(\s+--)?\s+\./hyper-v/ubuntu/Ansible/ops/provision-toolchains\.sh$'
            $Script:CapturedCwd | Should -Be $Script:ProvisionerPath
        }

        It 'throws when WslDistro is missing' {
            { Set-VmToolchainsForTest `
                -ToolchainsFlow  'ansible' `
                -ProvisionerPath $Script:ProvisionerPath
            } | Should -Throw '*requires -WslDistro*'
        }

        It 'throws with the exit code when the driver fails' {
            function wsl { $global:LASTEXITCODE = 5 }

            { Set-VmToolchainsForTest `
                -ToolchainsFlow  'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -WslDistro       'Ubuntu-24.04'
            } | Should -Throw '*exited 5*'
        }
    }

    # ------------------------------------------------------------------
    Context 'invalid ToolchainsFlow' {
    # ------------------------------------------------------------------

        It 'rejects unknown values at parameter binding time' {
            { Set-VmToolchainsForTest `
                -ToolchainsFlow  'legacy' `
                -ProvisionerPath $Script:ProvisionerPath
            } | Should -Throw '*ValidateSet*'
        }
    }
}
