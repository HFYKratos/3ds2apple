#!/usr/bin/env bash
# build-ios-app-sim.sh — build the shipping SwiftUI shell and/or the direct
# runtime harness for the iOS Simulator against build/ios/libzakuro_ios_sim.a.
#
# Why this script exists next to build-ios-app.sh:
#   * build-ios-app.sh builds for iphoneos against the arm64 device library
#     build/ios/libzakuro_ios.a; the Intel build VM's Simulator is x86_64 and
#     needs the simulator static library from scripts/build-zakuro-ios-sim.sh.
#   * ios/app/project.yml hard-codes the device library search path and its
#     sources live under ios/app (owned by the shell task), so this script
#     generates the Xcode project from a COPY of the spec under build/ with
#     absolute paths and -lzakuro_ios_sim instead of editing the checked-in
#     spec. ios/app/Sources is never modified.
#
# Usage:
#   scripts/build-ios-app-sim.sh                  # shell + runtime harness
#   scripts/build-ios-app-sim.sh --app harness    # harness only (fast)
#   scripts/build-ios-app-sim.sh --app shell      # shipping shell only
#   scripts/build-ios-app-sim.sh --install        # then simctl install both
#   ZKSIM_UDID=<udid> scripts/build-ios-app-sim.sh --install
#
# Per-game AOT proof: add a real GamePack dylib to both apps (the shell shows
# the library entry, the harness drives the same pack) with
#   scripts/build-ios-app-sim.sh --game-code-dir build/game/pokemon-y \
#       --game-title-id 0004000000055E00 --game-display-name "Pokemon Y"
# The generated C is compiled for x86_64-apple-ios-simulator by
# scripts/build-game-pack.sh --target sim, and the app bundle gets
# Frameworks/GamePack-<TITLE_ID>.dylib plus the GameCatalog.json the AOT shell
# reads. This is the Simulator proof path (build-game-pack.sh --no-record);
# shipped packs still get their GameInfo.json/catalogue from the Rust CLI.
#
# Self-contained package (task-11): add the user's decrypted ROM so the shell
# boots it straight from the app bundle with no Documents/roms import:
#   scripts/build-ios-app-sim.sh --app shell \
#       --game-pack build/sim/game/packages/0004000000055E00 \
#       --game-rom "/path/to/your/Pokemon Y.cci"
# The ROM is copied to Roms/<TITLE_ID>.<ext> inside the shell app and named by
# the generated catalog's "romFile". With --game-pack DIR the script also picks
# up a GameRom.<ext> file from that package directory automatically. The ROM is
# a user-owned local file: never commit it, and it is only embedded in the shell,
# not in the harness.
#
# Outputs (all under the gitignored build/):
#   build/sim/shell/out/Release-iphonesimulator/3ds2apple.app
#   build/sim/harness/out/Release-iphonesimulator/3ds2apple-sim-harness.app
#
# This script only builds (and optionally installs); booting/launching the
# Simulator is documented in docs/build-simulator.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/desktop-aot.sh
source "$ROOT/scripts/lib/desktop-aot.sh"
LIB="$ROOT/build/ios/libzakuro_ios_sim.a"
OUTDIR="$ROOT/build/sim"
APP="both"
CONFIG="Release"
INSTALL=0
GAME_CODE_DIR_ARG=""
GAME_PACK_ARG=""
GAME_TITLE_ARG=""
GAME_NAME_ARG="pokemon-y"
GAME_DISPLAY_ARG=""
GAME_PRODUCT_ARG=""
GAME_TITLE_ID=""
GAME_DISPLAY_NAME=""
GAME_PACK=""
GAME_ROM_ARG=""
GAME_ROM=""
ROM_EXT=""
ROM_BUNDLE_FILE=""
UDID="${ZKSIM_UDID:-3CBF5A62-AE12-47E8-803D-1D77BED85A66}"

