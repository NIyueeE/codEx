#!/usr/bin/env bash
# Bootstraps a buildable codex tree from the upstream `openai/codex` tag
# pinned in BASE_TAG, then applies the fork patch queue with `git am --3way`.
#
# Usage: bash scripts/bootstrap.sh [output-dir]
#   output-dir defaults to "tree".
set -euo pipefail

repo="${FORK_UPSTREAM_REPO:-openai/codex}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
patches_dir="${repo_root}/patches"
base_tag="$(cat "${repo_root}/BASE_TAG" 2>/dev/null || true)"
output_dir="${1:-tree}"

if [[ -z "${base_tag}" ]]; then
  echo "BASE_TAG is missing or empty in ${repo_root}" >&2
  exit 1
fi

if [[ -d "${output_dir}/codex-rs" ]]; then
  echo "A bootstrapped tree already exists at ${output_dir}/codex-rs; leaving it alone."
  exit 0
fi

if [[ -e "${output_dir}" ]]; then
  if [[ ! -d "${output_dir}" ]]; then
    echo "Output path ${output_dir} exists and is not a directory." >&2
    exit 1
  fi
  if [[ -n "$(find "${output_dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Output directory ${output_dir} exists and is not empty (no codex-rs/ inside)." >&2
    echo "Move or remove it first, then re-run this script." >&2
    exit 1
  fi
fi

echo "Cloning https://github.com/${repo}.git at ${base_tag} ..."
git clone --depth 1 --branch "${base_tag}" "https://github.com/${repo}.git" "${output_dir}"

# The tree is a scratch build directory, so it carries only what the fork
# actually builds, tests, and packages with. Upstream's Bazel configuration,
# Python SDK, npm package, macOS signing, and voice tooling are never read
# here, and checking them out only adds noise that has to be re-synced on
# every upstream bump. Keep this list in step with what scripts/gates.sh and
# .github/workflows/rust-release.yml resolve through TREE_DIR.
#
# BASE_TAG is written rather than cloned: it is the fork's own pin, and
# scripts/check-patch-modules.sh reads it back out of the tree to confirm the
# queue was applied to the tag it was exported against.
# --no-cone, not the default cone mode: cone mode always materializes every
# file in the repository root, which would drag in upstream's Bazel, npm,
# Nix, and Prettier configuration. These patterns are gitignore-style and
# anchored at the root, so nothing outside them is checked out.
sparse_patterns=(
  /codex-rs/
  /scripts/
  /.github/scripts/
  /.github/actions/setup-msvc-env/
  /third_party/
  /.cargo/
)
git -C "${output_dir}" sparse-checkout set --no-cone "${sparse_patterns[@]}"

echo "${base_tag}" > "${output_dir}/BASE_TAG"
echo "/BASE_TAG" >> "${output_dir}/.git/info/exclude"

echo "Applying fork patches ..."
cd "${output_dir}"
git config user.name "codEx Fork Bot"
git config user.email "codex-fork-bot@localhost"

if ! git am --3way "${patches_dir}"/*.patch; then
  echo "=============================================================" >&2
  echo "Failed to apply the patch queue against ${base_tag}." >&2
  echo "Resolve conflicts in ${output_dir} and continue with 'git am --continue'," >&2
  echo "or abort with 'git am --abort' and re-run this script after fixing the queue." >&2
  echo "=============================================================" >&2
  exit 1
fi

echo "✅ Bootstrapped tree ready at ${output_dir} (base ${base_tag})"
