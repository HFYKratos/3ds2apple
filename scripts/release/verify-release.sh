#!/usr/bin/env bash
# verify-release.sh - read-only release gate for the three platform packages.
#
# Release policy (CONTRIBUTING.md#release-policy): a release carries exactly three
# assets, 3ds2apple-<ver>-windows-x64.zip, 3ds2apple-<ver>-macos-universal.zip and
# 3ds2apple-<ver>-linux-x86_64.tar.gz. The zips carry their platform launcher
# plus the repository licence texts LICENSE, NOTICE and THIRD_PARTY.md at the ZIP
# root, byte-identical to the repository files. The Linux tar.gz carries the
# launcher, the ROM-free shell template, plumesign/devpush, the same licence
# texts and the local-AOT toolchain inside one top-level launcher directory. The
# texts ship inside the packages and are never separate Release assets, and
# GitHub shows each asset's SHA-256 digest on the Release page.
#
# This script never publishes or modifies anything: zip archives are listed with
# unzip and their entries streamed with "unzip -p" (nothing is extracted to
# disk), the Linux tar is read in one streaming python3 tarfile pass, and the
# release directory and the optional self-test log are only read.
#
# Checks (each result is printed as [PASS]/[FAIL]/[SKIP]):
#   windows zip   exactly 3ds2apple-launcher.exe + LICENSE + NOTICE +
#                 THIRD_PARTY.md at the ZIP root, nothing else
#   macOS zip     exactly 3ds2apple-launcher.app + LICENSE + NOTICE +
#                 THIRD_PARTY.md at the top level; the .app keeps
#                 Contents/Info.plist and Contents/MacOS/*
#   linux tar     one top-level directory 3ds2apple-launcher-linux-x64/ whose
#                 first-level subdirectories are only Shell/, Bin/, ThirdParty/,
#                 tools/ and licenses/; the launcher executable at the package
#                 root, LICENSE/NOTICE/THIRD_PARTY.md both there and under
#                 licenses/ (byte-identical to the repository files), the
#                 DistributionLayout.LinuxExpectedRelativePaths payload
#                 (Shell/manifest.json, Shell/3ds2apple-shell.ipa,
#                 ThirdParty/Impactor/*, Bin/3ds2apple-pack, Bin/devpush) and the
#                 local-AOT toolchain staged by
#                 launcher/linux/build-linux.sh --local-aot (Bin/3dsrecomp,
#                 Bin/llvm/bin/{clang,llvm-ar,ld64.lld}, clang resource headers,
#                 tools/winbuild/{darwin-stubs,zk_gamepack_shim.c,include},
#                 PINS-local-aot.json)
#   linux tar     shell manifest cross-check: schemaVersion 1, fileName
#                 3ds2apple-shell.ipa, version == the release version, bytes and
#                 sha256 == the actual Shell/3ds2apple-shell.ipa entry
#   linux tar     PINS-local-aot.json is valid JSON, its recompiler sha256 equals
#                 the actual Bin/3dsrecomp digest and its llvm field carries the
#                 pinned LLVM version 23.1.6
#   linux tar     the launcher binary embeds the expected release version: like the
#                 Windows single-file exe, the Linux .NET single-file bundle keeps
#                 deps.json as plain UTF-8 and its entry project key is
#                 "3ds2apple-launcher/<ver>"; a stale --skip-publish bundle (the
#                 0.3.0 Linux tar carried 0.2.2-beta6) is a FAIL
#   all assets    no ROM (.3ds/.cci/.cia/.cxi/.3dsx/.nsp/.xci/.keys), no
#                 GamePack-*.dylib, no Roms/ entries; the only .ipa is the
#                 ROM-free shell template at
#                 3ds2apple-launcher-linux-x64/Shell/3ds2apple-shell.ipa
#   release dir   exactly the three canonical asset files, same <ver>, no extras
#                 (the licence texts are inside the packages, never separate assets)
#   windows zip   the exe embeds the expected release version: the .NET single-file
#                 bundle stores deps.json as plain UTF-8 and its entry project key
#                 is "3ds2apple-launcher/<ver>"; the expected version comes from
#                 --expect-package-version, the v<ver> release directory name or
#                 a canonical asset file name (see main)
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

