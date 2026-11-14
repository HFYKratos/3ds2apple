#!/usr/bin/env bash
# build-game-pack.sh — build or adopt one per-game AOT pack package.
#
# Desktop AOT-first flow (docs/desktop-aot.md):
#
#   scripts/build-recomp-ios.sh <rom> <name>     # 3dsrecomp -> libgame.a
#   scripts/build-linked-ios-lib.sh <name>       # linked libzakuro_ios.a
#   scripts/build-game-pack.sh <name> --title-id <id> --out out
#       -> out/packages/<TITLE_ID>/GameInfo.json + GamePack.dylib
#
# Real mode (macOS): --dylib FILE adopts an already-built Mach-O dylib, and
# --from-libs links build/ios/<name>/{libzakuro_ios.a,libgame.a} into a
# GamePack.dylib. The --from-libs path is EXPERIMENTAL: the linked runtime was
# designed to be linked into the app, and registering a standalone image is the
# runtime task's work (docs/desktop-aot.md gaps). The pack is then recorded by
# the Rust desktop CLI (3ds2apple-pack packages record), which owns the
# GameInfo.json schema.
#
# Fake/preview mode (Linux/Windows/macOS): --fake records a deterministic
# placeholder pack; it is for layout tests and previews only and is never
# installable or shippable.
#
# --dry-run validates the inputs and prints what would happen without writing
# anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/aot-common.sh
source "${SCRIPT_DIR}/lib/aot-common.sh"
# shellcheck source=lib/desktop-aot.sh
source "${SCRIPT_DIR}/lib/desktop-aot.sh"

NAME_ARG=""
TITLE_ARG=""
DISPLAY_ARG=""
PRODUCT_ARG=""
AOT_VERSION_ARG="1"
OUT_ARG="out"
LIB_DIR_ARG=""
DYLIB_ARG=""
FROM_LIBS=0
FAKE=0
DRY_RUN=0
PACK_BIN_ARG=""
ROM_ARG=""

usage() {
  cat <<'EOF'
Build or adopt one per-game AOT pack package.

Usage:
  scripts/build-game-pack.sh <name> --title-id <TITLE_ID> [options]

Arguments:
  <name>             Game build name used by build-recomp-ios.sh
                     ([A-Za-z0-9._-]; e.g. pokemon-y-00055e00)

Options:
  --title-id ID      16 hex digit application title ID (00040000...)
  --display-name T   Display name recorded in GameInfo.json (default: <name>)
  --product-code C   Product code, e.g. CTR-P-EK2A (default: empty)
  --aot-version N    AOT pack version recorded in GameInfo.json (default: 1)
  --out DIR          Output root; the package goes to DIR/packages/<TITLE_ID>/
                     (default: out)
  --rom FILE         ROM provenance to record (optional, must match the title)
  --lib-dir DIR      Per-game lib dir (default: build/ios/<name>)

Pack source (exactly one of):
  --dylib FILE       Adopt an already-built arm64 Mach-O GamePack.dylib
  --from-libs        Link --lib-dir/{libzakuro_ios.a,libgame.a} into a dylib
                     (macOS only; EXPERIMENTAL, see docs/desktop-aot.md)
  --fake             Write a deterministic placeholder pack (preview/tests)
  --dry-run          Validate and print the plan; write nothing

Other:
  --pack-bin PATH    Desktop CLI binary (default: builder/target/{release,debug}/,
                     PATH, or $THREEDS2APPLE_PACK)
  -h, --help         Show this help and exit

The GameInfo.json manifest (and the catalogue later) is written by the Rust
desktop CLI so there is exactly one schema writer. On a Linux/Windows machine
without a Mac use --fake (preview) or --dry-run; the real pack needs macOS with
Xcode and the existing scripts/ pipeline.

Exit status: 0 on success, non-zero on failure.
EOF
}

