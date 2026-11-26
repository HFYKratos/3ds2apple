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
# unzip, licence texts and the Windows exe are streamed with "unzip -p" (nothing
# is extracted to disk); the release directory and the optional self-test log are
# only read.
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
#   windows zip   the exe embeds the expected release version: the .NET single-file
#                 bundle stores deps.json as plain UTF-8 and its entry project key
#                 is "3ds2apple-launcher/<ver>"; the expected version comes from
#                 --expect-package-version, the v<ver> release directory name or
#                 the canonical zip file name (see check_windows_exe_version)
#   optional      --win-selftest-log FILE: the log written by
#                 scripts/release/win-selftest.sh must show exit code 0,
#                 SELF-TEST OK, 33 PASS, 0 FAIL, 0 WARN and the expected
#                 3ds2apple-launcher-windows/<ver> line (+1 PASS)
#   always        prints byte size and SHA-256 of each verified asset, and the
#                 uncompressed byte size of the Windows exe
#
# Usage:
#   scripts/release/verify-release.sh --release-dir out/release/v0.1.0
#   scripts/release/verify-release.sh --release-dir out/release/v0.1.0 \
#     --win-selftest-log out/release/win-selftest-0.1.0.log
#   scripts/release/verify-release.sh --windows-zip A.zip --macos-zip B.zip \
#     --expect-package-version 0.1.0
#
# Exit codes: 0 = every requested check passed, 1 = at least one check failed,
#             2 = usage/tooling error (nothing was verified).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Both shipped packages must carry these three repository files at the ZIP root.
LICENSE_TEXTS=(LICENSE NOTICE THIRD_PARTY.md)
# Exact entry sets (no directories, nothing else).
WINDOWS_EXE="3ds2apple-launcher.exe"
WINDOWS_ENTRIES=("$WINDOWS_EXE" LICENSE NOTICE THIRD_PARTY.md)
MACOS_TOP_LEVEL=(3ds2apple-launcher.app LICENSE NOTICE THIRD_PARTY.md)

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Read-only verification of the two platform release assets.

Usage:
  scripts/release/verify-release.sh --release-dir DIR [--win-selftest-log FILE]
  scripts/release/verify-release.sh --windows-zip FILE --macos-zip FILE \
    [--expect-package-version VER] [--win-selftest-log FILE]

Options:
  --release-dir DIR   Verify a directory assembled by assemble-release.sh: it must
                      contain exactly the two canonical platform zips. A directory
                      named v<ver> (out/release/v<ver>) also supplies the expected
                      release version for the Windows exe cross-check.
  --windows-zip FILE  Windows single-file launcher zip to verify.
  --macos-zip FILE    macOS launcher .app zip to verify.
  --expect-package-version VER
                      Expected release version embedded in the Windows exe
                      (overrides the v<ver> release directory name and the
                      canonical zip file name).
  --win-selftest-log FILE
                      Log produced by scripts/release/win-selftest.sh on the
                      Windows host; adds one PASS when it proves exit code 0,
                      SELF-TEST OK, 33 PASS, 0 FAIL, 0 WARN and the expected
                      launcher version line.
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

# Uncompressed byte size of one archive entry, read from the zip central directory.
zip_entry_bytes() {
  local zip="$1" entry="$2"
  unzip -l "$zip" "$entry" 2>/dev/null | awk -v name="$entry" '$4 == name { print $1; exit }' || true
}

