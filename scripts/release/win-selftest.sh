#!/usr/bin/env bash
# win-selftest.sh - run the shipped Windows launcher's native --self-test on the
# Windows host (through WSL interop) and assert the clean-folder acceptance result.
#
# The Windows package is a self-contained .NET single-file PE
# (3ds2apple-launcher.exe) with the ROM-free shell template, the pinned official
# Impactor/plumesign, the Bin tool CLIs and the licence texts embedded. Only a
# Windows host can execute it and prove that embedded payload, so AGENTS.md §7
# requires a clean-folder "3ds2apple-launcher.exe --self-test" on Windows
# (33 PASS / 0 FAIL / 0 WARN) before a release. This script makes that run
# reproducible from WSL:
#
#   - refuses to run without the WSL Windows interop binfmt handler
#     (/proc/sys/fs/binfmt_misc/WSLInterop) and exits 2 on a plain Linux host;
#   - extracts a release zip into a fresh mktemp directory under the git-ignored
#     out/ (or --work-dir DIR);
#   - executes ./3ds2apple-launcher.exe --self-test DIRECTLY on Windows (no
#     cmd.exe wrapper, so the exit code and the captured streams are the
#     launcher's own) and captures stdout+stderr to self-test.log;
#   - prints one [PASS]/[FAIL] line per check:
#       exit code 0,
#       the exact final line "SELF-TEST OK" (no "with N warning(s)"),
#       exactly 32 [PASS] lines, 0 [FAIL] lines, 0 [WARN] lines,
#       the version line "3ds2apple launcher self-test · 3ds2apple-launcher-windows/<ver>"
#       where <ver> is --expect-version or parsed from
#       3ds2apple-<ver>-windows-x64.zip;
#   - appends "win-selftest: exit code N" evidence lines to the log, which
#     scripts/release/verify-release.sh --win-selftest-log folds into the release
#     gate as one PASS;
#   - removes its own mktemp directory on exit unless --keep is given. It only
#     ever removes the directory created by this run under out/win-selftest.*
#     (realpath-checked, ${VAR:?} guarded); --work-dir directories are never
#     deleted.
#
# One run takes about a minute: the launcher extracts its ~300 MB payload beside
# the exe and runs 32 host-side checks. The Windows host must be up; WSL interop
# is enabled by default on Windows 10/11. Run it from a Windows drive mount
# (e.g. /mnt/f/project/3ds2apple) so the exe can use a normal Win32 path.
#
# Usage:
#   scripts/release/win-selftest.sh --zip out/release/v0.1.4/3ds2apple-0.1.4-windows-x64.zip
#   scripts/release/win-selftest.sh --zip <zip> --expect-version 0.1.4 --keep
#   scripts/release/win-selftest.sh --zip <zip> --work-dir out/win-selftest-manual
#
# Exit codes: 0 = every native self-test check passed, 1 = at least one check
#             failed, 2 = usage/tooling/interop error (nothing was verified).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EXE_NAME="3ds2apple-launcher.exe"
EXPECTED_PASS_LINES=33
INTEROP_FILE="/proc/sys/fs/binfmt_misc/WSLInterop"

ZIP=""
EXPECT_VERSION=""
EXPECT_VERSION_SOURCE=""
KEEP=0
WORK_DIR=""
WORK=""
CREATED_WORK=0
LOG=""
PASS_COUNT=0
FAIL_COUNT=0

usage() {
  cat <<'EOF'
Run the shipped Windows launcher's native --self-test through WSL Windows interop.

Usage:
  scripts/release/win-selftest.sh --zip FILE [options]

Required:
  --zip FILE             Windows release zip (3ds2apple-<ver>-windows-x64.zip);
                         the exe is extracted and executed as
                         ./3ds2apple-launcher.exe --self-test.

Options:
  --expect-version VER   Expected launcher version (default: parsed from the
                         canonical zip file name 3ds2apple-<ver>-windows-x64.zip).
  --keep                 Keep the temporary work directory and print the log path
                         (it is removed by default).
  --work-dir DIR         Extract and run in DIR instead of a fresh out/ mktemp
                         directory; DIR must be empty and is never deleted.
  -h, --help             Show this help and exit.

Checks: exit code 0, final line "SELF-TEST OK", exactly 33 PASS lines, 0 FAIL
lines, 0 WARN lines and the version line
"3ds2apple launcher self-test · 3ds2apple-launcher-windows/<ver>".

Exit codes: 0 all checks passed, 1 a check failed, 2 usage/tooling/interop error.
EOF
}

info() { echo "[win-selftest] $*"; }
warn() { echo "[win-selftest][warn] $*" >&2; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "[PASS] $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "[FAIL] $*" >&2; }
die() { echo "error: $*" >&2; exit 2; }

resolve_path() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$ROOT/$1" ;;
  esac
}

