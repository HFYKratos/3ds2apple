#!/usr/bin/env bash
# aot-sim-harness.sh — simulated split/incremental AOT build on a non-macOS host.
#
# The per-game scripts refuse to run on Linux because they need the Apple iOS
# SDK. This harness still exercises their portability-critical logic end-to-end:
# it copies scripts/ into a throw-away "repo", puts a fake Darwin toolchain in
# PATH (uname/xcrun/nm/clang/cargo/xcodegen/xcodebuild - all shell scripts that
# only mimic the output shapes the real scripts consume) and runs the *real*
# scripts. Covered:
#
#   1. adopting an archive built elsewhere (--archive) whose title ID arrives
#      corrupted ("0004000000055E00n", the real 2026-11-12 VM bug) -> repaired
#      recomp-info.txt and a warning, no trailing garbage;
#   2. --reuse paths without a ROM or cargo;
#   3. linked-library reuse repairs a corrupted build/ios/<name>/build-info.txt
#      and validates the 7 _recomp_* symbols;
#   4. nm regressions: output without leading whitespace is accepted, a prefix
#      decoy (_recomp_abi_extra) does not satisfy _recomp_abi, and an
#      interpreter-only shell library is rejected;
#   5. build-game-ipa.sh writes a clean manifest.txt (exactly 16 hex digits) and
#      packages the IPA;
#   6. split build: C generated on Linux -> serial incremental compile on the
#      VM -> linked reuse (no cargo) -> IPA, including "second run reuses all
#      objects" and "--force recompiles";
#   7. invalid title IDs / ROM paths / option combinations fail loudly.
#
# It never touches the real repo, ROM/ or build/ (everything is under mktemp)
# and never needs a game ROM. The real macOS run is still required for the iOS
# SDK parts; see scripts/AOT_BUILD.md §10.
#
# Usage:
#   scripts/tests/aot-sim-harness.sh
#   AOT_SIM_KEEP=1 scripts/tests/aot-sim-harness.sh   # keep the temp dir
#
# Exit status: 0 when every check passes, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CHECKS=0
FAILURES=0

