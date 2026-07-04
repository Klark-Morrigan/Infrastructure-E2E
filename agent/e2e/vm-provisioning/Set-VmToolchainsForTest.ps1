<#
.NOTES
    Toolchain-flow dispatcher for the provisioning E2E layer. The
    provisioning phases install jdk / dotnet toolchains one of two ways,
    selected by $Config.ToolchainsFlow (threaded from Start-E2EAgent):

      custom-powershell (default) - the PowerShell reconciler installs the
        toolchains as a side effect of provision.ps1 reconciling the
        javaDevKit / dotnetSdk / dotnetTools blocks in VmProvisionerConfig.
        This dispatcher is then a no-op: the work already happened inside
        provision.ps1, so nothing here changes today's run.

      ansible - the phases strip those blocks from VmProvisionerConfig (so
        the reconciler skips the toolchain providers) and this dispatcher
        drives Infrastructure-Vm-Provisioner's
        hyper-v/ubuntu/Ansible/ops/provision-toolchains.sh instead. That
        wrapper stages + verifies the artifacts host-side and runs the
        Common-Ansible jdk / dotnet_sdk / dotnet_tools roles against every
        VM in the VmProvisioner inventory. The desired toolchain versions
        are read from the Toolchains vault entry this dispatcher writes.

    The two engines reconcile the same on-VM end state, which is why the
    phases reuse one set of jdk / dotnet assertions across both (engine-
    specific manifest-store paths and the JDK install prefix are passed to
    those assertions by the phase, per step 5.5-A.5).

    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Initialize-E2EEnvironment (for Get-E2ESecretName) and the secret
    cmdlets are loaded.
#>

# ---------------------------------------------------------------------------
# New-ToolchainDesiredState
#   Builds the Toolchains-vault desired-state document the Ansible flow's
#   staging step (Stage-ToolchainArtifacts) reads and resolves. The shape
#   mirrors that reader's contract exactly: jdk_versions (loose pins the
#   staging step resolves against Adoptium), dotnet_sdk_versions
#   ({channel, version} pairs), and dotnet_tools_tools ({id, version}). An
#   empty array in any slot is the "ensure none" signal - the roles'
#   set-difference removal uninstalls whatever the host currently carries,
#   the Ansible-engine equivalent of the reconciler's javaDevKit=$null / @().
#
#   @() casts keep single-element inputs as JSON arrays after ConvertTo-Json.
# ---------------------------------------------------------------------------

function New-ToolchainDesiredState {
    [CmdletBinding()]
    param(
        # Loose JDK version pins, e.g. @('21'). Empty => uninstall all JDKs.
        [Parameter()] [string[]] $JdkVersions = @(),

        # SDK entries, e.g. @([ordered]@{ channel = '8.0'; version = '8.0.100' }).
        # Empty => uninstall all SDKs.
        [Parameter()] [object[]] $DotnetSdkVersions = @(),

        # Tool entries, e.g. @([ordered]@{ id = '...'; version = '5.4.4' }).
        # Empty => uninstall all tools.
        [Parameter()] [object[]] $DotnetToolsTools = @()
    )

    return [ordered]@{
        jdk_versions        = @($JdkVersions)
        dotnet_sdk_versions = @($DotnetSdkVersions)
        dotnet_tools_tools  = @($DotnetToolsTools)
    }
}

# ---------------------------------------------------------------------------
# Set-VmToolchainsForTest
#   The single switch point the phases call to put the phase's desired
#   toolchain state on the VM(s) under whichever engine the session
#   selected. custom-powershell returns immediately (provision.ps1 already
#   did the work); ansible writes the Toolchains vault entry and runs the
#   provision-toolchains.sh driver via WSL.
#
#   Symmetric with Set-VmUsersForTest / Set-VmRunnersForTest, but note the
#   sequencing difference: those run instead of a reconciler step, whereas
#   this one runs AFTER provision.ps1 (which still owns VM / network /
#   files / envVars creation) - only the toolchain install is gated here.
# ---------------------------------------------------------------------------

