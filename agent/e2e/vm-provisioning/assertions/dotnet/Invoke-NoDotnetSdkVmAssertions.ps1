<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-NoDotnetSdkVmAssertions
#   Blast-radius witness for a VM that must remain .NET-SDK-free across
#   phases where another VM in the same provision run is having its
#   dotnetSdk installed, uninstalled, or replaced. A regression that
#   leaked a dotnetSdk step to the wrong VM would only fire here. Mirror
#   of Invoke-NoJdkVmAssertions:
#     D1 - No /opt/dotnet-* directory.
#     D2 - No /etc/profile.d/dotnet.sh.
#     D3 - No /usr/local/bin/dotnet symlink.
#     D4 - No dotnetSdk-*.json manifest under the reconciler store.
#
#   This function deliberately does NOT re-check hostname or cloud-init -
#   the caller pairs it with Invoke-NoJdkVmAssertions which already covers
#   those (B1 / B2). Doing them again here would just slow phase 2 / 3
#   without adding signal.
#
#   Throws on the first failure with a message naming the VM and the
#   observed value. The outer try/finally in Invoke-VmProvisioningTest still
#   runs teardown.
# ---------------------------------------------------------------------------

function Invoke-NoDotnetSdkVmAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $SshClient,

        [Parameter(Mandatory)]
        [string] $VmName
    )

    # D1) No /opt/dotnet-* directory. nullglob so the literal pattern is
    #     not emitted when the glob does not match.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'shopt -s nullglob; arr=( /opt/dotnet-* ); echo `${#arr[@]}'"
    if ($result.ExitStatus -ne 0) {
        throw "/opt/dotnet-* probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $matchCount = [int]($result.Output.Trim())
    if ($matchCount -ne 0) {
        throw "Unexpected dotnet SDK install dir(s) on $VmName " +
            "(expected 0 under /opt/dotnet-*, got $matchCount). " +
            "A dotnetSdk step leaked from another VM in the same provision run."
    }
    Write-Host '  [OK] D1: no /opt/dotnet-* directories' -ForegroundColor Green

    # D2) No /etc/profile.d/dotnet.sh.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -e /etc/profile.d/dotnet.sh && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Profile-snippet probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $state = $result.Output.Trim()
    if ($state -ne 'absent') {
        throw "Unexpected /etc/profile.d/dotnet.sh on $VmName (state '$state'). " +
            "A dotnetSdk step leaked from another VM in the same provision run."
    }
    Write-Host '  [OK] D2: no /etc/profile.d/dotnet.sh' -ForegroundColor Green

    # D3) No /usr/local/bin/dotnet symlink. test -L matches the symlink
    #     regardless of whether the target exists, so an orphan would
    #     also surface.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  "bash -c 'test -L /usr/local/bin/dotnet && echo present || echo absent'"
    if ($result.ExitStatus -ne 0) {
        throw "Symlink probe for /usr/local/bin/dotnet failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $linkState = $result.Output.Trim()
    if ($linkState -ne 'absent') {
        throw "Unexpected /usr/local/bin/dotnet symlink on $VmName (state '$linkState'). " +
            "A dotnetSdk step leaked from another VM in the same provision run."
    }
    Write-Host '  [OK] D3: no /usr/local/bin/dotnet symlink' -ForegroundColor Green

    # D4) No dotnetSdk-*.json manifest under the reconciler store. A leak
    #     here means the reconciler ran with stale state on the witness
    #     VM, which would cause unsolicited teardown attempts on its
    #     next reconciliation.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("bash -c 'ls -1 /var/lib/infra-provisioner/manifests/" +
                   "dotnetSdk-*.json 2>/dev/null || true'")
    if ($result.ExitStatus -ne 0) {
        throw "Manifest leak probe failed on $VmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $leftover = $result.Output.Trim()
    if (-not [string]::IsNullOrEmpty($leftover)) {
        throw "Unexpected dotnetSdk manifest(s) on ${VmName}: $leftover. " +
            "A dotnetSdk reconciliation step leaked from another VM in the same " +
            "provision run."
    }
    Write-Host '  [OK] D4: no dotnetSdk manifest leftover' `
        -ForegroundColor Green
}