pass() {
  CHECKS=$((CHECKS + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf '  FAIL %s\n' "$1" >&2
}

expect_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
expect_file() { # label path
  if [[ -s "$2" ]]; then pass "$1"; else fail "$1 (missing or empty: $2)"; fi
}
expect_contains() { # label needle haystack
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing '$2')"; fi
}

LAST_OUTPUT=""
run_ok() { # label command...
  local label="$1"
  shift
  if LAST_OUTPUT="$("$@" 2>&1)"; then
    pass "$label"
  else
    fail "$label (unexpected non-zero exit)"
    printf '%s\n' "$LAST_OUTPUT" | tail -25 >&2
  fi
}
run_fail() { # label expected-output-pattern command...
  local label="$1" pattern="$2" status=0
  shift 2
  LAST_OUTPUT="$("$@" 2>&1)" || status=$?
  if [[ "$status" -eq 0 ]]; then
    fail "$label (expected a non-zero exit, got success)"
  elif [[ "$LAST_OUTPUT" == *"$pattern"* ]]; then
    pass "$label"
  else
    fail "$label (missing '$pattern' in output)"
    printf '%s\n' "$LAST_OUTPUT" | tail -25 >&2
  fi
}

REAL_SYMBOLS="recomp_abi recomp_generation recomp_entry_count recomp_entries"
REAL_SYMBOLS="${REAL_SYMBOLS} recomp_module_count recomp_modules recomp_origins"

# Write the text markers the fake nm/clang understand:
#   !T <sym>    defined table symbol
#   !U <sym>    undefined symbol
#   !BARE <sym> symbol line without nm's "address type" prefix
write_symbol_markers() { # file kind
  local file="$1" kind="$2" symbol
  {
    for symbol in $REAL_SYMBOLS; do
      printf '!%s _%s\n' "$kind" "$symbol"
    done
  } > "$file"
}

info_value() { # file key
  sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n '1p'
}

# ---------------------------------------------------------------------------
# throw-away repo + fake Darwin toolchain
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/aot-sim.XXXXXX")"
REPO="${WORK}/repo"
FAKEBIN="${WORK}/fakebin"
FAKE_SDK="${WORK}/fake-sdk"
FAKE_CLANG="${FAKEBIN}/fake-clang"
export FAKE_CLANG_COUNTER="${WORK}/fake-clang-calls.txt"

cleanup() {
  if [[ "${AOT_SIM_KEEP:-0}" -eq 1 ]]; then
    printf '\n[aot-sim-harness] kept temp dir: %s\n' "$WORK" >&2
  else
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT

mkdir -p "$FAKEBIN" "$FAKE_SDK" "$REPO/ios/app"
cp -R "${SCRIPTS_DIR}" "${REPO}/scripts"
printf 'name: 3ds2apple\n' > "${REPO}/ios/app/project.yml"
: > "$FAKE_CLANG_COUNTER"
export FAKE_SDK FAKE_CLANG
export REAL_UNAME
REAL_UNAME="$(command -v uname)"
export PATH="${FAKEBIN}:${PATH}"

write_fake() { # name, body on stdin
  local name="$1"
  cat > "${FAKEBIN}/${name}"
  chmod +x "${FAKEBIN}/${name}"
}

write_fake uname <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
  printf 'Darwin\n'
else
  exec "$REAL_UNAME" "$@"
fi
SH

write_fake xcrun <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --sdk)
    case "${3:-}" in
      --show-sdk-path) printf '%s\n' "$FAKE_SDK" ;;
      -f) printf '%s\n' "$FAKE_CLANG" ;;
      *) printf 'fake-xcrun: unsupported --sdk args: %s\n' "$*" >&2; exit 1 ;;
    esac
    ;;
  lipo)
    [[ "${2:-}" == "-info" ]] || { printf 'fake-xcrun: only lipo -info is supported\n' >&2; exit 1; }
    printf 'Non-fat file: %s is architecture: arm64\n' "${3:-unknown}"
    ;;
  *)
    printf 'fake-xcrun: unsupported invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH

write_fake nm <<'SH'
#!/usr/bin/env bash
# Fake nm: reads the "object"/"archive" as text and prints the marker lines.
# Markers: !T defined, !U undefined, !BARE symbol without address/type prefix.
# Flag shapes used by the scripts: -g (external), -u (undefined only) and
# -gU (Darwin: defined external symbols only).
only_defined=0
only_undefined=0
input=""
for arg in "$@"; do
  case "$arg" in
    -gU|-U) only_defined=1 ;;
    -g) : ;;
    -u) only_undefined=1 ;;
    -*) : ;;
    *) input="$arg" ;;
  esac
done
[[ -n "$input" && -f "$input" ]] || exit 1
while IFS= read -r line; do
  case "$line" in
    '!T '*)
      [[ "$only_undefined" -eq 1 ]] && continue
      printf '0000000000000000 T %s\n' "${line#'!T '}"
      ;;
    '!U '*)
      [[ "$only_defined" -eq 1 ]] && continue
      printf '                 U %s\n' "${line#'!U '}"
      ;;
    '!BARE '*)
      [[ "$only_defined" -eq 1 ]] && continue
      printf '%s\n' "${line#'!BARE '}"
      ;;
  esac
done < "$input"
exit 0
SH

write_fake fake-clang <<'SH'
#!/usr/bin/env bash
# Fake iOS clang: writes an object containing the 7 table symbols and records
# the full invocation (the harness asserts the documented -target/-O2 flags).
out=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$arg"; fi
  prev="$arg"
