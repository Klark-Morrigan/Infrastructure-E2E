<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after the Hyper-V module has been Import-Module'd.
#>

# ---------------------------------------------------------------------------
# Resolve-RouterIpFromKvp
#   Thin wrapper around Infrastructure.HyperV's Get-VmKvpIpAddress that
#   stamps the discovered IPv4 back onto the supplied router VM def as
#   a NoteProperty named 'ipAddress'. A no-op when the def already
#   carries an ipAddress (static-mode routers, or a re-call after the
#   discovery already succeeded).
#
#   Why the test rediscovers an IP provision.ps1 already knows:
#     provision.ps1 runs as a child invocation (& "...\provision.ps1"
#     under the agent's PowerShell scope). The router VM def it mutates
#     with the discovered IP lives inside its own process / module scope -
#     the test's local $Vm1Def._RouterVm is a separate object that never
#     sees the write. Re-running KVP discovery on the test side is the
#     simplest restoration of state without introducing a side channel
#     (a sentinel file, an env var, a return value contract on
#     provision.ps1).
#
#   The polling loop, the VM-state guard, the IPv4 filter, and the
#   deadline error surface all live in the module helper - this file
#   keeps the "if absent, discover and stamp" contract specific to the
#   E2E test harness.
# ---------------------------------------------------------------------------
function Resolve-RouterIpFromKvp {
    [CmdletBinding()]
    param(
        # Router VM definition. Must carry vmName and externalSwitchName.
        # ipAddress is stamped on as a NoteProperty when not already
        # present; pinned-static routers (externalDhcp=false) skip the
        # poll entirely.
        [Parameter(Mandatory)]
        [object] $RouterVmDef,

        # Forwarded to Get-VmKvpIpAddress. The router's ext0 lease
        # typically lands within ~30 s of boot, but a slow / flaky
        # upstream LAN extends that; 5 minutes matches the
        # provisioner's own discovery budget.
        [Parameter()]
        [int] $TimeoutMinutes = 5,

        # Forwarded to Get-VmKvpIpAddress.
        [Parameter()]
        [int] $PollIntervalSeconds = 2
    )

    if ($RouterVmDef.PSObject.Properties['ipAddress'] -and $RouterVmDef.ipAddress) {
        return
    }

    Write-Host "  Resolving router upstream IP via Hyper-V KVP ..." -NoNewline

    try {
        $discoveredIp = Get-VmKvpIpAddress `
                            -VmName              $RouterVmDef.vmName `
                            -SwitchName          $RouterVmDef.externalSwitchName `
                            -TimeoutMinutes      $TimeoutMinutes `
                            -PollIntervalSeconds $PollIntervalSeconds `
                            -OnPoll              { Write-Host '.' -NoNewline }
    } catch {
        Write-Host ''
        throw
    }

    Add-Member -InputObject $RouterVmDef `
               -MemberType NoteProperty `
               -Name 'ipAddress' `
               -Value $discoveredIp `
               -Force
    Write-Host " $discoveredIp" -ForegroundColor Green
}
