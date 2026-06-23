<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell and Infrastructure.HyperV are loaded (for
    Invoke-SshClientCommand). Called by Invoke-EgressAssertions on a failed
    endpoint.
#>

# ---------------------------------------------------------------------------
# Get-EgressFailureDiagnostics
#   Re-probes a failed endpoint from the workload VM and returns a
#   human-readable block separating the DNS answer from the connect
#   attempt. `getent hosts` shows the IP dnsmasq handed back (a dead/
#   stale address here points at the destination CDN, not the router);
#   `curl -v` (tail only - the body is discarded) shows whether the
#   socket connected and where TLS got to. timeout/--max-time keep the
#   probe from hanging a teardown.
# ---------------------------------------------------------------------------
function Get-EgressFailureDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $Endpoint
    )

    $hostName = ([uri] $Endpoint).Host

    $probe = Invoke-SshClientCommand `
        -SshClient $SshClient `
        -Command  ("echo '--- getent hosts $hostName ---'; " +
                   "getent hosts '$hostName' 2>&1 || echo '(no DNS answer)'; " +
                   "echo '--- curl -v $Endpoint ---'; " +
                   "curl -sS -v --max-time 15 '$Endpoint' -o /dev/null 2>&1 " +
                   "| tail -n 20")

    "  [diag] egress probe for ${hostName}:`n$($probe.Output)$($probe.Error)"
}