done
[[ -n "$out" ]] || { printf 'fake-clang: no -o <object> argument\n' >&2; exit 1; }
{
  printf '!T _recomp_abi\n'
  printf '!T _recomp_generation\n'
  printf '!T _recomp_entry_count\n'
  printf '!T _recomp_entries\n'
  printf '!T _recomp_module_count\n'
  printf '!T _recomp_modules\n'
  printf '!T _recomp_origins\n'
} > "$out"
if [[ -n "${FAKE_CLANG_COUNTER:-}" ]]; then printf '%s\n' "$*" >> "$FAKE_CLANG_COUNTER"; fi
SH

write_fake cargo <<'SH'
#!/usr/bin/env bash
printf 'fake-cargo: cargo must not run in the simulated adoption/reuse paths: %s\n' "$*" >&2
exit 3
SH

write_fake xcodegen <<'SH'
#!/usr/bin/env bash
mkdir -p 3ds2apple.xcodeproj
printf '// fake project generated by aot-sim-harness\n' > 3ds2apple.xcodeproj/project.pbxproj
SH

write_fake xcodebuild <<'SH'
#!/usr/bin/env bash
configuration="Release"
symroot=""
bundle_id=""
display_name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -version) printf 'Xcode 16.4\nBuild version 16F6\n'; exit 0 ;;
    -configuration) configuration="${2:-Release}"; shift 2 ;;
    SYMROOT=*) symroot="${1#SYMROOT=}"; shift ;;
    PRODUCT_BUNDLE_IDENTIFIER=*) bundle_id="${1#*=}"; shift ;;
    INFOPLIST_KEY_CFBundleDisplayName=*) display_name="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$symroot" ]] || symroot="$PWD/build"
app="${symroot}/${configuration}-iphoneos/3ds2apple.app"
mkdir -p "$app"
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<plist version="1.0"><dict>\n'
  printf '<key>CFBundleExecutable</key><string>3ds2apple</string>\n'
  [[ -z "$bundle_id" ]] || printf '<key>CFBundleIdentifier</key><string>%s</string>\n' "$bundle_id"
  [[ -z "$display_name" ]] || printf '<key>CFBundleDisplayName</key><string>%s</string>\n' "$display_name"
  printf '</dict></plist>\n'
} > "$app/Info.plist"
{
  printf '!T _recomp_abi\n'
  printf '!T _recomp_generation\n'
  printf '!T _recomp_entry_count\n'
  printf '!T _recomp_entries\n'
  printf '!T _recomp_module_count\n'
  printf '!T _recomp_modules\n'
  printf '!T _recomp_origins\n'
  printf '!T _zk_linked_code\n'
} > "$app/3ds2apple"
chmod +x "$app/3ds2apple"
SH

write_fake fake-3dsrecomp <<'SH'
#!/usr/bin/env bash
# Fake `3dsrecomp port <rom> <out> --name <name>`: writes the generated-code
# tree the real CLI produces (code/*.c, code/recomp.h, code/librecomp.a and the
# desktop src/main.rs that carries the title ID). No 3dsrecomp code is used.
[[ "${1:-}" == "port" ]] || { printf 'fake-3dsrecomp: only the port subcommand is simulated\n' >&2; exit 1; }
[[ "${CC:-}" == *"-target arm64-apple-ios16.0"* ]] \
  || { printf 'fake-3dsrecomp: CC is not the iOS clang string: %s\n' "${CC:-<unset>}" >&2; exit 1; }
[[ "${AR:-}" == "ar" ]] \
  || { printf 'fake-3dsrecomp: AR is not ar: %s\n' "${AR:-<unset>}" >&2; exit 1; }
