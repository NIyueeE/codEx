# Repository Guidelines

Contributor guide for codEx, a Linux-only community fork of `openai/codex`
maintained as a **patch-queue repository**: upstream code is not vendored.
Only the fork's delta lives here; `bootstrap.sh` rebuilds a full codex tree
from `BASE_TAG` and applies `patches/` via `git am`.

## Project Structure & Module Organization

- `patches/` — the fork's entire change set as a `git format-patch` series,
  named `NNNN-lowercase-hyphen.patch` and numbered from `0001`
- `BASE_TAG` — upstream tag the queue applies to (e.g. `rust-v0.147.0`)
- `scripts/` — `bootstrap.sh`, `update.sh`, `gen-patches.sh`
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

- `bash scripts/update.sh <tag>` — upgrade to a new upstream tag: applies the
  queue with `git am --3way`, tests, then regenerates `patches/` and `BASE_TAG`
- `bash scripts/gen-patches.sh [tag]` — regenerate `patches/` from the tree's
  git history
- `pre-commit install` — local hooks (codespell, README ASCII check,
  patch-queue sanity check, `cargo fmt --check`)

## Coding Style & Naming Conventions

- Rust: standard `rustfmt`; keep `cargo fmt --check` clean
- Patches: sequential `NNNN-` prefixes, lowercase hyphenated names, never
  empty; patch content never changes version numbers
- `README.md` must be ASCII-only (U+2728 allowed), enforced by CI
  (`asciicheck`); update `README.zh.md` alongside it
- Keep codespell clean (`.codespellignore`); Bash scripts use
  `set -euo pipefail`

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

## Commit & Pull Request Guidelines

Commits use conventional-style prefixes from the project history — `docs:`,
`fix:`, `ci:`, `release:`, `patches:`, `rewind:` — with a bulleted body
explaining what and why. Keep messages ASCII-only.

PRs must pass every `blocking-ci` job (build, fmt, TUI and core tests,
codespell, repo-checks) and leave the worktree clean. Describe the change and
motivation; link related issues when they exist. Upgrades commit the new
`BASE_TAG` and regenerated `patches/` together, tagged `rust-v<semver>`.
