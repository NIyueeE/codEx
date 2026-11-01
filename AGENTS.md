# Repository Guidelines

codEx is a Linux + Windows TUI/CLI fork of `openai/codex`, maintained as a
patch queue: only the delta lives here. `BASE_TAG` selects the upstream tag;
`bootstrap.sh` rebuilds the tree and applies `patches/` with `git am`.

## Layout and workflow

- `patches/` contains exactly one generated patch per feature module, in order:
  `infra`, `rollback`, `updates`, `input`, `privacy`, `distribution`,
  `identity` (see `scripts/patch-modules.conf`). Never hand-edit it.
- `scripts/` owns bootstrap, upgrades, patch export, ownership checks, and the
  single gate runner. `scripts/gates.sh` is the authority for check contents;
  hooks and CI select tiers from it.
- `.github/` keeps upstream workflow names and narrows their content to Linux +
  Windows. Only `blocking-ci.yml`, `postmerge-ci.yml`, and `rust-release.yml`
  set `concurrency`: called workflows see the caller's `github.workflow`.
- `README.md` is ASCII-only (U+2728 allowed) and `README.zh.md` is its Chinese
  counterpart. Update both when documenting behaviour.
- Rust sources exist only after bootstrapping, under `tree/` (or `update-work/`
  during an upgrade). Both are gitignored and never committed.
- The seven patch modules own disjoint files, machine-checked by
  `check-patch-modules.sh`. A feature adds one manifest section and one tree
  commit; a change is rebased/`--fixup`ed into the owning module, not a new
  module patch. Fork-owned files at the slim root and tree must be identical
  (README, scripts, `.github/*`, `.codespell*`, `install.sh`); `.gitignore` is
  the only intentional exception. This guide is slim-only: edit it directly.
- Commits use conventional prefixes (`docs:`, `fix:`, `ci:`, `release:`,
  `patches:`, `rewind:`) with an ASCII bulleted body. Keep messages ASCII.

## Build, test, and upgrade

```sh
bash scripts/bootstrap.sh
cd tree/codex-rs
cargo build --release --bin codex
cargo fmt --check

CARGO_BUILD_JOBS=2 RUST_MIN_STACK=8388608 NEXTEST_PROFILE=local \
  cargo nextest run -j 2 --no-fail-fast -p codex-tui
CARGO_BUILD_JOBS=2 RUST_MIN_STACK=8388608 NEXTEST_PROFILE=local \
  cargo nextest run -j 2 --no-fail-fast \
  -p codex-core -E 'not test(suite) and not test(code_mode_host)'
```

- `scripts/gates.sh [light|tree|full|heavy|all] [--only ID] [--skip ID]` is
  the single gate implementation. `light` needs no tree (queue layout, docs,
  spelling, shell lint, blob budget); `tree` adds queue/export/slim-copy
  integrity, Python suites, the TUI/core boundary, compile surface, config
  schema, rustfmt, and cargo-deny when installed; `full` adds the release CLI
  build and TUI/core suites; `heavy` is tree + full; `all` is light + heavy.
- `pre-commit install` runs light on commit;
  `pre-commit install --hook-type pre-push` runs heavy before push. A local
  pass uses the same commands as CI. Never run two cargo-backed tiers against
  the same tree: gates.sh takes a per-tree lock. Its flock and capped jobs
  prevent starvation from turning five-second waits into flaky tests.
- Reproduce codespell without modifying system Python:
  `git ls-files -z | xargs -0 uvx --from codespell==2.4.3 codespell -I .codespellignore`.
  Use the pinned versions for other CI tools too; restored caches can make
  `cargo install` fail on an existing binary, so install only when absent.
- Run builds serially with `CARGO_BUILD_JOBS=2`, detached with a log under
  `$HOME/tmp/`, and cap nextest explicitly. `suite::*` needs self-hosted
  sandbox runners and `code_mode_host::*` needs the V8-linked helper built by
  the release workflow; both are excluded from hosted core tests.
  `liblzma-dev`/`libbz2-dev` are needed for TUI test links. The compile gate
  is `cargo check -p codex-cli --bin codex -p codex-tui -p codex-core
  --all-targets`, not `--workspace` (voice-host needs gstreamer headers).