out="${3:?fake-3dsrecomp: missing output dir}"
mkdir -p "$out/code" "$out/src"
{
  printf '!T _recomp_abi\n'
  printf '!T _recomp_generation\n'
  printf '!T _recomp_entry_count\n'
  printf '!T _recomp_entries\n'
  printf '!T _recomp_module_count\n'
  printf '!T _recomp_modules\n'
  printf '!T _recomp_origins\n'
} > "$out/code/librecomp.a"
printf 'int code000(void) { return 0; }\n' > "$out/code/code000.c"
printf '#pragma once\n' > "$out/code/recomp.h"
printf 'const PROGRAM_ID: u64 = 0x0004000000055E00;\n' > "$out/src/main.rs"
SH

if ! command -v zip >/dev/null 2>&1; then
  write_fake zip <<'SH'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in *.ipa) out="$arg" ;; esac
done
[[ -n "$out" ]] || { printf 'fake-zip: no .ipa argument\n' >&2; exit 1; }
printf 'fake ipa payload\n' > "$out"
SH
fi

printf 'aot-sim-harness: fake toolchain in %s\n' "$FAKEBIN"
printf 'repo copy: %s\n\n' "$REPO"
RECOMP_SH="${REPO}/scripts/build-recomp-ios.sh"
LINKED_SH="${REPO}/scripts/build-linked-ios-lib.sh"
IPA_SH="${REPO}/scripts/build-game-ipa.sh"

# ---------------------------------------------------------------------------
# 1. adopt an archive built elsewhere; corrupted title ID is repaired
# ---------------------------------------------------------------------------
printf '[1] split build: adopt an archive built elsewhere\n'
FROM_VM="${WORK}/from-vm"
mkdir -p "$FROM_VM"
write_symbol_markers "${FROM_VM}/librecomp.a" T
run_ok "build-recomp-ios.sh --archive" \
  bash "$RECOMP_SH" pokemon-y --archive "${FROM_VM}/librecomp.a" --title-id '0004000000055e00n'
RECOMP_INFO="${REPO}/build/game/pokemon-y/recomp-info.txt"
expect_eq "recomp-info title_id repaired (no trailing n)" '0004000000055E00' \
  "$(info_value "$RECOMP_INFO" title_id)"
expect_eq "recomp-info compile_mode" 'adopted-archive' "$(info_value "$RECOMP_INFO" compile_mode)"
expect_file "librecomp.a collected into build/game" "${REPO}/build/game/pokemon-y/code/librecomp.a"
expect_contains "repair warning printed" 'repaired corrupted title ID' "$LAST_OUTPUT"
if grep -q '0004000000055E00n' "$RECOMP_INFO"; then
  fail "recomp-info.txt has no trailing-garbage title ID"
else
  pass "recomp-info.txt has no trailing-garbage title ID"
fi

# ---------------------------------------------------------------------------
# 2. --reuse without a ROM or 3dsrecomp
# ---------------------------------------------------------------------------
printf '\n[2] recomp --reuse (no ROM, no generation)\n'
run_ok "build-recomp-ios.sh --reuse" bash "$RECOMP_SH" pokemon-y --reuse
expect_eq "reuse compile_mode" 'reuse' "$(info_value "$RECOMP_INFO" compile_mode)"
expect_eq "reuse keeps the clean title ID" '0004000000055E00' \
  "$(info_value "$RECOMP_INFO" title_id)"
expect_eq "reuse title source" 'recomp-info.txt' "$(info_value "$RECOMP_INFO" title_id_source)"

# ---------------------------------------------------------------------------
# 3. linked lib reuse repairs a corrupted build-info.txt (real VM bug)
# ---------------------------------------------------------------------------
printf '\n[3] linked libs --reuse repairs corrupted build-info.txt\n'
LIB_DIR="${REPO}/build/ios/pokemon-y"
BUILD_INFO="${LIB_DIR}/build-info.txt"
mkdir -p "$LIB_DIR"
write_symbol_markers "${LIB_DIR}/libzakuro_ios.a" U
printf 'name=pokemon-y\ntitle_id=0004000000055E00n\nzakuro_rev=deadbee\n' > "$BUILD_INFO"
run_ok "build-linked-ios-lib.sh --reuse" bash "$LINKED_SH" pokemon-y --reuse
expect_eq "build-info title_id repaired" '0004000000055E00' "$(info_value "$BUILD_INFO" title_id)"
expect_eq "build-info reuse flag" '1' "$(info_value "$BUILD_INFO" reuse)"
expect_file "libgame.a collected" "${LIB_DIR}/libgame.a"
expect_contains "repair warning printed" 'repaired corrupted title ID' "$LAST_OUTPUT"

