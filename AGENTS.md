# Repository Guidelines

Contributor guide for codEx, a Linux-only community fork of `openai/codex`
maintained as a **patch-queue repository**: upstream code is not vendored.
Only the fork's delta lives here; `bootstrap.sh` rebuilds a full codex tree
from `BASE_TAG` and applies `patches/` via `git am`.

## Project Structure & Module Organization

- `patches/` — one `git format-patch` per feature module, applied in order:
  `infra`, `rollback`, `input`, `updates`, `privacy`, `distribution`,
  `identity` (see `scripts/patch-modules.conf`)
- `BASE_TAG` — upstream tag the queue applies to (e.g. `rust-v0.147.0`)
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

- `bash scripts/update.sh <tag>` — upgrade to a new upstream tag (`rust-v0.148.0`
  or `0.148.0` both work): clones into `update-work/`, applies the queue with
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

## Commit & Pull Request Guidelines

Commits use conventional-style prefixes from the project history — `docs:`,
`fix:`, `ci:`, `release:`, `patches:`, `rewind:` — with a bulleted body
explaining what and why. Keep messages ASCII-only.

PRs must pass every `blocking-ci` job (build, fmt, TUI and core tests,
codespell, repo-checks) and leave the worktree clean. Describe the change and
motivation; link related issues when they exist. Upgrades commit the new
`BASE_TAG` and regenerated `patches/` together, tagged `rust-v<semver>`.
