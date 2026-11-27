#!/usr/bin/env bash
# Build the 3ds2apple Linux launcher (0.2.3 P0/P3).
#
#   ./launcher/linux/build-linux.sh [--payload] [--tar] [--output <dir>]
#                                   [--shell-dir <dir>] [--pack-bin <file>]
#                                   [--devpush-bin <file>] [--plumesign <file>]
#
# Publishes the shared Avalonia launcher for linux-x64 into a self-contained
# folder and copies the repository licence texts next to it. With --payload it also
# stages the runtime payload used by the installed launcher:
#   Shell/                         ROM-free shell template IPA + manifest (macOS build)
#   ThirdParty/Impactor/           verified official plumesign-linux-x86_64 + PINS/licences
#   Bin/3ds2apple-pack             Linux pack CLI (builder/pack)
#   Bin/devpush                    Linux device bridge (tools/devpush)
#   licenses/                      LICENSE, NOTICE, THIRD_PARTY.md
# It never embeds ROMs, IPAs, keys or game data in the git tree; binaries stay in
# the git-ignored output folder.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUTPUT="$REPO/out/launchers/3ds2apple-launcher-linux-x64"
MAKE_TAR=0
MAKE_PAYLOAD=0
SHELL_DIR="${THREEDS2APPLE_SHELL_DIR:-$REPO/out/shell}"
PACK_BIN="${THREEDS2APPLE_PACK_BIN:-$REPO/builder/target/release/3ds2apple-pack}"
DEVPUSH_BIN="${THREEDS2APPLE_DEVPUSH_BIN:-$REPO/tools/devpush/target/release/devpush}"
PLUMESIGN="${THREEDS2APPLE_PLUMESIGN_BIN:-$REPO/launcher/linux/vendor/plumesign-linux-x86_64}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --payload) MAKE_PAYLOAD=1; shift ;;
    --tar) MAKE_TAR=1; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --shell-dir) SHELL_DIR="$2"; shift 2 ;;
    --pack-bin) PACK_BIN="$2"; shift 2 ;;
    --devpush-bin) DEVPUSH_BIN="$2"; shift 2 ;;
    --plumesign) PLUMESIGN="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
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

if [ "$MAKE_PAYLOAD" = "1" ]; then
  echo "[linux] staging P3 payload"
  for required in "$SHELL_DIR/manifest.json" "$SHELL_DIR/3ds2apple-shell.ipa" "$PACK_BIN" "$DEVPUSH_BIN" "$PLUMESIGN"; do
    if [ ! -f "$required" ]; then
      echo "error: payload file missing: $required" >&2
      echo "       build it first (shell template: macOS build; pack: cargo build --release -p builder-pack;" >&2
      echo "       devpush: cargo build --release in tools/devpush; plumesign: official v2.7.3 Linux download)." >&2
      exit 2
    fi
  done
  mkdir -p "$OUTPUT/Shell" "$OUTPUT/Bin" "$OUTPUT/ThirdParty/Impactor" "$OUTPUT/licenses"
  cp "$SHELL_DIR/manifest.json" "$SHELL_DIR/3ds2apple-shell.ipa" "$OUTPUT/Shell/"
  cp "$PACK_BIN" "$OUTPUT/Bin/3ds2apple-pack"
  cp "$DEVPUSH_BIN" "$OUTPUT/Bin/devpush"
  cp "$PLUMESIGN" "$OUTPUT/ThirdParty/Impactor/plumesign-linux-x86_64"
  cp "$REPO/launcher/linux/vendor/PINS.json" \
     "$REPO/launcher/linux/vendor/LICENSE-Impactor-MIT.txt" \
     "$REPO/launcher/linux/vendor/LICENSE-apple-codesign-MPL-2.0.txt" \
     "$REPO/launcher/linux/vendor/README-source-and-licenses.txt" \
     "$OUTPUT/ThirdParty/Impactor/"
  cp "$REPO/LICENSE" "$REPO/NOTICE" "$REPO/THIRD_PARTY.md" "$OUTPUT/licenses/"
  chmod +x "$OUTPUT/3ds2apple-launcher" "$OUTPUT/Bin/3ds2apple-pack" "$OUTPUT/Bin/devpush" \
           "$OUTPUT/ThirdParty/Impactor/plumesign-linux-x86_64"
  echo "[linux] payload: Shell + plumesign-linux + pack + devpush + licences"
fi

BIN="$OUTPUT/3ds2apple-launcher"
chmod +x "$BIN"
echo "[linux] launcher: $BIN"
echo "[linux] self-test: $BIN --self-test"

if [ "$MAKE_TAR" = "1" ]; then
  TAR="$REPO/out/launchers/3ds2apple-launcher-linux-x64.tar.gz"
  tar -czf "$TAR" -C "$(dirname "$OUTPUT")" "$(basename "$OUTPUT")"
  echo "[linux] archive: $TAR"
fi