# Every shipped package must carry these three repository files (the zips at
# the ZIP root, the Linux tar at the launcher folder root and under licenses/).
LICENSE_TEXTS=(LICENSE NOTICE THIRD_PARTY.md)
# Exact entry sets (no directories, nothing else).
WINDOWS_EXE="3ds2apple-launcher.exe"
WINDOWS_ENTRIES=("$WINDOWS_EXE" LICENSE NOTICE THIRD_PARTY.md)
MACOS_TOP_LEVEL=(3ds2apple-launcher.app LICENSE NOTICE THIRD_PARTY.md)
# Linux tar layout. The contract is the payload the Linux launcher itself
# enforces (DistributionLayout.LinuxExpectedRelativePaths) plus the local-AOT
# toolchain staged by launcher/linux/build-linux.sh --local-aot.
LINUX_TOP_DIR="3ds2apple-launcher-linux-x64"
LINUX_ALLOWED_DIRS=(Shell Bin ThirdParty tools licenses)
LINUX_REQUIRED=(
  "3ds2apple-launcher"
  LICENSE NOTICE THIRD_PARTY.md
  "Shell/manifest.json"
  "Shell/3ds2apple-shell.ipa"
  "ThirdParty/Impactor/plumesign-linux-x86_64"
  "ThirdParty/Impactor/PINS.json"
  "ThirdParty/Impactor/LICENSE-Impactor-MIT.txt"
  "ThirdParty/Impactor/LICENSE-apple-codesign-MPL-2.0.txt"
  "ThirdParty/Impactor/README-source-and-licenses.txt"
  "Bin/3ds2apple-pack"
  "Bin/devpush"
  "Bin/3dsrecomp"
  "Bin/llvm/bin/clang"
  "Bin/llvm/bin/llvm-ar"
  "Bin/llvm/bin/ld64.lld"
  "tools/winbuild/zk_gamepack_shim.c"
  "tools/winbuild/include/zakuro_gamepack.h"
  "PINS-local-aot.json"
  "licenses/LICENSE"
  "licenses/NOTICE"
  "licenses/THIRD_PARTY.md"
)
LINUX_SHELL_IPA="Shell/3ds2apple-shell.ipa"
LINUX_SHELL_IPA_FILE="3ds2apple-shell.ipa"
# Exact LLVM pin staged into the Linux local-AOT payload (tools/winbuild/README.md
# "LLVM 23.1.6 pin": the official llvmorg-23.1.6 release). PINS-local-aot.json
# must report this version in its "llvm" field. Bump this constant together with
# the pin in tools/winbuild (do not relax it to a range: the release policy pins
# one verified toolchain).
EXPECTED_LLVM_VERSION="23.1.6"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Read-only verification of the three platform release assets.

Usage:
  scripts/release/verify-release.sh --release-dir DIR [--win-selftest-log FILE]
  scripts/release/verify-release.sh --windows-zip FILE --macos-zip FILE \
    --linux-tar FILE [--expect-package-version VER] [--win-selftest-log FILE]
  scripts/release/verify-release.sh --linux-tar FILE [--expect-package-version VER]

Options:
  --release-dir DIR   Verify a directory assembled by assemble-release.sh: it must
                      contain exactly the three canonical platform packages. A
                      directory named v<ver> (out/release/v<ver>) also supplies
                      the expected release version for the cross-checks.
  --windows-zip FILE  Windows single-file launcher zip to verify.
  --macos-zip FILE    macOS launcher .app zip to verify.
  --linux-tar FILE    Linux x86_64 launcher .tar.gz to verify.
  --expect-package-version VER
                      Expected release version embedded in the Windows exe and in
                      the Linux shell manifest (overrides the v<ver> release
                      directory name and a canonical asset file name).
  --win-selftest-log FILE
                      Log produced by scripts/release/win-selftest.sh on the
                      Windows host; adds one PASS when it proves exit code 0,
                      SELF-TEST OK, 33 PASS, 0 FAIL, 0 WARN and the expected
                      launcher version line.
  -h, --help          Show this help and exit.

