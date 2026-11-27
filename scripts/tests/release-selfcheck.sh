#!/usr/bin/env bash
# release-selfcheck.sh - offline positive/negative checks for the release gate.
#
# Creates minimal synthetic launcher zips and a synthetic Linux launcher tar.gz in
# a mktemp directory and asserts that scripts/release/verify-release.sh and
# scripts/release/assemble-release.sh accept exactly the shipped three-platform
# contract and reject every deviation:
#   PASS  complete Windows/macOS zips: launcher + LICENSE + NOTICE +
#         THIRD_PARTY.md at the root, with the three texts byte-identical to the
#         repository files
#   FAIL  a missing licence text, a licence text with a different digest, an
#         extra file in the archive and a ROM payload (.cci) in either zip
#   PASS  a Windows zip whose exe embeds the expected release version (the
#         synthetic exe carries the single-file deps.json key
#         "3ds2apple-launcher/<ver>")
#   FAIL  a Windows zip whose exe embeds a different version
#   PASS  a clean win-selftest.sh log: exit code 0, SELF-TEST OK, 33 PASS,
#         0 FAIL, 0 WARN and the expected version line (--win-selftest-log)
#   FAIL  a win-selftest.sh log with a failure, or a missing log file
#   PASS  a complete Linux tar.gz: single top-level launcher directory, every
#         required payload/local-AOT file, repository-identical licence texts
#         both at the folder root and under licenses/, a shell manifest that
#         matches the shell template IPA's bytes and sha256, and
#         PINS-local-aot.json whose recompiler sha256 matches Bin/3dsrecomp and
#         whose llvm field carries the pinned LLVM version
#   FAIL  Linux tar deviations: missing/tampered licence, missing launcher,
#         missing shell manifest, shell manifest sha256/bytes mismatch, missing
#         PINS-local-aot.json, PINS recompiler sha mismatch, an extra top-level
#         directory, an illegal top-level subdirectory, a ROM payload, a
#         non-whitelisted second .ipa, a manifest version different from the
#         expected release version, and a file that is not a readable gzip tar
#   PASS  a release directory with exactly the three canonical platform packages
#   FAIL  a release directory with an extra asset (separate licence text or
#         SHA256SUMS.txt), a missing platform package or mixed versions
#   PASS  assemble-release.sh --dry-run lists the three canonical assets, runs
#         the verifier on the sources and writes nothing
#   PASS  assemble-release.sh writes exactly the three canonical assets and its
#         automatic verify-release.sh run passes; a re-run is a no-op
#   FAIL  different bytes are refused without --force, PASS with --force
#
# It never needs the network, a ROM or a built launcher, never writes under the
# repository (mktemp only, removed on exit) and never touches out/. The real
# repository files are only read to build the synthetic packages. The synthetic
# archives are written with python3 (zipfile/tarfile), so no 'zip' binary is
# needed; unzip is still required by verify-release.sh.
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
ASSEMBLE="$ROOT/scripts/release/assemble-release.sh"

VERSION="0.1.0"
WINDOWS_EXE="3ds2apple-launcher.exe"
MAC_APP="3ds2apple-launcher.app"
LICENSE_TEXTS=(LICENSE NOTICE THIRD_PARTY.md)
LINUX_TOP_DIR="3ds2apple-launcher-linux-x64"

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

for tool in unzip python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required by release-selfcheck.sh" >&2
    exit 2
  fi
done
if command -v sha256sum >/dev/null 2>&1; then
  hash_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "error: sha256sum or shasum is required by release-selfcheck.sh" >&2
  exit 2
fi
file_bytes() { wc -c < "$1" | tr -d ' '; }

