#!/usr/bin/env bash
# vm-build.sh - build the macOS launcher (Release, universal), run its
# self-checks, render the localized non-game UI screenshots and assemble the
# user-facing ZIP (3ds2apple-launcher.app + LICENSE/NOTICE/THIRD_PARTY.md at the
# ZIP root) under the project's own out/launchers/ directory (gitignored), per
# launcher/macos/README.md.
#
#   cd ~/3ds2apple/launcher/macos && bash scripts/vm-build.sh
#
# It never needs a ROM, an iPhone, an Apple ID or the network: the screenshots
# and self-checks use the mock backends.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
ROOT="$(cd "$HERE/../.." && pwd)"
# Point the headless self-check at this build tree (checkout detection) so the
# MoltenVK/template assertions inspect the right out/shell template.
export THREEDS2APPLE_ROOT="$ROOT"
# Deterministic portable data root for the headless modes on the VM; the live
# app resolves its own root beside the .app (see Sources/PortableData.swift).
DATA_ROOT="${THREEDS2APPLE_DATA_DIR:-/tmp/zl-launcher-data-vm}"
export THREEDS2APPLE_DATA_DIR="$DATA_ROOT"

export PATH=/usr/local/bin:$PATH
CONFIG="${CONFIG:-Release}"
LOG=/tmp/zl-launcher-build.log
VERSION="$(sed -n 's/^        MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || VERSION="0.1.7"
# The bundle version stays numeric (CFBundleShortVersionString); the package file
# name can carry a pre-release suffix (THREEDS2APPLE_PACKAGE_VERSION).
PACKAGE_VERSION="${THREEDS2APPLE_PACKAGE_VERSION:-$VERSION}"
BUILD_NUMBER="$(sed -n 's/^        CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
[ -n "$BUILD_NUMBER" ] || BUILD_NUMBER="1"
OUT_DIR="$ROOT/out/launchers"
PACKAGE_NAME="3ds2apple-launcher-${PACKAGE_VERSION}-macos-app"
LICENSE_TEXTS=(LICENSE NOTICE THIRD_PARTY.md)
STATUS=0

echo "== xcodegen =="
if ! xcodegen generate --spec project.yml > "$LOG.xcodegen" 2>&1; then
  echo "xcodegen FAILED"; tail -30 "$LOG.xcodegen"; exit 1
fi
echo "xcodegen ok"

echo "== xcodebuild ($CONFIG) =="
if xcodebuild -project 3ds2apple-launcher.xcodeproj -scheme 3ds2apple-launcher \
      -configuration "$CONFIG" -destination 'platform=macOS' \
      -derivedDataPath build build > "$LOG" 2>&1; then
  echo "xcodebuild PASSED"
  grep -E "warning:" "$LOG" | head -20 || true
else
  echo "xcodebuild FAILED"
  grep -E "error:" "$LOG" | head -80 || true
  echo "---- tail ----"
  tail -60 "$LOG"
  exit 1
fi

APP="build/Build/Products/$CONFIG/3ds2apple-launcher.app"
BIN="$APP/Contents/MacOS/3ds2apple-launcher"
if [ ! -x "$BIN" ]; then
  echo "app binary missing: $BIN"; exit 1
fi
echo "app: $APP"
echo "binary: $(ls -l "$BIN" | awk '{print $5}') bytes"
echo "archs: $(lipo -archs "$BIN" 2>/dev/null || file "$BIN")"
echo "bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null)"
echo "version: $BUNDLE_VERSION build $BUNDLE_BUILD"
if [ "$BUNDLE_VERSION" != "$VERSION" ] || [ "$BUNDLE_BUILD" != "$BUILD_NUMBER" ]; then
  echo "VERSION MISMATCH: bundle $BUNDLE_VERSION/$BUNDLE_BUILD vs project.yml $VERSION/$BUILD_NUMBER"
  STATUS=1
fi
echo "headless data root: $DATA_ROOT"

echo "== embed MoltenVK.framework (hardware renderer + system Metal HUD) =="
TEMPLATE="$ROOT/out/shell/3ds2apple-shell.ipa"
MOLTENVK_SHA="6cd5888490d08b36356d04c50c05e2eda5b9bcb3d0338ece693a28987de96aff"
if [ ! -f "$TEMPLATE" ]; then
  echo "SHELL TEMPLATE MISSING: $TEMPLATE"
  echo "  the launcher copies Frameworks/MoltenVK.framework from the pinned ROM-free shell template"
  exit 1
fi
rm -rf /tmp/zl-shell-template-extract "$APP/Contents/Resources/MoltenVK.framework"
mkdir -p /tmp/zl-shell-template-extract
if ! unzip -q -o "$TEMPLATE" -d /tmp/zl-shell-template-extract; then
  echo "SHELL TEMPLATE UNZIP FAILED: $TEMPLATE"; exit 1