function Set-VmToolchainsForTest {
    [CmdletBinding()]
    param(
        # Selects the engine. ValidateSet rejects unknown values at parse
        # time so a typo never reaches the dispatch.
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $ToolchainsFlow,

        # Infrastructure-Vm-Provisioner repo root - the provision-toolchains.sh
        # wrapper's home. Its Ansible slice self-resolves the Common-Ansible
        # substrate (roles + bridge) as a sibling checkout, so no
        # Common-Ansible path is threaded here.
        [Parameter(Mandatory)]
        [string] $ProvisionerPath,

        # Desired toolchain state for this phase, from New-ToolchainDesiredState.
        # Written to the Toolchains vault as ToolchainsConfig-<E2E suffix>,
        # the same secret the staging step resolves and stages by.
        [Parameter(Mandatory)]
        [object] $DesiredState,

        # WSL distro the Ansible bridge runs inside. Required for the ansible
        # flow; ignored by custom-powershell. Passed via `wsl -d <name>` so
        # the run does not depend on the workstation's WSL default (Docker
        # Desktop silently moves it to its no-bash 'docker-desktop' distro).
        [Parameter()]
        [string] $WslDistro
    )

    # custom-powershell: the reconciler installed the toolchains inside
    # provision.ps1 already (the phase left the javaDevKit / dotnetSdk /
    # dotnetTools blocks in VmProvisionerConfig). Nothing to drive here.
    if ($ToolchainsFlow -eq 'custom-powershell') {
        return
    }

    if (-not $WslDistro) {
        throw 'ToolchainsFlow=ansible requires -WslDistro'
    }

    # The Toolchains vault is not seeded by any setup-secrets writer (it is
    # the interim desired-state SSOT the operator populates in production;
    # step 9.1 folds it into VmProvisionerConfig). Register it on first use
    # so the Set-Secret below - and the staging step's cross-process read -
    # resolve. Register-SecretVault is non-destructive (unlike
    # Initialize-MicrosoftPowerShellSecretStoreVault, which resets the
    # store): it only adds a vault-name over the already-unlocked SecretStore
    # the agent uses for every other fixture.
    if (-not (Get-SecretVault -Name 'Toolchains' -ErrorAction SilentlyContinue)) {
        Register-SecretVault -Name 'Toolchains' `
            -ModuleName 'Microsoft.PowerShell.SecretStore'
    }

    Write-Host 'Writing test ToolchainsConfig to vault ...' -ForegroundColor Magenta
    Set-Secret `
        -Vault  Toolchains `
        -Name   (Get-E2ESecretName 'ToolchainsConfig') `
        -Secret (ConvertTo-Json $DesiredState -Depth 5 -Compress)

    # Push-Location + `wsl -d <distro> --`: cwd is $ProvisionerPath so the
    # relative wrapper path resolves as the Linux cwd, and -d targets the
    # bash-having distro regardless of the WSL default. SECRET_SUFFIX (the
    # only env the wrapper needs) is already exported and forwarded through
    # WSLENV by Initialize-E2EEnvironment, so the wsl child inherits it - the
    # same mechanism the working UsersFlow=ansible default relies on.
    #
    # `2>&1 | Out-Host`: the wsl call is a native command; without Out-Host
    # its stdout/stderr would fold into this function's pipeline and be
    # silently swallowed by any caller in an assignment / subexpression
    # context, leaving an exit code with no error text. Same gotcha as
    # Set-VmRunnersForTest / Set-VmUsersForTest; see those for the full note.
    Push-Location $ProvisionerPath
    try {
        Write-Host "Provisioning toolchains via ansible flow (WSL '$WslDistro') ..." `
            -ForegroundColor Magenta
        & wsl -d $WslDistro -- ./hyper-v/ubuntu/Ansible/ops/provision-toolchains.sh 2>&1 |
            Out-Host
    }
    finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Ansible provision-toolchains.sh exited $LASTEXITCODE"
    }
}