The zips must carry LICENSE, NOTICE and THIRD_PARTY.md at their root and the
Linux tar at the launcher folder root and under licenses/, all identical to the
repository files. Exit codes: 0 all requested checks passed, 1 a check failed,
2 usage/tooling error.
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

require_python3() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required to inspect the Linux .tar.gz"
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

# Linux tar.gz: the archive has no random access, so one python3 tarfile pass
# lists every entry and streams the few files that are cross-checked (nothing is
# extracted to disk, the package is never unpacked into the repository). python3
# prints "PASS: ..."/"FAIL: ..."/"SKIP: ..."/"INFO: ..." lines and the shell
# counts them through pass/fail/skip/info, keeping the [PASS]/[FAIL]/[SKIP]
# style and the 0/1/2 exit code contract of the other checks.
check_linux_tar() {
  local tar="$1" expected="$2" report rc line
  if [ ! -f "$tar" ]; then
    fail "linux tar: not a file: $tar"
    return
  fi
  if report="$(python3 - "$tar" "$ROOT" "$expected" "$EXPECTED_LLVM_VERSION" "${LINUX_ALLOWED_DIRS[@]}" -- "${LINUX_REQUIRED[@]}" <<'PY'
import hashlib
import json
import os
import re
import sys
import tarfile

args = sys.argv[1:]
tar_path, repo_root, expected_version, expected_llvm = args[0:4]
sep = args.index("--")
allowed_dirs = set(args[4:sep])
required = args[sep + 1:]
top = "3ds2apple-launcher-linux-x64"
license_texts = ["LICENSE", "NOTICE", "THIRD_PARTY.md"]
shell_ipa = "Shell/3ds2apple-shell.ipa"
shell_ipa_file = "3ds2apple-shell.ipa"
forbidden_exts = (".3ds", ".cci", ".cia", ".cxi", ".3dsx", ".nsp", ".xci", ".keys")


def emit(kind, message):
    print(kind + ": " + message)


def normalize(name):
    while name.startswith("./"):
        name = name[2:]
    return name[:-1] if name.endswith("/") else name


def read_hash(fileobj):
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = fileobj.read(1 << 20)
        if not chunk:
            break
        digest.update(chunk)
        size += len(chunk)
    return digest.hexdigest(), size


def file_hash(file_path):
    with open(file_path, "rb") as handle:
        return read_hash(handle)


try:
    archive = tarfile.open(tar_path, "r:gz")
    members = archive.getmembers()
except (tarfile.TarError, OSError, EOFError) as exc:
    emit("FAIL", "not a readable gzip tar: " + str(exc))
    sys.exit(0)

files = {}
dirs = set()
outside = []
unsafe = []
root_seen = False
for member in members:
    name = member.name.replace("\\", "/")
    if name.startswith("/") or ".." in name.split("/"):
        unsafe.append(member.name)
        continue
    name = normalize(name)
    if not name or name == ".":
        continue
    if member.isdir():
        if name == top:
            root_seen = True
        elif name.startswith(top + "/"):
            dirs.add(name[len(top) + 1:])
        else:
            outside.append(member.name)
        continue
    if name.startswith(top + "/"):
        rel = name[len(top) + 1:]
        files[rel] = member
        parts = rel.split("/")
        for index in range(1, len(parts)):
            dirs.add("/".join(parts[:index]))
    else:
        outside.append(member.name)

if root_seen or files:
    emit("PASS", "single top-level directory " + top + "/")
else:
    emit("FAIL", "missing top-level directory " + top + "/")
if outside:
    tail = ", ..." if len(outside) > 5 else ""
    emit("FAIL", "entries outside the single top-level directory: " + ", ".join(outside[:5]) + tail)
if unsafe:
    tail = ", ..." if len(unsafe) > 5 else ""
    emit("FAIL", "unsafe absolute or '..' archive paths: " + ", ".join(unsafe[:5]) + tail)

unexpected = sorted({path.split("/")[0] for path in dirs if path and path.split("/")[0] not in allowed_dirs})
if unexpected:
    emit("FAIL", "unexpected top-level subdirectory under " + top + "/: " + ", ".join(unexpected) + " (allowed: " + ", ".join(sorted(allowed_dirs)) + ")")
else:
    emit("PASS", "top-level subdirectories are only " + ", ".join(sorted(allowed_dirs)))

missing = [path for path in required if path not in files]
if missing:
    for path in missing:
        emit("FAIL", "missing required file: " + path)
else:
    emit("PASS", "all " + str(len(required)) + " required payload files are present")

llvm_headers = [path for path in files if path.startswith("Bin/llvm/lib/clang/") and "/include/" in path]
if llvm_headers:
    emit("PASS", "clang resource headers under Bin/llvm/lib/clang/<ver>/include/ (" + str(len(llvm_headers)) + " files)")
else:
    emit("FAIL", "missing clang resource headers under Bin/llvm/lib/clang/<ver>/include/")
darwin_stubs = [path for path in files if path.startswith("tools/winbuild/darwin-stubs/")]
if darwin_stubs:
    emit("PASS", "Darwin stubs under tools/winbuild/darwin-stubs/ (" + str(len(darwin_stubs)) + " files)")
else:
    emit("FAIL", "missing Darwin stubs under tools/winbuild/darwin-stubs/")


def hash_member(rel):
    member = files.get(rel)
    if member is None:
        return None
    try:
        handle = archive.extractfile(member)
    except (KeyError, OSError, tarfile.TarError):
        return None
    if handle is None:
        return None
    try:
        return read_hash(handle)
    finally:
        handle.close()


def check_license_group(prefix, label):
    ok = True
    matched = 0
    for text in license_texts:
        rel = prefix + text
        if rel not in files:
            ok = False
            continue
        repo_path = os.path.join(repo_root, text)
        if not os.path.isfile(repo_path):
            emit("FAIL", "repository licence file missing: " + repo_path)
            ok = False
            continue
        repo_digest, _ = file_hash(repo_path)
        got = hash_member(rel)
        if got is None:
            emit("FAIL", rel + " is not a readable regular file")
            ok = False
            continue
        if got[0] != repo_digest:
            emit("FAIL", rel + " sha256 " + got[0] + " differs from the repository file (" + repo_digest + ")")
            ok = False
        else:
            matched += 1
    if ok and matched == len(license_texts):
        emit("PASS", label + ": licence texts are byte-identical to the repository files")


check_license_group("", "package root")
check_license_group("licenses/", "licenses/")

manifest_member = files.get("Shell/manifest.json")
ipa_member = files.get(shell_ipa)
ipa_digest = None
ipa_bytes = None
if ipa_member is not None:
    ipa_hash = hash_member(shell_ipa)
    if ipa_hash is not None:
        ipa_digest, ipa_bytes = ipa_hash
manifest_data = None
if manifest_member is not None:
    handle = archive.extractfile(manifest_member)
    if handle is None:
        emit("FAIL", "Shell/manifest.json is not a readable regular file")
    else:
        try:
            manifest_data = json.load(handle)
        except (json.JSONDecodeError, UnicodeDecodeError, OSError) as exc:
            emit("FAIL", "Shell/manifest.json is not valid JSON: " + str(exc))
        finally:
            handle.close()
if isinstance(manifest_data, dict) and ipa_digest is not None and ipa_bytes is not None:
    if manifest_data.get("schemaVersion") == 1:
        emit("PASS", "shell manifest schemaVersion is 1")
    else:
        emit("FAIL", "shell manifest schemaVersion is " + repr(manifest_data.get("schemaVersion")) + ", expected 1")
    if manifest_data.get("fileName") == shell_ipa_file:
        emit("PASS", "shell manifest fileName is " + shell_ipa_file)
    else:
        emit("FAIL", "shell manifest fileName is " + repr(manifest_data.get("fileName")) + ", expected " + shell_ipa_file)
    version = manifest_data.get("version")
    if expected_version:
        if version == expected_version:
            emit("PASS", "shell manifest version is the release version " + expected_version)
        else:
            emit("FAIL", "shell manifest version is " + repr(version) + ", expected release version " + expected_version)
    else:
        emit("SKIP", "shell manifest version " + repr(version) + " not cross-checked (no expected release version)")
    try:
        manifest_bytes = int(manifest_data.get("bytes"))
    except (TypeError, ValueError):
        manifest_bytes = None
    if manifest_bytes == ipa_bytes:
        emit("PASS", "shell manifest bytes " + str(ipa_bytes) + " match the shell template IPA")
    else:
        emit("FAIL", "shell manifest bytes " + repr(manifest_data.get("bytes")) + " do not match the shell template IPA (" + str(ipa_bytes) + " bytes)")
    manifest_sha = manifest_data.get("sha256")
    if isinstance(manifest_sha, str) and manifest_sha.lower() == ipa_digest:
        emit("PASS", "shell manifest sha256 matches the shell template IPA (" + ipa_digest + ")")
    else:
        emit("FAIL", "shell manifest sha256 " + repr(manifest_sha) + " does not match the shell template IPA (" + ipa_digest + ")")

pins_member = files.get("PINS-local-aot.json")
pins_data = None
if pins_member is not None:
    handle = archive.extractfile(pins_member)
    if handle is None:
        emit("FAIL", "PINS-local-aot.json is not a readable regular file")
    else:
        try:
            pins_data = json.load(handle)
        except (json.JSONDecodeError, UnicodeDecodeError, OSError) as exc:
            emit("FAIL", "PINS-local-aot.json is not valid JSON: " + str(exc))
        finally:
            handle.close()
if isinstance(pins_data, dict):
    recomp_sha = None
    recomp_hash = hash_member("Bin/3dsrecomp")
    if recomp_hash is not None:
        recomp_sha = recomp_hash[0]
    reported_recomp = pins_data.get("recompiler")
    if not isinstance(reported_recomp, str) or not reported_recomp:
        emit("FAIL", "PINS-local-aot.json has no recompiler sha256")
    elif recomp_sha is None:
        pass
    elif reported_recomp.lower() == recomp_sha:
        emit("PASS", "PINS-local-aot.json recompiler sha256 matches Bin/3dsrecomp (" + recomp_sha + ")")
    else:
        emit("FAIL", "PINS-local-aot.json recompiler sha256 " + reported_recomp + " does not match Bin/3dsrecomp (" + recomp_sha + ")")
    llvm_reported = pins_data.get("llvm")
    if isinstance(llvm_reported, str) and expected_llvm in llvm_reported:
        emit("PASS", "PINS-local-aot.json llvm reports the pinned LLVM " + expected_llvm + " (" + llvm_reported + ")")
    else:
        emit("FAIL", "PINS-local-aot.json llvm " + repr(llvm_reported) + " does not carry the pinned LLVM " + expected_llvm)

# The Linux launcher is a .NET single-file bundle, so the same plain-UTF-8
# deps.json project key the Windows exe carries ("3ds2apple-launcher/<ver>") is
# embedded in the launcher binary. 0.3.0 was packaged with --skip-publish against
# the old 0.2.2-beta6 publish folder, so its launcher reported the wrong version;
# this cross-check makes that a release-gate failure. The launcher is streamed in
# chunks with a small overlap so a key crossing a chunk boundary is still found;
# nothing is extracted to disk.
def deps_versions(rel):
    member = files.get(rel)
    if member is None:
        return None
    try:
        handle = archive.extractfile(member)
    except (KeyError, OSError, tarfile.TarError):
        return None
    if handle is None:
        return None
    found = set()
    overlap = b""
    try:
        while True:
            chunk = handle.read(1 << 20)
            if not chunk:
                break
            data = overlap + chunk
            for match in re.finditer(rb'"3ds2apple-launcher/[^"]*"', data):
                found.add(match.group(0).decode("ascii", "replace"))
            overlap = data[-256:]
    finally:
        handle.close()
    return found


launcher_versions = deps_versions("3ds2apple-launcher")
if launcher_versions is not None:
    rows = sorted(launcher_versions)
    if not rows:
        emit("FAIL", "the launcher binary does not embed a 3ds2apple-launcher/<ver> deps.json key")
    elif expected_version:
        wanted = '"3ds2apple-launcher/' + expected_version + '"'
        if wanted in launcher_versions:
            emit("PASS", "the launcher binary embeds launcher version " + expected_version + " (deps.json)")
        else:
            emit("FAIL", "the launcher binary does not embed launcher version " + expected_version + " (found: " + ", ".join(rows) + ")")
    else:
        emit("SKIP", "the launcher binary embeds " + ", ".join(rows) + "; version not cross-checked (no expected release version)")

hits = []
for rel in sorted(files):
    base = rel.rsplit("/", 1)[-1]
    lower = rel.lower()
    if lower.endswith(forbidden_exts):
        hits.append(rel + " (ROM/key payload)")
    elif base.startswith("GamePack-") and base.endswith(".dylib"):
        hits.append(rel + " (GamePack payload)")
    elif "/roms/" in "/" + rel + "/":
        hits.append(rel + " (Roms/ path)")
    elif lower.endswith(".ipa") and rel != shell_ipa:
        hits.append(rel + " (.ipa other than the shell template)")
if hits:
    for hit in hits:
        emit("FAIL", "forbidden payload in the Linux tar: " + hit)
else:
    emit("PASS", "no ROM/key/GamePack payloads and no .ipa other than " + shell_ipa)
PY
)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    fail "linux tar: verifier failed to inspect the archive (python3 exit $rc)"
    return
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "PASS: "*) pass "linux tar: ${line#PASS: }" ;;
      "FAIL: "*) fail "linux tar: ${line#FAIL: }" ;;
      "SKIP: "*) skip "linux tar: ${line#SKIP: }" ;;
      "INFO: "*) info "linux tar: ${line#INFO: }" ;;
      *) info "linux tar: $line" ;;
    esac
  done <<< "$report"
  pass "linux tar: $(file_bytes "$tar") bytes, sha256 $(hash_file "$tar")"
}

