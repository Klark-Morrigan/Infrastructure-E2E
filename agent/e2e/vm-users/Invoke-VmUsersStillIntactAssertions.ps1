<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmUsersTest.ps1
    after PowerShell.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-VmUsersStillIntactAssertions
#   Lightweight re-verification block that confirms each declared user
#   still exists on the VM after an operation that should NOT have touched
#   user state (e.g. a re-provision run that flipped javaDevKit.uninstall).
#
#   This is intentionally narrower than the full Invoke-VmUsersTest
#   assertion block: it answers "are the users still here?" rather than
#   "were they set up correctly?". The full assertions ran once after
#   create-users.ps1; if they passed then, a later regression that
#   disturbed users surfaces here as a missing 'id' lookup.
#
#   Throws on the first failure with a message naming the VM and the
#   missing user / group. The outer try/finally in the calling test still
#   runs teardown.
# ---------------------------------------------------------------------------

function Invoke-VmUsersStillIntactAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName,

        # The VmUsersConfig entry the assertion block originally validated.
        # Same shape as Get-E2EUsersTestEntry / Get-E2ERunnerUsersEntry
        # (vmName, groups[], users[]).
        [Parameter(Mandatory)] [object] $Entry
    )

    foreach ($group in $Entry.groups) {
        $groupName = $group.groupName
        $result    = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "getent group '$groupName'"
        if ($result.ExitStatus -ne 0) {
            throw "Group '$groupName' missing on $VmName after re-provision."
        }
        Write-Host "  [OK] group '$groupName' still present." -ForegroundColor Green
    }

    foreach ($user in $Entry.users) {
        $username = $user.username
        $result   = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command   "id '$username'"
        if ($result.ExitStatus -ne 0) {
            throw "User '$username' missing on $VmName after re-provision."
        }
        Write-Host "  [OK] user '$username' still present." -ForegroundColor Green
    }
}
