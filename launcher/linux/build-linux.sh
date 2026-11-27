#!/usr/bin/env bash
# Build the 3ds2apple Linux launcher (0.2.3 P0).
#
#   ./launcher/linux/build-linux.sh [--tar] [--output <dir>]
#
# Publishes the shared Avalonia launcher for linux-x64 into a self-contained
# folder and copies the repository licence texts next to it. It never embeds ROMs,
# IPAs or game data; the optional shell/tool payload is staged separately (P3).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUTPUT="$REPO/out/launchers/3ds2apple-launcher-linux-x64"
MAKE_TAR=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tar) MAKE_TAR=1; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

DOTNET="${DOTNET:-dotnet}"
if ! command -v "$DOTNET" >/dev/null 2>&1; then
  if [ -x "$HOME/.dotnet10/dotnet" ]; then
    DOTNET="$HOME/.dotnet10/dotnet"
  else
    echo "error: .NET 10 SDK not found (install it or set DOTNET=...)." >&2
    exit 2
  fi
fi

echo "[linux] publishing self-contained linux-x64 launcher -> $OUTPUT"
rm -rf "$OUTPUT"
"$DOTNET" publish \
  "$REPO/launcher/windows/src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj" \
  -c Release -r linux-x64 --self-contained true \
  -p:EmbedDistributionPayload=false \
  -o "$OUTPUT"

for text in LICENSE NOTICE THIRD_PARTY.md; do
  if [ ! -f "$REPO/$text" ]; then
    echo "error: $text is missing from the repository root." >&2
    exit 2
  fi
  cp "$REPO/$text" "$OUTPUT/$text"
done

BIN="$OUTPUT/3ds2apple-launcher"
chmod +x "$BIN"
echo "[linux] launcher: $BIN"
echo "[linux] self-test: $BIN --self-test"

if [ "$MAKE_TAR" = "1" ]; then
  TAR="$REPO/out/launchers/3ds2apple-launcher-linux-x64.tar.gz"
  tar -czf "$TAR" -C "$(dirname "$OUTPUT")" "$(basename "$OUTPUT")"
  echo "[linux] archive: $TAR"
fi
