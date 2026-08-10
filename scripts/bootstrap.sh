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
base_tag="$(cat "${repo_root}/BASE_TAG")"
output_dir="${1:-tree}"

if [[ -d "${output_dir}/codex-rs" ]]; then
  echo "A bootstrapped tree already exists at ${output_dir}/codex-rs; leaving it alone."
  exit 0
fi

echo "Cloning https://github.com/${repo}.git at ${base_tag} ..."
git clone --depth 1 --branch "${base_tag}" "https://github.com/${repo}.git" "${output_dir}"

echo "Applying fork patches ..."
cd "${output_dir}"
git config user.name "codEx Fork Bot"
git config user.email "codex-fork-bot@localhost"
git am --3way "${patches_dir}"/*.patch

echo "✅ Bootstrapped tree ready at ${output_dir} (base ${base_tag})"
