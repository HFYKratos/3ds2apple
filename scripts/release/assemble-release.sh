#!/usr/bin/env bash
# assemble-release.sh - collect the two platform launcher packages into an
# auditable GitHub Release directory.
#
# Release policy (CONTRIBUTING.md#release-policy): a release carries exactly two
# assets and nothing else:
#   3ds2apple-<ver>-windows-x64.zip      Windows launcher (self-contained exe +
#                                        LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root)
#   3ds2apple-<ver>-macos-universal.zip  macOS launcher (.app + the same three
#                                        licence texts at the ZIP root)
# The licence texts ship INSIDE both zips and are never collected as separate
# assets (no SHA256SUMS.txt, no standalone LICENSE/NOTICE/THIRD_PARTY.md, no
# shell IPA): the ROM-free shell template is embedded in the launchers and
# GitHub shows each asset's SHA-256 digest on the Release page.
#
# Nothing is published or committed: the script only reads the git-ignored build
# outputs (out/launchers/**) and copies them into out/release/<tag>/ (also
# git-ignored). It is idempotent and non-destructive:
#   - unchanged bytes are a no-op;
#   - an existing file with different bytes is only replaced with --force;
#   - no file is ever deleted, moved or modified, including in out/;
#   - verify-release.sh rejects extra files in the release directory.
#
# Build inputs keep their build names (out/launchers/3ds2apple-windows-single-*.zip
# and out/launchers/3ds2apple-launcher-*-macos-app.zip); only the copies in the
# release directory get the canonical names above.
#
# Usage:
#   scripts/release/assemble-release.sh --version v0.1.0
#   scripts/release/assemble-release.sh --version v0.1.0 --dry-run
#   scripts/release/assemble-release.sh --version v0.1.0 --out-dir /tmp/release
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
DRY_RUN=0
FORCE=0
SKIP_VERIFY=0
DISCOVERED=""

usage() {
  cat <<'EOF'
Assemble the two-asset GitHub Release directory.

Usage:
  scripts/release/assemble-release.sh --version <tag> [options]

Required:
  --version TAG        Release tag (form: v<major>.<minor>.<patch>[-suffix],
                       e.g. v0.1.0); used for the directory and asset names.

Options:
  --out-dir DIR        Release directory (default: out/release/<tag>, git-ignored).
  --windows-zip FILE   Windows launcher zip. Default: unique
                       out/launchers/3ds2apple-windows-single-*.zip.
  --macos-zip FILE     macOS launcher zip. Default: unique
                       out/launchers/3ds2apple-launcher-*-macos-app.zip.
  --dry-run            Validate inputs and print the plan; write nothing.
  --force              Replace an existing release file whose bytes differ.
  --skip-verify        Do not run verify-release.sh after assembling.
  -h, --help           Show this help and exit.

The release directory contains only 3ds2apple-<ver>-windows-x64.zip and
3ds2apple-<ver>-macos-universal.zip. The licence texts ship inside both zips
(never as separate assets), the shell template is embedded in the launchers, and
the release policy is in CONTRIBUTING.md#release-policy.
EOF
}

info() { echo "[assemble] $*"; }
warn() { echo "[assemble][warn] $*" >&2; }
die() { echo "error: $*" >&2; exit 2; }
build_error() { echo "error: $*" >&2; exit 1; }

resolve_path() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$ROOT/$1" ;;
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

# find_unique_dir_asset DIR PREFIX SUFFIX LABEL - sets DISCOVERED.
find_unique_dir_asset() {
  local dir="$1" prefix="$2" suffix="$3" label="$4" count=0 first="" f
  DISCOVERED=""
  for f in "$dir/$prefix"*"$suffix"; do
    if [ -f "$f" ]; then
      count=$((count + 1))
      if [ "$count" -eq 1 ]; then
        first="$f"
      fi
    fi
  done
  if [ "$count" -eq 0 ]; then
    build_error "$label: no file matching $dir/$prefix*$suffix; build it first (see CONTRIBUTING.md#release-policy)"
  fi
  if [ "$count" -gt 1 ]; then
    build_error "$label: multiple candidates in $dir; pass the exact path with --windows-zip/--macos-zip"
  fi
  DISCOVERED="$first"
}

main() {
  local w_src="" w_name="" m_src="" m_name="" release_version=""
  local added=0 unchanged=0 changed=0 total_bytes=0
  local f

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
  case "$VERSION" in
    v*.*.*) ;;
    *) die "invalid release tag: $VERSION (expected v<major>.<minor>.<patch>[-suffix])" ;;
  esac
  case "$VERSION" in
    *[!A-Za-z0-9.v-]*) die "invalid release tag characters: $VERSION" ;;
  esac

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
  [ -n "$OUT_DIR" ] || OUT_DIR="$ROOT/out/release/$VERSION"
  OUT_DIR="$(resolve_path "$OUT_DIR")"

  for f in "$WINDOWS_ZIP" "$MACOS_ZIP"; do
    [ -f "$f" ] || build_error "required build artifact not found: $f"
  done

  # Canonical product-level names; the inputs keep their out/ names.
  release_version="$(echo "$VERSION" | cut -c2-)"
  w_src="$WINDOWS_ZIP"
  w_name="3ds2apple-$release_version-windows-x64.zip"
  m_src="$MACOS_ZIP"
  m_name="3ds2apple-$release_version-macos-universal.zip"

  total_bytes=$(( $(file_bytes "$w_src") + $(file_bytes "$m_src") ))

  if [ "$DRY_RUN" -eq 1 ]; then
    info "DRY-RUN: nothing will be written"
    info "release tag: $VERSION"
    info "release dir: $OUT_DIR"
    echo "[plan] $w_name <- $w_src"
    echo "[plan] $m_name <- $m_src"
    echo "[plan] SHA-256 (paste into release notes if needed)"
    echo "  $(hash_file "$w_src")  $w_name"
    echo "  $(hash_file "$m_src")  $m_name"
    if [ "$SKIP_VERIFY" -eq 0 ]; then
      info "running read-only verify-release.sh against the source artifacts"
      "$SCRIPT_DIR/verify-release.sh" --windows-zip "$w_src" --macos-zip "$m_src" ||
        build_error "verification of the source artifacts failed; fix them before assembling"
    fi
    echo "DRY-RUN OK: 2 files ($total_bytes bytes) would be written to $OUT_DIR"
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

  if [ "$SKIP_VERIFY" -eq 0 ]; then
    info "running verify-release.sh on $OUT_DIR"
    "$SCRIPT_DIR/verify-release.sh" --release-dir "$OUT_DIR" ||
      build_error "assembled release directory failed verification; do not publish it"
  fi

  echo
  echo "assemble-release: OK"
  echo "  tag:        $VERSION"
  echo "  directory:  $OUT_DIR"
  echo "  files:      2 ($added added, $changed replaced, $unchanged unchanged)"
  echo "  size:       $total_bytes bytes"
  echo "  sha256:"
  echo "    $(hash_file "$OUT_DIR/$w_name")  $w_name"
  echo "    $(hash_file "$OUT_DIR/$m_name")  $m_name"
  echo "next: tag v$release_version, then gh release create $VERSION --title \"$release_version\" --notes-file <notes.md> $OUT_DIR/*"
}

main "$@"
