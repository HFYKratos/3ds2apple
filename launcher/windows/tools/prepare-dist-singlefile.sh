#!/usr/bin/env bash
# Build the one-executable Windows launcher ZIP (self-contained .NET single-file).
#
# The exe embeds the ROM-free shell template, the pinned official Impactor/plumesign,
# the Bin/ tool CLIs, 3dsrecomp.exe + Darwin stubs/shim (Windows local build) and
# LICENSE/NOTICE/THIRD_PARTY. On first run it extracts them to
# %LOCALAPPDATA%\3ds2apple\distribution\<version>. The user-facing ZIP contains
# 3ds2apple-launcher.exe plus the repository licence texts (LICENSE, NOTICE,
# THIRD_PARTY.md) at the ZIP root, byte-identical to the repository files. Those
# texts ship inside both platform packages; they are never separate Release
# assets (see CONTRIBUTING.md#release-policy). The clean-run-win folder still
# holds only the exe, so the clean-folder --self-test semantics are unchanged.
#
# The official LLVM 23.1.6 toolchain (clang.exe / llvm-ar.exe / ld64.lld.exe +
# lib/clang/23/include) is staged under Bin/llvm when available (THREEDS2APPLE_LLVM_DIR,
# default build/win-toolchain/llvm or third_party/llvm-win). Only the tool executables and
# clang's resource headers are embedded; the release folder's LLVM-C/libclang/LTO/libLLDB
# DLLs and PDBs are not needed (tools import system DLLs only). It is NOT faked: without
# it the packaged launcher's Deploy page shows one actionable local-toolchain error + Retry.
#
# Data location (task-39): the packaged exe keeps its workspace and extracts the payload
# into <exe-dir>/3ds2apple-data when that folder is writable, and falls back to
# %LOCALAPPDATA%/3ds2apple only for a read-only launcher folder. The clean-folder self-test
# below verifies the portable extraction on the Linux host.
#
# Output defaults to the repo's own git-ignored out/launchers/ (never temp_transfer).
#
# Usage: tools/prepare-dist-singlefile.sh [output-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WINDOWS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$WINDOWS_ROOT/../.." && pwd)"
OUTPUT_ROOT="$REPO_ROOT/out/launchers"
if [ "$#" -ge 1 ]; then OUTPUT_ROOT="$1"; fi
mkdir -p "$OUTPUT_ROOT"
VERSION="$(awk -F'[<>]' '/<Version>/{print $3; exit}' "$WINDOWS_ROOT/Directory.Build.props")"
if [ -z "$VERSION" ]; then VERSION="0.1.6-beta2"; fi
EXE_NAME="3ds2apple-launcher.exe"
PUBLISH_DIR="$OUTPUT_ROOT/publish-win-x64"
ZIP_PATH="$OUTPUT_ROOT/3ds2apple-windows-single-$VERSION.zip"

if [ -z "${DOTNET_ROOT:-}" ]; then DOTNET_ROOT="$HOME/.dotnet10"; fi
export DOTNET_ROOT
export PATH="$DOTNET_ROOT:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

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

# 2. Pinned official Impactor v2.7.3 + plumesign (fetch + verify when absent).
if [ ! -f "$WINDOWS_ROOT/vendor/impactor/Impactor-windows-x86_64-portable.exe" ]; then
  "$WINDOWS_ROOT/tools/fetch-impactor.sh" "$WINDOWS_ROOT/vendor/impactor"
fi

# 3. Tool CLIs (cross-built Rust binaries).
for tool in 3ds2apple-pack.exe devpush.exe; do
  if [ ! -f "$WINDOWS_ROOT/Bin/$tool" ]; then
    echo "error: Bin/$tool is missing. Build it for x86_64-pc-windows-gnu first." >&2
    exit 2
  fi
done

# 3b. Windows local-build payload: 3dsrecomp.exe (built from the pinned upstream).
if [ ! -f "$WINDOWS_ROOT/Bin/3dsrecomp.exe" ]; then
  for candidate in \
    "$REPO_ROOT/third_party/3dsrecomp/target/x86_64-pc-windows-gnu/release/3dsrecomp.exe" \
    "$REPO_ROOT/third_party/3dsrecomp/target/release/3dsrecomp.exe"; do
    if [ -f "$candidate" ]; then
      cp "$candidate" "$WINDOWS_ROOT/Bin/3dsrecomp.exe"
      break
    fi
  done