# ---------------------------------------------------------------------------
# 4. nm output shapes: no leading whitespace, prefix decoys, shell library
# ---------------------------------------------------------------------------
printf '\n[4] nm symbol checks\n'
write_symbol_markers "${LIB_DIR}/libzakuro_ios.a" BARE
run_ok "linked --reuse accepts nm lines without leading whitespace" \
  bash "$LINKED_SH" pokemon-y --reuse
expect_eq "build-info still clean after bare-line nm" '0004000000055E00' \
  "$(info_value "$BUILD_INFO" title_id)"

# Interpreter-only shell library: has ordinary undefined symbols but no tables.
printf '!U _malloc\n!U _free\n' > "${LIB_DIR}/libzakuro_ios.a"
run_fail "linked --reuse rejects the interpreter-only shell library" \
  'no undefined _recomp_' bash "$LINKED_SH" pokemon-y --reuse

# Prefix decoy: _recomp_abi_extra must not satisfy _recomp_abi.
{
  for symbol in recomp_generation recomp_entry_count recomp_entries \
    recomp_module_count recomp_modules recomp_origins; do
    printf '!U _%s\n' "$symbol"
  done
  printf '!U _recomp_abi_extra\n'
} > "${LIB_DIR}/libzakuro_ios.a"
run_fail "linked --reuse rejects a _recomp_abi prefix decoy" \
  'missing expected undefined symbols' bash "$LINKED_SH" pokemon-y --reuse
write_symbol_markers "${LIB_DIR}/libzakuro_ios.a" U

# ---------------------------------------------------------------------------
# 5. build-game-ipa.sh: clean manifest, IPA packaged
# ---------------------------------------------------------------------------
printf '\n[5] build-game-ipa.sh manifest correctness\n'
printf 'name=pokemon-y\ntitle_id=0004000000055E00n\nzakuro_rev=deadbee\nrecomp_rev=df82e6e3\n' \
  > "$BUILD_INFO"
run_ok "build-game-ipa.sh (corrupted build-info)" \
  bash "$IPA_SH" pokemon-y --display-name "Pokemon Y"
MANIFEST="${LIB_DIR}/manifest.txt"
expect_eq "manifest title_id is clean" '0004000000055E00' "$(info_value "$MANIFEST" title_id)"
expect_file "IPA packaged" "${REPO}/IPA/pokemon-y-AOT.ipa"
expect_contains "repair warning printed" 'repaired corrupted title ID' "$LAST_OUTPUT"
expect_eq "manifest bundle_id" 'com.kratos.3ds2apple.pokemon-y' \
  "$(info_value "$MANIFEST" bundle_id)"
MANIFEST_SHA="$(info_value "$MANIFEST" ipa_sha256)"
expect_eq "manifest ipa_sha256 is a SHA-256" '64' "${#MANIFEST_SHA}"
if grep -q '0004000000055E00n' "$MANIFEST"; then
  fail "manifest has no trailing-garbage title ID"
else
  pass "manifest has no trailing-garbage title ID"
fi

# ---------------------------------------------------------------------------
# 6. explicit --title-id forms + invalid title IDs
# ---------------------------------------------------------------------------
printf '\n[6] title ID validation\n'
run_ok "build-game-ipa.sh --title-id 0x<lowercase>" \
  bash "$IPA_SH" pokemon-y --title-id '0x0004000000055e00' \
  --ipa-name pokemon-y-aot-normalized --out-dir IPA-normalized
