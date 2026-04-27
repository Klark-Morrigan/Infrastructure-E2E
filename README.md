# Infrastructure-E2E

> End-to-end tests for the infrastructure provisioning pipeline.

## Index

- [Overview](#overview)
- [What this repo does not do](#what-this-repo-does-not-do)
- [Prerequisites](#prerequisites)
- [GitHub App setup](#github-app-setup)
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
- `Infrastructure.Common` >= `1.3.1` installed from PSGallery

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

Run `agent\setup-secrets.ps1` (added in a later step) to store the
following in the `E2EConfig` vault:

| Field | Description |
|---|---|
| App ID | Shown on the app's settings page |
| Private key path | Local path to the downloaded `.pem` file |
| E2E installation ID | Installation ID for `Infrastructure-E2E` |
| GitHubRunners installation ID | Installation ID for `Infrastructure-GitHubRunners` |

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

## Repo structure

```
.github/
  workflows/
    e2e.yml                   - E2E workflow (manual, scheduled, cross-repo)
agent/
  github/                     - GitHub API functions (added in steps 2-5)
  e2e/
    vm-provisioning/          - VM provisioning E2E test
    vm-users/                 - VM users E2E test
    runner-lifecycle/         - Full runner lifecycle E2E test
  Start-E2EAgent.ps1          - Polling agent (run manually on workstation)
docs/
  dev/
    implementation/           - Problem and plan docs per implementation phase
```
