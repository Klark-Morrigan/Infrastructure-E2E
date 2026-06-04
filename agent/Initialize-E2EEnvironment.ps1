<#
.NOTES
    Dot-source this file from every E2E entry-point script (Start-E2EAgent.ps1,
    Start-*Test.ps1) to ensure a consistent E2E session before any
    Infrastructure.* function is called.

    Concerns of this script: the runtime environment that wraps the modules
    (SecretStore provider registration, anything else session-wide).

    Module install / import is delegated to Install-ModuleDependencies.ps1
    so the dependency list lives in one place for this repo.
#>

. "$PSScriptRoot\Install-ModuleDependencies.ps1"

Use-MicrosoftPowerShellSecretStoreProvider

# E2E test fixtures are named `<Base>-E2E` so a test run never
# overwrites and then deletes the operator's persistent `<Base>-Production`
# data. The convention lives entirely on the test side - production
# consumer scripts (provision.ps1, create-users.ps1, etc.) take a
# mandatory `-SecretSuffix` parameter; the agent passes `E2E` for fixtures.
$script:E2ETestSecretSuffix = 'E2E'

# `SECRET_SUFFIX` is the bash bridge's contract (Infrastructure-VM-
# Ansible's _run-playbook.sh requires it set). Set here for the agent
# process so any `wsl --` child the agent spawns inherits it via
# WSLENV/u (Unix-side; the suffix is a label, not a path).
$env:SECRET_SUFFIX = $script:E2ETestSecretSuffix
if ($env:WSLENV) {
    if ($env:WSLENV -notlike '*SECRET_SUFFIX*') {
        $env:WSLENV = "$env:WSLENV`:SECRET_SUFFIX/u"
    }
} else {
    $env:WSLENV = 'SECRET_SUFFIX/u'
}

# Sugar so the agent's own Set/Get/Remove call sites do not repeat the
# suffix string. Production scripts take a -SecretSuffix parameter directly;
# this helper is only for the agent-internal cmdlet calls (Set-Secret /
# Remove-Secret / Get-SecretInfo against the test fixtures).
function Get-E2ESecretName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $DefaultName)
    "${DefaultName}-${script:E2ETestSecretSuffix}"
}
