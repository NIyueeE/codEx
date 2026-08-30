# Repository Guidelines

Contributor guide for codEx, a Linux-only community fork of `openai/codex`
maintained as a **patch-queue repository**: upstream code is not vendored.
Only the fork's delta lives here; `bootstrap.sh` rebuilds a full codex tree
from `BASE_TAG` and applies `patches/` via `git am`.

## Project Structure & Module Organization

- `patches/` — one `git format-patch` per feature module, applied in order:
  `infra`, `rollback`, `updates`, `input`, `privacy`, `distribution`,
  `identity` (see `scripts/patch-modules.conf`)
- `BASE_TAG` — upstream tag the queue applies to (e.g. `rust-v0.151.0`)
- `scripts/` — `bootstrap.sh`, `update.sh`, `gen-patches.sh`,
  `patch-modules.conf` (module manifest), `check-patch-modules.sh` (layout checker)
- `.github/` — CI workflows (`blocking-ci.yml`, `repo-checks.yml`,
  `codespell.yml`, `rust-release.yml`)
- `README.md` / `README.zh.md` — English/Chinese docs

Rust sources exist only after bootstrapping, under `tree/` (or
`update-work/` during upgrades); never commit either — both are gitignored.

## Build, Test & Development Commands

```sh
bash scripts/bootstrap.sh      # clone openai/codex@BASE_TAG into tree/ and apply patches/
cd tree/codex-rs
cargo build --release --bin codex   # build the CLI
cargo fmt --check                   # rustfmt check
```

- `bash scripts/update.sh <tag>` — upgrade to a new upstream tag (`rust-v0.149.1`
  or `0.149.1` both work): clones into `update-work/`, applies the queue with
  `git am --3way`, runs the CI-equivalent checks (build, fmt, nextest) from
  `codex-rs/`, then regenerates `patches/` and `BASE_TAG`
- `bash scripts/gen-patches.sh <base-tag> [output-dir]` — regenerate `patches/`
  as one patch per feature module; run it from inside a bootstrapped tree
  (`tree/` or `update-work/`), e.g. `bash ../scripts/gen-patches.sh rust-v0.148.0`.
  It refuses to run in the slim repo (no upstream history), and refuses to
  export any tree or patch set that violates `patch-modules.conf`
- `bash scripts/check-patch-modules.sh --tree DIR [--patches DIR]` — validate
  the module manifest against a tree and/or an exported patches/ dir
- `pre-commit install` — local hooks (codespell, README ASCII check,
  patch-module layout check, `cargo fmt --check`, config schema fixture
  check, patch export drift check)

## Upgrading the Patch Queue

Upgrades (`rust-vX.Y.Z`) routinely conflict: upstream refactors the same code
regions the fork patches touch. Resolve conflicts with a clear hierarchy:

- **Upstream wins by default.** Take the upstream implementation verbatim
  whenever the conflict region is not part of a fork feature. Cosmetic fork
  deltas (assertion messages, lockfile version sync) are re-applied only
  when they are load-bearing (e.g. `--locked` reproducibility).
- **Only fork core features are re-implemented.** Keep the fork's side when
  the conflict touches behavior the fork exists to change: `/rewind`
  snapshot/restore logic, single-Esc/double-Esc semantics, update-source
  redirection, and the Linux-only CI/release replacement. Everything else
  follows upstream.
- **Independent additions coexist.** When both sides added separate items
  at the same spot (an enum vs a struct, two unrelated calls), keep both.
  When both sides rewrote the same logic block, prefer upstream's rewrite
  and layer the fork behavior on top only if upstream provably cannot
  satisfy the fork feature. Example: upstream's replay-buffer turn merge is
  bounded (32768 events / 256KB of agent deltas), so long sessions evict
  old turns; `/rewind` therefore keeps its `thread_read` fast path while
  upstream's logic survives unchanged as the fallback.
- **Snapshot conflicts resolve against upstream content.** Take the
  upstream `.snap` side, run the suite with `INSTA_UPDATE=always`, then
  review the regenerated diff to confirm it only contains fork-intended
  deltas (bindings, branding, versions).
