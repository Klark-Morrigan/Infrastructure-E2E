<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after PowerShell.Common and Infrastructure.HyperV are loaded (for
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
#   Each endpoint is fetched with `curl -fsS --max-time 30` so a hung
#   handshake bounds quickly (curl's default is too long for a test
#   loop). -f turns 4xx/5xx into failures; both endpoints return small
#   JSON documents, so a successful exit code is sufficient evidence
#   the egress path is healthy.
#
#   Throws on the first failure with a message naming the VM and the
#   endpoint that broke. The outer try/finally in the calling phase
#   still runs teardown.
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
            -Command  "curl -fsS --max-time 30 '$endpoint' -o /dev/null"
        if ($r.ExitStatus -ne 0) {
            throw "Egress from $VmName to $endpoint failed " +
                "(exit $($r.ExitStatus)): $($r.Error). " +
                "Likely router NAT / DNS / TLS regression."
        }
        Write-Host "  [OK] egress to $endpoint" -ForegroundColor Green
    }
}