[ -f "$VERIFY" ] || { echo "error: verifier not found: $VERIFY" >&2; exit 2; }
[ -f "$ASSEMBLE" ] || { echo "error: assembler not found: $ASSEMBLE" >&2; exit 2; }
for text in "${LICENSE_TEXTS[@]}"; do
  [ -f "$ROOT/$text" ] || { echo "error: repository licence text missing: $ROOT/$text" >&2; exit 2; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/3ds2apple-release-selfcheck.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
CASE_DIR="$TMP/cases"
mkdir -p "$CASE_DIR"

# py_zip ZIP STAGE NAME... - write a zip with python3's zipfile (the Windows
# build host normally provides zip, this check must also run where it does not).
# A NAME that is a directory is added recursively; names are archive-relative.
py_zip() {
  local zip="$1" stage="$2"
  shift 2
  python3 - "$zip" "$stage" "$@" <<'PY'
import os
import sys
import zipfile

zip_path, stage = sys.argv[1], sys.argv[2]
names = sys.argv[3:]
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
    for name in names:
        source = os.path.join(stage, name)
        if os.path.isdir(source):
            for base, dirs, files in os.walk(source):
                dirs.sort()
                for entry in sorted(files):
                    full = os.path.join(base, entry)
                    rel = os.path.relpath(full, stage).replace(os.sep, "/")
                    archive.write(full, rel)
        else:
            archive.write(source, name)
PY
}

# py_tar TAR STAGE - gzip tar of the STAGE entries with plain relative names, the
# same layout launcher/linux/build-linux.sh writes with
# "tar -czf <tar> -C <parent> 3ds2apple-launcher-linux-x64".
py_tar() {
  local tar="$1" stage="$2"
  python3 - "$tar" "$stage" <<'PY'
import os
import sys
import tarfile

tar_path, stage = sys.argv[1], sys.argv[2]
with tarfile.open(tar_path, "w:gz") as archive:
    for name in sorted(os.listdir(stage)):
        archive.add(os.path.join(stage, name), arcname=name, recursive=True)
PY
}

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

# LAST_RC/LAST_OUT are set by capture; expect_rc/expect_grep/expect_grep_count
# turn them into pass/fail cases (used for the assemble-release checks).
LAST_RC=0
LAST_OUT=""
capture() {
  set +e
  LAST_OUT="$("$@" 2>&1)"
  LAST_RC=$?
  set -e
}
expect_rc() {
  local name="$1" expected="$2"
  if [ "$LAST_RC" -eq "$expected" ]; then
    pass_case "$name"
  else
    fail_case "$name" "exit $LAST_RC, expected $expected"
    printf '%s\n' "$LAST_OUT" | sed 's/^/    | /' >&2
  fi
}
expect_grep() {
  local name="$1" pattern="$2"
  if grep -qE -- "$pattern" <<< "$LAST_OUT"; then
    pass_case "$name"
  else
    fail_case "$name" "missing expected output: $pattern"
    printf '%s\n' "$LAST_OUT" | sed 's/^/    | /' >&2
  fi
}
expect_grep_count() {
  local name="$1" pattern="$2" expected="$3" count
  count="$(grep -cE -- "$pattern" <<< "$LAST_OUT" || true)"
  if [ "$count" -eq "$expected" ]; then
    pass_case "$name"
  else
    fail_case "$name" "expected $expected lines matching $pattern, found $count"
  fi
}
check_absent() {
  local name="$1" path="$2"
  if [ -e "$path" ]; then fail_case "$name" "unexpected path exists: $path"; else pass_case "$name"; fi
}
check_same_bytes() {
  local name="$1" left="$2" right="$3"
  if [ "$(hash_file "$left")" = "$(hash_file "$right")" ]; then
    pass_case "$name"
  else
    fail_case "$name" "different bytes: $left vs $right"
  fi
}
check_exact_files() {
  local name="$1" dir="$2" expected actual f
  shift 2
  expected="$(printf '%s\n' "$@" | LC_ALL=C sort)"
  actual=""
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    [ -f "$f" ] || continue
    actual="$actual$(basename "$f")"$'\n'
  done
  actual="$(printf '%s' "$actual" | LC_ALL=C sort)"
  if [ "$actual" = "$expected" ]; then
    pass_case "$name"
  else
    fail_case "$name" "expected: $(printf '%s' "$expected" | tr '\n' ' '); found: $(printf '%s' "$actual" | tr '\n' ' ')"
  fi
}

make_windows_zip() {
  local zip="$1" missing="${2:-}" tamper="${3:-}" extra="${4:-}" rom="${5:-}" exe_suffix="${6:-}"
  local stage="$CASE_DIR/$(basename "$zip" .zip)-win"
  local names=("$WINDOWS_EXE") text
  rm -rf "$stage"
  mkdir -p "$stage"
  # Mirror the real single-file exe: the uncompressed deps.json carries the build
  # version as the entry project key "3ds2apple-launcher/<ver>".
  {
    printf 'synthetic Windows launcher payload for release-selfcheck\n'
    printf '"3ds2apple-launcher/%s"\n' "$VERSION"
    if [ -n "$exe_suffix" ]; then printf '%s\n' "$exe_suffix"; fi
  } > "$stage/$WINDOWS_EXE"
  for text in "${LICENSE_TEXTS[@]}"; do
    [ "$text" = "$missing" ] && continue
    cp "$ROOT/$text" "$stage/$text"
    if [ "$text" = "$tamper" ]; then printf '\n[tampered by release-selfcheck]\n' >> "$stage/$text"; fi
    names+=("$text")
  done
  if [ -n "$extra" ]; then printf 'unexpected file\n' > "$stage/$extra"; names+=("$extra"); fi
  if [ -n "$rom" ]; then printf 'not a real ROM\n' > "$stage/$rom"; names+=("$rom"); fi
  py_zip "$zip" "$stage" "${names[@]}"
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
  local names=("$MAC_APP")
  for text in "${LICENSE_TEXTS[@]}"; do
    [ "$text" = "$missing" ] && continue
    cp "$ROOT/$text" "$stage/$text"
    if [ "$text" = "$tamper" ]; then printf '\n[tampered by release-selfcheck]\n' >> "$stage/$text"; fi
    names+=("$text")
  done
  if [ -n "$extra" ]; then printf 'unexpected file\n' > "$stage/$extra"; names+=("$extra"); fi
  if [ -n "$rom" ]; then printf 'not a real ROM\n' > "$stage/$rom"; names+=("$rom"); fi
  py_zip "$zip" "$stage" "${names[@]}"
}

# make_linux_stage STAGE [shell-version] - a complete synthetic Linux launcher
# folder matching launcher/linux/build-linux.sh --payload --local-aot: the
# DistributionLayout payload, the local-AOT toolchain, the repository licence
# texts at the folder root and under licenses/, a shell manifest consistent with
# the synthetic shell template IPA and PINS-local-aot.json consistent with
# Bin/3dsrecomp.
make_linux_stage() {
  local stage="$1" shell_version="${2:-$VERSION}" ipa_sha ipa_bytes recomp_sha
  local root="$stage/$LINUX_TOP_DIR"
  rm -rf "$stage"
  mkdir -p "$root/Shell" "$root/Bin/llvm/bin" "$root/Bin/llvm/lib/clang/23.1.6/include" \
    "$root/ThirdParty/Impactor" "$root/tools/winbuild/darwin-stubs" \
    "$root/tools/winbuild/include" "$root/licenses"
  printf '#!/bin/sh\n# synthetic 3ds2apple Linux launcher for release-selfcheck\nexit 0\n' > "$root/3ds2apple-launcher"
  chmod +x "$root/3ds2apple-launcher"
  cp "$ROOT/LICENSE" "$root/LICENSE"
  cp "$ROOT/NOTICE" "$root/NOTICE"
  cp "$ROOT/THIRD_PARTY.md" "$root/THIRD_PARTY.md"
  cp "$ROOT/LICENSE" "$root/licenses/LICENSE"
  cp "$ROOT/NOTICE" "$root/licenses/NOTICE"
  cp "$ROOT/THIRD_PARTY.md" "$root/licenses/THIRD_PARTY.md"
  printf 'synthetic ROM-free shell template IPA for release-selfcheck\n' > "$root/Shell/3ds2apple-shell.ipa"
  ipa_sha="$(hash_file "$root/Shell/3ds2apple-shell.ipa")"
  ipa_bytes="$(file_bytes "$root/Shell/3ds2apple-shell.ipa")"
  cat > "$root/Shell/manifest.json" <<EOF
{"schemaVersion":1,"fileName":"3ds2apple-shell.ipa","version":"$shell_version","bundleId":"io.github.hfykratos.3ds2apple.shell","sha256":"$ipa_sha","bytes":$ipa_bytes,"build":1,"minIosVersion":"17.0"}
EOF
  printf 'synthetic 3dsrecomp Linux build for release-selfcheck\n' > "$root/Bin/3dsrecomp"
  recomp_sha="$(hash_file "$root/Bin/3dsrecomp")"
  cat > "$root/PINS-local-aot.json" <<EOF
{"schema":"3ds2apple-linux-local-aot/1","llvm":"clang version 23.1.6 (synthetic release-selfcheck)","ld64":"LLD 23.1.6 (synthetic release-selfcheck)","recompiler":"$recomp_sha","note":"synthetic release-selfcheck payload"}
EOF
  printf 'synthetic 3ds2apple-pack CLI for release-selfcheck\n' > "$root/Bin/3ds2apple-pack"
  printf 'synthetic devpush for release-selfcheck\n' > "$root/Bin/devpush"
  printf 'synthetic plumesign-linux-x86_64 for release-selfcheck\n' > "$root/ThirdParty/Impactor/plumesign-linux-x86_64"
  printf '{"synthetic":true}\n' > "$root/ThirdParty/Impactor/PINS.json"
  printf 'synthetic Impactor MIT text for release-selfcheck\n' > "$root/ThirdParty/Impactor/LICENSE-Impactor-MIT.txt"
  printf 'synthetic apple-codesign MPL-2.0 text for release-selfcheck\n' > "$root/ThirdParty/Impactor/LICENSE-apple-codesign-MPL-2.0.txt"
  printf 'synthetic Impactor source and licence links for release-selfcheck\n' > "$root/ThirdParty/Impactor/README-source-and-licenses.txt"
  printf 'synthetic clang binary for release-selfcheck\n' > "$root/Bin/llvm/bin/clang"
  printf 'synthetic llvm-ar binary for release-selfcheck\n' > "$root/Bin/llvm/bin/llvm-ar"
  printf 'synthetic ld64.lld binary for release-selfcheck\n' > "$root/Bin/llvm/bin/ld64.lld"
  printf 'synthetic clang resource header for release-selfcheck\n' > "$root/Bin/llvm/lib/clang/23.1.6/include/stddef.h"
  printf '/* synthetic Darwin stub for release-selfcheck */\n' > "$root/tools/winbuild/darwin-stubs/synthetic_stub.h"
  printf '/* synthetic zk_gamepack_shim.c for release-selfcheck */\n' > "$root/tools/winbuild/zk_gamepack_shim.c"
  printf '#pragma once\n/* synthetic zakuro_gamepack.h for release-selfcheck */\n' > "$root/tools/winbuild/include/zakuro_gamepack.h"
}

# make_linux_tar TAR [shell-version] - fresh complete stage + tar.gz.
make_linux_tar() {
  local tar="$1" shell_version="${2:-$VERSION}"
  local stage="$CASE_DIR/$(basename "$tar" .tar.gz)-stage"
  make_linux_stage "$stage" "$shell_version"
  py_tar "$tar" "$stage"
}

# new_linux_stage NAME - create a fresh complete stage for one negative case.
new_linux_stage() {
  local stage="$CASE_DIR/$1-stage"
  make_linux_stage "$stage"
  echo "$stage"
}

# set_json_field FILE KEY VALUE [numeric] - rewrite one JSON field as a string
# by default (the sha256/recompiler digests are strings); pass "numeric" for
# integer fields such as the shell manifest "bytes".
set_json_field() {
  python3 - "$1" "$2" "$3" "${4:-string}" <<'PY'
import json
import sys

path, key, value, kind = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
data[key] = int(value) if kind == "numeric" else value
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
}

# make_win_selftest_log FILE VERSION [PASS_COUNT] [FAIL_COUNT] [WARN_COUNT] [EXIT_CODE]
# Minimal stand-in for the log scripts/release/win-selftest.sh writes: the
# version header line, [PASS]/[FAIL]/[WARN] status lines, the final verdict line
# and the appended "win-selftest: exit code N" evidence line.
make_win_selftest_log() {
  local log="$1" version="$2"
  local pass_count="${3:-33}" fail_count="${4:-0}" warn_count="${5:-0}" exit_code="${6:-0}" i
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

echo "[1/7] windows zip: complete archive passes"
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
echo "[2/7] windows zip: embedded launcher version + native self-test log"
run_verify_case "windows exe embeds the expected version -> PASS" pass "embeds launcher version 0.1.0" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.0
run_verify_case "windows exe version mismatch -> FAIL" fail "does not embed launcher version 0.1.4" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.4

GOOD_LOG="$CASE_DIR/win-selftest-ok.log"
make_win_selftest_log "$GOOD_LOG" 0.1.0
run_verify_case "clean win-selftest log -> PASS" pass "33 PASS / 0 FAIL / 0 WARN" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.0 --win-selftest-log "$GOOD_LOG"

BAD_LOG="$CASE_DIR/win-selftest-fail.log"
make_win_selftest_log "$BAD_LOG" 0.1.0 31 1 0 1
run_verify_case "win-selftest log with a FAIL -> FAIL" fail "does not prove a clean native self-test" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.0 --win-selftest-log "$BAD_LOG"

run_verify_case "missing win-selftest log -> FAIL" fail "win-selftest-log file not found" \
  --windows-zip "$W_COMPLETE" --expect-package-version 0.1.0 --win-selftest-log "$CASE_DIR/does-not-exist.log"

echo
echo "[3/7] macOS zip: complete archive passes"
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
echo "[4/7] Linux tar.gz: complete package passes and matches the shell manifest"
L_COMPLETE="$CASE_DIR/3ds2apple-0.1.0-linux-x86_64.tar.gz"
make_linux_tar "$L_COMPLETE"
run_verify_case "linux tar complete -> PASS" pass "all 23 required payload files are present" --linux-tar "$L_COMPLETE"
run_verify_case "linux tar complete with the expected release version -> PASS" pass "shell manifest version is the release version 0.1.0" \
  --linux-tar "$L_COMPLETE" --expect-package-version 0.1.0

echo
echo "[5/7] Linux tar.gz: every contract deviation is rejected"
L_STAGE="$(new_linux_stage linux-missing-launcher)"
rm -f "$L_STAGE/$LINUX_TOP_DIR/3ds2apple-launcher"
py_tar "$CASE_DIR/linux-missing-launcher.tar.gz" "$L_STAGE"
run_verify_case "linux missing launcher -> FAIL" fail "missing required file: 3ds2apple-launcher" \
  --linux-tar "$CASE_DIR/linux-missing-launcher.tar.gz"

L_STAGE="$(new_linux_stage linux-missing-root-license)"
rm -f "$L_STAGE/$LINUX_TOP_DIR/LICENSE"
py_tar "$CASE_DIR/linux-missing-root-license.tar.gz" "$L_STAGE"
run_verify_case "linux missing root LICENSE -> FAIL" fail "missing required file: LICENSE" \
  --linux-tar "$CASE_DIR/linux-missing-root-license.tar.gz"

L_STAGE="$(new_linux_stage linux-tampered-license)"
printf '\n[tampered by release-selfcheck]\n' >> "$L_STAGE/$LINUX_TOP_DIR/NOTICE"
py_tar "$CASE_DIR/linux-tampered-license.tar.gz" "$L_STAGE"
run_verify_case "linux tampered root NOTICE -> FAIL" fail "NOTICE sha256 .* differs from the repository file" \
  --linux-tar "$CASE_DIR/linux-tampered-license.tar.gz"

L_STAGE="$(new_linux_stage linux-missing-licenses-third-party)"
rm -f "$L_STAGE/$LINUX_TOP_DIR/licenses/THIRD_PARTY.md"
py_tar "$CASE_DIR/linux-missing-licenses-third-party.tar.gz" "$L_STAGE"
run_verify_case "linux missing licenses/THIRD_PARTY.md -> FAIL" fail "missing required file: licenses/THIRD_PARTY.md" \
  --linux-tar "$CASE_DIR/linux-missing-licenses-third-party.tar.gz"

L_STAGE="$(new_linux_stage linux-missing-shell-manifest)"
rm -f "$L_STAGE/$LINUX_TOP_DIR/Shell/manifest.json"
py_tar "$CASE_DIR/linux-missing-shell-manifest.tar.gz" "$L_STAGE"
run_verify_case "linux missing Shell/manifest.json -> FAIL" fail "missing required file: Shell/manifest.json" \
  --linux-tar "$CASE_DIR/linux-missing-shell-manifest.tar.gz"

L_STAGE="$(new_linux_stage linux-manifest-sha-mismatch)"
set_json_field "$L_STAGE/$LINUX_TOP_DIR/Shell/manifest.json" sha256 "$(printf '0%.0s' {1..64})"
py_tar "$CASE_DIR/linux-manifest-sha-mismatch.tar.gz" "$L_STAGE"
run_verify_case "linux shell manifest sha256 mismatch -> FAIL" fail "shell manifest sha256" \
  --linux-tar "$CASE_DIR/linux-manifest-sha-mismatch.tar.gz"

L_STAGE="$(new_linux_stage linux-manifest-bytes-mismatch)"
set_json_field "$L_STAGE/$LINUX_TOP_DIR/Shell/manifest.json" bytes 1 numeric
py_tar "$CASE_DIR/linux-manifest-bytes-mismatch.tar.gz" "$L_STAGE"
run_verify_case "linux shell manifest bytes mismatch -> FAIL" fail "shell manifest bytes" \
  --linux-tar "$CASE_DIR/linux-manifest-bytes-mismatch.tar.gz"

L_STAGE="$(new_linux_stage linux-missing-pins)"
rm -f "$L_STAGE/$LINUX_TOP_DIR/PINS-local-aot.json"
py_tar "$CASE_DIR/linux-missing-pins.tar.gz" "$L_STAGE"
run_verify_case "linux missing PINS-local-aot.json -> FAIL" fail "missing required file: PINS-local-aot.json" \
  --linux-tar "$CASE_DIR/linux-missing-pins.tar.gz"

L_STAGE="$(new_linux_stage linux-pins-recompiler-mismatch)"
set_json_field "$L_STAGE/$LINUX_TOP_DIR/PINS-local-aot.json" recompiler "$(printf '0%.0s' {1..64})"
py_tar "$CASE_DIR/linux-pins-recompiler-mismatch.tar.gz" "$L_STAGE"
run_verify_case "linux PINS recompiler sha mismatch -> FAIL" fail "recompiler sha256 .* does not match Bin/3dsrecomp" \
  --linux-tar "$CASE_DIR/linux-pins-recompiler-mismatch.tar.gz"

L_STAGE="$(new_linux_stage linux-extra-top-level-dir)"
mkdir -p "$L_STAGE/unexpected-top-level"
printf 'unexpected extra top-level directory\n' > "$L_STAGE/unexpected-top-level/file.txt"
py_tar "$CASE_DIR/linux-extra-top-level-dir.tar.gz" "$L_STAGE"
run_verify_case "linux extra top-level directory -> FAIL" fail "entries outside the single top-level directory" \
  --linux-tar "$CASE_DIR/linux-extra-top-level-dir.tar.gz"

L_STAGE="$(new_linux_stage linux-illegal-subdir)"
mkdir -p "$L_STAGE/$LINUX_TOP_DIR/Extra"
printf 'unexpected top-level subdirectory\n' > "$L_STAGE/$LINUX_TOP_DIR/Extra/file.txt"
py_tar "$CASE_DIR/linux-illegal-subdir.tar.gz" "$L_STAGE"
run_verify_case "linux illegal top-level subdirectory -> FAIL" fail "unexpected top-level subdirectory" \
  --linux-tar "$CASE_DIR/linux-illegal-subdir.tar.gz"

L_STAGE="$(new_linux_stage linux-rom-payload)"
printf 'not a real ROM\n' > "$L_STAGE/$LINUX_TOP_DIR/game.3ds"
py_tar "$CASE_DIR/linux-rom-payload.tar.gz" "$L_STAGE"
run_verify_case "linux ROM payload -> FAIL" fail "forbidden payload in the Linux tar" \
  --linux-tar "$CASE_DIR/linux-rom-payload.tar.gz"

L_STAGE="$(new_linux_stage linux-second-ipa)"
printf 'not a real IPA\n' > "$L_STAGE/$LINUX_TOP_DIR/Shell/second-game.ipa"
py_tar "$CASE_DIR/linux-second-ipa.tar.gz" "$L_STAGE"
run_verify_case "linux non-whitelisted second .ipa -> FAIL" fail "forbidden payload in the Linux tar" \
  --linux-tar "$CASE_DIR/linux-second-ipa.tar.gz"

L_STAGE="$(new_linux_stage linux-manifest-version)"
make_linux_stage "$L_STAGE" 0.1.4
py_tar "$CASE_DIR/linux-manifest-version.tar.gz" "$L_STAGE"
run_verify_case "linux shell manifest version vs expected -> FAIL" fail "expected release version 0.1.0" \
  --linux-tar "$CASE_DIR/linux-manifest-version.tar.gz" --expect-package-version 0.1.0

printf 'this is not a gzip tar archive\n' > "$CASE_DIR/linux-not-a-tar.tar.gz"
run_verify_case "linux unreadable tar -> FAIL" fail "not a readable gzip tar" --linux-tar "$CASE_DIR/linux-not-a-tar.tar.gz"

echo
echo "[6/7] all three platform packages + release directory: exactly three assets"
run_verify_case "windows + macOS + Linux complete -> PASS" pass "linux tar: single top-level directory" \
  --windows-zip "$W_COMPLETE" --macos-zip "$M_COMPLETE" --linux-tar "$L_COMPLETE"

RD_THREE="$CASE_DIR/release-dir-three-assets"
mkdir -p "$RD_THREE"
cp "$W_COMPLETE" "$RD_THREE/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_THREE/3ds2apple-0.1.0-macos-universal.zip"
cp "$L_COMPLETE" "$RD_THREE/3ds2apple-0.1.0-linux-x86_64.tar.gz"
run_verify_case "release dir with three assets -> PASS" pass "release dir: exactly three assets" --release-dir "$RD_THREE"

RD_LICENSE="$CASE_DIR/release-dir-license-attachment"
mkdir -p "$RD_LICENSE"
cp "$W_COMPLETE" "$RD_LICENSE/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_LICENSE/3ds2apple-0.1.0-macos-universal.zip"
cp "$L_COMPLETE" "$RD_LICENSE/3ds2apple-0.1.0-linux-x86_64.tar.gz"
cp "$ROOT/LICENSE" "$RD_LICENSE/LICENSE"
run_verify_case "release dir with a separate LICENSE -> FAIL" fail "unexpected asset name: LICENSE" --release-dir "$RD_LICENSE"

RD_SUMS="$CASE_DIR/release-dir-sha256sums"
mkdir -p "$RD_SUMS"
cp "$W_COMPLETE" "$RD_SUMS/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_SUMS/3ds2apple-0.1.0-macos-universal.zip"
cp "$L_COMPLETE" "$RD_SUMS/3ds2apple-0.1.0-linux-x86_64.tar.gz"
printf 'synthetic sums\n' > "$RD_SUMS/SHA256SUMS.txt"
run_verify_case "release dir with SHA256SUMS.txt -> FAIL" fail "unexpected asset name: SHA256SUMS.txt" --release-dir "$RD_SUMS"

RD_ONE="$CASE_DIR/release-dir-one-asset"
mkdir -p "$RD_ONE"
cp "$W_COMPLETE" "$RD_ONE/3ds2apple-0.1.0-windows-x64.zip"
run_verify_case "release dir with one asset -> FAIL" fail "expected exactly 3 asset files" --release-dir "$RD_ONE"

RD_TWO="$CASE_DIR/release-dir-two-assets"
mkdir -p "$RD_TWO"
cp "$W_COMPLETE" "$RD_TWO/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_TWO/3ds2apple-0.1.0-macos-universal.zip"
run_verify_case "release dir with two assets -> FAIL" fail "expected exactly 3 asset files" --release-dir "$RD_TWO"

RD_MIXED="$CASE_DIR/release-dir-mixed-versions"
mkdir -p "$RD_MIXED"
cp "$W_COMPLETE" "$RD_MIXED/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_MIXED/3ds2apple-0.1.0-macos-universal.zip"
cp "$L_COMPLETE" "$RD_MIXED/3ds2apple-0.1.4-linux-x86_64.tar.gz"
run_verify_case "release dir with mixed versions -> FAIL" fail "different versions" --release-dir "$RD_MIXED"

RD_VERSIONED="$CASE_DIR/v0.1.0"
mkdir -p "$RD_VERSIONED"
cp "$W_COMPLETE" "$RD_VERSIONED/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_VERSIONED/3ds2apple-0.1.0-macos-universal.zip"
cp "$L_COMPLETE" "$RD_VERSIONED/3ds2apple-0.1.0-linux-x86_64.tar.gz"
run_verify_case "release dir named v0.1.0 with matching artifacts -> PASS" pass "embeds launcher version 0.1.0" --release-dir "$RD_VERSIONED"

RD_WRONGVER="$CASE_DIR/v0.9.9"
mkdir -p "$RD_WRONGVER"
cp "$W_COMPLETE" "$RD_WRONGVER/3ds2apple-0.1.0-windows-x64.zip"
cp "$M_COMPLETE" "$RD_WRONGVER/3ds2apple-0.1.0-macos-universal.zip"
cp "$L_COMPLETE" "$RD_WRONGVER/3ds2apple-0.1.0-linux-x86_64.tar.gz"
run_verify_case "release dir name v0.9.9 vs artifacts 0.1.0 -> FAIL" fail "does not embed launcher version 0.9.9" --release-dir "$RD_WRONGVER"

echo
echo "[7/7] assemble-release.sh: dry-run, three canonical assets, idempotence, --force"
ASSEMBLE_DIR="$CASE_DIR/assemble-out"
W_CHANGED="$CASE_DIR/windows-complete-changed.zip"
make_windows_zip "$W_CHANGED" "" "" "" "" "extra payload so the archive bytes differ"

capture "$ASSEMBLE" --version "v$VERSION" --out-dir "$ASSEMBLE_DIR" \
  --windows-zip "$W_COMPLETE" --macos-zip "$M_COMPLETE" --linux-tar "$L_COMPLETE" --dry-run
expect_rc "assemble dry-run -> exit 0" 0
expect_grep_count "assemble dry-run lists exactly three [plan] asset lines" '^\[plan\] 3ds2apple-' 3
expect_grep "assemble dry-run uses the canonical Windows asset name" '3ds2apple-0\.1\.0-windows-x64\.zip <- '
expect_grep "assemble dry-run uses the canonical macOS asset name" '3ds2apple-0\.1\.0-macos-universal\.zip <- '
expect_grep "assemble dry-run uses the canonical Linux asset name" '3ds2apple-0\.1\.0-linux-x86_64\.tar\.gz <- '
expect_grep "assemble dry-run verifies the source artifacts" 'verify-release: OK'
expect_grep "assemble dry-run plan summary counts three files" 'DRY-RUN OK: 3 files'
check_absent "assemble dry-run writes nothing" "$ASSEMBLE_DIR"

capture "$ASSEMBLE" --version "v$VERSION" --out-dir "$ASSEMBLE_DIR" \
  --windows-zip "$W_COMPLETE" --macos-zip "$M_COMPLETE" --linux-tar "$L_COMPLETE"
expect_rc "assemble writes the release directory -> exit 0" 0
expect_grep "assemble runs the verifier on the assembled directory" 'verify-release: OK'
expect_grep "assemble summary counts three files" 'files: +3 \(3 added, 0 replaced, 0 unchanged\)'
check_exact_files "assemble writes exactly the three canonical assets" "$ASSEMBLE_DIR" \
  "3ds2apple-$VERSION-windows-x64.zip" \
  "3ds2apple-$VERSION-macos-universal.zip" \
  "3ds2apple-$VERSION-linux-x86_64.tar.gz"
check_same_bytes "assemble copies the Windows zip byte-for-byte" \
  "$ASSEMBLE_DIR/3ds2apple-$VERSION-windows-x64.zip" "$W_COMPLETE"
check_same_bytes "assemble copies the macOS zip byte-for-byte" \
  "$ASSEMBLE_DIR/3ds2apple-$VERSION-macos-universal.zip" "$M_COMPLETE"
check_same_bytes "assemble copies the Linux tar byte-for-byte" \
  "$ASSEMBLE_DIR/3ds2apple-$VERSION-linux-x86_64.tar.gz" "$L_COMPLETE"
run_verify_case "assembled release directory passes verify-release.sh" pass "release dir: exactly three assets" --release-dir "$ASSEMBLE_DIR"

capture "$ASSEMBLE" --version "v$VERSION" --out-dir "$ASSEMBLE_DIR" \
  --windows-zip "$W_COMPLETE" --macos-zip "$M_COMPLETE" --linux-tar "$L_COMPLETE"
expect_rc "assemble re-run -> exit 0" 0
expect_grep "assemble re-run leaves all three assets unchanged" 'files: +3 \(0 added, 0 replaced, 3 unchanged\)'

capture "$ASSEMBLE" --version "v$VERSION" --out-dir "$ASSEMBLE_DIR" \
  --windows-zip "$W_CHANGED" --macos-zip "$M_COMPLETE" --linux-tar "$L_COMPLETE"
expect_rc "assemble different bytes without --force -> exit 1" 1
expect_grep "assemble refuses different bytes without --force" 'refusing to overwrite .*use --force'
check_same_bytes "assemble keeps the old bytes after the refused overwrite" \
  "$ASSEMBLE_DIR/3ds2apple-$VERSION-windows-x64.zip" "$W_COMPLETE"

capture "$ASSEMBLE" --version "v$VERSION" --out-dir "$ASSEMBLE_DIR" \
  --windows-zip "$W_CHANGED" --macos-zip "$M_COMPLETE" --linux-tar "$L_COMPLETE" --force
expect_rc "assemble different bytes with --force -> exit 0" 0
expect_grep "assemble reports the forced replacement" 'files: +3 \(0 added, 1 replaced, 2 unchanged\)'
expect_grep "assemble verifies the forced release directory" 'verify-release: OK'
check_same_bytes "assemble replaces the Windows zip with --force" \
  "$ASSEMBLE_DIR/3ds2apple-$VERSION-windows-x64.zip" "$W_CHANGED"

echo
echo "release-selfcheck: $CHECKS cases, $PASS_CASES passed, $FAIL_CASES failed"
if [ "$FAILURES" -ne 0 ]; then
  echo "release-selfcheck: FAILED" >&2
  exit 1
fi
echo "release-selfcheck: OK"
