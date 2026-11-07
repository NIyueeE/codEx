#!/bin/sh
#
# codEx standalone installer
#
# Downloads the latest codEx fork release from GitHub, verifies its sha256
# checksum, and installs it into the standalone layout that `codex update`
# recognizes:
#
#   $CODEX_HOME/packages/standalone/releases/<version>-<target>/
#     codex-package.json
#     bin/codex
#     codex-path/rg
#     codex-resources/bwrap
#     codex -> bin/codex
#
# The package layout is the same one upstream publishes: it is what
# `InstallContext` recognizes and what `codex app-server daemon` copies when
# it installs the shared background server. A `codex` symlink is placed in
# $CODEX_INSTALL_DIR (default ~/.local/bin).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NIyueeE/codEx/main/install.sh | sh
#
# Environment:
#   CODEX_RELEASE            version to install (default: latest)
#   CODEX_INSTALL_DIR        directory for the codex symlink (default: ~/.local/bin)
#   CODEX_HOME               codex home (default: ~/.codex)
#   CODEX_RELEASES_BASE_URL  base URL for release assets (testing/mirrors)

set -eu

FORK_REPO="NIyueeE/codEx"
DEFAULT_RELEASES_BASE_URL="https://github.com/${FORK_REPO}/releases/download"
RELEASES_BASE_URL="${CODEX_RELEASES_BASE_URL:-$DEFAULT_RELEASES_BASE_URL}"
API_BASE_URL="${CODEX_API_BASE_URL:-https://api.github.com/repos/${FORK_REPO}}"

CODEX_INSTALL_DIR="${CODEX_INSTALL_DIR:-$HOME/.local/bin}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
STANDALONE_ROOT="$CODEX_HOME_DIR/packages/standalone"
RELEASES_DIR="$STANDALONE_ROOT/releases"
CURRENT_LINK="$STANDALONE_ROOT/current"
LOCK_DIR="$STANDALONE_ROOT/install.lock"

step() { printf '==> %s\n' "$1"; }
warn() { printf 'WARNING: %s\n' "$1" >&2; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

cleanup() {
  [ -n "${tmp_dir:-}" ] && rm -rf "$tmp_dir"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' was not found"
}

normalize_version() {
  case "$1" in
    "" | latest)
      printf 'latest\n'
      ;;
    rust-v*)
      printf '%s\n' "${1#rust-v}"
      ;;
    v*)
      printf '%s\n' "${1#v}"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

validate_version() {
  version="$1"

  if [ "$version" = "latest" ]; then
    return
  fi

  if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-alpha(\.[0-9]+){0,2}|-beta(\.[0-9]+)?)?$'; then
    echo "Invalid codEx release version: $version. Expected latest or x.y.z[-alpha[.N[.M]]|-beta[.N]]." >&2
    return 1
  fi
}