- For upgrades run `bash scripts/update.sh rust-vX.Y.Z` (prefix optional).
  It applies the queue with 3-way merges, runs heavy checks, and regenerates
  `patches/` + `BASE_TAG`. For manual export use
  `bash scripts/gen-patches.sh <base-tag> [output-dir]` from a bootstrapped
  tree. Validate with `check-patch-modules.sh --tree DIR --patches DIR
  --slim .`, then re-bootstrap from the exported queue as the final proof.
  An export applies to a fresh clone with plain `git am`.
- During conflict resolution, fetch the previous base tag with the `origin`
  remote named explicitly so `git am --3way` has its blobs. Bump the tree's
  BASE_TAG before manifest checks. Fold BASE_TAG and any infra changes into
  `[infra]` via fixup + autosquash; `git diff <pre-rebase-sha> HEAD` must be
  empty. Keep module order compilable; update the manifest in the same commit
  as newly owned files. The exporter uses `--no-signature` and the drift check
  normalizes the `From <sha>` line, so different git versions do not churn.

## Diagnose before changing

Compare against the previous `BASE_TAG` and identify the cause first:
upstream behaviour changed, a fork patch is wrong/incomplete, or the fork's
distribution/CI/environment diverged. Then resolve with upstream as the
authority: use its mechanism, remove the contradictory distribution choice,
and keep fork exceptions only where a core feature genuinely requires them
(`/rewind`, Esc semantics, update redirection, Linux + Windows distribution).

- Mirror upstream's structure, commands, step order, and prerequisites; do not
  re-derive them. Cosmetic fork deltas survive only when load-bearing.
- Independent additions coexist; rewrites favour upstream, with fork behaviour
  layered on only when upstream cannot provide it. Upstream deletions win;
  scrub every fork reference, including tests, comments, and branding.
  Delete/modify conflicts on fork-deleted files accept deletion. Lockfile
  conflicts take upstream verbatim and let the build regenerate fork entries.
- Resolve file-level conflicts, not with `-X theirs`; 3-way merges can splice
  neighbouring tests without markers. Read merged functions. Stage every
  `checkout --ours/--theirs` immediately. If a resolution is clobbered,
  rebuild it with `git merge-file` from the new/old upstream blobs and the
  fork's module blob instead of guessing.
- When upstream removed entry points but rewrote the machinery, drop its new
  helpers for removed variants rather than retaining both. Reconstruct such
  files from the fork's prior version and adapt to the new upstream API; do
  not resolve merely block by block.
- A deterministic failure is not automatically a regression: read the panic,
  diff the code, check upstream main, and rule out environment first. Re-run
  load-sensitive tests alone, never patch upstream timeouts. Host networking,
  DNS, runner caches, and terminal settings are common causes.

## CI and releases

CI file ownership belongs to the fork, but upstream owns their content: jobs,
steps, commands, and prerequisites. Narrow, never re-derive. A red check is
diagnosed, not edited; only a genuine runner divergence justifies an edit.

- Do not weaken what a check verifies: no artifact-shaping `CARGO_PROFILE_*`
  overrides, skipped runnable checks, silenced lints, or inflated timeouts.
  Runner limits change job count, target directory, or timeout headroom only.
  `CARGO_BUILD_JOBS=2` is allowed; the published release profile is not.
- Shared prerequisites belong in `bootstrap-tree` (the fork's `setup-ci`
  analogue), once. Mirror upstream's Windows `core.longpaths`, cargo build
  root, `STABLE_GIT_COMMIT`, `--timings`, and non-Apple split-debuginfo
  settings; when a failure points elsewhere, diff the upstream action first.
  When the build root changes, resolve `CARGO_TARGET_DIR` before joining
  paths and check every consumer, including bwrap and the symbols archive.
