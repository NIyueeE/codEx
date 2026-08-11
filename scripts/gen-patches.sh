#!/usr/bin/env bash
# Regenerates patches/ as a modular series (one patch per commit) from a
# bootstrapped tree's commit history.
#
# Preferred usage (inside the bootstrapped tree after resolving conflicts or
# after a successful update):
#   bash ../scripts/gen-patches.sh <base-tag> [patch-output-dir]
#
# Alternative (full fork checkout whose git history contains the base tag):
#   bash scripts/gen-patches.sh
# Reads BASE_TAG from the repository root. The slim patch-queue repo has no
# upstream history and no codex-rs/ workspace, so this script refuses to run
# there; use it from a bootstrapped tree instead.
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
  base_tag="$(cat "${repo_root}/BASE_TAG" 2>/dev/null || true)"
  output_dir="${repo_root}/patches"
  worktree="${repo_root}"
  if [[ -z "${base_tag}" ]]; then
    echo "BASE_TAG is missing or empty in ${repo_root}" >&2
    exit 1
  fi
fi

# The Rust workspace must be present: this is a bootstrapped tree (tree/,
# update-work/) or a full fork checkout. The slim patch-queue repo cannot
# regenerate the queue because its history has no upstream base commit.
if [[ ! -d "${worktree}/codex-rs" ]]; then
  echo "No codex-rs/ workspace found under ${worktree}." >&2
  echo "Run this script from a bootstrapped tree (tree/ or update-work/), e.g.:" >&2
  echo "  bash ${repo_root}/scripts/gen-patches.sh <base-tag>" >&2
  exit 1
fi

if ! git -C "${worktree}" rev-parse --verify --quiet "${base_tag}^{commit}" >/dev/null; then
  echo "Base tag '${base_tag}' does not resolve in ${worktree}." >&2
  echo "Pass the upstream tag applied to this tree, e.g. rust-v0.148.0." >&2
  exit 1
fi

if ! git -C "${worktree}" merge-base --is-ancestor "${base_tag}" HEAD 2>/dev/null; then
  echo "Base tag '${base_tag}' is not an ancestor of HEAD in ${worktree}." >&2
  exit 1
fi

# Guard against wiping anything broader than the patch directory itself.
if [[ -z "${output_dir}" || "${output_dir}" == "/" ]]; then
  echo "Refusing to use output directory '${output_dir}'" >&2
  exit 1
fi
output_dir="$(mkdir -p "${output_dir}" && cd "${output_dir}" && pwd)"
if [[ "${output_dir}" == "${repo_root}" ]]; then
  echo "Refusing to use output directory '${output_dir}'" >&2
  exit 1
fi
case "${worktree}/" in
  "${output_dir}/"*) echo "Output directory ${output_dir} contains the worktree; refusing." >&2; exit 1 ;;
esac

commit_count="$(git -C "${worktree}" rev-list --count "${base_tag}..HEAD")"
if [[ "${commit_count}" -eq 0 ]]; then
  echo "No commits between ${base_tag} and HEAD; nothing to export." >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"
git -C "${worktree}" format-patch "${base_tag}"..HEAD --output-directory "${output_dir}" --keep-subject

patch_count="$(find "${output_dir}" -name '*.patch' | wc -l)"
if [[ "${patch_count}" -ne "${commit_count}" ]]; then
  echo "Expected ${commit_count} patch(es) but wrote ${patch_count}; review before committing." >&2
  exit 1
fi

echo "✅ Wrote ${patch_count} patch(es) to ${output_dir} (base ${base_tag}):"
find "${output_dir}" -name '*.patch' | sort