# The Windows exe embeds the release version. Feasibility experiment on the
# shipped 0.1.4 exe (163,875,695 B, 2026-11-20):
#   - the exe is a .NET self-contained single-file bundle (PublishSingleFile +
#     EnableCompressionInSingleFile), so its assemblies are compressed and the
#     runtime product string "3ds2apple-launcher-windows/<ver>"
#     (LauncherInfo.VersionLine) is NOT present as contiguous bytes: strings -a
#     and strings -el find no "3ds2apple-launcher-windows/" at all, and the
#     version line is interpolated at run time from assembly metadata;
#   - the bundle keeps deps.json as PLAIN UTF-8 (the single-file host reads it
#     without extraction): the exe contains the JSON project key
#     "3ds2apple-launcher/<ver>" (in the targets and libraries sections, at
#     ~163.8 MB of the 157,292,331 B zip / 163,875,695 B exe);
#   - a UTF-16LE search therefore matches nothing useful while a streaming UTF-8
#     grep does. This is the reliable, encoding-safe check: the literal deps.json
#     project key is the build's Version property, i.e. exactly the release
#     version. Everything is streamed from the zip; nothing is extracted.
check_windows_exe_version() {
  local zip="$1" expected="$2" exe_bytes found
  exe_bytes="$(zip_entry_bytes "$zip" "$WINDOWS_EXE")"
  if [ -z "$exe_bytes" ]; then
    exe_bytes="unknown"
  fi
  if [ -z "$expected" ]; then
    skip "windows zip: launcher exe version not cross-checked (no expected release version; pass --expect-package-version or use a v<ver> release dir)"
    info "windows zip: 3ds2apple-launcher.exe is $exe_bytes bytes uncompressed"
    return
  fi
  found="$(unzip -p "$zip" "$WINDOWS_EXE" 2>/dev/null | LC_ALL=C grep -a -o '"3ds2apple-launcher/[^"]*"' | LC_ALL=C sort -u || true)"
  if printf '%s\n' "$found" | LC_ALL=C grep -Fxq -e "\"3ds2apple-launcher/$expected\""; then
    pass "windows zip: launcher exe embeds launcher version $expected (deps.json, $exe_bytes bytes uncompressed)"
  else
    fail "windows zip: launcher exe does not embed launcher version $expected (found: ${found:-nothing})"
  fi
}

# The optional --win-selftest-log folds the native Windows acceptance run into
# the release gate as exactly one PASS. The file is produced by
# scripts/release/win-selftest.sh: it holds the exe's stdout+stderr (decoded from
# the Windows console code page to UTF-8, CR stripped) followed by
# "win-selftest: exit code <n>". A missing file or any failed content check is a
# FAIL, never a skip: a release must not claim the Windows self-test passed.
check_win_selftest_log() {
  local log="$1" expected="$2" problems="" pass_lines fail_lines warn_lines version_line
  if [ ! -f "$log" ]; then
    fail "windows zip: --win-selftest-log file not found: $log"
    return
  fi
  pass_lines="$(tr -d '\r' < "$log" 2>/dev/null | LC_ALL=C grep -a -c '^\[PASS\]' || true)"
  fail_lines="$(tr -d '\r' < "$log" 2>/dev/null | LC_ALL=C grep -a -c '^\[FAIL\]' || true)"
  warn_lines="$(tr -d '\r' < "$log" 2>/dev/null | LC_ALL=C grep -a -c '^\[WARN\]' || true)"
  if [ "$pass_lines" -ne 33 ]; then
    problems="$problems 33 PASS lines expected, found $pass_lines;"
  fi
  if [ "$fail_lines" -ne 0 ]; then
    problems="$problems $fail_lines FAIL lines;"
  fi
  if [ "$warn_lines" -ne 0 ]; then
    problems="$problems $warn_lines WARN lines;"
  fi
  if ! tr -d '\r' < "$log" 2>/dev/null | LC_ALL=C grep -a -Fxq 'SELF-TEST OK'; then
    problems="$problems no exact SELF-TEST OK final line;"
  fi
  if ! tr -d '\r' < "$log" 2>/dev/null | LC_ALL=C grep -a -Fxq 'win-selftest: exit code 0'; then
    problems="$problems no 'win-selftest: exit code 0' evidence line;"
  fi
  version_line="$(tr -d '\r' < "$log" 2>/dev/null | LC_ALL=C grep -a -E '^3ds2apple launcher self-test ' | head -n 1 || true)"
  if [ -n "$expected" ]; then
    case "$version_line" in
      *"3ds2apple-launcher-windows/$expected") ;;
      *) problems="$problems version line does not end with 3ds2apple-launcher-windows/$expected;" ;;
    esac
  else
    case "$version_line" in
      *"3ds2apple-launcher-windows/"?*) ;;
      *) problems="$problems no 3ds2apple-launcher-windows/<ver> version line;" ;;
    esac
  fi
  if [ -z "$problems" ]; then
    if [ -n "$expected" ]; then
      pass "windows zip: --win-selftest-log: 33 PASS / 0 FAIL / 0 WARN, SELF-TEST OK, exit code 0, 3ds2apple-launcher-windows/$expected ($log)"
    else
      pass "windows zip: --win-selftest-log: 33 PASS / 0 FAIL / 0 WARN, SELF-TEST OK, exit code 0 ($log)"
    fi
  else
    fail "windows zip: --win-selftest-log does not prove a clean native self-test:$problems ($log)"
  fi
}

