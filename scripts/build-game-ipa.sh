#!/usr/bin/env bash
# build-game-ipa.sh — build the per-game AOT IPA (linked Zakuro + libgame.a).
#
# Per-game AOT pipeline (authoritative design: ios/zakuro-ios/scripts/AOT_BUILD.md §3.4/§9):
#
#   scripts/build-zakuro-ios.sh              # once per Zakuro checkout
#   scripts/build-recomp-ios.sh <rom> <name> # 3dsrecomp -> librecomp.a
#   scripts/build-linked-ios-lib.sh <name>   # linked libs in build/ios/<name>/
#   scripts/build-game-ipa.sh <name>         # this script -> IPA/3ds2apple-<name>-<ver>.ipa
#
# The XcodeGen project in ios/app is generated as usual (no ios/app changes are
# needed); the two static archives are linked by overriding OTHER_LDFLAGS on the
# xcodebuild command line. The order is fixed and deliberate (scripts/AOT_BUILD.md §3.4):
#
#   -L<repo>/build/ios/<name> -lzakuro_ios -lgame
#
# `-lzakuro_ios` first (creates the unresolved _recomp_* references), then
# `-lgame` (resolves them). Reversing it, or forgetting libgame.a, makes the
# link fail with undefined _recomp_* symbols - that is the intended guard
# against shipping an interpreter-only "AOT" build.
#
# Split/incremental path (2026-11-12 VM run): when the generated C was produced
# elsewhere (e.g. 3dsrecomp on Linux) and build/ios/<name>/{libzakuro_ios.a,
# libgame.a} already exist, this script is the only command needed. The title ID
# is resolved from --title-id, build-info.txt, recomp-info.txt or the generated
# src/main.rs (see scripts/lib/aot-common.sh); a corrupted value such as
# "0004000000055E00n" (over-escaped printf in the first run) is repaired with a
# warning instead of being written to manifest.txt.
#
# The built app also carries GameCatalog.json (the build-time AOT manifest read
# by ios/app/Sources/GameCatalog.swift): exactly one game entry for the linked
# title, so the phone only selects and launches code that is already compiled
# into the app - it never recompiles a ROM on device. The catalog is installed
# into ios/app/Resources/ before xcodegen, verified inside the built .app, and
# removed again on exit (also on failure), so the working tree stays clean.
#
# The app remains unsigned (CODE_SIGNING_ALLOWED=NO); signing/installing is the
# user's job on Windows with Sideloadly/AltStore. Nothing is committed: libs,
# build logs, the IPA and its manifest all live in gitignored directories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AOT_LOG_PREFIX="build-game-ipa"
# shellcheck source=lib/aot-common.sh
source "${SCRIPT_DIR}/lib/aot-common.sh"
# shellcheck source=lib/game-catalog.sh
source "${SCRIPT_DIR}/lib/game-catalog.sh"

CONFIGURATION="Release"
APP_DIR_ARG="${ROOT}/ios/app"
LIB_DIR_ARG=""
OUT_DIR_ARG="${ROOT}/IPA"
IPA_NAME_ARG=""
BUNDLE_ID_ARG=""
DISPLAY_NAME_ARG=""
NAME_ARG=""
TITLE_ARG=""
PRODUCT_CODE_ARG=""
AOT_VERSION_ARG=""
IPA_VERSION_ARG=""
CLEAN_PROJECT=0
VERBOSE=0

# Last-resort version for the IPA file name when neither the built app nor
# ios/app/project.yml exposes one (simulated/partial environment only; keep in
# sync with MARKETING_VERSION). A real build derives it from the app.
DEFAULT_IPA_VERSION="0.1.2"
PRODUCT_CODE=""
AOT_VERSION=1
IPA_VERSION=""
IPA_NAME=""
CATALOG_TMP=""
CATALOG_SUMMARY=""
CATALOG_IN_APP=""

EXPECTED_RECOMP_SYMBOLS="$AOT_EXPECTED_RECOMP_SYMBOLS"

# nm dumps are written to temp files (never piped into `grep -q`: under
# `set -o pipefail` an early grep exit makes nm die with SIGPIPE and a present
# symbol looks missing). The trap removes whatever is still around on failure.
NM_DUMP=""
NM_DUMP_UNDEF=""
cleanup_nm_dumps() {
  [[ -z "${NM_DUMP:-}" ]] || rm -f -- "$NM_DUMP"
  [[ -z "${NM_DUMP_UNDEF:-}" ]] || rm -f -- "$NM_DUMP_UNDEF"
}