expect_eq "explicit lower-case/0x title ID is normalised in the manifest" \
  '0004000000055E00' "$(info_value "$MANIFEST" title_id)"
run_fail "reject a 15 hex digit title ID" 'could not determine a valid 16 hex digit title ID' \
  bash "$IPA_SH" pokemon-y --title-id 0004000000055E0
run_fail "refuse to truncate an 18 hex digit title ID" \
  'could not determine a valid 16 hex digit title ID' \
  bash "$IPA_SH" pokemon-y --title-id 0004000000055E00FF

# ---------------------------------------------------------------------------
# 7. split build: C generated on Linux -> serial compile -> reuse -> IPA
# ---------------------------------------------------------------------------
printf '\n[7] split build: Linux-generated C -> serial incremental compile\n'
LINUX_OUT="${WORK}/linux-recomp"
mkdir -p "${LINUX_OUT}/code" "${LINUX_OUT}/src"
printf '/* generated by 3dsrecomp on Linux */\nint code000(void) { return 0; }\n' \
  > "${LINUX_OUT}/code/code000.c"
printf 'int code001(void) { return 1; }\n' > "${LINUX_OUT}/code/code001.c"
printf '#pragma once\n' > "${LINUX_OUT}/code/recomp.h"
printf 'const PROGRAM_ID: u64 = 0x0004000000055E00;\n' > "${LINUX_OUT}/src/main.rs"
: > "$FAKE_CLANG_COUNTER"

run_ok "build-recomp-ios.sh --code-dir (serial compile)" \
  bash "$RECOMP_SH" split-game --code-dir "${LINUX_OUT}/code"
SPLIT_INFO="${REPO}/build/game/split-game/recomp-info.txt"
expect_eq "split compile_mode" 'serial' "$(info_value "$SPLIT_INFO" compile_mode)"
expect_eq "split title from generated src/main.rs" '0004000000055E00' \
  "$(info_value "$SPLIT_INFO" title_id)"
expect_file "split archive" "${REPO}/build/game/split-game/code/librecomp.a"
SPLIT_FIRST_CALLS="$(wc -l < "$FAKE_CLANG_COUNTER" | tr -d '[:space:]')"
expect_eq "split first run compiled 2 objects" '2' "$SPLIT_FIRST_CALLS"
CLANG_ARGS="$(cat "$FAKE_CLANG_COUNTER")"
expect_contains "serial compile passes -target arm64-apple-ios16.0" \
  '-target arm64-apple-ios16.0' "$CLANG_ARGS"
expect_contains "serial compile passes the documented -O2 flags" \
  '-O2 -ffp-contract=off -fno-math-errno' "$CLANG_ARGS"

run_ok "build-recomp-ios.sh --code-dir (incremental re-run)" \
  bash "$RECOMP_SH" split-game --code-dir "${LINUX_OUT}/code"
expect_eq "split re-run compile_mode" 'serial-incremental' "$(info_value "$SPLIT_INFO" compile_mode)"
SPLIT_SECOND_CALLS="$(wc -l < "$FAKE_CLANG_COUNTER" | tr -d '[:space:]')"
expect_eq "split re-run did not invoke clang" "$SPLIT_FIRST_CALLS" "$SPLIT_SECOND_CALLS"

run_ok "build-recomp-ios.sh --code-dir --force" \
  bash "$RECOMP_SH" split-game --code-dir "${LINUX_OUT}/code" --force
expect_eq "split --force compile_mode" 'serial' "$(info_value "$SPLIT_INFO" compile_mode)"
SPLIT_FORCED_CALLS="$(wc -l < "$FAKE_CLANG_COUNTER" | tr -d '[:space:]')"
expect_eq "split --force recompiled both objects" \
  "$((SPLIT_SECOND_CALLS + 2))" "$SPLIT_FORCED_CALLS"

