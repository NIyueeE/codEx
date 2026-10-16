#!/usr/bin/env bash
# The single gate runner shared by the local git hooks and CI.
#
# Every check the fork gates on is implemented here, once, so a hook and a CI
# job cannot drift apart: the local gate catches what the remote gate would
# catch, just earlier. CI calls this script; .pre-commit-config.yaml calls this
# script; developers call this script directly.
#
# Tiers
# -----
#   light   no patch list, no bootstrap: seconds. Runs on a pull request, on
#           `git commit`, and from any checkout (`bash scripts/gates.sh light`).
#   tree    needs the bootstrapped tree (BASE_TAG + patches/ applied): the
#           queue's own invariants, the export drift check, the Python suites,
#           the crate boundary, the Cargo compile surface, rustfmt, cargo-deny.
#   full    needs the bootstrapped tree: the release CLI build and the full
#           codex-tui / codex-core suites.
#   heavy   tree + full. What `git push` runs, and what CI runs after a merge.
#   all     light + heavy.
#
# Options
# -------
#   --tree DIR        bootstrapped tree root (default: auto-detect . / tree/ /
#                     update-work/)
#   --only ID[,ID]    run only the named checks
#   --skip ID[,ID]    run everything except the named checks
#   --fast-fail       stop at the first failing check (default for `light`)
#   --no-fail-fast    keep going and report every failure at the end
#                     (default for everything else)
#
# Check ids (stable; use them with --only/--skip)
#   light:  queue readme-ascii readme-zh codespell shellcheck blob-size
#   tree:   queue-tree export package-tests installer-tests boundary
#           type-check config-schema rustfmt cargo-deny
#   full:   release-build tui-tests core-tests
#
# Environment
#   GATES_BASE_SHA, GATES_HEAD_SHA   git range for `blob-size` (CI sets them
#                                    from the event; without them the check is
#                                    skipped with a note)
#   CARGO_BUILD_JOBS=2               memory ceiling, as in AGENTS.md
#   RUST_MIN_STACK=8388608           stack headroom for the snapshot suites
#   NEXTEST_PROFILE=local            the profile CI uses
#   NEXTEST_JOBS=2                   thread cap, as in AGENTS.md
#   TERM_PROFILE=xterm-256color      terminal the snapshot suites expect
#
# Exit status is 0 when every selected check passed, 1 otherwise.
#
# Never run two cargo-backed gate runs against the same tree at once. Cargo
# serialises on the package-cache lock, and the workspace's own tests spawn
# sandboxes, PTYs, and servers, so a second concurrent run starves the first
# and turns marginal timeouts into spurious failures. This runner takes a
# per-tree lock so the mistake surfaces as a clear refusal instead of a
# mystery red test. The light tier runs no cargo, so it takes no lock.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

usage() {
  cat >&2 <<'EOF'
usage: gates.sh [light|tree|full|heavy|all] [--tree DIR]
                [--only ID[,ID]] [--skip ID[,ID]] [--fast-fail|--no-fail-fast]
EOF
}

mode="${1:-light}"
case "${mode}" in
  light | tree | full | heavy | all) ;;
  *)
    usage
    exit 2
    ;;
esac
shift || true

tree_dir=""
fail_fast=""
only=()
skip=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree) tree_dir="$2"; shift 2 ;;
    --only) IFS=',' read -r -a only <<< "$2"; shift 2 ;;
    --skip) IFS=',' read -r -a skip <<< "$2"; shift 2 ;;
    --fast-fail) fail_fast=yes; shift ;;
    --no-fail-fast) fail_fast=no; shift ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# Memory ceilings: the AGENTS.md rules exist because a 20-core host OOMs when an