usage() {
  cat <<'EOF'
Build the per-game AOT IPA from the ios/app XcodeGen project.

Usage:
  scripts/build-game-ipa.sh <name> [options]

Arguments:
  <name>             Short game name used by the recomp/linked steps
                     (expects build/ios/<name>/{libzakuro_ios.a,libgame.a})

Options:
  --name NAME        Same as the <name> argument
  --title-id ID      16 hex digit ROM title ID (e.g. 0004000000055E00).
                     Default: read from --title-id > build-info.txt >
                     build/game/<name>/recomp-info.txt > src/main.rs. The value
                     written to manifest.txt is always validated 16-hex hex.
  --lib-dir DIR      Per-game lib dir (default: build/ios/<name>)
  --app-dir DIR      XcodeGen project dir (default: ios/app)
  --configuration C  xcodebuild configuration (default: Release)
  --bundle-id ID     Per-game bundle identifier (default:
                     com.kratos.3ds2apple.<name>); lets the AOT app be
                     installed side by side with the interpreter shell
  --display-name T   Home-screen name (default: <name>); also the GameCatalog
                     displayName entry
  --product-code C   Product code recorded in GameCatalog.json (e.g.
                     CTR-P-EKJA). Default: empty (optional metadata).
  --aot-version N    AOT asset version recorded in GameCatalog.json
                     (default: 1)
  --out-dir DIR      IPA output dir (default: IPA/, gitignored)
  --ipa-name NAME    Explicit IPA base name without .ipa (default:
                     3ds2apple-<name>-<version>)
  --ipa-version V    Version used in the default IPA name; defaults to the
                     app CFBundleShortVersionString (project.yml
                     MARKETING_VERSION), e.g. 0.1.2
  --clean-project    Delete the generated 3ds2apple.xcodeproj afterwards
                     (default: keep; ios/app/3ds2apple.xcodeproj/ is gitignored)
  --verbose          Stream xcodebuild output to the terminal as well
  -h, --help         Show this help and exit

Split/incremental builds:
  If build/ios/<name>/{libzakuro_ios.a,libgame.a} already exist (for example
  after a manual split build: 3dsrecomp generated the C on Linux, libgame.a and
  the linked library were built separately), just run this script - it reuses
  them and produces the manifest-correct IPA. Only Xcode is needed; cargo and
  the ROM are not (the ROM is still required on the device at runtime).

GameCatalog.json (AOT manifest read by ios/app/Sources/GameCatalog.swift):
  The build installs ios/app/Resources/GameCatalog.json for the duration of the
  build: exactly one game entry for the linked title (titleID, displayName,
  productCode, aot=true, aotVersion). It is bundled into the .app, verified
  after the build and removed again (also on failure), so the working tree
  stays clean (.gitignore covers it as a safeguard).

Outputs (all gitignored):
  IPA/3ds2apple-<name>-<version>.ipa     unsigned AOT IPA
  build/ios/<name>/manifest.txt          title ID, source, revs, catalog, SHA256
  build/logs/build-game-ipa-<name>-*.log

Exit status: 0 on success, non-zero on failure (the log tail is printed).
EOF
}

log() {
  printf '[build-game-ipa] %s\n' "$*"
}

warn() {
  printf '[build-game-ipa] warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${ROOT}/$1" ;;
  esac
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH. $2"
}

sanitize_bundle_component() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9.' '-' \
    | sed -e 's/--*/-/g' -e 's/^-*//' -e 's/-*$//'
}