fi
SHELL_APP="$(find /tmp/zl-shell-template-extract/Payload -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
SRC_FW="$SHELL_APP/Frameworks/MoltenVK.framework"
if [ ! -f "$SRC_FW/MoltenVK" ]; then
  echo "TEMPLATE HAS NO Frameworks/MoltenVK.framework: $SRC_FW"; exit 1
fi
mkdir -p "$APP/Contents/Resources"
ditto "$SRC_FW" "$APP/Contents/Resources/MoltenVK.framework"
EMBEDDED_FW="$APP/Contents/Resources/MoltenVK.framework/MoltenVK"
EMBEDDED_SHA="$(shasum -a 256 "$EMBEDDED_FW" | awk '{print $1}')"
EMBEDDED_BYTES="$(stat -f%z "$EMBEDDED_FW")"
if [ "$EMBEDDED_SHA" != "$MOLTENVK_SHA" ] || [ "$EMBEDDED_BYTES" != "4822128" ]; then
  echo "EMBEDDED MOLTENVK MISMATCH: $EMBEDDED_BYTES bytes sha256 $EMBEDDED_SHA"; exit 1
fi
echo "embedded MoltenVK.framework: $EMBEDDED_BYTES bytes sha256 $EMBEDDED_SHA"
echo "template IPA sha256: $(shasum -a 256 "$TEMPLATE" | awk '{print $1}')"

echo "== app icon =="
ICON="$APP/Contents/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
  echo "icon present: $(ls -l "$ICON" | awk '{print $5}') bytes"
  rm -rf /tmp/zl-icon-check.iconset
  if iconutil -c iconset -o /tmp/zl-icon-check.iconset "$ICON"; then
    echo "icon icns valid: $(ls /tmp/zl-icon-check.iconset | wc -l | tr -d ' ') sizes"
  else
    echo "icon icns INVALID"; STATUS=1
  fi
else
  echo "ICON MISSING: $ICON"; STATUS=1
fi

echo "== localizations =="
find "$APP/Contents/Resources" -maxdepth 1 -name '*.lproj' -print | sort
for lproj in en.lproj zh-Hans.lproj; do
  if [ -f "$APP/Contents/Resources/$lproj/InfoPlist.strings" ]; then
    echo "$lproj/InfoPlist.strings: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Resources/$lproj/InfoPlist.strings" 2>/dev/null || echo unreadable)"
  else
    echo "$lproj/InfoPlist.strings MISSING"; STATUS=1
  fi
done

echo "== selfcheck =="
if "$BIN" --selfcheck > /tmp/zl-launcher-selfcheck.log 2>&1; then
  echo "selfcheck PASSED"
  SELFCHECK_RESULT="$(tail -1 /tmp/zl-launcher-selfcheck.log)"
else
  echo "selfcheck FAILED"
  SELFCHECK_RESULT="FAILED"
  STATUS=1
fi
tail -14 /tmp/zl-launcher-selfcheck.log

echo "== screenshots =="
rm -rf screenshots
for theme in dark light; do
  if "$BIN" --screenshot-dir screenshots --theme "$theme" --lang all --mock > "/tmp/zl-launcher-shots-$theme.log" 2>&1; then
    echo "screenshots ($theme) PASSED"
  else
    echo "screenshots ($theme) FAILED"
    tail -20 "/tmp/zl-launcher-shots-$theme.log"
    STATUS=1
  fi
done
ls -l screenshots | tail -25
SHOT_COUNT="$(ls screenshots | wc -l | tr -d ' ')"
echo "screenshot count: $SHOT_COUNT"

echo "== package (ZIP = .app + repository licence texts under out/launchers) =="
mkdir -p "$OUT_DIR"
for text in "${LICENSE_TEXTS[@]}"; do
  if [ ! -f "$ROOT/$text" ]; then
    echo "REPOSITORY LICENCE TEXT MISSING: $ROOT/$text"; exit 1
  fi
done
rm -rf /tmp/zl-macos-package
mkdir -p /tmp/zl-macos-package
ditto "$APP" "/tmp/zl-macos-package/3ds2apple-launcher.app"
rm -f "$OUT_DIR/$PACKAGE_NAME.zip"
# ditto keeps the .app bundle structure byte-for-byte (symlinks, resource forks,
# extended attributes); the three repository licence texts are then appended at
# the ZIP root. Both shipped packages carry them inside the archive and the
# GitHub Release still has exactly two assets (the texts are never separate
# uploads), matching CONTRIBUTING.md#release-policy.
ditto -c -k --sequesterRsrc --keepParent "/tmp/zl-macos-package/3ds2apple-launcher.app" "$OUT_DIR/$PACKAGE_NAME.zip"
(cd "$ROOT" && zip -q "$OUT_DIR/$PACKAGE_NAME.zip" "${LICENSE_TEXTS[@]}")
shasum -a 256 "$OUT_DIR/$PACKAGE_NAME.zip" | tee "$OUT_DIR/$PACKAGE_NAME.zip.sha256"
ZIP_SIZE="$(stat -f%z "$OUT_DIR/$PACKAGE_NAME.zip")"
echo "zip: $OUT_DIR/$PACKAGE_NAME.zip ($ZIP_SIZE bytes)"