# Delete only the directory this run created with mktemp under out/. The target
# is canonicalised with realpath and must match out/win-selftest.?????? exactly;
# the removal is additionally guarded with ${VAR:?} so an empty or unexpected
# path can never expand into a broad "rm -rf".
cleanup() {
  local out_real resolved
  if [ -z "${WORK:-}" ]; then
    return 0
  fi
  if [ "${CREATED_WORK:-0}" -ne 1 ] || [ "${KEEP:-0}" -eq 1 ]; then
    return 0
  fi
  out_real="$(realpath "$ROOT/out" 2>/dev/null || true)"
  resolved="$(realpath "$WORK" 2>/dev/null || true)"
  if [ -z "${resolved:-}" ] || [ -z "${out_real:-}" ]; then
    warn "refusing to delete the unresolved work directory '${WORK:-}'; remove it manually"
    return 0
  fi
  case "$resolved" in
    "$out_real"/win-selftest.??????)
      rm -rf -- "${resolved:?refusing to delete an unresolved path}" ;;
    *)
      warn "refusing to delete unexpected path: $resolved (only this run's out/win-selftest.* directory is removed)" ;;
  esac
}
trap cleanup EXIT

# The Windows launcher writes redirected Console.Out in the Windows console code
# page. On the release host that is CP936 (GBK): the "·" and "—" characters in
# the self-test output are 2-byte GBK sequences and the raw capture is not valid
# UTF-8. Decode the capture to UTF-8 and strip CR so the line-anchored checks and
# the kept evidence log are portable. The code page is only *reported* by
# "cmd.exe /c chcp"; the self-test itself is always executed directly.
windows_console_encoding() {
  local cp=""
  if command -v cmd.exe >/dev/null 2>&1; then
    cp="$(cmd.exe /c chcp 2>/dev/null | tr -dc '0-9' || true)"
  fi
  case "$cp" in
    ""|0|65001) echo "" ;;
    *) echo "CP$cp" ;;
  esac
}

normalize_log() {
  local raw="$1" out="$2" enc=""
  if iconv -f UTF-8 -t UTF-8 "$raw" >/dev/null 2>&1; then
    tr -d '\r' < "$raw" > "$out"
    return 0
  fi
  if command -v iconv >/dev/null 2>&1; then
    for enc in "$(windows_console_encoding)" GB18030 CP1252; do
      if [ -z "$enc" ]; then
        continue
      fi
      if iconv -f "$enc" -t UTF-8 "$raw" 2>/dev/null | tr -d '\r' > "$out"; then
        return 0
      fi
    done
  fi
  warn "could not decode the captured self-test output to UTF-8; keeping the raw bytes"
  tr -d '\r' < "$raw" > "$out"
}

print_kept_paths() {
  if [ "$CREATED_WORK" -eq 0 ]; then
    echo "[info] work dir (kept): $WORK"
    echo "[info] self-test log: $LOG"
  elif [ "$KEEP" -eq 1 ]; then
    echo "[info] kept work dir: $WORK"
    echo "[info] self-test log: $LOG"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --zip)
      [ "$#" -ge 2 ] || die "--zip requires a value"
      ZIP="$2"
      shift 2
      ;;
    --expect-version)
      [ "$#" -ge 2 ] || die "--expect-version requires a value"
      EXPECT_VERSION="$2"
      EXPECT_VERSION_SOURCE="--expect-version"
      shift 2
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    --work-dir)
      [ "$#" -ge 2 ] || die "--work-dir requires a value"
      WORK_DIR="$2"
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

if [ -z "$ZIP" ]; then
  usage >&2
  die "--zip is required"
fi

for tool in unzip realpath; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required by win-selftest.sh"
done

ZIP="$(resolve_path "$ZIP")"
[ -f "$ZIP" ] || die "Windows release zip not found: $ZIP"

if [ -z "$EXPECT_VERSION" ]; then
  zip_base="$(basename "$ZIP")"
  case "$zip_base" in
    3ds2apple-*-windows-x64.zip)
      candidate="${zip_base#3ds2apple-}"
      candidate="${candidate%-windows-x64.zip}"
      if [ -n "$candidate" ]; then
        EXPECT_VERSION="$candidate"
        EXPECT_VERSION_SOURCE="zip file name"
      fi
      ;;
  esac
fi
[ -n "${EXPECT_VERSION:-}" ] || die "cannot derive the expected version from the zip name; pass --expect-version <ver>"
case "$EXPECT_VERSION" in
  *[!A-Za-z0-9.+-]*) die "invalid expected version: $EXPECT_VERSION" ;;
esac

