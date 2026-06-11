BeforeAll {
    # Stub the agent-shared helpers Invoke-VmProvisioningTeardown
    # consults (Get-E2ESecretName, Get-Secret, Remove-Secret) before
    # dot-sourcing the file under test. Pester can then Mock them
    # per-test.
    function Get-E2ESecretName { param([string] $BaseName) "$BaseName-TEST" }
    function Get-Secret        { param($Vault, $Name, [switch] $AsPlainText, $ErrorAction) }
    function Remove-Secret     { param($Vault, $Name) }
    function Invoke-VmTeardownAssertions { param($Config) }
    # Pester's Mock needs the command to exist before mocking; stub
    # the diag helper at file scope so per-test Mocks attach to it.
    # The real Invoke-VmRuntimeDiag is dot-sourced at runtime from
    # the fake provisioner tree under TestDrive; this stub is the
    # binding target for Mock and is shadowed by the dot-sourced
    # script's same-named function.
    function Invoke-VmRuntimeDiag { param($Vm, $VmConfigPath, $Timestamp) }

    # Teardown lives under phases\; its dot-source of the diag
    # helper resolves via ..\diag\ from there.
    . "$PSScriptRoot\..\agent\e2e\vm-provisioning\phases\Invoke-VmProvisioningTeardown.ps1"

    # Helper to build a self-contained provisioner-shaped tree on
    # TestDrive whose diag scripts contain a stub Invoke-VmRuntimeDiag.
    # Lets the function-under-test dot-source the real path and pick
    # up the stub instead of the production helper (which would try to
    # open a real SSH session).
    function New-FakeProvisionerTree {
        param(
            [Parameter(Mandatory)] [string] $Root,
            [string] $DiagBody = '
function Get-VmDiagFolder { param($VmConfigPath, $VmName, $Timestamp) "stub" }
function Get-VmAdapterIPv4 { param($Adapter) @() }
function Invoke-VmRuntimeDiag {
    param($Vm, $VmConfigPath, $Timestamp)
    "diag-stub-folder/$($Vm.vmName)"
}
'
        )
        $diagRoot    = Join-Path $Root 'hyper-v\ubuntu\common\diag'
        $networkRoot = Join-Path $Root 'hyper-v\ubuntu\common\network'
        New-Item -ItemType Directory -Path $diagRoot    -Force | Out-Null
        New-Item -ItemType Directory -Path $networkRoot -Force | Out-Null
        Set-Content -Path (Join-Path $diagRoot    'Get-VmDiagFolder.ps1')      -Value $DiagBody
        Set-Content -Path (Join-Path $networkRoot 'Get-VmAdapterIPv4.ps1')     -Value ''
        Set-Content -Path (Join-Path $diagRoot    'Invoke-VmRuntimeDiag.ps1')  -Value ''
    }

    function New-FakeVmsJson {
        param([switch] $Empty)
        if ($Empty) { return '[]' }
        @'
[
  { "vmName": "router-e2e",  "kind": "router",  "vmConfigPath": "C:\\diag", "username": "r", "password": "p" },
  { "vmName": "e2e-test-1",  "kind": "workload","vmConfigPath": "C:\\diag", "username": "u", "password": "p" }
]
'@
    }
}

Describe 'Invoke-PreTeardownRuntimeDiagCapture' {

    BeforeEach {
        $script:provRoot = Join-Path 'TestDrive:\' ([Guid]::NewGuid().Guid)
        New-Item -ItemType Directory -Path $script:provRoot | Out-Null
        $script:config = [PSCustomObject]@{ ProvisionerPath = $script:provRoot }
    }

    It 'skips and warns when the diag helper scripts are missing' {
        # No fake tree created - the helper paths do not exist.
        Mock Get-Secret { New-FakeVmsJson }
        Mock Invoke-VmRuntimeDiag { 'never-called' }

        $warnings = @()
        # Re-route Write-Host into a sink so we can assert on the
        # warning text without polluting test output.
        Mock Write-Host { $warnings += $Object } -ParameterFilter { $Object -is [string] }

        { Invoke-PreTeardownRuntimeDiagCapture -Config $script:config } |
            Should -Not -Throw

        # Invoke-VmRuntimeDiag must not have been called when helpers
        # are missing.
        Should -Invoke Invoke-VmRuntimeDiag -Times 0
    }

    It 'skips and warns when the vault read fails' {
        New-FakeProvisionerTree -Root $script:provRoot
        Mock Get-Secret { throw 'vault unreachable' }
        Mock Invoke-VmRuntimeDiag { 'never-called' }

        { Invoke-PreTeardownRuntimeDiagCapture -Config $script:config } |
            Should -Not -Throw

        Should -Invoke Invoke-VmRuntimeDiag -Times 0
    }

    It 'skips and warns when VmProvisionerConfig is empty' {
        New-FakeProvisionerTree -Root $script:provRoot
        Mock Get-Secret { New-FakeVmsJson -Empty }
        Mock Invoke-VmRuntimeDiag { 'never-called' }

        { Invoke-PreTeardownRuntimeDiagCapture -Config $script:config } |
            Should -Not -Throw

        Should -Invoke Invoke-VmRuntimeDiag -Times 0
    }

    It 'snapshots every VM in the config' {
        New-FakeProvisionerTree -Root $script:provRoot
        Mock Get-Secret { New-FakeVmsJson }
        $script:_snappedVms = @()
        Mock Invoke-VmRuntimeDiag {
            param($Vm, $VmConfigPath, $Timestamp)
            $script:_snappedVms += $Vm.vmName
            "stub-folder/$($Vm.vmName)"
        }

        Invoke-PreTeardownRuntimeDiagCapture -Config $script:config

        Should -Invoke Invoke-VmRuntimeDiag -Times 2
        $script:_snappedVms | Should -Contain 'router-e2e'
        $script:_snappedVms | Should -Contain 'e2e-test-1'
    }

    It 'stamps _RouterVm on workload VMs before snapshotting' {
        # The diag helper's SSH dispatch depends on _RouterVm being
        # stamped on workloads so it knows to jump through the router.
        New-FakeProvisionerTree -Root $script:provRoot
        Mock Get-Secret { New-FakeVmsJson }
        $script:_routerStampSeen = $false
        Mock Invoke-VmRuntimeDiag {
            param($Vm, $VmConfigPath, $Timestamp)
            if ($Vm.vmName -eq 'e2e-test-1' -and
                $Vm.PSObject.Properties['_RouterVm'] -and
                $Vm._RouterVm.vmName -eq 'router-e2e') {
                $script:_routerStampSeen = $true
            }
            'stub-folder'
        }

        Invoke-PreTeardownRuntimeDiagCapture -Config $script:config

        $script:_routerStampSeen | Should -BeTrue
    }

    It 'continues snapshotting subsequent VMs after a per-VM failure' {
        New-FakeProvisionerTree -Root $script:provRoot
        Mock Get-Secret { New-FakeVmsJson }
        $script:_calls = @()
        Mock Invoke-VmRuntimeDiag {
            param($Vm, $VmConfigPath, $Timestamp)
            $script:_calls += $Vm.vmName
            if ($Vm.vmName -eq 'router-e2e') {
                throw 'simulated SSH failure'
            }
            'stub-folder'
        }

        # Function must not propagate the per-VM failure.
        { Invoke-PreTeardownRuntimeDiagCapture -Config $script:config } |
            Should -Not -Throw

        # And the workload snapshot must have been attempted despite
        # the router failure.
        $script:_calls | Should -Contain 'e2e-test-1'
    }
}
