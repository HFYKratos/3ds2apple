#!/usr/bin/env bash
# vm-build.sh - build the macOS launcher (Release, universal), run its
# self-checks, render the localized non-game UI screenshots and assemble the
# user-facing app-only ZIP under the project's own out/launchers/ directory
# (gitignored), per docs/launcher-flow-v2.md.
#
#   cd ~/3ds2apple/launcher/macos && bash scripts/vm-build.sh
#
# It never needs a ROM, an iPhone, an Apple ID or the network: the screenshots
# and self-checks use the mock backends.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
ROOT="$(cd "$HERE/../.." && pwd)"

export PATH=/usr/local/bin:$PATH
CONFIG="${CONFIG:-Release}"
LOG=/tmp/zl-launcher-build.log
VERSION="$(sed -n 's/^        MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || VERSION="0.2.1"
BUILD_NUMBER="$(sed -n 's/^        CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
[ -n "$BUILD_NUMBER" ] || BUILD_NUMBER="3"
OUT_DIR="$ROOT/out/launchers"
PACKAGE_NAME="3ds2apple-launcher-${VERSION}-macos-app"
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
echo "version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null) build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null)"

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

echo "== package (app-only ZIP under out/launchers) =="
mkdir -p "$OUT_DIR"
rm -rf /tmp/zl-macos-package
mkdir -p /tmp/zl-macos-package
ditto "$APP" "/tmp/zl-macos-package/3ds2apple-launcher.app"
rm -f "$OUT_DIR/$PACKAGE_NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "/tmp/zl-macos-package/3ds2apple-launcher.app" "$OUT_DIR/$PACKAGE_NAME.zip"
shasum -a 256 "$OUT_DIR/$PACKAGE_NAME.zip" | tee "$OUT_DIR/$PACKAGE_NAME.zip.sha256"
ZIP_SIZE="$(stat -f%z "$OUT_DIR/$PACKAGE_NAME.zip")"
echo "zip: $OUT_DIR/$PACKAGE_NAME.zip ($ZIP_SIZE bytes)"

echo "== package verification =="
unzip -t "$OUT_DIR/$PACKAGE_NAME.zip" | tail -2
echo "zip entries: $(unzip -l "$OUT_DIR/$PACKAGE_NAME.zip" | tail -1)"
if unzip -l "$OUT_DIR/$PACKAGE_NAME.zip" | grep -E -i '(\.cci|\.3ds|\.ipa|\.dylib|GameRom|GamePack|screenshots/)'; then
  echo "PACKAGE CONTAINS FORBIDDEN GAME/BUILD ENTRIES"; STATUS=1
else
  echo "package contains only the .app (no ROM/IPA/dylib/screenshot entries)"
fi

echo "== vm-build done (status $STATUS) =="
echo "zip: $OUT_DIR/$PACKAGE_NAME.zip"
echo "selfcheck: $SELFCHECK_RESULT"
echo "screenshots: $SHOT_COUNT"
exit $STATUS
