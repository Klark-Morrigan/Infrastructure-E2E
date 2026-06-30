<#
.NOTES
    Dispatcher for the create-side of the vm-users E2E layer. Selects
    between the bespoke PowerShell flow and the Ansible flow. Both flows
    now resolve within Infrastructure-Vm-Users (the user domain owner):
    custom-powershell runs hyper-v/ubuntu/PowerShell/create-users.ps1, ansible
    runs hyper-v/ubuntu/Ansible/ops/create-users.sh - the latter consuming the
    Common-Ansible substrate (roles + bridge) as a sibling checkout. Each impl
    is a self-contained slice under hyper-v/ubuntu/. Both reconcile the
    same on-VM state from the same VmUsersConfig vault entry; the test
    layer treats them as first-class peers.

    The teardown half stays on remove-users.ps1 for both flows for now -
    feature 03 in Common-Ansible introduces the symmetric
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

        # Infrastructure-Vm-Users repo root. Required for both flows: it
        # is the create-users.ps1 home under custom-powershell and the
        # ops/create-users.sh home under ansible (both user
        # implementations live in their owner repo as of feature 19).
        [Parameter(Mandatory)]
        [string] $UsersPath,

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
            & "$UsersPath\hyper-v\ubuntu\PowerShell\create-users.ps1" -SecretSuffix $script:E2ETestSecretSuffix
            if ($LASTEXITCODE -ne 0) {
                throw "custom-powershell create-users.ps1 exited $LASTEXITCODE"
            }
        }
        'ansible' {
            if (-not $WslDistro) {
                throw 'UsersFlow=ansible requires -WslDistro'
            }
            # Push-Location + `wsl -d <distro> --`:
            #
            # The create-users.sh wrapper lives in the user domain owner
            # (Infrastructure-Vm-Users), so cwd is $UsersPath - the
            # wrapper's repo. The wrapper resolves the Common-Ansible
            # substrate (roles + bridge) itself as a sibling checkout via
            # ops/imports/_common-ansible-root.sh, so this layer passes no
            # Common-Ansible path.
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
            # Push-Location anchors PowerShell's cwd at the wrapper's repo
            # root so wsl inherits it as the Linux cwd. `wsl --cd <path>`
            # would do the same, but it routes the command through a
            # /bin/sh -c "cd <path>; <cmd>" interop layer with a sparse
            # PATH inherited from the calling PS process - and that sh
            # layer cannot find `bash` by name. Push-Location avoids
            # that wrapper entirely; wsl execs the script directly with
            # its normal startup PATH.
            Push-Location $UsersPath
            try {
                # -vvv goes to a file, summary stays on the terminal.
                # The verbose stream localizes any future SSH-via-WSL
                # failure (which hop closed, banner exchange, etc.)
                # without flooding the operator's screen every run.
                # File path: <vmConfigPath>/diagnostics/ansible/
                # <timestamp>-create-users.log. Collocated with the
                # per-VM runtime-diag artefacts so a failed run leaves
                # the full picture in one place.
                $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
                $logDir    = Join-Path $VmDef.vmConfigPath 'diagnostics\ansible'
                if (-not (Test-Path -LiteralPath $logDir)) {
                    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
                }
                # Retention sweep before writing today's log: keep the
                # last 20 transcripts, or 30 days of them, whichever
                # leaves fewer. Caps the diagnostics folder at a
                # bounded size without losing recent failures.
                # Limit-RetainedItem ships in Common.PowerShell, which
                # the agent's bootstrap loads at startup.
                Limit-RetainedItem `
                    -Directory  $logDir `
                    -Filter     '*-create-users.log' `
                    -MaxItems   20 `
                    -MaxAgeDays 30 `
                    -FileOnly
                $logPath = Join-Path $logDir "$timestamp-create-users.log"
                Write-Host "  Ansible verbose log -> $logPath"

                # Pipeline shape:
                #   wsl | Tee-Object  (full -vvv goes to disk)
                #       | Where-Object (filter for the operator-
                #                       readable summary lines)
                #       | Out-Host    (display to terminal,
                #                       bypassing function pipeline)
                # PLAY / TASK / RECAP / fatal: / ok: / changed: /
                # failed: / skipped: / unreachable: cover the lines
                # an operator cares about during a normal run. The
                # full transcript stays in the file for debugging.
                $summaryPattern =
                    '^(PLAY|TASK|PLAY RECAP|fatal:|ok:|changed:|skipped:|failed:|unreachable:|\s*=+\s*$|.*\| (ok|changed|failed|skipping|fatal): \[)'

                & wsl -d $WslDistro -- ./hyper-v/ubuntu/Ansible/ops/create-users.sh -vvv 2>&1 |
                    Tee-Object -FilePath $logPath |
                    Where-Object { $_ -match $summaryPattern } |
                    Out-Host
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
