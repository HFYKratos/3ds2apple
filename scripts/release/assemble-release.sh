#!/usr/bin/env bash
# assemble-release.sh — collect the pinned launcher-first artifacts into an
# auditable GitHub Release directory and write a SHA256SUMS.txt that covers every
# file shipped with the release (binaries *and* licence/notice texts).
#
# Nothing is published or committed. The script only reads the git-ignored build
# outputs (out/launchers/**, out/shell/**) and copies them into
# out/release/<tag>/ (also git-ignored). It is idempotent and non-destructive:
#
#   - re-running with unchanged inputs is a no-op for existing files and rewrites
#     the same deterministic SHA256SUMS.txt;
#   - an existing file with different bytes is only replaced with --force;
#   - no file is ever deleted, moved or modified, including in out/;
#   - the release directory must stay clean: verify-release.sh rejects extra files.
#
# Asset set (see docs/release.md; canonical product-level asset names):
#   3ds2apple-<ver>-windows-x64.zip         Windows single-file launcher
#   3ds2apple-<ver>-macos-universal.zip     macOS launcher (one .app)
#   3ds2apple-<ver>-shell.ipa               ROM-free base shell IPA template
#   SHA256SUMS.txt                          SHA-256 of every file in the directory
#   LICENSE, NOTICE, THIRD_PARTY.md         project + bundled third-party notices
#
# Inputs keep their build names (out/launchers/3ds2apple-windows-single-*.zip,
# out/launchers/3ds2apple-launcher-*-macos-app.zip, out/shell/3ds2apple-shell.ipa);
# only the copies in the release directory get the canonical names above.
#
# Usage:
#   scripts/release/assemble-release.sh --version v0.1.0
#   scripts/release/assemble-release.sh --version v0.1.0 --dry-run
#   scripts/release/assemble-release.sh --version v0.1.0 \
#       --out-dir /tmp/release --windows-zip out/launchers/foo.zip
#
# Exit codes: 0 = release directory ready, 1 = build/verification error,
#             2 = usage/tooling error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION=""
OUT_DIR=""
WINDOWS_ZIP=""
MACOS_ZIP=""
SHELL_IPA=""
DRY_RUN=0
FORCE=0
SKIP_VERIFY=0
DISCOVERED=""

usage() {
  cat <<'EOF'
Assemble the launcher-first GitHub Release directory.

Usage:
  scripts/release/assemble-release.sh --version <tag> [options]

Required:
  --version TAG        Release tag used for the directory name and release notes
                       (form: v<major>.<minor>.<patch>[-suffix], e.g. v0.1.0).

Options:
  --out-dir DIR        Release directory (default: out/release/<tag>, git-ignored).
  --windows-zip FILE   Windows launcher zip. Default: unique
                       out/launchers/3ds2apple-windows-single-*.zip.
  --macos-zip FILE     macOS launcher zip. Default: unique
                       out/launchers/3ds2apple-launcher-*-macos-app.zip.
  --shell-ipa FILE     ROM-free shell template IPA. Default:
                       out/shell/3ds2apple-shell.ipa (its sibling
                       out/shell/manifest.json is cross-checked).
  --dry-run            Validate inputs and print the plan; write nothing. Runs
                       verify-release.sh against the source artifacts.
  --force              Replace an existing release file whose bytes differ.
  --skip-verify        Do not run verify-release.sh after assembling (not
                       recommended for a real release).
  -h, --help           Show this help and exit.

The artifacts are never modified. Licence/notice files (LICENSE, NOTICE,
THIRD_PARTY.md) are copied into the directory so they can be attached to the
GitHub Release next to the binaries.
EOF
}

info() { printf '[assemble] %s\n' "$*"; }
warn() { printf '[assemble][warn] %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }
build_error() { printf 'error: %s\n' "$*" >&2; exit 1; }

resolve_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s' "$ROOT/$1" ;;
  esac
}

file_bytes() { wc -c < "$1" | tr -d ' '; }

if command -v sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "need sha256sum or shasum to compute SHA-256"
fi

# find_unique_dir_asset DIR PREFIX SUFFIX LABEL — sets DISCOVERED.
find_unique_dir_asset() {
  local dir="$1" prefix="$2" suffix="$3" label="$4" count=0 first="" f
  DISCOVERED=""
  shopt -s nullglob
  for f in "$dir/$prefix"*"$suffix"; do
    if [ -f "$f" ]; then
      count=$((count + 1))
      if [ "$count" -eq 1 ]; then
        first="$f"
      fi
    fi
  done
  shopt -u nullglob
  if [ "$count" -eq 0 ]; then
    build_error "$label: no file matching $dir/$prefix*$suffix; build it first (see docs/release.md)"
  fi
  if [ "$count" -gt 1 ]; then
    build_error "$label: multiple candidates in $dir; pass the exact path with --windows-zip/--macos-zip/--shell-ipa"
  fi
  DISCOVERED="$first"
}