# unconstrained cargo job links codex-cli with thin LTO (10+ GB in one process)
# and nextest spawns one process per CPU. Keep the same caps CI uses so a local
# pass means a CI pass.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
# codex-tui snapshot tests need the stack headroom CI gives them.
export RUST_MIN_STACK="${RUST_MIN_STACK:-8388608}"
# nextest's `local` profile keeps the app-server integration groups small
# enough for a laptop; CI selects the same profile, so the two agree. The
# thread cap matches the CI ceiling for the same reason.
export NEXTEST_PROFILE="${NEXTEST_PROFILE:-local}"
export NEXTEST_JOBS="${NEXTEST_JOBS:-2}"
# The TUI snapshot suite renders ANSI style escapes, so a terminal that
# advertises no colour makes the cursor/frame assertions fail on frames that
# are perfectly correct. CI runners export a real TERM; pin the same one here
# so a local pass means a CI pass, and so a snapshot is never regenerated
# under a colour-blind terminal (see the snapshot-regeneration rule in
# AGENTS.md).
export TERM="${TERM_PROFILE:-xterm-256color}"
unset NO_COLOR
# The Python suites run inside the tree, and CI fails a job that leaves the
# worktree dirty; bytecode is not part of any check, so never write it.
export PYTHONDONTWRITEBYTECODE=1

if [[ -z "${tree_dir}" ]]; then
  if [[ -d codex-rs ]]; then
    tree_dir="."
  elif [[ -d tree/codex-rs ]]; then
    tree_dir="tree"
  elif [[ -d update-work/codex-rs ]]; then
    tree_dir="update-work"
  fi
fi
code_dir="${tree_dir:+${tree_dir}/codex-rs}"

needs_tree() { [[ "${mode}" == "tree" || "${mode}" == "full" || "${mode}" == "heavy" || "${mode}" == "all" ]]; }

if needs_tree && [[ -z "${tree_dir}" || ! -d "${code_dir}" ]]; then
  echo "gates: mode=${mode} needs a bootstrapped tree, but none was found" >&2
  echo "gates: looked for codex-rs/, tree/, update-work/ under ${repo_root}" >&2
  echo "gates: run 'bash scripts/bootstrap.sh' first (network + a few minutes)." >&2
  exit 1
fi

if [[ -z "${fail_fast}" ]]; then
  if [[ "${mode}" == "light" ]]; then
    fail_fast=yes
  else
    fail_fast=no
  fi
fi

# One cargo-backed gate at a time per tree. flock on a per-tree lock file makes
# a concurrent second invocation refuse rather than compete: two gate runs on
# one host starve each other and turn marginal timeouts into spurious failures.
if needs_tree; then
  gate_lock="${repo_root}/.gates-$(echo "${tree_dir}" | tr '/' '-').lock"
  exec 9>"${gate_lock}"
  if ! flock -n 9; then
    echo "gates: another gate run already holds ${gate_lock}." >&2
    echo "gates: wait for it to finish, or run the tiers one at a time." >&2
    echo "gates: two concurrent runs on one host make the test suites time out." >&2
    exit 1
  fi
fi

failed=()
skipped=()

# run <label> <cmd...>  -- run one check, honouring the fail-fast policy.
run() {
  local label="$1"
  shift
  printf '\n=== %s ===\n' "${label}"
  if [[ "${fail_fast}" == "yes" ]]; then
    "$@"
    return
  fi
  if "$@"; then
    return 0
  fi
  failed+=("${label}")
  printf '\n!!! FAILED: %s\n' "${label}" >&2
}

# skip <label> <reason>
skip() {
  local label="$1" reason="$2"
  skipped+=("${label}: ${reason}")
  printf '\n--- %s: skipped (%s)\n' "${label}" "${reason}"
}

selected() { # $1 id -> 0 when the id was selected by --only/--skip
  local id="$1" entry
  if [[ "${#only[@]}" -gt 0 ]]; then
    for entry in "${only[@]}"; do
      [[ "${entry}" == "${id}" ]] && return 0
    done
    return 1
  fi
  for entry in "${skip[@]}"; do
    [[ "${entry}" == "${id}" ]] && return 1
  done
  return 0
}

# check <id> <label> <cmd...>  -- run a check when --only/--skip selected it.
check() {
  local id="$1"
  shift
  selected "${id}" || return 0
  run "$@"
}

# has <cmd> -- true when the command exists.
has() { command -v "$1" >/dev/null 2>&1; }

# A patch-queue checkout (this repository) exports the queue into patches/;
# a full fork checkout (codex-rs/ at the root) is upstream's tree, where
# patches/ is upstream's Bazel patch directory. The queue checks only apply to
# the former.
queue_repo() { [[ ! -d codex-rs ]]; }

