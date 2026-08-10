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

### `/rewind` - roll back conversation and workspace files

The headline feature. `/rewind` lets you undo a conversation turn and/or the
file changes a turn made, without needing git.

**Usage**: type `/rewind`, then choose a scope:

1. **Files and conversation** - pick a past message; the chat forks before that
   message (a new thread with the conversation truncated there, prompt
   restored into the composer) and the workspace files are restored to the
   snapshot taken right before that message.
2. **Conversation only** - pick a past message from a searchable picker and
   fork the chat before it; files are left untouched.
3. **Files only** - pick a numbered snapshot and restore the workspace to it.

**How snapshots work** (pure files, no git involved):

- Before each user turn is submitted, the TUI snapshots the workspace into
  `~/.codex/snapshots/<workspace-hash>/<turn>/` (or `$CODEX_HOME/snapshots/...`).
  Each snapshot contains a `manifest.json` (relative path, size, mtime for every
  file, plus a prompt excerpt) and the file contents under `files/`.
- Snapshots are **incremental**: a file is only copied again when its size or
  mtime changed since the previous snapshot, so repeated turns are cheap.
- The walk skips `.git` and, by default, respects `.gitignore` files.
- The most recent **20 snapshots** are kept per workspace; older ones are pruned.
- Restore copies snapshot files back over the workspace and deletes files that
  were created after the snapshot (gitignored paths are left alone).

**Configuration** (`config.toml`):

```toml
rewind_enabled = true            # master switch, default true
rewind_respect_gitignore = true  # default true; false snapshots every file
```

### Esc: single press does nothing, double press stops the reply

- A single **Esc** in the main UI/composer is a **no-op** - it no longer
  interrupts a turn or arms any backtrack mode.
- While a reply is running, the **first Esc** shows a footer hint
  ("esc again to stop reply") and arms a **400 ms** window; a **second Esc**
  inside that window interrupts the turn (pending steers are submitted first,
  like the old behavior).
- Existing Esc behavior is preserved everywhere it matters: modals, popups, the
  `?` shortcut overlay, history search, bash-mode prompts, vim-insert mode, and
  the request-user-input panel all still use Esc as before.
- The `chat.interrupt_turn` keybinding is **unbound by default** (you can bind
  it again in `/keymap`; modal views honor it), and the old "Esc-Esc to edit
  previous message" backtrack was removed in favor of `/rewind`.

### `codex update`: pure-Rust self-update

- `codex update` no longer shells out to `curl | sh`, npm, or brew. It is a
  self-contained Rust implementation:
  1. Maps the host architecture to the fork's release target
     (`x86_64-unknown-linux-musl`).
  2. Downloads `codex-<target>.tar.gz` and its `.sha256` asset from this
     fork's latest GitHub release.
  3. Verifies the sha256 checksum **before** touching anything.
  4. Extracts, then atomically replaces the running `codex` binary and the
     bundled `bwrap` resource (`codex-resources/bwrap`), keeping a `.old`
     backup during the swap.
- Because the archive is built by the fork's release workflow, the new
  binary's embedded bwrap digest always matches the new bwrap it ships with.
- Non-standalone installs (npm/brew/... ) get a clear message pointing at the
  fork releases for manual download.

### No update chatter, no announcements

- `check_for_update_on_startup` now defaults to **`false`**: the TUI does not
  phone home on startup. Set it to `true` in `config.toml` to opt in.
- The startup **announcement fetch** (remote `announcement_tip.toml`) was
  removed entirely; only the local random tooltips remain.
- Update banners/notices, when enabled, point at this fork's releases and tell
  you to run `codex update`.

### Branding

- `codex --version` prints `codEx 0.147.0 (codEx fork)`; the status bar shows
  `codEx <version>`.
- The version number itself **matches the upstream base tag** (e.g. `0.147.0`),
  so version parsing stays plain semver and fork release tags stay clean.

### Release & CI (Linux + CLI only)

- **Release matrix**: `x86_64-unknown-linux-musl` only (upstream ships
  macOS/Windows/ARM64/app-server bundles; this fork does not). Each release
  publishes exactly two assets:
  - `codex-x86_64-unknown-linux-musl.tar.gz` (contains `codex` + `bwrap`)
  - `codex-x86_64-unknown-linux-musl.tar.gz.sha256`
- **CI** (`blocking-ci.yml`) is plain Cargo on hosted runners:
  `cargo build --release --bin codex`, `cargo fmt --check`,
  `codex-tui` full test suite, `codex-core` unit tests, codespell, repo-checks.
  The sandbox-dependent core integration suite (`suite::*`) needs
  sandbox-capable runners and is excluded from hosted CI, mirroring upstream's
  own self-hosted-runner setup.
- The workflows are bootstrap-aware: they work both in a full checkout and in
  this slim repo (bootstrap first, then build/test/release inside `tree/`).

### Patch-queue model

This repo deliberately does **not** vendor upstream code. It stores:

- `BASE_TAG` - the upstream tag the current patch queue applies to
- `patches/` - `git format-patch` series with every fork change
- `scripts/bootstrap.sh` - shallow-clone `openai/codex@BASE_TAG`, apply patches
- `scripts/update.sh` - upgrade to a new upstream tag (apply, resolve, regen)
- `scripts/gen-patches.sh` - regenerate the patch series from git history

`bootstrap.sh` + `git am` produce the complete, buildable codEx tree; the CI
and release workflows do exactly that before building. See
[Building](#building-from-this-repository) and
[Upgrading](#upgrading-to-a-new-upstream-tag) below.

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
