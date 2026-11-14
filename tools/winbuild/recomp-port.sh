#!/usr/bin/env bash
# recomp-port.sh - run 3dsrecomp on THIS host to turn a user ROM into generated
# C and arm64 iOS objects, without a Mac and without Apple's SDK.
#
# Part of 3ds2apple (Apache-2.0). This is the "3dsrecomp on Windows/Linux" half
# of the local build: 3dsrecomp is a Rust CLI that works on Linux and Windows
# (upstream README: any C compiler works; MinGW-w64's gcc or clang on Windows).
# On Windows the launcher does not need this shell script: it sets
# CC="clang.exe --target=arm64-apple-ios16.0" and CPATH=<stubs> (3dsrecomp splits
# CC on spaces, and its compiler program is found on PATH) and runs the same
# "3dsrecomp port" command - see docs/windows-build.md.
#
# Usage:
#   tools/winbuild/recomp-port.sh <rom> <out-dir> [--name NAME] [--recomp-bin PATH]
#   tools/winbuild/recomp-port.sh --selfcheck
#
# Output (all gitignored if under build/):
#   <out-dir>/code/*.c, *.h, recomp.h, librecomp.a
#   <out-dir>/Cargo.toml, build.rs, src/main.rs   (3dsrecomp's standalone project)
# Then build the GamePack from the generated C:
#   tools/winbuild/build-gamepack.sh <name> --code-dir <out-dir>/code #       --title-id 0004000000055E00 --out build/winbuild
#
# Requires: bash, a 3dsrecomp build (third_party/3dsrecomp via
# scripts/build-recomp-ios.sh, or --recomp-bin), an LLVM release with clang.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
winbuild_dir="${WINBUILD_LLVM_DIR:-}"
stubs="${WINBUILD_DARWIN_STUBS:-${here}/darwin-stubs/include}"

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

rom=""
out=""
name=""
recomp="${THREEDS2APPLE_RECOMP:-${root}/third_party/3dsrecomp/target/release/3dsrecomp}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) [[ $# -ge 2 ]] || die "--name needs a value"; name="$2"; shift 2 ;;
    --recomp-bin) [[ $# -ge 2 ]] || die "--recomp-bin needs a value"; recomp="$2"; shift 2 ;;
    --selfcheck) [[ -x "${recomp}" ]] || die "3dsrecomp not built: ${recomp}"; "${recomp}" 2>&1 | head -5 || true; [[ -d "${stubs}" ]] || die "darwin stubs not found: ${stubs}"; echo "selfcheck: 3dsrecomp + darwin stubs present"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) if [[ -z "${rom}" ]]; then rom="$1"; elif [[ -z "${out}" ]]; then out="$1"; else die "unexpected argument: $1"; fi; shift ;;
  esac
done
[[ -n "${rom}" && -n "${out}" ]] || { usage >&2; exit 2; }
[[ -f "${rom}" ]] || die "ROM not found: ${rom}"
[[ -x "${recomp}" ]] || die "3dsrecomp binary not found: ${recomp}
  Build it once: cargo build --release in a 3dsrecomp checkout pinned to the
  revision in scripts/build-recomp-ios.sh, or pass --recomp-bin PATH."
[[ -d "${stubs}" ]] || die "darwin stubs not found: ${stubs}"
[[ -n "${name}" ]] || name="$(basename "${rom}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')"
command -v cargo >/dev/null 2>&1 || die "cargo is needed to build 3dsrecomp"
ar="${WINBUILD_LLVM_DIR:+}${WINBUILD_LLVM_DIR:-}/llvm-ar"
if [[ ! -x "${ar}" ]]; then ar="$(command -v llvm-ar || command -v ar || true)"; fi
[[ -n "${ar}" ]] || die "llvm-ar/ar not found"
mkdir -p "${out}"
log() { printf '[recomp-port] %s\n' "$*"; }
log "3dsrecomp: ${recomp}"
log "ROM:        ${rom}"
log "out:        ${out}"
log "CC:         ${here}/darwin-cc.sh (arm64-apple-ios16.0, darwin stubs, no Apple SDK)"
log "AR:         ${ar}"
CC="${here}/darwin-cc.sh" AR="${ar}" "${recomp}" port "${rom}" "${out}" --name "${name}"
printf 'GENERATED_C: %s\n' "${out}/code"
printf 'ARCHIVE: %s\n' "${out}/code/librecomp.a"
