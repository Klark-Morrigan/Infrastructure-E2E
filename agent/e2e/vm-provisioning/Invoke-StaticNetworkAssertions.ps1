<#
.NOTES
    Do not run this file directly. Dot-sourced by Invoke-VmProvisioningTest.ps1
    after PowerShell.Common (for Invoke-SshClientCommand) is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-StaticNetworkAssertions
#   Verifies the on-disk state produced by feature 40 (static network
#   config delivered via cloud-init write_files). This is the integration
#   counterpart to the unit tests under Tests/up/seed/* in the provisioner
#   repo - the unit tests prove the seed content is right, this proves
#   cloud-init parsed it, applied it, and netplan brought the interface up.
#
#   Checks (per Step 4 of docs/dev/implementation/40 - static network
#   config/plan.md in Infrastructure-Vm-Provisioner):
#     - /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg exists and
#       contains the literal 'network: {config: disabled}' that cloud-init
#       parses verbatim to suppress its network module on subsequent boots.
#     - /etc/netplan/99-static.yaml exists with mode 0600 (secrets-grade
#       perms because it is the only authoritative netplan source).
#     - The netplan YAML mentions the VM's configured IP, gateway, and DNS
#       - cheap structural check that the write_files payload was the one
#       New-StaticNetplanYaml produced for this VM, without re-importing
#       the builder cross-repo.
#     - 'ip -4 addr show' lists the configured IP on some interface -
#       proves netplan apply actually took effect, not just that the file
#       was dropped on disk. SSH reaching the VM at this IP is a weaker
#       signal because DHCP could in principle hand back the same address.
#
#   Throws on the first failure with a message naming the VM and the
#   observed value. The outer try/finally in the calling test still runs
#   teardown.
# ---------------------------------------------------------------------------

function Invoke-StaticNetworkAssertions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $SshClient,
        [Parameter(Mandatory)] [PSCustomObject] $VmDef
    )

    $vmName = $VmDef.vmName

    # 1. Disable flag file - exact-content match. cloud-init parses this
    # verbatim, so any drift (extra quotes, different spacing) silently
    # turns the network module back on.
    $disablePath = '/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
    $expectedDisable = 'network: {config: disabled}'
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command "sudo cat $disablePath"
    if ($result.ExitStatus -ne 0) {
        throw "Reading $disablePath failed on $vmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    if ($result.Output.Trim() -ne $expectedDisable) {
        throw "$disablePath on $vmName has unexpected content. " +
            "Expected '$expectedDisable', got '$($result.Output.Trim())'."
    }
    Write-Host "  [OK] $disablePath present with expected content" `
        -ForegroundColor Green

    # 2. Netplan file mode - 0600 is required. A world-readable netplan
    # leaks the gateway / DNS layout, and cloud-init also warns at boot
    # if the mode is wider than 0600.
    $netplanPath = '/etc/netplan/99-static.yaml'
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command "sudo stat -c '%a' $netplanPath"
    if ($result.ExitStatus -ne 0) {
        throw "stat on $netplanPath failed on $vmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $mode = $result.Output.Trim()
    if ($mode -ne '600') {
        throw "$netplanPath on $vmName has mode $mode (expected 600)."
    }
    Write-Host "  [OK] $netplanPath mode is 0600" -ForegroundColor Green

    # 3. Netplan YAML carries the VM's IP / gateway / DNS. Substring match
    # rather than parse-and-compare keeps this helper free of a YAML
    # dependency and free of cross-repo knowledge of New-StaticNetplanYaml's
    # exact whitespace.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command "sudo cat $netplanPath"
    if ($result.ExitStatus -ne 0) {
        throw "Reading $netplanPath failed on $vmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $yaml = $result.Output
    foreach ($needle in @($VmDef.ipAddress, $VmDef.gateway, $VmDef.dns)) {
        if ($yaml -notmatch [regex]::Escape($needle)) {
            throw "$netplanPath on $vmName does not contain '$needle'. " +
                "Content: $yaml"
        }
    }
    Write-Host "  [OK] $netplanPath references IP / gateway / DNS" `
        -ForegroundColor Green

    # 4. Kernel actually has the static IP bound. 'ip -o -4 addr show'
    # one-line-per-address output is grep-friendly; the slash-prefixed
    # match ('/' + ipAddress + '/') would be wrong because the CIDR
    # form is "<ip>/<bits>" not "/<ip>/", so we match the bare IP
    # bracketed by whitespace / slash.
    $result = Invoke-SshClientCommand `
        -SshClient $SshClient -Command 'ip -o -4 addr show'
    if ($result.ExitStatus -ne 0) {
        throw "'ip -o -4 addr show' failed on $vmName " +
            "(exit $($result.ExitStatus)): $($result.Error)"
    }
    $pattern = '(^|\s)' + [regex]::Escape($VmDef.ipAddress) + '/'
    if ($result.Output -notmatch $pattern) {
        throw "Configured IP $($VmDef.ipAddress) not bound on any " +
            "interface on $vmName. ip output: $($result.Output)"
    }
    Write-Host "  [OK] $($VmDef.ipAddress) is bound on the VM" `
        -ForegroundColor Green
}
