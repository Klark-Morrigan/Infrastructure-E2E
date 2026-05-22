# 18 - Static netplan assertions

## Index

- [For laymen](#for-laymen)
- [Summary](#summary)
- [Why this matters](#why-this-matters)
- [What needs to happen](#what-needs-to-happen)
- [Out of scope](#out-of-scope)

---

## For laymen

The provisioner builds Linux VMs that are supposed to come up with a
fixed IP address. A separate piece of work in the provisioner repo
([Infrastructure-Vm-Provisioner feature 40](../../../../../Infrastructure-Vm-Provisioner/docs/dev/implementation/40%20-%20static%20network%20config/problem.md))
moved how that fixed IP gets applied: instead of cloud-init owning the
network config and being able to overwrite it later, the provisioner now
drops a netplan file directly and tells cloud-init not to touch it.

That change has unit tests over the seed *content* it produces, but no
test actually boots a real VM and checks the IP is bound, the right
files are on disk, and cloud-init won't clobber them again. This work
adds those checks to the existing E2E provisioning test so the next
time someone rearranges the netplan delivery, a regression shows up
immediately - not weeks later when an operator finds an unreachable VM.

---

## Summary

The provisioning E2E test (`agent/e2e/vm-provisioning/`) verifies that
a freshly provisioned VM is SSH-reachable and that JDK / file-transfer
/ env-vars side effects are correct - but it asserts nothing about the
on-disk state of the static-IP mechanism the provisioner installs. The
provisioner's own
[feature 40 plan step 4](../../../../../Infrastructure-Vm-Provisioner/docs/dev/implementation/40%20-%20static%20network%20config/plan.md#step-4---end-to-end-verification-on-a-fresh-provision)
intentionally left that gate as a manual operator checklist. Manual
checklists rot - this work moves the gate into the automated suite.

---

## Why this matters

The provisioner change in feature 40 has three on-disk artefacts that
must all be correct for the static IP to survive subsequent boots:

1. `/etc/netplan/99-static.yaml` (mode `0600`) - the netplan-owned
   source of truth.
2. `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` containing
   exactly `network: {config: disabled}` - the flag that stops
   cloud-init from re-evaluating networking and clobbering the file
   above.
3. The IP itself, actually bound on an interface in the running kernel.

The seed-content unit tests in the provisioner cover only what the seed
*looks like* when generated. They cannot prove cloud-init parsed it,
that `write_files` landed at the right paths with the right modes, or
that `netplan apply` ran and actually configured the NIC. SSH reaching
the VM at the configured address is a weak signal - a VM that happened
to get a matching IP by chance (or via a different mechanism) would
satisfy it. We need positive evidence that the feature-40 pipeline ran
end-to-end on a real boot.

## What needs to happen

Extend the existing provisioning E2E with positive assertions over
each of the three artefacts above, on every VM the test brings up,
on every phase that creates or re-runs against a VM. The checks must
fail loudly with a message that names the VM and the observed value so
a regression is identifiable from the test log alone, without re-running
to a console.

The new assertion must reuse the existing `Invoke-SshClientCommand`
helper and the `VmDef` shape already passed through the orchestrator -
no new connection helpers, no new config plumbing.

## Out of scope

- Post-reboot recheck (boot the VM a second time and re-verify the IP
  survived without the seed ISO). Worth doing but requires a reboot
  step the harness does not currently support.
- Asserting netplan YAML structure beyond the substring "this file
  mentions our IP / gateway / DNS." A full structural compare would
  require importing `New-StaticNetplanYaml` from the provisioner repo;
  the substring check is the cheapest meaningful signal.
- Anything about cloud-init's first-boot ordering. The provisioner-side
  design is the provisioner's concern; the E2E test only verifies the
  observable outcome.
