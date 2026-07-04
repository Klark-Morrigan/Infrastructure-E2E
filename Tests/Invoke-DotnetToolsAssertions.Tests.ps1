BeforeAll {
    # Stub the Common.PowerShell cmdlet before dot-sourcing the file under
    # test so Pester can Mock it without the real module loaded.
    function Invoke-SshClientCommand { param($SshClient, $Command) }

    $assertionsDir = "$PSScriptRoot\..\agent\e2e\vm-provisioning\assertions"
    . "$assertionsDir\dotnet\Invoke-DotnetToolsAssertions.ps1"

    # Result shape Invoke-SshClientCommand returns on the wire.
    function New-SshResult {
        param([string] $Output = '', [int] $ExitStatus = 0)
        [PSCustomObject]@{ ExitStatus = $ExitStatus; Output = $Output; Error = '' }
    }

    # Tool identity shared by every test; the engine layouts only differ
    # in the manifest store and filename prefixes.
    $script:ToolId  = 'dotnet-reportgenerator-globaltool'
    $script:ToolCmd = 'reportgenerator'

    # Green-path answers for the install assertions under one layout. The
    # tool manifest (I4) and parent SDK manifest (I5) are real JSON so the
    # walker-contract checks parse them. Rule order matters: the manifest
    # probe embeds 'sudo cat' inside a 'test -f' guard, so 'test -f' must
    # be evaluated before the bare 'sudo cat' rule for the SDK manifest.
    function New-ToolsInstallRules {
        param([string] $ToolManifestPath, [string] $SdkManifestPath)
        $toolManifest = @{
            id            = $script:ToolId
            rawVersion    = '5.4.4'
            ownedSymlinks = @(@{ path = "/usr/local/bin/$($script:ToolCmd)" })
        } | ConvertTo-Json -Depth 5
        $sdkManifest = @{ children = @($ToolManifestPath) } | ConvertTo-Json -Depth 5
        @(
            @{ Match = '*test -d*';  Output = 'present' }
            @{ Match = '*test -L*';  Output = "/usr/local/share/dotnet/tools/$($script:ToolCmd)" }
            @{ Match = '*test -f*';  Output = $toolManifest }
            @{ Match = '*ls -1*';    Output = $SdkManifestPath }
            @{ Match = 'sudo cat*';  Output = $sdkManifest }
        )
    }
}