fi
if [ -f "$WINDOWS_ROOT/Bin/3dsrecomp.exe" ]; then
  echo "[single] 3dsrecomp.exe staged ($(sha256sum "$WINDOWS_ROOT/Bin/3dsrecomp.exe" | cut -d' ' -f1 | cut -c1-16)…)"
else
  echo "[single] WARN: Bin/3dsrecomp.exe is missing; the packaged launcher will show one actionable local-toolchain error on Deploy"
fi

# 3c. Optional official LLVM 23.1.6 toolchain (real local GamePack compile).
LLVM_SOURCE="${THREEDS2APPLE_LLVM_DIR:-$REPO_ROOT/build/win-toolchain/llvm}"
if [ -d "$LLVM_SOURCE/lib/clang" ] && [ -f "$LLVM_SOURCE/bin/clang.exe" ]; then
  LLVM_STAGE="$WINDOWS_ROOT/Bin/llvm"
  rm -rf "$LLVM_STAGE"
  mkdir -p "$LLVM_STAGE/bin" "$LLVM_STAGE/lib/clang"
  for tool in clang.exe llvm-ar.exe ld64.lld.exe llvm-nm.exe llvm-objdump.exe; do
    if [ -f "$LLVM_SOURCE/bin/$tool" ]; then cp "$LLVM_SOURCE/bin/$tool" "$LLVM_STAGE/bin/"; fi
  done
  # The official Windows tools link only against system DLLs (verified with objdump
  # imports); the 300+ MB of LLVM-C/libclang/LTO/libLLDB DLLs and PDBs in the release
  # folder are NOT needed by clang/ld64.lld/llvm-ar and are deliberately not embedded.
  # The clang resource headers 3dsrecomp's generated C needs (-isystem).
  for clang_dir in "$LLVM_SOURCE"/lib/clang/*/; do
    version="$(basename "$clang_dir")"
    if [ -d "${clang_dir}include" ]; then
      mkdir -p "$LLVM_STAGE/lib/clang/$version/include"
      cp -a "${clang_dir}include/." "$LLVM_STAGE/lib/clang/$version/include/"
    fi
  done
  for notice in LICENSE.TXT LICENSE.txt; do
    if [ -f "$LLVM_SOURCE/$notice" ]; then cp "$LLVM_SOURCE/$notice" "$LLVM_STAGE/LICENSE.TXT"; fi
  done
  echo "[single] LLVM staged under Bin/llvm ($(du -sh "$LLVM_STAGE" | cut -f1))"
else
  echo "[single] WARN: official LLVM 23.1.6 not found at $LLVM_SOURCE; packaging without it (Deploy shows one actionable local-toolchain error; set THREEDS2APPLE_LLVM_DIR to stage it)"
fi

echo "[single] Bin tools: $(ls "$WINDOWS_ROOT/Bin" | tr '\n' ' ')"

# 4. Single-file self-contained Windows publish (Release embeds the payload).
rm -rf "$PUBLISH_DIR"
mkdir -p "$PUBLISH_DIR"
dotnet publish "$WINDOWS_ROOT/src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj" \
  -c Release -r win-x64 --self-contained true -o "$PUBLISH_DIR" \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false \
  --nologo

# Only the executable stays in the release folder.
find "$PUBLISH_DIR" -mindepth 1 -maxdepth 1 ! -name "$EXE_NAME" -exec rm -rf {} +

# 5. ZIP = the exe + the repository licence texts at the ZIP root. Both shipped
#    packages carry LICENSE/NOTICE/THIRD_PARTY.md inside the archive (the GitHub
#    Release still has exactly two assets; the texts are never separate uploads),
#    and each text inside the archive must be byte-identical to the repository
#    file. scripts/release/verify-release.sh enforces the same rules.
LICENSE_TEXTS=(LICENSE NOTICE THIRD_PARTY.md)
for text in "${LICENSE_TEXTS[@]}"; do
  if [ ! -f "$REPO_ROOT/$text" ]; then
    echo "error: repository licence text is missing: $REPO_ROOT/$text" >&2
    exit 2
  fi
done
rm -f "$ZIP_PATH"
(cd "$PUBLISH_DIR" && zip -j -q "$ZIP_PATH" "$EXE_NAME")
(cd "$REPO_ROOT" && zip -q -j "$ZIP_PATH" "${LICENSE_TEXTS[@]}")
# Positive/negative gate: the archive is exactly the exe + the three texts (no
# directories, nothing else) and the texts match the repository bytes.
ZIP_ENTRIES="$(unzip -Z1 "$ZIP_PATH" | LC_ALL=C sort)"
EXPECTED_ENTRIES="$(printf '%s\n' "$EXE_NAME" "${LICENSE_TEXTS[@]}" | LC_ALL=C sort)"
if [ "$ZIP_ENTRIES" != "$EXPECTED_ENTRIES" ]; then
  echo "error: unexpected entries in $ZIP_PATH (expected $EXE_NAME + LICENSE + NOTICE + THIRD_PARTY.md):" >&2
  printf '%s\n' "$ZIP_ENTRIES" >&2
  exit 1
fi
for text in "${LICENSE_TEXTS[@]}"; do
  ZIP_TEXT_SHA="$(unzip -p "$ZIP_PATH" "$text" | sha256sum | cut -d' ' -f1)"
  REPO_TEXT_SHA="$(sha256sum "$REPO_ROOT/$text" | cut -d' ' -f1)"
  if [ "$ZIP_TEXT_SHA" != "$REPO_TEXT_SHA" ]; then
    echo "error: $text in $ZIP_PATH ($ZIP_TEXT_SHA) differs from the repository file ($REPO_TEXT_SHA)" >&2
    exit 1
  fi
done
echo "[single] zip entries: $EXE_NAME + LICENSE + NOTICE + THIRD_PARTY.md (licence texts byte-identical to the repository)"
echo "[single] zip: $ZIP_PATH"
unzip -l "$ZIP_PATH"
sha256sum "$ZIP_PATH" "$PUBLISH_DIR/$EXE_NAME" | tee "$OUTPUT_ROOT/SHA256SUMS-single.txt"

# 6. Clean-folder staging for the Windows exe (acceptance: run --self-test there).
CLEAN_DIR="$OUTPUT_ROOT/clean-run-win"
rm -rf "$CLEAN_DIR"
mkdir -p "$CLEAN_DIR"
cp "$PUBLISH_DIR/$EXE_NAME" "$CLEAN_DIR/"
echo "[single] clean folder: $CLEAN_DIR"
echo "[single] Windows acceptance: cd $CLEAN_DIR && $EXE_NAME --self-test"

# 7. Linux-host clean-folder self-test of the SAME embedded payload (WSL/CI cannot run
#    the Windows PE). Publish a framework-dependent single-file Linux executable,
#    copy it alone into a clean folder and run --self-test with an isolated HOME so the
#    first-run payload extraction into LOCALAPPDATA is exercised for real.
if command -v dotnet >/dev/null 2>&1; then
  LINUX_PUBLISH="$OUTPUT_ROOT/self-test-linux-x64"
  rm -rf "$LINUX_PUBLISH"
  dotnet publish "$WINDOWS_ROOT/src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj" \
    -c Release -r linux-x64 --self-contained false -o "$LINUX_PUBLISH" \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=false \
    -p:DebugType=None -p:DebugSymbols=false --nologo
  CLEAN_LINUX="$OUTPUT_ROOT/clean-run-linux"
  rm -rf "$CLEAN_LINUX"
  mkdir -p "$CLEAN_LINUX/home"
  cp "$LINUX_PUBLISH/3ds2apple-launcher" "$CLEAN_LINUX/"
  ( cd "$CLEAN_LINUX" && HOME="$CLEAN_LINUX/home" XDG_DATA_HOME="$CLEAN_LINUX/home/.local/share" \
      DOTNET_CLI_TELEMETRY_OPTOUT=1 ./3ds2apple-launcher --self-test > self-test.log 2>&1 ) || true
  echo "----- clean-folder self-test (payload extraction, Linux host) -----"
  tail -45 "$CLEAN_LINUX/self-test.log"
  if grep -q "SELF-TEST OK" "$CLEAN_LINUX/self-test.log"; then
    echo "[single] clean-folder self-test PASS ($CLEAN_LINUX/self-test.log)"
  else
    echo "[single] clean-folder self-test FAIL ($CLEAN_LINUX/self-test.log)" >&2
    exit 1
  fi
else
  echo "[single] WARN: dotnet not on PATH; skipped the Linux clean-folder self-test"
fi
