<#
.NOTES
    Dispatcher for the create-side of the vm-users E2E layer. Selects
    between the bespoke PowerShell flow (Infrastructure-Vm-Users) and the
    Ansible flow (Infrastructure-VM-Ansible). Both flows reconcile the
    same on-VM state from the same VmUsersConfig vault entry; the test
    layer treats them as first-class peers.

    The teardown half stays on remove-users.ps1 for both flows for now -
    feature 03 in Infrastructure-VM-Ansible introduces the symmetric
    remove-side fork. Until then the PowerShell removal script handles
    users created by either flow (it deletes Linux accounts by name).

    Do not run this file directly. Dot-source it from Invoke-VmUsersTest.
#>

# ---------------------------------------------------------------------------
# Set-VmUsersForTest
#   Runs whichever create-users implementation the test session selected.
#   $UsersFlow comes from the agent CLI / Start-VmUsersTest parameter and
#   propagates down through $Config; this function is the single switch
#   point. $VmDef / $Entry are accepted for symmetry with the teardown
#   contract and for any future per-host invocation logic - neither flow
#   needs them today (both scripts read everything they need from the
#   VmUsers vault entry written by Invoke-VmUsersSetup).
# ---------------------------------------------------------------------------

function Set-VmUsersForTest {
    [CmdletBinding()]
    param(
        # Selects the implementation. ValidateSet rejects unknown values at
        # parse time so a typo never reaches the dispatch switch.
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $UsersFlow,

        # Infrastructure-Vm-Users repo root. Required for both flows
        # because teardown still uses remove-users.ps1 from this repo
        # regardless of which create flow ran.
        [Parameter(Mandatory)]
        [string] $UsersPath,

        # Infrastructure-VM-Ansible repo root. Required when
        # UsersFlow=ansible; ignored otherwise. The dispatcher validates
        # presence at call time so a misconfigured session fails here
        # rather than at the underlying wsl invocation.
        [string] $AnsiblePath,

        [Parameter(Mandatory)]
        [PSCustomObject] $VmDef,

        [Parameter(Mandatory)]
        [object] $Entry
    )

    switch ($UsersFlow) {
        'custom-powershell' {
            # The invocation that lived inline in Invoke-VmUsersSetup
            # before this step. Identical surface so the existing flow
            # remains a first-class peer of the Ansible one.
            & "$UsersPath\hyper-v\ubuntu\create-users.ps1"
            if ($LASTEXITCODE -ne 0) {
                throw "custom-powershell create-users.ps1 exited $LASTEXITCODE"
            }
        }
        'ansible' {
            if (-not $AnsiblePath) {
                throw 'UsersFlow=ansible requires -AnsiblePath'
            }
            # --cd because the bridge resolves .venv/bin/activate, the
            # helpers, and the playbook path relative to the repo root.
            #
            # `bash -lc` (login shell) rather than direct `./ops/...`:
            # `wsl --` execs the script via the kernel, which reads the
            # `#!/usr/bin/env bash` shebang and runs env. env then needs
            # bash on PATH - but the non-interactive wsl call inherits
            # the calling PS process's sparse PATH, with no /etc/profile
            # sourced, so /usr/bin is often absent and env fails with
            # `env: can't execute 'bash': No such file or directory`.
            # A login shell sources /etc/profile, fixing PATH for the
            # whole bridge chain in one place.
            & wsl --cd $AnsiblePath -- bash -lc './ops/create-users.sh'
            if ($LASTEXITCODE -ne 0) {
                throw "Ansible create-users.sh exited $LASTEXITCODE"
            }
        }
    }
}