log() { printf '[build-game-pack] %s\n' "$*"; }
warn() { printf '[build-game-pack] warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${ROOT}/$1" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title-id) [[ $# -ge 2 ]] || die "--title-id requires a value"; TITLE_ARG="$2"; shift 2 ;;
    --display-name) [[ $# -ge 2 ]] || die "--display-name requires a value"; DISPLAY_ARG="$2"; shift 2 ;;
    --product-code) [[ $# -ge 2 ]] || die "--product-code requires a value"; PRODUCT_ARG="$2"; shift 2 ;;
    --aot-version) [[ $# -ge 2 ]] || die "--aot-version requires a value"; AOT_VERSION_ARG="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out requires a value"; OUT_ARG="$2"; shift 2 ;;
    --rom) [[ $# -ge 2 ]] || die "--rom requires a value"; ROM_ARG="$2"; shift 2 ;;
    --lib-dir) [[ $# -ge 2 ]] || die "--lib-dir requires a value"; LIB_DIR_ARG="$2"; shift 2 ;;
    --dylib) [[ $# -ge 2 ]] || die "--dylib requires a value"; DYLIB_ARG="$2"; shift 2 ;;
    --from-libs) FROM_LIBS=1; shift ;;
    --fake) FAKE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --pack-bin) [[ $# -ge 2 ]] || die "--pack-bin requires a value"; PACK_BIN_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      if [[ -z "$NAME_ARG" ]]; then NAME_ARG="$1"; else die "unexpected argument: $1 (try --help)"; fi
      shift ;;
  esac
done

[[ -n "$NAME_ARG" ]] || die "missing <name> argument (try --help)"
[[ -n "$TITLE_ARG" ]] || die "missing --title-id (16 hex digits, e.g. 0004000000055E00)"
aot_is_valid_name "$NAME_ARG" \
  || die "invalid game name: '$NAME_ARG' (use letters, digits, '.', '_', '-')"

TITLE_ID="$(printf '%s' "$TITLE_ARG" | tr '[:lower:]' '[:upper:]')"
case "$TITLE_ID" in
  *[!0-9A-F]*) die "invalid --title-id '$TITLE_ARG' (16 hex digits expected)" ;;
esac
[[ ${#TITLE_ID} -eq 16 ]] || die "invalid --title-id '$TITLE_ARG' (16 hex digits expected)"
case "$TITLE_ID" in
  00040000*) ;;
  *) die "title ID $TITLE_ID is not an application title (expected the 00040000 high word)" ;;
esac

DISPLAY_NAME="${DISPLAY_ARG:-$NAME_ARG}"
[[ -n "$DISPLAY_NAME" ]] || die "--display-name must not be empty"
case "$DISPLAY_NAME" in
  *$'\n'*|*$'\r'*) die "--display-name must be a single line" ;;
esac
PRODUCT_CODE="${PRODUCT_ARG:-}"
case "$AOT_VERSION_ARG" in
  ''|*[!0-9]*) die "--aot-version must be a positive integer" ;;
esac
[[ "$AOT_VERSION_ARG" -ge 1 ]] || die "--aot-version must be >= 1"

OUT_ROOT="$(resolve_path "$OUT_ARG")"
mkdir -p "$OUT_ROOT"
OUT_ROOT="$(cd "$OUT_ROOT" && pwd)"
PACKAGE_DIR="${OUT_ROOT}/packages/${TITLE_ID}"

# Exactly one pack source.
SOURCE_COUNT=$(( FROM_LIBS + FAKE ))
if [[ -n "$DYLIB_ARG" ]]; then SOURCE_COUNT=$(( SOURCE_COUNT + 1 )); fi
if [[ "$DRY_RUN" -eq 0 ]]; then
  if [[ "$SOURCE_COUNT" -eq 0 ]]; then
    die "choose a pack source: --dylib FILE, --from-libs, or --fake (or --dry-run)"
  elif [[ "$SOURCE_COUNT" -gt 1 ]]; then
    die "choose exactly one of --dylib, --from-libs, --fake"
  fi
fi

PACK_BIN=""
if [[ "$DRY_RUN" -eq 0 ]]; then
  PACK_BIN="$(desktop_aot_find_pack_bin "$ROOT" "$PACK_BIN_ARG")" \
    || die "3ds2apple-pack binary not found ($(desktop_aot_pack_bin_hint))"
  log "pack CLI: $PACK_BIN"
fi

TMP_DYLIB=""
TMP_LINK_DIR=""
cleanup() {
  if [[ -n "${TMP_DYLIB:-}" && -f "${TMP_DYLIB}" ]]; then rm -f -- "${TMP_DYLIB}"; fi
  if [[ -n "${TMP_LINK_DIR:-}" && -d "${TMP_LINK_DIR}" ]]; then rm -rf -- "${TMP_LINK_DIR}"; fi
}
trap cleanup EXIT

if [[ -n "$DYLIB_ARG" ]]; then
  DYLIB="$(resolve_path "$DYLIB_ARG")"
  [[ -f "$DYLIB" ]] || die "dylib not found: $DYLIB"
  if ! desktop_aot_pack_is_macho "$DYLIB"; then
    die "not a Mach-O dylib: $DYLIB (arm64-apple-ios Mach-O expected)"
  fi
  log "adopting dylib: $DYLIB ($(desktop_aot_file_bytes "$DYLIB") bytes, sha256 $(desktop_aot_sha256 "$DYLIB"))"
elif [[ "$FROM_LIBS" -eq 1 ]]; then
  [[ "$(uname -s)" == "Darwin" ]] \
    || die "--from-libs needs macOS with Xcode clang; on Linux/Windows use --fake for a preview package"
  LIB_DIR="$(resolve_path "${LIB_DIR_ARG:-build/ios/${NAME_ARG}}")"
  LIB_ZAKURO="${LIB_DIR}/libzakuro_ios.a"
  LIB_GAME="${LIB_DIR}/libgame.a"
  [[ -f "$LIB_ZAKURO" ]] || die "missing $LIB_ZAKURO (run scripts/build-linked-ios-lib.sh $NAME_ARG first)"
  [[ -f "$LIB_GAME" ]] || die "missing $LIB_GAME (run scripts/build-recomp-ios.sh first)"
  command -v clang >/dev/null 2>&1 || die "clang not found (install the Xcode command line tools)"
  TMP_LINK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/3ds2apple-gamepack.XXXXXX")"
  TMP_DYLIB="${TMP_LINK_DIR}/GamePack.dylib"
  warn "--from-libs is EXPERIMENTAL: the linked runtime was designed to be linked into the app; validate the dylib path on device (docs/desktop-aot.md gaps)"
  log "linking GamePack.dylib from $LIB_DIR (undefined symbols resolve from the host app)"
  clang -dynamiclib -target arm64-apple-ios16.0 -o "$TMP_DYLIB" \
    -Wl,-force_load,"$LIB_ZAKURO" \
    -Wl,-force_load,"$LIB_GAME" \
    -Wl,-undefined,dynamic_lookup \
    -framework Foundation -framework UIKit -framework Metal -framework MetalKit \
    -framework QuartzCore -framework CoreGraphics -framework CoreVideo \
    -framework AudioToolbox -framework AVFoundation -framework Security \
    || die "clang could not link GamePack.dylib; inspect the output above (see docs/desktop-aot.md)"
  desktop_aot_pack_is_macho "$TMP_DYLIB" || die "clang produced a non-Mach-O file: $TMP_DYLIB"
  log "linked dylib: $TMP_DYLIB ($(desktop_aot_file_bytes "$TMP_DYLIB") bytes, sha256 $(desktop_aot_sha256 "$TMP_DYLIB"))"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry run: no files written"
  printf 'name=%s\n' "$NAME_ARG"
  printf 'title_id=%s\n' "$TITLE_ID"
  printf 'display_name=%s\n' "$DISPLAY_NAME"
  printf 'product_code=%s\n' "$PRODUCT_CODE"
  printf 'aot_version=%s\n' "$AOT_VERSION_ARG"
  printf 'out_root=%s\n' "$OUT_ROOT"
  printf 'package_dir=%s\n' "$PACKAGE_DIR"
  if [[ -n "$DYLIB_ARG" ]]; then printf 'source=dylib:%s\n' "$(resolve_path "$DYLIB_ARG")"; fi
  if [[ "$FROM_LIBS" -eq 1 ]]; then printf 'source=from_libs:%s\n' "$(resolve_path "${LIB_DIR_ARG:-build/ios/${NAME_ARG}}")"; fi
  if [[ "$FAKE" -eq 1 ]]; then printf 'source=fake_placeholder\n'; fi
  exit 0
fi

RECORD_ARGS=(packages record --title-id "$TITLE_ID" --display-name "$DISPLAY_NAME" --out "$OUT_ROOT")
if [[ -n "$PRODUCT_CODE" ]]; then RECORD_ARGS+=(--product-code "$PRODUCT_CODE"); fi
RECORD_ARGS+=(--aot-version "$AOT_VERSION_ARG")
if [[ -n "$ROM_ARG" ]]; then RECORD_ARGS+=(--rom "$(resolve_path "$ROM_ARG")"); fi
if [[ "$FAKE" -eq 1 ]]; then
  RECORD_ARGS+=(--fake-placeholder)
else
  if [[ -n "$DYLIB_ARG" ]]; then
    RECORD_ARGS+=(--pack "$(resolve_path "$DYLIB_ARG")")
  else
    RECORD_ARGS+=(--pack "$TMP_DYLIB")
  fi
fi

log "recording package metadata in $PACKAGE_DIR"
"$PACK_BIN" "${RECORD_ARGS[@]}"

log "package ready: $PACKAGE_DIR"
printf 'PACKAGE: %s\n' "$PACKAGE_DIR"
printf 'TITLE_ID: %s\n' "$TITLE_ID"
printf 'GAME_PACK: %s\n' "${PACKAGE_DIR}/GamePack.dylib"
printf 'GAME_INFO: %s\n' "${PACKAGE_DIR}/GameInfo.json"
if [[ "$FAKE" -eq 1 ]]; then
  warn "--fake wrote a placeholder pack; it is for previews only and must not be shipped"
fi
