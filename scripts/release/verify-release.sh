#!/usr/bin/env bash
# verify-release.sh - read-only release gate for the two platform launcher zips.
#
# Release policy (CONTRIBUTING.md#release-policy): a release carries exactly two
# assets, 3ds2apple-<ver>-windows-x64.zip and
# 3ds2apple-<ver>-macos-universal.zip. The ROM-free shell template is embedded in
# the launchers, license texts live in the repository, and GitHub shows each
# asset's SHA-256 digest on the Release page.
#
# This script never publishes or modifies anything: archives are listed with
# unzip (nothing is extracted) and the release directory is only read.
#
# Checks:
#   windows zip   one top-level 3ds2apple-launcher.exe and nothing else
#   macOS zip     one top-level 3ds2apple-launcher.app with Contents/Info.plist
#                 and Contents/MacOS/*, and nothing else
#   both zips     no ROM (.3ds/.cci/.cia/.cxi/.3dsx/.nsp/.xci/.keys), no .ipa,
#                 no GamePack-*.dylib, no Roms/ entries
#   release dir   exactly the two canonical asset files, same <ver>, no extras
#   always        prints byte size and SHA-256 of each verified asset
#
# Usage:
#   scripts/release/verify-release.sh --release-dir out/release/v0.1.0
#   scripts/release/verify-release.sh --windows-zip A.zip --macos-zip B.zip
#
# Exit codes: 0 = every requested check passed, 1 = at least one check failed,
#             2 = usage/tooling error (nothing was verified).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Read-only verification of the two platform release assets.

Usage:
  scripts/release/verify-release.sh --release-dir DIR
  scripts/release/verify-release.sh --windows-zip FILE --macos-zip FILE

Options:
  --release-dir DIR   Verify a directory assembled by assemble-release.sh: it must
                      contain exactly the two canonical platform zips.
  --windows-zip FILE  Windows single-file launcher zip to verify.
  --macos-zip FILE    macOS launcher .app zip to verify.
  -h, --help          Show this help and exit.

Exit codes: 0 all requested checks passed, 1 a check failed, 2 usage/tooling error.
EOF
}

info() { echo "[info] $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "[PASS] $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "[FAIL] $*" >&2; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); echo "[SKIP] $*"; }
die() { echo "error: $*" >&2; exit 2; }

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
  hash_file() { echo unavailable; }
fi

require_unzip() {
  command -v unzip >/dev/null 2>&1 || die "unzip is required (Info-ZIP unzip)"
}

zip_entries() { unzip -Z1 "$1"; }

