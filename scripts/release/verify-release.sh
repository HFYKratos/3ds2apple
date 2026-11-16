#!/usr/bin/env bash
# verify-release.sh - read-only release gate for the two platform launcher zips.
#
# Release policy (CONTRIBUTING.md#release-policy): a release carries exactly two
# assets, 3ds2apple-<ver>-windows-x64.zip and
# 3ds2apple-<ver>-macos-universal.zip. Each zip carries its platform launcher
# plus the repository licence texts LICENSE, NOTICE and THIRD_PARTY.md at the
# ZIP root, byte-identical to the repository files. The texts ship inside the
# packages and are never separate Release assets. The ROM-free shell template is
# embedded in the launchers, and GitHub shows each asset's SHA-256 digest on the
# Release page.
#
# This script never publishes or modifies anything: archives are listed with
# unzip and licence texts are streamed with "unzip -p" (nothing is extracted to
# disk); the release directory is only read.
#
# Checks (each result is printed as [PASS]/[FAIL]/[SKIP]):
#   windows zip   exactly 3ds2apple-launcher.exe + LICENSE + NOTICE +
#                 THIRD_PARTY.md at the ZIP root, nothing else
#   macOS zip     exactly 3ds2apple-launcher.app + LICENSE + NOTICE +
#                 THIRD_PARTY.md at the top level; the .app keeps
#                 Contents/Info.plist and Contents/MacOS/*
#   both zips     LICENSE/NOTICE/THIRD_PARTY.md are byte-identical to the
#                 repository files (ROOT/<name>, compared by SHA-256)
#   both zips     no ROM (.3ds/.cci/.cia/.cxi/.3dsx/.nsp/.xci/.keys), no .ipa,
#                 no GamePack-*.dylib, no Roms/ entries
#   release dir   exactly the two canonical asset files, same <ver>, no extras
#                 (the licence texts are inside the zips, never separate assets)
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

# Both shipped packages must carry these three repository files at the ZIP root.
LICENSE_TEXTS=(LICENSE NOTICE THIRD_PARTY.md)
# Exact entry sets (no directories, nothing else).
WINDOWS_ENTRIES=(3ds2apple-launcher.exe LICENSE NOTICE THIRD_PARTY.md)
MACOS_TOP_LEVEL=(3ds2apple-launcher.app LICENSE NOTICE THIRD_PARTY.md)

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

Both zips must carry LICENSE, NOTICE and THIRD_PARTY.md at their root, identical
to the repository files. Exit codes: 0 all requested checks passed, 1 a check
failed, 2 usage/tooling error.
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
  stream_hash() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
  stream_hash() { shasum -a 256 | awk '{print $1}'; }
else
  hash_file() { echo unavailable; }
  stream_hash() { echo unavailable; }
fi

require_unzip() {
  command -v unzip >/dev/null 2>&1 || die "unzip is required (Info-ZIP unzip)"
}

zip_entries() { unzip -Z1 "$1"; }

# SHA-256 of one archive entry, streamed from the zip (nothing is written to disk).
zip_text_hash() {
  local zip="$1" entry="$2"
  unzip -p "$zip" "$entry" 2>/dev/null | stream_hash || true
}

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

# The three licence texts must be present at the archive root and byte-identical
# to the repository files ($ROOT/<name>); entries is the already-listed zip.
check_license_texts() {
  local zip="$1" label="$2" entries="$3" text zip_hash repo_hash
  for text in "${LICENSE_TEXTS[@]}"; do
    if ! grep -Fxq "$text" <<< "$entries"; then
      fail "$label: missing licence text $text at the archive root"
      continue
    fi
    zip_hash="$(zip_text_hash "$zip" "$text")"
    repo_hash="$(hash_file "$ROOT/$text")"
    if [ "$zip_hash" = "$repo_hash" ]; then
      pass "$label: $text is byte-identical to the repository file (sha256 $zip_hash)"
    else
      fail "$label: $text sha256 $zip_hash differs from the repository file ($repo_hash)"
    fi
  done
}

