<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after the Hyper-V module has been Import-Module'd.
#>

# ---------------------------------------------------------------------------
# Resolve-RouterIpFromKvp
#   Discovers the router VM's upstream NIC IPv4 address via Hyper-V's KVP
#   integration services and stamps it back onto the supplied router VM
#   definition as a NoteProperty named 'ipAddress'. A no-op when the def
#   already carries an ipAddress (static-mode routers, or a re-call after
#   the discovery already succeeded).
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
#   The lookup matches the router's *external* switch name to pick the
#   correct NIC; Hyper-V exposes both adapters (ext0 and priv0) via
#   KVP, and only the external one carries the upstream LAN IP.
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

        # How long to wait for KVP to report an IPv4. The router's
        # ext0 lease typically lands within ~30 s of boot, but a slow
        # / flaky upstream LAN extends that; 5 minutes matches the
        # provisioner's own discovery budget.
        [Parameter()]
        [int] $TimeoutMinutes = 5,

        # Polling cadence. 2 s avoids hammering Get-VMNetworkAdapter
        # while still landing within a single SSH connect's wait
        # budget once the lease arrives.
        [Parameter()]
        [int] $PollIntervalSeconds = 2
    )

    if ($RouterVmDef.PSObject.Properties['ipAddress'] -and $RouterVmDef.ipAddress) {
        return
    }

    Write-Host "  Resolving router upstream IP via Hyper-V KVP ..." -NoNewline

    $deadline     = (Get-Date).AddMinutes($TimeoutMinutes)
    $discoveredIp = $null

    while ((Get-Date) -lt $deadline -and -not $discoveredIp) {
        # KVP only reports on a Running VM, so guard up front - a
        # stopped VM would loop silently until the deadline.
        $vmState = (Get-VM -Name $RouterVmDef.vmName).State
        if ($vmState -ne 'Running') {
            Write-Host ''
            throw (
                "Router VM '$($RouterVmDef.vmName)' is not Running " +
                "(state: $vmState). Cannot discover its upstream IP via KVP."
            )
        }

        $extAdapter = @(Get-VMNetworkAdapter -VMName $RouterVmDef.vmName |
            Where-Object { $_.SwitchName -eq $RouterVmDef.externalSwitchName })
        if ($extAdapter.Count -gt 0) {
            $discoveredIp = @($extAdapter[0].IPAddresses) |
                Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
                Select-Object -First 1
        }
        if (-not $discoveredIp) {
            Write-Host '.' -NoNewline
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    if (-not $discoveredIp) {
        Write-Host ''
        throw (
            "Router VM '$($RouterVmDef.vmName)' did not report an ext0 " +
            "IP via Hyper-V KVP within $TimeoutMinutes minute(s). The " +
            "router itself ran post-provisioning successfully, so the " +
            "External vSwitch is fine - re-check the test harness's " +
            "Hyper-V module import."
        )
    }

    Add-Member -InputObject $RouterVmDef `
               -MemberType NoteProperty `
               -Name 'ipAddress' `
               -Value $discoveredIp `
               -Force
    Write-Host " $discoveredIp" -ForegroundColor Green
}