read_manifest_field() {
  local manifest="$1" field="$2"
  sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*[\"]\{0,1\}\([^\",}]*\)[\"]\{0,1\}.*/\1/p" "$manifest" | head -n 1
}

main() {
  local w_src="" w_name="" m_src="" m_name="" shell_src="" shell_name=""
  local shell_manifest shell_version shell_build manifest_sha manifest_bytes
  local added=0 unchanged=0 changed=0 total_bytes=0 sums_tmp sums_line
  local f name

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        [ "$#" -ge 2 ] || die "--version requires a value"
        VERSION="$2"
        shift 2
        ;;
      --out-dir)
        [ "$#" -ge 2 ] || die "--out-dir requires a value"
        OUT_DIR="$2"
        shift 2
        ;;
      --windows-zip)
        [ "$#" -ge 2 ] || die "--windows-zip requires a value"
        WINDOWS_ZIP="$2"
        shift 2
        ;;
      --macos-zip)
        [ "$#" -ge 2 ] || die "--macos-zip requires a value"
        MACOS_ZIP="$2"
        shift 2
        ;;
      --shell-ipa)
        [ "$#" -ge 2 ] || die "--shell-ipa requires a value"
        SHELL_IPA="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --skip-verify)
        SKIP_VERIFY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option: $1 (try --help)"
        ;;
      *)
        die "unexpected argument: $1 (try --help)"
        ;;
    esac
  done

  [ -n "$VERSION" ] || die "--version is required (e.g. v0.1.0)"
  if ! printf '%s' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    die "invalid release tag: $VERSION (expected v<major>.<minor>.<patch>[-suffix])"
  fi

  if [ -z "$WINDOWS_ZIP" ]; then
    find_unique_dir_asset "$ROOT/out/launchers" "3ds2apple-windows-single-" ".zip" "Windows launcher zip"
    WINDOWS_ZIP="$DISCOVERED"
  else
    WINDOWS_ZIP="$(resolve_path "$WINDOWS_ZIP")"
  fi
  if [ -z "$MACOS_ZIP" ]; then
    find_unique_dir_asset "$ROOT/out/launchers" "3ds2apple-launcher-" "-macos-app.zip" "macOS launcher zip"
    MACOS_ZIP="$DISCOVERED"
  else
    MACOS_ZIP="$(resolve_path "$MACOS_ZIP")"
  fi
  if [ -z "$SHELL_IPA" ]; then
    SHELL_IPA="$ROOT/out/shell/3ds2apple-shell.ipa"
  else
    SHELL_IPA="$(resolve_path "$SHELL_IPA")"
  fi
  [ -n "$OUT_DIR" ] || OUT_DIR="$ROOT/out/release/$VERSION"
  OUT_DIR="$(resolve_path "$OUT_DIR")"

  for f in "$WINDOWS_ZIP" "$MACOS_ZIP" "$SHELL_IPA"; do
    [ -f "$f" ] || build_error "required build artifact not found: $f"
  done
  for f in "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY.md"; do
    [ -f "$f" ] || build_error "required notice file not found: $f"
  done

  # Canonical product-level names: build artifacts keep their out/ names, only
  # the release copies are renamed to 3ds2apple-<ver>-{windows-x64,macos-universal}.zip
  # and 3ds2apple-<ver>-shell.ipa.
  local release_version="${VERSION#v}"
  w_src="$WINDOWS_ZIP"
  w_name="3ds2apple-$release_version-windows-x64.zip"
  m_src="$MACOS_ZIP"
  m_name="3ds2apple-$release_version-macos-universal.zip"
  shell_src="$SHELL_IPA"
  shell_name="3ds2apple-$release_version-shell.ipa"

  # Shell template IPA: cross-check the launcher manifest (version/build/sha/bytes).
  shell_manifest="$(dirname "$SHELL_IPA")/manifest.json"
  if [ -f "$shell_manifest" ]; then
    shell_version="$(read_manifest_field "$shell_manifest" version)"
    shell_build="$(read_manifest_field "$shell_manifest" build)"
    manifest_sha="$(read_manifest_field "$shell_manifest" sha256)"
    manifest_bytes="$(read_manifest_field "$shell_manifest" bytes)"
    [ -n "$shell_version" ] || build_error "shell manifest has no version: $shell_manifest"
    [ -n "$shell_build" ] || build_error "shell manifest has no build: $shell_manifest"
    if [ "$shell_version" != "$release_version" ]; then
      build_error "shell manifest version $shell_version does not match release $release_version ($shell_manifest); rebuild the shell template for this release"
    fi
    if ! printf '%s' "$shell_version$shell_build" | grep -Eq '^[0-9A-Za-z._-]+$'; then
      build_error "shell manifest version/build contains unexpected characters: $shell_version / $shell_build"
    fi
    if [ -n "$manifest_sha" ] && [ "$manifest_sha" != "$(hash_file "$SHELL_IPA")" ]; then
      build_error "shell IPA does not match its manifest sha256 ($shell_manifest); rebuild the template"
    fi
    if [ -n "$manifest_bytes" ] && [ "$manifest_bytes" != "$(file_bytes "$SHELL_IPA")" ]; then
      build_error "shell IPA does not match its manifest bytes ($shell_manifest); rebuild the template"
    fi
  else
    warn "$shell_manifest not found; cannot cross-check the shell template pin"
  fi

  total_bytes=$(( $(file_bytes "$w_src") + $(file_bytes "$m_src") + $(file_bytes "$shell_src") ))
  for f in "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY.md"; do
    total_bytes=$((total_bytes + $(file_bytes "$f")))
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    info "DRY-RUN: nothing will be written"
    info "release tag: $VERSION"
    info "release dir: $OUT_DIR"
    printf '[plan] %-44s <- %s\n' "$w_name" "$w_src"
    printf '[plan] %-44s <- %s\n' "$m_name" "$m_src"
    printf '[plan] %-44s <- %s\n' "$shell_name" "$shell_src"
    for f in "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY.md"; do
      printf '[plan] %-44s <- %s\n' "$(basename "$f")" "$f"
    done
    printf '[plan] SHA256SUMS.txt over the %d files above\n' 6
    if [ "$SKIP_VERIFY" -eq 0 ]; then
      info "running read-only verify-release.sh against the source artifacts"
      "$SCRIPT_DIR/verify-release.sh" \
        --windows-zip "$w_src" \
        --macos-zip "$m_src" \
        --shell-ipa "$shell_src" \
        || build_error "verification of the source artifacts failed; fix them before assembling"
    fi
    printf 'DRY-RUN OK: 6 files (%d bytes) would be written to %s\n' "$total_bytes" "$OUT_DIR"
    exit 0
  fi

  if [ -e "$OUT_DIR" ] && [ ! -d "$OUT_DIR" ]; then
    build_error "release path exists and is not a directory: $OUT_DIR"
  fi
  mkdir -p "$OUT_DIR"

  sync_asset() {
    local src="$1" dst_name="$2"
    local dst="$OUT_DIR/$dst_name"
    if [ -e "$dst" ]; then
      if [ ! -f "$dst" ]; then
        build_error "refusing to replace non-file: $dst"
      fi
      if [ "$(hash_file "$src")" = "$(hash_file "$dst")" ]; then
        info "unchanged $dst_name"
        unchanged=$((unchanged + 1))
        return
      fi
      if [ "$FORCE" -ne 1 ]; then
        build_error "refusing to overwrite $dst with different bytes (use --force)"
      fi
      cp -f "$src" "$dst"
      info "replaced $dst_name (--force)"
      changed=$((changed + 1))
      return
    fi
    cp "$src" "$dst"
    info "added $dst_name"
    added=$((added + 1))
  }

  sync_asset "$w_src" "$w_name"
  sync_asset "$m_src" "$m_name"
  sync_asset "$shell_src" "$shell_name"
  sync_asset "$ROOT/LICENSE" "LICENSE"
  sync_asset "$ROOT/NOTICE" "NOTICE"
  sync_asset "$ROOT/THIRD_PARTY.md" "THIRD_PARTY.md"

  # Deterministic SHA256SUMS.txt over exactly the managed files, sorted by name.
  sums_tmp="$OUT_DIR/.SHA256SUMS.txt.tmp"
  : > "$sums_tmp"
  for name in "$w_name" "$m_name" "$shell_name" "LICENSE" "NOTICE" "THIRD_PARTY.md"; do
    sums_line="$(hash_file "$OUT_DIR/$name")  $name"
    printf '%s\n' "$sums_line" >> "$sums_tmp"
  done
  LC_ALL=C sort "$sums_tmp" > "$OUT_DIR/SHA256SUMS.txt"
  rm -f "$sums_tmp"
  info "wrote $OUT_DIR/SHA256SUMS.txt"

  if [ "$SKIP_VERIFY" -eq 0 ]; then
    info "running verify-release.sh on $OUT_DIR"
    "$SCRIPT_DIR/verify-release.sh" --release-dir "$OUT_DIR" \
      || build_error "assembled release directory failed verification; do not publish it"
  fi

  printf '\nassemble-release: OK\n'
  printf '  tag:        %s\n' "$VERSION"
  printf '  directory:  %s\n' "$OUT_DIR"
  printf '  files:      6 (%d added, %d replaced, %d unchanged)\n' "$added" "$changed" "$unchanged"
  printf '  size:       %d bytes\n' "$total_bytes"
  printf '  checksums:  %s\n' "$OUT_DIR/SHA256SUMS.txt"
  printf 'next: gh release create %s [--prerelease] --title "<title>" --notes-file <notes.md> %s/*\n' "$VERSION" "$OUT_DIR"
}

main "$@"
