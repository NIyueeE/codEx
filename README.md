# codEx

codEx is a community fork of [openai/codex](https://github.com/openai/codex)
that keeps the CLI happy-path for standalone Linux users: fewer moving parts,
no phone-home update checks, and a built-in `codex update` that downloads
verified binaries from this fork's releases.

This repository follows a **patch-queue model**: instead of vendoring the
upstream tree, it stores only the fork's changes as a `git format-patch`
series plus the scripts that rebuild a full codex tree from an upstream tag.
The actual code lives upstream; `BASE_TAG` pins the upstream tag the current
patch queue applies to (currently `rust-v0.147.0`).

## Installing from a release

Standalone Linux users can install or update codEx with the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/NIyueeE/codEx/main/install.sh | sh
```

The installer resolves the latest fork release, downloads
`codex-<target>.tar.gz` plus its published sha256 checksum, verifies the
checksum before touching anything, and installs into the standalone layout
under `~/.codex/packages/standalone/releases/<version>-<target>/` (with the
bundled `bwrap` under `codex-resources/`) so `codex update` keeps working
afterwards. It then links `codex` into `~/.local/bin` (or `CODEX_INSTALL_DIR`).

Environment overrides:

- `CODEX_RELEASE` - version to install, e.g. `0.147.0` (default: `latest`)
- `CODEX_INSTALL_DIR` - directory for the `codex` symlink (default: `~/.local/bin`)
- `CODEX_HOME` - codex home (default: `~/.codex`)

## What changes versus upstream

codEx keeps the upstream `codex` binary name and configuration format, so it
drops into existing workflows, but changes the surrounding experience:

- **Rollback**: `/rewind` undoes conversation turns and/or workspace file
  changes without git.
- **Input**: Esc no longer interrupts by accident; a double press stops a
  running reply.
- **Updates**: `codex update` is a pure-Rust downloader with checksum
  verification; no `curl | sh`, npm, or brew.
- **Privacy**: no update checks or announcement fetches on startup by default.
- **Distribution**: Linux-only standalone archives (`codex` + `bwrap`), no
  macOS/Windows/app-server bundles.
- **Identity**: the CLI and TUI brand themselves as codEx, and
  `codex --version` points at this fork's repository.

Details below.

### `/rewind` - roll back conversation and workspace files

The headline feature. `/rewind` lets you undo a conversation turn and/or the
file changes a turn made, without needing git.

**Usage**: type `/rewind`, then choose a scope:

1. **Files and conversation** - pick a past message in the transcript; the chat
   forks before that message (a new thread with the conversation truncated
   there, prompt restored into the composer) and the workspace files are
   restored to the snapshot taken right before that message. A confirmation
   shows how many files would be restored and deleted before anything is
   applied; if no matching snapshot exists, the conversation still rewinds
   without touching files.
2. **Conversation only** - pick a past message in the transcript and fork the
   chat before it; files are left untouched.
3. **Files only** - pick a numbered snapshot; a confirmation shows how many
   files would be restored and deleted before the workspace is touched.

Both conversation scopes reuse the transcript picker (the same full-history
view the old double-Esc backtrack used): the newest user message starts
highlighted, **Esc** or **Left** steps to older messages, **Right** steps
newer, and **Enter** confirms the rewind.

**How snapshots work** (pure files, no git involved):

- Before each main-thread user turn is submitted, the TUI snapshots the
  workspace into `~/.codex/snapshots/<workspace-hash>/threads/<conversation>/<turn>/`
  (or `$CODEX_HOME/snapshots/...`). Each conversation owns an independent
  snapshot chain, so conversations never evict each other's snapshots and the
  numbering always matches the picker's transcript ordinals.
  Side-conversation messages and pending steer edits don't create snapshots.
  Each snapshot contains a `manifest.json` (relative path, size, mtime, object
  id for every file, plus a prompt excerpt, a full-prompt hash for exact
  message matching, the snapshot-time `.gitignore` setting, and raw path
  bytes for non-UTF-8 file names) and the file contents under `files/`.
- Storage is a small **content-addressed store** (no git involved): each
  unique file content is saved once under `objects/` and every snapshot's
  `files/` entries are hardlinks into it. Unchanged files are linked from the
  previous snapshot without being re-read, and identical content from any
  earlier turn is never stored twice. A conversation's first snapshot also
  seeds from the newest snapshot of any conversation in the same workspace,
  so resumed and forked conversations stay cheap.
- The walk skips `.git` and, by default, respects `.gitignore` files.
- The most recent **100 snapshots per conversation** are kept by default
  (configurable via `rewind_max_snapshots`); older ones are pruned per
  conversation and their unreferenced objects are garbage-collected, and
  interrupted (manifest-less) snapshot directories are cleaned up.
- Unreadable files are skipped instead of failing the whole snapshot; the
  skipped paths are recorded in the manifest, surfaced in the transcript, and
  left untouched by a later restore. A snapshot that fails outright is also
  shown in the transcript rather than only logged.
- Restore copies snapshot files back over the workspace and deletes files that
  were created after the snapshot. The delete set uses the snapshot-time
  `.gitignore` setting against the current workspace's `.gitignore` rules, so
  the confirmation preview and the actual restore always agree. Restored
  files keep their original mtime so later snapshots stay cheap.
- Restore is preflighted before anything is touched: a missing physical copy,
  a directory in the way, an unsafe recorded path, or a symbolic link above a
  target aborts the restore without modifying anything. A symbolic link at a
  target path is replaced by the restored regular file (never written
  through), and read-only targets are replaced atomically via a temporary
  file and rename.
- The **Files only** picker lists snapshots from all conversations (each
  labeled with a short conversation id and its per-turn change count), and
  file restore is refused while a task is running. Every restore is preceded
  by a dry-run preview that reports the files that would be restored and
  deleted (and is skipped entirely when nothing would change). When a
  conversation rewind has to search other conversations for the matching
  snapshot, ambiguous matches (the same prompt in more than one conversation)
  decline to restore files rather than guessing.

**Configuration** (`config.toml` under the codEx data directory):

| Field | Default | Description |
| --- | --- | --- |
| `rewind_enabled` | `true` | Master switch for `/rewind`. When `false`, the command is disabled and no snapshots are taken. |
| `rewind_respect_gitignore` | `true` | When `true`, snapshots skip `.gitignore`-matched files (and always skip `.git`); set to `false` to snapshot every file. |
| `rewind_max_snapshots` | `100` | How many file snapshots are retained per conversation (`1`-`10000`). Older snapshots are pruned. |

Example:

```toml
rewind_enabled = true            # master switch
rewind_respect_gitignore = true  # respect .gitignore when snapshotting
rewind_max_snapshots = 200       # keep 200 snapshots per conversation
```

**Limitations**:

- Snapshot capture is best effort: a failed capture is surfaced in the
  transcript and the turn continues, so a conversation rewind may have no
  matching file state.
- Snapshots treat a file as unchanged when its size and modification time
  match the previous snapshot; content changes that preserve both (for
  example `touch -r`) are not detected. The snapshot is taken synchronously
  before the turn starts so it always reflects the state before the turn's
  file writes.
- Restore overwrites the current contents of affected files and deletes files
  that were created after the snapshot; edits made after the snapshot are not
  preserved.
- Shell commands can change databases, services, network resources, git
  state, or files outside the active directory; rewind does not reverse those
  side effects, and other processes can edit the workspace between capture
  and restore.
- Snapshots contain the full contents of captured files (excluding
  `.gitignore`-matched paths by default) and are stored under the codEx data
  directory; treat them like source code, not as secret-free metadata.
- Rewind is a convenience for revising recent work, not a replacement for git
  commits or backups.

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
  previous message" backtrack was removed from the main UI; `/rewind` now
  reuses its transcript picker for message selection.

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

- `codex --version` prints
  `codEx 0.147.0 (codEx fork, https://github.com/NIyueeE/codEx)`; the status
  bar shows `codEx <version>`.
- The TUI welcome screen, session header, and status header display `codEx`;
  tips reference `codEx` as well.
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

This repo deliberately does **not** vendor upstream code, unlike a classic
fork that carries the full tree and periodically merges upstream. Instead it
stores only the delta, organized as **one patch per feature module** (not one
per commit):

| Piece | Purpose |
| --- | --- |
| `BASE_TAG` | upstream tag the patch queue applies to (e.g. `rust-v0.147.0`) |
| `patches/` | one `git format-patch` per feature module, in fixed order |
| `scripts/patch-modules.conf` | the module manifest: order, subjects, and file ownership |
| `scripts/check-patch-modules.sh` | machine-checks the manifest against the tree and `patches/` |
| `scripts/bootstrap.sh` | shallow-clone `openai/codex@BASE_TAG` and `git am` the patches |
| `scripts/update.sh` | upgrade to a new upstream tag (apply, CI-equivalent checks, regen) |
| `scripts/gen-patches.sh` | regenerate `patches/` from the tree history; refuses to export a layout that violates the manifest |

The seven modules are `infra` (patch-queue tooling, lockfile, README),
`rollback` (`/rewind`), `input` (double-Esc interrupt), `updates` (pure-Rust
self-update), `privacy` (no startup network chatter), `distribution`
(Linux-only CI/release), and `identity` (branding). Every file changed by the
fork is owned by exactly one module; `check-patch-modules.sh` enforces the
partition at export time (gen-patches), during upgrades (update.sh), in CI
(repo-checks), and locally (pre-commit).

Workflow: a **new feature** adds a section to `patch-modules.conf` and a
matching commit in the bootstrapped tree; a **change to an existing feature**
is rebased/folded into that module's commit. Hand-editing `patches/` is
rejected by the checker.

`bootstrap.sh` + `git am` produce the complete, buildable codEx tree; the CI
and release workflows do exactly that before building. See
[Building](#building-from-this-repository) and
[Upgrading](#upgrading-to-a-new-upstream-tag) below.

## Building from this repository

The slim repository has no `codex-rs/` checked in, so build from a
bootstrapped tree:

```sh
bash scripts/bootstrap.sh        # clones openai/codex@BASE_TAG into tree/ and applies patches/
cd tree/codex-rs
cargo build --release --bin codex
```

If you happen to have a full-tree checkout (with `codex-rs/` present), build
directly:

```sh
cd codex-rs
cargo build --release --bin codex
```

## Upgrading to a new upstream tag

```sh
bash scripts/update.sh rust-v0.148.0
```

`update.sh` clones the new tag into `update-work/`, applies the patch queue
with `git am --3way`, then runs the same checks as CI (build, `cargo fmt
--check`, and the `codex-tui`/`codex-core` nextest runs) from the `codex-rs`
workspace. It accepts the tag with or without the `rust-v` prefix
(`rust-v0.148.0` or `0.148.0`). If a patch conflicts, resolve it in
`update-work/` (`git am --continue`), then regenerate with
`bash scripts/gen-patches.sh rust-v0.148.0` from inside the bootstrapped tree
(the slim repo has no upstream history, so the script refuses to run there).
The patch queue never changes version numbers; fork releases keep the
upstream semver and are tagged `rust-v<version>` (for example
`rust-v0.148.0`), and the release workflow publishes
`codex-<target>.tar.gz` + sha256 checksums.

## License

The fork retains the upstream license (Apache-2.0). See `LICENSE`.