# Forbidden payloads in either asset: ROMs, keys, IPAs and per-game code.
forbidden_entry() {
  case "$1" in
    *.3ds|*.cci|*.cia|*.cxi|*.3dsx|*.nsp|*.xci|*.keys) return 0 ;;
    *.ipa) return 0 ;;
    *GamePack-*.dylib) return 0 ;;
  esac
  case "/$1/" in
    */Roms/*) return 0 ;;
  esac
  return 1
}

check_forbidden_payloads() {
  local zip="$1" label="$2" entry hits=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if forbidden_entry "$entry"; then
      fail "$label: forbidden payload in the archive: $entry"
      hits=$((hits + 1))
    fi
  done < <(zip_entries "$zip" 2>/dev/null || true)
  [ "$hits" -eq 0 ] && pass "$label: no ROM/key/IPA/GamePack payloads"
}

check_windows_zip() {
  local zip="$1" entries count
  if [ ! -f "$zip" ]; then
    fail "windows zip: not a file: $zip"
    return
  fi
  entries="$(zip_entries "$zip" 2>/dev/null || true)"
  if [ -z "$entries" ]; then
    fail "windows zip: not a readable zip (or empty): $zip"
    return
  fi
  count="$(echo "$entries" | grep -c . || true)"
  if [ "$count" -ne 1 ]; then
    fail "windows zip: expected exactly 1 entry (one .exe), found $count: $zip"
    return
  fi
  if [ "$entries" != "3ds2apple-launcher.exe" ]; then
    fail "windows zip: the single entry must be 3ds2apple-launcher.exe: $entries"
    return
  fi
  pass "windows zip: single entry $entries ($(file_bytes "$zip") bytes, sha256 $(hash_file "$zip"))"
  check_forbidden_payloads "$zip" "windows zip"
}

check_macos_zip() {
  local zip="$1" entries roots app count
  if [ ! -f "$zip" ]; then
    fail "macOS zip: not a file: $zip"
    return
  fi
  entries="$(zip_entries "$zip" 2>/dev/null || true)"
  if [ -z "$entries" ]; then
    fail "macOS zip: not a readable zip (or empty): $zip"
    return
  fi
  roots="$(echo "$entries" | cut -d/ -f1 | LC_ALL=C sort -u | grep -c . || true)"
  if [ "$roots" -ne 1 ]; then
    fail "macOS zip: expected one top-level .app, found $roots top-level root(s)"
    return
  fi
  app="$(echo "$entries" | cut -d/ -f1 | LC_ALL=C sort -u | head -n 1)"
  if [ "$app" != "3ds2apple-launcher.app" ]; then
    fail "macOS zip: top-level entry must be 3ds2apple-launcher.app: $app"
    return
  fi
  if ! echo "$entries" | grep -Fxq "3ds2apple-launcher.app/Contents/Info.plist"; then
    fail "macOS zip: the .app has no Contents/Info.plist"
    return
  fi
  count="$(echo "$entries" | grep -c "^3ds2apple-launcher.app/Contents/MacOS/" || true)"
  if [ "$count" -lt 1 ]; then
    fail "macOS zip: the .app has no Contents/MacOS executable"
    return
  fi
  pass "macOS zip: one .app bundle $app ($(file_bytes "$zip") bytes, sha256 $(hash_file "$zip"))"
  check_forbidden_payloads "$zip" "macOS zip"
}

# release-dir mode: exactly the two canonical assets, same <ver>, nothing else.
check_release_dir() {
  local dir="$1" f base w_name="" m_name="" ver="" count=0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    count=$((count + 1))
    base="$(basename "$f")"
    case "$base" in
      *-windows-x64.zip)
        if [ -n "$w_name" ]; then
          fail "release dir: more than one windows-x64.zip asset"
          return
        fi
        w_name="$base"
        ;;
      *-macos-universal.zip)
        if [ -n "$m_name" ]; then
          fail "release dir: more than one macos-universal.zip asset"
          return
        fi
        m_name="$base"
        ;;
      *)
        fail "release dir: unexpected asset name: $base (release policy allows only the two platform zips)"
        return
        ;;
    esac
  done
  if [ "$count" -ne 2 ]; then
    fail "release dir: expected exactly 2 asset files, found $count in $dir"
    return
  fi
  if [ -z "$w_name" ] || [ -z "$m_name" ]; then
    fail "release dir: missing one of the two platform zips ($w_name / $m_name)"
    return
  fi
  ver="$(echo "$w_name" | awk '{sub(/^3ds2apple-/,""); sub(/-windows-x64.zip$/,""); print}')"
  if [ "$m_name" != "3ds2apple-$ver-macos-universal.zip" ]; then
    fail "release dir: windows and macOS assets have different versions ($w_name / $m_name)"
    return
  fi
  pass "release dir: exactly two assets, version $ver, no extra files"
}

find_asset() {
  local dir="$1" suffix="$2" n=0 found="" f
  for f in "$dir"/*"$suffix"; do
    if [ -f "$f" ]; then
      n=$((n + 1))
      found="$f"
    fi
  done
  [ "$n" -eq 1 ] || return 1
  echo "$found"
}

main() {
  local release_dir="" windows_zip="" macos_zip=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --release-dir)
        [ "$#" -ge 2 ] || die "--release-dir requires a value"
        release_dir="$2"
        shift 2
        ;;
      --windows-zip)
        [ "$#" -ge 2 ] || die "--windows-zip requires a value"
        windows_zip="$2"
        shift 2
        ;;
      --macos-zip)
        [ "$#" -ge 2 ] || die "--macos-zip requires a value"
        macos_zip="$2"
        shift 2
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

  if [ -n "$release_dir" ]; then
    if [ -n "$windows_zip$macos_zip" ]; then
      die "use either --release-dir or explicit --windows-zip/--macos-zip, not both"
    fi
    release_dir="$(resolve_path "$release_dir")"
    [ -d "$release_dir" ] || die "release dir not found: $release_dir"
    windows_zip="$(find_asset "$release_dir" "-windows-x64.zip" || true)"
    macos_zip="$(find_asset "$release_dir" "-macos-universal.zip" || true)"
    check_release_dir "$release_dir"
  else
    if [ -z "$windows_zip$macos_zip" ]; then
      usage >&2
      die "pass --release-dir or at least one of --windows-zip/--macos-zip"
    fi
  fi

  require_unzip
  info "verify-release: read-only check, no artifact is modified"
  if [ -n "$release_dir" ]; then
    info "release dir: $release_dir"
  fi

  if [ -n "$windows_zip" ]; then
    windows_zip="$(resolve_path "$windows_zip")"
    check_windows_zip "$windows_zip"
  else
    skip "windows zip: not requested"
  fi
  if [ -n "$macos_zip" ]; then
    macos_zip="$(resolve_path "$macos_zip")"
    check_macos_zip "$macos_zip"
  else
    skip "macOS zip: not requested"
  fi

  echo
  echo "verify-release: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    echo "verify-release: FAILED - do not publish these artifacts" >&2
    exit 1
  fi
  echo "verify-release: OK"
}

main "$@"
