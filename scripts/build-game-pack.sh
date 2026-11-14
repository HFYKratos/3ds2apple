#!/usr/bin/env bash
# build-game-pack.sh - build or adopt one per-game AOT GamePack package.
#
# Desktop AOT-first flow (docs/desktop-aot.md):
#
#   scripts/build-recomp-ios.sh <rom> <name>     # 3dsrecomp -> generated C
#   scripts/build-game-pack.sh <name> --code-dir build/game/<name> \
#       --title-id <id> --out out                # GamePack-<TID>.dylib + GameInfo.json
#
#   (the single-game linked path remains: build-linked-ios-lib.sh, then
#    build-game-pack.sh --from-libs --lib-dir build/ios/<name>)
#
# Real mode (macOS): links the generated 3dsrecomp archive (libgame.a) plus the
# GamePack shim (ios/zakuro-ios/gamepack/zk_gamepack_shim.c) into a dylib that
# exports GamePack C ABI v1 (ios/zakuro-ios/include/zakuro_gamepack.h), and
# records the package through the Rust desktop CLI (the single schema writer).
#
# --target sim builds the same pack for the iOS Simulator (x86_64 on this build
# VM, docs/build-simulator.md), leaving the runtime host API for the app to
# resolve at dlopen time; --no-record skips the desktop CLI and writes
# GamePack.dylib only (the simulator shell builder writes its own catalogue).
#
# Fake/preview mode (Linux/Windows/macOS): --fake records a deterministic
# placeholder pack; layout tests and previews only, never installable.
#
# --dry-run validates the inputs and prints what would happen without writing
# anything. --selfcheck exercises the shim and the pack link without a ROM or a
# generated archive (host run plus Mach-O link/export checks).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/aot-common.sh
source "$SCRIPT_DIR/lib/aot-common.sh"
# shellcheck source=lib/desktop-aot.sh
source "$SCRIPT_DIR/lib/desktop-aot.sh"

NAME_ARG=""
TITLE_ARG=""
DISPLAY_ARG=""
PRODUCT_ARG=""
AOT_VERSION_ARG="1"
OUT_ARG="out"
LIB_DIR_ARG=""
DYLIB_ARG=""
CODE_DIR_ARG=""
TARGET_ARG="device"
JOBS_ARG=""
SHIM_ARG=""
FROM_LIBS=0
FAKE=0
DRY_RUN=0
NO_RECORD=0
SELFCHECK=0
PACK_BIN_ARG=""
ROM_ARG=""
INCLUDE_ROM=0
ALLOW_NON_GAMEPACK=0
INCLUDE_ROM_FLAG=""
WORK=""

usage() {
  cat <<'EOF'
Build or adopt one per-game AOT GamePack package.

Usage:
  scripts/build-game-pack.sh <name> --title-id <TITLE_ID> [options]

Arguments:
  <name>             Game build name used by build-recomp-ios.sh
                     ([A-Za-z0-9._-]; e.g. pokemon-y)

Options:
  --title-id ID      16 hex digit application title ID (00040000...)
  --display-name T   Display name recorded in GameInfo.json (default: <name>)
  --product-code C   Product code, e.g. CTR-P-EK2A (default: empty)
  --aot-version N    AOT pack version recorded in GameInfo.json (default: 1)
  --out DIR          Output root; the package goes to DIR/packages/<TITLE_ID>/
                     (default: out)
  --rom FILE         ROM provenance to record (optional, must match the title)
  --include-rom      Copy --rom FILE into the package as GameRom.<ext> and
                     record romFile/romSha256/romBytes, so the package is
                     self-contained (the phone never imports game data). It is
                     wired through --fake/--dry-run previews too, so a preview
                     package has the same shape as the real one.
  --target KIND      device (arm64-apple-ios16.0, default) or sim
                     (x86_64-apple-ios16.0-simulator on this build VM), or a
                     full clang target triple
  --jobs N           Parallel compile jobs for --code-dir (default: CPU count,
                     capped at 8)

Pack source (exactly one of):
  --code-dir DIR     Compile 3dsrecomp-generated C in DIR for the target, then
                     link one GamePack.dylib from it (macOS only)
  --from-libs        Link DIR/libgame.a into a dylib (macOS only; the archive
                     from build-linked-ios-lib.sh)
  --dylib FILE       Adopt an already-built Mach-O GamePack.dylib
  --fake             Write a deterministic placeholder pack (preview/tests)
  --dry-run          Validate and print the plan; write nothing

Other:
  --lib-dir DIR      Per-game lib dir for --from-libs (default: build/ios/<name>)
  --shim FILE        GamePack shim C source (default:
                     ios/zakuro-ios/gamepack/zk_gamepack_shim.c)
  --no-record        Skip the Rust pack CLI; write <out>/packages/<TITLE_ID>/
                     GamePack.dylib only (used by the simulator shell builder)
  --pack-bin PATH    Desktop CLI binary (default: builder/target/release,
                     builder/target/debug, PATH, or $THREEDS2APPLE_PACK)
  --allow-non-gamepack  Adopt a --dylib that is not a GamePack (missing ABI
                     exports / wrong slice); preview tooling only
  --selfcheck        Run the GamePack shim/link self-check and exit
  -h, --help         Show this help and exit

The GameInfo.json manifest (and the catalogue later) is written by the Rust
desktop CLI so there is exactly one schema writer. --no-record is for the
Simulator proof build only, which embeds the dylib and writes its own catalogue.

Exit status: 0 on success, non-zero on failure.
EOF
}

