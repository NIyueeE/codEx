# codEx

codEx is a community fork of [openai/codex](https://github.com/openai/codex)
that keeps the CLI happy-path for standalone Linux users: fewer moving parts,
no phone-home update checks, and a built-in `codex update` that downloads
verified binaries from this fork's releases.

This repository follows a **patch-queue model**: it stores only the fork's
changes (as `git format-patch` series) plus the scripts that rebuild a full
codex tree from an upstream tag. The actual code lives upstream; `BASE_TAG`
pins the upstream tag the current patch queue applies to (currently
`rust-v0.147.0`).

## What changes versus upstream

- **Release & CI**: Linux-only (`x86_64` MUSL), CLI-only. No macOS/Windows or
  ARM64 builds, no DMG, no app-server bundles, no R2/npm/winget.
  CI is plain Cargo: `cargo build --release --bin codex`, `cargo fmt --check`,
  `just test -p codex-tui`, `just test -p codex-core`.
- **`/rewind`**: roll back conversation and/or workspace files. The TUI
  snapshots the workspace (plain files, no git) before each turn under
  `~/.codex/snapshots/<workspace-hash>/<turn>/`, respecting `.gitignore` by
  default, and offers a searchable picker to fork the chat before a chosen
  message and/or restore files to that point. Configurable via
  `rewind_enabled` (default `true`) and `rewind_respect_gitignore` (default
  `true`).
- **Esc behavior**: a single Esc is a no-op in the main UI. Pressing Esc twice
  within 400 ms stops a running reply. Modals, popups, the `?` shortcut
  overlay, and vim-insert mode keep their existing Esc behavior.
- **No update chatter by default**: `check_for_update_on_startup` defaults to
  `false`, and the startup announcement fetch is removed.
- **`codex update`**: pure Rust self-update. It downloads
  `codex-<target>.tar.gz` from this fork's latest release, verifies the sha256
  checksum asset, and atomically replaces the `codex` binary and the bundled
  `bwrap` resource. Non-standalone installs are told to download manually.
- **Branding**: the CLI reports `codEx <version> (codEx fork)`; the status bar
  shows `codEx <version>`. The version number itself matches the upstream base
  tag (for example `0.147.0`), so fork release tags stay plain semver.

## Building from this repository

If `codex-rs/` is present (full-tree checkout, e.g. the `feat/fork-cleanup`
branch), build directly:

```sh
cd codex-rs
cargo build --release --bin codex
```

To rebuild the tree from scratch from the upstream tag:

```sh
bash scripts/bootstrap.sh        # clones openai/codex@BASE_TAG into tree/ and applies patches/
cd tree
cargo build --release --bin codex
```

## Upgrading to a new upstream tag

```sh
bash scripts/update.sh rust-v0.148.0
```

`update.sh` clones the new tag, applies the patch queue with `git am --3way`,
builds and tests, then regenerates `patches/` and updates `BASE_TAG`. If a
patch conflicts, resolve it in `update-work/` (`git am --continue`), then
regenerate with `bash scripts/gen-patches.sh rust-v0.148.0`. The patch queue
never changes version numbers; fork releases are tagged with the plain semver
(for example `0.148.0`) and the release workflow publishes
`codex-<target>.tar.gz` + sha256 checksums.

## License

The fork retains the upstream license (Apache-2.0). See `LICENSE`.
