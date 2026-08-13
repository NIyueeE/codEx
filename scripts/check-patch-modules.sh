#!/usr/bin/env bash
# Validates that the fork's patch queue matches the module manifest at
# scripts/patch-modules.conf.
#
#   check-patch-modules.sh --tree DIR      validate a bootstrapped tree
#   check-patch-modules.sh --patches DIR   validate an exported patches/ dir
#   check-patch-modules.sh --tree DIR --patches DIR
#
# Tree checks: exactly one commit per manifest module, in order, with the
# exact subjects, and every fork-delta file owned by exactly one module.
# Patch checks: one patch per module, matching subjects, file ownership.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
manifest_path="${script_dir}/patch-modules.conf"

fail=0
note() { printf 'check-patch-modules: %s\n' "$*" >&2; }

order=()
declare -A subjects=()
declare -A patterns=()

# $1 file, $2 slug -> 0 when the file matches the module's patterns.
module_matches() {
    local file="$1" slug="$2" line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$file" in ($line) return 0 ;; esac
    done <<< "${patterns[$slug]}"
    return 1
}

check_tree() { # $1 tree dir
    local tree="$1" base count i commit slug subject file matches
    if [[ ! -f "${tree}/BASE_TAG" ]]; then
        note "--tree ${tree}: BASE_TAG missing"
        fail=1
        return
    fi
    base="$(cat "${tree}/BASE_TAG")"
    if ! git -C "$tree" rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
        note "--tree ${tree}: base tag '${base}' does not resolve"
        fail=1
        return
    fi
    count="$(git -C "$tree" rev-list --count "${base}..HEAD")"
    if [[ "$count" -ne "${#order[@]}" ]]; then
        note "--tree: expected ${#order[@]} commits above ${base}, found ${count}"
        fail=1
    fi
    i=0
    while IFS= read -r commit; do
        slug="${order[$i]}"
        subject="$(git -C "$tree" log -1 --format=%s "$commit")"
        if [[ "$subject" != "${subjects[$slug]}" ]]; then
            note "--tree: commit ${commit} subject '${subject}' != expected '${subjects[$slug]}'"
            fail=1
        fi
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            if ! module_matches "$file" "$slug"; then
                note "--tree: ${slug} commit touches a file it does not own: ${file}"
                fail=1
            fi
        done < <(git -C "$tree" show --no-renames --format= --name-only "$commit")
        i=$((i + 1))
    done < <(git -C "$tree" rev-list --reverse "${base}..HEAD")

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        matches=0
        for slug in "${order[@]}"; do
            if module_matches "$file" "$slug"; then
                matches=$((matches + 1))
            fi
        done
        if [[ "$matches" -eq 0 ]]; then
            note "--tree: fork-delta file owned by no module: ${file}"
            fail=1
        elif [[ "$matches" -gt 1 ]]; then
            note "--tree: fork-delta file owned by ${matches} modules: ${file}"
            fail=1
        fi
    done < <(git -C "$tree" diff --no-renames --name-only "${base}..HEAD")
}

check_patches() { # $1 patches dir
    local dir="$1" i num slug subject file
    local -a patch_files=()
    while IFS= read -r patch; do
        [[ -n "$patch" ]] && patch_files+=("$patch")
    done < <(find "$dir" -maxdepth 1 -name '*.patch' -type f 2>/dev/null | sort)
    if [[ "${#patch_files[@]}" -ne "${#order[@]}" ]]; then
        note "--patches: expected ${#order[@]} patches, found ${#patch_files[@]}"
        fail=1
    fi
    i=0
    for patch in "${patch_files[@]}"; do
        slug="${order[$i]}"
        num="$(printf '%04d' $((i + 1)))"
        local name=""
        name="$(basename "$patch")"
        if [[ "$name" != "${num}-"* || "$name" != *.patch ]]; then
            note "--patches: bad patch name '${name}' (expected ${num}-...)"
            fail=1
        fi
        if [[ ! -s "$patch" ]]; then
            note "--patches: empty patch: ${patch}"
            fail=1
        fi
        subject="$(sed -n 's/^Subject: //p' "$patch" | head -1)"
        if [[ "$subject" != "${subjects[$slug]}" ]]; then
            note "--patches: ${patch} subject '${subject}' != expected '${subjects[$slug]}'"
            fail=1
        fi
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            if ! module_matches "$file" "$slug"; then
                note "--patches: ${patch} touches a file not owned by ${slug}: ${file}"
                fail=1
            fi
        done < <(sed -n 's|^diff --git a/\([^ ]*\) b/\([^ ]*\)$|\1\n\2|p' "$patch" | sort -u)
        i=$((i + 1))
    done
}

tree_arg=""
patches_arg=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tree) tree_arg="$2"; shift 2 ;;
        --patches) patches_arg="$2"; shift 2 ;;
        *) note "unknown argument: $1"; exit 2 ;;
    esac
done
if [[ -z "$tree_arg" && -z "$patches_arg" ]]; then
    note "give --tree DIR and/or --patches DIR"
    exit 2
fi

# Parse the manifest.
current=""
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    [[ -z "${line// }" ]] && continue
    if [[ "$line" == \[*\] ]]; then
        current="${line#[}"
        current="${current%]}"
        order+=("$current")
        subjects["$current"]=""
        patterns["$current"]=""
    elif [[ "$line" == subject:* ]]; then
        [[ -n "$current" ]] || { note "subject line before module section in ${manifest_path}"; exit 1; }
        subjects["$current"]="${line#subject: }"
    else
        [[ -n "$current" ]] || { note "file pattern before module section in ${manifest_path}: ${line}"; exit 1; }
        patterns["$current"]+="${line}"$'\n'
    fi
done < "$manifest_path"

if [[ "${#order[@]}" -eq 0 ]]; then
    note "no modules parsed from ${manifest_path}"
    exit 1
fi
for slug in "${order[@]}"; do
    [[ -n "${subjects[$slug]}" ]] || { note "module ${slug} has no subject"; exit 1; }
    [[ -n "${patterns[$slug]}" ]] || { note "module ${slug} has no file patterns"; exit 1; }
done

if [[ -n "$tree_arg" ]]; then
    [[ -d "$tree_arg" ]] || { note "--tree ${tree_arg} does not exist"; exit 1; }
    check_tree "$tree_arg"
fi
if [[ -n "$patches_arg" ]]; then
    [[ -d "$patches_arg" ]] || { note "--patches ${patches_arg} does not exist"; exit 1; }
    check_patches "$patches_arg"
fi

if [[ "$fail" -ne 0 ]]; then
    note "patch module layout violated"
    exit 1
fi
printf 'patch modules OK: %d modules\n' "${#order[@]}"
