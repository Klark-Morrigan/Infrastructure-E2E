<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after Common.PowerShell and Infrastructure.HyperV are loaded (for
    Invoke-SshClientCommand).
#>

# ---------------------------------------------------------------------------
# Invoke-RouterReadyAssertions
#   White-box assertions on the router VM. Pins the router's internal
#   state - sysctl forwarding, nftables / dnsmasq services, MASQUERADE
#   rule - so a regression in the router-seed payload names itself
#   here rather than masking as a confusing curl/dig failure on every
#   downstream workload.
#
#   Called once from Invoke-VmProvisioningPhase1 after the first
#   provision.ps1 returns and the router SSH session opens. Phases 2
#   and 3 don't re-run this - the router stays up across phases and
#   its config doesn't drift (the same router entry is in every phase's
#   VmProvisionerConfig, byte-identical, so the reconciler takes the
#   no-op branch).
#
#   Each assertion throws on the first failure naming the VM and the
#   observed value. The outer try/finally in the phase still runs
#   teardown.
# ---------------------------------------------------------------------------

function Invoke-RouterReadyAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]         $SshClient,
        [Parameter(Mandatory)] [PSCustomObject] $RouterVmDef
    )

    $vmName = $RouterVmDef.vmName

    # IPv4 forwarding. Loaded from /etc/sysctl.d/99-router.conf by
    # sysctl --system during cloud-init runcmd and re-applied on every
    # subsequent boot.
    $r = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'sysctl -n net.ipv4.ip_forward'
    if ($r.ExitStatus -ne 0) {
        throw "sysctl on $vmName failed (exit $($r.ExitStatus)): $($r.Error)"
    }
    if ($r.Output.Trim() -ne '1') {
        throw "net.ipv4.ip_forward on $vmName is '$($r.Output.Trim())' " +
            "(expected '1')."
    }
    Write-Host "  [OK] net.ipv4.ip_forward = 1" -ForegroundColor Green

    # nftables service. Carries the FORWARD allow-list and the NAT
    # postrouting MASQUERADE rule. systemd-enabled so it survives
    # reboot - if any rule was delivered as a one-shot runcmd this
    # would fail after the first restart.
    $r = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'systemctl is-active nftables'
    if ($r.Output.Trim() -ne 'active') {
        throw "nftables.service on $vmName is '$($r.Output.Trim())' " +
            "(expected 'active')."
    }
    Write-Host "  [OK] nftables.service is active" -ForegroundColor Green

    # dnsmasq service. Bound to the private NIC IP, forwards to the
    # router's upstream DNS. Workload VMs use this as their resolver
    # (their VmProvisionerConfig dns field points at the router's
    # private IP).
    $r = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'systemctl is-active dnsmasq'
    if ($r.Output.Trim() -ne 'active') {
        throw "dnsmasq.service on $vmName is '$($r.Output.Trim())' " +
            "(expected 'active')."
    }
    Write-Host "  [OK] dnsmasq.service is active" -ForegroundColor Green

    # MASQUERADE on the external NIC + FORWARD allow rule on the
    # private NIC. The pair is load-bearing: MASQUERADE rewrites the
    # source IP, FORWARD lets the packet leave. Either one missing
    # breaks egress for every downstream workload.
    $r = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'sudo nft list ruleset'
    if ($r.ExitStatus -ne 0) {
        throw "nft list ruleset on $vmName failed " +
            "(exit $($r.ExitStatus)): $($r.Error)"
    }
    if ($r.Output -notmatch 'oifname\s+"ext0"\s+masquerade') {
        throw "MASQUERADE on ext0 not found on $vmName."
    }
    if ($r.Output -notmatch 'iifname\s+"priv0"\s+oifname\s+"ext0"\s+accept') {
        throw "FORWARD priv0 -> ext0 accept rule not found on $vmName."
    }
    Write-Host "  [OK] MASQUERADE + FORWARD rules present" -ForegroundColor Green

    # Private NIC carries the configured gateway IP. set-name in the
    # router-seed netplan pins the device name to priv0 regardless of
    # kernel naming; the IP comes from the router entry's
    # privateIpAddress.
    $r = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'ip -4 -o addr show dev priv0'
    if ($r.ExitStatus -ne 0) {
        throw "ip addr show dev priv0 on $vmName failed " +
            "(exit $($r.ExitStatus)): $($r.Error)"
    }
    $pattern = '(^|\s)' + [regex]::Escape($RouterVmDef.privateIpAddress) + '/'
    if ($r.Output -notmatch $pattern) {
        throw "priv0 on $vmName does not carry $($RouterVmDef.privateIpAddress)."
    }
    Write-Host "  [OK] priv0 carries $($RouterVmDef.privateIpAddress)" `
        -ForegroundColor Green
}
