<#
.NOTES
    Dispatcher for the remove-side of the vm-users E2E layer. Selects
    between the bespoke PowerShell flow and the Ansible flow. Mirror of
    Set-VmUsersForTest: both directions are first-class peers, both flows
    reconcile against the same VmUsersConfig vault entry, and both now
    resolve within Infrastructure-Vm-Users (the user domain owner) -
    custom-powershell via hyper-v/ubuntu/remove-users.ps1, ansible via
    ops/remove-users.sh consuming the Common-Ansible substrate.

    Feature 03 of Common-Ansible introduced the symmetric
    remove path (sudoers -> users -> groups, reverse of create) and the
    `ops/remove-users.sh` operator entry. Before this dispatcher landed,
    teardown stayed on `Infrastructure-Vm-Users/.../remove-users.ps1`
    regardless of which create flow ran; that PS path keeps working under
    UsersFlow=custom-powershell so the two halves remain swappable while
    operators validate the Ansible remove path in parallel.

    Do not run this file directly. Dot-source it from Invoke-VmUsersTest.
#>

# ---------------------------------------------------------------------------
# Remove-VmUsersForTest
#   Runs whichever remove-users implementation the test session selected.
#   $UsersFlow comes from the same agent CLI / Start-VmUsersTest parameter
#   chain that feeds the create-side dispatcher and propagates down through
#   $Config; this function is the symmetric switch point. $VmDef / $Entry
#   are accepted for parity with Set-VmUsersForTest's contract and any
#   future per-host invocation logic - neither flow needs them today (both
#   scripts read everything they need from the VmUsers vault entry).
# ---------------------------------------------------------------------------

function Remove-VmUsersForTest {
    [CmdletBinding()]
    param(
        # Selects the implementation. ValidateSet rejects unknown values at
        # parse time so a typo never reaches the dispatch switch.
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $UsersFlow,

        # Infrastructure-Vm-Users repo root. Required for both flows: it
        # is the remove-users.ps1 home under custom-powershell and the
        # ops/remove-users.sh home under ansible (both user
        # implementations live in their owner repo as of feature 19).
        [Parameter(Mandatory)]
        [string] $UsersPath,

        # Common-Ansible substrate root. Required when UsersFlow=ansible;
        # ignored otherwise. No longer the wrapper's cwd - the wrapper
        # lives under $UsersPath now - but it still consumes the
        # Common-Ansible roles + bridge, so this pins that substrate via
        # COMMON_ANSIBLE_ROOT. The dispatcher validates presence at call
        # time so a misconfigured session fails here, not at the wsl call.
        [string] $AnsiblePath,

        # Name of the WSL distro the Ansible bridge runs inside.
        # Required when UsersFlow=ansible; ignored otherwise. Passed to
        # `wsl -d <name> --` so the dispatcher does not depend on the
        # operator's WSL default (which Docker Desktop silently moves
        # to its no-bash 'docker-desktop' engine distro). Same trap as
        # the create-side dispatcher; same fix.
        [string] $WslDistro,

        [Parameter(Mandatory)]
        [PSCustomObject] $VmDef,

        [Parameter(Mandatory)]
        [object] $Entry
    )

    switch ($UsersFlow) {
        'custom-powershell' {
            # The invocation that lived inline in Invoke-VmUsersTeardown
            # before this step. Identical surface so the existing flow
            # remains a first-class peer of the Ansible one. -SecretSuffix
            # matches the create-side dispatcher so both directions read
            # the same E2E-scoped vault entry.
            & "$UsersPath\hyper-v\ubuntu\remove-users.ps1" -SecretSuffix $script:E2ETestSecretSuffix
            if ($LASTEXITCODE -ne 0) {
                throw "custom-powershell remove-users.ps1 exited $LASTEXITCODE"
            }
        }
        'ansible' {
            if (-not $AnsiblePath) {
                throw 'UsersFlow=ansible requires -AnsiblePath'
            }
            if (-not $WslDistro) {
                throw 'UsersFlow=ansible requires -WslDistro'
            }
            # Push-Location + `wsl -d <distro> --` + COMMON_ANSIBLE_ROOT
            # forwarding: same rationale as Set-VmUsersForTest (see that
            # file for the canonical explanation). cwd is $UsersPath - the
            # remove-users.sh wrapper's owner repo - and COMMON_ANSIBLE_ROOT
            # pins the substrate the wrapper consumes to $AnsiblePath,
            # forwarded into WSL via WSLENV's /p path-translation flag.
            # WSLENV is saved and restored in finally so the per-invocation
            # forwarding does not leak into a later flow.
            Push-Location $UsersPath
            $env:COMMON_ANSIBLE_ROOT = $AnsiblePath
            $priorWslEnv = $env:WSLENV
            if ($env:WSLENV) {
                if ($env:WSLENV -notlike '*COMMON_ANSIBLE_ROOT*') {
                    $env:WSLENV = "$env:WSLENV`:COMMON_ANSIBLE_ROOT/p"
                }
            } else {
                $env:WSLENV = 'COMMON_ANSIBLE_ROOT/p'
            }
            try {
                # `2>&1 | Out-Host`: the wsl invocation is a native
                # command, and its stdout/stderr otherwise get collected
                # into this function's pipeline output. Whoever calls
                # Remove-VmUsersForTest in a subexpression / assignment
                # context (or upstream of any cmdlet pipe) consumes that
                # pipeline and silently drops ansible-playbook's output,
                # leaving the operator to debug an exit code with no
                # error text. Merge stderr first (2>&1), then write
                # straight to the host display via Out-Host, bypassing
                # the function pipeline entirely. Same gotcha as the
                # create-side dispatcher.
                & wsl -d $WslDistro -- ./ops/remove-users.sh 2>&1 | Out-Host
            }
            finally {
                # Clear the substrate pin and restore WSLENV so neither
                # leaks into a later flow in the same agent process. A
                # $null prior value means WSLENV did not exist before, so
                # remove it rather than setting it to an empty string.
                Remove-Item Env:COMMON_ANSIBLE_ROOT -ErrorAction SilentlyContinue
                if ($null -eq $priorWslEnv) {
                    Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
                } else {
                    $env:WSLENV = $priorWslEnv
                }
                Pop-Location
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Ansible remove-users.sh exited $LASTEXITCODE"
            }
        }
    }
}