# Build-time GameCatalog.json and temp files are always removed (also on
# failure), so the working tree stays clean; the catalog is restored if a file
# existed before the build.
cleanup_all() {
  cleanup_nm_dumps
  if [[ -n "${CATALOG_TMP:-}" && -f "$CATALOG_TMP" ]]; then
    rm -f -- "$CATALOG_TMP"
  fi
  game_catalog_cleanup
}
trap cleanup_all EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      NAME_ARG="$2"
      shift 2
      ;;
    --title-id)
      [[ $# -ge 2 ]] || die "--title-id requires a value"
      TITLE_ARG="$2"
      shift 2
      ;;
    --lib-dir)
      [[ $# -ge 2 ]] || die "--lib-dir requires a value"
      LIB_DIR_ARG="$2"
      shift 2
      ;;
    --app-dir)
      [[ $# -ge 2 ]] || die "--app-dir requires a value"
      APP_DIR_ARG="$2"
      shift 2
      ;;
    --configuration)
      [[ $# -ge 2 ]] || die "--configuration requires a value"
      CONFIGURATION="$2"
      shift 2
      ;;
    --bundle-id)
      [[ $# -ge 2 ]] || die "--bundle-id requires a value"
      BUNDLE_ID_ARG="$2"
      shift 2
      ;;
    --display-name)
      [[ $# -ge 2 ]] || die "--display-name requires a value"
      DISPLAY_NAME_ARG="$2"
      shift 2
      ;;
    --product-code)
      [[ $# -ge 2 ]] || die "--product-code requires a value"
      PRODUCT_CODE_ARG="$2"
      shift 2
      ;;
    --aot-version)
      [[ $# -ge 2 ]] || die "--aot-version requires a value"
      AOT_VERSION_ARG="$2"
      shift 2
      ;;
    --ipa-version)
      [[ $# -ge 2 ]] || die "--ipa-version requires a value"
      IPA_VERSION_ARG="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR_ARG="$2"
      shift 2
      ;;
    --ipa-name)
      [[ $# -ge 2 ]] || die "--ipa-name requires a value"
      IPA_NAME_ARG="$2"
      shift 2
      ;;
    --clean-project)
      CLEAN_PROJECT=1
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1 (try --help)"
      ;;
    *)
      if [[ -z "$NAME_ARG" ]]; then
        NAME_ARG="$1"
      else
        die "unexpected argument: $1 (try --help)"
      fi
      shift
      ;;
  esac
done

[[ -n "$NAME_ARG" ]] || die "missing <name> argument
usage: scripts/build-game-ipa.sh <name> [options]"
NAME="$NAME_ARG"
aot_is_valid_name "$NAME" \
  || die "invalid game name: '$NAME' (use letters, digits, '.', '_', '-')"
[[ -n "$CONFIGURATION" ]] || die "--configuration must not be empty"

APP_DIR="$(resolve_path "$APP_DIR_ARG")"
LIB_DIR="$(resolve_path "${LIB_DIR_ARG:-build/ios/${NAME}}")"
OUT_DIR="$(resolve_path "$OUT_DIR_ARG")"
[[ -d "$APP_DIR" ]] || die "app directory not found: $APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd)"
[[ -f "${APP_DIR}/project.yml" ]] || die "no project.yml in $APP_DIR (ios/app contract)"
[[ -d "$LIB_DIR" ]] || die "per-game lib dir not found: $LIB_DIR
       Run scripts/build-linked-ios-lib.sh $NAME first (or copy an existing
       split-build libzakuro_ios.a + libgame.a into $LIB_DIR)."

LIB_ZAKURO="${LIB_DIR}/libzakuro_ios.a"
LIB_GAME="${LIB_DIR}/libgame.a"
BUILD_INFO="${LIB_DIR}/build-info.txt"
[[ -f "$LIB_ZAKURO" ]] || die "missing $LIB_ZAKURO
       Run scripts/build-linked-ios-lib.sh $NAME first, or point --lib-dir at
       the directory from the split build."
[[ -f "$LIB_GAME" ]] || die "missing $LIB_GAME
       Run scripts/build-linked-ios-lib.sh $NAME first, or point --lib-dir at
       the directory from the split build."

# xcodebuild receives OTHER_LDFLAGS as a space separated list, so a lib path
# containing spaces cannot be represented safely.
case "$LIB_DIR" in
  *" "*) die "the lib dir path contains spaces, which the OTHER_LDFLAGS override
       cannot represent: '$LIB_DIR'. Move the repo to a path without spaces." ;;
esac

# --- identity ----------------------------------------------------------------
BUNDLE_ID="${BUNDLE_ID_ARG:-com.kratos.3ds2apple.$(sanitize_bundle_component "$NAME")}"
case "$BUNDLE_ID" in
  ''|*[!A-Za-z0-9.-]*) die "invalid bundle id: '$BUNDLE_ID' (letters, digits, '.', '-')" ;;
esac
DISPLAY_NAME="${DISPLAY_NAME_ARG:-$NAME}"
[[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$NAME"
case "$DISPLAY_NAME" in
  *$'\n'*|*$'\r'*) die "--display-name must be a single line (no newlines)" ;;
esac
# --- catalog metadata (written to GameCatalog.json) -------------------------
PRODUCT_CODE="${PRODUCT_CODE_ARG:-}"
AOT_VERSION="${AOT_VERSION_ARG:-1}"
case "$AOT_VERSION" in
  ''|*[!0-9]*) die "--aot-version must be a positive integer (got '$AOT_VERSION')" ;;
esac
[[ "$AOT_VERSION" -ge 1 ]] || die "--aot-version must be >= 1 (got $AOT_VERSION)"

# An explicit --ipa-name still wins; otherwise the default is derived after the
# app is built: 3ds2apple-<name>-<version> (version from the app, see below).
if [[ -n "$IPA_NAME_ARG" ]]; then
  IPA_NAME="${IPA_NAME_ARG%.ipa}"
  [[ -n "$IPA_NAME" ]] || die "--ipa-name must not be empty"
  case "$IPA_NAME" in
    */*) die "--ipa-name must be a file name, not a path: $IPA_NAME" ;;
  esac
fi

# --- title ID (validated, never "unknown") -----------------------------------
# The AOT linked library is compiled for one title ID; the manifest must record
# exactly that value (scripts/AOT_BUILD.md §9). Resolution order: --title-id, then
# build-info.txt (what build-linked-ios-lib.sh baked in), then recomp-info.txt,
# then the generated src/main.rs. Corrupted values from the first VM run
# ("...5E00n") are repaired with a warning by aot_normalize_title_id.
if ! aot_resolve_title_id "$ROOT" "$NAME" "$TITLE_ARG"; then
  die "could not determine a valid 16 hex digit title ID for '$NAME'.
       Tried: --title-id, build/ios/${NAME}/build-info.txt,
       build/game/${NAME}/recomp-info.txt, build/game/${NAME}/src/main.rs.
       Pass --title-id 0004000000055E00 (or the ROM's real title ID) and the
       manifest will record that value."
fi
TITLE_ID="$AOT_TITLE_ID"
TITLE_ID_SOURCE="$AOT_TITLE_SOURCE"

# If the caller overrides the title explicitly, compare it with what the linked
# build claims: a mismatch means the runtime loader will fall back to the
# interpreter ("the code linked in is for title X, not Y").
if [[ "$TITLE_ID_SOURCE" == "--title-id" ]]; then
  BUILD_INFO_TITLE_RAW="$(aot_info_value "$BUILD_INFO" title_id || true)"
  if [[ -n "$BUILD_INFO_TITLE_RAW" ]]; then
    BUILD_INFO_TITLE="$(aot_normalize_title_id "$BUILD_INFO_TITLE_RAW" 2>/dev/null || true)"
    if [[ -n "$BUILD_INFO_TITLE" && "$BUILD_INFO_TITLE" != "$TITLE_ID" ]]; then
      warn "linked library claims title $BUILD_INFO_TITLE ($BUILD_INFO) but
       --title-id is $TITLE_ID; the device will likely fall back to the
       interpreter unless the linked lib is rebuilt for the same title."
    fi
  fi
fi

RECOMP_REV="$(aot_info_value "$BUILD_INFO" recomp_rev || true)"
if [[ -z "$RECOMP_REV" ]]; then
  RECOMP_REV="$(aot_info_value "${ROOT}/build/game/${NAME}/recomp-info.txt" recomp_rev || true)"
fi
ZAKURO_REV="$(aot_info_value "$BUILD_INFO" zakuro_rev || true)"

# --- host / tool checks ------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  die "this script must run on macOS with Xcode installed (detected $(uname -s)).
       iOS apps can only be built with the Apple iOS SDK; run it on the macOS VM."
fi

need_tool xcrun "Install Xcode and select it: sudo xcode-select -s \"\$HOME/Applications/Xcode-16.4.0.app\""
need_tool xcodebuild "Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
need_tool xcodegen "Install XcodeGen: brew install xcodegen"
need_tool nm "Install the Xcode command line tools: xcode-select --install"

# --- pre-flight: the libs must be the linked/AOT variants -------------------
check_linked_lib() {
  local file="$1" undefined count missing symbol lines
  aot_lipo_arch_ok "$file" \
    || die "libzakuro_ios.a is not arm64: $file
       (lipo: $AOT_LIPO_INFO)"
  NM_DUMP="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-nm.XXXXXX")"
  aot_nm_dump "$file" "$NM_DUMP" -u \
    || die "nm -u failed on $file (scripts/AOT_BUILD.md §8.2)"
  undefined="$(aot_nm_symbols_with_prefix "$NM_DUMP" '_recomp_')"
  rm -f -- "$NM_DUMP"
  NM_DUMP=""
  [[ -n "$undefined" ]] || die "$file has no undefined _recomp_* symbols.
       That is the interpreter-only shell library, not the linked variant.
       Run scripts/build-linked-ios-lib.sh $NAME (and make sure its build used
       --features linked). See scripts/AOT_BUILD.md §3.3."
  count="$(printf '%s\n' "$undefined" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  missing=""
  lines=$'\n'"$undefined"$'\n'
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    case "$lines" in
      *$'\n'"_${symbol}"$'\n'*) : ;;
      *) missing="$missing _${symbol}" ;;
    esac
  done
  [[ -z "$missing" ]] || die "$file is missing undefined symbols:$missing (scripts/AOT_BUILD.md §8.2)"
  [[ "$count" -eq 7 ]] || die "$file has ${count} undefined _recomp_* symbols; expected 7.
       Run scripts/build-linked-ios-lib.sh $NAME to rebuild the linked variant."
}

check_game_archive() {
  local file="$1" missing="" symbol
  aot_lipo_arch_ok "$file" \
    || die "libgame.a is not arm64: $file (lipo: $AOT_LIPO_INFO)"
  # One nm dump, then exact last-field matching. See aot_nm_dump for the
  # pipefail/SIGPIPE bug this replaces, and aot_nm_has_symbol for the old
  # prefix-matching bug.
  NM_DUMP="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-nm.XXXXXX")"
  aot_nm_dump "$file" "$NM_DUMP" -g \
    || die "nm -g failed on $file"
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    aot_nm_has_symbol "$NM_DUMP" "_${symbol}" || missing="$missing _${symbol}"
  done
  rm -f -- "$NM_DUMP"
  NM_DUMP=""
  [[ -z "$missing" ]] || die "$file does not export generated tables:$missing
       Re-run scripts/build-recomp-ios.sh <rom> $NAME (scripts/AOT_BUILD.md §3.2), or
       re-run build-linked-ios-lib.sh with the right --libgame/--archive."
}

check_linked_lib "$LIB_ZAKURO"
check_game_archive "$LIB_GAME"

# --- GameCatalog.json for this title (build artifact, removed afterwards) ---
# Exactly one game: the title the linked library was built for. The app reads
# this to know that the bundled AOT code matches the selected ROM. Generated in
# a temp file first, validated, then installed where XcodeGen bundles it.
[ -n "$TITLE_ID" ] || die "internal: no title ID resolved before the catalog step"
CATALOG_TMP="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-catalog.XXXXXX")" \
  || die "mktemp failed; cannot create the build-time GameCatalog.json"
if ! game_catalog_write_game "$CATALOG_TMP" "$TITLE_ID" "$DISPLAY_NAME" "$PRODUCT_CODE" "$AOT_VERSION"; then
  die "could not generate GameCatalog.json: ${GAME_CATALOG_ERROR:-unknown error}"
fi
if ! game_catalog_validate "$CATALOG_TMP"; then
  die "the generated GameCatalog.json failed validation: ${GAME_CATALOG_ERROR:-unknown error}"
fi
CATALOG_SUMMARY="$(game_catalog_summary_text)"
CATALOG_DEST="${APP_DIR}/${GAME_CATALOG_RELATIVE_PATH}"
if ! game_catalog_install "$CATALOG_TMP" "$CATALOG_DEST"; then
  die "could not install GameCatalog.json into $CATALOG_DEST: ${GAME_CATALOG_ERROR:-unknown error}"
fi
[[ -z "$CATALOG_TMP" ]] || rm -f -- "$CATALOG_TMP"
log "game catalog: $CATALOG_SUMMARY"
log "  installed for this build: $CATALOG_DEST (removed afterwards)"

LOG_DIR="${ROOT}/build/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-game-ipa-${NAME}-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE"

PROJECT="${APP_DIR}/3ds2apple.xcodeproj"
BUILD_ROOT="${APP_DIR}/build"
EXPECTED_APP="${BUILD_ROOT}/${CONFIGURATION}-iphoneos/3ds2apple.app"

log "repo root:     $ROOT"
log "game name:     $NAME"
log "title id:      $TITLE_ID (source: $TITLE_ID_SOURCE)"
log "lib dir:       $LIB_DIR"
log "bundle id:     $BUNDLE_ID"
log "display name:  $DISPLAY_NAME"
log "product code:  ${PRODUCT_CODE:-(empty)}"
log "configuration: $CONFIGURATION"
log "build log:     $LOG_FILE"

run_stage() {
  local label="$1"
  shift
  if [[ "$VERBOSE" -eq 1 ]]; then
    if ! "$@" 2>&1 | tee -a "$LOG_FILE"; then
      die "$label failed; full log: $LOG_FILE"
    fi
  elif ! "$@" >>"$LOG_FILE" 2>&1; then
    printf '\n--- %s failed: last 80 lines of %s ---\n' "$label" "$LOG_FILE" >&2
    tail -n 80 "$LOG_FILE" >&2
    die "$label failed; full log: $LOG_FILE"
  fi
}

do_xcodegen() {
  ( cd "$APP_DIR" && xcodegen generate --spec project.yml )
}

do_xcodebuild() {
  local actions
  actions=("build")

  # scripts/AOT_BUILD.md §3.4: same directory holds both archives and the order is fixed.
  local ldflags="-L${LIB_DIR} -lzakuro_ios -lgame"

  ( cd "$APP_DIR" && xcodebuild \
      -project "$PROJECT" \
      -target 3ds2apple \
      -sdk iphoneos \
      -configuration "$CONFIGURATION" \
      "${actions[@]}" \
      "SYMROOT=${BUILD_ROOT}" \
      "OBJROOT=${BUILD_ROOT}" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      "OTHER_LDFLAGS=${ldflags}" \
      "PRODUCT_BUNDLE_IDENTIFIER=${BUNDLE_ID}" \
      "INFOPLIST_KEY_CFBundleDisplayName=${DISPLAY_NAME}" )
}

log "generating Xcode project with xcodegen..."
run_stage "xcodegen generate" do_xcodegen
[[ -e "$PROJECT" ]] || die "xcodegen finished but $PROJECT was not generated."
log "xcodegen generate: ok"

log "running xcodebuild (unsigned, iphoneos, AOT link)..."
log "  OTHER_LDFLAGS override: -L${LIB_DIR} -lzakuro_ios -lgame"
run_stage "xcodebuild (AOT)" do_xcodebuild
log "xcodebuild: ok"

# --- locate and validate the .app -------------------------------------------
APP_PATH="$EXPECTED_APP"
if [[ ! -d "$APP_PATH" ]]; then
  FOUND_APP="$(find "$BUILD_ROOT" -maxdepth 6 -type d -name '*.app' 2>/dev/null | sed -n '1p' || true)"
  if [[ -n "$FOUND_APP" ]]; then
    APP_PATH="$FOUND_APP"
    warn "expected $EXPECTED_APP but found $APP_PATH; using the found bundle."
  fi
fi
[[ -d "$APP_PATH" ]] || die "xcodebuild succeeded but no .app was found under $BUILD_ROOT
       (expected $EXPECTED_APP; inspect $LOG_FILE)"
[[ -f "$APP_PATH/Info.plist" ]] || die "built app has no Info.plist: $APP_PATH"

APP_EXECUTABLE="${APP_PATH}/3ds2apple"
if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
  PLIST_EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null || true)"
  [[ -z "$PLIST_EXEC_NAME" ]] || APP_EXECUTABLE="${APP_PATH}/${PLIST_EXEC_NAME}"

  ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)"
  [[ -z "$ACTUAL_BUNDLE_ID" || "$ACTUAL_BUNDLE_ID" == "$BUNDLE_ID" ]] \
    || die "bundle id override failed: Info.plist has '$ACTUAL_BUNDLE_ID', expected '$BUNDLE_ID'
     (the xcodebuild PRODUCT_BUNDLE_IDENTIFIER override did not apply)."

  ACTUAL_DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PATH/Info.plist" 2>/dev/null || true)"
  if [[ -n "$ACTUAL_DISPLAY_NAME" && "$ACTUAL_DISPLAY_NAME" != "$DISPLAY_NAME" ]]; then
    warn "CFBundleDisplayName is '$ACTUAL_DISPLAY_NAME', expected '$DISPLAY_NAME'"
  fi
fi
[[ -f "$APP_EXECUTABLE" ]] || die "app executable not found: $APP_EXECUTABLE"

# The final binary must contain the generated tables (pulled from libgame.a);
# if the OTHER_LDFLAGS override was lost, this check catches the "AOT IPA that
# is secretly the interpreter shell" case before packaging.
NM_DUMP="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-nm.XXXXXX")"
NM_DUMP_UNDEF="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-nm.XXXXXX")"
aot_nm_dump "$APP_EXECUTABLE" "$NM_DUMP" -gU \
  || die "nm -gU failed on $APP_EXECUTABLE (is it a Mach-O binary?)"
aot_nm_dump "$APP_EXECUTABLE" "$NM_DUMP_UNDEF" -u \
  || warn "nm -u failed on $APP_EXECUTABLE; skipping the undefined-symbol check"
if aot_nm_has_symbol "$NM_DUMP" '_recomp_abi'; then
  log "AOT link check: _recomp_abi present in the app binary"
else
  die "the app binary does not contain _recomp_abi, so libgame.a was not linked.
       Check the OTHER_LDFLAGS override and the -lzakuro_ios -lgame order (scripts/AOT_BUILD.md §3.4).
       Full build log: $LOG_FILE"
fi
if aot_nm_has_symbol "$NM_DUMP" '_zk_linked_code'; then
  log "AOT link check: zk_linked_code present (linked build diagnostics available)"
else
  warn "zk_linked_code not found in the app binary (Swift may not call it yet; not fatal)"
fi
UNDEFINED_RECOMP="$(aot_nm_symbols_with_prefix "$NM_DUMP_UNDEF" '_recomp_')"
rm -f -- "$NM_DUMP" "$NM_DUMP_UNDEF"
NM_DUMP=""
NM_DUMP_UNDEF=""
[[ -z "$UNDEFINED_RECOMP" ]] || die "the app binary still has undefined _recomp_* symbols:
$(printf '%s\n' "$UNDEFINED_RECOMP")
       The link must have failed instead; inspect $LOG_FILE"

# --- GameCatalog.json inside the app (S2ARM split) --------------------------
# The catalog must ship in the bundle; the .app is what the phone installs, so a
# missing/invalid catalog is fatal here (unlike the shell build, which only warns).
CATALOG_IN_APP="$(game_catalog_find_in_app "$APP_PATH" || true)"
[[ -n "$CATALOG_IN_APP" ]] || die "the built app contains no GameCatalog.json.
       Make sure ios/app/project.yml bundles Resources/ and that xcodegen ran
       after the catalog was installed (see scripts/AOT_BUILD.md)."
if ! game_catalog_validate "$CATALOG_IN_APP"; then
  die "the GameCatalog.json bundled in the app is invalid: $GAME_CATALOG_ERROR"
fi
[[ "$GAME_CATALOG_COUNT" -eq 1 ]] \
  || die "the bundled GameCatalog.json has $GAME_CATALOG_COUNT games; a per-game AOT IPA must contain exactly 1"
case "$GAME_CATALOG_AOT_LINES" in
  *"$TITLE_ID"*) ;;
  *) die "the bundled GameCatalog.json does not list the linked title ID $TITLE_ID:
       $GAME_CATALOG_AOT_LINES" ;;
esac

# --- IPA name: 3ds2apple-<game>-<version> -----------------------------------
# The version is taken from the built app (CFBundleShortVersionString) so it
# matches SideStore's source.json requirement (version == CFBundleShortVersionString);
# --ipa-version overrides it, project.yml MARKETING_VERSION is the fallback.
APP_VERSION=""
if [[ -x /usr/libexec/PlistBuddy && -f "$APP_PATH/Info.plist" ]]; then
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist" 2>/dev/null || true)"
fi
if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "${APP_DIR}/project.yml" 2>/dev/null | tr -d '"[:space:]' | sed -n '1p')"
fi
[[ -n "$APP_VERSION" ]] || APP_VERSION="$DEFAULT_IPA_VERSION"
IPA_VERSION="${IPA_VERSION_ARG:-$APP_VERSION}"
case "$IPA_VERSION" in
  ''|*[!A-Za-z0-9._-]*) die "invalid --ipa-version: '$IPA_VERSION' (letters, digits, '.', '_', '-')" ;;
esac
if [[ -n "$APP_VERSION" && "$IPA_VERSION" != "$APP_VERSION" ]]; then
  warn "--ipa-version $IPA_VERSION differs from the app CFBundleShortVersionString $APP_VERSION (SideStore source.json expects the app version)"
fi
if [[ -z "$IPA_NAME" ]]; then
  IPA_NAME="3ds2apple-${NAME}-${IPA_VERSION}"
fi
log "game catalog in app: $(basename "$CATALOG_IN_APP") ($GAME_CATALOG_AOT_LINES)"
log "IPA name:      ${IPA_NAME}.ipa (version $IPA_VERSION)"

# --- package IPA (delegates to scripts/package-ipa.sh) ----------------------
[[ -x "${ROOT}/scripts/package-ipa.sh" ]] || die "missing executable: ${ROOT}/scripts/package-ipa.sh"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
IPA_PATH="${OUT_DIR}/${IPA_NAME}.ipa"

log "packaging IPA via scripts/package-ipa.sh -> $IPA_PATH"
"${ROOT}/scripts/package-ipa.sh" "$APP_PATH" --name "$IPA_NAME" --out-dir "$OUT_DIR"
[[ -f "$IPA_PATH" ]] || die "package-ipa.sh finished but $IPA_PATH is missing"

IPA_SHA="$(aot_sha256 "$IPA_PATH")"
IPA_BYTES="$(wc -c < "$IPA_PATH" | tr -d '[:space:]')"
IPA_SIZE="$(du -h "$IPA_PATH" | awk '{print $1}')"
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | sed -n '1p' || echo unknown)"

# --- manifest ---------------------------------------------------------------
MANIFEST="${LIB_DIR}/manifest.txt"
{
  printf 'name=%s\n' "$NAME"
  printf 'title_id=%s\n' "$TITLE_ID"
  printf 'title_id_source=%s\n' "$TITLE_ID_SOURCE"
  printf 'bundle_id=%s\n' "$BUNDLE_ID"
  printf 'display_name=%s\n' "$DISPLAY_NAME"
  printf 'product_code=%s\n' "$PRODUCT_CODE"
  printf 'aot_version=%s\n' "$AOT_VERSION"
  printf 'ipa_version=%s\n' "$IPA_VERSION"
  printf 'game_catalog=%s\n' "$GAME_CATALOG_BUNDLE_NAME"
  printf 'game_catalog_sha256=%s\n' "$(aot_sha256 "$CATALOG_IN_APP")"
  printf 'game_catalog_games=%s\n' "$GAME_CATALOG_COUNT"
  printf 'game_catalog_title_id=%s\n' "$TITLE_ID"
  printf 'configuration=%s\n' "$CONFIGURATION"
  printf 'recomp_rev=%s\n' "${RECOMP_REV:-unknown}"
  printf 'zakuro_rev=%s\n' "${ZAKURO_REV:-unknown}"
  printf 'libzakuro_ios_sha256=%s\n' "$(aot_sha256 "$LIB_ZAKURO")"
  printf 'libgame_sha256=%s\n' "$(aot_sha256 "$LIB_GAME")"
  printf 'app=%s\n' "$APP_PATH"
  printf 'ipa=%s\n' "$IPA_PATH"
  printf 'ipa_bytes=%s\n' "$IPA_BYTES"
  printf 'ipa_sha256=%s\n' "$IPA_SHA"
  printf 'xcode=%s\n' "$XCODE_VERSION"
  printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MANIFEST"

# Self-check the manifest so a future over-escaping regression cannot ship a
# wrong title ID again: title_id must be exactly 16 hex digits.
MANIFEST_TITLE="$(aot_info_value "$MANIFEST" title_id || true)"
[[ "$MANIFEST_TITLE" == "$TITLE_ID" ]] || die "manifest title_id round-trip failed:
       wrote '$MANIFEST_TITLE', expected '$TITLE_ID' (manifest: $MANIFEST)"
aot_validate_title_id "$MANIFEST_TITLE" \
  || die "manifest title_id is not 16 hex digits: '$MANIFEST_TITLE'"

# --- generated-project hygiene ----------------------------------------------
if [[ "$CLEAN_PROJECT" -eq 1 ]]; then
  rm -rf -- "$PROJECT"
  log "removed generated project (--clean-project): $PROJECT"
elif command -v git >/dev/null 2>&1 && [[ -e "${ROOT}/.git" ]]; then
  if ! git -C "$ROOT" check-ignore -q -- "$PROJECT" 2>/dev/null; then
    warn "$PROJECT is not gitignored; add 'ios/app/3ds2apple.xcodeproj/' to
         .gitignore or pass --clean-project, so 'git status' stays clean."
  fi
fi

log "AOT IPA ready"
log "  IPA:      $IPA_PATH ($IPA_SIZE, ${IPA_BYTES} bytes)"
log "  SHA256:   $IPA_SHA"
log "  manifest: $MANIFEST"
log "  title:    $TITLE_ID (source: $TITLE_ID_SOURCE)"
log "  catalog:  $GAME_CATALOG_BUNDLE_NAME: $GAME_CATALOG_AOT_LINES"
log "  bundle:   $BUNDLE_ID (display name: $DISPLAY_NAME, product code: ${PRODUCT_CODE:-(empty)})"
log "install: sideload the unsigned IPA with Sideloadly/AltStore (user's Apple ID)."
log "on-device checks (idevicesyslog): expect zk_linked_code()==1,"
log "  zk_linked_program_id()==0x${TITLE_ID}, zk_recompiled()==1 after load;"
log "  zk_recompiled()==0 means the loader fell back (see AOT_BUILD.md 失败诊断)."
printf '%s\n' "$IPA_PATH"