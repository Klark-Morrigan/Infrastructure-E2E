# Problem

## Index

- [Summary](#summary)
- [For laymen](#for-laymen)
- [Detail](#detail)

---

## Summary

The runner provisioning pipeline spans three repos
(Infrastructure-Vm-Provisioner, Infrastructure-Vm-Users,
Infrastructure-GitHubRunners) with no automated end-to-end verification
that a provisioned Ubuntu VM ends up with a working, registered GitHub
Actions runner. Verification requires real Hyper-V VM creation,
and GitHub API access.

---

## Detail

### What needs to happen

1. A GitHub Actions workflow (manual or scheduled) triggers an E2E
   test run.
2. The workflow creates a GitHub Deployment on `Infrastructure-E2E`
   with environment `e2e-workstation`, encoding test parameters in
   the deployment payload.
3. A polling agent running manually on the workstation detects the
   pending deployment.
4. The agent runs the full provisioning sequence:
   - Provision Ubuntu VM (Infrastructure-Vm-Provisioner)
   - Set up users (Infrastructure-Vm-Users)
   - Register runner + verify service active
     (Infrastructure-GitHubRunners)
   - Verify runner appears online via GitHub API
   - Deregister runner
   - Destroy VM
5. The agent posts a deployment status (success/failure) back to
   GitHub.
6. The workflow reads the deployment status and exits pass/fail.

### Constraints

- The workstation is outbound-only - GitHub Actions cannot reach it
  directly.
- Hyper-V cannot run inside a Docker container or GitHub-hosted runner.
- Git history must not be polluted with test signals (rules out commit
  status API).
- PATs must not require manual rotation (rules out static PATs).
- The polling agent runs manually - it is not a persistent service.
- The agent must exit cleanly after a configurable timeout even if no
  deployment arrives.

### Authentication

A GitHub App is registered and installed on `Infrastructure-E2E` and
`Infrastructure-GitHubRunners`. It provides:

| Permission | Repo | Used by |
|---|---|---|
| `deployments: write` | Infrastructure-E2E | Agent (list + post status) |
| `actions: write` | Infrastructure-GitHubRunners | Agent (registration token, runner list, runner delete) |

The workflow uses `GITHUB_TOKEN` (automatic, `deployments: write`) to
create the deployment in its own repo. The polling agent uses the GitHub
App installation token for deployment status updates and runner API calls.

### Repos involved

| Repo | Role |
|---|---|
| Infrastructure-E2E | Workflow, polling agent, GitHub App config |
| Infrastructure-Vm-Provisioner | Provision and destroy Ubuntu VM |
| Infrastructure-Vm-Users | Set up users on VM |
| Infrastructure-GitHubRunners | Install, register, and verify runner |
