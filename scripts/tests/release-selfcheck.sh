#!/usr/bin/env bash
# release-selfcheck.sh - offline positive/negative checks for the release gate.
#
# Creates minimal synthetic launcher zips in a mktemp directory and asserts that
# scripts/release/verify-release.sh accepts exactly the shipped contract and
# rejects every deviation:
#   PASS  complete zips: launcher + LICENSE + NOTICE + THIRD_PARTY.md at the root,
#         with the three texts byte-identical to the repository files
#   FAIL  a missing licence text
#   FAIL  a licence text with a different digest (tampered copy)
#   FAIL  an extra file in the archive (both platforms)
#   FAIL  a ROM payload (.cci) in the archive (both platforms)
#   PASS  a Windows zip whose exe embeds the expected release version (the
#         synthetic exe carries the single-file deps.json key
#         "3ds2apple-launcher/<ver>")
#   FAIL  a Windows zip whose exe embeds a different version
#   PASS  a clean win-selftest.sh log: exit code 0, SELF-TEST OK, 32 PASS,
#         0 FAIL, 0 WARN and the expected version line (--win-selftest-log)
#   FAIL  a win-selftest.sh log with a failure, or a missing log file
#   PASS  a release directory named v<ver> with assets matching that version
#   FAIL  a release directory named v<ver> whose exe embeds another version
#   PASS  a release directory with exactly the two canonical assets
#   FAIL  a release directory with a licence text attached as a third asset, or
#         with one platform asset missing
#
# It never needs the network, a ROM or a built launcher, never writes under the
# repository (mktemp only, removed on exit) and never touches out/. The real
# repository files are only read to build the synthetic zips.
#
# Usage:
#   scripts/tests/release-selfcheck.sh
#
# Exit status: 0 when every case behaves as expected, 1 otherwise, 2 on
# missing tooling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="$ROOT/scripts/release/verify-release.sh"

WINDOWS_EXE="3ds2apple-launcher.exe"
MAC_APP="3ds2apple-launcher.app"
LICENSE_TEXTS=(LICENSE NOTICE THIRD_PARTY.md)

CHECKS=0
PASS_CASES=0
FAIL_CASES=0
FAILURES=0

pass_case() {
  CHECKS=$((CHECKS + 1))
  PASS_CASES=$((PASS_CASES + 1))
  printf '  ok   %s\n' "$1"
}

fail_case() {
  CHECKS=$((CHECKS + 1))
  FAIL_CASES=$((FAIL_CASES + 1))
  FAILURES=$((FAILURES + 1))
  printf '  FAIL %s (%s)\n' "$1" "$2" >&2
}

for tool in zip unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required by release-selfcheck.sh" >&2
    exit 2
  fi
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  echo "error: sha256sum or shasum is required by release-selfcheck.sh" >&2
  exit 2
