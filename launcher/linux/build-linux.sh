#!/usr/bin/env bash
# Build the 3ds2apple Linux launcher (0.2.3 P0/P3).
#
#   ./launcher/linux/build-linux.sh [--payload] [--local-aot] [--tar] [--output <dir>]
#                                   [--shell-dir <dir>] [--pack-bin <file>]
#                                   [--devpush-bin <file>] [--plumesign <file>]
#                                   [--llvm-dir <bin dir>] [--recompiler-bin <file>]
#                                   [--skip-publish]
#
# Publishes the shared Avalonia launcher for linux-x64 into a self-contained
# folder and copies the repository licence texts next to it. With --payload it also
# stages the runtime payload used by the installed launcher:
#   Shell/                         ROM-free shell template IPA + manifest (macOS build)
#   ThirdParty/Impactor/           verified official plumesign-linux-x86_64 + PINS/licences
#   Bin/3ds2apple-pack             Linux pack CLI (builder/pack)
#   Bin/devpush                    Linux device bridge (tools/devpush)
#   licenses/                      LICENSE, NOTICE, THIRD_PARTY.md
# With --local-aot it also stages the Linux local-AOT toolchain used by the
# launcher's Deploy/Build button (3dsrecomp + LLVM clang/llvm-ar/ld64.lld subset +
# Darwin stubs/shim/include). --skip-publish reuses an already-published $OUTPUT
# folder (used when assembling the payload on a machine without .NET); a
# stale-publish guard then compares the version embedded in the staged launcher
# bundle with launcher/windows/Directory.Build.props and fails when they differ
# (the published 0.3.0 Linux tar carried a 0.2.2-beta6 launcher this way).
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
MAKE_LOCAL_AOT=0
SKIP_PUBLISH=0
LLVM_DIR="${WINBUILD_LLVM_DIR:-}"
RECOMPILER_BIN="${THREEDS2APPLE_RECOMP:-$REPO/third_party/3dsrecomp/target/release/3dsrecomp}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --payload) MAKE_PAYLOAD=1; shift ;;
    --local-aot) MAKE_LOCAL_AOT=1; shift ;;
    --skip-publish) SKIP_PUBLISH=1; shift ;;
    --tar) MAKE_TAR=1; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --shell-dir) SHELL_DIR="$2"; shift 2 ;;
    --pack-bin) PACK_BIN="$2"; shift 2 ;;
    --devpush-bin) DEVPUSH_BIN="$2"; shift 2 ;;
    --plumesign) PLUMESIGN="$2"; shift 2 ;;
    --llvm-dir) LLVM_DIR="$2"; shift 2 ;;
    --recompiler-bin) RECOMPILER_BIN="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# launcher_bundle_versions FILE - print the "3ds2apple-launcher/<ver>" deps.json
# project keys embedded in the .NET single-file launcher bundle (plain UTF-8;
# read-only, nothing is extracted or executed). A version mismatch here is what
# the stale-publish guard below rejects.
launcher_bundle_versions() {
  LC_ALL=C grep -a -o '"3ds2apple-launcher/[^"]*"' "$1" 2>/dev/null | LC_ALL=C sort -u || true
}

# expected_launcher_version - Version property shared by every launcher package
# (launcher/windows/Directory.Build.props is the single source of truth).
expected_launcher_version() {
  local props="$REPO/launcher/windows/Directory.Build.props"
  [ -f "$props" ] || return 1
  sed -n 's:.*<Version>\([^<]*\)</Version>.*:\1:p' "$props" | head -n 1
}

if [ "$SKIP_PUBLISH" != "1" ]; then
  DOTNET="${DOTNET:-dotnet}"
  if ! command -v "$DOTNET" >/dev/null 2>&1; then
    if [ -x "$HOME/.dotnet10/dotnet" ]; then
      DOTNET="$HOME/.dotnet10/dotnet"
    else
      echo "error: .NET 10 SDK not found (install it or set DOTNET=...)." >&2
      exit 2
    fi
  fi
fi

if [ "$SKIP_PUBLISH" = "1" ]; then
  if [ ! -x "$OUTPUT/3ds2apple-launcher" ]; then
    echo "error: --skip-publish needs an existing published launcher at $OUTPUT" >&2
    exit 2
  fi
  echo "[linux] reusing published launcher at $OUTPUT"