check_windows_zip() {
  local zip="$1" entries expected actual
  if [ ! -f "$zip" ]; then
    fail "windows zip: not a file: $zip"
    return
  fi
  entries="$(zip_entries "$zip" 2>/dev/null || true)"
  if [ -z "$entries" ]; then
    fail "windows zip: not a readable zip (or empty): $zip"
    return
  fi
  check_forbidden_payloads "$zip" "windows zip"
  expected="$(printf '%s\n' "${WINDOWS_ENTRIES[@]}" | LC_ALL=C sort)"
  actual="$(printf '%s\n' "$entries" | LC_ALL=C sort)"
  if [ "$actual" = "$expected" ]; then
    pass "windows zip: entries are exactly 3ds2apple-launcher.exe + LICENSE + NOTICE + THIRD_PARTY.md"
  else
    fail "windows zip: expected exactly 3ds2apple-launcher.exe + LICENSE + NOTICE + THIRD_PARTY.md at the ZIP root, found: $(printf '%s' "$actual" | tr '\n' ' ')"
  fi
  check_license_texts "$zip" "windows zip" "$entries"
  pass "windows zip: $(file_bytes "$zip") bytes, sha256 $(hash_file "$zip")"
}

check_macos_zip() {
  local zip="$1" entries roots expected count
  if [ ! -f "$zip" ]; then
    fail "macOS zip: not a file: $zip"
    return
  fi
  entries="$(zip_entries "$zip" 2>/dev/null || true)"
  if [ -z "$entries" ]; then
    fail "macOS zip: not a readable zip (or empty): $zip"
    return
  fi
  check_forbidden_payloads "$zip" "macOS zip"
  roots="$(printf '%s\n' "$entries" | cut -d/ -f1 | LC_ALL=C sort -u)"
  expected="$(printf '%s\n' "${MACOS_TOP_LEVEL[@]}" | LC_ALL=C sort)"
  if [ "$roots" = "$expected" ]; then
    pass "macOS zip: top level is exactly 3ds2apple-launcher.app + LICENSE + NOTICE + THIRD_PARTY.md"
  else
    fail "macOS zip: expected exactly 3ds2apple-launcher.app + LICENSE + NOTICE + THIRD_PARTY.md at the top level, found: $(printf '%s' "$roots" | tr '\n' ' ')"
  fi
  if grep -Fxq "3ds2apple-launcher.app/Contents/Info.plist" <<< "$entries"; then
    pass "macOS zip: the .app has Contents/Info.plist"
  else
    fail "macOS zip: the .app has no Contents/Info.plist"
  fi
  count="$(printf '%s\n' "$entries" | grep -c "^3ds2apple-launcher.app/Contents/MacOS/" || true)"
  if [ "$count" -ge 1 ]; then
    pass "macOS zip: the .app has $count Contents/MacOS/ entries"
  else
    fail "macOS zip: the .app has no Contents/MacOS executable"
  fi
  check_license_texts "$zip" "macOS zip" "$entries"
  pass "macOS zip: $(file_bytes "$zip") bytes, sha256 $(hash_file "$zip")"
}

# release-dir mode: exactly the two canonical assets, same <ver>, nothing else.
# The licence texts travel inside the zips, so a separate LICENSE/NOTICE/
# THIRD_PARTY.md (or SHA256SUMS.txt) in the release directory is an extra asset.
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
  pass "release dir: exactly two assets, version $ver, no extra files (licence texts are inside the zips)"
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
  local release_dir="" windows_zip="" macos_zip="" text
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
  for text in "${LICENSE_TEXTS[@]}"; do
    [ -f "$ROOT/$text" ] || die "repository licence text missing: $ROOT/$text (run from the repository checkout)"
  done
  info "verify-release: read-only check, no artifact is modified; licence texts are compared with $ROOT"
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