log() { printf '[build-game-pack] %s\n' "$*"; }
warn() { printf '[build-game-pack] warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$ROOT/$1" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title-id) [[ $# -ge 2 ]] || die "--title-id requires a value"; TITLE_ARG="$2"; shift 2 ;;
    --display-name) [[ $# -ge 2 ]] || die "--display-name requires a value"; DISPLAY_ARG="$2"; shift 2 ;;
    --product-code) [[ $# -ge 2 ]] || die "--product-code requires a value"; PRODUCT_ARG="$2"; shift 2 ;;
    --aot-version) [[ $# -ge 2 ]] || die "--aot-version requires a value"; AOT_VERSION_ARG="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out requires a value"; OUT_ARG="$2"; shift 2 ;;
    --rom) [[ $# -ge 2 ]] || die "--rom requires a value"; ROM_ARG="$2"; shift 2 ;;
    --include-rom) INCLUDE_ROM=1; shift ;;
    --allow-non-gamepack) ALLOW_NON_GAMEPACK=1; shift ;;
    --lib-dir) [[ $# -ge 2 ]] || die "--lib-dir requires a value"; LIB_DIR_ARG="$2"; shift 2 ;;
    --code-dir) [[ $# -ge 2 ]] || die "--code-dir requires a value"; CODE_DIR_ARG="$2"; shift 2 ;;
    --target) [[ $# -ge 2 ]] || die "--target requires a value"; TARGET_ARG="$2"; shift 2 ;;
    --jobs) [[ $# -ge 2 ]] || die "--jobs requires a value"; JOBS_ARG="$2"; shift 2 ;;
    --shim) [[ $# -ge 2 ]] || die "--shim requires a value"; SHIM_ARG="$2"; shift 2 ;;
    --dylib) [[ $# -ge 2 ]] || die "--dylib requires a value"; DYLIB_ARG="$2"; shift 2 ;;
    --from-libs) FROM_LIBS=1; shift ;;
    --fake) FAKE=1; shift ;;
    --no-record) NO_RECORD=1; shift ;;
    --selfcheck) SELFCHECK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --pack-bin) [[ $# -ge 2 ]] || die "--pack-bin requires a value"; PACK_BIN_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "$NAME_ARG" ]]; then NAME_ARG="$1"; else die "unexpected argument: $1 (try --help)"; fi
      shift ;;
  esac
done

cleanup() {
  if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi
}
trap cleanup EXIT

# --- target ------------------------------------------------------------------
case "$TARGET_ARG" in
  ''|device|ios) TRIPLE="arm64-apple-ios16.0"; SDK_NAME="iphoneos" ;;
  sim|simulator) TRIPLE="x86_64-apple-ios16.0-simulator"; SDK_NAME="iphonesimulator" ;;
  *simulator*) TRIPLE="$TARGET_ARG"; SDK_NAME="iphonesimulator" ;;
  *) TRIPLE="$TARGET_ARG"; SDK_NAME="iphoneos" ;;
esac

if [[ -n "$SHIM_ARG" ]]; then SHIM_SRC="$(resolve_path "$SHIM_ARG")"; else SHIM_SRC="$ROOT/ios/zakuro-ios/gamepack/zk_gamepack_shim.c"; fi
SHIM_DIR="$(dirname "$SHIM_SRC")"
INCLUDE_DIR="$(cd "$SHIM_DIR/../include" && pwd)"
WORK_ROOT=/tmp
if [[ -n "${TMPDIR:-}" ]]; then WORK_ROOT="$TMPDIR"; fi

# --- self-check --------------------------------------------------------------
if [[ "$SELFCHECK" -eq 1 ]]; then
  [[ "$(uname -s)" == "Darwin" ]] || die "--selfcheck needs macOS with Xcode clang (Mach-O output)"
  [[ -f "$SHIM_SRC" ]] || die "GamePack shim not found: $SHIM_SRC"
  command -v clang >/dev/null 2>&1 || die "clang not found (install the Xcode command line tools)"
  WORK="$(mktemp -d "$WORK_ROOT/3ds2apple-gamepack-selfcheck.XXXXXX")"
  CHECKS=0
  FAILURES=0
  sc_pass() { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$1"; }
  sc_fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '  FAIL %s\n' "$1" >&2; }

  cat > "$WORK/tables.c" <<'C'
#include <stdint.h>
/* stand-ins for the seven 3dsrecomp tables the shim references */
const uint32_t recomp_abi = 5;
const uint32_t recomp_generation = 7;
const uint32_t recomp_entry_count = 1;
const unsigned char recomp_entries[8] = { 0 };
const uint32_t recomp_module_count = 1;
const unsigned char recomp_modules[16] = { 0 };
const unsigned char recomp_origins[16] = { 0 };
C
  cat > "$WORK/host.c" <<'C'
#include <stdint.h>
#include <stdio.h>
#include "zakuro_gamepack.h"

static int failures = 0;
#define CHECK(cond, label) do { \
    if (cond) printf("  ok   %s\n", label); \
    else { printf("  FAIL %s\n", label); failures++; } \
} while (0)

static int calls = 0;
static uint64_t seen_title = 0;
static uint32_t seen_recomp_abi = 0;
static uint32_t seen_generation = 0;
static uint32_t seen_entries = 0;
static uint32_t seen_modules = 0;
static const void *seen_entries_ptr = 0;

int32_t zk_register_gamepack(uint64_t title_id, uint32_t recomp_abi, uint32_t generation,
                             const void *entries, uint32_t entry_count,
                             const void *modules, uint32_t module_count,
                             const void *origins) {
    calls++;
    seen_title = title_id;
    seen_recomp_abi = recomp_abi;
    seen_generation = generation;
    seen_entries = entry_count;
    seen_modules = module_count;
    seen_entries_ptr = entries;
    (void)modules;
    (void)origins;
    return 0;
}

int main(void) {
    CHECK(zk_gamepack_title_id() == 0x0004000000055E00ULL, "pack reports its title id");
    CHECK(zk_gamepack_abi_version() == ZK_GAMEPACK_ABI_VERSION, "pack reports the host ABI");
    CHECK(zk_gamepack_register(ZK_GAMEPACK_ABI_VERSION) == 0, "register accepts the host ABI");
    CHECK(calls == 1, "register forwards one host call");
    CHECK(seen_title == 0x0004000000055E00ULL, "host sees the title id");
    CHECK(seen_recomp_abi == 5, "host sees the recomp interface ABI");
    CHECK(seen_generation == 7, "host sees the generation");
    CHECK(seen_entries == 1 && seen_modules == 1, "host sees the table sizes");
    CHECK(seen_entries_ptr != 0, "host sees the entries pointer");
    CHECK(zk_gamepack_register(ZK_GAMEPACK_ABI_VERSION + 1) != 0, "register rejects another ABI");
    CHECK(calls == 1, "a rejected host does not forward");
    printf("  host-check: %d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
C

  printf 'GamePack shim self-check\n'
  if ! clang -O1 -Wall -Wextra -Werror -I "$INCLUDE_DIR" \
        -DZK_GAMEPACK_TITLE_ID=0x0004000000055E00ULL \
        "$WORK/tables.c" "$WORK/host.c" "$SHIM_SRC" -o "$WORK/host-check" >"$WORK/host-build.log" 2>&1; then
    cat "$WORK/host-build.log" >&2
    die "self-check host program did not compile"
  fi
  "$WORK/host-check" || die "self-check host program failed"
  CHECKS=$((CHECKS + 11))

  check_target() { # label triple sdk
    label="$1"; triple="$2"; sdk="$3"
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null || true)"
    if [[ -z "$sdk_path" ]]; then
      printf '  skip %s (%s SDK not installed)\n' "$label" "$sdk"
      return 0
    fi
    shim_obj="$WORK/shim-$label.o"
    dylib="$WORK/GamePack-$label.dylib"
    if ! clang -target "$triple" -isysroot "$sdk_path" -O2 -fPIC -I "$INCLUDE_DIR" \
          -DZK_GAMEPACK_TITLE_ID=0x0004000000055E00ULL -c "$SHIM_SRC" -o "$shim_obj" \
          >"$WORK/shim-$label.log" 2>&1; then
      cat "$WORK/shim-$label.log" >&2
      sc_fail "$label: shim compiles"
      return 0
    fi
    sc_pass "$label: shim compiles"
    if ! clang -dynamiclib -target "$triple" -isysroot "$sdk_path" -o "$dylib" \
          "$shim_obj" "$WORK/tables-$label.o" -Wl,-undefined,dynamic_lookup \
          >"$WORK/link-$label.log" 2>&1; then
      cat "$WORK/link-$label.log" >&2
      sc_fail "$label: pack links as a dylib"
      return 0
    fi
    sc_pass "$label: pack links as a dylib"
    if desktop_aot_pack_is_macho "$dylib"; then sc_pass "$label: output is a Mach-O dylib"; else
      sc_fail "$label: output is a Mach-O dylib"; fi
    defined="$WORK/defined-$label.txt"
    undefined="$WORK/undefined-$label.txt"
    nm -gU "$dylib" >"$defined" 2>/dev/null || nm -g "$dylib" >"$defined" 2>/dev/null || true
    nm -u "$dylib" >"$undefined" 2>/dev/null || true
    missing=""
    for symbol in _zk_gamepack_title_id _zk_gamepack_abi_version _zk_gamepack_register \
                  _recomp_abi _recomp_generation _recomp_entry_count _recomp_entries \
                  _recomp_module_count _recomp_modules _recomp_origins; do
      aot_nm_has_symbol "$defined" "$symbol" || missing="$missing $symbol"
    done
    if [[ -z "$missing" ]]; then sc_pass "$label: exports the GamePack ABI and recomp tables"; else
      sc_fail "$label: missing exports:$missing"; fi
    if aot_nm_has_symbol "$undefined" _zk_register_gamepack; then
      sc_pass "$label: host runtime API stays undefined (the app resolves it)"; else
      sc_fail "$label: host runtime API stays undefined (the app resolves it)"; fi
    if aot_nm_has_symbol "$defined" _zk_create; then
      sc_fail "$label: pack must not carry the Zakuro runtime"; else
      sc_pass "$label: pack does not carry the Zakuro runtime"; fi
  }

  for spec in "device arm64-apple-ios16.0 iphoneos" "sim x86_64-apple-ios16.0-simulator iphonesimulator"; do
    set -- $spec
    label="$1"; triple="$2"; sdk="$3"
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null || true)"
    if [[ -z "$sdk_path" ]]; then
      printf '  skip %s (%s SDK not installed)\n' "$label" "$sdk"
      continue
    fi
    clang -target "$triple" -isysroot "$sdk_path" -O2 -fPIC -c "$WORK/tables.c" \
          -o "$WORK/tables-$label.o" >"$WORK/tables-$label.log" 2>&1 || {
      cat "$WORK/tables-$label.log" >&2; sc_fail "$label: stand-in tables compile"; continue; }
    check_target "$label" "$triple" "$sdk"
  done

  printf 'selfcheck: %d checks, %d failure(s)\n' "$CHECKS" "$FAILURES"
  [[ "$FAILURES" -eq 0 ]] || die "self-check failures: $FAILURES"
  log "self-check passed"
  exit 0
fi

# --- argument validation -----------------------------------------------------
[[ -n "$NAME_ARG" ]] || die "missing <name> argument (try --help)"
[[ -n "$TITLE_ARG" ]] || die "missing --title-id (16 hex digits, e.g. 0004000000055E00)"
aot_is_valid_name "$NAME_ARG" \
  || die "invalid game name: '$NAME_ARG' (use letters, digits, '.', '_', '-')"

TITLE_ID="$(printf '%s' "$TITLE_ARG" | tr '[:lower:]' '[:upper:]')"
case "$TITLE_ID" in
  *[!0-9A-F]*) die "invalid --title-id '$TITLE_ARG' (16 hex digits expected)" ;;