die() { printf 'build-ios-app-sim: %s\n' "$*" >&2; exit 1; }
log() { printf '[sim-app] %s\n' "$*"; }

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?--app needs shell|harness|both}"; shift 2 ;;
    --configuration) CONFIG="${2:?--configuration needs a value}"; shift 2 ;;
    --udid) UDID="${2:?--udid needs a value}"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --game-code-dir) [[ $# -ge 2 ]] || die "--game-code-dir needs a value"; GAME_CODE_DIR_ARG="$2"; shift 2 ;;
    --game-pack) [[ $# -ge 2 ]] || die "--game-pack needs a value"; GAME_PACK_ARG="$2"; shift 2 ;;
    --game-title-id) [[ $# -ge 2 ]] || die "--game-title-id needs a value"; GAME_TITLE_ARG="$2"; shift 2 ;;
    --game-name) [[ $# -ge 2 ]] || die "--game-name needs a value"; GAME_NAME_ARG="$2"; shift 2 ;;
    --game-display-name) [[ $# -ge 2 ]] || die "--game-display-name needs a value"; GAME_DISPLAY_ARG="$2"; shift 2 ;;
    --game-product-code) [[ $# -ge 2 ]] || die "--game-product-code needs a value"; GAME_PRODUCT_ARG="$2"; shift 2 ;;
    --game-rom) [[ $# -ge 2 ]] || die "--game-rom needs a value"; GAME_ROM_ARG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

case "$APP" in shell|harness|both) ;; *) die "--app must be shell, harness or both" ;; esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "this script must run on macOS with Xcode installed"
fi
# Non-login SSH sessions on the build VM do not get Homebrew's /usr/local/bin,
# where xcodegen lives; prepend it so the script works over plain SSH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v xcodegen >/dev/null 2>&1 || die "xcodegen is not in PATH"
[[ -s "$LIB" ]] || die "missing $LIB — run scripts/build-zakuro-ios-sim.sh first"
[[ "$(lipo -info "$LIB" 2>/dev/null)" == *x86_64* ]] || die "$LIB is not the x86_64 Simulator slice"

mkdir -p "$OUTDIR"

# --- per-game GamePack (AOT-first proof) ------------------------------------
# Builds one real GamePack dylib from generated 3dsrecomp C (or adopts one),
# embeds it under the app Frameworks/ directory and writes the
# GameCatalog.json the AOT shell reads. Both generated apps get the same pack,
# so the shell shows the library entry and the harness can drive the exact same
# dylib headless.
prepare_game_args() {
  GAME_DISPLAY_NAME="$GAME_DISPLAY_ARG"
  if [[ -z "$GAME_DISPLAY_NAME" ]]; then GAME_DISPLAY_NAME="$GAME_NAME_ARG"; fi
  if [[ -z "$GAME_CODE_DIR_ARG" && -z "$GAME_PACK_ARG" ]]; then
    # A ROM without a pack would be silently dropped (the catalogue needs a
    # title ID and a packFile); refuse it instead of ignoring the flag.
    if [[ -n "$GAME_ROM_ARG" ]]; then
      die "--game-rom requires --game-pack or --game-code-dir (the catalogue entry needs --game-title-id and a pack)"
    fi
    return 0
  fi
  if [[ -n "$GAME_CODE_DIR_ARG" && -n "$GAME_PACK_ARG" ]]; then
    die "choose one of --game-code-dir or --game-pack"
  fi
  if [[ -z "$GAME_TITLE_ARG" ]]; then
    die "--game-title-id is required with --game-code-dir/--game-pack"
  fi
  GAME_TITLE_ID="$(printf '%s' "$GAME_TITLE_ARG" | tr '[:lower:]' '[:upper:]')"
  local len
  len="$(printf '%s' "$GAME_TITLE_ID" | wc -c | tr -d '[:space:]')"
  if [[ "$len" -ne 16 ]]; then die "invalid --game-title-id '$GAME_TITLE_ARG' (16 hex digits expected)"; fi
  case "$GAME_TITLE_ID" in *[!0-9A-F]*) die "invalid --game-title-id '$GAME_TITLE_ARG' (16 hex digits expected)" ;; esac
  if [[ -n "$GAME_CODE_DIR_ARG" ]]; then
    [[ -d "$GAME_CODE_DIR_ARG" ]] || die "--game-code-dir is not a directory: $GAME_CODE_DIR_ARG"
    GAME_CODE_DIR_ARG="$(cd "$GAME_CODE_DIR_ARG" && pwd)"
  fi
  if [[ -n "$GAME_PACK_ARG" ]]; then
    [[ -d "$GAME_PACK_ARG" ]] || die "--game-pack is not a directory: $GAME_PACK_ARG"
    GAME_PACK_ARG="$(cd "$GAME_PACK_ARG" && pwd)"
  fi

  # Bundled game data (self-contained package): explicit --game-rom wins, then
  # a GameRom.<ext> the package builder recorded next to GamePack.dylib.
  if [[ -n "$GAME_ROM_ARG" ]]; then
    [[ -f "$GAME_ROM_ARG" ]] || die "--game-rom is not a file: $GAME_ROM_ARG"
    GAME_ROM="$(cd "$(dirname "$GAME_ROM_ARG")" && pwd)/$(basename "$GAME_ROM_ARG")"
  elif [[ -n "$GAME_PACK_ARG" ]]; then
    for candidate in "$GAME_PACK_ARG"/GameRom.*; do
      if [[ -f "$candidate" ]]; then GAME_ROM="$candidate"; break; fi
    done
  fi
  if [[ -n "$GAME_ROM" ]]; then
    local rom_extension
    rom_extension="$(printf '%s' "${GAME_ROM##*.}" | tr '[:upper:]' '[:lower:]')"
    case "$rom_extension" in
      cci|3ds|ncch|cxi) ;;
      *) die "unsupported --game-rom extension '.$rom_extension' (expected .cci/.3ds/.ncch/.cxi; .cia is not a runtime format)" ;;
    esac
    ROM_EXT=".$rom_extension"
    ROM_BUNDLE_FILE="Roms/$GAME_TITLE_ID$ROM_EXT"
    log "bundled ROM: $GAME_ROM ($(desktop_aot_file_bytes "$GAME_ROM") bytes) -> $ROM_BUNDLE_FILE"
  fi
}

build_game_pack() {
  local out="$OUTDIR/game"
  if [[ -n "$GAME_PACK_ARG" ]]; then
    GAME_PACK="$GAME_PACK_ARG/GamePack.dylib"
    [[ -f "$GAME_PACK" ]] || die "--game-pack has no GamePack.dylib: $GAME_PACK_ARG"
    desktop_aot_pack_matches_target "$GAME_PACK" "x86_64-apple-ios16.0-simulator" \
      || die "--game-pack is not an x86_64 iOS Simulator dylib (slice: $(desktop_aot_pack_arch "$GAME_PACK" 2>/dev/null || echo unknown)); build it with --target sim"
    desktop_aot_pack_exports_gamepack "$GAME_PACK" \
      || die "--game-pack does not export the GamePack ABI (zk_gamepack_title_id / zk_gamepack_abi_version / zk_gamepack_register)"
    log "adopting GamePack: $GAME_PACK ($(desktop_aot_pack_arch "$GAME_PACK") slice)"
    if [[ -f "$GAME_PACK_ARG/GameInfo.json" ]]; then
      # The desktop CLI records the bundled ROM's size and SHA256; verify the
      # ROM this build is about to embed against that record.
      local rom_record expected_file expected_bytes expected_sha actual_bytes actual_sha
      rom_record="$(desktop_aot_package_rom "$GAME_PACK_ARG")" \
        || die "cannot read the bundled-ROM record from $GAME_PACK_ARG/GameInfo.json"
      if [[ -n "$rom_record" ]]; then
        IFS="$(printf '\t')" read -r expected_file expected_bytes expected_sha <<< "$rom_record"
        if [[ -z "$GAME_ROM" ]]; then
          die "--game-pack records bundled ROM '$expected_file' but no --game-rom was given and no GameRom.<ext> was found next to GamePack.dylib"
        fi
        actual_bytes="$(desktop_aot_file_bytes "$GAME_ROM")"
        [[ "$actual_bytes" == "$expected_bytes" ]] \
          || die "--game-rom size mismatch for $GAME_TITLE_ID: GameInfo.json records $expected_bytes bytes, $GAME_ROM is $actual_bytes"
        actual_sha="$(desktop_aot_sha256 "$GAME_ROM")"
        [[ "$actual_sha" == "$expected_sha" ]] \
          || die "--game-rom SHA256 mismatch for $GAME_TITLE_ID: GameInfo.json records $expected_sha, $GAME_ROM is $actual_sha"
        log "verified bundled ROM against GameInfo.json: $expected_file $expected_bytes bytes sha256 $expected_sha"
      fi
    fi
  else
    log "building the GamePack for $GAME_TITLE_ID from $GAME_CODE_DIR_ARG (compiles the game C)"
    "$ROOT/scripts/build-game-pack.sh" "$GAME_NAME_ARG" \
      --title-id "$GAME_TITLE_ID" --display-name "$GAME_DISPLAY_NAME" \
      --product-code "$GAME_PRODUCT_ARG" --code-dir "$GAME_CODE_DIR_ARG" \
      --target sim --out "$out" --no-record \
      || die "build-game-pack.sh failed (see its output above)"
    GAME_PACK="$out/packages/$GAME_TITLE_ID/GamePack.dylib"
    [[ -f "$GAME_PACK" ]] || die "build-game-pack.sh produced no GamePack at $GAME_PACK"
  fi
  log "GamePack: $GAME_PACK"
}

write_game_catalog() { # output-file [rom-bundle-file]
  # Written with python3 so a display name/product code containing quotes or
  # backslashes still produces valid JSON (the desktop pipeline's single schema
  # writer is the Rust CLI; this Simulator-only path mirrors its fields).
  local name="$1" rom_file="${2:-}" game
  python3 - "$name" "$GAME_TITLE_ID" "$GAME_DISPLAY_NAME" "$GAME_PRODUCT_ARG" "$rom_file" <<'PY'
import json
import sys

destination, title_id, display_name, product_code, rom_file = sys.argv[1:6]
game = {
    "titleID": title_id,
    "displayName": display_name,
    "productCode": product_code,
    "aot": True,
    "aotVersion": 1,
    "packFile": "Frameworks/GamePack-%s.dylib" % title_id,
    "packABIVersion": 1,
    "notes": "simulator proof build",
}
if rom_file:
    game["romFile"] = rom_file
with open(destination, "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"schemaVersion": 2, "games": [game]}, ensure_ascii=False,
                            separators=(",", ":")) + "\n")
PY
}

embed_game_pack() { # app-bundle [embed-rom]
  local app="$1" with_rom="${2:-}" frameworks
  if [[ -z "$GAME_PACK" ]]; then return 0; fi
  frameworks="$app/Frameworks"
  mkdir -p "$frameworks"
  cp -f "$GAME_PACK" "$frameworks/GamePack-$GAME_TITLE_ID.dylib" \
    || die "could not copy the GamePack into $app"
  write_game_catalog "$app/GameCatalog.json" ""
  log "embedded: $frameworks/GamePack-$GAME_TITLE_ID.dylib"
  log "embedded: $app/GameCatalog.json"
  if [[ "$with_rom" == "1" && -n "$GAME_ROM" ]]; then
    local rom_dir="$app/Roms" source_sha copied_sha
    mkdir -p "$rom_dir"
    source_sha="$(desktop_aot_sha256 "$GAME_ROM")" || die "cannot hash $GAME_ROM"
    cp -f "$GAME_ROM" "$rom_dir/$GAME_TITLE_ID$ROM_EXT" \
      || die "could not copy the ROM into $app"
    copied_sha="$(desktop_aot_sha256 "$rom_dir/$GAME_TITLE_ID$ROM_EXT")"
    [[ "$source_sha" == "$copied_sha" ]] \
      || die "the embedded ROM copy does not match its source ($source_sha vs $copied_sha)"
    write_game_catalog "$app/GameCatalog.json" "$ROM_BUNDLE_FILE"
    log "embedded: $rom_dir/$GAME_TITLE_ID$ROM_EXT ($(desktop_aot_file_bytes "$GAME_ROM") bytes, sha256 $copied_sha)"
  fi
}

# --- shell ------------------------------------------------------------------
build_shell() {
  local dir="$OUTDIR/shell"
  local spec="$dir/project.yml"
  local project="$dir/3ds2apple.xcodeproj"
  rm -rf "$dir"
  mkdir -p "$dir"
  log "generating a Simulator shell spec under build/sim/shell"
  python3 - "$ROOT" "$ROOT/ios/app/project.yml" "$spec" <<'PY'
import sys
root, source, destination = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(source, encoding='utf-8').read()
replacements = [
    ('- path: Sources', '- path: ' + root + '/ios/app/Sources'),
    ('- path: Resources', '- path: ' + root + '/ios/app/Resources'),
    ('$(SRCROOT)/../ZakuroBridge.h', root + '/ios/ZakuroBridge.h'),
    ('["$(SRCROOT)/.."]', '["' + root + '/ios"]'),
    ('["-L$(SRCROOT)/../../build/ios", "-lzakuro_ios"]',
     '["-L' + root + '/build/ios", "-lzakuro_ios_sim"]'),
]
for needle, replacement in replacements:
    if needle not in text:
        raise SystemExit('build-ios-app-sim: ios/app/project.yml changed; expected: ' + needle)
    text = text.replace(needle, replacement)
open(destination, 'w', encoding='utf-8').write(text)
print('wrote ' + destination)
PY
  ( cd "$dir" && xcodegen generate --spec "$spec" >/dev/null )
  log "building shell for iphonesimulator ($CONFIG, x86_64)"
  xcodebuild -project "$project" -target 3ds2apple -sdk iphonesimulator -arch x86_64 \
    -configuration "$CONFIG" SYMROOT="$dir/out" OBJROOT="$dir/out-obj" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >"$dir/xcodebuild.log" 2>&1 \
    || { tail -n 40 "$dir/xcodebuild.log" >&2; die "shell xcodebuild failed; log: $dir/xcodebuild.log"; }
  SHELL_APP="$dir/out/$CONFIG-iphonesimulator/3ds2apple.app"
  [[ -d "$SHELL_APP" ]] || die "shell build produced no app at $SHELL_APP"
  log "shell: $SHELL_APP"
  embed_game_pack "$SHELL_APP" 1
  log "shell binary: $(lipo -info "$SHELL_APP/3ds2apple" 2>/dev/null)"
}

# --- runtime harness --------------------------------------------------------
build_harness() {
  local dir="$OUTDIR/harness"
  local spec="$dir/project.yml"
  local project="$dir/3ds2apple-sim-harness.xcodeproj"
  rm -rf "$dir"
  mkdir -p "$dir"
  log "generating the runtime-harness spec under build/sim/harness"
  sed "s|__REPO_ROOT__|$ROOT|g" "$ROOT/ios/sim/project.yml" > "$spec"
  ( cd "$dir" && xcodegen generate --spec "$spec" >/dev/null )
  log "building the runtime harness ($CONFIG, x86_64)"
  xcodebuild -project "$project" -target 3ds2apple-sim-harness -sdk iphonesimulator -arch x86_64 \
    -configuration "$CONFIG" SYMROOT="$dir/out" OBJROOT="$dir/out-obj" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >"$dir/xcodebuild.log" 2>&1 \
    || { tail -n 60 "$dir/xcodebuild.log" >&2; die "harness xcodebuild failed; log: $dir/xcodebuild.log"; }
  HARNESS_APP="$dir/out/$CONFIG-iphonesimulator/3ds2apple-sim-harness.app"
  [[ -d "$HARNESS_APP" ]] || die "harness build produced no app at $HARNESS_APP"
  log "harness: $HARNESS_APP"
  embed_game_pack "$HARNESS_APP" 0
  log "harness binary: $(lipo -info "$HARNESS_APP/3ds2apple-sim-harness" 2>/dev/null)"
}

SHELL_APP=""
HARNESS_APP=""
prepare_game_args
if [[ -n "$GAME_CODE_DIR_ARG" || -n "$GAME_PACK_ARG" ]]; then
  build_game_pack
fi
[[ "$APP" == shell || "$APP" == both ]] && build_shell
[[ "$APP" == harness || "$APP" == both ]] && build_harness

# --- optional install -------------------------------------------------------
if [[ "$INSTALL" -eq 1 ]]; then
  if ! xcrun simctl list devices | grep -F "$UDID" | grep -q Booted; then
    die "Simulator $UDID is not booted; boot it first (xcrun simctl boot $UDID) and rerun with --install"
  fi
  [[ -n "$SHELL_APP" ]] && { xcrun simctl install "$UDID" "$SHELL_APP"; log "installed shell: com.kratos.3ds2apple"; }
  [[ -n "$HARNESS_APP" ]] && { xcrun simctl install "$UDID" "$HARNESS_APP"; log "installed harness: com.kratos.3ds2apple.sim"; }
fi

log "done"
printf '\nNext (see docs/build-simulator.md):\n'
printf '  xcrun simctl boot %s\n' "$UDID"
printf '  xcrun simctl bootstatus %s -b\n' "$UDID"
[[ -n "$HARNESS_APP" ]] && printf '  xcrun simctl install %s %s\n' "$UDID" "$HARNESS_APP"
printf '  seed ROM into the app Documents/roms (container path from: xcrun simctl get_app_container %s <bundle-id> data)\n' "$UDID"
printf '  xcrun simctl launch --console-pty %s <bundle-id>\n' "$UDID"
printf '  xcrun simctl io %s screenshot /tmp/sim.png\n' "$UDID"
