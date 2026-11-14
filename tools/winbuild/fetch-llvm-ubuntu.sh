#!/usr/bin/env bash
# fetch-llvm-ubuntu.sh - install an LLVM/Clang + LLD toolchain without root,
# from Ubuntu's llvm-toolchain-21 packages (no apt install, no sudo).
#
# Part of 3ds2apple (Apache-2.0). Prototype/CI helper for the Linux/WSL side of
# the local GamePack cross-build (tools/winbuild/build-gamepack.sh). It exists
# because the legal no-Apple-SDK path only needs an official LLVM release; on
# Ubuntu/Debian one can unpack the distro packages into a private prefix instead
# of installing them system-wide. Windows users install the official LLVM
# release instead (see tools/winbuild/llvm-manifest.json and README.md).
#
# Every downloaded .deb is checked against the SHA512 that apt itself publishes
# in its download URIs (apt verifies the signed package index first), then
# extracted with dpkg-deb into PREFIX. No file is copied from Apple's SDK.
#
# Usage:
#   tools/winbuild/fetch-llvm-ubuntu.sh [--prefix DIR] [--jobs N]
# Defaults: PREFIX=$HOME/.local/llvm-21
#
# Prints the toolchain bin directory on success. Requires: bash, apt-get,
# dpkg-deb, sha512sum, xz (Ubuntu/Debian/WSL only).
set -euo pipefail

PREFIX="${HOME}/.local/llvm-21"
PACKAGES="clang-21 lld-21 libclang-cpp21 libllvm21 llvm-21-runtime llvm-21 libclang-common-21-dev llvm-21-linker-tools"

log() { printf '[fetch-llvm-ubuntu] %s\n' "$*"; }
die() { printf '[fetch-llvm-ubuntu] error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) [[ $# -ge 2 ]] || die "--prefix requires a value"; PREFIX="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

for tool in apt-get dpkg-deb sha512sum; do
  command -v "${tool}" >/dev/null 2>&1 || die "'${tool}' not found (this helper is for Ubuntu/Debian/WSL)"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/3ds2apple-llvm-debs.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT
mkdir -p "${PREFIX}"

log "downloading: ${PACKAGES}"
( cd "${WORK}" && apt-get download ${PACKAGES} ) || die "apt-get download failed (is this Ubuntu with llvm-toolchain-21?)"

log "verifying SHA512 against apt's published digests"
failures=0
for pkg in ${PACKAGES}; do
  # apt-get download --print-uris line: 'URI' filename size SHA512:hash
  line="$(cd "${WORK}" && apt-get download --print-uris "${pkg}" 2>/dev/null | head -n 1 || true)"
  [[ -n "${line}" ]] || { log "warning: no URI for ${pkg}"; continue; }
  want="${line##*SHA512:}"
  want="${want%% *}"
  file="$(printf '%s\n' "${line}" | awk '{print $2}')"
  file="${file%\'}"
  file="${file#\'}"
  [[ -f "${WORK}/${file}" ]] || { log "warning: ${file} not downloaded"; continue; }
  got="$(sha512sum "${WORK}/${file}" | awk '{print $1}')"
  if [[ "${got}" != "${want}" ]]; then
    log "SHA512 MISMATCH for ${file}"; log "  expected ${want}"; log "  actual   ${got}"
    failures=$((failures + 1))
  fi
done
[[ "${failures}" -eq 0 ]] || die "package verification failed (${failures}); not extracting"

log "extracting to ${PREFIX}"
for deb in "${WORK}"/*.deb; do
  dpkg-deb -x "${deb}" "${PREFIX}"
done

BIN="${PREFIX}/usr/lib/llvm-21/bin"
[[ -x "${BIN}/clang" ]] || die "extraction did not produce ${BIN}/clang"
log "installed: $("${BIN}/clang" --version | head -n 1)"
log "use it with: tools/winbuild/build-gamepack.sh --llvm-dir '${BIN}'"
printf '%s\n' "${BIN}"