# Reads the top-level string fields of a JSON document as `key<TAB>value` lines.
# The pruning pass uses it on a package's codex-package.json, whose version,
# target, and entrypoint decide whether a release directory may be retired. The
# asset fields are kept as well so the parser stays the one upstream ships and
# tests, rather than a fork-specific cut of it.
parse_release_metadata() {
  # Bound awk's record size so compact, single-line JSON stays fast on every
  # supported awk implementation. JSON strings cannot contain literal newlines,
  # so the record boundaries inserted by fold do not change the document.
  LC_ALL=C fold -b -w 4096 | LC_ALL=C awk '
    function finish_string(value) {
      if (object_depth == 1 &&
          (key == "tag_name" || key == "version" || key == "target" || key == "entrypoint")) {
        print key "\t" value
      } else if (object_depth == asset_object_depth) {
        if (key == "name") {
          asset_name = value
        } else if (key == "digest") {
          asset_digest = value
        }
      }

      expecting_value = 0
      key = ""
    }

    {
      for (i = 1; i <= length($0); i++) {
        char = substr($0, i, 1)

        if (in_string) {
          if (escaped) {
            token = token "\\" char
            escaped = 0
          } else if (char == "\\") {
            escaped = 1
          } else if (char == "\"") {
            in_string = 0
            if (string_is_value) {
              finish_string(token)
            } else {
              pending_key = token
            }
          } else {
            token = token char
          }
          continue
        }

        if (char == "\"") {
          in_string = 1
          token = ""
          escaped = 0
          string_is_value = expecting_value
        } else if (char == ":" && pending_key != "") {
          key = pending_key
          pending_key = ""
          expecting_value = 1
        } else if (char == "{") {
          object_depth++
          if (assets_array_depth != 0 &&
              array_depth == assets_array_depth &&
              asset_object_depth == 0) {
            asset_object_depth = object_depth
            asset_name = ""
            asset_digest = ""
          }
          expecting_value = 0
          key = ""
        } else if (char == "}") {
          if (object_depth == asset_object_depth) {
            if (asset_name != "" && asset_digest != "") {
              print "asset\t" asset_name "\t" asset_digest
            }
            asset_object_depth = 0
            asset_name = ""
            asset_digest = ""
          }
          object_depth--
          expecting_value = 0
          key = ""
          pending_key = ""
        } else if (char == "[") {
          array_depth++
          if (expecting_value && key == "assets" && object_depth == 1) {
            assets_array_depth = array_depth
          }
          expecting_value = 0
          key = ""
        } else if (char == "]") {
          if (array_depth == assets_array_depth) {
            assets_array_depth = 0
          }
          array_depth--
          expecting_value = 0
          key = ""
          pending_key = ""
        } else if (char == ",") {
          expecting_value = 0
          key = ""
          pending_key = ""
        }
      }
    }

    END {
      if (in_string || object_depth != 0 || array_depth != 0) {
        exit 1
      }
    }
  '
}

detect_target() {
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os-$arch" in
    Linux-x86_64)
      printf 'x86_64-unknown-linux-musl\n'
      ;;
    Linux-aarch64 | Linux-arm64)
      die "codEx does not publish aarch64 binaries yet; only x86_64-unknown-linux-musl releases are available"
      ;;
    *)
      die "unsupported platform $os-$arch; codEx publishes Linux x86_64 binaries only"
      ;;
  esac
}

resolve_latest_tag() {
  # api.github.com allows 60 unauthenticated requests per hour per source IP,
  # which a shared or NATed address exhausts without any local mistake; the
  # resulting 403 then blocks the install outright. The releases/latest
  # redirect answers the same question outside the API limit, so follow it
  # first and keep the API only as a fallback, authenticated when the
  # environment carries a token. This mirrors release_metadata.rs, which
  # codex update and codex doctor already use.
  tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
    "https://github.com/${FORK_REPO}/releases/latest" 2>/dev/null |
    sed -n 's#.*/releases/tag/\([^/]*\)$#\1#p' | head -1)"

  if [ -z "$tag" ]; then
    auth_header=""
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      auth_header="Authorization: Bearer ${GITHUB_TOKEN}"
    elif [ -n "${GH_TOKEN:-}" ]; then
      auth_header="Authorization: Bearer ${GH_TOKEN}"
    fi
    if [ -n "$auth_header" ]; then
      tag="$(curl -fsSL -H "$auth_header" \
        "$API_BASE_URL/releases/latest" 2>/dev/null |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    else
      tag="$(curl -fsSL "$API_BASE_URL/releases/latest" 2>/dev/null |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    fi
  fi

  [ -n "$tag" ] ||
    die "failed to resolve the latest codEx release from $API_BASE_URL"
  printf '%s\n' "$tag"
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else
    die "sha256sum, shasum, or openssl is required to verify the codEx download"
  fi
}

acquire_lock() {
  mkdir -p "$STANDALONE_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another codEx install is in progress (lock: $LOCK_DIR); if this is stale, remove it and retry"
  fi
}

cleanup_stale_install_artifacts() {
  # A killed install leaves its staging directory and the temporary selection
  # link behind; neither is ever adopted, so drop them before this install
  # starts. codEx publishes Linux x86_64 only, so the macOS inspection paths
  # upstream carries are not needed here.
  mkdir -p "$RELEASES_DIR" "$STANDALONE_ROOT"

  find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -name '.staging.*' -exec rm -rf {} +
  find "$STANDALONE_ROOT" -mindepth 1 -maxdepth 1 -name '.current.*' -exec rm -f {} +

  if [ -d "$CODEX_INSTALL_DIR" ]; then
    find "$CODEX_INSTALL_DIR" -mindepth 1 -maxdepth 1 -name '.codex.*' -exec rm -f {} +
  fi
}

