<#
.NOTES
    Dispatcher for the remove-side of the vm-users E2E layer. Selects
    between the bespoke PowerShell flow (Infrastructure-Vm-Users) and the
    Ansible flow (Infrastructure-VM-Ansible). Mirror of
    Set-VmUsersForTest: both directions are first-class peers, both flows
    reconcile against the same VmUsersConfig vault entry.

    Feature 03 of Infrastructure-VM-Ansible introduced the symmetric
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

        # Infrastructure-Vm-Users repo root. Required for the
        # custom-powershell flow; harmless under ansible (ignored).
        [Parameter(Mandatory)]
        [string] $UsersPath,

        # Infrastructure-VM-Ansible repo root. Required when
        # UsersFlow=ansible; ignored otherwise. The dispatcher validates
        # presence at call time so a misconfigured session fails here
        # rather than at the underlying wsl invocation.
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
            # Push-Location + `wsl -d <distro> --`: same rationale as
            # Set-VmUsersForTest. `-d <distro>` pins the bash-having
            # Linux distro regardless of the workstation's WSL default
            # (Docker Desktop silently changes the default to a no-bash
            # engine distro). Push-Location anchors PowerShell's cwd
            # at the repo root so wsl inherits it as the Linux cwd,
            # bypassing the `wsl --cd` interop layer whose sparse PATH
            # cannot find bash by name.
            Push-Location $AnsiblePath
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
                Pop-Location
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Ansible remove-users.sh exited $LASTEXITCODE"
            }
        }
    }
}
