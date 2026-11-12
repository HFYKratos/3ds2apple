#!/usr/bin/env bash
# Build a portable tarball and a Debian package for the Linux Builder frontend.
#
# The output contains the two release binaries (zkb + 3ds2apple-builder), the
# man page, the desktop entry, the licence and the docs. No ROM, IPA, static
# library or credential is included. Run from anywhere inside the checkout.
#
# Usage:
#   builder/linux/packaging/build-deb.sh [--version 0.1.0] [--arch amd64]
#                                       [--out dist] [--skip-build]
#
# Debian/Ubuntu need: cargo, rust, dpkg-deb. Arch/CachyOS users should use the
# PKGBUILD instead (see packaging/README.md).
set -euo pipefail

VERSION="0.1.0"
DEB_ARCH="amd64"
OUT="dist"
SKIP_BUILD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*) VERSION="${1#--version=}"; shift ;;
    --arch) DEB_ARCH="${2:?--arch needs a value}"; shift 2 ;;
    --arch=*) DEB_ARCH="${1#--arch=}"; shift ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help) sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILDER="$REPO_ROOT/builder"
PKG="3ds2apple-builder"
case "$OUT" in
  /*) OUT_DIR="$OUT" ;;
  *) OUT_DIR="$REPO_ROOT/$OUT" ;;
esac
STAGE="$OUT_DIR/stage-$PKG-$VERSION-$DEB_ARCH"
TARBALL="$OUT_DIR/$PKG-$VERSION-linux-$DEB_ARCH.tar.gz"
DEB="$OUT_DIR/${PKG}_${VERSION}_${DEB_ARCH}.deb"

if [[ -z "$SKIP_BUILD" ]]; then
  echo "== building release binaries =="
  (cd "$BUILDER" && cargo build --release --locked -p builder-cli -p builder-linux)
fi
ZK_BIN="$BUILDER/target/release/zkb"
FRONTEND_BIN="$BUILDER/target/release/3ds2apple-builder"
for binary in "$ZK_BIN" "$FRONTEND_BIN"; do
  [[ -x "$binary" ]] || { echo "missing release binary: $binary (drop --skip-build)" >&2; exit 1; }
done

echo "== staging $VERSION ($DEB_ARCH) =="
rm -rf "$STAGE"
install -d "$STAGE/usr/bin" \
  "$STAGE/usr/share/doc/$PKG" \
  "$STAGE/usr/share/man/man1" \
  "$STAGE/usr/share/applications" \
  "$STAGE/usr/share/licenses/$PKG"
install -m 755 "$ZK_BIN" "$STAGE/usr/bin/zkb"
install -m 755 "$FRONTEND_BIN" "$STAGE/usr/bin/3ds2apple-builder"
install -m 644 "$REPO_ROOT/builder/linux/README.md" "$STAGE/usr/share/doc/$PKG/README.md"
install -m 644 "$REPO_ROOT/builder/linux/packaging/3ds2apple-builder.1" \
  "$STAGE/usr/share/man/man1/3ds2apple-builder.1"
install -m 644 "$REPO_ROOT/builder/linux/packaging/3ds2apple-builder.desktop" \
  "$STAGE/usr/share/applications/3ds2apple-builder.desktop"
install -m 644 "$REPO_ROOT/LICENSE" "$STAGE/usr/share/licenses/$PKG/LICENSE"
install -m 644 "$REPO_ROOT/NOTICE" "$STAGE/usr/share/licenses/$PKG/NOTICE"

echo "== portable tarball =="
mkdir -p "$OUT_DIR"
tar -C "$STAGE" -czf "$TARBALL" usr

echo "== .deb =="
if command -v dpkg-deb >/dev/null 2>&1; then
  install -d "$STAGE/DEBIAN"
  cat >"$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Section: devel
Priority: optional
Architecture: $DEB_ARCH
Depends: openssh-client
Maintainer: 3ds2apple contributors <https://github.com/HFYKratos/3ds2apple>
Homepage: https://github.com/HFYKratos/3ds2apple
Description: Linux Builder frontend for 3ds2apple
 Builds your own legally owned 3DS ROM into an unsigned IPA on a macOS build
 host you control (a local VM, a LAN Mac or a cloud Mac), then verifies and
 explains how to sign/install the result. Includes the shared cross-platform
 client (zkb). No ROM, key, IPA or credential is included.
EOF
  dpkg-deb --build --root-owner-group "$STAGE" "$DEB" >/dev/null
else
  echo "note: dpkg-deb is not installed; skipped the .deb, tarball still built" >&2
fi

echo "== checksums =="
(cd "$OUT_DIR" && sha256sum "$(basename "$TARBALL")" >SHA256SUMS)
if [[ -f "$DEB" ]]; then
  (cd "$OUT_DIR" && sha256sum "$(basename "$DEB")" >>SHA256SUMS)
fi
echo "ok: $TARBALL"
if [[ -f "$DEB" ]]; then
  echo "ok: $DEB"
fi
echo "checksums: $OUT_DIR/SHA256SUMS"
