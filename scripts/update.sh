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
#   4. Build + run the same checks as CI (build, fmt, nextest) from the
#      codex-rs workspace root.
#   5. Regenerate patches/, update BASE_TAG, and print release instructions.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/update.sh <new-upstream-tag>" >&2
  exit 1
fi

new_tag="$1"
version="${new_tag#rust-v}"
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid upstream tag '${new_tag}'; expected e.g. rust-v0.148.0" >&2
  exit 1
fi
upstream_tag="rust-v${version}"

repo="${FORK_UPSTREAM_REPO:-openai/codex}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
work_dir="${repo_root}/update-work"
code_dir="${work_dir}/codex-rs"

rm -rf "${work_dir}"
echo "Cloning https://github.com/${repo}.git at ${upstream_tag} ..."
git clone --depth 1 --branch "${upstream_tag}" "https://github.com/${repo}.git" "${work_dir}"
cd "${work_dir}"
git config user.name "codEx Fork Bot"
git config user.email "codex-fork-bot@localhost"

echo "Applying fork patches ..."
if ! git am --3way "${repo_root}"/patches/*.patch; then
  echo "=============================================================" >&2
  echo "Conflict while applying patches against ${upstream_tag}." >&2
  echo "Resolve conflicts in ${work_dir}, then run:" >&2
  echo "  git am --continue" >&2
  echo "  bash ${repo_root}/scripts/gen-patches.sh ${upstream_tag}" >&2
  echo "Or abort with: git am --abort" >&2
  echo "=============================================================" >&2
  exit 1
fi

if [[ ! -d "${code_dir}" ]]; then
  echo "Rust workspace not found at ${code_dir}; upstream layout may have changed." >&2
  exit 1
fi

cd "${code_dir}"
echo "Building ..."
cargo build --release --bin codex

echo "Checking formatting ..."
cargo fmt --check

if ! command -v cargo-nextest >/dev/null 2>&1; then
  echo "cargo-nextest not found; installing it (same as CI) ..."
  cargo install --locked cargo-nextest
fi

echo "Running codex-tui tests ..."
RUST_MIN_STACK=8388608 NEXTEST_PROFILE=local cargo nextest run --no-fail-fast -p codex-tui

echo "Running codex-core tests ..."
# The full core integration suite (sandbox/approvals scenarios) needs
# sandbox-capable runners; CI excludes suite::* tests, so do the same here.
RUST_MIN_STACK=8388608 NEXTEST_PROFILE=local cargo nextest run --no-fail-fast \
  -p codex-core -E 'not test(suite)'

cd "${work_dir}"
echo "Regenerating patches ..."
bash "${repo_root}/scripts/gen-patches.sh" "${upstream_tag}" "${repo_root}/patches"
echo "${upstream_tag}" > "${repo_root}/BASE_TAG"

echo "✅ Upgrade to ${upstream_tag} complete."
echo "Next steps:"
echo "  1. Commit the new BASE_TAG and patches/."
echo "  2. Tag the fork release: git tag ${upstream_tag}"
echo "     (the rust-v prefix is required; the release workflow triggers on rust-v* / v*)"
echo "  3. Push the tag; the release workflow publishes codex-<target>.tar.gz + checksums."
