#!/usr/bin/env bash
# Publishes this repo's GitHub Actions release tags - an immutable
# vX.Y.Z plus a floating major vX - on the tip of origin/master, so
# consumers can pin this repo's reusable workflows (ci.yml, e2e.yml,
# ci-docker-*.yml) by tag. Thin shim to Common-Automation's
# publish-version-tags.sh, which holds the engine. Unlike the run-* /
# fix-permissions shims it does NOT set COMMON_AUTOMATION_TARGET_REPO:
# that variable is read by the COMMON_AUTOMATION_TARGET_REPO-aware
# engines, but publish-version-tags.sh operates on the current git
# repo's origin/master, so we cd into this repo first and forward the
# version argument ("$@"; the engine prompts when it is omitted).
# Common-Automation is expected as a sibling checkout under the same
# parent directory.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
common_automation_root="$(cd "${repo_root}/../Common-Automation" && pwd)"

cd "${repo_root}" || exit 1
exec "${common_automation_root}/scripts/publish-version-tags.sh" "$@"
