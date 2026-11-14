#!/usr/bin/env bash
# build-game-pack-llvm.sh - build one per-game GamePack dylib with open-source
# LLVM/Clang + LLD instead of Apple's Xcode toolchain (Linux/WSL/Windows).
#
# Part of 3ds2apple (Apache-2.0).
#
# This is the repo-facing wrapper around tools/winbuild/build-gamepack.sh. It
# fills in the desktop AOT pipeline conventions (scripts/build-game-pack.sh):
#   --code-dir defaults to build/game/<name>  (3dsrecomp-generated C)
#   --out      defaults to build/winbuild     (gitignored, like build/)
#   --target   defaults to device             (arm64-apple-ios16.0)
# Everything else (--title-id, --jobs, --llvm-dir, --target sim, --selfcheck,
# --dry-run, --force, --pack-bin ...) is passed through to the LLVM builder.
#
# The macOS/Xcode path stays authoritative for shipping builds; this path lets a
# Windows or Linux launcher produce the same GamePack.dylib locally without an
# Apple SDK, using tools/winbuild/darwin-stubs/include + -undefined dynamic_lookup
# instead of the iPhoneOS SDK. See docs/windows-build.md and
# tools/winbuild/README.md.
#
# Usage:
#   scripts/build-game-pack-llvm.sh pokemon-y --title-id 0004000000055E00
#   scripts/build-game-pack-llvm.sh pokemon-y --title-id 0004000000055E00 --target sim
#   scripts/build-game-pack-llvm.sh --selfcheck
#
# Exit status: the underlying builder's (0 ok, 1 build/validation failure,
# 2 usage/config).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILDER="${ROOT}/tools/winbuild/build-gamepack.sh"
[[ -x "${BUILDER}" ]] || { printf 'error: %s not found/executable\n' "${BUILDER}" >&2; exit 2; }

NAME=""
HAS_CODE=0
HAS_OUT=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --code-dir)   HAS_CODE=1; ARGS+=("$1" "$2"); shift 2 ;;
    --code-dir=*) HAS_CODE=1; ARGS+=("$1"); shift ;;
    --out)        HAS_OUT=1; ARGS+=("$1" "$2"); shift 2 ;;
    --out=*)      HAS_OUT=1; ARGS+=("$1"); shift ;;
    -h|--help)    exec "${BUILDER}" --help ;;
    -*)           ARGS+=("$1"); shift ;;
    *)
      if [[ -z "${NAME}" ]]; then NAME="$1"; fi
      ARGS+=("$1"); shift ;;
  esac
done

# Non-build invocations (--selfcheck, --help, malformed) go straight through.
if [[ -z "${NAME}" || "${NAME}" == --* ]]; then
  exec "${BUILDER}" "${ARGS[@]}"
fi

case "${NAME}" in
  *[!A-Za-z0-9._-]*) printf 'error: invalid game name: %s\n' "${NAME}" >&2; exit 2 ;;
esac

if [[ "${HAS_CODE}" -eq 0 ]]; then
  if [[ -d "${ROOT}/build/game/${NAME}" ]]; then
    ARGS+=(--code-dir "${ROOT}/build/game/${NAME}")
  elif [[ -d "${ROOT}/build/game/${NAME}/code" ]]; then
    ARGS+=(--code-dir "${ROOT}/build/game/${NAME}/code")
  fi
fi
if [[ "${HAS_OUT}" -eq 0 ]]; then
  ARGS+=(--out "${ROOT}/build/winbuild")
fi

printf '[build-game-pack-llvm] delegating to tools/winbuild/build-gamepack.sh\n'
exec "${BUILDER}" "${ARGS[@]}"
