#!/usr/bin/env bash
# vm-build.sh - build the macOS launcher, run its self-checks and render the
# non-game UI screenshots. Intended to be copied to the macOS build VM (inside
# the 3ds2apple checkout) and run over SSH by launcher-macos:
#
#   cd ~/3ds2apple/launcher/macos && bash scripts/vm-build.sh
#
# It never needs a ROM, an iPhone, an Apple ID or the network: the screenshots
# and self-checks use the mock backends.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

export PATH=/usr/local/bin:$PATH
LOG=/tmp/zl-launcher-build.log

echo "== xcodegen =="
if ! xcodegen generate --spec project.yml > "$LOG.xcodegen" 2>&1; then
  echo "xcodegen FAILED"; tail -30 "$LOG.xcodegen"; exit 1
fi
echo "xcodegen ok"

echo "== xcodebuild =="
if xcodebuild -project 3ds2apple-launcher.xcodeproj -scheme 3ds2apple-launcher \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath build build > "$LOG" 2>&1; then
  echo "xcodebuild PASSED"
  grep -E "warning:" "$LOG" | head -20 || true
else
  echo "xcodebuild FAILED"
  grep -E "error:" "$LOG" | head -60 || true
  echo "---- tail ----"
  tail -40 "$LOG"
  exit 1
fi

APP="build/Build/Products/Debug/3ds2apple-launcher.app"
BIN="$APP/Contents/MacOS/3ds2apple-launcher"
if [ ! -x "$BIN" ]; then
  echo "app binary missing: $BIN"; exit 1
fi
echo "app: $APP"
echo "binary: $(ls -l "$BIN" | awk '{print $5}') bytes"
echo "bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"

echo "== selfcheck =="
if "$BIN" --selfcheck > /tmp/zl-launcher-selfcheck.log 2>&1; then
  echo "selfcheck PASSED"
else
  echo "selfcheck FAILED (exit $?)"
fi
tail -40 /tmp/zl-launcher-selfcheck.log

echo "== screenshots =="
rm -rf screenshots
for theme in dark light; do
  if "$BIN" --screenshot-dir screenshots --theme "$theme" --mock > "/tmp/zl-launcher-shots-$theme.log" 2>&1; then
    echo "screenshots ($theme) PASSED"
  else
    echo "screenshots ($theme) FAILED (mock rendering)"
    tail -20 "/tmp/zl-launcher-shots-$theme.log"
  fi
done
cp /tmp/zl-launcher-shots-dark.log /tmp/zl-launcher-shots.log 2>/dev/null || true
tail -12 /tmp/zl-launcher-shots.log
ls -l screenshots 2>/dev/null || true
echo "== vm-build done =="