Describe 'Invoke-DotnetToolsInstallAssertions' {

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
            # Unmatched probe = the bare tool invocation (I3); exit 0 means
            # the apphost found the runtime.
            return New-SshResult ''
        }
    }

    It 'probes the PowerShell reconciler store and manifest prefixes by default' {
        $toolManifestPath = '/var/lib/infra-provisioner/manifests/' +
            "dotnetTools-$($script:ToolId)-5.4.4.json"
        $script:SshRules = New-ToolsInstallRules `
            -ToolManifestPath $toolManifestPath `
            -SdkManifestPath  '/var/lib/infra-provisioner/manifests/dotnetSdk-8.0.100.json'

        { Invoke-DotnetToolsInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ToolId $script:ToolId -ToolVersion '5.4.4' `
            -Command $script:ToolCmd } | Should -Not -Throw

        @($script:IssuedCommands -like "*test -f*$toolManifestPath*").Count |
            Should -Be 1
        @($script:IssuedCommands -like `
            '*ls -1 /var/lib/infra-provisioner/manifests/dotnetSdk-*.json*'
        ).Count | Should -Be 1
    }

    It 'stops at manifest presence under the ansible engine (skips reconciler content + walker)' {
        $toolManifestPath = '/var/lib/common-ansible/toolchains/manifests/' +
            "dotnettool-$($script:ToolId)-5.4.4.json"
        # The real Ansible manifest schema: version / symlinks, no children
        # and no rawVersion / ownedSymlinks. Under -SkipReconcilerManifestSchema
        # it is not parsed - only its presence matters - and no parent-SDK
        # manifest probe is issued (I5 is reconciler-only).
        $ansibleManifest = @{
            schema_version = 1
            id             = $script:ToolId
            version        = '5.4.4'
            symlinks       = @(@{ path = "/usr/local/bin/$($script:ToolCmd)" })
        } | ConvertTo-Json -Depth 5
        $script:SshRules = @(
            @{ Match = '*test -d*'; Output = 'present' }
            @{ Match = '*test -L*'; Output = "/usr/local/share/dotnet/tools/$($script:ToolCmd)" }
            @{ Match = '*test -f*'; Output = $ansibleManifest }
        )

        { Invoke-DotnetToolsInstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ToolId $script:ToolId -ToolVersion '5.4.4' `
            -Command $script:ToolCmd `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'dotnettool-' `
            -SkipReconcilerManifestSchema } | Should -Not -Throw

        @($script:IssuedCommands -like "*test -f*$toolManifestPath*").Count |
            Should -Be 1
        # I5 (parent-SDK walker link) is reconciler-only: no manifest
        # listing is issued under the skip switch.
        @($script:IssuedCommands -like '*ls -1*manifests*').Count | Should -Be 0
        # No probe may keep pointing at the reconciler layout.
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*dotnetTools-*').Count      | Should -Be 0
    }
}

Describe 'Invoke-DotnetToolsVersionChangeAssertions' {

    BeforeEach {
        Mock Write-Host {}
        $script:IssuedCommands = @()
        Mock Invoke-SshClientCommand {
            $script:IssuedCommands += $Command
            foreach ($rule in $script:SshRules) {
                if ($Command -like $rule.Match) { return New-SshResult $rule.Output }
            }
            return New-SshResult ''
        }
        # Clean 5.4.3 -> 5.4.4 swap: everything versioned as old is gone,
        # everything versioned as new is present, the symlink survives.
        $script:SshRules = @(
            @{ Match = '*test -d*5.4.3*'; Output = 'absent' }
            @{ Match = '*test -d*5.4.4*'; Output = 'present' }
            @{ Match = '*test -f*5.4.3*'; Output = 'absent' }
            @{ Match = '*test -f*5.4.4*'; Output = 'present' }
            @{ Match = '*test -L*';       Output = 'present' }
        )
    }

    It 'probes the PowerShell reconciler store and manifest prefix by default' {
        { Invoke-DotnetToolsVersionChangeAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ToolId $script:ToolId `
            -PreviousVersion '5.4.3' -NewVersion '5.4.4' `
            -Command $script:ToolCmd } | Should -Not -Throw

        $oldManifest = '/var/lib/infra-provisioner/manifests/' +
            "dotnetTools-$($script:ToolId)-5.4.3.json"
        @($script:IssuedCommands -like "*test -f*$oldManifest*").Count |
            Should -Be 1
    }

    It 'probes the common-ansible store and manifest prefix when overridden' {
        { Invoke-DotnetToolsVersionChangeAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ToolId $script:ToolId `
            -PreviousVersion '5.4.3' -NewVersion '5.4.4' `
            -Command $script:ToolCmd `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'dotnettool-' } | Should -Not -Throw

        $oldManifest = '/var/lib/common-ansible/toolchains/manifests/' +
            "dotnettool-$($script:ToolId)-5.4.3.json"
        @($script:IssuedCommands -like "*test -f*$oldManifest*").Count |
            Should -Be 1
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*dotnetTools-*').Count      | Should -Be 0
    }
}

Describe 'Invoke-DotnetToolsUninstallAssertions' {

    BeforeEach {
        Mock Write-Host {}
        $script:IssuedCommands = @()
        Mock Invoke-SshClientCommand {
            $script:IssuedCommands += $Command
            foreach ($rule in $script:SshRules) {
                if ($Command -like $rule.Match) { return New-SshResult $rule.Output }
            }
            return New-SshResult ''
        }
        # Fully-removed tool: no store entry, no symlink, no manifest.
        $script:SshRules = @(
            @{ Match = '*test -e*'; Output = 'absent' }
            @{ Match = '*test -L*'; Output = 'absent' }
            @{ Match = '*ls -1*';   Output = '' }
        )
    }

    It 'probes the PowerShell reconciler store and manifest prefix by default' {
        { Invoke-DotnetToolsUninstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ToolId $script:ToolId -Command $script:ToolCmd } |
            Should -Not -Throw

        @($script:IssuedCommands -like ('*ls -1 /var/lib/infra-provisioner/manifests/' +
            "dotnetTools-$($script:ToolId)-*.json*")).Count | Should -Be 1
    }

    It 'probes the common-ansible store and manifest prefix when overridden' {
        { Invoke-DotnetToolsUninstallAssertions -SshClient ([object]::new()) `
            -VmName 'vm1' -ToolId $script:ToolId -Command $script:ToolCmd `
            -ManifestStoreDir   '/var/lib/common-ansible/toolchains/manifests' `
            -ManifestFilePrefix 'dotnettool-' } | Should -Not -Throw

        @($script:IssuedCommands -like ('*ls -1 /var/lib/common-ansible/toolchains/manifests/' +
            "dotnettool-$($script:ToolId)-*.json*")).Count | Should -Be 1
        @($script:IssuedCommands -like '*infra-provisioner*').Count | Should -Be 0
        @($script:IssuedCommands -like '*dotnetTools-*').Count      | Should -Be 0
    }
}