- The native Windows check is authoritative for `cfg(windows)` code; Linux
  cannot reproduce its toolchain. Treat a red Windows job as a regression,
  not CI noise. A cargo git checkout with chromium submodules needs long
  paths on Windows; runner OOM and disk exhaustion need resource fixes, not
  artifact changes. A shutdown signal is not automatically an OOM - inspect
  step timing and competing jobs before changing anything.
- Snapshot work uses `env -u NO_COLOR TERM=xterm-256color` and
  `INSTA_UPDATE=always`. Take upstream `.snap` content, regenerate, and review
  `git diff rust-v<tag> -- <snap>` for only intended branding/footer deltas.
  Delete stale `.snap.new` files and re-run clean. Claim every regenerated
  snapshot by its driver (branding -> identity, footer/keymap -> input),
  including new `@windows.snap` variants; avoid double-claiming directory
  patterns. Some tests execute `target/debug/codex` or assume `/tmp`, so
  rebuild helpers and keep the temp directory conventional before blaming
  an upgrade for snapshot failures.
- The release workflow publishes `codex-<target>.tar.gz` + `.sha256` for
  x86_64 Linux musl and Windows MSVC, including `bin/codex-exec-server` in
  the canonical package. Push `main`, wait for `blocking-ci`, then tag and
  push `rust-v<version>`; never tag before blocking CI concludes.
- `releases/latest` stays monotonic through `.github/scripts/releases.py`.
  Verify an asset's checksum and `codex --version` after release. Retry the
  intermittent workstation `GnuTLS handshake failed` push before debugging
  elsewhere.

## Product boundary

codEx is headless TUI/CLI only. Remove vendor-facing entry points while
leaving the underlying implementation intact: `codex app`, `/app` and
`codex://`, desktop doctor/update feeds and startup tips, `codex cloud`,
`codex remote-control`, daemon remote-control toggles, and the remote plugin
marketplace. Do not reintroduce or "fix" their absence. Local/Git marketplaces
still work. Check new upstream surfaces against
`grep -rn 'oaistatic|appcast|\.dmg|app-landing-page' codex-rs` and
`codex --help`; pets' CDN sprite pack is the intentional default-disabled
exception. Also remove stale references in tests and to removed modules
(`app_cmd`, `desktop_app`, `remote_control_cmd`, `wsl_paths`, `npm_registry`).

Privacy defaults stay off: no startup update checks, announcement fetches, or
remote plugin searches. `tooltips.rs` should be upstream minus remote
announcements and desktop promotion, not an old fork copy that resurrects
marketing text. Updates use pure Rust against fork releases with checksum
verification; daemon supervision never runs upstream's install script.
Release lookup prefers the `releases/latest` redirect (no REST quota), with
authenticated API fallback. Keep that order in release metadata, self-update,
and the shared fork helpers.

## Queue-maintenance details

- Rebase/history rewrites never change content. Verify touched snapshot
  families after autosquash and ensure exactly the owning module touches the
  manifest. Empty fixups are silently dropped; check with `git log`.
- Resolve advisory drift by bumping the dependency in `[infra]` and
  re-exporting, not adding ignores. Remove ignore entries that no longer
  match the graph. Advisories can appear after the queue was last green.
- Module order is load-bearing (`updates` before `input`). New fork-delta
  files, snapshots, and upstream tests that wait for the product name must be
  claimed before export. Branding should make `OpenAI Codex` unreachable in
  the UI; adapt tests to `codEx` rather than letting them time out.
- Keep each patch's cut minimal: prefer deleting entry points, retaining
  upstream implementations, and avoiding fork-only alternatives. Reconstruct
  inherited UI from the current upstream file when a fork copy is years old;
  the session header is branding-only, not a separate card layout.
- Upstream zsh removal, Windows executable helpers, the standalone executor,
  and `rust-release-windows.yml` settings can move between workflows without
  disappearing. Check the action that actually consumes a setting before
  deleting it from the fork's single-workflow release.