# release-dir mode: exactly the three canonical assets, same <ver>, nothing else.
# The licence texts travel inside the packages, so a separate LICENSE/NOTICE/
# THIRD_PARTY.md (or SHA256SUMS.txt) in the release directory is an extra asset.
check_release_dir() {
  local dir="$1" f base w_name="" m_name="" l_name="" ver="" count=0 extra=0
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    count=$((count + 1))
    base="$(basename "$f")"
    if [ ! -f "$f" ]; then
      fail "release dir: unexpected non-file entry: $base (release policy allows only the three platform packages)"
      extra=$((extra + 1))
      continue
    fi
    case "$base" in
      3ds2apple-*-windows-x64.zip)
        if [ -n "$w_name" ]; then
          fail "release dir: more than one windows-x64.zip asset"
          extra=$((extra + 1))
        else
          w_name="$base"
        fi
        ;;
      3ds2apple-*-macos-universal.zip)
        if [ -n "$m_name" ]; then
          fail "release dir: more than one macos-universal.zip asset"
          extra=$((extra + 1))
        else
          m_name="$base"
        fi
        ;;
      3ds2apple-*-linux-x86_64.tar.gz)
        if [ -n "$l_name" ]; then
          fail "release dir: more than one linux-x86_64.tar.gz asset"
          extra=$((extra + 1))
        else
          l_name="$base"
        fi
        ;;
      *)
        fail "release dir: unexpected asset name: $base (release policy allows only the three platform packages)"
        extra=$((extra + 1))
        ;;
    esac
  done
  if [ -z "$w_name" ] || [ -z "$m_name" ] || [ -z "$l_name" ]; then
    if [ "$count" -ne 3 ]; then
      fail "release dir: expected exactly 3 asset files, found $count in $dir"
    fi
    fail "release dir: missing one of the three platform packages (windows: ${w_name:-none}, macOS: ${m_name:-none}, Linux: ${l_name:-none})"
    return
  fi
  ver="${w_name#3ds2apple-}"
  ver="${ver%-windows-x64.zip}"
  if [ "$m_name" != "3ds2apple-$ver-macos-universal.zip" ] || [ "$l_name" != "3ds2apple-$ver-linux-x86_64.tar.gz" ]; then
    fail "release dir: the three platform assets have different versions ($w_name / $m_name / $l_name)"
    return
  fi
  if [ "$count" -ne 3 ] || [ "$extra" -ne 0 ]; then
    fail "release dir: expected exactly 3 canonical assets without extra files, found $count files with $extra unexpected entries in $dir"
    return
  fi
  pass "release dir: exactly three assets, version $ver, no extra files (licence texts are inside the packages)"
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
  local release_dir="" windows_zip="" macos_zip="" linux_tar="" text
  local expect_package_version="" win_selftest_log=""
  local expected_version="" expected_version_source="" base candidate asset
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
      --linux-tar)
        [ "$#" -ge 2 ] || die "--linux-tar requires a value"
        linux_tar="$2"
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
    if [ -n "$windows_zip$macos_zip$linux_tar" ]; then
      die "use either --release-dir or explicit --windows-zip/--macos-zip/--linux-tar, not both"
    fi
    release_dir="$(resolve_path "$release_dir")"
    [ -d "$release_dir" ] || die "release dir not found: $release_dir"
    windows_zip="$(find_asset "$release_dir" "-windows-x64.zip" || true)"
    macos_zip="$(find_asset "$release_dir" "-macos-universal.zip" || true)"
    linux_tar="$(find_asset "$release_dir" "-linux-x86_64.tar.gz" || true)"
    check_release_dir "$release_dir"
  else
    if [ -z "$windows_zip$macos_zip$linux_tar" ]; then
      usage >&2
      die "pass --release-dir or at least one of --windows-zip/--macos-zip/--linux-tar"
    fi
  fi

  # Expected release version for the Windows exe, --win-selftest-log and the Linux
  # shell manifest. Precedence: --expect-package-version, the v<ver> release
  # directory name (e.g. out/release/v0.1.4 -> 0.1.4), a canonical asset file name.
  # When none applies the version cross-check is reported as [SKIP] instead of
  # guessing.
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
  if [ -z "$expected_version" ]; then
    for asset in "$windows_zip" "$macos_zip" "$linux_tar"; do
      [ -n "$asset" ] || continue
      base="$(basename "$asset")"
      candidate=""
      case "$base" in
        3ds2apple-*-windows-x64.zip)
          candidate="${base#3ds2apple-}"
          candidate="${candidate%-windows-x64.zip}"
          expected_version_source="canonical Windows zip file name"
          ;;
        3ds2apple-*-macos-universal.zip)
          candidate="${base#3ds2apple-}"
          candidate="${candidate%-macos-universal.zip}"
          expected_version_source="canonical macOS zip file name"
          ;;
        3ds2apple-*-linux-x86_64.tar.gz)
          candidate="${base#3ds2apple-}"
          candidate="${candidate%-linux-x86_64.tar.gz}"
          expected_version_source="canonical Linux tar file name"
          ;;
      esac
      if [ -n "$candidate" ]; then
        expected_version="$candidate"
        break
      fi
    done
  fi
  if [ -n "$win_selftest_log" ] && [ -z "$windows_zip" ]; then
    die "--win-selftest-log requires the Windows zip (use --windows-zip or --release-dir)"
  fi
  if [ -n "$win_selftest_log" ]; then
    win_selftest_log="$(resolve_path "$win_selftest_log")"
  fi

  if [ -n "$windows_zip$macos_zip" ]; then
    require_unzip
  fi
  if [ -n "$linux_tar" ]; then
    require_python3
  fi
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
  if [ -n "$linux_tar" ]; then
    linux_tar="$(resolve_path "$linux_tar")"
    check_linux_tar "$linux_tar" "$expected_version"
  else
    skip "Linux tar: not requested"
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