run_ok "build-recomp-ios.sh --reuse on the split archive" \
  bash "$RECOMP_SH" split-game --reuse
expect_eq "split reuse compile_mode" 'reuse' "$(info_value "$SPLIT_INFO" compile_mode)"

# --serial-compile alone must not clone/build 3dsrecomp (no cargo/git needed).
run_ok "build-recomp-ios.sh --serial-compile without 3dsrecomp" \
  bash "$RECOMP_SH" split-game --serial-compile
expect_eq "--serial-compile compile_mode" 'serial-incremental' \
  "$(info_value "$SPLIT_INFO" compile_mode)"
if [[ -e "${REPO}/third_party/3dsrecomp" ]]; then
  fail "--serial-compile did not clone 3dsrecomp"
else
  pass "--serial-compile did not clone 3dsrecomp"
fi

# linked libs can be adopted without cargo, then packaged without a ROM.
mkdir -p "${REPO}/build/ios/split-game"
write_symbol_markers "${REPO}/build/ios/split-game/libzakuro_ios.a" U
run_ok "build-linked-ios-lib.sh --reuse (split libs, no cargo)" \
  bash "$LINKED_SH" split-game --reuse
expect_eq "split build-info title_id" '0004000000055E00' \
  "$(info_value "${REPO}/build/ios/split-game/build-info.txt" title_id)"
run_ok "build-game-ipa.sh from the split libs" bash "$IPA_SH" split-game
expect_eq "split manifest title_id" '0004000000055E00' \
  "$(info_value "${REPO}/build/ios/split-game/manifest.txt" title_id)"
expect_file "split IPA packaged" "${REPO}/IPA/split-game-AOT.ipa"

# ---------------------------------------------------------------------------
# 8. fresh port path (prebuilt CLI, derived name, title from src/main.rs)
# ---------------------------------------------------------------------------
printf '\n[8] fresh port path (--recomp-bin)\n'
mkdir -p "${WORK}/rom"
printf 'fake user-owned ROM (never a real game dump)\n' > "${WORK}/rom/Fresh Game.cci"
run_ok "build-recomp-ios.sh with a prebuilt 3dsrecomp CLI" \
  bash "$RECOMP_SH" "${WORK}/rom/Fresh Game.cci" --recomp-bin "${FAKEBIN}/fake-3dsrecomp"
FRESH_INFO="${REPO}/build/game/fresh-game/recomp-info.txt"
expect_file "fresh port archive" "${REPO}/build/game/fresh-game/code/librecomp.a"
expect_eq "fresh port derived game name" 'Fresh Game.cci' \
  "$(info_value "$FRESH_INFO" rom_basename)"
expect_eq "fresh port title from generated src/main.rs" '0004000000055E00' \
  "$(info_value "$FRESH_INFO" title_id)"
expect_eq "fresh port title source" 'src/main.rs' "$(info_value "$FRESH_INFO" title_id_source)"
expect_eq "fresh port compile_mode" 'port' "$(info_value "$FRESH_INFO" compile_mode)"
expect_eq "fresh port recomp_rev for a prebuilt CLI" 'prebuilt' \
  "$(info_value "$FRESH_INFO" recomp_rev)"

# ---------------------------------------------------------------------------
# 9. loud failures
# ---------------------------------------------------------------------------
printf '\n[9] loud failures\n'
run_fail "recomp rejects a missing ROM without an adoption flag" 'ROM not found' \
  bash "$RECOMP_SH" "${WORK}/missing.3ds" ghost
run_fail "recomp rejects --archive combined with --code-dir" 'cannot be combined' \
  bash "$RECOMP_SH" pokemon-y --archive "${FROM_VM}/librecomp.a" --code-dir "${LINUX_OUT}/code"
run_fail "game-ipa rejects a path traversal name" 'invalid game name' \
  bash "$IPA_SH" ../etc

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
printf '\naot-sim-harness: %s checks, %s failure(s)\n' "$CHECKS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