else
  echo "[linux] publishing self-contained linux-x64 launcher -> $OUTPUT"
  rm -rf "$OUTPUT"
  "$DOTNET" publish \
    "$REPO/launcher/windows/src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj" \
    -c Release -r linux-x64 --self-contained true \
    -p:EmbedDistributionPayload=false \
    -o "$OUTPUT"
fi

# Stale-publish guard: --skip-publish reuses an existing published folder, so a
# launcher built for an older version can silently end up in the release payload
# (the published v0.3.0 Linux tar carried a 0.2.2-beta6 launcher while the
# Windows/macOS assets reported 0.3.0). The .NET single-file bundle keeps
# deps.json as plain UTF-8, so the embedded project key is the launcher version.
EXPECTED_LAUNCHER_VERSION="$(expected_launcher_version || true)"
if [ -z "$EXPECTED_LAUNCHER_VERSION" ]; then
  echo "error: cannot read the expected launcher version from $REPO/launcher/windows/Directory.Build.props" >&2
  exit 2
fi
LAUNCHER_BUNDLE_VERSIONS="$(launcher_bundle_versions "$OUTPUT/3ds2apple-launcher")"
if [ -z "$LAUNCHER_BUNDLE_VERSIONS" ]; then
  echo "error: the staged launcher $OUTPUT/3ds2apple-launcher does not embed a 3ds2apple-launcher/<ver> deps.json key; cannot verify launcher version $EXPECTED_LAUNCHER_VERSION (stale publish folder?)" >&2
  exit 2
fi
if ! printf '%s\n' "$LAUNCHER_BUNDLE_VERSIONS" | grep -Fxq "\"3ds2apple-launcher/$EXPECTED_LAUNCHER_VERSION\""; then
  echo "error: stale launcher at $OUTPUT: expected launcher version $EXPECTED_LAUNCHER_VERSION, found $(printf '%s' "$LAUNCHER_BUNDLE_VERSIONS" | tr '\n' ' ')" >&2
  echo "       rebuild the launcher without --skip-publish, or point --output at a fresh publish folder." >&2
  exit 2
fi
echo "[linux] launcher version: $EXPECTED_LAUNCHER_VERSION (stale-publish guard)"

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

