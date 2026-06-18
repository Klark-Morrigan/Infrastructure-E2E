<#
.NOTES
    Dispatcher for the register-side of the runner-lifecycle E2E layer.
    Selects between the bespoke PowerShell flow
    (Infrastructure-GitHubRunners\hyper-v\ubuntu\register-runners.ps1) and
    the Ansible flow (Infrastructure-VM-Ansible's
    ops/register-runners.sh). Both flows reconcile the same on-VM state
    from the same GitHubRunnersConfig vault entry; the test layer treats
    them as first-class peers.

    The deregister half stays on
    Infrastructure-GitHubRunners\hyper-v\ubuntu\deregister-runners.ps1 for
    both flows until feature 09 in Infrastructure-VM-Ansible introduces
    the symmetric remove-side fork. The PowerShell removal script tears
    down runners installed by either flow (it operates on systemd units
    and GitHub registrations by name, not on flow-specific state).

    Do not run this file directly. Dot-source it from
    Invoke-RunnerLifecycleTest.
#>

# ---------------------------------------------------------------------------
# Set-VmRunnersForTest
#   Runs whichever register-runners implementation the test session
#   selected. $RunnersFlow comes from the agent CLI / Start-E2EAgent
#   parameter and propagates down through $Config; this function is the
#   single switch point. $VmDef / $Entry are accepted for symmetry with
#   Set-VmUsersForTest's contract - neither flow needs them today (both
#   scripts read everything they need from the GitHubRunnersConfig vault
#   entry written by Invoke-RunnerLifecycleSetup).
# ---------------------------------------------------------------------------

function Set-VmRunnersForTest {
    [CmdletBinding()]
    param(
        # Selects the implementation. ValidateSet rejects unknown values at
        # parse time so a typo never reaches the dispatch switch.
        [Parameter(Mandatory)]
        [ValidateSet('custom-powershell', 'ansible')]
        [string] $RunnersFlow,

        # Infrastructure-GitHubRunners repo root. Required for both flows
        # because deregister-runners.ps1 from this repo is still the
        # teardown path regardless of which create flow ran.
        [Parameter(Mandatory)]
        [string] $RunnersPath,

        # Infrastructure-VM-Ansible repo root. Required when
        # RunnersFlow=ansible; ignored otherwise. The dispatcher validates
        # presence at call time so a misconfigured session fails here
        # rather than at the underlying wsl invocation.
        [string] $AnsiblePath,

        # Name of the WSL distro the Ansible bridge runs inside.
        # Required when RunnersFlow=ansible; ignored otherwise. Passed to
        # `wsl -d <name> --` so the dispatcher does not depend on the
        # operator's WSL default (which Docker Desktop silently moves
        # to its no-bash 'docker-desktop' engine distro).
        [string] $WslDistro,

        # Short-lived GitHub App token scoped to administration:write on
        # the runners repo. Reaches the PowerShell flow as -Token and the
        # Ansible flow as the GH_TOKEN environment variable (which
        # ops/_run-playbook.sh forwards through to ansible-playbook as
        # extra-vars via the chmod-600 tmpfs file - never on argv).
        [Parameter(Mandatory)]
        [string] $Token,

        # E2E test secret suffix. Routes both flows to the same
        # *-{suffix} secret names in the GitHubRunners vault.
        [Parameter(Mandatory)]
        [string] $SecretSuffix,

        [Parameter(Mandatory)]
        [PSCustomObject] $VmDef,

        [Parameter(Mandatory)]
        [object] $Entry
    )

    switch ($RunnersFlow) {
        'custom-powershell' {
            # The invocation that lived inline in Invoke-RunnerLifecycleTest
            # before this step. Identical surface so the existing flow
            # remains a first-class peer of the Ansible one.
            & "$RunnersPath\hyper-v\ubuntu\register-runners.ps1" `
                -Token        $Token `
                -SecretSuffix $SecretSuffix
            if ($LASTEXITCODE -ne 0) {
                throw "custom-powershell register-runners.ps1 exited $LASTEXITCODE"
            }
        }
        'ansible' {
            if (-not $AnsiblePath) {
                throw 'RunnersFlow=ansible requires -AnsiblePath'
            }
            if (-not $WslDistro) {
                throw 'RunnersFlow=ansible requires -WslDistro'
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
            # Push-Location anchors PowerShell's cwd at the repo root so
            # wsl inherits it as the Linux cwd. `wsl --cd <path>` would
            # do the same, but it routes the command through a
            # /bin/sh -c "cd <path>; <cmd>" interop layer with a sparse
            # PATH inherited from the calling PS process - and that sh
            # layer cannot find `bash` by name.
            #
            # GH_TOKEN: the Ansible bridge consumes the token through this
            # env var (ops/_run-playbook.sh validates it before any vault
            # read, then unsets it before invoking ansible-playbook so the
            # token only reaches the play via the chmod-600 tmpfs
            # extra-vars file). Setting it process-wide here is safe
            # because the agent is single-threaded between tests; the
            # finally block clears it whether wsl threw or returned.
            Push-Location $AnsiblePath
            $env:GH_TOKEN = $Token
            # Windows env vars do NOT cross into `wsl -- ...` unless their
            # names are listed in WSLENV. register-runners.sh reads
            # GH_TOKEN from its Linux environment; without this forwarding
            # the variable set above is invisible inside WSL, so the script
            # falls into its interactive `read 'GitHub token:'` prompt and
            # hangs the unattended agent forever. Mirror the SECRET_SUFFIX/u
            # forwarding in Initialize-E2EEnvironment.ps1 (the token is a
            # value, not a path -> /u). Saved and restored in finally so the
            # per-invocation forwarding does not accumulate across tests.
            $priorWslEnv = $env:WSLENV
            if ($env:WSLENV) {
                if ($env:WSLENV -notlike '*GH_TOKEN*') {
                    $env:WSLENV = "$env:WSLENV`:GH_TOKEN/u"
                }
            } else {
                $env:WSLENV = 'GH_TOKEN/u'
            }
            try {
                # `2>&1 | Out-Host`: the wsl invocation is a native
                # command, and its stdout/stderr otherwise get collected
                # into this function's pipeline output. Whoever calls
                # Set-VmRunnersForTest in a subexpression / assignment
                # context (or upstream of any cmdlet pipe) consumes that
                # pipeline and silently drops ansible-playbook's output,
                # leaving the operator to debug an exit code with no
                # error text. Same gotcha as Set-VmUsersForTest's wsl
                # invocation; see that file for the canonical
                # explanation.
                & wsl -d $WslDistro -- ./ops/register-runners.sh 2>&1 | Out-Host
            }
            finally {
                # Belt-and-braces: clear GH_TOKEN even on throw so the
                # token never lingers in the agent process env after this
                # invocation returns.
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
                # Restore WSLENV to its pre-invocation state. A $null prior
                # value means WSLENV did not exist before, so remove it
                # rather than setting it to an empty string.
                if ($null -eq $priorWslEnv) {
                    Remove-Item Env:WSLENV -ErrorAction SilentlyContinue
                } else {
                    $env:WSLENV = $priorWslEnv
                }
                Pop-Location
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Ansible register-runners.sh exited $LASTEXITCODE"
            }
        }
    }
}