# ---------------------------------------------------------------------------
# Light tier: everything that needs no patch list and no bootstrapped tree, so
# it runs in seconds from the slim repo, from a full checkout, and from the
# commit hook. It covers the queue's exported shape, the docs, spelling, shell
# linting, and the changed-blob budget.
# ---------------------------------------------------------------------------
light_gate() {
  # The queue is the repository's product, and the exported patches/ can be
  # validated on its own: one patch per module, in order, with the exact
  # subjects and file ownership the manifest declares.
  if queue_repo; then
    check queue "patch-queue layout (patches/ + manifest)" \
      bash scripts/check-patch-modules.sh --patches patches
  else
    selected queue && skip "patch-queue layout" "not a patch-queue checkout (codex-rs/ present)"
  fi

  # README.md is fork-owned and shipped, so it has to stay ASCII (plus U+2728)
  # for anchors, search, and diffing. scripts/asciicheck.py is upstream's own
  # checker, carried at the slim root byte-identically so the local hook, CI,
  # and the tree all enforce one implementation.
  check readme-ascii "README ASCII check" \
    python3 scripts/asciicheck.py README.md

  # README.zh.md is slim-only, so the tree's asciicheck does not cover it, and
  # its contract is different: it is a translation, so CJK and the CJK
  # punctuation Chinese prose normally uses are expected. What is banned is the
  # invisible and ambiguous set that breaks anchors, search, diffing, or
  # copy-paste out of a terminal -- the codes asciicheck.py calls out for the
  # ASCII README.
  check readme-zh "README.zh typography check" python3 - <<-'PYEOF'
	import sys
	from pathlib import Path

	# Invisible or look-alike code points that break anchors, search, or
	# diffing. Deliberately excludes U+2014 (em dash, used as "——"), which
	# is ordinary Chinese punctuation.
	banned = {
	    0x00A0,  # no-break space
	    0x2011,  # no-break hyphen
	    0x2018,  # left single quote
	    0x2019,  # right single quote
	    0x201C,  # left double quote
	    0x201D,  # right double quote
	    0x2026,  # ellipsis
	    0x202F,  # narrow no-break space
	}
	path = Path("README.zh.md")
	if not path.exists():
	    print("README.zh.md is absent; nothing to check")
	    raise SystemExit(0)
	bad = {}
	for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
	    for char in line:
	        if ord(char) in banned:
	            bad.setdefault(f"U+{ord(char):04X}", []).append(lineno)
	if bad:
	    for code, lines in sorted(bad.items()):
	        print(f"{path}: {code} on line(s) {lines[:10]}")
	    print("Use the ASCII equivalent instead (see scripts/asciicheck.py).")
	    sys.exit(1)
	print("README.zh.md typography OK")
	PYEOF

  check codespell "codespell" bash -c '
    if command -v codespell >/dev/null 2>&1; then
      exec codespell -I .codespellignore
    fi
    # The pinned version CI uses; uvx keeps it out of an externally managed
    # system Python.
    git ls-files -z | xargs -0 uvx --from codespell==2.4.3 codespell -I .codespellignore
  '

  if has shellcheck; then
    # action.yml files are YAML with embedded shell, which shellcheck cannot
    # parse directly; the shell scripts are what matter, so check those.
    check shellcheck "shellcheck" shellcheck scripts/*.sh install.sh
  else
    selected shellcheck && skip "shellcheck" "not installed (apt install shellcheck)"
  fi

  # Upstream's blob-size policy, narrowed to the fork: the queue is the fork's
  # product and its module patches are the largest files it ships, so
  # patches/*.patch is expanded into the allowlist at run time instead of
  # pinning names that change whenever the queue is regenerated. Without a
  # comparison range (a local run has no pushed range to inspect) the check has
  # nothing to look at and says so.
  if selected blob-size; then
    if [[ -n "${GATES_BASE_SHA:-}" && -n "${GATES_HEAD_SHA:-}" ]]; then
      check blob-size "changed blob sizes" blob_size_check
    else
      skip "changed blob sizes" "no comparison range (set GATES_BASE_SHA/GATES_HEAD_SHA; CI does)"
    fi
  fi
}

blob_size_check() {
  local allowlist
  allowlist="$(mktemp)"
  # Expand at trap-set time: bash drops a function's locals before its RETURN
  # trap runs, so a lazily-expanded ${allowlist} would be unbound.
  trap "rm -f '${allowlist}'" RETURN
  cat .github/blob-size-allowlist.txt > "${allowlist}"
  local patch
  for patch in patches/*.patch; do
    [[ -e "${patch}" ]] && printf '%s\n' "${patch}" >> "${allowlist}"
  done
  python3 scripts/check_blob_size.py \
    --base "${GATES_BASE_SHA}" \
    --head "${GATES_HEAD_SHA}" \
    --max-bytes 512000 \
    --allowlist "${allowlist}"
}

# ---------------------------------------------------------------------------
# Tree tier: the queue applied by scripts/bootstrap.sh. These are the checks
# that only make sense against real sources -- the queue's layout in the tree,
# the export drift check, the Python suites, the compile surface.
# ---------------------------------------------------------------------------
tree_gate() {
  # The tree copy of the manifest check. --patches/--slim are only meaningful
  # when the slim repo and the tree sit on the same base: during an upgrade
  # (update-work/, BASE_TAG already bumped) the export has not been regenerated
  # yet, so comparing it would report the in-flight upgrade as a violation.
  local queue_args=(--tree "${tree_dir}")
  if [[ "${tree_dir}" != "." && -f BASE_TAG && -f "${tree_dir}/BASE_TAG" ]] \
      && [[ "$(cat BASE_TAG)" == "$(cat "${tree_dir}/BASE_TAG")" ]]; then
    queue_args+=(--patches patches --slim .)
  fi
  check queue-tree "patch-module layout (tree, export, slim copies)" \
    bash scripts/check-patch-modules.sh "${queue_args[@]}"

  # A tree commit edited without re-exporting leaves patches/ stale in a way
  # the layout check cannot see, because both sides still satisfy the manifest.
  # This re-exports and byte-compares.
  if queue_repo; then
    check export "patch export matches tree" export_check
  else
    selected export && skip "patch export matches tree" "not a patch-queue checkout"
  fi

  # The package builder produces the release archives and the installer is the
  # fork's own entry point; both suites are pure Python but they import from
  # the tree, so they live in this tier.
  check package-tests "codex_package tests" bash -c "
    CODEX_REPO_ROOT=\"${repo_root}/${tree_dir}\" \
      python3 -m unittest discover -s '${tree_dir}/scripts/codex_package' -p 'test_*.py'
  "

  check installer-tests "installer tests" bash -c "
    CODEX_REPO_ROOT=\"${repo_root}/${tree_dir}\" \
      python3 -m unittest discover -s '${tree_dir}/scripts/install' -p 'test_*.py'
  "

  # Upstream's rule that codex-tui must not import codex-core directly.
  check boundary "codex-tui/codex-core boundary" \
    python3 "${tree_dir}/.github/scripts/verify_tui_core_boundary.py"

  # The CI-equivalent compile gate. A bare `cargo check --workspace` pulls in
  # workspace members that need system headers the fork never installs
  # (voice-host wants gstreamer/glib via pkg-config), so check exactly the
  # three crates the fork builds, tests, and releases.
  check type-check "type-check CLI, TUI, core" bash -c "
    cd '${code_dir}' && cargo check -p codex-cli --bin codex -p codex-tui -p codex-core --all-targets
  "

  check config-schema "config schema fixture" bash -c "
    cd '${code_dir}' || exit 1
    fixture='core/config.schema.json'
    tmp=\"\$(mktemp)\"
    trap 'rm -f \"\$tmp\"' EXIT
    cargo run -q -p codex-config-schema --bin codex-write-config-schema -- --out \"\$tmp\" || {
      echo 'config-schema: failed to generate the schema' >&2
      exit 1
    }
    if ! diff -u \"\$fixture\" \"\$tmp\"; then
      echo 'config-schema: core/config.schema.json is out of date.' >&2
      echo 'Fix: (cd ${code_dir} && cargo run -p codex-config-schema --bin codex-write-config-schema)' >&2
      echo 'then re-export: (cd ${tree_dir} && bash ../scripts/gen-patches.sh \"\$(cat BASE_TAG)\")' >&2
      exit 1
    fi
    echo 'config schema fixture OK'
  "

  check rustfmt "rustfmt" bash -c "cd '${code_dir}' && cargo fmt --check"

  # cargo-deny is CI's own job (cargo-deny.yml, via upstream's action) because
  # the action also caches the advisory database. Locally the same check runs
  # when the binary is installed; without it the local gate says so rather than
  # pretending the licences and advisories were inspected.
  if selected cargo-deny; then
    if has cargo-deny; then
      check cargo-deny "cargo-deny" bash -c "cd '${code_dir}' && cargo deny check"
    else
      skip "cargo-deny" "cargo-deny not installed (CI runs it; cargo install cargo-deny)"
    fi
  fi
}

export_check() {
  local base_tag tmp
  base_tag="$(cat BASE_TAG)"
  tmp="$(mktemp -d)"
  # Expand at trap-set time; see the note in blob_size_check.
  trap "rm -rf '${tmp}'" RETURN
  if ! (cd "${tree_dir}" && bash ../scripts/gen-patches.sh "${base_tag}" "${tmp}" >/dev/null); then
    echo "patch-export: gen-patches.sh failed; fix the tree/queue first" >&2
    return 1
  fi
  if ! diff -rq patches "${tmp}" >/dev/null; then
    echo "patch-export: patches/ drifted from the bootstrapped tree." >&2
    echo "Re-export: (cd ${tree_dir} && bash ../scripts/gen-patches.sh \"${base_tag}\")" >&2
    return 1
  fi
  echo "patch export matches tree"
}

# ---------------------------------------------------------------------------
# Full tier: the build and the suites. Tens of minutes, so it runs on
# pre-push and post-merge rather than on every commit.
# ---------------------------------------------------------------------------
full_gate() {
  check release-build "release CLI build" bash -c "cd '${code_dir}' && cargo build --release --bin codex"

  check tui-tests "codex-tui tests" bash -c "
    cd '${code_dir}' || exit 1
    if ! cargo nextest --version >/dev/null 2>&1; then
      echo 'codex-tui tests: cargo-nextest is required (matches CI).' >&2
      echo 'Install it with: cargo install --locked cargo-nextest' >&2
      exit 1
    fi
    # A few TUI tests spawn the CLI binary, which nextest -p codex-tui does not
    # build, so build it first so they can locate target/debug/codex.
    cargo build --bin codex
    RUST_MIN_STACK=${RUST_MIN_STACK} NEXTEST_PROFILE=${NEXTEST_PROFILE} \
      cargo nextest run -j \"${NEXTEST_JOBS}\" --no-fail-fast -p codex-tui
  "

  check core-tests "codex-core tests" bash -c "
    cd '${code_dir}' || exit 1
    if ! cargo nextest --version >/dev/null 2>&1; then
      echo 'codex-core tests: cargo-nextest is required (matches CI).' >&2
      echo 'Install it with: cargo install --locked cargo-nextest' >&2
      exit 1
    fi
    # The sandbox/approvals integration suite needs sandbox-capable runners,
    # exactly like upstream, which runs it on self-hosted runners only. CI
    # excludes suite::* and so does this gate.
    RUST_MIN_STACK=${RUST_MIN_STACK} NEXTEST_PROFILE=${NEXTEST_PROFILE} \
      cargo nextest run -j \"${NEXTEST_JOBS}\" --no-fail-fast \
      -p codex-core -E 'not test(suite)'
  "
}

printf 'gates: mode=%s tree=%s fail_fast=%s\n' "${mode}" "${tree_dir:-none}" "${fail_fast}"

case "${mode}" in
  light) light_gate ;;
  tree) tree_gate ;;
  full) full_gate ;;
  heavy)
    tree_gate
    full_gate
    ;;
  all)
    light_gate
    tree_gate
    full_gate
    ;;
esac

if [[ ${#skipped[@]} -gt 0 ]]; then
  printf '\nSkipped checks:\n'
  printf '  - %s\n' "${skipped[@]}"
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  printf '\nFailed checks (%d):\n' "${#failed[@]}"
  printf '  - %s\n' "${failed[@]}"
  exit 1
fi

printf '\nAll %s checks passed.\n' "${mode}"