esac
TITLE_LEN="$(printf '%s' "$TITLE_ID" | wc -c | tr -d '[:space:]')"
[[ "$TITLE_LEN" -eq 16 ]] || die "invalid --title-id '$TITLE_ARG' (16 hex digits expected)"
case "$TITLE_ID" in
  00040000*) ;;
  *) die "title ID $TITLE_ID is not an application title (expected the 00040000 high word)" ;;
esac

if [[ -n "$DISPLAY_ARG" ]]; then DISPLAY_NAME="$DISPLAY_ARG"; else DISPLAY_NAME="$NAME_ARG"; fi
[[ -n "$DISPLAY_NAME" ]] || die "--display-name must not be empty"
case "$DISPLAY_NAME" in
  *$'\n'*|*$'\r'*) die "--display-name must be a single line" ;;
esac
PRODUCT_CODE="$PRODUCT_ARG"
case "$AOT_VERSION_ARG" in
  ''|*[!0-9]*) die "--aot-version must be a positive integer" ;;
esac
[[ "$AOT_VERSION_ARG" -ge 1 ]] || die "--aot-version must be >= 1"

[[ -f "$SHIM_SRC" ]] || die "GamePack shim not found: $SHIM_SRC"

JOB_COUNT="$JOBS_ARG"
if [[ -z "$JOB_COUNT" ]]; then
  if command -v sysctl >/dev/null 2>&1; then JOB_COUNT="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"; else JOB_COUNT=4; fi
