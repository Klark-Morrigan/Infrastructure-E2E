<#
.NOTES
    Do not run this file directly. Dot-source it after Infrastructure.Common
    and Infrastructure.Secrets are loaded.

    TODO (step 10): implement VM user setup and assertion. Currently delegates
    entirely to Invoke-VmProvisioningTest.
#>

. "$PSScriptRoot\..\vm-provisioning\Invoke-VmProvisioningTest.ps1"

# ---------------------------------------------------------------------------
# Invoke-VmUsersTest
#   E2E test covering VM provisioning and user setup. Currently a stub -
#   step 10 replaces the body with real user setup and assertions.
# ---------------------------------------------------------------------------

function Invoke-VmUsersTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject] $Config
    )

    Invoke-VmProvisioningTest -Config $Config
}
