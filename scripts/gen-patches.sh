#!/usr/bin/env bash
# Regenerates patches/ from a bootstrapped tree's commit history.
#
# Usage (inside the bootstrapped tree after resolving conflicts or after a
# successful update):
#   bash ../scripts/gen-patches.sh <new-base-tag> <patch-output-dir>
#
# In the full fork repository (this checkout), run without arguments to
# materialize the fork branch's commits relative to BASE_TAG:
#   bash scripts/gen-patches.sh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

if [[ $# -ge 1 ]]; then
  # Form used inside a bootstrapped tree.
  base_tag="$1"
  output_dir="${2:-${repo_root}/patches}"
  worktree="$(pwd)"
else
  # Form used in the full fork checkout.
  base_tag="$(cat "${repo_root}/BASE_TAG")"
  output_dir="${repo_root}/patches"
  worktree="${repo_root}"
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"
cd "${worktree}"
git format-patch "${base_tag}"..HEAD --output-directory "${output_dir}" --keep-subject

echo "✅ Wrote $(find "${output_dir}" -name '*.patch' | wc -l) patch(es) to ${output_dir} (base ${base_tag})"
