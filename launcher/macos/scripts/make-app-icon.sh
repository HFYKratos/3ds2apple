#!/usr/bin/env bash
# make-app-icon.sh - regenerate launcher/macos/Resources/AppIcon.icns (and the
# 1024 px PNG used inside the About panel) from the iOS shell app icon, using only
# macOS built-in tooling. Run on a Mac from the repository root:
#
#   bash launcher/macos/scripts/make-app-icon.sh
#
# The generated files are committed under launcher/macos/Resources so a normal
# build does not need this step.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/ios/app/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
OUT="$HERE/Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"

if [ ! -f "$SRC" ]; then
  echo "missing iOS app icon: $SRC"; exit 1
fi
mkdir -p "$ICONSET" "$OUT"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
            "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$SRC" --out "$ICONSET/$2.png" >/dev/null
done
iconutil -c icns -o "$OUT/AppIcon.icns" "$ICONSET"
sips -z 1024 1024 "$SRC" --out "$OUT/AppIcon-1024.png" >/dev/null
echo "wrote $OUT/AppIcon.icns and $OUT/AppIcon-1024.png"
