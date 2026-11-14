#!/bin/sh
# darwin-cc.sh - CC wrapper: let a host tool compile C for arm64 iOS with
# open-source LLVM/Clang and no Apple SDK.
#
# Part of 3ds2apple (Apache-2.0). Used by tools/winbuild/recomp-port.sh on
# Linux/WSL/macOS: 3dsrecomp runs $CC with its own flags (-O2 -ffp-contract=off
# -fno-math-errno -w -fPIC -fvisibility=hidden -c ...), and this wrapper adds the
# arm64-apple-ios16.0 target plus the hand-written ISO C stubs. Windows does not
# need this wrapper: the launcher sets CC="clang.exe --target=arm64-apple-ios16.0"
# and CPATH=<stubs> (3dsrecomp splits CC on spaces), see docs/windows-build.md.
#
# Environment:
#   WINBUILD_LLVM_DIR   LLVM bin directory (default: clang found on PATH)
#   WINBUILD_DARWIN_STUBS  stub include dir (default: tools/winbuild/darwin-stubs/include)
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
stubs="${WINBUILD_DARWIN_STUBS:-${here}/darwin-stubs/include}"
if [ -n "${WINBUILD_LLVM_DIR:-}" ]; then
  clang="${WINBUILD_LLVM_DIR}/clang"
else
  clang="$(command -v clang || true)"
fi
[ -n "${clang}" ] || { echo "darwin-cc: clang not found (set WINBUILD_LLVM_DIR)" >&2; exit 2; }
res="$("${clang}" -print-resource-dir)"
exec "${clang}" -target arm64-apple-ios16.0 -nostdinc \
  -isystem "${res}/include" -isystem "${stubs}" "$@"
