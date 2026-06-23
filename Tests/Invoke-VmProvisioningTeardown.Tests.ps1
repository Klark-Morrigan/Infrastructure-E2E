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

    It 'tolerates VM defs missing the optional kind field (workload default)' {
        # The schema treats 'kind' as router-only - workload entries
        # written by Write-VmProvisionerConfig do not carry it. Under
        # Strict-Mode -Latest, a bare $vm.kind access throws
        # "property cannot be found". This test locks in the
        # PSObject.Properties guard that defaults missing values
        # to 'workload' so teardown does not fail on a normal config.
        New-FakeProvisionerTree -Root $script:provRoot
        Mock Get-Secret {
            @'
[
  { "vmName": "router-e2e", "kind": "router", "vmConfigPath": "C:\\diag" },
  { "vmName": "e2e-test-1",                   "vmConfigPath": "C:\\diag" }
]
'@
        }
        Mock Invoke-VmRuntimeDiag { 'stub-folder' }

        Set-StrictMode -Version Latest
        try {
            { Invoke-PreTeardownRuntimeDiagCapture -Config $script:config } |
                Should -Not -Throw
        } finally {
            Set-StrictMode -Off
        }

        Should -Invoke Invoke-VmRuntimeDiag -Times 2
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

Describe 'Invoke-VmProvisioningTeardown - diag failure does not cancel deprovision' {
    # The 2026-06 regression: pre-teardown diag threw on a missing
    # 'kind' field, the throw propagated past the diag function's
    # internal try/catch blocks, and the teardown function aborted
    # before Invoke deprovision.ps1, leaving VHDX files wedged for
    # the next run. The site-level try/catch in
    # Invoke-VmProvisioningTeardown is the belt to the diag function's
    # suspenders - even a brand-new bug in the diag helper must not
    # cancel destruction.

    BeforeEach {
        $script:provRoot = Join-Path 'TestDrive:\' ([Guid]::NewGuid().Guid)
        New-Item -ItemType Directory -Path $script:provRoot | Out-Null
        # Minimal deprovision.ps1 stub at the path the teardown
        # function invokes via & "$ProvisionerPath\hyper-v\ubuntu\
        # deprovision.ps1". The body records the call by dropping a
        # marker file beside itself ($PSScriptRoot resolves to the
        # stub's own dir at invocation), letting the test assert
        # "deprovision ran" via Test-Path. The stub runs in its own
        # script scope, so a marker file - not a cross-script global -
        # is the signal channel back to the test.
        $deprovDir = Join-Path $script:provRoot 'hyper-v\ubuntu'
        New-Item -ItemType Directory -Path $deprovDir -Force | Out-Null
        $deprovScript = Join-Path $deprovDir 'deprovision.ps1'
        Set-Content -Path $deprovScript -Value @'
param([string] $SecretSuffix)
Set-Content -Path (Join-Path $PSScriptRoot 'deprovision-invoked.marker') -Value 'invoked'
'@
        $script:deprovMarker = Join-Path $deprovDir 'deprovision-invoked.marker'

        $script:config = [PSCustomObject]@{ ProvisionerPath = $script:provRoot }
        $script:E2ETestSecretSuffix = 'TEST'
    }

    It 'still runs deprovision when the diag function throws an unexpected error' {
        # Replace the diag function with one that throws OUTSIDE its
        # own try/catch blocks (the bug shape from 2026-06).
        function global:Invoke-PreTeardownRuntimeDiagCapture {
            throw 'simulated unexpected diag failure'
        }

        Mock Remove-Secret { }

        { Invoke-VmProvisioningTeardown -Config $script:config } |
            Should -Not -Throw

        Test-Path -LiteralPath $script:deprovMarker | Should -BeTrue
    }

    It 'still removes the VmProvisionerConfig secret after a diag throw' {
        function global:Invoke-PreTeardownRuntimeDiagCapture {
            throw 'simulated unexpected diag failure'
        }

        $script:_secretRemoved = $false
        Mock Remove-Secret { $script:_secretRemoved = $true }

        Invoke-VmProvisioningTeardown -Config $script:config

        $script:_secretRemoved | Should -BeTrue
    }

    It 'still runs the post-teardown assertions after a diag throw' {
        function global:Invoke-PreTeardownRuntimeDiagCapture {
            throw 'simulated unexpected diag failure'
        }

        $script:_assertionsRan = $false
        Mock Remove-Secret { }
        Mock Invoke-VmTeardownAssertions { $script:_assertionsRan = $true }

        Invoke-VmProvisioningTeardown -Config $script:config

        $script:_assertionsRan | Should -BeTrue
    }
}
