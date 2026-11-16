#!/usr/bin/env bash
# verify-release.sh — read-only release gate for the launcher-first distribution.
#
# Checks the GitHub Release assets described in docs/release.md and
# never publishes or modifies anything: zips/IPAs are unpacked into a private
# mktemp directory that is removed on exit. The builds it inspects are ROM-free:
#
#   Windows zip  one top-level .exe and nothing else
#   macOS zip    one top-level .app bundle (with Contents/Info.plist) and nothing else
#   shell IPA    Payload/<App>.app containing Frameworks/MoltenVK.framework/MoltenVK
#                and the template GameCatalog.json {"schemaVersion":2,"games":[]},
#                with no GamePack-*.dylib / .dylib / Roms/ / ROM files
#   SHA256SUMS   every listed file exists and matches; the release directory has
#                no files that are not listed
#   release dir  no ROM / key / BIOS / GamePack-looking files, no extra IPA
#
# Usage:
#   scripts/release/verify-release.sh --release-dir out/release/v0.1.0
#   scripts/release/verify-release.sh --windows-zip A.zip --macos-zip B.zip --shell-ipa C.ipa
#   scripts/release/verify-release.sh --shell-ipa out/shell/3ds2apple-shell.ipa
#
# --release-dir mode is the release gate: it requires all three artifacts plus
# SHA256SUMS.txt. Explicit-path mode checks only the artifacts you pass, which is
# useful while building (e.g. verify the shell template alone).
#
# Exit codes: 0 = every requested check passed, 1 = at least one check failed,
#             2 = usage/tooling error (nothing was verified).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TMP_DIR=""
DISCOVERED=""

usage() {
  cat <<'EOF'
Read-only verification of the launcher-first release assets.

Usage:
  scripts/release/verify-release.sh --release-dir DIR
  scripts/release/verify-release.sh --windows-zip FILE --macos-zip FILE --shell-ipa FILE
  scripts/release/verify-release.sh --shell-ipa FILE [--sums FILE]

Options:
  --release-dir DIR   Verify a directory assembled by assemble-release.sh: requires
                      exactly one Windows zip, one macOS app zip, one shell IPA and
                      a SHA256SUMS.txt, and rejects extra/unlisted files.
  --windows-zip FILE  Windows single-file launcher zip to verify.
  --macos-zip FILE    macOS launcher .app zip to verify.
  --shell-ipa FILE    ROM-free base shell IPA template to verify.
  --sums FILE         SHA256SUMS.txt to verify (default: release-dir/SHA256SUMS.txt
                      in --release-dir mode; skipped when not given).
  -h, --help          Show this help and exit.

Exit codes: 0 all requested checks passed, 1 a check failed, 2 usage/tooling error.
EOF
}

info() { printf '[info] %s\n' "$*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '[PASS] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*" >&2; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); printf '[SKIP] %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

ensure_tmp() {
  if [ -z "$TMP_DIR" ]; then
    TMP_DIR="$(mktemp -d)"
  fi
}

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
  hash_file() { die "need sha256sum or shasum to compute SHA-256"; }
fi

require_unzip() {
  command -v unzip >/dev/null 2>&1 || die "unzip is required (Info-ZIP unzip)"
}

zip_entries() { unzip -Z1 "$1"; }

# discover_dir_asset DIR PREFIX SUFFIX LABEL
# Sets DISCOVERED; reports a failed check (not a usage error) when the release
# directory does not contain exactly one matching artifact.
discover_dir_asset() {
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
    fail "$label: no file matching $prefix*$suffix in $dir"
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    fail "$label: multiple candidates in $dir (remove stale builds or verify one artifact explicitly)"
    return 1
  fi
  DISCOVERED="$first"
  return 0
}