check_windows_zip() {
  local zip="$1" expected_version="$2" entries expected actual
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
  check_windows_exe_version "$zip" "$expected_version"
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
  local expect_package_version="" win_selftest_log=""
  local expected_version="" expected_version_source="" base candidate
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
      --expect-package-version)
        [ "$#" -ge 2 ] || die "--expect-package-version requires a value"
        expect_package_version="$2"
        shift 2
        ;;
      --win-selftest-log)
        [ "$#" -ge 2 ] || die "--win-selftest-log requires a value"
        win_selftest_log="$2"
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

  case "$expect_package_version" in
    "") ;;
    *[!A-Za-z0-9.+-]*) die "invalid --expect-package-version: $expect_package_version" ;;
  esac

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

  # Expected release version for the Windows exe / --win-selftest-log checks.
  # Precedence: --expect-package-version, the v<ver> release directory name (e.g.
  # out/release/v0.1.4 -> 0.1.4), the canonical Windows zip file name. When none
  # applies the exe version check is reported as [SKIP] instead of guessing.
  if [ -n "$expect_package_version" ]; then
    expected_version="$expect_package_version"
    expected_version_source="--expect-package-version"
  elif [ -n "$release_dir" ]; then
    base="$(basename "$release_dir")"
    if [[ "$base" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.]+)?$ ]]; then
      expected_version="${base#v}"
      expected_version_source="release dir name $base"
    fi
  fi
  if [ -z "$expected_version" ] && [ -n "$windows_zip" ]; then
    base="$(basename "$windows_zip")"
    case "$base" in
      3ds2apple-*-windows-x64.zip)
        candidate="${base#3ds2apple-}"
        candidate="${candidate%-windows-x64.zip}"
        if [ -n "$candidate" ]; then
          expected_version="$candidate"
          expected_version_source="canonical Windows zip file name"
        fi
        ;;
    esac
  fi
  if [ -z "$release_dir" ]; then
    if [ -n "$win_selftest_log" ] && [ -z "$windows_zip" ]; then
      die "--win-selftest-log requires the Windows zip (use --windows-zip or --release-dir)"
    fi
    if [ -n "$expect_package_version" ] && [ -z "$windows_zip" ]; then
      die "--expect-package-version requires the Windows zip (use --windows-zip or --release-dir)"
    fi
  fi
  if [ -n "$win_selftest_log" ]; then
    win_selftest_log="$(resolve_path "$win_selftest_log")"
  fi

  require_unzip
  for text in "${LICENSE_TEXTS[@]}"; do
    [ -f "$ROOT/$text" ] || die "repository licence text missing: $ROOT/$text (run from the repository checkout)"
  done
  info "verify-release: read-only check, no artifact is modified; licence texts are compared with $ROOT"
  if [ -n "$release_dir" ]; then
    info "release dir: $release_dir"
  fi
  if [ -n "$expected_version" ]; then
    info "expected release version: $expected_version (from $expected_version_source)"
  fi

  if [ -n "$windows_zip" ]; then
    windows_zip="$(resolve_path "$windows_zip")"
    check_windows_zip "$windows_zip" "$expected_version"
  else
    skip "windows zip: not requested"
  fi
  if [ -n "$win_selftest_log" ]; then
    check_win_selftest_log "$win_selftest_log" "$expected_version"
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