if [ "$MAKE_LOCAL_AOT" = "1" ]; then
  echo "[linux] staging Linux local-AOT toolchain"
  if [ -z "$LLVM_DIR" ] || [ ! -x "$LLVM_DIR/clang" ]; then
    echo "error: --local-aot needs --llvm-dir (or WINBUILD_LLVM_DIR) containing clang/llvm-ar/ld64.lld" >&2
    exit 2
  fi
  if [ ! -x "$RECOMPILER_BIN" ]; then
    echo "error: --local-aot needs --recompiler-bin (3dsrecomp Linux build): $RECOMPILER_BIN" >&2
    exit 2
  fi
  for tool in clang llvm-ar ld64.lld; do
    [ -x "$LLVM_DIR/$tool" ] || { echo "error: missing LLVM tool: $LLVM_DIR/$tool" >&2; exit 2; }
  done
  mkdir -p "$OUTPUT/Bin/llvm/bin" "$OUTPUT/Bin/llvm/lib" "$OUTPUT/tools/winbuild" "$OUTPUT/licenses"
  cp -L "$LLVM_DIR/clang" "$LLVM_DIR/llvm-ar" "$LLVM_DIR/ld64.lld" "$OUTPUT/Bin/llvm/bin/"
  for optional in llvm-nm llvm-objdump; do
    [ -x "$LLVM_DIR/$optional" ] && cp -L "$LLVM_DIR/$optional" "$OUTPUT/Bin/llvm/bin/"
  done
  RESOURCE_DIR="$("$LLVM_DIR/clang" -print-resource-dir 2>/dev/null || true)"
  if [ -n "$RESOURCE_DIR" ] && [ -d "$RESOURCE_DIR/include" ]; then
    RESOURCE_VERSION="$(basename "$RESOURCE_DIR")"
    mkdir -p "$OUTPUT/Bin/llvm/lib/clang/$RESOURCE_VERSION"
    cp -a "$RESOURCE_DIR/include" "$OUTPUT/Bin/llvm/lib/clang/$RESOURCE_VERSION/include"
  else
    echo "error: could not locate clang resource headers (lib/clang/<ver>/include)" >&2
    exit 2
  fi
  # Bundle the shared libraries the distro LLVM binaries link against. The
  # launcher prepends Bin/llvm/lib to LD_LIBRARY_PATH; system libc is not copied.
  for binary in "$OUTPUT/Bin/llvm/bin/"*; do
    ldd "$binary" 2>/dev/null | awk '/=> \/|^\// {print $3}' | while read -r lib; do
      [ -f "$lib" ] || continue
      base="$(basename "$lib")"
      case "$base" in
        libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|ld-linux*|libgcc_s.so*|libstdc++.so*) ;;
        *) cp -L "$lib" "$OUTPUT/Bin/llvm/lib/$base" 2>/dev/null || true ;;
      esac
    done
  done
  cp -a "$REPO/tools/winbuild/darwin-stubs" "$OUTPUT/tools/winbuild/"
  cp "$REPO/ios/zakuro-ios/gamepack/zk_gamepack_shim.c" "$OUTPUT/tools/winbuild/zk_gamepack_shim.c"
  cp -a "$REPO/ios/zakuro-ios/include" "$OUTPUT/tools/winbuild/include"
  cp "$RECOMPILER_BIN" "$OUTPUT/Bin/3dsrecomp"
  chmod +x "$OUTPUT/Bin/3dsrecomp" "$OUTPUT/Bin/llvm/bin/"* "$OUTPUT/Bin/llvm/lib/"*.so* 2>/dev/null || true
  # Toolchain licence texts are additional evidence: stage them under distinct
  # names so the upstream files (both named LICENSE) can never overwrite the
  # repository licence texts staged in the payload step above. 0.3.0 shipped a
  # Linux tar whose licenses/LICENSE was the LLVM licence because of exactly
  # that basename collision; the guard below now makes it a build failure.
  if [ -f /usr/share/licenses/llvm/LICENSE ]; then
    cp /usr/share/licenses/llvm/LICENSE "$OUTPUT/licenses/LLVM-LICENSE.txt"
  fi
  for license in "$REPO/third_party/3dsrecomp/LICENSE" "$REPO/third_party/3dsrecomp/LICENSE.txt"; do
    if [ -f "$license" ]; then
      cp "$license" "$OUTPUT/licenses/3dsrecomp-LICENSE.txt"
      break
    fi
  done
  LLVM_VERSION="$( ( "$OUTPUT/Bin/llvm/bin/clang" --version 2>/dev/null || true ) | head -1)"
  {
    echo "{"
    echo '  "schema": "3ds2apple-linux-local-aot/1",'
    echo '  "llvm": "'"$LLVM_VERSION"'",'
    echo '  "ld64": "'"$( ("$OUTPUT/Bin/llvm/bin/ld64.lld" --version 2>/dev/null || true) | head -1 )"'",'
    echo '  "recompiler": "'"$(sha256sum "$OUTPUT/Bin/3dsrecomp" | awk '{print $1}')"'",'
    echo '  "note": "Official open-source LLVM + 3dsrecomp binaries; the exact LLVM pin is 23.1.6 and this file records the version actually staged."'
    echo "}"
  } > "$OUTPUT/PINS-local-aot.json"
  echo "[linux] local AOT: 3dsrecomp + $LLVM_VERSION + Darwin stubs/shim/include"
fi

# Cheap guard: the three repository licence texts in licenses/ must still be the
# repository files after every staging step (payload + optional local-AOT
# toolchain licences), so a future basename collision fails the build instead of
# shipping a wrong license text. Only checked when the payload staged them.
if [ "$MAKE_PAYLOAD" = "1" ]; then
  for text in LICENSE NOTICE THIRD_PARTY.md; do
    if ! cmp -s "$REPO/$text" "$OUTPUT/licenses/$text"; then
      echo "error: licenses/$text no longer matches the repository $text (a toolchain licence overwrote it)" >&2
      exit 2
    fi
  done
fi

BIN="$OUTPUT/3ds2apple-launcher"
chmod +x "$BIN"
echo "[linux] launcher: $BIN"
echo "[linux] self-test: $BIN --self-test"

if [ "$MAKE_TAR" = "1" ]; then
  TAR="${THREEDS2APPLE_TAR:-$(dirname "$OUTPUT")/$(basename "$OUTPUT").tar.gz}"
  mkdir -p "$(dirname "$TAR")"
  tar -czf "$TAR" -C "$(dirname "$OUTPUT")" "$(basename "$OUTPUT")"
  echo "[linux] archive: $TAR"
fi