fi
case "$JOB_COUNT" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[[ "$JOB_COUNT" -ge 1 ]] || die "--jobs must be >= 1"
[[ "$JOB_COUNT" -le 8 ]] || JOB_COUNT=8

if [[ "$INCLUDE_ROM" -eq 1 && -z "$ROM_ARG" ]]; then
  die "--include-rom requires --rom FILE (the ROM to copy into the package)"
fi
if [[ "$INCLUDE_ROM" -eq 1 ]]; then INCLUDE_ROM_FLAG="--include-rom"; fi

OUT_ROOT="$(resolve_path "$OUT_ARG")"
mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
PACKAGE_DIR="$OUT_ROOT/packages/$TITLE_ID"

# Exactly one pack source.
SOURCE_COUNT=$(( FROM_LIBS + FAKE ))
if [[ -n "$DYLIB_ARG" ]]; then SOURCE_COUNT=$((SOURCE_COUNT + 1)); fi
if [[ -n "$CODE_DIR_ARG" ]]; then SOURCE_COUNT=$((SOURCE_COUNT + 1)); fi
if [[ "$DRY_RUN" -eq 0 && "$SELFCHECK" -eq 0 ]]; then
  if [[ "$SOURCE_COUNT" -eq 0 ]]; then
    die "choose a pack source: --code-dir DIR, --from-libs, --dylib FILE, or --fake (or --dry-run)"
  elif [[ "$SOURCE_COUNT" -gt 1 ]]; then
    die "choose exactly one of --code-dir, --from-libs, --dylib, --fake"
  fi
