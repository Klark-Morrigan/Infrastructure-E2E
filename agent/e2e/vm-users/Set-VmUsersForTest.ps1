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

        # Name of the WSL distro the Ansible bridge runs inside.
        # Required when UsersFlow=ansible; ignored otherwise. Passed to
        # `wsl -d <name> --` so the dispatcher does not depend on the
        # operator's WSL default (which Docker Desktop silently moves
        # to its no-bash 'docker-desktop' engine distro).
        [string] $WslDistro,

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
            & "$UsersPath\hyper-v\ubuntu\create-users.ps1" -SecretSuffix $script:E2ETestSecretSuffix
            if ($LASTEXITCODE -ne 0) {
                throw "custom-powershell create-users.ps1 exited $LASTEXITCODE"
            }
        }
        'ansible' {
            if (-not $AnsiblePath) {
                throw 'UsersFlow=ansible requires -AnsiblePath'
            }
            if (-not $WslDistro) {
                throw 'UsersFlow=ansible requires -WslDistro'
            }
            # Push-Location + `wsl -d <distro> --`:
            #
            # `-d <distro>` targets the bash-having Linux distro the
            # operator bootstrapped against, regardless of what the
            # workstation's WSL default happens to be. Docker Desktop's
            # installer silently changes the default to its minimal
            # `docker-desktop` engine distro (busybox + no bash), so a
            # bare `wsl --` here would otherwise fail with
            # `env: can't execute 'bash': No such file or directory`
            # the next time Docker Desktop is installed or upgraded.
            #
            # Push-Location anchors PowerShell's cwd at the repo root
            # so wsl inherits it as the Linux cwd. `wsl --cd <path>`
            # would do the same, but it routes the command through a
            # /bin/sh -c "cd <path>; <cmd>" interop layer with a sparse
            # PATH inherited from the calling PS process - and that sh
            # layer cannot find `bash` by name. Push-Location avoids
            # that wrapper entirely; wsl execs the script directly with
            # its normal startup PATH.
            Push-Location $AnsiblePath
            try {
                # `2>&1 | Out-Host`: the wsl invocation is a native
                # command, and its stdout/stderr otherwise get collected
                # into this function's pipeline output. Whoever calls
                # Set-VmUsersForTest in a subexpression / assignment
                # context (or upstream of any cmdlet pipe) consumes that
                # pipeline and silently drops ansible-playbook's output,
                # leaving the operator to debug an exit code with no
                # error text. Merge stderr first (2>&1), then write
                # straight to the host display via Out-Host, bypassing
                # the function pipeline entirely. `$LASTEXITCODE` is set
                # by the native command and unaffected by the downstream
                # cmdlet. Same gotcha as bootstrap-controller.ps1's
                # wsl-invocation fix; see that file for the canonical
                # explanation.
                & wsl -d $WslDistro -- ./ops/create-users.sh 2>&1 | Out-Host
            }
            finally {
                Pop-Location
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Ansible create-users.sh exited $LASTEXITCODE"
            }
        }
    }
}