check_windows_zip() {
  local zip="$1" entries count
  if [ ! -f "$zip" ]; then
    fail "windows zip: not a file: $zip"
    return
  fi
  if ! entries="$(zip_entries "$zip" 2>/dev/null)"; then
    fail "windows zip: not a readable zip: $zip"
    return
  fi
  count="$(printf '%s\n' "$entries" | grep -c . || true)"
  if [ "$count" -ne 1 ]; then
    fail "windows zip: expected exactly 1 entry, found $count: $zip"
    return
  fi
  if ! printf '%s\n' "$entries" | grep -Eq '^[^/]+\.exe$'; then
    fail "windows zip: the single entry is not a top-level .exe: $entries"
    return
  fi
  pass "windows zip: single entry $entries ($(file_bytes "$zip") bytes, sha256 $(hash_file "$zip"))"
}

check_macos_zip() {
  local zip="$1" entries roots app count
  if [ ! -f "$zip" ]; then
    fail "macOS zip: not a file: $zip"
    return
  fi
  if ! entries="$(zip_entries "$zip" 2>/dev/null)"; then
    fail "macOS zip: not a readable zip: $zip"
    return
  fi
  roots="$(printf '%s\n' "$entries" | cut -d/ -f1 | LC_ALL=C sort -u | grep -c . || true)"
  if [ "$roots" -ne 1 ]; then
    fail "macOS zip: expected one top-level .app, found $roots top-level root(s)"
    return
  fi
  app="$(printf '%s\n' "$entries" | cut -d/ -f1 | LC_ALL=C sort -u | head -n 1)"
  if ! printf '%s' "$app" | grep -Eq '^[^/]+\.app$'; then
    fail "macOS zip: top-level entry is not a .app bundle: $app"
    return
  fi
  count="$(printf '%s\n' "$entries" | grep -vc '/$' || true)"
  if [ "$count" -lt 1 ]; then
    fail "macOS zip: .app bundle is empty: $zip"
    return
  fi
  if ! printf '%s\n' "$entries" | grep -Fxq "$app/Contents/Info.plist"; then
    fail "macOS zip: $app has no Contents/Info.plist"
    return
  fi
  pass "macOS zip: one .app bundle $app ($count files, $(file_bytes "$zip") bytes, sha256 $(hash_file "$zip"))"
}