fi
if [[ "$NO_RECORD" -eq 1 && "$FAKE" -eq 1 ]]; then
  die "--no-record cannot be combined with --fake (the CLI is what writes the placeholder)"
fi

NEED_BUILD=0
if [[ "$FROM_LIBS" -eq 1 || -n "$CODE_DIR_ARG" ]]; then NEED_BUILD=1; fi
if [[ "$NEED_BUILD" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
  [[ "$(uname -s)" == "Darwin" ]] \
    || die "--code-dir/--from-libs need macOS with Xcode clang; on Linux/Windows use --fake for a preview package"
  command -v clang >/dev/null 2>&1 || die "clang not found (install the Xcode command line tools)"
  CC_BIN="$(xcrun --sdk "$SDK_NAME" -f clang 2>/dev/null)" \
    || die "cannot locate the $SDK_NAME SDK clang (xcrun -f clang failed)"
  SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path 2>/dev/null)" \
    || die "cannot locate the $SDK_NAME SDK (xcrun --show-sdk-path failed)"
  [[ -n "$CC_BIN" && -x "$CC_BIN" ]] || die "SDK clang is not executable: $CC_BIN"
  [[ -n "$SDK_PATH" && -d "$SDK_PATH" ]] || die "SDK path is not a directory: $SDK_PATH"
  case "$SDK_PATH" in *" "*) die "the SDK path contains spaces: '$SDK_PATH'" ;; esac
  WORK="$(mktemp -d "$WORK_ROOT/3ds2apple-gamepack.XXXXXX")"
  LOG_FILE="$WORK/build.log"
  : > "$LOG_FILE"
fi

PACK_BIN=""
if [[ "$DRY_RUN" -eq 0 && "$NO_RECORD" -eq 0 ]]; then
  PACK_BIN="$(desktop_aot_find_pack_bin "$ROOT" "$PACK_BIN_ARG")" \
    || die "3ds2apple-pack binary not found ($(desktop_aot_pack_bin_hint))"
  log "pack CLI: $PACK_BIN"
fi

