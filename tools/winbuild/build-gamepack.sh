#!/usr/bin/env bash
# build-gamepack.sh - locally cross-build one 3dsrecomp GamePack Mach-O dylib
# with open-source LLVM/Clang + LLD, on Linux/WSL/Windows (Git Bash), no macOS.
#
# Part of 3ds2apple (Apache-2.0).
#
# This is the legal no-Apple-SDK path for the Windows/macOS launcher:
#   * Clang (official LLVM release, Apache-2.0 WITH LLVM-exception) compiles
#     the 3dsrecomp-generated C for arm64-apple-ios16.0 (or x86_64 simulator).
#   * There is no iPhoneOS SDK and no Apple libc: the build uses -nostdinc
#     with tools/winbuild/darwin-stubs/include (hand-written ISO C declarations)
#     and links -undefined dynamic_lookup, so libSystem calls (memcpy, sqrtf,
#     __stack_chk_* ...) and zk_register_gamepack resolve from the host app when
#     the shell dlopen()s the pack. No Apple file is copied or redistributed.
#   * ld64.lld (LLVM's Mach-O linker) writes the dylib with
#     LC_BUILD_VERSION platform=ios/iossimulator minos=16.0.
#   * check-gamepack.py (or an llvm-nm/llvm-objdump fallback) validates the Mach-O.
#
# Equivalent macOS command (what scripts/build-game-pack.sh runs with Xcode):
#   clang -target arm64-apple-ios16.0 -isysroot <iphoneos.sdk> -O2 ... -c code.c
#   clang -dynamiclib -target arm64-apple-ios16.0 -isysroot <iphoneos.sdk> \
#         shim.o librecomp.a -Wl,-undefined,dynamic_lookup ...
# This script replaces the SDK with stubs + dynamic_lookup and Apple's ld64 with
# ld64.lld. See tools/winbuild/README.md and docs/windows-build.md.
#
# Usage:
#   tools/winbuild/build-gamepack.sh <name> --code-dir <dir> --title-id <id> [options]
#   tools/winbuild/build-gamepack.sh --selfcheck
#
# Options:
#   --code-dir DIR      Directory of 3dsrecomp-generated C (recomp.h, *.c)
#   --title-id ID       16 hex digit application title ID (00040000...)
#   --target KIND       device (arm64-apple-ios16.0, default), sim
#                       (x86_64-apple-ios16.0-simulator) or a full clang triple
#   --out DIR           Output root (default: out); writes
#                       DIR/packages/<TITLE_ID>/GamePack-<TITLE_ID>.dylib
#   --jobs N            Parallel compiles (default: CPU count, capped at 16)
#   --llvm-dir DIR      LLVM bin directory (default: WINBUILD_LLVM_DIR, llvm-config,
#                       clang on PATH, then the official Windows install paths)
#   --shim FILE         GamePack shim source
#                       (default: ios/zakuro-ios/gamepack/zk_gamepack_shim.c)
#   --include-dir DIR   Header directory for the shim (default: ios/zakuro-ios/include)
#   --stubs-dir DIR     Darwin C stub headers (default: tools/winbuild/darwin-stubs/include)
#   --obj-dir DIR       Object cache (default: DIR/.obj/<target>; incremental)
#   --force             Recompile every C file (ignore the object cache)
#   --pack-bin PATH     Optional 3ds2apple-pack CLI: record GameInfo.json after
#                       the link (same schema writer as scripts/build-game-pack.sh)
#   --no-record         Never call the pack CLI (default when it is not built)
#   --dry-run           Print the plan and exit; write nothing
#   --selfcheck         Build and validate a stand-in pack for both targets
#                       (no ROM/generated C needed); exits nonzero on failure
#   --no-check          Skip Mach-O validation (NOT recommended)
#   -h, --help          Show this help
#
# Exit status: 0 success, 1 build/validation failure, 2 usage/config error.
# Requires: bash 3.2+, an LLVM release with clang + ld64.lld + llvm-ar +
# llvm-nm + llvm-objdump (Windows installer or Linux tarball; see
# tools/winbuild/llvm-manifest.json), Python 3 for the full Mach-O check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAME_ARG=""
CODE_DIR_ARG=""
TITLE_ARG=""
TARGET_ARG="device"
OUT_ARG="out"
JOBS_ARG=""
LLVM_DIR_ARG=""
SHIM_ARG=""
INCLUDE_DIR_ARG=""
STUBS_DIR_ARG=""
OBJ_DIR_ARG=""
PACK_BIN_ARG=""
FORCE=0
NO_RECORD=0
DRY_RUN=0
SELFCHECK=0
NO_CHECK=0
WORK=""
TMP_ROOT=${TMPDIR:-/tmp}
[[ -d "${TMP_ROOT}" ]] || TMP_ROOT=/tmp

