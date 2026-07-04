BeforeAll {
    # Stub the secret cmdlets + the Get-E2ESecretName sugar (normally from
    # Initialize-E2EEnvironment) before dot-sourcing, so Pester can Mock them
    # without the real SecretManagement module / vault. Pester runs each file
    # in a fresh runspace.
    function Get-SecretVault { param($Name, $ErrorAction) }
    function Register-SecretVault { param($Name, $ModuleName) }
    function Set-Secret { param($Vault, $Name, $Secret) }
    function Get-E2ESecretName { param($DefaultName) "$DefaultName-TEST" }

    . "$PSScriptRoot\..\agent\e2e\vm-provisioning\Set-VmToolchainsForTest.ps1"

    $Script:Desired = New-ToolchainDesiredState -JdkVersions @('21')
}

Describe 'New-ToolchainDesiredState' {

    It 'defaults every slot to an empty array (the ensure-none signal)' {
        $d = New-ToolchainDesiredState
        # ConvertTo-Json round-trip keeps single-element and empty arrays as
        # arrays - the shape the staging step reads.
        $d.jdk_versions        | Should -HaveCount 0
        $d.dotnet_sdk_versions | Should -HaveCount 0
        $d.dotnet_tools_tools  | Should -HaveCount 0
    }

    It 'projects the loose pins into the staging-step field names' {
        $d = New-ToolchainDesiredState `
            -JdkVersions       @('21') `
            -DotnetSdkVersions @([ordered]@{ channel = '8.0'; version = '8.0.100' }) `
            -DotnetToolsTools  @([ordered]@{ id = 'some.tool'; version = '5.4.4' })

        $d.jdk_versions              | Should -Be @('21')
        $d.dotnet_sdk_versions[0].channel | Should -Be '8.0'
        $d.dotnet_sdk_versions[0].version | Should -Be '8.0.100'
        $d.dotnet_tools_tools[0].id       | Should -Be 'some.tool'
        $d.dotnet_tools_tools[0].version  | Should -Be '5.4.4'
    }
}

Describe 'Set-VmToolchainsForTest' {

    BeforeEach {
        Mock Write-Host {}
        Mock Set-Secret {}
        Mock Register-SecretVault {}
        # Default: the vault already exists, so no registration happens
        # unless a test overrides this to return $null.
        Mock Get-SecretVault { [PSCustomObject]@{ Name = 'Toolchains' } }
        $Script:ProvisionerPath = Join-Path $TestDrive 'Vm-Provisioner'
        New-Item -Path $Script:ProvisionerPath -ItemType Directory -Force | Out-Null
    }

    # ------------------------------------------------------------------
    Context 'ToolchainsFlow=custom-powershell' {
    # ------------------------------------------------------------------

        It 'returns without writing the vault or invoking wsl (reconciler already ran)' {
            $Script:wslRan = $false
            function wsl { $Script:wslRan = $true; $global:LASTEXITCODE = 0 }

            Set-VmToolchainsForTest `
                -ToolchainsFlow  'custom-powershell' `
                -ProvisionerPath $Script:ProvisionerPath `
                -DesiredState    $Script:Desired

            $Script:wslRan | Should -BeFalse
            Should -Invoke Set-Secret -Times 0
            Should -Invoke Register-SecretVault -Times 0
        }
    }

    # ------------------------------------------------------------------
    Context 'ToolchainsFlow=ansible' {
    # ------------------------------------------------------------------

        It 'writes the Toolchains vault entry and drives provision-toolchains.sh from ProvisionerPath' {
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
                -DesiredState    $Script:Desired `
                -WslDistro       'Ubuntu-24.04'

            # Vault write routes to the E2E-suffixed name in the Toolchains vault.
            Should -Invoke Set-Secret -Times 1 -ParameterFilter {
                $Vault -eq 'Toolchains' -and $Name -eq 'ToolchainsConfig-TEST'
            }
            # `--` is consumed by PowerShell before a function shadow; assert
            # the surrounding tokens, and that cwd anchored at ProvisionerPath.
            $joined = $Script:Captured -join ' '
            $joined | Should -Match '^-d Ubuntu-24\.04(\s+--)?\s+\./hyper-v/ubuntu/Ansible/ops/provision-toolchains\.sh$'
            $Script:CapturedCwd | Should -Be $Script:ProvisionerPath
        }

        It 'registers the Toolchains vault when it is not yet registered' {
            Mock Get-SecretVault { $null }
            function wsl { $global:LASTEXITCODE = 0 }

            Set-VmToolchainsForTest `
                -ToolchainsFlow  'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -DesiredState    $Script:Desired `
                -WslDistro       'Ubuntu-24.04'

            Should -Invoke Register-SecretVault -Times 1 -ParameterFilter {
                $Name -eq 'Toolchains'
            }
        }

        It 'does not re-register the Toolchains vault when it already exists' {
            function wsl { $global:LASTEXITCODE = 0 }

            Set-VmToolchainsForTest `
                -ToolchainsFlow  'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -DesiredState    $Script:Desired `
                -WslDistro       'Ubuntu-24.04'

            Should -Invoke Register-SecretVault -Times 0
        }

        It 'throws when WslDistro is missing' {
            { Set-VmToolchainsForTest `
                -ToolchainsFlow  'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -DesiredState    $Script:Desired
            } | Should -Throw '*requires -WslDistro*'
        }

        It 'throws with the exit code when the driver fails' {
            function wsl { $global:LASTEXITCODE = 5 }

            { Set-VmToolchainsForTest `
                -ToolchainsFlow  'ansible' `
                -ProvisionerPath $Script:ProvisionerPath `
                -DesiredState    $Script:Desired `
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
                -ProvisionerPath $Script:ProvisionerPath `
                -DesiredState    $Script:Desired
            } | Should -Throw '*ValidateSet*'
        }
    }
}
