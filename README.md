# Infrastructure-E2E

> End-to-end tests for the infrastructure provisioning pipeline.

## Index

- [Overview](#overview)
- [What this repo does not do](#what-this-repo-does-not-do)
- [Requirements](#requirements)
- [Prerequisites](#prerequisites)
- [GitHub App setup](#github-app-setup)
- [How to run the polling agent](#how-to-run-the-polling-agent)
- [How to run individual tests](#how-to-run-individual-tests)
- [How to trigger](#how-to-trigger)
- [Test coverage](#test-coverage)
- [Timing report and artifact](#timing-report-and-artifact)
- [Linting and CI](#linting-and-ci)
  - [Running the lint suite locally](#running-the-lint-suite-locally)
  - [Known-failing actionlint job](#known-failing-actionlint-job)
- [Repo structure](#repo-structure)

---

## Overview

Verifies that the full provisioning pipeline - VM creation, user setup,
and GitHub Actions runner registration - produces a working, online
runner. Tests run against real infrastructure on the workstation via a
polling agent that receives signals from GitHub Actions workflows.

---

## What this repo does not do

- Unit or integration tests for individual repos - those live in their
  own repos.
- Provisioning, user management, or runner registration - those are
  delegated to `Infrastructure-Vm-Provisioner`, `Infrastructure-Vm-Users`,
  and `Infrastructure-GitHubRunners` respectively. Each domain owns both
  of its flows: `custom-powershell` and `ansible` implementations live
  side by side in the owner repo, and the `ansible` wrappers consume the
  `Common-Ansible` substrate (roles + bridge) as a sibling checkout they
  resolve themselves. User reconciliation, user removal, runner
  registration, and jdk / dotnet toolchain installation each have two
  first-class implementations selected at agent startup via `UsersFlow`,
  `RunnersFlow`, and `ToolchainsFlow`. `ToolchainsFlow` gates only which
  engine installs the toolchains: `custom-powershell` (the default) leaves
  the PowerShell reconciler doing it inside `provision.ps1`, while
  `ansible` drives `Infrastructure-Vm-Provisioner`'s
  `provision-toolchains.sh`. The same jdk / dotnet end-state assertions run
  for both engines, so the two are measured against one bar.

---

## Requirements

PowerShell 7+ (`pwsh`).

---

## Prerequisites

- Windows 11 with Hyper-V enabled
- Administrator privileges on the workstation
- The following repos checked out on the workstation:
  - `Infrastructure-Vm-Provisioner`
  - `Infrastructure-Vm-Users`
  - `Infrastructure-GitHubRunners`
  - `Common-Ansible` - required only when running an `ansible` flow.
    It is not a configured path: the `ansible` wrappers under
    `Infrastructure-Vm-Users` / `Infrastructure-GitHubRunners` resolve it
    as a sibling checkout (a directory named `Common-Ansible` alongside
    the owner repo), so it must sit next to the other repos.
- `Infrastructure.Secrets` module configured with vaults:
  - `VmProvisioner` (owned by `Infrastructure-Vm-Provisioner`)
  - `VmUsers` (owned by `Infrastructure-Vm-Users`)
  - `GitHubRunners` (owned by `Infrastructure-GitHubRunners`)
  - `E2EConfig` (owned by this repo - see [GitHub App setup](#github-app-setup))
- `Common.PowerShell` >= `9.1.0` installed from PSGallery (supplies the
  N-level timing surface the runner-lifecycle run records its phase / part
  breakdown with)
- When `UsersFlow=ansible` (the default since feature 02 of
  `Common-Ansible`), `RunnersFlow=ansible` (opt-in during
  the first validation cycle; the default-flip happens in a follow-up
  bump), or `ToolchainsFlow=ansible` (opt-in; default stays
  `custom-powershell`), the agent runs that flow inside WSL2 via the owner
  repo's wrapper, which resolves the `Common-Ansible` substrate as a
  sibling checkout; the Ansible controller must have been bootstrapped once
  via `Common-Ansible/ops/bootstrap-controller.ps1`. Pass
  `-UsersFlow custom-powershell` to fall back to the original
  Infrastructure-Vm-Users flow, `-RunnersFlow ansible` to opt the
  register-runners half into the Ansible path, or `-ToolchainsFlow ansible`
  to install the jdk / dotnet toolchains via
  `Infrastructure-Vm-Provisioner`'s `provision-toolchains.sh` instead of
  the reconciler. The flow switches are independent: each layer reconciles
  the same on-VM contract regardless of which engine ran it. The
  `ToolchainsFlow=ansible` path reads its desired versions from a
  `Toolchains` vault entry the test writes; that vault is registered lazily
  on first use, so no manual `Toolchains` vault setup is required.

---

## GitHub App setup

One-time manual steps required before any E2E test can run.

### 1. Create the GitHub App

Go to `github.com/settings/apps/new` and fill in:

| Field | Value |
|---|---|
| GitHub App name | Any unique name (e.g. `my-org-e2e-agent`) |
| Homepage URL | Any URL (e.g. your org URL) - required by GitHub, not used |
| Callback URL | Leave blank - only needed for user OAuth flows; this app uses installation tokens |
| Webhook | **Uncheck** "Active" - the app does not receive webhooks |

Under **Repository permissions**, set:

| Permission | Level | Repo | Purpose |
|---|---|---|---|
| Deployments | Read & write | Infrastructure-E2E | Agent polls pending deployments and posts status |
| Contents | Read & write | Infrastructure-E2E | Upstream trigger workflows fire `repository_dispatch` |

Leave all other permissions at **No access**.

Under **Where can this GitHub App be installed?**, select **Only on this account**.

Click **Create GitHub App**. Note the **App ID** shown on the next page.

Scroll to **Private keys** and click **Generate a private key**. Save the
downloaded `.pem` file to a stable local path (e.g.
`C:\private\e2e-agent.pem`) - this path goes into the vault in step 3.

### 2. Install the app

A GitHub App is a registered identity. An **installation** is a grant of
that identity's permissions to a specific account or repo. Each installation
gets its own ID and its own scoped access token - so a token minted for the
`Infrastructure-E2E` installation can only touch `Infrastructure-E2E`, even
though the app has permissions declared for other repos too.

Install the app on all four repos:

1. Go to the app's settings page:
   `github.com/settings/apps/<app-name>/installations`
2. Click **Install** and select your account
3. Choose **Only select repositories**, tick all five repos, and confirm:
   - `Infrastructure-E2E`
   - `Infrastructure-Vm-Provisioner`
   - `Infrastructure-Vm-Users`
   - `Common-Ansible`
   - `Infrastructure-GitHubRunners`

After installing, GitHub redirects to the installation page. The installation
ID is the number at the end of that URL:
`github.com/settings/installations/`**`22222222`**

The polling agent uses two installation IDs:
- **E2E** (`E2EInstallationId`) - to get a `deployments: write` token for
  polling and posting deployment status on `Infrastructure-E2E`
- **GitHubRunners** (`RunnersInstallationId`) - to mint a token scoped to
  `Infrastructure-GitHubRunners` with `administration: write` only, used
  for runner registration and deregistration

Scoping the runners token to one repo and one permission at mint time means
`Administration` access is never granted to the other repos in the installation.

The other three repos (`Infrastructure-Vm-Provisioner`,
`Infrastructure-Vm-Users`, `Common-Ansible`) are installed
so the app can receive `workflow_call` triggers from their CI workflows
- their installation IDs are not needed in the vault.

### 3. Configure the E2EConfig vault

Run `agent\setup-secrets.ps1` (added in step 9) to store the
following in the `E2EConfig` vault:

```jsonc
{
  "AppId":               123456,
  "PrivateKeyPath":      "C:\\private\\e2e-agent.pem",
  "E2EInstallationId":    11111111,  // installation ID for Infrastructure-E2E
  "RunnersInstallationId": 22222222, // installation ID for Infrastructure-GitHubRunners
  "Owner":               "my-org",
  "Repo":                "Infrastructure-E2E",
  "Environment":         "e2e-workstation",
  "PollIntervalSeconds": 30,
  "TimeoutMinutes":      60,
  "ProvisionerPath":     "C:\\a_Code\\Infrastructure-Vm-Provisioner",
  "UsersPath":           "C:\\a_Code\\Infrastructure-Vm-Users",
  "UsersFlow":           "ansible",                                   // optional session default - 'ansible' (default) or 'custom-powershell'; a caller's flow-spec overrides per run
  "WslDistro":           "Ubuntu-24.04",                              // required when any flow is 'ansible' (UsersFlow/RunnersFlow default, ToolchainsFlow opt-in); the WSL2 distro the ansible wrappers run in. Each wrapper (under UsersPath / RunnersPath / ProvisionerPath) self-resolves the Common-Ansible substrate as a sibling checkout, so no Common-Ansible path is configured here. See Common-Ansible README Troubleshooting
  "RunnersPath":         "C:\\a_Code\\Infrastructure-GitHubRunners",
  "RunnersFlow":         "custom-powershell",                         // optional session default - 'custom-powershell' (default) or 'ansible'; a caller's flow-spec overrides per run
  "ToolchainsFlow":      "custom-powershell",                         // optional session default - 'custom-powershell' (default, the jdk/dotnet reconciler) or 'ansible' (provision-toolchains.sh under ProvisionerPath); a caller's flow-spec overrides per run
  "HostTarballCachePath": "C:\\cache\\github-runners",
  "TestVm": {
    "ubuntuVersion":  "24.04",
    "ipAddress":      "192.168.101.10",
    "subnetMask":     24,
    "gateway":        "192.168.101.1",
    "dns":            "8.8.8.8",
    "vmConfigPath":   "E:\\a_VMs\\Hyper-V\\Config",
    "vhdPath":        "E:\\a_VMs\\Hyper-V\\Disks"
  }
}
```

### 4. Store Actions secrets in upstream repos

In each of the four upstream repos (`Infrastructure-Vm-Provisioner`,
`Infrastructure-Vm-Users`, `Common-Ansible`,
`Infrastructure-GitHubRunners`), add the following GitHub Actions
secrets:

| Secret | Value |
|---|---|
| `GH_APP_ID` | App ID |
| `GH_APP_PRIVATE_KEY` | Contents of the `.pem` file |

---

## How to run the polling agent

Start the agent on the workstation. Order relative to triggering the
workflow does not matter - the agent polls for any pending deployment,
so a deployment created before the agent starts is picked up on the
next poll. The only constraint is that the agent must pick the
deployment up before the workflow's status poll times out.

```powershell
# Run from the repo root (elevated PowerShell on the workstation)
.\agent\Start-E2EAgent.ps1
```

Expected console output when a deployment is found and tests pass:

```
E2E agent started. Polling 'e2e-workstation' in my-org/Infrastructure-E2E.
Poll interval: 30s   Timeout: 60min
[10:02:00] No pending deployment. 59min remaining. Waiting 30s ...
[10:02:30] No pending deployment. 59min remaining. Waiting 30s ...
Deployment 123 found - running E2E tests ...
E2E tests passed.
```

Expected output on test failure (exception from the lifecycle test is
re-thrown after posting `failure` status):

```
Deployment 124 found - running E2E tests ...
E2E tests failed: SSH connection refused - VM did not start
```

The agent exits cleanly when the timeout is reached with no deployment:

```
Agent timed out after 60 minutes - no deployment found.
```

---

## How to run individual tests

Use these scripts to run a single test layer on demand - no GitHub
deployment signal or polling agent required. Useful for local debugging
and first-time verification after setup.

Run from an elevated PowerShell session on the workstation.

### VM provisioning test

Runs a four-phase scenario over two VMs so the install / uninstall /
re-install / deprovision lifecycle is covered in a single test run.
VM identities (`vmName`, `ipAddress`, credentials) are pinned across all
phases - only VM1's `javaDevKit` and `envVars` blocks change between
phases.

On the lifecycle path the JDK re-provisioning phases (2-3) run *after*
user reconciliation and runner registration on VM1, so the test
exercises the realistic operator flow: re-provision a machine that is
already fully configured. Users and runner are re-asserted after each
re-provision so a regression that disturbs them surfaces in the same
run.

1. **Install JDK 21 on VM1.** Single-VM `VmProvisionerConfig` with a
   mixed `files` array (one single entry + one bulk pattern entry) so
   both Copy-VmFiles and Copy-VmFilesByPattern dispatch are exercised
   end-to-end. Asserts `JAVA_HOME`, login + non-login `java` on `PATH`,
   `java -version` prefix matches `"21"`, the single fixture landed at
   the target path with matching SHA-256, and exactly three `*.jar`
   fixtures landed under `/opt/ci-jars` with `root:root` ownership,
   mode `0644`, and per-file SHA-256 matching their host sources. The
   VM-side hashes are snapshotted for the idempotence check in phase 2.
   The same VM also carries an `envVars` block (`e2e-ci`) with two
   entries (`FOO_HOME=/opt/foo`, `BAR_VAR=baz`); the test asserts the
   managed block landed in `/etc/environment` with `root:root 0644`,
   both entries appear between the `# BEGIN e2e-ci` / `# END e2e-ci`
   markers, and both values are visible to `pam_env`. After the
   assertions pass an out-of-block sentinel
   (`MARKER_OUTSIDE="untouched"`) is seeded via SSH and the
   `/etc/environment` mtime is snapshotted for phase 2's re-write
   check. On the lifecycle path, users + runner are then created and
   verified online against the JDK-21 VM before phase 2 runs.
2. **Uninstall on VM1, add VM2 (no JDK) in the same run.** Asserts the
   `/opt/jdk-temurin-*` install dir, `/etc/profile.d/jdk.sh`, and stale
   `/usr/local/bin` symlinks are all gone from VM1; asserts VM2 is up
   (hostname matches, cloud-init done) and carries no JDK artifacts. The
   VM2 check is the "blast-radius witness" - a regression that leaked a
   JDK step across VMs would only fire here. VM1's `files` array is
   carried forward unchanged from phase 1 (no edits), so this phase also
   doubles as the no-edit re-provision idempotence check: file contents
   and mode on `/opt/e2e-fixtures/...` and `/opt/ci-jars/*.jar` must
   match the phase-1 SHA-256 snapshot. VM1's `envVars.entries` narrow
   to one entry (BAR_VAR removed); the test asserts BAR_VAR's line is
   gone from the managed block, FOO_HOME's line is still inside it,
   `MARKER_OUTSIDE` survived the re-write outside the block, and
   `/etc/environment`'s mtime advanced past the phase-1 snapshot
   (proving the transport actually rewrote the file rather than
   skip-unchanged). On layers that exist above provisioning, users +
   runner are re-asserted intact immediately after.
3. **Re-install JDK 17 on VM1, VM2 unchanged.** Asserts JDK 17 is the
   active install on VM1 (`JAVA_HOME` under `/opt/jdk-temurin-17`,
   `java -version` prefix matches `"17"`); re-runs the VM2 witness checks
   to confirm phase 3 also did not touch VM2. VM1's `envVars.entries`
   is set to `[]` (the operator's "remove the managed block" intent);
   the test asserts the `# BEGIN e2e-ci` / `# END e2e-ci` markers and
   both formerly-managed entries are gone from `/etc/environment`,
   ownership/mode are unchanged, and `MARKER_OUTSIDE` still sits
   outside the (now absent) block. Users + runner re-asserted intact
   again on layers that have them.
4. **Deprovision both.** Asserts both VMs are gone from Hyper-V, the
   per-VM `.vhdx` and `-seed.iso` files are gone, and the host-side JDK
   cache (tarball + lockfile for versions 21 and 17) is **still present** -
   the cache is host-owned, not VM-owned, so deprovision must not touch it.

Versions and vendor (`temurin`, `21`, `17`) are hard-coded so the prefix
assertion against the reported `java -version` is stable across operator
workstations. The file-transfer fixtures live under
`agent/e2e/vm-provisioning/fixtures/` (single-file fixture as a single
`.txt`; bulk-pattern fixtures under `fixtures/jars/` as three distinct
`.jar` files) and are resolved via `$PSScriptRoot` so the absolute path
is computed per workstation. VM2's IP is derived from VM1's by
incrementing the last octet - operator config still pins a single IP.

The jdk / dotnet toolchain assertion helpers (under
`agent/e2e/vm-provisioning/assertions/`) take the engine-specific parts
of the on-disk layout as parameters: the manifest store directory, the
manifest filename prefix, and the JDK install prefix. The filename
prefix is the leading segment of the manifest basename - the jdk /
dotnet_sdk helpers derive their `<prefix>*.json` listing glob from it,
while the dotnet_tools helpers build the exact
`<prefix><id>-<version>.json` name they probe (and the tools install
helper also takes the parent-SDK prefix for its walker-contract check).
Every parameter defaults to the PowerShell reconciler's layout
(`/var/lib/infra-provisioner/manifests`; `javaDevKit-` / `dotnetSdk-` /
`dotnetTools-`; `/opt/jdk-temurin-`), so the phase files pass nothing
and keep driving the `custom-powershell` flow unchanged. A caller
driving the Common-Ansible toolchain engine reuses the same end-state
checks by passing that engine's store
(`/var/lib/common-ansible/toolchains/manifests`), filename prefixes
(`jdk-` / `dotnet-` / `dotnettool-`), and the `/opt/jdk-` install
prefix.

Manifest *content* differs by engine as well, and only the dotnet_tools
install helper reads it: its I4 field assertions (`rawVersion`,
`ownedSymlinks`) and its I5 parent-SDK `children` walker link are the
PowerShell reconciler's truth-source schema. The Common-Ansible engine
tracks tool manifests independently (a `version` / `symlinks` schema with
no `children` array), verifying that schema in its own role molecule
tests, so its caller passes `-SkipReconcilerManifestSchema` to run only
the engine-agnostic checks (store dir, `/usr/local/bin` symlink, apphost
launch, and tool-manifest presence). The observable end-state those
reconciler-only checks stand in for stays covered by the presence and
symlink probes.

```powershell
# Standard VmLAN setup - no arguments needed:
.\agent\e2e\vm-provisioning\Start-VmProvisioningTest.ps1

# Override the VM IP if the default (192.168.100.10) is already in use:
.\agent\e2e\vm-provisioning\Start-VmProvisioningTest.ps1 -IpAddress 192.168.100.11
```

No vault setup is required before running this script. `VmProvisionerConfig`
is written to the vault at runtime by the test and removed in its `finally`
block regardless of outcome.

Default values assume a standard VmLAN setup (`192.168.100.0/24`, gateway
`192.168.100.1`) and `C:\a_VMs\Hyper-V\` for VM storage. All defaults can
be overridden via parameters.

---

## How to trigger

The polling agent must start and complete the test suite within
**30 minutes** of the workflow creating the deployment - that is the
workflow's polling window. Starting the agent before triggering is the
simplest way to guarantee this.

### Manual

From the GitHub UI: go to **Actions > E2E > Run workflow**.

From the command line:

```bash
gh workflow run e2e.yml --repo <owner>/Infrastructure-E2E
```

### Automatic (PR check in upstream repos)

Pull requests in `Infrastructure-Vm-Provisioner`, `Infrastructure-Vm-Users`,
`Common-Ansible`, and `Infrastructure-GitHubRunners` call this
workflow via `workflow_call` as a required status check. The full
lifecycle layer always runs regardless of which upstream repo the PR is
in - so an Ansible role change cannot merge to master without proving
the new code still reconciles users and brings up an online runner on a
real VM.

Each caller selects which implementation the run exercises through the
`flow-spec` input - a JSON object
`{"usersFlow":"...","runnersFlow":"...","toolchainsFlow":"..."}` with
values `ansible` or `custom-powershell`. The workflow embeds that JSON in
the GitHub Deployment payload; the polling agent reads it and overrides
its vault `UsersFlow` / `RunnersFlow` / `ToolchainsFlow` defaults for that
one run, so a repo's PR exercises the path it owns. Any key may be omitted
- `usersFlow` / `runnersFlow` then fall back to the agent's vault
defaults, and an omitted `toolchainsFlow` stays `custom-powershell` (the
jdk / dotnet reconciler):

| Caller repo | `flow-spec` | Tests |
|---|---|---|
| `Common-Ansible` (users/runners) | `{"usersFlow":"ansible","runnersFlow":"ansible"}` | the Ansible create-users + register-runners scripts |
| `Common-Ansible` (toolchains) | `{"toolchainsFlow":"ansible"}` | `provision-toolchains.sh` installs jdk / dotnet; the shared install / swap / uninstall assertions run against it |
| `Infrastructure-Vm-Users` | `{"usersFlow":"custom-powershell","runnersFlow":"custom-powershell"}` | the PowerShell users scripts |
| `Infrastructure-GitHubRunners` | `{"usersFlow":"custom-powershell","runnersFlow":"custom-powershell"}` | the PowerShell runner-registration script |
| `Infrastructure-Vm-Provisioner` | omitted | the default scenario (ansible users/runners, reconciler toolchains) |

For users and runners `ansible` is the default scenario: a caller that
omits those keys (and a manual `workflow_dispatch` left at its default)
runs both layers on the Ansible path. `toolchainsFlow` is the exception -
it defaults to `custom-powershell` so every existing run keeps installing
toolchains via the reconciler; the `Common-Ansible` toolchain PR opts in.
A `flow-spec` that names an unknown flow, or that upgrades a layer to
`ansible` on an agent without `WslDistro` configured, fails the deployment
with a named error rather than guessing.

### Reading results

Results appear in two places:

- **Actions tab** - the workflow run shows pass/fail and the poll log
  with per-tick state transitions.
- **Deployments UI** (`github.com/<owner>/Infrastructure-E2E/deployments`) -
  shows the `e2e-workstation` environment with the status posted by the
  polling agent (`in_progress`, `success`, or `failure`) and any
  description attached by the agent (e.g. the exception message on
  failure).

---

## Test coverage

The E2E tests are layered - each layer reuses the layer below it and adds
its own assertions on top.

| Layer | Script | Asserts |
|---|---|---|
| VM provisioning | `agent/e2e/vm-provisioning/Invoke-VmProvisioningTest.ps1` | Four-phase install / uninstall / re-install / deprovision lifecycle over two VMs (see [VM provisioning test](#vm-provisioning-test)). Each phase asserts: VM is reachable via SSH; cloud-init completed; root filesystem not full. Per-phase: phase 1 - JDK 21 installed on VM1 (`JAVA_HOME`, login + non-login `PATH`, `java -version` prefix), mixed `files` array landed - single fixture at target + three `*.jar` fixtures under `/opt/ci-jars` (per-file SHA-256, `root:root`, `0644`); phase 2 - VM1 JDK removed (install dir, `/etc/profile.d/jdk.sh`, stale symlinks all gone), VM2 has no JDK artifacts, file-transfer targets on VM1 idempotent vs phase-1 snapshot; phase 3 - JDK 17 active on VM1, VM2 still has no JDK artifacts; phase 4 - both VMs and their disk artifacts removed, host-side JDK cache for both versions preserved |
| VM users | `agent/e2e/vm-users/Invoke-VmUsersTest.ps1` | Expected OS groups exist; expected users exist with correct shell and group membership; sudoers files are in place. The create half dispatches via [`Set-VmUsersForTest.ps1`](agent/e2e/vm-users/Set-VmUsersForTest.ps1) - both flows resolve under `$UsersPath` (`Infrastructure-Vm-Users`, the user domain owner): `UsersFlow=ansible` (default) runs `Infrastructure-Vm-Users/hyper-v/ubuntu/Ansible/ops/create-users.sh` under WSL (the wrapper self-resolves the `Common-Ansible` substrate as a sibling checkout); `UsersFlow=custom-powershell` runs `Infrastructure-Vm-Users/hyper-v/ubuntu/PowerShell/create-users.ps1`. The teardown half dispatches symmetrically via [`Remove-VmUsersForTest.ps1`](agent/e2e/vm-users/Remove-VmUsersForTest.ps1) - `UsersFlow=ansible` runs `Infrastructure-Vm-Users/hyper-v/ubuntu/Ansible/ops/remove-users.sh`; `UsersFlow=custom-powershell` runs `Infrastructure-Vm-Users/hyper-v/ubuntu/PowerShell/remove-users.ps1`. Both halves are first-class permanent peers and either pairing is supported - an `ansible` create can be torn down by a `custom-powershell` remove and vice versa, because both directions reconcile by username against the same on-VM contract. |
| Runner lifecycle | `agent/e2e/runner-lifecycle/Invoke-RunnerLifecycleTest.ps1` | Runner systemd service is active; runner appears online in the GitHub API. The register half dispatches via [`Set-VmRunnersForTest.ps1`](agent/e2e/runner-lifecycle/Set-VmRunnersForTest.ps1) - both flows resolve under `$RunnersPath` (`Infrastructure-GitHubRunners`, the runner domain owner): `RunnersFlow=custom-powershell` (current default) runs `Infrastructure-GitHubRunners/hyper-v/ubuntu/register-runners.ps1`; `RunnersFlow=ansible` runs `Infrastructure-GitHubRunners/hyper-v/ubuntu/Ansible/ops/register-runners.sh` under WSL (the wrapper self-resolves the `Common-Ansible` substrate as a sibling checkout). The default-flip to `ansible` happens in a follow-up bump after the Ansible path validates on real hardware. The teardown half stays on `Infrastructure-GitHubRunners/hyper-v/ubuntu/deregister-runners.ps1` for both flows until the symmetric remove-side fork lands in GitHubRunners. As with `UsersFlow`, either pairing is supported - an `ansible` register can be torn down by the PowerShell deregister and vice versa, because both directions reconcile against the same on-VM and GitHub-API contracts. |

The polling agent (`Start-E2EAgent.ps1`) always runs the full runner
lifecycle test, which transitively exercises all three layers. The
lower-layer scripts exist so a provisioning or users failure produces a
focused stack trace rather than a runner error.

---

## Timing report and artifact

The runner-lifecycle run is the longest-running thing in the fleet and its
cost is spread across four repos and several child processes. To make that
cost visible, every run emits a hierarchical timing report at the end,
built on the N-level timing surface in `Common.PowerShell`.

### What it shows

A single indented, single-colour console block listing the whole run, each
phase as a share of the total, and each part as a share of its parent - to
arbitrary depth, including the internals of the child processes each part
shells out to. It prints on **both the success and failure paths** (via the
run's outer `finally`), so a failed or hung run still shows where the time
went up to the failure point.

```
=== Timing report: runner-lifecycle ===
  Setup                       [OK]     512.30 s  ( 84%)
    provisioning Phase 1      [OK]     430.10 s  ( 84%)
    reconcile users           [OK]      70.20 s  ( 14%)
  Register runners            [OK]      41.80 s  (  7%)
  Verify online               [OK]      18.40 s  (  3%)
  Phase 2 + reassert          [OK]      15.10 s  (  2%)
  Phase 3 + reassert          [OK]      14.90 s  (  2%)
  Teardown                    [OK]       6.70 s  (  1%)
  --------------------------------------
  total observed: 609.20 s
=== Timing report: runner-lifecycle ===
```

Until a given child process ships its own timing emitter, its part renders
as a single opaque span (as `provisioning Phase 1` above); once the emitter
lands, that part deepens into its own sub-steps automatically, with no
change on the E2E side.

### Where the JSON lands

The same tree is persisted as a machine-readable artifact so successive runs
can be compared and a regression (a step that suddenly doubled) is visible.
It is written to:

```
<vmConfigPath>/diagnostics/timing/<timestamp>.json
```

next to the run's `runtime-diag.log` / `console.log`, so all artifacts for a
run stay side by side. `<vmConfigPath>` is the `TestVm.vmConfigPath` from the
`E2EConfig` vault (default `E:\a_VMs\Hyper-V\Config`). The file is the
in-house nested-tree shape (schema `e2e-timing/v1`: explicit `children[]`,
first-class `status`, duration-only `elapsedMs`), not a timestamp trace, so a
cross-process merge is a subtree graft rather than a clock rebase.

### Retention knob

Old artifacts are pruned at write time via `Common.PowerShell`'s
`Limit-RetainedItem`, keeping the most recent N `*.json` files in the
`timing/` folder. N defaults to `20` (the `$script:TimingArtifactRetentionCount`
default in `Publish-E2ETimingReport.ps1`); pass `-MaxItems` to that function
to override the rolling-window size.

### Child-process depth: the `TIMING_TREE_OUTPUT_PATH` opt-in

Each part that shells out to a child process is timed by
`Measure-ChildProcessTimingSpan`, which sets the neutral environment variable
`TIMING_TREE_OUTPUT_PATH` to a fresh per-invocation temp file before the call.
A child that honours the opt-in exports its own timing tree to that path (on
success and failure); after the child returns, the E2E orchestrator imports
that tree and grafts it as the children of the part's span, then deletes the
temp file. When the variable is unset - or the child has no emitter yet, or it
crashes before exporting - nothing is written and the part is simply timed as
a single span, so the graft is graceful by design.

The variable name is deliberately neutral: a production script exports to
whatever path it is handed and never learns that the E2E run is its consumer,
keeping the child scripts test-agnostic.

#### Parts that shell out to more than one exporting child

`Measure-ChildProcessTimingSpan` hands each part **one** output path, so a part
that shells out to two exporting children in sequence would have the second
writer clobber the first. `provisioning Phase 1` is exactly that case under
`ToolchainsFlow=ansible`: it runs `provision.ps1` (the baseline provision) and
then `provision-toolchains.sh` (the Ansible toolchain install), and both honour
the opt-in. To keep the two subtrees separate, the phase wraps the toolchains
shell-out in a **nested** `provision toolchains` child span with its own
per-invocation path, so it grafts as a sub-span rather than overwriting
`provision.ps1`'s export:

```
    provisioning Phase 1      [OK]     430.10 s  ( 84%)
      boot VM                 [OK]     120.00 s  ( 28%)   <- from provision.ps1
      install JDK             [OK]      95.00 s  ( 22%)   <- from provision.ps1
      provision toolchains    [OK]     180.00 s  ( 42%)   <- nested child span
        run jdk role          [OK]      90.00 s  ( 50%)   <- from provision-toolchains.sh
        run dotnet role       [OK]      85.00 s  ( 47%)   <- from provision-toolchains.sh
```

Under `ToolchainsFlow=custom-powershell` the dispatcher shells out to nothing
(the reconciler installed the toolchains inside `provision.ps1`), so the
`provision toolchains` span renders empty.

#### Crossing the WSL boundary for bash children

A pwsh child inherits `TIMING_TREE_OUTPUT_PATH` directly, but a bash child
launched with `wsl -- ...` does not: a Windows environment variable is
invisible inside WSL unless its name is listed in `WSLENV`, and a path value is
unusable there without the `/p` translation flag (which maps the Windows temp
path under `C:` to `/mnt/c/...`). So while it holds the opt-in variable set,
`Measure-ChildProcessTimingSpan` also appends `TIMING_TREE_OUTPUT_PATH/p` to
`WSLENV` for the duration of the action and restores the prior `WSLENV` in the
same `finally` (removed if it did not exist before). The append is guarded
against duplication, so a nested wrap does not stack a second entry.

Doing this once, in the wrapper that owns the opt-in variable, covers every
bash child - present and future - with no per-shell-out edits: the bash
emitters (`register-runners.sh`, `create-users.sh`, `provision-toolchains.sh`)
write the very file the parent then imports. When the wrapper is not on the
stack the variable stays unset and `WSLENV` is untouched, so a normal run is
unchanged.

---

## Linting and CI

Two delegating workflows lint this repo's non-PowerShell surfaces on every
pull request to `master`. Both forward to reusable workflows in
`Common-Automation`, so the lint logic lives in one place and this repo
carries only thin caller files:

- [`.github/workflows/ci-yaml.yml`](.github/workflows/ci-yaml.yml) -
  delegates to Common-Automation's reusable `ci-yaml.yml`, which runs
  actionlint, action-validator, yamllint, and ansible-lint in parallel.
  Each job auto-skips when its target surface is absent.
- [`.github/workflows/ci-bash.yml`](.github/workflows/ci-bash.yml) -
  delegates to Common-Automation's reusable `ci-bash.yml`, which runs
  shellcheck, the `check-sh-executable` +x-bit gate, and every `*.bats`
  suite. This repo's only bash surface is the runner shims under
  `scripts/`, held to the same strict bar as every other repo.

These lint the YAML and bash surfaces only. The real E2E test suite is
Pester and is unaffected - it runs via the polling agent and the
per-layer scripts described above, never through this lint tooling.

### Running the lint suite locally

Three sibling shim commands reproduce the CI surface locally via Git Bash plus
Docker, so failures surface before the PR rather than in CI. All three point
Common-Automation's engine at this repo via `COMMON_AUTOMATION_TARGET_REPO`, so
`Common-Automation` must be a sibling checkout (`..\Common-Automation`).

- [`scripts/run-ci-yaml-and-bash.sh`](scripts/run-ci-yaml-and-bash.sh) is the
  MAIN local entry: the full local equivalent of this repo's `ci-yaml.yml` +
  `ci-bash.yml` - it runs the whole lint suite AND the bats tests in one go.
  Double-clicking [`scripts/run-ci-yaml-and-bash.bat`](scripts/run-ci-yaml-and-bash.bat)
  is the Explorer launcher for the same flow.
- To run a single half: [`scripts/run-lint-yaml-and-bash.sh`](scripts/run-lint-yaml-and-bash.sh)
  runs the LINT half only (shellcheck, actionlint, action-validator, yamllint,
  ansible-lint), and [`scripts/run-tests-bash.sh`](scripts/run-tests-bash.sh)
  runs the bats TEST half only. Each has a sibling `.bat` Explorer launcher.

The lint shim is named `run-lint`, not `run-tests`, to stay distinct from this
repo's real test runner ([`scripts/Run-Tests.ps1`](scripts/Run-Tests.ps1), the
Pester entry) - these bash shims never touch the Pester tests.

Two supporting files keep the bash tooling CI-clean on a Windows checkout:

- [`scripts/fix-permissions.sh`](scripts/fix-permissions.sh) (and its
  [`.bat`](scripts/fix-permissions.bat) launcher) re-stages `+x` on every
  tracked `*.sh` missing it, so the `check-sh-executable` gate stays green
  after authoring a script on Windows (where new files land mode `0644`).
- [`.gitattributes`](.gitattributes) pins `*.sh` to LF and `*.bat` to
  CRLF, so a stray CR on a shebang line cannot break the Linux CI runners.

### Publishing release tags

This repo's workflows ([`e2e.yml`](.github/workflows/e2e.yml),
[`ci-yaml.yml`](.github/workflows/ci-yaml.yml), [`ci-bash.yml`](.github/workflows/ci-bash.yml))
are reusable (`workflow_call`), so consumers pin them by tag. Running
[`scripts/publish-version-tags.sh`](scripts/publish-version-tags.sh) `v1.2.3`
(or double-clicking [`scripts/publish-version-tags.bat`](scripts/publish-version-tags.bat))
delegates to Common-Automation's engine, which places the immutable `vX.Y.Z`
tag and force-moves the floating `vX` tag onto the current tip of
`origin/master` - never the local checkout. With no version argument the
engine prompts for one. Like the lint shims it relies on `Common-Automation`
being a sibling checkout (`..\Common-Automation`).

### Known-failing actionlint job

The pre-existing [`.github/workflows/e2e.yml`](.github/workflows/e2e.yml)
has actionlint findings (invalid `create-github-app-token` inputs and an
unsafe `github.head_ref` usage), so the new `ci-yaml` actionlint job is
currently red. The job is reporting an accurate pre-existing problem; it
will go green once `e2e.yml` is fixed.

---

## Repo structure

```
.github/
  workflows/
    e2e.yml                        - E2E workflow (manual, scheduled, cross-repo)
    ci-yaml.yml                    - YAML/Actions lint, delegates to Common-Automation
    ci-bash.yml                    - Bash lint + bats, delegates to Common-Automation
.gitattributes                     - Pins *.sh to LF, *.bat to CRLF
scripts/
  Run-Tests.ps1                    - Pester test runner (the real test suite)
  run-ci-yaml-and-bash.sh          - MAIN: full local lint + bats (shim to Common-Automation)
  run-ci-yaml-and-bash.bat         - Explorer launcher for run-ci-yaml-and-bash.sh
  run-lint-yaml-and-bash.sh        - Lint half only (shim to Common-Automation)
  run-lint-yaml-and-bash.bat       - Explorer launcher for run-lint-yaml-and-bash.sh
  run-tests-bash.sh                - Bats test half only (shim to Common-Automation)
  run-tests-bash.bat               - Explorer launcher for run-tests-bash.sh
  publish-version-tags.sh          - Publishes vX.Y.Z + floating vX release tags (shim to Common-Automation)
  publish-version-tags.bat         - Explorer launcher for publish-version-tags.sh
  fix-permissions.sh               - Re-stages +x on tracked *.sh (shim)
  fix-permissions.bat              - Explorer launcher for fix-permissions.sh
agent/
  e2e/
    vm-provisioning/
      Invoke-VmProvisioningTest.ps1            - Four-phase VM provisioning E2E orchestrator (Setup, Test, shared helpers)
      Invoke-VmProvisioningPhase1.ps1          - Phase 1: install JDK 21 on VM1 + file-transfer fixture
      Invoke-VmProvisioningPhase2.ps1          - Phase 2: uninstall on VM1 + add VM2 (no JDK)
      Invoke-VmProvisioningPhase3.ps1          - Phase 3: re-install JDK 17 on VM1, VM2 unchanged
      Invoke-VmProvisioningTeardown.ps1        - Deprovision + automatic Invoke-VmTeardownAssertions call
      Invoke-VmTeardownAssertions.ps1          - Post-deprovision assertions (called from Teardown)
      Invoke-NoLeftoverTestVmsAssertions.ps1   - Pre-flight: both test VMs absent in Hyper-V
      Invoke-VmReadyAssertions.ps1             - Baseline cloud-init / hostname / disk checks (all VM1 phases)
      Invoke-JdkInstallAssertions.ps1          - JDK install post-conditions (used by phases 1, 3)
      Invoke-JdkUninstallAssertions.ps1        - JDK removal post-conditions (used by phase 2)
      Invoke-NoJdkVmAssertions.ps1             - "VM2 untouched" witness assertions (phases 2, 3)
      Invoke-DotnetToolsAssertions.ps1         - dotnetTools install / version-change / uninstall post-conditions (covers the happy-path nested-provider lifecycle across phases 1-3)
      Invoke-FileTransferAssertions.ps1        - Copy-VmFiles (single) fixture post-conditions
      Invoke-BulkFileTransferAssertions.ps1    - Copy-VmFilesByPattern (bulk) fixture post-conditions
      Invoke-EnvVarsAppliedAssertions.ps1      - Managed envVars block post-conditions (phases 1, 2)
      Invoke-EnvVarsRemovedAssertions.ps1      - Managed envVars block removal post-conditions (phase 3)
      Start-VmProvisioningTest.ps1   - Manual runner for the provisioning test
    vm-users/
      Invoke-VmUsersTest.ps1               - vm-users E2E + re-asserts after phases 2, 3
      Invoke-VmUsersStillIntactAssertions.ps1 - "users untouched" re-verification block
      Set-VmUsersForTest.ps1               - create-side dispatcher (custom-powershell | ansible)
      Remove-VmUsersForTest.ps1            - teardown dispatcher (custom-powershell | ansible)
    runner-lifecycle/
      Invoke-RunnerLifecycleTest.ps1            - Full lifecycle E2E + re-asserts after phases 2, 3
      Invoke-RunnerStillOnlineAssertions.ps1    - "runner still active + online" re-verification block
      Set-VmRunnersForTest.ps1                  - register-side dispatcher (custom-powershell | ansible)
    timing/
      Measure-ChildProcessTimingSpan.ps1        - Times a shell-out part + grafts the child's exported tree under it
      Publish-E2ETimingReport.ps1               - End-of-run console report + rolling JSON artifact + retention
  Initialize-E2EEnvironment.ps1    - Shared module bootstrap (dot-sourced by entry points)
  Start-E2EAgent.ps1               - Polling agent (run manually on workstation)
Tests/
  Invoke-E2EAgentLoop.Tests.ps1          - Unit tests for the polling loop
  Set-VmUsersForTest.Tests.ps1           - Unit tests for the create-side flow dispatcher
  Remove-VmUsersForTest.Tests.ps1        - Unit tests for the teardown flow dispatcher
  Set-VmRunnersForTest.Tests.ps1         - Unit tests for the register-side flow dispatcher
  Invoke-RunnerLifecycleTest.Tests.ps1   - Unit tests for the lifecycle timing tree + report emission
  Measure-ChildProcessTimingSpan.Tests.ps1 - Unit tests for the child-tree graft
  Invoke-VmProvisioningPhase1.Tests.ps1  - Unit tests for the nested provision-toolchains child span
  Publish-E2ETimingReport.Tests.ps1      - Unit tests for the report + artifact + retention
  support/
    TimingSpanTestDoubles.ps1            - Shared timing doubles for the three timing suites (not a *.Tests.ps1)
docs/
  dev/
    implementation/                - Problem and plan docs per implementation phase
```