- **Lockfile conflicts take upstream verbatim.** The fork's only planned
  `Cargo.lock` delta is the workspace member-version sync, and nothing in
  the fork's CI or release workflows builds with `--locked`. Resolve by
  taking upstream's lockfile and letting the build regenerate whatever
  entries fork features need (e.g. `self_update`'s tar/flate2/sha2/ignore);
  the regenerated lock lands in the `[infra]` commit at export time.
- **Upstream deletions win, then scrub the fork.** When upstream removes a
  whole feature the fork's code references (the plan-mode nudge in 0.151.0),
  take upstream's side and delete every fork reference to it, including
  comment mentions -- the queue then applies but the tree must still
  compile. When upstream rewrote machinery the fork had deleted (the
  npm/brew/windows update dispatch in `cli/src/main.rs`), keep the fork's
  replacement, drop upstream's new helpers for the removed variants, and
  grep the merged tree for stale references before continuing.
- **Delete/modify conflicts on fork-deleted files accept the deletion.**
  Upstream edits to files the fork removes (its CI replacement deletes
  upstream workflows and bazel patch files) are irrelevant to the fork;
  resolve with `git rm` and move on.

Operational experience from the rust-v0.149.1 and rust-v0.151.0 upgrades:

- `git am --3way` needs the previous base tag's blobs to build its fake
  ancestor; a shallow clone of the new tag alone fails with "sha1
  information is lacking or useless". `update.sh` fetches the old `BASE_TAG`
  into the shallow clone; the fetch must name the `origin` remote
  explicitly -- a bare `git fetch <refspec>` parses the refspec as a
  repository URL and always fails (this shipped as a silent bug once, so
  the "could not fetch" warning can mean the queue is about to fail with
  missing blobs; fetch the tag manually before retrying `git am`).
- Module order must keep every intermediate revision of the queue
  compilable: `[updates]` precedes `[input]` because the input module
  removes `mod npm_registry;` from lib.rs only after the updates module
  stops referencing it. Reorder commits and the manifest together, never
  one without the other.
- New fork-delta files introduced by an upgrade (regenerated snapshots,
  newly touched upstream files such as the app-server-daemon updater) must
  be added to `scripts/patch-modules.conf` before `gen-patches.sh` will
  export the queue. Brand-new upstream test snapshots whose rendered
  content changes under fork patches count too (the 0.151.0 upgrade had to
  claim a new footer-text snapshot for `[input]`).
- Mid-upgrade the module checks need the tree's `BASE_TAG` bumped first.
  `check-patch-modules.sh` derives the base from the tree, and during an
  upgrade `old-base..HEAD` counts every upstream commit in between -- on a
  clean bootstrap the old base is HEAD's direct parent, so only conflict
  upgrades hit this (mass bogus "touches a file it does not own" notes,
  then an `order[$i]: unbound variable` crash). After `git am --continue`
  finishes the queue: write the new tag into the tree's `BASE_TAG`, fold
  it together with any `[infra]` script/manifest changes into the infra
  commit via fixup commits and `git rebase -i --autosquash rust-vX.Y.Z`,
  and only then run the check and `gen-patches.sh`. Amending `[infra]` is
  also what makes the regenerated patch 0001 carry the new base, so a
  fresh bootstrap records the right `BASE_TAG`.
- History rewrites must not change content. After the autosquash rebase,
  `git diff <pre-rebase-sha> HEAD` has to be empty; a targeted rerun of
  the touched snapshot families confirms nothing shifted.
- After resolving conflicts: grep for leftover conflict markers, run
  `cargo fmt`, build, run the TUI suite with `INSTA_UPDATE=always`
  (regenerates snapshots in one pass; review the resulting `git diff` by
  category -- version strings, fork footer text, unbound-count deltas --
  so surprises stand out), then run core unit tests, then re-bootstrap a
  fresh tree from the regenerated patches as the final proof that the
  queue applies cleanly.
- Upstream files the fork does not need (e.g. CLA/issue-bot workflows that
  only make sense on openai/codex) stay inert inside the bootstrapped tree;
  the slim repo only runs its own four workflows, so they need no cleanup.
- Release builds of this workspace are memory-heavy: linking `codex-cli`
  with thin LTO holds 10+ GB in a single process. Never run multiple
  cargo builds concurrently on one host (even in separate target dirs) --
  the machine can OOM and hang. Run builds serially; on memory-constrained
  hosts cap parallelism with `CARGO_BUILD_JOBS=2` and do not start other
  cargo work while the final link runs. Run long builds detached
  (`setsid nohup ... &`) and poll the log, so an outer tool timeout never
  kills a half-finished compile or link.
- A deterministic single-test failure is not automatically an upgrade
  regression. Before treating it as one, check in order: which assert
  actually fired (read the panic, not just the test name), whether the
  code under test differs between the old and new tags, whether upstream
  `main` already fixed it, and whether the fork touches that area at all.
  The 0.151.0 upgrade hit
  `session::tests::managed_network_proxy_decider_survives_full_access_start`:
  it fails deterministically on hosts whose `/etc/hosts` maps
  `example.com` into the 198.18.0.0/15 fake-IP range, because the network
  proxy's baseline policy blocks the request as a local address before
  the policy decider is consulted (`"source":"baseline_policy"` in the
  response body; the decider counter stays 0). Environmental -- ignore it
  on such hosts, everything else still gates the upgrade.

## Coding Style & Naming Conventions

- Rust: standard `rustfmt`; keep `cargo fmt --check` clean
- Patches: exactly one commit per module in `scripts/patch-modules.conf`;
  every fork-delta file belongs to exactly one module (the ownership
  partition is enforced by `check-patch-modules.sh`). To add a feature,
  append a manifest section and the matching tree commit; to change an
  existing feature, rebase/`--fixup` into that module's commit. Never
  hand-edit `patches/`. Sequential `NNNN-` prefixes, subject-derived names;
  patch content never changes version numbers
- `README.md` must be ASCII-only (U+2728 allowed), enforced by CI
  (`asciicheck`); update `README.zh.md` alongside it
- Keep codespell clean (`.codespellignore` for pre-commit, `.codespellrc` for
  CI); Bash scripts use `set -euo pipefail`

## Testing Guidelines

Tests use `cargo-nextest` in the bootstrapped tree:

```sh
RUST_MIN_STACK=8388608 NEXTEST_PROFILE=local cargo nextest run --no-fail-fast -p codex-tui
RUST_MIN_STACK=8388608 NEXTEST_PROFILE=local cargo nextest run --no-fail-fast \
  -p codex-core -E 'not test(suite)'   # sandbox-dependent suite::* tests need self-hosted runners
```

Add regression tests with bug fixes (e.g. `/rewind` tests). `repo-checks.yml`
also runs the `codex_package` Python unit tests and the `codex-tui`/
`codex-core` boundary check.

TUI snapshot tests are environment-independent: the footer shortcuts pin a
test-only WSL flag, so the full suite passes on WSL hosts and Linux CI alike.

## Publishing a Release

Upgrades (and other `main` changes) ship through CI, in this order:

1. Push `main`, then wait for `blocking-ci` to finish green:
   `gh run list --commit <sha>` followed by
   `gh run watch <run-id> --exit-status`. Never tag before CI concludes.
2. Tag the upgrade commit and push the tag:
   `git tag rust-v<version> <commit> && git push origin rust-v<version>`.
   `rust-release.yml` validates the tag against the workspace version in
   `codex-rs/Cargo.toml`, builds the musl target (~45 min on CI), and
   publishes `codex-<target>.tar.gz` plus its `.sha256`.
3. Verify end to end: download the asset, compare the checksum, and run
   `codex --version` -- expect
   `codEx <version> (codEx fork, https://github.com/NIyueeE/codEx)`.

Pushes to GitHub from this workstation can fail with intermittent
"GnuTLS, handshake failed" errors while `api.github.com` (and `gh`) keep
working; retry the same push several times before investigating anything
else.

## Commit & Pull Request Guidelines

Commits use conventional-style prefixes from the project history — `docs:`,
`fix:`, `ci:`, `release:`, `patches:`, `rewind:` — with a bulleted body
explaining what and why. Keep messages ASCII-only.

PRs must pass every `blocking-ci` job (build, fmt, TUI and core tests,
codespell, repo-checks) and leave the worktree clean. Describe the change and
motivation; link related issues when they exist. Upgrades commit the new
`BASE_TAG` and regenerated `patches/` together, tagged `rust-v<semver>`.