# Lists the executables of every process this user can see, so a release that
# is still running is never retired. Declines to prune when a Codex or bundled
# helper process cannot be inspected: an incomplete listing proves nothing.
record_standalone_releases_in_use() {
  [ -r /proc/self/mountinfo ] && [ -L /proc/self/exe ] || return 1
  # hidepid can omit other users' processes entirely; do not assume an
  # incomplete process listing proves an older release is unused.
  if grep -E '(^|[ ,])hidepid=[^0, ]' /proc/self/mountinfo >/dev/null; then
    return 1
  fi
  : > "$tmp_dir/in-use" || return 1
  for process in /proc/[0-9]*; do
    if executable="$(readlink "$process/exe" 2>/dev/null)"; then
      printf 'n%s\n' "$executable" >> "$tmp_dir/in-use" || return 1
    elif [ -d "$process" ]; then
      # Even same-user ssh-agent/systemd processes may deny exe inspection.
      # Only an unreadable Codex or bundled helper prevents safe pruning.
      process_name="$(cat "$process/comm" 2>/dev/null)" || {
        [ ! -d "$process" ] && continue
        return 1
      }
      # Linux truncates comm to 15 bytes, including the code-mode host.
      case "$process_name" in
        codex* | rg | bwrap)
          # A zombie has no files left open, even if its parent never reaps it.
          grep -Eq '^State:[[:space:]]*Z' "$process/status" 2>/dev/null && continue
          [ ! -d "$process" ] && continue
          return 1
          ;;
      esac
    fi
  done
}

release_is_unused() {
  path_field="n$1"
  # Appending / also matches a process whose cwd is the release root itself.
  LC_ALL=C RELEASE_PATH="$path_field/" awk 'index($0 "/", ENVIRON["RELEASE_PATH"]) { exit 1 }' "$tmp_dir/in-use"
}

