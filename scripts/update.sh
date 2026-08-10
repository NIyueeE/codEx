#!/usr/bin/env bash
# Upgrades the fork to a new upstream tag.
#
# Usage: bash scripts/update.sh <new-upstream-tag>
#   e.g. bash scripts/update.sh rust-v0.148.0
#
# Flow:
#   1. Shallow-clone the new upstream tag.
#   2. Apply the existing patch queue with `git am --3way`.
#   3. If a patch conflicts, stop and let you resolve it manually
#      (`git am --continue` / `git am --abort`), then run
#      `bash scripts/gen-patches.sh <new-upstream-tag>` to regenerate.
#   4. Build + run the targeted test suite.
#   5. Regenerate patches/, update BASE_TAG, and print release instructions.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/update.sh <new-upstream-tag>" >&2
  exit 1
fi

new_tag="$1"
repo="${FORK_UPSTREAM_REPO:-openai/codex}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
work_dir="${repo_root}/update-work"

rm -rf "${work_dir}"
echo "Cloning https://github.com/${repo}.git at ${new_tag} ..."
git clone --depth 1 --branch "${new_tag}" "https://github.com/${repo}.git" "${work_dir}"
cd "${work_dir}"
git config user.name "codEx Fork Bot"
git config user.email "codex-fork-bot@localhost"

echo "Applying fork patches ..."
if ! git am --3way "${repo_root}"/patches/*.patch; then
  echo "=============================================================" >&2
  echo "Conflict while applying patches against ${new_tag}." >&2
  echo "Resolve conflicts in ${work_dir}, then run:" >&2
  echo "  git am --continue" >&2
  echo "  bash ${repo_root}/scripts/gen-patches.sh ${new_tag}" >&2
  echo "Or abort with: git am --abort" >&2
  echo "=============================================================" >&2
  exit 1
fi

echo "Building ..."
cargo build --release --bin codex

echo "Running targeted tests ..."
just test -p codex-tui
just test -p codex-core

echo "Regenerating patches ..."
bash "${repo_root}/scripts/gen-patches.sh" "${new_tag}" "${repo_root}/patches"
echo "${new_tag}" > "${repo_root}/BASE_TAG"

echo "✅ Upgrade to ${new_tag} complete."
echo "Next steps:"
echo "  1. Commit the new BASE_TAG and patches/."
echo "  2. Tag the fork release: git tag ${new_tag#rust-v}   (plain semver; patch queue never changes versions)"
echo "  3. Push the tag; the release workflow publishes codex-<target>.tar.gz + checksums."