log() { printf '[winbuild] %s\n' "$*"; }
warn() { printf '[winbuild] warning: %s\n' "$*" >&2; }
die() { printf '[winbuild] error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cleanup() { if [[ -n "${WORK}" && -d "${WORK}" ]]; then rm -rf -- "${WORK}"; fi; }
trap cleanup EXIT

# --- arguments ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --code-dir)    [[ $# -ge 2 ]] || die "--code-dir requires a value"; CODE_DIR_ARG="$2"; shift 2 ;;
    --title-id)    [[ $# -ge 2 ]] || die "--title-id requires a value"; TITLE_ARG="$2"; shift 2 ;;
    --target)      [[ $# -ge 2 ]] || die "--target requires a value"; TARGET_ARG="$2"; shift 2 ;;
    --out)         [[ $# -ge 2 ]] || die "--out requires a value"; OUT_ARG="$2"; shift 2 ;;
    --jobs)        [[ $# -ge 2 ]] || die "--jobs requires a value"; JOBS_ARG="$2"; shift 2 ;;
    --llvm-dir)    [[ $# -ge 2 ]] || die "--llvm-dir requires a value"; LLVM_DIR_ARG="$2"; shift 2 ;;
    --shim)        [[ $# -ge 2 ]] || die "--shim requires a value"; SHIM_ARG="$2"; shift 2 ;;
    --include-dir) [[ $# -ge 2 ]] || die "--include-dir requires a value"; INCLUDE_DIR_ARG="$2"; shift 2 ;;
    --stubs-dir)   [[ $# -ge 2 ]] || die "--stubs-dir requires a value"; STUBS_DIR_ARG="$2"; shift 2 ;;
    --obj-dir)     [[ $# -ge 2 ]] || die "--obj-dir requires a value"; OBJ_DIR_ARG="$2"; shift 2 ;;
    --pack-bin)    [[ $# -ge 2 ]] || die "--pack-bin requires a value"; PACK_BIN_ARG="$2"; shift 2 ;;
    --force)       FORCE=1; shift ;;
    --no-record)   NO_RECORD=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --selfcheck)   SELFCHECK=1; shift ;;
    --no-check)    NO_CHECK=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "${NAME_ARG}" ]]; then NAME_ARG="$1"; else die "unexpected argument: $1 (try --help)"; fi
      shift ;;
  esac
done

resolve_path() {
  case "$1" in
    /*|[A-Za-z]:[\\/]*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${ROOT}/$1" ;;
  esac
}

# --- target ------------------------------------------------------------------
case "$TARGET_ARG" in
  ''|device|ios)       TRIPLE="arm64-apple-ios16.0";          PLATFORM="ios";           MINOS="16.0.0"; CHECK_TARGET="device" ;;
  sim|simulator)       TRIPLE="x86_64-apple-ios16.0-simulator"; PLATFORM="ios-simulator"; MINOS="16.0.0"; CHECK_TARGET="sim" ;;
  *simulator*)         TRIPLE="$TARGET_ARG";                  PLATFORM="ios-simulator"; MINOS="16.0.0"; CHECK_TARGET="sim" ;;
  *)                   TRIPLE="$TARGET_ARG";                  PLATFORM="ios";           MINOS="16.0.0"; CHECK_TARGET="device" ;;
esac
case "$TRIPLE" in
  arm64*)  ARCH="arm64" ;;
  x86_64*) ARCH="x86_64" ;;
  *) die "unsupported target triple: $TRIPLE (need arm64 or x86_64)" ;;
esac

# --- locate the LLVM toolchain ----------------------------------------------
tool_in() { # dir name -> path (with .exe on Windows)
  local dir="$1" name="$2"
  if [[ -x "${dir}/${name}" ]]; then printf '%s\n' "${dir}/${name}"; return 0; fi
  if [[ -x "${dir}/${name}.exe" ]]; then printf '%s\n' "${dir}/${name}.exe"; return 0; fi
  return 1
}

find_llvm_dir() {
  local cand
  if [[ -n "${LLVM_DIR_ARG}" ]]; then printf '%s\n' "${LLVM_DIR_ARG}"; return 0; fi
  if [[ -n "${WINBUILD_LLVM_DIR:-}" ]]; then printf '%s\n' "${WINBUILD_LLVM_DIR}"; return 0; fi
  if command -v llvm-config >/dev/null 2>&1; then
    cand="$(llvm-config --bindir 2>/dev/null || true)"
    if [[ -n "${cand}" ]] && tool_in "${cand}" clang >/dev/null 2>&1; then
      printf '%s\n' "${cand}"; return 0
    fi
  fi
  if command -v clang >/dev/null 2>&1; then
    cand="$(dirname "$(command -v clang)")"
    printf '%s\n' "${cand}"; return 0
  fi
  for cand in \
    "/c/Program Files/LLVM/bin" \
    "/mnt/c/Program Files/LLVM/bin" \
    "${PROGRAMFILES:-}/LLVM/bin" \
    "${ProgramFiles:-}/LLVM/bin" \
    "${LOCALAPPDATA:-}/Programs/LLVM/bin" \
    "/usr/lib/llvm-21/bin" /usr/lib/llvm-20/bin /usr/lib/llvm-19/bin /usr/lib/llvm-18/bin; do
    if [[ -d "${cand}" ]] && tool_in "${cand}" clang >/dev/null 2>&1; then
      printf '%s\n' "${cand}"; return 0
    fi
  done
  return 1
}

LLVM_DIR="$(find_llvm_dir || true)"
[[ -n "${LLVM_DIR}" ]] || die "LLVM not found.
  Install an official LLVM release (manifest: tools/winbuild/llvm-manifest.json):
    Windows: winget install LLVM.LLVM   (or https://github.com/llvm/llvm-project/releases)
    Ubuntu/WSL: tools/winbuild/fetch-llvm-ubuntu.sh   (no root needed)
  Or pass --llvm-dir DIR / set WINBUILD_LLVM_DIR."
CC="$(tool_in "${LLVM_DIR}" clang)" || die "clang not found in ${LLVM_DIR}"
AR="$(tool_in "${LLVM_DIR}" llvm-ar)" || die "llvm-ar not found in ${LLVM_DIR}"
NM="$(tool_in "${LLVM_DIR}" llvm-nm)" || true
OBJDUMP="$(tool_in "${LLVM_DIR}" llvm-objdump)" || true
LD64="$(tool_in "${LLVM_DIR}" ld64.lld)" || true
[[ -n "${LD64}" ]] || warn "ld64.lld not found in ${LLVM_DIR}; will try the clang driver only"
RESOURCE_DIR="$("${CC}" -print-resource-dir 2>/dev/null || true)"
[[ -n "${RESOURCE_DIR}" && -d "${RESOURCE_DIR}/include" ]] || die "clang resource directory not found (${RESOURCE_DIR}/include)"
log "clang: ${CC}"
log "resource headers: ${RESOURCE_DIR}/include"
[[ -n "${LD64}" ]] && log "Mach-O linker: ${LD64}"

if [[ -n "${SHIM_ARG}" ]]; then SHIM_SRC="$(resolve_path "${SHIM_ARG}")"; else SHIM_SRC="${ROOT}/ios/zakuro-ios/gamepack/zk_gamepack_shim.c"; fi
if [[ -n "${INCLUDE_DIR_ARG}" ]]; then INCLUDE_DIR="$(resolve_path "${INCLUDE_DIR_ARG}")"; else INCLUDE_DIR="${ROOT}/ios/zakuro-ios/include"; fi
if [[ -n "${STUBS_DIR_ARG}" ]]; then STUBS_DIR="$(resolve_path "${STUBS_DIR_ARG}")"; else STUBS_DIR="${ROOT}/tools/winbuild/darwin-stubs/include"; fi
[[ -f "${SHIM_SRC}" ]] || die "GamePack shim not found: ${SHIM_SRC}"
[[ -d "${INCLUDE_DIR}" ]] || die "include dir not found: ${INCLUDE_DIR}"
[[ -d "${STUBS_DIR}" ]] || die "Darwin stub headers not found: ${STUBS_DIR}"
CHECKER="${ROOT}/tools/winbuild/check-gamepack.py"

PYTHON=""
for candidate in python3 python; do
  if command -v "${candidate}" >/dev/null 2>&1; then PYTHON="${candidate}"; break; fi
done
if [[ -z "${PYTHON}" && -x "/c/Windows/py.exe" ]]; then PYTHON="/c/Windows/py.exe"; fi

if [[ -n "${JOBS_ARG}" ]]; then
  JOBS="${JOBS_ARG}"
else
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf '%s' "${NUMBER_OF_PROCESSORS:-4}")"
fi
case "${JOBS}" in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac
[[ "${JOBS}" -ge 1 ]] || die "--jobs must be >= 1"
[[ "${JOBS}" -le 16 ]] || JOBS=16

# --- compile/link flags ------------------------------------------------------
# Same codegen flags as scripts/build-game-pack.sh, minus -isysroot: no Apple SDK.
COMMON_CFLAGS=(-target "${TRIPLE}" -O2 -ffp-contract=off -fno-math-errno -w
               -fPIC -nostdinc -isystem "${RESOURCE_DIR}/include" -isystem "${STUBS_DIR}")
SHIM_CFLAGS=("${COMMON_CFLAGS[@]}")
LINK_FLAGS=(-target "${TRIPLE}" -dynamiclib -nostdlib -fuse-ld=lld
            -Wl,-undefined,dynamic_lookup -Wl,-dead_strip)
# ld64.lld fallback (used when the clang driver cannot find its lld):
LD64_FLAGS=(-arch "${ARCH}" -platform_version "${PLATFORM}" "${MINOS}" "${MINOS}"
            -dylib -undefined dynamic_lookup -dead_strip)

# --- selfcheck ---------------------------------------------------------------
write_selfcheck_sources() { # dir
  local dir="$1"
  mkdir -p "${dir}"
  cat > "${dir}/tables.c" <<'C'
#include <stdint.h>
/* stand-ins for the seven 3dsrecomp tables the shim references; the real
 * generated entries.c marks them with recomp.h's RECOMP_EXPORT attribute, so
 * compile with -fvisibility=hidden like a real pack and keep them exported. */
#define RECOMP_EXPORT __attribute__((visibility("default")))
RECOMP_EXPORT const uint32_t recomp_abi = 5;
RECOMP_EXPORT const uint32_t recomp_generation = 5;
RECOMP_EXPORT const uint32_t recomp_entry_count = 1;
RECOMP_EXPORT const unsigned char recomp_entries[8] = { 0 };
RECOMP_EXPORT const uint32_t recomp_module_count = 1;
RECOMP_EXPORT const unsigned char recomp_modules[16] = { 0 };
RECOMP_EXPORT const unsigned char recomp_origins[16] = { 0 };
C
  cat > "${dir}/game.c" <<'C'
#include <math.h>
#include <string.h>
/* exercises the Darwin stubs: memcpy/sqrtf become dynamic_lookup imports */
int winbuild_selfcheck_probe(const void *src, unsigned bytes, float x) {
    unsigned char buffer[16];
    memcpy(buffer, src, bytes);
    return (int)sqrtf(x) + buffer[0];
}
C
}

run_selfcheck() {
  SELF_WORK="$(mktemp -d "${TMP_ROOT}/3ds2apple-winbuild-selfcheck.XXXXXX")"
  WORK="${SELF_WORK}"
  write_selfcheck_sources "${SELF_WORK}/src"
  log "selfcheck: sources in ${SELF_WORK}/src"
  local spec label triple platform arch dylib defined checks=0 failures=0
  for spec in "device|arm64-apple-ios16.0|ios|arm64" "sim|x86_64-apple-ios16.0-simulator|ios-simulator|x86_64"; do
    IFS='|' read -r label triple platform arch <<<"${spec}" || true
    dylib="${SELF_WORK}/GamePack-selfcheck-${label}.dylib"
    log "selfcheck: compiling stand-in pack for ${label} (${triple})"
    if ! "${CC}" -target "${triple}" -O2 -fPIC -fvisibility=hidden -nostdinc \
          -isystem "${RESOURCE_DIR}/include" -isystem "${STUBS_DIR}" -I "${SELF_WORK}/src" \
          -c "${SELF_WORK}/src/tables.c" -o "${SELF_WORK}/tables-${label}.o" 2>"${SELF_WORK}/compile-${label}.log"; then
      cat "${SELF_WORK}/compile-${label}.log" >&2
      failures=$((failures + 1)); warn "selfcheck ${label}: stand-in tables compile"; continue
    fi
    if ! "${CC}" -target "${triple}" -O2 -fPIC -fvisibility=hidden -nostdinc \
          -isystem "${RESOURCE_DIR}/include" -isystem "${STUBS_DIR}" -I "${SELF_WORK}/src" \
          -c "${SELF_WORK}/src/game.c" -o "${SELF_WORK}/game-${label}.o" 2>>"${SELF_WORK}/compile-${label}.log"; then
      cat "${SELF_WORK}/compile-${label}.log" >&2
      failures=$((failures + 1)); warn "selfcheck ${label}: stand-in game code compiles"; continue
    fi
    checks=$((checks + 1))
    if ! "${CC}" -target "${triple}" -O2 -fPIC -nostdinc \
          -isystem "${RESOURCE_DIR}/include" -isystem "${STUBS_DIR}" \
          -I "${INCLUDE_DIR}" -DZK_GAMEPACK_TITLE_ID=0x0004000000055E00ULL \
          -c "${SHIM_SRC}" -o "${SELF_WORK}/shim-${label}.o" 2>"${SELF_WORK}/shim-${label}.log"; then
      cat "${SELF_WORK}/shim-${label}.log" >&2
      failures=$((failures + 1)); warn "selfcheck ${label}: shim compiles"; continue
    fi
    checks=$((checks + 1))
    if ! "${CC}" -target "${triple}" -dynamiclib -nostdlib -fuse-ld=lld \
          -o "${dylib}" "${SELF_WORK}/shim-${label}.o" "${SELF_WORK}/tables-${label}.o" \
          "${SELF_WORK}/game-${label}.o" -Wl,-undefined,dynamic_lookup -Wl,-dead_strip \
          -Wl,-install_name,"@rpath/GamePack-0004000000055E00.dylib" 2>"${SELF_WORK}/link-${label}.log"; then
      cat "${SELF_WORK}/link-${label}.log" >&2
      failures=$((failures + 1)); warn "selfcheck ${label}: pack links as a Mach-O dylib"; continue
    fi
    checks=$((checks + 1))
    if run_check "${dylib}" "${label}" "0004000000055E00" "${SELF_WORK}/check-${label}.json"; then
      checks=$((checks + 1))
    else
      failures=$((failures + 1)); warn "selfcheck ${label}: Mach-O validation failed"
    fi
    if [[ -n "${NM}" ]]; then
      defined="$("${NM}" -gU "${dylib}" 2>/dev/null || true)"
      for symbol in _zk_gamepack_title_id _zk_gamepack_abi_version _zk_gamepack_register \
                    _recomp_abi _recomp_generation _recomp_entry_count _recomp_entries \
                    _recomp_module_count _recomp_modules _recomp_origins; do
        if printf '%s\n' "${defined}" | grep -qE " T ${symbol}$| S ${symbol}$| D ${symbol}$"; then
          checks=$((checks + 1))
        else
          failures=$((failures + 1)); warn "selfcheck ${label}: missing export ${symbol}"
        fi
      done
      if "${NM}" -u "${dylib}" 2>/dev/null | grep -qE "_zk_register_gamepack$"; then
        checks=$((checks + 1))
      else
        failures=$((failures + 1)); warn "selfcheck ${label}: zk_register_gamepack is not undefined"
      fi
    fi
  done
  printf 'selfcheck: %d checks, %d failure(s)\n' "${checks}" "${failures}"
  printf 'selfcheck: driver clang=%s ld64=%s\n' "${CC}" "${LD64:-clang-driver}"
  [[ "${failures}" -eq 0 ]] || die "selfcheck failed"
  log "selfcheck passed"
  exit 0
}

# --- validation --------------------------------------------------------------
run_check() { # dylib target title-id json-out
  local dylib="$1" target="$2" title="$3" json_out="$4" defined headers
  if [[ "${NO_CHECK}" -eq 1 ]]; then log "skipping Mach-O validation (--no-check)"; return 0; fi
  if [[ -n "${PYTHON}" && -f "${CHECKER}" ]]; then
    if "${PYTHON}" "${CHECKER}" "${dylib}" --target "${target}" --title-id "${title}" --json >"${json_out}" 2>"${json_out}.err"; then
      log "Mach-O validation passed (${CHECKER})"
      return 0
    fi
    cat "${json_out}.err" >&2 2>/dev/null || true
    warn "Mach-O validation FAILED:"
    "${PYTHON}" "${CHECKER}" "${dylib}" --target "${target}" --title-id "${title}" >&2 || true
    return 1
  fi
  warn "python3 not found; using llvm-nm/llvm-objdump fallback checks"
  [[ -n "${NM}" && -n "${OBJDUMP}" ]] || { warn "llvm-nm/llvm-objdump missing; cannot validate"; return 1; }
  defined="$("${NM}" -gU "${dylib}" 2>/dev/null || true)"
  for symbol in _zk_gamepack_title_id _zk_gamepack_abi_version _zk_gamepack_register \
                _recomp_abi _recomp_generation _recomp_entry_count _recomp_entries \
                _recomp_module_count _recomp_modules _recomp_origins; do
    printf '%s\n' "${defined}" | grep -qE " T ${symbol}$| S ${symbol}$| D ${symbol}$" \
      || { warn "missing export ${symbol}"; return 1; }
  done
  "${NM}" -u "${dylib}" 2>/dev/null | grep -qE "_zk_register_gamepack$" \
    || { warn "zk_register_gamepack is not an undefined import"; return 1; }
  if printf '%s\n' "${defined}" | grep -qE " T _zk_create$"; then
    warn "pack defines _zk_create (it must not carry the runtime)"; return 1
  fi
  headers="$("${OBJDUMP}" --macho --private-headers "${dylib}" 2>/dev/null || true)"
  if ! printf '%s\n' "${headers}" | grep -q "platform ios"; then
    warn "LC_BUILD_VERSION platform is not iOS"; return 1
  fi
  log "Mach-O validation passed (llvm-nm/llvm-objdump fallback)"
}

# --- main --------------------------------------------------------------------
if [[ "${SELFCHECK}" -eq 1 ]]; then run_selfcheck; fi

[[ -n "${NAME_ARG}" ]] || die "missing <name> argument (or use --selfcheck; try --help)"
case "${NAME_ARG}" in *[!A-Za-z0-9._-]*) die "invalid game name: '${NAME_ARG}' (letters, digits, '.', '_', '-')" ;; esac
[[ -n "${CODE_DIR_ARG}" ]] || die "missing --code-dir DIR (3dsrecomp-generated C) or --selfcheck"
TITLE_ID="$(printf '%s' "${TITLE_ARG}" | tr '[:lower:]' '[:upper:]')"
case "${TITLE_ID}" in
  ''|*[!0-9A-F]*) die "missing/invalid --title-id (16 hex digits, e.g. 0004000000055E00)" ;;
esac
[[ "${#TITLE_ID}" -eq 16 ]] || die "--title-id must be exactly 16 hex digits"
case "${TITLE_ID}" in
  00040000*) ;;
  *) die "title ID ${TITLE_ID} is not an application title (expected the 00040000 high word)" ;;
esac

CODE_DIR="$(resolve_path "${CODE_DIR_ARG}")"
[[ -d "${CODE_DIR}" ]] || die "--code-dir is not a directory: ${CODE_DIR}"
shopt -s nullglob
C_FILES=("${CODE_DIR}"/*.c)
shopt -u nullglob
[[ "${#C_FILES[@]}" -ge 1 ]] || die "--code-dir has no generated C files: ${CODE_DIR}"
[[ -f "${CODE_DIR}/recomp.h" ]] || warn "${CODE_DIR}/recomp.h is missing; the generated C may not compile"

OUT_ROOT="$(resolve_path "${OUT_ARG}")"
PACKAGE_DIR="${OUT_ROOT}/packages/${TITLE_ID}"
# Keep the canonical IPA file name for the device pack; give the simulator pack
# a suffix so building both targets into the same --out never overwrites one.
if [[ "${CHECK_TARGET}" == "device" ]]; then
  DYLIB="${PACKAGE_DIR}/GamePack-${TITLE_ID}.dylib"
else
  DYLIB="${PACKAGE_DIR}/GamePack-${TITLE_ID}-${CHECK_TARGET}.dylib"
fi
if [[ -n "${OBJ_DIR_ARG}" ]]; then OBJ_DIR="$(resolve_path "${OBJ_DIR_ARG}")"; else OBJ_DIR="${OUT_ROOT}/.obj/${CHECK_TARGET}"; fi
PACK_BIN=""
if [[ -n "${PACK_BIN_ARG}" ]]; then PACK_BIN="$(resolve_path "${PACK_BIN_ARG}")"; fi
if [[ -z "${PACK_BIN}" && "${NO_RECORD}" -eq 0 ]]; then
  for candidate in "${ROOT}/builder/target/release/3ds2apple-pack" "${ROOT}/builder/target/debug/3ds2apple-pack"; do
    if [[ -x "${candidate}" ]]; then PACK_BIN="${candidate}"; break; fi
  done
  if [[ -z "${PACK_BIN}" ]] && command -v 3ds2apple-pack >/dev/null 2>&1; then PACK_BIN="$(command -v 3ds2apple-pack)"; fi
fi
[[ "${NO_RECORD}" -eq 1 ]] && PACK_BIN=""

log "name:      ${NAME_ARG}"
log "title:     ${TITLE_ID}"
log "target:    ${TRIPLE} (${CHECK_TARGET})"
log "code dir:  ${CODE_DIR} (${#C_FILES[@]} generated C files)"
log "output:    ${DYLIB}"
log "obj cache: ${OBJ_DIR}"
log "jobs:      ${JOBS}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "dry run: no files written"
  printf 'target=%s\nplatform=%s\nminos=%s\narch=%s\n' "${TRIPLE}" "${PLATFORM}" "${MINOS}" "${ARCH}"
  printf 'dylib=%s\ninstall_name=@rpath/GamePack-%s.dylib\n' "${DYLIB}" "${TITLE_ID}"
  printf 'cc=%s\nld64=%s\nstubs=%s\n' "${CC}" "${LD64:-clang-driver}" "${STUBS_DIR}"
  printf 'jobs=%s\nfiles=%s\n' "${JOBS}" "${#C_FILES[@]}"
  exit 0
fi

mkdir -p "${PACKAGE_DIR}" "${OBJ_DIR}"
WORK="$(mktemp -d "${TMP_ROOT}/3ds2apple-winbuild.XXXXXX")"
LOG_FILE="${OUT_ROOT}/build-gamepack-${NAME_ARG}-${CHECK_TARGET}.log"
: > "${LOG_FILE}"

# Compile one C file (incremental object cache). Arguments: cc, triple, code dir,
# obj dir, log, force, resource dir, stubs dir, source file.
cat > "${WORK}/compile-one.sh" <<'SH'
#!/usr/bin/env bash
set -eu
cc="$1"; triple="$2"; code_dir="$3"; obj_dir="$4"; log="$5"; force="$6"; res="$7"; stubs="$8"; src="$9"
base="$(basename "$src" .c)"
obj="$obj_dir/$base.o"
if [ "$force" -eq 0 ] && [ -f "$obj" ] && [ "$obj" -nt "$src" ]; then
  exit 0
fi
"$cc" -target "$triple" -O2 -ffp-contract=off -fno-math-errno -w -fPIC -fvisibility=hidden \
  -nostdinc -isystem "$res/include" -isystem "$stubs" -I "$code_dir" \
  -c "$src" -o "$obj" >>"$log" 2>&1 || {
    printf 'compile failed: %s\n' "$base" >&2
    tail -n 20 "$log" >&2
    exit 1
  }
SH
chmod +x "${WORK}/compile-one.sh"
log "compiling generated C for ${TRIPLE} into ${OBJ_DIR} (incremental)"
printf '%s\n' "${C_FILES[@]}" | \
  xargs -P "${JOBS}" -n 1 "${WORK}/compile-one.sh" "${CC}" "${TRIPLE}" "${CODE_DIR}" "${OBJ_DIR}" "${LOG_FILE}" "${FORCE}" "${RESOURCE_DIR}" "${STUBS_DIR}" \
  || { tail -n 40 "${LOG_FILE}" >&2; die "generated C did not compile; full log: ${LOG_FILE}"; }
OBJ_FILES=()
for c_file in "${C_FILES[@]}"; do
  base="$(basename "${c_file}" .c)"
  obj="${OBJ_DIR}/${base}.o"
  [[ -f "${obj}" ]] || die "missing object after compile: ${obj}"
  OBJ_FILES[${#OBJ_FILES[@]}]="${obj}"
done
log "archiving ${#OBJ_FILES[@]} objects -> ${OBJ_DIR}/librecomp.a"
rm -f "${OBJ_DIR}/librecomp.a"
"${AR}" rcs "${OBJ_DIR}/librecomp.a" "${OBJ_FILES[@]}" >>"${LOG_FILE}" 2>&1 \
  || die "llvm-ar failed; full log: ${LOG_FILE}"

log "compiling the GamePack shim for ${TRIPLE}"
SHIM_OBJ="${WORK}/zk_gamepack_shim.o"
"${CC}" "${SHIM_CFLAGS[@]}" -I "${INCLUDE_DIR}" -DZK_GAMEPACK_TITLE_ID="0x${TITLE_ID}ULL" \
  -c "${SHIM_SRC}" -o "${SHIM_OBJ}" >>"${LOG_FILE}" 2>&1 \
  || { tail -n 20 "${LOG_FILE}" >&2; die "the GamePack shim did not compile"; }

log "linking ${DYLIB} with ld64.lld"
rm -f "${DYLIB}"
if ! "${CC}" "${LINK_FLAGS[@]}" -o "${DYLIB}" "${SHIM_OBJ}" "${OBJ_DIR}/librecomp.a" \
      -Wl,-install_name,"@rpath/GamePack-${TITLE_ID}.dylib" >>"${LOG_FILE}" 2>&1; then
  if [[ -n "${LD64}" ]]; then
    warn "clang driver link failed; retrying with ld64.lld directly"
    if ! "${LD64}" "${LD64_FLAGS[@]}" -install_name "@rpath/GamePack-${TITLE_ID}.dylib" \
          -o "${DYLIB}" "${SHIM_OBJ}" "${OBJ_DIR}/librecomp.a" >>"${LOG_FILE}" 2>&1; then
      tail -n 40 "${LOG_FILE}" >&2
      die "ld64.lld could not link the GamePack dylib; full log: ${LOG_FILE}"
    fi
  else
    tail -n 40 "${LOG_FILE}" >&2
    die "clang could not link the GamePack dylib; full log: ${LOG_FILE}"
  fi
fi

BYTES="$(wc -c < "${DYLIB}" | tr -d '[:space:]')"
if command -v sha256sum >/dev/null 2>&1; then SHA256="$(sha256sum "${DYLIB}" | awk '{print $1}')";
elif command -v shasum >/dev/null 2>&1; then SHA256="$(shasum -a 256 "${DYLIB}" | awk '{print $1}')";
else SHA256="(no sha256 tool)"; fi
log "dylib: ${DYLIB} (${BYTES} bytes, sha256 ${SHA256})"
printf 'DYLIB: %s\n' "${DYLIB}"
printf 'TITLE_ID: %s\n' "${TITLE_ID}"
printf 'TARGET: %s\n' "${TRIPLE}"
printf 'BYTES: %s\n' "${BYTES}"
printf 'SHA256: %s\n' "${SHA256}"

run_check "${DYLIB}" "${CHECK_TARGET}" "${TITLE_ID}" "${PACKAGE_DIR}/GamePack-check.json"

if [[ -n "${PACK_BIN}" ]]; then
  log "recording GameInfo.json with ${PACK_BIN}"
  "${PACK_BIN}" packages record --title-id "${TITLE_ID}" --display-name "${NAME_ARG}" \
    --out "${OUT_ROOT}" --pack "${DYLIB}" >>"${LOG_FILE}" 2>&1 \
    || { tail -n 30 "${LOG_FILE}" >&2; die "3ds2apple-pack could not record the package"; }
  printf 'GAME_INFO: %s\n' "${OUT_ROOT}/packages/${TITLE_ID}/GameInfo.json"
fi

printf 'PACKAGE: %s\n' "${PACKAGE_DIR}"
printf 'LOG: %s\n' "${LOG_FILE}"
log "done"
