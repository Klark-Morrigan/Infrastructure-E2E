<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell and Infrastructure.HyperV are loaded (for
    Invoke-SshClientCommand).
#>

# ---------------------------------------------------------------------------
# Invoke-EgressAssertions
#   Proves outbound HTTPS works from a workload VM through the router's
#   NAT + dnsmasq layers to two real production endpoints:
#
#     - api.github.com       - GitHub Actions runner registration depends
#                              on this; if it's unreachable the runner-
#                              lifecycle layer will fail downstream with
#                              a much less obvious error.
#     - api.nuget.org        - NuGet host-side .nupkg prefetch and
#                              tool-install path both depend on this; a
#                              regression in TLS or DNS surfaces here
#                              against the same surface dotnetTools uses.
#
#   Each endpoint is fetched with `curl -4 -fsS --max-time 30` so a hung
#   handshake bounds quickly (curl's default is too long for a test
#   loop). -f turns 4xx/5xx into failures; both endpoints return small
#   JSON documents, so a successful exit code is sufficient evidence
#   the egress path is healthy.
#
#   -4 (force IPv4) is load-bearing, not cosmetic. The router VM is a
#   single-purpose IPv4 NAT+DNS gateway; the private switch has no IPv6
#   route at all. These CDN hosts publish AAAA records, and dnsmasq
#   intermittently hands back an AAAA-only answer - when it does, an
#   unpinned curl has only a v6 address to try, black-holes on the dead
#   route until --max-time (observed: ~11s first connect, then instant
#   0ms failures against the now-known-unreachable dest), and burns all
#   4 retries against the same trap. Every attempt resolves to the same
#   unusable family, so retries cannot absorb it. Pinning to IPv4 makes
#   the probe test the one address family this datapath actually
#   supports; an AAAA-only answer is a trap, not a real regression.
#
#   Retries: --retry 3 --retry-delay 3 --retry-all-errors. The egress
#   targets are real production CDNs (api.nuget.org sits behind Azure
#   Front Door, whose edge IPs drain and rotate); a single un-retried
#   curl turns a transient connect failure to a draining edge - or a
#   stale dnsmasq A-record pointing at one - into a red E2E. The router
#   datapath is exercised by every retry, so a genuine NAT/DNS/TLS
#   regression still fails all 4 attempts and surfaces; only same-IP
#   blips are absorbed. --retry-all-errors (not just --retry-connrefused)
#   is required because the observed failure mode is curl exit 7
#   "Couldn't connect", which plain --retry ignores.
#
#   On final failure the path is probed once more for diagnostics -
#   `getent hosts` (the IP dnsmasq actually returned, i.e. DNS-side)
#   plus a verbose curl tail (connect vs TLS, i.e. datapath-side) - and
#   the result is folded into the thrown message so the next reader can
#   tell a stale/dead destination IP from a real router regression
#   without re-deriving it by hand.
#
#   Throws on the first endpoint that stays broken, naming the VM and
#   the endpoint. The outer try/finally in the calling phase still runs
#   teardown.
# ---------------------------------------------------------------------------

function Invoke-EgressAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [string] $VmName
    )

    $endpoints = @(
        'https://api.github.com',
        'https://api.nuget.org/v3/index.json'
    )

    foreach ($endpoint in $endpoints) {
        $r = Invoke-SshClientCommand `
            -SshClient $SshClient `
            -Command  ("curl -4 -fsS --max-time 30 --retry 3 --retry-delay 3 " +
                       "--retry-all-errors '$endpoint' -o /dev/null")
        if ($r.ExitStatus -ne 0) {
            $diag = Get-EgressFailureDiagnostics -SshClient $SshClient -Endpoint $endpoint
            throw "Egress from $VmName to $endpoint failed " +
                "(exit $($r.ExitStatus)): $($r.Error). " +
                "Likely router NAT / DNS / TLS regression.`n$diag"
        }
        Write-Host "  [OK] egress to $endpoint" -ForegroundColor Green
    }
}