check_shell_ipa() {
  local ipa="$1" entries app catalog expected actual moltenvk_bytes
  local count_roms count_dylib count_gamepacks count_apps
  if [ ! -f "$ipa" ]; then
    fail "shell IPA: not a file: $ipa"
    return
  fi
  if ! entries="$(zip_entries "$ipa" 2>/dev/null)"; then
    fail "shell IPA: not a readable zip: $ipa"
    return
  fi
  if ! printf '%s\n' "$entries" | grep -Eq '^Payload/'; then
    fail "shell IPA: missing top-level Payload/ directory"
    return
  fi
  app="$(printf '%s\n' "$entries" | sed -n 's|^Payload/\([^/]*\.app\)/.*|\1|p' | head -n 1)"
  if [ -z "$app" ]; then
    fail "shell IPA: no Payload/<App>.app directory entry"
    return
  fi
  count_apps="$(printf '%s\n' "$entries" | sed -n 's|^Payload/\([^/]*\.app\)/.*|\1|p' | LC_ALL=C sort -u | grep -c . || true)"
  if [ "$count_apps" -ne 1 ]; then
    fail "shell IPA: expected exactly one Payload/<App>.app bundle, found $count_apps"
    return
  fi
  if ! printf '%s\n' "$entries" | grep -Fxq "Payload/$app/Frameworks/MoltenVK.framework/MoltenVK"; then
    fail "shell IPA: missing Frameworks/MoltenVK.framework/MoltenVK"
    return
  fi
  count_roms="$(printf '%s\n' "$entries" | grep -Ec '(^|/)Roms/' || true)"
  if [ "$count_roms" -ne 0 ]; then
    fail "shell IPA: must not contain Roms/ entries (found $count_roms)"
    return
  fi
  count_gamepacks="$(printf '%s\n' "$entries" | grep -Ec 'GamePack-[^/]*\.dylib$' || true)"
  if [ "$count_gamepacks" -ne 0 ]; then
    fail "shell IPA: must not contain GamePack-*.dylib (found $count_gamepacks); the template is ROM-free"
    return
  fi
  count_dylib="$(printf '%s\n' "$entries" | grep -Ec '\.dylib$' || true)"
  if [ "$count_dylib" -ne 0 ]; then
    fail "shell IPA: must not contain any .dylib (found $count_dylib); GamePacks are injected per user"
    return
  fi
  if printf '%s\n' "$entries" | grep -Eic '\.(3ds|cci|cia|cxi|3dsx|nsp|xci)$' | grep -qv '^0$'; then
    fail "shell IPA: must not contain ROM files"
    return
  fi
  ensure_tmp
  if ! unzip -p "$ipa" "Payload/$app/GameCatalog.json" > "$TMP_DIR/GameCatalog.json" 2>/dev/null; then
    fail "shell IPA: missing Payload/$app/GameCatalog.json"
    return
  fi
  catalog="$(tr -d '[:space:]' < "$TMP_DIR/GameCatalog.json")"
  expected='{"schemaVersion":2,"games":[]}'
  if [ "$catalog" != "$expected" ]; then
    fail "shell IPA: GameCatalog.json is not the empty schema-2 template (got: $catalog)"
    return
  fi
  moltenvk_bytes="$(unzip -p "$ipa" "Payload/$app/Frameworks/MoltenVK.framework/MoltenVK" 2>/dev/null | wc -c | tr -d ' ')"
  if [ "$moltenvk_bytes" -le 0 ]; then
    fail "shell IPA: Frameworks/MoltenVK.framework/MoltenVK is empty"
    return
  fi
  pass "shell IPA: Payload/$app, MoltenVK $moltenvk_bytes bytes, empty schema-2 GameCatalog ($(file_bytes "$ipa") bytes, sha256 $(hash_file "$ipa"))"
}