# Run under the install lock, after the new release has been verified. Only
# retire ordinary, manifest-owned packages; never retry a retired tree.
prune_standalone_releases() (
  [ ! -L "$STANDALONE_ROOT" ] && [ ! -L "$RELEASES_DIR" ] || return 1
  releases="$(cd -P "$RELEASES_DIR" && pwd)" || return 1
  # Local process inspection cannot establish whether a network home is in
  # use on another host. df -l excludes remotely mounted filesystems.
  df -lP "$releases" > /dev/null 2> "$tmp_dir/df-error" || return 1
  [ ! -s "$tmp_dir/df-error" ] || return 1
  selected="$(cd -P "$CURRENT_LINK" && pwd)" || return 1
  # A missing or unreadable history only means pruning cannot run; keep the
  # shell's complaint about it off the user's terminal.
  history="$(cat "$STANDALONE_ROOT/selection-history" 2>/dev/null)" || return 1
  previous="$(printf '%s\n' "$history" | sed -n '2p')"
  case "$previous" in
    */* | . | ..) return 1 ;;
  esac
  identity="$(LC_ALL=C stat -c '%d %i %.9Z' "$CURRENT_LINK")" || return 1
  [ "$selected" = "$releases/${selected##*/}" ] &&
    [ "$history" = "$(printf '%s\n%s\n%s' "${selected##*/}" "$previous" "$identity")" ] ||
    return 1
  record_standalone_releases_in_use || return 1
  restore_candidate=""
  # A stopped install must not strand a late-starting release in retirement.
  trap 'if [ -n "$restore_candidate" ] && [ -d "$retired/release" ] &&
    [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
    mv "$retired/release" "$candidate" && rmdir "$retired"
  fi' EXIT
  trap 'exit 1' HUP INT TERM

  for candidate in "$releases"/*; do
    # `|| continue` is the intent in each guard below: a candidate that fails
    # any check is left alone, never half-processed.
    # shellcheck disable=SC2015
    [ -d "$candidate" ] && [ ! -L "$candidate" ] &&
      [ "$candidate" != "$selected" ] && [ "${candidate##*/}" != "$previous" ] || continue
    release_is_unused "$candidate" || continue
    # shellcheck disable=SC2015
    [ -f "$candidate/codex-package.json" ] && [ ! -L "$candidate/codex-package.json" ] || continue
    metadata="$(parse_release_metadata < "$candidate/codex-package.json")" || continue
    version="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "version" {print $2}')"
    target="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "target" {print $2}')"
    entrypoint="$(printf '%s\n' "$metadata" | awk -F '\t' '$1 == "entrypoint" {print $2}')"
    # shellcheck disable=SC2015
    [ "${candidate##*/}" = "$version-$target" ] && [ "$version" != "latest" ] &&
      [ "$entrypoint" = "bin/codex" ] && [ -f "$candidate/bin/codex" ] || continue
    validate_version "$version" >/dev/null 2>&1 || continue
    case "$target" in
      x86_64-unknown-linux-musl) ;;
      *) continue ;;
    esac

    # Reject symlinks (except the installer's own alias), special files and
    # mounts before rm -r. find -xdev alone would not protect nested mounts.
    [ "$(readlink "$candidate/codex" 2>/dev/null)" = "bin/codex" ] || continue
    if ! find "$candidate" -xdev ! -type f ! -type d ! -path "$candidate/codex" -print > "$tmp_dir/unowned"; then
      continue
    fi
    [ ! -s "$tmp_dir/unowned" ] || continue
    # mountinfo escapes spaces, tabs, newlines, and backslashes in paths.
    if ! CODEX_PRUNE_RELEASE="$candidate" LC_ALL=C awk '
      BEGIN { release = ENVIRON["CODEX_PRUNE_RELEASE"] }
      { path = $5; gsub(/\\040/, " ", path); gsub(/\\011/, "\t", path)
        gsub(/\\012/, "\n", path); gsub(/\\134/, "\\", path)
        if (path == release || index(path, release "/") == 1) found = 1 }
      END { exit found ? 1 : 0 }
    ' /proc/self/mountinfo; then
      continue
    fi

    retired="$(mktemp -d "$releases/.retired.XXXXXXXX")" || return 1
    restore_candidate=1
    if mv "$candidate" "$retired/release"; then
      # Block new launches at the original path before the final use check.
      if ! record_standalone_releases_in_use ||
        ! release_is_unused "$candidate" || ! release_is_unused "$retired/release"; then
        [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || return 1
        mv "$retired/release" "$candidate" && rmdir "$retired" || return 1
        restore_candidate=""
        continue
      fi
      # Once proved unused, never restore a possibly partially deleted tree.
      restore_candidate=""
      find "$retired" -xdev -depth -delete || return 1
    else
      restore_candidate=""
      rmdir "$retired"
      return 1
    fi
  done
)