# --- compile generated C for the target (--code-dir) -------------------------
compile_game_code() { # dir -> prints archive path
  dir="$1"
  [[ -d "$dir" ]] || die "--code-dir is not a directory: $dir"
  set -- "$dir"/*.c
  [[ -e "$1" ]] || die "--code-dir has no generated C files: $dir"
  FILE_COUNT="$(printf '%s\n' "$@" | wc -l | tr -d '[:space:]')"
  # stdout belongs to the caller: it captures the archive path. Log lines go to
  # stderr so a captured multi-line logging message can never become the archive
  # path (2026-11-14: did exactly that and clang tried to link a log line).
  printf '[build-game-pack] compiling %s generated C files for %s with %s jobs\n' \
    "$FILE_COUNT" "$TRIPLE" "$JOB_COUNT" >&2
  wrapper="$WORK/compile-one.sh"
  cat > "$wrapper" <<'SH'
#!/bin/sh
# args: cc target sdk dir log src
set -eu
cc="$1"; target="$2"; sdk="$3"; dir="$4"; log="$5"; src="$6"
cd "$dir"
obj="$(echo "$src" | sed 's/\.c$/.o/')"
# Incremental like build-recomp-ios.sh: an object newer than its source is reused,
# so a re-run (or a link-only fix) does not recompile hundreds of files.
if [ -f "$obj" ] && [ "$obj" -nt "$src" ]; then
  exit 0
fi
"$cc" -target "$target" -isysroot "$sdk" -O2 -ffp-contract=off -fno-math-errno -w \
  -fPIC -fvisibility=hidden -I. -c "$src" -o "$obj" >>"$log" 2>&1
SH
  chmod +x "$wrapper"
  ( cd "$dir" && ls *.c | xargs -P "$JOB_COUNT" -n 1 \
      "$wrapper" "$CC_BIN" "$TRIPLE" "$SDK_PATH" "$dir" "$LOG_FILE" ) \
    || { tail -n 40 "$LOG_FILE" >&2; die "generated C did not compile; full log: $LOG_FILE"; }
  printf '[build-game-pack] archiving objects\n' >&2
  ( cd "$dir" && rm -f librecomp.a && ar rcs librecomp.a ./*.o ) >>"$LOG_FILE" 2>&1 \
    || die "ar failed while creating $dir/librecomp.a; full log: $LOG_FILE"
  printf '%s\n' "$dir/librecomp.a"
}

# --- link one GamePack.dylib -------------------------------------------------
link_game_pack() { # libgame-archive out-dylib
  libgame="$1"; out="$2"
  shim_obj="$WORK/zk_gamepack_shim.o"
  log "compiling the GamePack shim for $TRIPLE"
  "$CC_BIN" -target "$TRIPLE" -isysroot "$SDK_PATH" -O2 -fPIC \
    -I "$INCLUDE_DIR" -DZK_GAMEPACK_TITLE_ID="0x$TITLE_ID""ULL" \
    -c "$SHIM_SRC" -o "$shim_obj" >>"$LOG_FILE" 2>&1 \
    || { tail -n 40 "$LOG_FILE" >&2; die "the GamePack shim did not compile"; }
  log "linking GamePack.dylib from $(basename "$libgame")"
  clang -dynamiclib -target "$TRIPLE" -isysroot "$SDK_PATH" -o "$out" \
    "$shim_obj" "$libgame" \
    -Wl,-undefined,dynamic_lookup \
    -Wl,-install_name,"@rpath/GamePack-$TITLE_ID.dylib" \
    -Wl,-dead_strip >>"$LOG_FILE" 2>&1 \
    || { tail -n 40 "$LOG_FILE" >&2; die "clang could not link GamePack.dylib (see docs/desktop-aot.md)"; }
  desktop_aot_pack_is_macho "$out" || die "clang produced a non-Mach-O file: $out"
}

# The pack must export the GamePack ABI and carry the recomp tables, refer to
# the host runtime (not carry it), and leave the host API for the app.
validate_game_pack() { # dylib
  dylib="$1"
  defined="$WORK/defined.txt"
  undefined="$WORK/undefined.txt"
  missing=""
  nm -gU "$dylib" >"$defined" 2>/dev/null || nm -g "$dylib" >"$defined" 2>/dev/null || true
  nm -u "$dylib" >"$undefined" 2>/dev/null || true
  for symbol in _zk_gamepack_title_id _zk_gamepack_abi_version _zk_gamepack_register \
                _recomp_abi _recomp_generation _recomp_entry_count _recomp_entries \
                _recomp_module_count _recomp_modules _recomp_origins; do
    aot_nm_has_symbol "$defined" "$symbol" || missing="$missing $symbol"
  done
  [[ -z "$missing" ]] || die "GamePack.dylib is missing required exports:$missing
       Build it with scripts/build-game-pack.sh (the shim implements the pack ABI)."
  aot_nm_has_symbol "$undefined" _zk_register_gamepack \
    || die "GamePack.dylib does not reference the host runtime API _zk_register_gamepack"
  if aot_nm_has_symbol "$defined" _zk_create; then
    die "GamePack.dylib carries the Zakuro runtime (_zk_create); link only the game archive"
  fi
}

TMP_DYLIB=""
if [[ -n "$DYLIB_ARG" ]]; then
  DYLIB="$(resolve_path "$DYLIB_ARG")"
  [[ -f "$DYLIB" ]] || die "dylib not found: $DYLIB"
  desktop_aot_pack_is_macho "$DYLIB" \
    || die "not a Mach-O dylib: $DYLIB ($TRIPLE Mach-O expected)"
  log "adopting dylib: $DYLIB ($(desktop_aot_file_bytes "$DYLIB") bytes, sha256 $(desktop_aot_sha256 "$DYLIB"))"
  if ! desktop_aot_pack_matches_target "$DYLIB" "$TRIPLE"; then
    if [[ "$ALLOW_NON_GAMEPACK" -eq 1 ]]; then
      warn "adopted dylib slice ($(desktop_aot_pack_arch "$DYLIB" 2>/dev/null || echo unknown)) does not match the requested target ($TRIPLE); --allow-non-gamepack"
    else
      die "adopted dylib is not a $TRIPLE Mach-O (slice: $(desktop_aot_pack_arch "$DYLIB" 2>/dev/null || echo unknown)); pass a --target matching the dylib, or --allow-non-gamepack for preview tooling"
    fi
  fi
  if ! desktop_aot_pack_exports_gamepack "$DYLIB"; then
    if [[ "$ALLOW_NON_GAMEPACK" -eq 1 ]]; then
      warn "adopted dylib does not export the GamePack ABI; the shell will refuse it (--allow-non-gamepack)"
    else
      die "adopted dylib does not export the required GamePack ABI (zk_gamepack_title_id / zk_gamepack_abi_version / zk_gamepack_register); pass --allow-non-gamepack to adopt a non-GamePack dylib for preview tooling"
    fi
  fi
elif [[ "$FROM_LIBS" -eq 1 || -n "$CODE_DIR_ARG" ]]; then
  if [[ "$DRY_RUN" -eq 0 ]]; then
    LIBGAME=""
    if [[ -n "$CODE_DIR_ARG" ]]; then
      LIBGAME="$(compile_game_code "$(resolve_path "$CODE_DIR_ARG")")"
    else
      if [[ -n "$LIB_DIR_ARG" ]]; then LIB_DIR="$(resolve_path "$LIB_DIR_ARG")"; else LIB_DIR="$ROOT/build/ios/$NAME_ARG"; fi
      LIBGAME="$LIB_DIR/libgame.a"
      [[ -f "$LIBGAME" ]] \
        || die "missing $LIBGAME (run scripts/build-recomp-ios.sh, or use --code-dir DIR with the generated C)"
      if [[ -f "$LIB_DIR/libzakuro_ios.a" ]]; then
        log "ignoring the per-game linked runtime: a GamePack carries the game's code only and resolves the runtime from the host app"
      fi
    fi
    TMP_DYLIB="$WORK/GamePack.dylib"
    link_game_pack "$LIBGAME" "$TMP_DYLIB"
    validate_game_pack "$TMP_DYLIB"
    log "linked dylib: $TMP_DYLIB ($(desktop_aot_file_bytes "$TMP_DYLIB") bytes, sha256 $(desktop_aot_sha256 "$TMP_DYLIB"))"
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run: no files written"
  printf 'name=%s\n' "$NAME_ARG"
  printf 'title_id=%s\n' "$TITLE_ID"
  printf 'display_name=%s\n' "$DISPLAY_NAME"
  printf 'product_code=%s\n' "$PRODUCT_CODE"
  printf 'aot_version=%s\n' "$AOT_VERSION_ARG"
  printf 'target=%s\n' "$TRIPLE"
  printf 'sdk=%s\n' "$SDK_NAME"
  printf 'out_root=%s\n' "$OUT_ROOT"
  printf 'package_dir=%s\n' "$PACKAGE_DIR"
  if [[ -n "$DYLIB_ARG" ]]; then printf 'source=dylib:%s\n' "$(resolve_path "$DYLIB_ARG")"; fi
  if [[ "$FROM_LIBS" -eq 1 ]]; then printf 'source=from_libs:%s\n' "$LIB_DIR_ARG"; fi
  if [[ -n "$CODE_DIR_ARG" ]]; then printf 'source=code_dir:%s\n' "$(resolve_path "$CODE_DIR_ARG")"; fi
  if [[ "$FAKE" -eq 1 ]]; then printf 'source=fake_placeholder\n'; fi
  if [[ "$NO_RECORD" -eq 1 ]]; then printf 'record=no\n'; fi
  if [[ "$INCLUDE_ROM" -eq 1 ]]; then printf 'include_rom=yes\n'; fi
  exit 0
fi

if [[ "$NO_RECORD" -eq 1 ]]; then
  # Simulator proof build: the catalogue and the app bundle are assembled by
  # scripts/build-ios-app-sim.sh; no GameInfo.json is written here.
  source_dylib="$TMP_DYLIB"
  if [[ -n "$DYLIB_ARG" ]]; then source_dylib="$(resolve_path "$DYLIB_ARG")"; fi
  mkdir -p "$PACKAGE_DIR"
  cp -f "$source_dylib" "$PACKAGE_DIR/GamePack.dylib"
  log "package ready (no record): $PACKAGE_DIR"
  printf 'PACKAGE: %s\n' "$PACKAGE_DIR"
  printf 'TITLE_ID: %s\n' "$TITLE_ID"
  printf 'TARGET: %s\n' "$TRIPLE"
  printf 'GAME_PACK: %s\n' "$PACKAGE_DIR/GamePack.dylib"
  exit 0
fi

log "recording package metadata in $PACKAGE_DIR"
if [[ "$FAKE" -eq 1 ]]; then
  # --fake previews must not silently drop --rom/--include-rom: record the same
  # provenance (and optionally the bundled ROM copy) a real pack record gets.
  fake_record=(packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME"
    --out "$OUT_ROOT" --aot-version "$AOT_VERSION_ARG" --fake-placeholder)
  if [[ -n "$ROM_ARG" ]]; then
    fake_record+=(--rom "$(resolve_path "$ROM_ARG")")
    if [[ "$INCLUDE_ROM" -eq 1 ]]; then fake_record+=(--include-rom); fi
  fi
  "$PACK_BIN" "${fake_record[@]}"
elif [[ -n "$DYLIB_ARG" ]]; then
  if [[ -n "$PRODUCT_CODE" && -n "$ROM_ARG" ]]; then
    "$PACK_BIN" packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" \
      --product-code "$PRODUCT_CODE" --aot-version "$AOT_VERSION_ARG" --rom "$(resolve_path "$ROM_ARG")" ${INCLUDE_ROM_FLAG} \
      --out "$OUT_ROOT" --pack "$(resolve_path "$DYLIB_ARG")"
  elif [[ -n "$PRODUCT_CODE" ]]; then
    "$PACK_BIN" packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" \
      --product-code "$PRODUCT_CODE" --aot-version "$AOT_VERSION_ARG" \
      --out "$OUT_ROOT" --pack "$(resolve_path "$DYLIB_ARG")"
  elif [[ -n "$ROM_ARG" ]]; then
    "$PACK_BIN" packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" \
      --aot-version "$AOT_VERSION_ARG" --rom "$(resolve_path "$ROM_ARG")" ${INCLUDE_ROM_FLAG} \
      --out "$OUT_ROOT" --pack "$(resolve_path "$DYLIB_ARG")"
  else
    "$PACK_BIN" packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" \
      --aot-version "$AOT_VERSION_ARG" --out "$OUT_ROOT" --pack "$(resolve_path "$DYLIB_ARG")"
  fi
else
  if [[ -n "$PRODUCT_CODE" && -n "$ROM_ARG" ]]; then
    "$PACK_BIN" packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" \
      --product-code "$PRODUCT_CODE" --aot-version "$AOT_VERSION_ARG" --rom "$(resolve_path "$ROM_ARG")" ${INCLUDE_ROM_FLAG} \
      --out "$OUT_ROOT" --pack "$TMP_DYLIB"
  elif [[ -n "$PRODUCT_CODE" ]]; then
    "$PACK_BIN" packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" \
      --product-code "$PRODUCT_CODE" --aot-version "$AOT_VERSION_ARG" \
      --out "$OUT_ROOT" --pack "$TMP_DYLIB"
  elif [[ -n "$ROM_ARG" ]]; then
    "$PACK_BIN" packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" \
      --aot-version "$AOT_VERSION_ARG" --rom "$(resolve_path "$ROM_ARG")" ${INCLUDE_ROM_FLAG} \
      --out "$OUT_ROOT" --pack "$TMP_DYLIB"
  else
    "$PACK_BIN" packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" \
      --aot-version "$AOT_VERSION_ARG" --out "$OUT_ROOT" --pack "$TMP_DYLIB"
  fi
fi

log "package ready: $PACKAGE_DIR"
printf 'PACKAGE: %s\n' "$PACKAGE_DIR"
printf 'TITLE_ID: %s\n' "$TITLE_ID"
printf 'GAME_PACK: %s\n' "$PACKAGE_DIR/GamePack.dylib"
printf 'GAME_INFO: %s\n' "$PACKAGE_DIR/GameInfo.json"
if [[ "$FAKE" -eq 1 ]]; then
  warn "--fake wrote a placeholder pack; it is for previews only and must not be shipped"
fi
