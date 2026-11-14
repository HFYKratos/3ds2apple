#!/usr/bin/env bash
# Build the one-executable Windows launcher ZIP (self-contained .NET single-file).
#
# The exe embeds the ROM-free shell template, the pinned official Impactor/plumesign,
# the Bin/ tool CLIs and LICENSE/NOTICE/THIRD_PARTY; on first run it extracts them to
# %LOCALAPPDATA%\3ds2apple\distribution\<version>. The user-facing ZIP contains exactly
# one file: 3ds2apple-launcher.exe.
#
# Requirements: .NET 10 SDK, cross-built Windows tool binaries under Bin/, the verified
# Impactor bundle under vendor/impactor/ and the ROM-free shell template under shell/.
# Every missing input aborts instead of producing a package that cannot install.
#
# Usage: tools/prepare-dist-singlefile.sh [output-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINDOWS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_ROOT="/mnt/f/temp_transfer/dist/windows-single"
if [ "$#" -ge 1 ]; then OUTPUT_ROOT="$1"; fi
VERSION="$(awk -F'[<>]' '/<Version>/{print $3; exit}' "$WINDOWS_ROOT/Directory.Build.props")"
if [ -z "$VERSION" ]; then VERSION="0.1.0"; fi
EXE_NAME="3ds2apple-launcher.exe"
PUBLISH_DIR="$OUTPUT_ROOT/publish"
ZIP_PATH="$OUTPUT_ROOT/3ds2apple-windows-single-$VERSION.zip"

if [ -z "${DOTNET_ROOT:-}" ]; then DOTNET_ROOT="$HOME/.dotnet10"; fi
export DOTNET_ROOT
export PATH="$DOTNET_ROOT:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1

echo "[single] 3ds2apple Windows launcher $VERSION -> $ZIP_PATH"

# 1. Base shell template (ROM-free; macOS build product, never committed).
if [ ! -f "$WINDOWS_ROOT/shell/manifest.json" ] || [ ! -f "$WINDOWS_ROOT/shell/3ds2apple-shell.ipa" ]; then
  echo "error: shell/manifest.json + shell/3ds2apple-shell.ipa are required (see shell/README.md)." >&2
  exit 2
fi
SHELL_SHA="$(sha256sum "$WINDOWS_ROOT/shell/3ds2apple-shell.ipa" | cut -d" " -f1)"
PINNED_SHA="$(grep -o '[0-9a-f]\{64\}' "$WINDOWS_ROOT/shell/manifest.json" | head -1)"
if [ -n "$PINNED_SHA" ] && [ "$SHELL_SHA" != "$PINNED_SHA" ]; then
  echo "error: shell IPA SHA-256 $SHELL_SHA does not match shell/manifest.json ($PINNED_SHA)." >&2
  exit 2
fi
echo "[single] shell template verified ($SHELL_SHA)"

# 2. Pinned official Impactor v2.7.2 + plumesign (fetch + verify when absent).
if [ ! -f "$WINDOWS_ROOT/vendor/impactor/Impactor-windows-x86_64-portable.exe" ]; then
  "$WINDOWS_ROOT/tools/fetch-impactor.sh" "$WINDOWS_ROOT/vendor/impactor"
fi

# 3. Tool CLIs (cross-built Rust binaries).
for tool in 3ds2apple-pack.exe builder-windows.exe devpush.exe; do
  if [ ! -f "$WINDOWS_ROOT/Bin/$tool" ]; then
    echo "error: Bin/$tool is missing. Build it for x86_64-pc-windows-gnu first." >&2
    exit 2
  fi
done
echo "[single] Bin tools: $(ls "$WINDOWS_ROOT/Bin" | tr "\n" " ")"

# 4. Single-file self-contained publish (Release embeds the payload).
rm -rf "$PUBLISH_DIR"
mkdir -p "$PUBLISH_DIR"
dotnet publish "$WINDOWS_ROOT/src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj" \
  -c Release -r win-x64 --self-contained true -o "$PUBLISH_DIR" \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false \
  --nologo

# Only the executable stays in the release folder (native packages ship loose .pdb files).
find "$PUBLISH_DIR" -maxdepth 1 -type f ! -name "$EXE_NAME" -delete

# 5. ZIP with exactly one file inside.
rm -f "$ZIP_PATH"
(cd "$PUBLISH_DIR" && zip -j -q "$ZIP_PATH" "$EXE_NAME")
echo "[single] zip: $ZIP_PATH"
unzip -l "$ZIP_PATH"
sha256sum "$ZIP_PATH" "$PUBLISH_DIR/$EXE_NAME" | tee "$OUTPUT_ROOT/SHA256SUMS-single.txt"

# 6. Clean-folder staging (no other files next to the exe).
CLEAN_DIR="$OUTPUT_ROOT/clean-run"
rm -rf "$CLEAN_DIR"
mkdir -p "$CLEAN_DIR"
cp "$PUBLISH_DIR/$EXE_NAME" "$CLEAN_DIR/"
echo "[single] clean folder: $CLEAN_DIR"
echo "[single] next: cd $CLEAN_DIR && ./$EXE_NAME --self-test"