case "$ROOT" in
  /mnt/?/*) : ;;
  *) warn "the repository is not under a /mnt/<drive> mount; a Windows process may not be able to use the work directory (run from the F: drive mount, e.g. /mnt/f/project/3ds2apple)" ;;
esac

# 1. Windows interop: without it WSL cannot execute the shipped PE.
if [ ! -r "$INTEROP_FILE" ]; then
  echo "error: Windows interop is not available: $INTEROP_FILE is not readable." >&2
  echo "error: win-selftest.sh executes a Windows .exe and must run inside WSL on the Windows host (Windows 10/11 with WSLInterop enabled) or on Windows itself; a plain Linux host cannot run 3ds2apple-launcher.exe --self-test." >&2
  exit 2
fi
if ! head -n 1 "$INTEROP_FILE" 2>/dev/null | grep -qx enabled; then
  echo "error: Windows interop is registered but disabled: $INTEROP_FILE does not start with 'enabled'." >&2
  echo "error: run win-selftest.sh inside WSL on the Windows host with Windows interop enabled, or on Windows itself." >&2
  exit 2
fi

# 2. Work directory: fresh mktemp under out/ by default (removed on exit), or a
#    user-chosen empty directory that is never deleted.
if [ -n "$WORK_DIR" ]; then
  WORK="$(resolve_path "$WORK_DIR")"
  if [ -e "$WORK" ] && [ ! -d "$WORK" ]; then
    die "--work-dir is not a directory: $WORK"
  fi
  if [ -d "$WORK" ] && [ -n "$(ls -A "$WORK" 2>/dev/null)" ]; then
    die "--work-dir must be empty: $WORK"
  fi
  mkdir -p "$WORK"
  CREATED_WORK=0
else
  mkdir -p "$ROOT/out"
  WORK="$(mktemp -d "$ROOT/out/win-selftest.XXXXXX")"
  CREATED_WORK=1
fi

info "zip: $ZIP"
info "work dir: $WORK"
info "expected version: $EXPECT_VERSION (from $EXPECT_VERSION_SOURCE)"
info "extracting the zip and running the native self-test (about a minute)"

# 3. Unpack and execute the shipped exe. The extraction runs on Windows so the
#    launcher can exercise its portable "beside the launcher" payload extraction.
unzip -q -o "$ZIP" -d "$WORK" || die "failed to extract $ZIP (is it a readable zip?)"
EXE_PATH="$WORK/$EXE_NAME"
[ -f "$EXE_PATH" ] || die "the zip does not contain $EXE_NAME at its ZIP root"
chmod +x "$EXE_PATH" 2>/dev/null || true

RAW_LOG="$WORK/self-test.raw.log"
LOG="$WORK/self-test.log"
info "executing ./$EXE_NAME --self-test directly through Windows interop (no cmd.exe wrapper)"
set +e
( cd "$WORK" && "./$EXE_NAME" --self-test ) > "$RAW_LOG" 2>&1
EXIT_CODE=$?
set -e
normalize_log "$RAW_LOG" "$LOG"
{
  echo
  echo "win-selftest: zip $ZIP"
  echo "win-selftest: expect-version $EXPECT_VERSION"
  echo "win-selftest: exit code $EXIT_CODE"
} >> "$LOG"

# 4. Assert the clean-folder result, one [PASS]/[FAIL] per check.
echo
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "exit code 0"
else
  fail "exit code $EXIT_CODE (expected 0)"
fi

if grep -a -Fxq 'SELF-TEST OK' "$LOG"; then
  pass "final line is exactly 'SELF-TEST OK' (no warnings)"
else
  fail "no exact 'SELF-TEST OK' line (warnings appear as 'SELF-TEST OK with N warning(s)')"
fi

PASS_LINES="$(grep -a -c '^\[PASS\]' "$LOG" || true)"
FAIL_LINES="$(grep -a -c '^\[FAIL\]' "$LOG" || true)"
WARN_LINES="$(grep -a -c '^\[WARN\]' "$LOG" || true)"
if [ "$PASS_LINES" -eq "$EXPECTED_PASS_LINES" ]; then
  pass "$EXPECTED_PASS_LINES PASS lines"
else
  fail "expected $EXPECTED_PASS_LINES PASS lines, found $PASS_LINES"
fi
if [ "$FAIL_LINES" -eq 0 ]; then
  pass "0 FAIL lines"
else
  fail "found $FAIL_LINES FAIL lines"
fi
if [ "$WARN_LINES" -eq 0 ]; then
  pass "0 WARN lines"
else
  fail "found $WARN_LINES WARN lines"
fi

VERSION_LINE="$(LC_ALL=C grep -a -E '^3ds2apple launcher self-test ' "$LOG" 2>/dev/null | head -n 1 || true)"
case "$VERSION_LINE" in
  *"3ds2apple-launcher-windows/$EXPECT_VERSION")
    pass "version line: 3ds2apple-launcher-windows/$EXPECT_VERSION" ;;
  *)
    fail "version line does not end with 3ds2apple-launcher-windows/$EXPECT_VERSION (found: ${VERSION_LINE:-no version line})" ;;
esac

# 5. Summary. The log is the evidence for verify-release.sh --win-selftest-log.
echo
echo "win-selftest: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -ne 0 ]; then
  echo "--- self-test.log (last 60 lines) ---" >&2
  tail -n 60 "$LOG" 2>/dev/null | sed 's/^/    | /' >&2 || true
  print_kept_paths
  echo "win-selftest: FAILED (use --keep to keep the work directory and the log)" >&2
  exit 1
fi
print_kept_paths
echo "win-selftest: OK"
