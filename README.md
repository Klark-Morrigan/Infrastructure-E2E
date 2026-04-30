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
  and `Infrastructure-GitHubRunners` respectively.

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
- `Infrastructure.Secrets` module configured with vaults:
  - `VmProvisioner` (owned by `Infrastructure-Vm-Provisioner`)
  - `VmUsers` (owned by `Infrastructure-Vm-Users`)
  - `GitHubRunners` (owned by `Infrastructure-GitHubRunners`)
  - `E2EConfig` (owned by this repo - see [GitHub App setup](#github-app-setup))
- `Infrastructure.Common` >= `2.0.0` installed from PSGallery

---

## GitHub App setup

One-time manual steps required before any E2E test can run.

### 1. Create the GitHub App

Go to `github.com/settings/apps/new` and configure:

| Permission | Repo | Purpose |
|---|---|---|
| `deployments: write` | Infrastructure-E2E | Agent lists pending deployments and posts status |
| `contents: write` | Infrastructure-E2E | Upstream trigger workflows fire `repository_dispatch` |
| `actions: write` | Infrastructure-GitHubRunners | Agent obtains runner registration tokens and manages runners |

Generate and download the private key (`.pem`).

### 2. Install the app

Install the app on all four repos and note the installation ID for
each:

- `Infrastructure-E2E`
- `Infrastructure-Vm-Provisioner`
- `Infrastructure-Vm-Users`
- `Infrastructure-GitHubRunners`

### 3. Configure the E2EConfig vault

Run `agent\setup-secrets.ps1` (added in step 9) to store the
following in the `E2EConfig` vault:

| Field | Description |
|---|---|
| App ID | Shown on the app's settings page |
| Private key path | Local path to the downloaded `.pem` file |
| E2E installation ID | Installation ID for `Infrastructure-E2E` |
| GitHubRunners installation ID | Installation ID for `Infrastructure-GitHubRunners` |
| Provisioner path | Absolute path to `Infrastructure-Vm-Provisioner` on the workstation |
| TestVm.ubuntuVersion | Ubuntu version to provision (e.g. `24.04`) |
| TestVm.ipAddress | IP to assign to the test VM (must be free on VmLAN) |
| TestVm.subnetMask | VmLAN CIDR prefix length (e.g. `24`) |
| TestVm.gateway | VmLAN gateway IP |
| TestVm.dns | DNS server for the test VM |
| TestVm.vmConfigPath | Workstation path for Hyper-V VM config files |
| TestVm.vhdPath | Workstation path for the test VM's VHDX |

### 4. Store Actions secrets in upstream repos

In each of the three upstream repos (`Infrastructure-Vm-Provisioner`,
`Infrastructure-Vm-Users`, `Infrastructure-GitHubRunners`), add the
following GitHub Actions secrets:

| Secret | Value |
|---|---|
| `GH_APP_ID` | App ID |
| `GH_APP_PRIVATE_KEY` | Contents of the `.pem` file |
| `GH_E2E_INSTALLATION_ID` | Installation ID for `Infrastructure-E2E` |

---

## How to run the polling agent

Start the agent on the workstation **before** triggering a workflow run.
The agent must be running when the workflow creates the deployment so it
can pick it up and post a status update promptly.

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

Provisions the test VM, verifies SSH reachability, then tears down.

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

Always start the polling agent on the workstation **before** triggering
a run - the agent must be running when the workflow creates the
deployment.

### Manual

From the GitHub UI: go to **Actions > E2E > Run workflow**.

From the command line:

```bash
gh workflow run e2e.yml --repo <owner>/Infrastructure-E2E
```

### Automatic (push to upstream repos)

Any push to `master` in `Infrastructure-Vm-Provisioner`,
`Infrastructure-Vm-Users`, or `Infrastructure-GitHubRunners` fires a
`repository_dispatch` event that triggers this workflow automatically
(added in step 11).

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
| VM provisioning | `agent/e2e/vm-provisioning/Invoke-VmProvisioningTest.ps1` | VM is reachable via SSH (`hostname` exits 0) |
| VM users | `agent/e2e/vm-users/Invoke-VmUsersTest.ps1` | Expected OS users and groups exist on the VM (step 9) |
| Runner lifecycle | `agent/e2e/runner-lifecycle/Invoke-RunnerLifecycleTest.ps1` | Runner service is active; runner appears online in GitHub API (step 10) |

The polling agent (`Start-E2EAgent.ps1`) always runs the full runner
lifecycle test, which transitively exercises all three layers. The
lower-layer scripts exist so a provisioning or users failure produces a
focused stack trace rather than a runner error.

---

## Repo structure

```
.github/
  workflows/
    e2e.yml                        - E2E workflow (manual, scheduled, cross-repo)
agent/
  e2e/
    vm-provisioning/
      Invoke-VmProvisioningTest.ps1  - VM provisioning E2E test (step 8)
      Start-VmProvisioningTest.ps1   - Manual runner for the provisioning test
    vm-users/
      Invoke-VmUsersTest.ps1         - VM users E2E test (step 9)
    runner-lifecycle/
      Invoke-RunnerLifecycleTest.ps1 - Full runner lifecycle E2E test (step 10)
  Initialize-E2EEnvironment.ps1    - Shared module bootstrap (dot-sourced by entry points)
  Start-E2EAgent.ps1               - Polling agent (run manually on workstation)
Tests/
  Invoke-E2EAgentLoop.Tests.ps1    - Unit tests for the polling loop
docs/
  dev/
    implementation/                - Problem and plan docs per implementation phase
```
