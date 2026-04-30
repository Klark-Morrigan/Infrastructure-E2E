<#
.NOTES
    Do not run this file directly. Dot-source it after Infrastructure.Common
    and Infrastructure.Secrets are loaded (Start-E2EAgent.ps1 handles this).

    TODO (step 11): implement runner registration and assertion. Currently
    delegates entirely to Invoke-VmUsersTest.
#>

. "$PSScriptRoot\..\vm-users\Invoke-VmUsersTest.ps1"

# ---------------------------------------------------------------------------
# Invoke-RunnerLifecycleTest
#   Full E2E test entry point called by the polling agent. Currently a stub -
#   step 11 replaces the body with runner registration and assertions.
# ---------------------------------------------------------------------------

function Invoke-RunnerLifecycleTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    Invoke-VmUsersTest -Config $Config
}
