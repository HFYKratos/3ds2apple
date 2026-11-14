#!/usr/bin/env bash
# vm-build.sh - build the macOS launcher (Release, universal), run its
# self-checks, render the localized non-game UI screenshots and assemble the
# distributable zip. Intended to be copied to the macOS build VM (inside the
# 3ds2apple checkout) and run over SSH:
#
#   cd ~/3ds2apple/launcher/macos && bash scripts/vm-build.sh
#
# It never needs a ROM, an iPhone, an Apple ID or the network: the screenshots
# and self-checks use the mock backends.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

export PATH=/usr/local/bin:$PATH
CONFIG="${CONFIG:-Release}"
LOG=/tmp/zl-launcher-build.log
VERSION="$(sed -n 's/^        MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || VERSION="0.2.0"
DIST=/tmp/zl-macos-ui
PACKAGE_NAME="3ds2apple-launcher-${VERSION}-macos-universal"

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
    echo "icon icns INVALID"; exit 1
  fi
else
  echo "ICON MISSING: $ICON"; exit 1
fi

echo "== localizations =="
find "$APP/Contents/Resources" -maxdepth 1 -name '*.lproj' -print | sort
for lproj in en.lproj zh-Hans.lproj; do
  if [ -f "$APP/Contents/Resources/$lproj/InfoPlist.strings" ]; then
    echo "$lproj/InfoPlist.strings: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Resources/$lproj/InfoPlist.strings" 2>/dev/null || echo unreadable)"
  else
    echo "$lproj/InfoPlist.strings MISSING"; exit 1
  fi
done

echo "== selfcheck =="
if "$BIN" --selfcheck > /tmp/zl-launcher-selfcheck.log 2>&1; then
  echo "selfcheck PASSED"
  SELFCHECK_RESULT="$(tail -1 /tmp/zl-launcher-selfcheck.log)"
else
  echo "selfcheck FAILED"
  SELFCHECK_RESULT="FAILED"
fi
tail -12 /tmp/zl-launcher-selfcheck.log

echo "== screenshots =="
rm -rf screenshots
for theme in dark light; do
  if "$BIN" --screenshot-dir screenshots --theme "$theme" --lang all --mock > "/tmp/zl-launcher-shots-$theme.log" 2>&1; then
    echo "screenshots ($theme) PASSED"
  else
    echo "screenshots ($theme) FAILED"
    tail -20 "/tmp/zl-launcher-shots-$theme.log"
  fi
done
ls -l screenshots | tail -25
echo "screenshot count: $(ls screenshots | wc -l | tr -d ' ')"

echo "== package =="
rm -rf "$DIST"
mkdir -p "$DIST/$PACKAGE_NAME"
ditto "$APP" "$DIST/$PACKAGE_NAME/3ds2apple-launcher.app"
cp README.md "$DIST/$PACKAGE_NAME/README.md" 2>/dev/null || true
mkdir -p "$DIST/$PACKAGE_NAME/screenshots"
cp screenshots/*.png "$DIST/$PACKAGE_NAME/screenshots/" 2>/dev/null || true
cat > "$DIST/$PACKAGE_NAME/PACKAGE-README.txt" <<README
3ds2apple macOS launcher $VERSION (build 2) - universal (arm64 + x86_64), unsigned.
Built on the macOS build VM with Xcode 26.6 (17F113) and xcodegen, Release.

Contents
  3ds2apple-launcher.app         the launcher app (drag to Applications; unsigned dev build)
  screenshots/                   non-game UI evidence, English and Simplified Chinese, dark/light
  README.md                      developer overview
  PACKAGE-README.txt             this file

Open it
  Unzip anywhere and double-click 3ds2apple-launcher.app. Because the app is not
  signed/notarized, macOS may require right-click -> Open the first time. On Apple
  silicon it runs natively; on Intel the same bundle runs through its x86_64 slice.
  The app is the launcher only: it never bundles a ROM, game data, an IPA or Impactor.
  It drives the user's own 3ds2apple checkout (Xcode signing + devpush) when used.

Language
  The interface follows the macOS system language: Simplified Chinese -> Chinese,
  everything else -> English. Settings (gear) can force English or Chinese.

Icon
  AppIcon.icns inside the app is generated from the iOS shell app icon
  (ios/app/Assets.xcassets/AppIcon.appiconset/icon-1024.png), so the launcher and
  the iPhone/iPad shell app look the same.

Build evidence
  xcodebuild Release: PASSED
  universal binary: $(lipo -archs "$BIN" 2>/dev/null || echo "see above")
  selfcheck: $SELFCHECK_RESULT
  screenshots: $(ls screenshots | wc -l | tr -d ' ') PNGs (en + zh, dark + light)
  raw logs on the build VM: /tmp/zl-launcher-build.log, /tmp/zl-launcher-selfcheck.log

No ROM, game pack, game key or device data is included in this package.
README
cd "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_NAME" "$PACKAGE_NAME.zip"
shasum -a 256 "$PACKAGE_NAME.zip" | tee "$PACKAGE_NAME.zip.sha256"
echo "zip: $DIST/$PACKAGE_NAME.zip"
ls -l "$DIST/$PACKAGE_NAME.zip"
echo "== vm-build done =="