check_sums() {
  local sums="$1" dir="$2" digest name file actual listed verified f base files_in_dir unlisted
  listed=0
  verified=0
  if [ ! -f "$sums" ]; then
    fail "SHA256SUMS: not a file: $sums"
    return
  fi
  while read -r digest name; do
    case "$digest" in
      ''|\#*) continue ;;
    esac
    if ! printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$'; then
      fail "SHA256SUMS: malformed line (bad SHA-256): $digest $name"
      continue
    fi
    if [ -z "$name" ]; then
      fail "SHA256SUMS: malformed line (no file name): $digest"
      continue
    fi
    case "$name" in
      /*|../*|*/../*)
        fail "SHA256SUMS: unsafe path: $name"
        continue
        ;;
    esac
    if [ -n "$dir" ]; then
      file="$dir/$name"
    else
      file="$name"
    fi
    if [ ! -f "$file" ]; then
      fail "SHA256SUMS: listed file is missing: $name"
      continue
    fi
    listed=$((listed + 1))
    actual="$(hash_file "$file")"
    if [ "$actual" = "$digest" ]; then
      verified=$((verified + 1))
    else
      fail "SHA256SUMS: hash mismatch for $name (expected $digest, got $actual)"
    fi
  done < "$sums"
  if [ "$listed" -eq 0 ]; then
    fail "SHA256SUMS: no entries found in $sums"
    return
  fi
  if [ "$verified" -eq "$listed" ]; then
    pass "SHA256SUMS: $verified listed file(s) verified ($sums)"
  fi
  if [ -n "$dir" ]; then
    ensure_tmp
    awk '{print $2}' "$sums" > "$TMP_DIR/listed.txt"
    files_in_dir=0
    unlisted=0
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      [ "$base" = "SHA256SUMS.txt" ] && continue
      files_in_dir=$((files_in_dir + 1))
      if ! grep -Fxq "$base" "$TMP_DIR/listed.txt"; then
        fail "SHA256SUMS: release file is not listed: $base"
        unlisted=$((unlisted + 1))
      fi
    done
    if [ "$unlisted" -eq 0 ]; then
      pass "SHA256SUMS: covers every file in $dir ($files_in_dir file(s))"
    fi
  fi
}

check_release_hygiene() {
  local dir="$1" f base bad
  bad=0
  if [ ! -d "$dir" ]; then
    fail "release dir: not a directory: $dir"
    return
  fi
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      prod.keys|aes_keys.txt|seeddb.bin|*.3ds|*.cci|*.cia|*.cxi|*.3dsx|*.nsp|*.xci|*.keys|*.sav|*.dsv|*.bin|*.dylib|GamePack-*)
        fail "release dir: must not contain ROM/key/GamePack file: $base"
        bad=$((bad + 1))
        ;;
    esac
  done
  if [ "$bad" -eq 0 ]; then
    pass "release dir: no ROM/key/GamePack-looking files"
  fi
}

main() {
  local release_dir="" windows_zip="" macos_zip="" shell_ipa="" sums_file="" f
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
      --shell-ipa)
        [ "$#" -ge 2 ] || die "--shell-ipa requires a value"
        shell_ipa="$2"
        shift 2
        ;;
      --sums)
        [ "$#" -ge 2 ] || die "--sums requires a value"
        sums_file="$2"
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
    if [ -n "$windows_zip$macos_zip$shell_ipa" ]; then
      die "use either --release-dir or explicit artifact paths, not both"
    fi
    release_dir="$(resolve_path "$release_dir")"
    [ -d "$release_dir" ] || die "release dir not found: $release_dir"
    if discover_dir_asset "$release_dir" "3ds2apple-" "-windows-x64.zip" "release dir windows zip"; then
      windows_zip="$DISCOVERED"
    fi
    if discover_dir_asset "$release_dir" "3ds2apple-" "-macos-universal.zip" "release dir macOS zip"; then
      macos_zip="$DISCOVERED"
    fi
    if discover_dir_asset "$release_dir" "3ds2apple-" "-shell.ipa" "release dir shell IPA"; then
      shell_ipa="$DISCOVERED"
    fi
    [ -n "$sums_file" ] || sums_file="$release_dir/SHA256SUMS.txt"
  else
    if [ -z "$windows_zip$macos_zip$shell_ipa" ]; then
      usage >&2
      die "pass --release-dir or at least one artifact path"
    fi
    if [ -z "$sums_file" ]; then
      skip "SHA256SUMS: not requested (use --sums FILE or --release-dir)"
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
    [ -n "$release_dir" ] || skip "windows zip: not requested"
  fi
  if [ -n "$macos_zip" ]; then
    macos_zip="$(resolve_path "$macos_zip")"
    check_macos_zip "$macos_zip"
  else
    [ -n "$release_dir" ] || skip "macOS zip: not requested"
  fi
  if [ -n "$shell_ipa" ]; then
    shell_ipa="$(resolve_path "$shell_ipa")"
    check_shell_ipa "$shell_ipa"
  else
    [ -n "$release_dir" ] || skip "shell IPA: not requested"
  fi
  if [ -n "$release_dir" ]; then
    check_release_hygiene "$release_dir"
    if [ -n "$shell_ipa" ]; then
      for f in "$release_dir"/*.ipa; do
        [ -e "$f" ] || continue
        if [ "$f" != "$shell_ipa" ]; then
          fail "release dir: extra IPA (per-game IPAs must never be published): $(basename "$f")"
        fi
      done
    fi
  fi
  if [ -n "$sums_file" ]; then
    sums_file="$(resolve_path "$sums_file")"
    check_sums "$sums_file" "$release_dir"
  fi

  printf '\nverify-release: %d passed, %d failed, %d skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  if [ "$FAIL_COUNT" -ne 0 ]; then
    printf 'verify-release: FAILED — do not publish these artifacts\n' >&2
    exit 1
  fi
  printf 'verify-release: OK\n'
}

main "$@"