fi
[ -f "$VERIFY" ] || { echo "error: verifier not found: $VERIFY" >&2; exit 2; }
for text in "${LICENSE_TEXTS[@]}"; do
  [ -f "$ROOT/$text" ] || { echo "error: repository licence text missing: $ROOT/$text" >&2; exit 2; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/3ds2apple-release-selfcheck.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CASE_DIR="$TMP/cases"
mkdir -p "$CASE_DIR"

# run_verify_case NAME pass|fail EXPECTED_SUBSTRING --verify-args...
# The verifier must be the only writer of stdout/stderr. EXPECTED_SUBSTRING is
# an extended grep pattern; empty means "the exit code is enough".
run_verify_case() {
  local name="$1" expect="$2" pattern="$3"
  shift 3
  local out rc ok=0 why=""
  set +e
  out="$("$VERIFY" "$@" 2>&1)"
  rc=$?
  set -e
  if [ "$expect" = "pass" ]; then
    if [ "$rc" -eq 0 ] && grep -q "verify-release: OK" <<< "$out"; then ok=1; else why="exit $rc, expected 0 and verify-release: OK"; fi
  else
    if [ "$rc" -eq 1 ] && grep -q "\[FAIL\]" <<< "$out" && ! grep -q "verify-release: OK" <<< "$out"; then
      ok=1
    else
      why="exit $rc, expected 1 with a [FAIL] line"
    fi
  fi
  if [ "$ok" -eq 1 ] && [ -n "$pattern" ] && ! grep -qE -- "$pattern" <<< "$out"; then
    ok=0
    why="missing expected output: $pattern"
  fi
  if [ "$ok" -eq 1 ]; then
    pass_case "$name"
  else
    fail_case "$name" "$why"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

make_windows_zip() {
  local zip="$1" missing="${2:-}" tamper="${3:-}" extra="${4:-}" rom="${5:-}"
  local stage="$CASE_DIR/$(basename "$zip" .zip)-win"
  local args=("$WINDOWS_EXE") text
  rm -rf "$stage"
  mkdir -p "$stage"
  # Mirror the real single-file exe: the uncompressed deps.json carries the build
  # version as the entry project key "3ds2apple-launcher/<ver>".
  printf 'synthetic Windows launcher payload for release-selfcheck\n"3ds2apple-launcher/0.1.0"\n' > "$stage/$WINDOWS_EXE"
  for text in "${LICENSE_TEXTS[@]}"; do
    [ "$text" = "$missing" ] && continue
    cp "$ROOT/$text" "$stage/$text"
    if [ "$text" = "$tamper" ]; then printf '\n[tampered by release-selfcheck]\n' >> "$stage/$text"; fi
    args+=("$text")
  done
  if [ -n "$extra" ]; then printf 'unexpected file\n' > "$stage/$extra"; args+=("$extra"); fi
  if [ -n "$rom" ]; then printf 'not a real ROM\n' > "$stage/$rom"; args+=("$rom"); fi
  ( cd "$stage" && zip -q -j "$zip" "${args[@]}" )
}

make_macos_zip() {
  local zip="$1" missing="${2:-}" tamper="${3:-}" extra="${4:-}" rom="${5:-}"
  local stage="$CASE_DIR/$(basename "$zip" .zip)-mac"
  local app="$stage/$MAC_APP" text
  rm -rf "$stage"
  mkdir -p "$app/Contents/MacOS"
  printf 'synthetic Info.plist for release-selfcheck\n' > "$app/Contents/Info.plist"
  printf 'synthetic executable for release-selfcheck\n' > "$app/Contents/MacOS/3ds2apple-launcher"
  chmod +x "$app/Contents/MacOS/3ds2apple-launcher"
  local args=("$MAC_APP")
  for text in "${LICENSE_TEXTS[@]}"; do
    [ "$text" = "$missing" ] && continue
    cp "$ROOT/$text" "$stage/$text"
    if [ "$text" = "$tamper" ]; then printf '\n[tampered by release-selfcheck]\n' >> "$stage/$text"; fi
    args+=("$text")
  done
  if [ -n "$extra" ]; then printf 'unexpected file\n' > "$stage/$extra"; args+=("$extra"); fi
  if [ -n "$rom" ]; then printf 'not a real ROM\n' > "$stage/$rom"; args+=("$rom"); fi
  ( cd "$stage" && zip -q -r "$zip" "${args[@]}" )
}

# make_win_selftest_log FILE VERSION [PASS_COUNT] [FAIL_COUNT] [WARN_COUNT] [EXIT_CODE]
# Minimal stand-in for the log scripts/release/win-selftest.sh writes: the
# version header line, [PASS]/[FAIL]/[WARN] status lines, the final verdict line
# and the appended "win-selftest: exit code N" evidence line.
make_win_selftest_log() {
  local log="$1" version="$2"
  local pass_count="${3:-32}" fail_count="${4:-0}" warn_count="${5:-0}" exit_code="${6:-0}" i
  {
    printf '3ds2apple launcher self-test \xc2\xb7 3ds2apple-launcher-windows/%s\n' "$version"
    for ((i = 0; i < pass_count; i++)); do printf '[PASS] synthetic check %d\n' "$i"; done
    for ((i = 0; i < fail_count; i++)); do printf '[FAIL] synthetic failure %d\n' "$i"; done
    for ((i = 0; i < warn_count; i++)); do printf '[WARN] synthetic warning %d\n' "$i"; done
    printf '\n'
    if [ "$fail_count" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
      printf 'SELF-TEST OK\n'
    else
      printf 'SELF-TEST FAILED (%s failure(s), %s warning(s))\n' "$fail_count" "$warn_count"
    fi
    printf 'win-selftest: exit code %s\n' "$exit_code"
  } > "$log"
}

echo "[1/5] windows zip: complete archive passes"
W_COMPLETE="$CASE_DIR/windows-complete.zip"
make_windows_zip "$W_COMPLETE"
run_verify_case "windows complete -> PASS" pass "windows zip: entries are exactly" --windows-zip "$W_COMPLETE"

W_MISSING="$CASE_DIR/windows-missing-notice.zip"
make_windows_zip "$W_MISSING" NOTICE
run_verify_case "windows missing NOTICE -> FAIL" fail "missing licence text NOTICE" --windows-zip "$W_MISSING"

W_BAD="$CASE_DIR/windows-bad-digest.zip"
make_windows_zip "$W_BAD" "" THIRD_PARTY.md
run_verify_case "windows altered THIRD_PARTY.md -> FAIL" fail "differs from the repository file" --windows-zip "$W_BAD"

W_EXTRA="$CASE_DIR/windows-extra-file.zip"
make_windows_zip "$W_EXTRA" "" "" EXTRA.txt
run_verify_case "windows extra file -> FAIL" fail "expected exactly 3ds2apple-launcher.exe" --windows-zip "$W_EXTRA"

W_ROM="$CASE_DIR/windows-rom-payload.zip"
make_windows_zip "$W_ROM" "" "" "" game.cci
run_verify_case "windows .cci payload -> FAIL" fail "forbidden payload" --windows-zip "$W_ROM"

echo
echo "[2/5] windows zip: embedded launcher version + native self-test log"
run_verify_case "windows exe embeds the expected version -> PASS" pass "embeds launcher version 0.1.0" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.0
run_verify_case "windows exe version mismatch -> FAIL" fail "does not embed launcher version 0.1.4" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.4

GOOD_LOG="$CASE_DIR/win-selftest-ok.log"
make_win_selftest_log "$GOOD_LOG" 0.1.0
run_verify_case "clean win-selftest log -> PASS" pass "32 PASS / 0 FAIL / 0 WARN" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.0 --win-selftest-log "$GOOD_LOG"

BAD_LOG="$CASE_DIR/win-selftest-fail.log"
make_win_selftest_log "$BAD_LOG" 0.1.0 31 1 0 1
run_verify_case "win-selftest log with a FAIL -> FAIL" fail "does not prove a clean native self-test" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.0 --win-selftest-log "$BAD_LOG"

run_verify_case "missing win-selftest log -> FAIL" fail "win-selftest-log file not found" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.0 --win-selftest-log "$CASE_DIR/does-not-exist.log"

echo
echo "[3/5] macOS zip: complete archive passes"
M_COMPLETE="$CASE_DIR/macos-complete.zip"
make_macos_zip "$M_COMPLETE"
run_verify_case "macOS complete -> PASS" pass "macOS zip: top level is exactly" --macos-zip "$M_COMPLETE"

M_MISSING="$CASE_DIR/macos-missing-license.zip"
make_macos_zip "$M_MISSING" LICENSE
run_verify_case "macOS missing LICENSE -> FAIL" fail "missing licence text LICENSE" --macos-zip "$M_MISSING"

M_BAD="$CASE_DIR/macos-bad-digest.zip"
make_macos_zip "$M_BAD" "" NOTICE
run_verify_case "macOS altered NOTICE -> FAIL" fail "differs from the repository file" --macos-zip "$M_BAD"

M_EXTRA="$CASE_DIR/macos-extra-root.zip"
make_macos_zip "$M_EXTRA" "" "" UNEXPECTED.txt
run_verify_case "macOS extra top-level file -> FAIL" fail "expected exactly 3ds2apple-launcher.app" --macos-zip "$M_EXTRA"

M_ROM="$CASE_DIR/macos-rom-payload.zip"
make_macos_zip "$M_ROM" "" "" "" rom.cci
run_verify_case "macOS .cci payload -> FAIL" fail "forbidden payload" --macos-zip "$M_ROM"

echo
echo "[4/5] both platform zips together"
run_verify_case "windows + macOS complete -> PASS" pass "" --windows-zip "$W_COMPLETE" --macos-zip "$M_COMPLETE"

echo
echo "[5/5] release directory: exactly the two assets"
RD_TWO="$CASE_DIR/release-dir-two-assets"
mkdir -p "$RD_TWO"
cp "$W_COMPLETE" "$RD_TWO/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_TWO/3ds2apple-0.1.0-macos-universal.zip"
run_verify_case "release dir with two assets -> PASS" pass "release dir: exactly two assets" --release-dir "$RD_TWO"

RD_LICENSE="$CASE_DIR/release-dir-license-attachment"
mkdir -p "$RD_LICENSE"
cp "$W_COMPLETE" "$RD_LICENSE/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_LICENSE/3ds2apple-0.1.0-macos-universal.zip"
cp "$ROOT/LICENSE" "$RD_LICENSE/LICENSE"
run_verify_case "release dir with a separate LICENSE -> FAIL" fail "unexpected asset name: LICENSE" --release-dir "$RD_LICENSE"

RD_ONE="$CASE_DIR/release-dir-one-asset"
mkdir -p "$RD_ONE"
cp "$W_COMPLETE" "$RD_ONE/3ds2apple-0.1.0-windows-x64.zip"
run_verify_case "release dir with one asset -> FAIL" fail "expected exactly 2 asset files" --release-dir "$RD_ONE"

RD_VERSIONED="$CASE_DIR/v0.1.0"
mkdir -p "$RD_VERSIONED"
cp "$W_COMPLETE" "$RD_VERSIONED/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_VERSIONED/3ds2apple-0.1.0-macos-universal.zip"
run_verify_case "release dir named v0.1.0 with matching exe -> PASS" pass "embeds launcher version 0.1.0" --release-dir "$RD_VERSIONED"

RD_WRONGVER="$CASE_DIR/v0.9.9"
mkdir -p "$RD_WRONGVER"
cp "$W_COMPLETE" "$RD_WRONGVER/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_WRONGVER/3ds2apple-0.1.0-macos-universal.zip"
run_verify_case "release dir name v0.9.9 vs exe 0.1.0 -> FAIL" fail "does not embed launcher version 0.9.9" --release-dir "$RD_WRONGVER"

echo
echo "release-selfcheck: $CHECKS cases, $PASS_CASES passed, $FAIL_CASES failed"
if [ "$FAILURES" -ne 0 ]; then
  echo "release-selfcheck: FAILED" >&2
  exit 1
fi
echo "release-selfcheck: OK"