install() {
  require_command curl
  require_command tar
  require_command uname

  target="$(detect_target)"
  version="$(normalize_version "${CODEX_RELEASE:-latest}")"

  step "Resolving codEx release..."
  if [ "$version" = "latest" ]; then
    tag="$(resolve_latest_tag)"
    [ -n "$tag" ] || die "failed to resolve the latest codEx release from $API_BASE_URL"
    version="${tag#rust-v}"
  else
    tag="rust-v$version"
  fi
  step "Installing codEx $version ($target) from $FORK_REPO"

  acquire_lock
  trap cleanup EXIT INT TERM
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-install.XXXXXX")"
  cleanup_stale_install_artifacts

  asset="codex-$target.tar.gz"
  archive_url="$RELEASES_BASE_URL/$tag/$asset"
  checksum_url="$archive_url.sha256"
  archive_path="$tmp_dir/$asset"
  checksum_path="$tmp_dir/$asset.sha256"

  step "Downloading $asset..."
  curl -fL --retry 3 --connect-timeout 10 -o "$archive_path" "$archive_url" ||
    die "failed to download $archive_url"
  curl -fL --retry 3 --connect-timeout 10 -o "$checksum_path" "$checksum_url" ||
    die "failed to download checksum $checksum_url"

  step "Verifying sha256 checksum..."
  actual="$(file_sha256 "$archive_path")"
  expected="$(awk '{print $1}' "$checksum_path")"
  [ -n "$expected" ] || die "checksum file $checksum_path is empty or malformed"
  [ "$actual" = "$expected" ] ||
    die "checksum mismatch for $asset (expected $expected, got $actual); refusing to install"

  release_dir="$RELEASES_DIR/$version-$target"
  staging_dir="$RELEASES_DIR/.staging.$version-$target.$$"

  step "Installing to $release_dir..."
  rm -rf "$staging_dir"
  mkdir -p "$staging_dir" "$RELEASES_DIR"
  tar -xzf "$archive_path" -C "$staging_dir"
  # The release archive is a canonical Codex package: the metadata file that
  # makes the install recognizable, plus bin/, codex-resources/, codex-path/.
  [ -f "$staging_dir/codex-package.json" ] ||
    die "release archive is not a Codex package (codex-package.json is missing)"
  [ -x "$staging_dir/bin/codex" ] || die "release archive does not contain bin/codex"
  [ -f "$staging_dir/codex-resources/bwrap" ] || die "release archive does not contain codex-resources/bwrap"
  # `codex update` and manual invocations use this alias at the package root.
  # CodexPackageLayout and the daemon's package hash both ignore it.
  ln -sfn "bin/codex" "$staging_dir/codex"

  # Atomically replace a previous install of the same version.
  if [ -e "$release_dir" ]; then
    rm -rf "$release_dir"
  fi
  mv "$staging_dir" "$release_dir"

  # Point $STANDALONE_ROOT/current at the new release. Replace the symlink
  # atomically so a concurrent reader never sees a half-updated link.
  mkdir -p "$STANDALONE_ROOT"
  previous_release="$(cd -P "$CURRENT_LINK" 2>/dev/null && pwd)" || previous_release=""
  tmp_link="$STANDALONE_ROOT/.current.$$"
  ln -s "$release_dir" "$tmp_link"
  mv -Tf "$tmp_link" "$CURRENT_LINK" 2>/dev/null ||
    { rm -f "$CURRENT_LINK"; mv "$tmp_link" "$CURRENT_LINK"; }

  # Bind the selection to the link it was made through, so the pruning pass can
  # tell which release is live, which one it replaced, and that the link has
  # not moved since. A history that does not match disables pruning.
  if [ "$previous_release" != "$(cd -P "$release_dir" && pwd)" ]; then
    if (
      history="$STANDALONE_ROOT/selection-history"
      # GNU stat inspects the link itself by default.
      selection_id="$(LC_ALL=C stat -c '%d %i %.9Z' "$CURRENT_LINK")"
      printf '%s\n%s\n%s\n' \
        "${release_dir##*/}" "${previous_release##*/}" "$selection_id" \
        > "$history.tmp.$$"
      mv -f "$history.tmp.$$" "$history"
    ); then
      :
    else
      warn "Could not record installation selection; old releases will not be pruned."
    fi
  fi

  step "Linking codex into $CODEX_INSTALL_DIR..."
  mkdir -p "$CODEX_INSTALL_DIR"
  ln -sfn "$CURRENT_LINK/codex" "$CODEX_INSTALL_DIR/codex"

  bin_path="$CODEX_INSTALL_DIR/codex"
  step "Verifying installation..."
  version_output="$("$bin_path" --version 2>&1)" ||
    die "installed binary at $bin_path failed to run: $version_output"
  printf '%s\n' "$version_output"

  case ":$PATH:" in
    *":$CODEX_INSTALL_DIR:"*) ;;
    *)
      warn "$CODEX_INSTALL_DIR is not on your PATH; add it, for example:"
      # The literal `$PATH` in the format string is text the user should copy
      # into their own shell, not a shell expansion of this script's PATH.
      # shellcheck disable=SC2016
      printf '  export PATH="%s:$PATH"\n' "$CODEX_INSTALL_DIR"
      ;;
  esac

  # The literal backticks name the command the user should run; the format
  # string stays single-quoted so the shell cannot try to expand them.
  # shellcheck disable=SC2016
  printf '\n🎉 codEx %s installed. Run `codex update` to upgrade in the future.\n' "$version"

  # Retire the releases this install superseded. A failure is not fatal: the
  # next install retries, and `codex update` still prunes what it replaces.
  if ! prune_standalone_releases; then
    warn "Could not safely inspect old codEx releases; skipped remaining cleanup."
  fi
}

install