echo "== package verification =="
unzip -t "$OUT_DIR/$PACKAGE_NAME.zip" | tail -2
unzip -l "$OUT_DIR/$PACKAGE_NAME.zip" > /tmp/zl-package-list.txt
echo "zip entries: $(tail -1 /tmp/zl-package-list.txt)"
ZIP_ENTRIES="$(unzip -Z1 "$OUT_DIR/$PACKAGE_NAME.zip")"
EXPECTED_ROOTS="$(printf '%s\n' "3ds2apple-launcher.app" "${LICENSE_TEXTS[@]}" | LC_ALL=C sort)"
ACTUAL_ROOTS="$(printf '%s\n' "$ZIP_ENTRIES" | cut -d/ -f1 | LC_ALL=C sort -u)"
if [ "$ACTUAL_ROOTS" != "$EXPECTED_ROOTS" ]; then
  echo "PACKAGE TOP-LEVEL ENTRIES MISMATCH (expected 3ds2apple-launcher.app + LICENSE + NOTICE + THIRD_PARTY.md)"
  printf '%s\n' "$ACTUAL_ROOTS"
  STATUS=1
else
  echo "package top level: 3ds2apple-launcher.app + LICENSE + NOTICE + THIRD_PARTY.md"
fi
for text in "${LICENSE_TEXTS[@]}"; do
  if ! grep -Fxq "$text" <<< "$ZIP_ENTRIES"; then
    echo "PACKAGE LICENCE TEXT MISSING: $text"; STATUS=1; continue
  fi
  ZIP_TEXT_SHA="$(unzip -p "$OUT_DIR/$PACKAGE_NAME.zip" "$text" | shasum -a 256 | awk '{print $1}')"
  REPO_TEXT_SHA="$(shasum -a 256 "$ROOT/$text" | awk '{print $1}')"
  if [ "$ZIP_TEXT_SHA" != "$REPO_TEXT_SHA" ]; then
    echo "PACKAGE LICENCE TEXT MISMATCH: $text ($ZIP_TEXT_SHA != $REPO_TEXT_SHA)"; STATUS=1
  else
    echo "package licence text: $text sha256 $ZIP_TEXT_SHA (matches repository)"
  fi
done
if grep -E -i '(\.cci|\.3ds|\.ipa|\.dylib|GameRom|GamePack|screenshots/)' /tmp/zl-package-list.txt; then
  echo "PACKAGE CONTAINS FORBIDDEN GAME/BUILD ENTRIES"; STATUS=1
else
  echo "package contains no ROM/IPA/dylib/screenshot entries"
fi

echo "== packaged app verification (fresh extraction) =="
PACKAGED_FW="3ds2apple-launcher.app/Contents/Resources/MoltenVK.framework/MoltenVK"
if grep -q "$PACKAGED_FW" /tmp/zl-package-list.txt; then
  echo "package carries the launcher-embedded MoltenVK.framework"
else
  echo "PACKAGE MISSING $PACKAGED_FW"; STATUS=1
fi
rm -rf /tmp/zl-macos-verify
mkdir -p /tmp/zl-macos-verify
ditto -x -k "$OUT_DIR/$PACKAGE_NAME.zip" /tmp/zl-macos-verify
VERIFY_APP="/tmp/zl-macos-verify/3ds2apple-launcher.app"
VERIFY_BIN="$VERIFY_APP/Contents/MacOS/3ds2apple-launcher"
if [ -x "$VERIFY_BIN" ] && THREEDS2APPLE_ROOT="$ROOT" "$VERIFY_BIN" --selfcheck > /tmp/zl-launcher-selfcheck-packaged.log 2>&1; then
  echo "packaged app selfcheck PASSED: $(tail -1 /tmp/zl-launcher-selfcheck-packaged.log)"
else
  echo "packaged app selfcheck FAILED"
  tail -20 /tmp/zl-launcher-selfcheck-packaged.log 2>/dev/null
  STATUS=1
fi
VERIFY_ARCHS="$(lipo -archs "$VERIFY_BIN" 2>/dev/null || echo "unknown")"
if [ -d "$VERIFY_APP" ]; then
  echo "packaged app: $(stat -f%z "$OUT_DIR/$PACKAGE_NAME.zip") bytes zip, archs $VERIFY_ARCHS, version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VERIFY_APP/Contents/Info.plist" 2>/dev/null) build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$VERIFY_APP/Contents/Info.plist" 2>/dev/null)"
fi

echo "data root (headless): $DATA_ROOT"
echo "version: $VERSION build $BUILD_NUMBER"
echo "== vm-build done (status $STATUS) =="
echo "zip: $OUT_DIR/$PACKAGE_NAME.zip"
echo "selfcheck: $SELFCHECK_RESULT"
echo "screenshots: $SHOT_COUNT"
exit $STATUS
