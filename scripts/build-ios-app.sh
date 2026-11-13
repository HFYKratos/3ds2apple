#!/usr/bin/env bash
# build-ios-app.sh — build the ROM-free 3ds2apple iOS app (unsigned .app).
#
# Runs on the macOS build VM only: it needs Xcode's iOS SDK (xcodebuild) and
# XcodeGen. It reads no ROMs and no game data, and it does NOT sign the app
# (CODE_SIGNING_ALLOWED=NO); signing/installing happens on Windows with
# Sideloadly / AltStore.
#
# Prerequisites (one-time):
#   scripts/build-zakuro-ios.sh        # -> build/ios/libzakuro_ios.a
#   brew install xcodegen
#
# Usage:
#   scripts/build-ios-app.sh
#   scripts/build-ios-app.sh --configuration Debug
#   scripts/build-ios-app.sh --app-dir ios/app --staticlib build/ios/libzakuro_ios.a
#   scripts/build-ios-app.sh --clean --verbose --keep-project
#   scripts/build-ios-app.sh --game-catalog build/catalog/pokemon-y.json
#
# GameCatalog.json (the build-time AOT manifest): a plain shell build writes an
# EMPTY catalog ({"schemaVersion":1,"games":[]}) so every ROM runs in interpreter
# mode. scripts/build-game-ipa.sh installs its one-game catalog itself; here the
# optional --game-catalog PATH lets an advanced shell build ship a pre-generated
# multi-game catalog. The catalog is copied into <app-dir>/Resources/ for the
# build only and removed (or restored) afterwards, so `git status` stays clean
# (.gitignore covers it as a safeguard).
#
# Relative paths are resolved from the repository root, so the script can be
# started from any working directory. It is safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/game-catalog.sh
source "${SCRIPT_DIR}/lib/game-catalog.sh"

APP_DIR="ios/app"
STATICLIB="build/ios/libzakuro_ios.a"
CONFIGURATION="Release"
PROJECT_FILE="3ds2apple.xcodeproj"
TARGET_NAME="3ds2apple"
CLEAN=0
VERBOSE=0
KEEP_PROJECT=0
PROJECT_GENERATED=0
GAME_CATALOG_ARG="${GAME_CATALOG:-}"
CATALOG_SRC=""
CATALOG_TMP=""
CATALOG_SUMMARY=""

usage() {
  cat <<'EOF'
Build the ROM-free 3ds2apple iOS app (unsigned .app) with XcodeGen + xcodebuild.

Usage:
  scripts/build-ios-app.sh [options]

Options:
  --app-dir DIR        XcodeGen project directory (default: ios/app)
  --staticlib PATH     Zakuro iOS static library, relative to repo root
                       (default: build/ios/libzakuro_ios.a)
  --game-catalog PATH  GameCatalog.json to bundle for this build (validated
                       first). Default: write an EMPTY catalog, i.e. no AOT
                       games / interpreter-only shell. Environment equivalent:
                       GAME_CATALOG=PATH
  --configuration CFG  xcodebuild configuration (default: Release)
  --project NAME       Generated Xcode project (default: 3ds2apple.xcodeproj)
  --target NAME        Xcode target to build (default: 3ds2apple)
  --clean              Run the xcodebuild "clean" action first
  --verbose            Stream xcodebuild output to the terminal as well
  --keep-project       Keep the generated .xcodeproj after the build.
                       Default: removed afterwards when it is not gitignored,
                       so `git status` stays clean (XcodeGen regenerates it).
  -h, --help           Show this help and exit

Outputs:
  <app-dir>/build/<Configuration>-iphoneos/<target>.app  unsigned app bundle
  <app-dir>/build/logs/build-ios-app-<timestamp>.log     full build log
  <app-dir>/<project>                                    XcodeGen output (kept only
                                                         when gitignored or with
                                                         --keep-project)

Exit status: 0 on success, non-zero on any failure (the tail of the build log is
printed to stderr on failure).
EOF
}

log() {
  printf '[build-ios-app] %s\n' "$*"
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${ROOT}/$1" ;;
  esac
}

# Keep the tracked tree clean: the .xcodeproj is an XcodeGen artifact and is not
# committed. If the repo already gitignores it, leave it in place for debugging;
# otherwise remove it unless --keep-project was requested.
GENERATED_PROJECT_CLEANED=0
cleanup_generated_project() {
  if [[ "$GENERATED_PROJECT_CLEANED" -eq 1 ]]; then
    return 0
  fi
  GENERATED_PROJECT_CLEANED=1
  if [[ "$PROJECT_GENERATED" -ne 1 ]]; then
    return 0
  fi
  if [[ "$KEEP_PROJECT" -eq 1 ]]; then
    log "keeping generated project (--keep-project): $PROJECT_FILE"
    return 0
  fi
  case "$PROJECT_FILE" in
    *.xcodeproj) ;;
    *) return 0 ;;
  esac
  case "$PROJECT_FILE" in
    "$ROOT"/*) ;;
    *) return 0 ;;
  esac
  if command -v git >/dev/null 2>&1 && [[ -e "$ROOT/.git" ]] \
      && git -C "$ROOT" check-ignore -q -- "$PROJECT_FILE" 2>/dev/null; then
    log "keeping generated project (gitignored): $PROJECT_FILE"
    return 0
  fi
  if [[ -d "$PROJECT_FILE" ]]; then
    rm -rf -- "$PROJECT_FILE"
    log "removed generated project to keep 'git status' clean: $PROJECT_FILE"
    log "  (XcodeGen regenerates it on the next run; use --keep-project to retain it)"
  fi
  return 0
}

# The build-time GameCatalog.json is generated, never committed: a pre-existing
# file is restored, otherwise ours is removed - also when the build fails.
BUILD_CATALOG_CLEANED=0
cleanup_build_catalog() {
  if [[ "$BUILD_CATALOG_CLEANED" -eq 1 ]]; then
    return 0
  fi
  BUILD_CATALOG_CLEANED=1
  if [[ -n "${CATALOG_TMP:-}" && -f "$CATALOG_TMP" ]]; then
    rm -f -- "$CATALOG_TMP"
  fi
  game_catalog_cleanup
}

cleanup_all() {
  local status=$?
  cleanup_build_catalog || true
  cleanup_generated_project || true
  exit "$status"
}
trap cleanup_all EXIT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)
      [[ $# -ge 2 ]] || die "--app-dir requires a value"
      APP_DIR="$2"
      shift 2
      ;;
    --staticlib)
      [[ $# -ge 2 ]] || die "--staticlib requires a value"
      STATICLIB="$2"
      shift 2
      ;;
    --game-catalog)
      [[ $# -ge 2 ]] || die "--game-catalog requires a value"
      GAME_CATALOG_ARG="$2"
      shift 2
      ;;
    --configuration)
      [[ $# -ge 2 ]] || die "--configuration requires a value"
      CONFIGURATION="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || die "--project requires a value"
      PROJECT_FILE="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || die "--target requires a value"
      TARGET_NAME="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --keep-project)
      KEEP_PROJECT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

[[ -n "$APP_DIR" ]] || die "--app-dir must not be empty"
[[ -n "$STATICLIB" ]] || die "--staticlib must not be empty"
[[ -n "$CONFIGURATION" ]] || die "--configuration must not be empty"
[[ -n "$PROJECT_FILE" ]] || die "--project must not be empty"
[[ -n "$TARGET_NAME" ]] || die "--target must not be empty"

# --- host / tool checks ------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  die "this script must run on macOS with Xcode installed (detected $(uname -s)).
       iOS targets can only be built with the Apple iOS SDK; run it on the macOS VM."
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  die "xcodebuild not found. Select the Xcode toolchain first, e.g.:
       sudo xcode-select -s /Applications/Xcode.app
       (the M0 macOS VM keeps Xcode under \$HOME/Applications, see ios/app/README.md)"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  die "xcodegen not found. Install it with: brew install xcodegen
       (or download a release from https://github.com/yonaskolb/XcodeGen)"
fi

# --- resolve and validate paths ---------------------------------------------
APP_DIR_ABS="$(resolve_path "$APP_DIR")"
STATICLIB_ABS="$(resolve_path "$STATICLIB")"

[[ -d "$APP_DIR_ABS" ]] || die "app directory not found: $APP_DIR_ABS (pass --app-dir <dir>)"
APP_DIR_ABS="$(cd "$APP_DIR_ABS" && pwd)"

[[ -f "$APP_DIR_ABS/project.yml" ]] \
  || die "no project.yml found in $APP_DIR_ABS
       XcodeGen needs a spec file; check --app-dir or wait for ios-shell's ios/app/."

[[ -f "$STATICLIB_ABS" ]] \
  || die "static library not found: $STATICLIB_ABS
       Build it first with scripts/build-zakuro-ios.sh, or pass --staticlib <path>."
[[ -s "$STATICLIB_ABS" ]] || die "static library is empty: $STATICLIB_ABS"

# --- build-time GameCatalog.json --------------------------------------------
# The app reads GameCatalog.json from its bundle to learn which title IDs have
# AOT code linked in. A plain shell build ships an EMPTY catalog (everything is
# interpreter-only); --game-catalog PATH bundles a pre-generated one. The file is
# installed before xcodegen so it is copied into the .app, then removed (or a
# pre-existing file restored) when the script exits - including failures.
CATALOG_DEST="$APP_DIR_ABS/${GAME_CATALOG_RELATIVE_PATH}"
if [[ -n "$GAME_CATALOG_ARG" ]]; then
  CATALOG_SRC="$(resolve_path "$GAME_CATALOG_ARG")"
  [[ -f "$CATALOG_SRC" ]] \
    || die "game catalog not found: $CATALOG_SRC (pass --game-catalog <GameCatalog.json>)"
  if ! game_catalog_validate "$CATALOG_SRC"; then
    die "invalid game catalog: $CATALOG_SRC
     ${GAME_CATALOG_ERROR}"
  fi
  CATALOG_SUMMARY="$(game_catalog_summary_text)"
  log "game catalog: $CATALOG_SRC ($CATALOG_SUMMARY)"
else
  CATALOG_TMP="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-catalog.XXXXXX")" \
    || die "mktemp failed; cannot create the build-time game catalog"
  if ! game_catalog_write_empty "$CATALOG_TMP"; then
    die "could not write the empty game catalog: ${GAME_CATALOG_ERROR:-unknown error}"
  fi
  if ! game_catalog_validate "$CATALOG_TMP"; then
    die "the generated empty catalog failed validation: ${GAME_CATALOG_ERROR:-unknown error}"
  fi
  CATALOG_SRC="$CATALOG_TMP"
  CATALOG_SUMMARY="$(game_catalog_summary_text)"
  log "game catalog: empty (no --game-catalog; interpreter-only shell)"
fi
if ! game_catalog_install "$CATALOG_SRC" "$CATALOG_DEST"; then
  die "could not install the game catalog: ${GAME_CATALOG_ERROR:-unknown error}"
fi
[[ -z "$CATALOG_TMP" ]] || rm -f -- "$CATALOG_TMP"
log "game catalog installed: $CATALOG_DEST (removed after the build)"

# The project path is relative to the app dir unless it is already absolute.
case "$PROJECT_FILE" in
  /*) ;;
  *) PROJECT_FILE="$APP_DIR_ABS/$PROJECT_FILE" ;;
esac

BUILD_ROOT="$APP_DIR_ABS/build"
LOG_DIR="$BUILD_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-ios-app-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE"

log "repo root:      $ROOT"
log "app dir:        $APP_DIR_ABS"
log "configuration:  $CONFIGURATION"
log "target:         $TARGET_NAME"
log "static library: $STATICLIB_ABS"
log "build log:      $LOG_FILE"
log "xcodebuild:     $(xcodebuild -version 2>/dev/null | head -n 1 || true)"

STATICLIB_BYTES="$(wc -c < "$STATICLIB_ABS" | tr -d '[:space:]')"
log "static library size: ${STATICLIB_BYTES} bytes"
if command -v shasum >/dev/null 2>&1; then
  log "static library sha256: $(shasum -a 256 "$STATICLIB_ABS" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  log "static library sha256: $(sha256sum "$STATICLIB_ABS" | awk '{print $1}')"
fi
if command -v file >/dev/null 2>&1; then
  log "static library type: $(file -b "$STATICLIB_ABS")"
fi
if command -v nm >/dev/null 2>&1; then
  if nm -gU "$STATICLIB_ABS" 2>/dev/null | grep -q '[[:space:]]_zk_screen_width$'; then
    log "static library exports zk_screen_width: yes"
  else
    printf 'warning: zk_screen_width not found in %s; check --staticlib (link may fail).\n' \
      "$STATICLIB_ABS" >&2
  fi
fi

# --- build helpers -----------------------------------------------------------
run_stage() {
  local label="$1"
  local stage_log="$2"
  shift 2

  if [[ "$VERBOSE" -eq 1 ]]; then
    if ! "$@" 2>&1 | tee -a "$stage_log"; then
      die "$label failed; full log: $stage_log"
    fi
  elif ! "$@" >>"$stage_log" 2>&1; then
    printf '\n--- %s failed: last 80 lines of %s ---\n' "$label" "$stage_log" >&2
    tail -n 80 "$stage_log" >&2
    die "$label failed; full log: $stage_log"
  fi
}

do_xcodegen() {
  ( cd "$APP_DIR_ABS" && xcodegen generate --spec project.yml )
}

do_xcodebuild() {
  # bash 3.2 (macOS default) is fine with array literals and +=.
  local actions=("build")
  if [[ "$CLEAN" -eq 1 ]]; then
    # `xcodebuild clean` refuses to delete an existing SYMROOT it did not create
    # ("Could not delete ... because it was not created by the build system") and
    # exits non-zero even though the following build succeeds. Treat the clean as
    # best effort: stale products are rebuilt by the build action anyway, and the
    # build action's own status is what this script reports.
    ( cd "$APP_DIR_ABS" && xcodebuild \
        -project "$PROJECT_FILE" \
        -target "$TARGET_NAME" \
        -sdk iphoneos \
        -configuration "$CONFIGURATION" \
        clean \
        SYMROOT="$PWD/build" \
        OBJROOT="$PWD/build" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO >/dev/null 2>&1 || true )
  fi

  # SYMROOT/OBJROOT = "$PWD/build" with cwd = app dir, so the .app ends up in
  # ios/app/build/<Configuration>-iphoneos/ (covered by .gitignore's build/).
  ( cd "$APP_DIR_ABS" && xcodebuild \
      -project "$PROJECT_FILE" \
      -target "$TARGET_NAME" \
      -sdk iphoneos \
      -configuration "$CONFIGURATION" \
      "${actions[@]}" \
      SYMROOT="$PWD/build" \
      OBJROOT="$PWD/build" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO )
}

# --- generate + build --------------------------------------------------------
log "generating Xcode project with xcodegen..."
PROJECT_GENERATED=1
run_stage "xcodegen generate" "$LOG_FILE" do_xcodegen
log "xcodegen generate: ok"

[[ -e "$PROJECT_FILE" ]] \
  || die "xcodegen finished but the project was not generated: $PROJECT_FILE
       Check the 'name:' field in $APP_DIR_ABS/project.yml, or pass --project <name>.xcodeproj."

log "running xcodebuild (unsigned, iphoneos)..."
run_stage "xcodebuild" "$LOG_FILE" do_xcodebuild
log "xcodebuild: ok"

# --- locate and report the .app ---------------------------------------------
EXPECTED_APP="$BUILD_ROOT/$CONFIGURATION-iphoneos/$TARGET_NAME.app"
APP_PATH="$EXPECTED_APP"

if [[ ! -d "$APP_PATH" ]]; then
  FOUND_APP="$(find "$BUILD_ROOT" -maxdepth 6 -type d -name "${TARGET_NAME}.app" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$FOUND_APP" ]]; then
    APP_PATH="$FOUND_APP"
    printf 'warning: expected %s but found %s; using the found bundle.\n' \
      "$EXPECTED_APP" "$APP_PATH" >&2
  fi
fi

[[ -n "$APP_PATH" && -d "$APP_PATH" ]] \
  || die "xcodebuild reported success but no .app was found under $BUILD_ROOT
       (expected $EXPECTED_APP; inspect the log: $LOG_FILE)"

# --- GameCatalog.json bundle check ------------------------------------------
# The catalog must ship inside the .app. The Swift side falls back to "no AOT
# games" when it is missing, so this is a warning here; the per-game build
# (scripts/build-game-ipa.sh) treats a missing catalog as fatal for its title.
CATALOG_IN_APP="$(game_catalog_find_in_app "$APP_PATH" || true)"
if [[ -n "$CATALOG_IN_APP" ]]; then
  if game_catalog_validate "$CATALOG_IN_APP"; then
    log "game catalog in app: $(basename "$CATALOG_IN_APP") ($(game_catalog_summary_text))"
  else
    printf 'warning: bundled GameCatalog.json is invalid: %s\n' "$GAME_CATALOG_ERROR" >&2
  fi
else
  printf 'warning: GameCatalog.json was not copied into %s\n' "$APP_PATH" >&2
  printf 'warning: the app will mark every game interpreter-only; check that ios/app/project.yml bundles Resources/.\n' >&2
fi

# --- Metal Performance HUD build gate ---------------------------------------
# Xcode's generated Info.plist only maps known INFOPLIST_KEY_* build settings,
# so the documented Metal HUD key is injected after the build.
if [[ -f "$APP_PATH/Info.plist" ]]; then
  /usr/libexec/PlistBuddy -c 'Add :MetalHudEnabled bool true' "$APP_PATH/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Set :MetalHudEnabled true' "$APP_PATH/Info.plist" 2>/dev/null || true
fi

# --- link sanity check (non-fatal) -------------------------------------------
# A static library only links the objects the app references: I1 calls
# zk_screen_width(), so that symbol is the reliable probe for "libzakuro_ios.a
# is linked". Other zk_* symbols may legitimately be absent until later
# iterations call them.
if command -v nm >/dev/null 2>&1 && [[ -f "$APP_PATH/Info.plist" ]]; then
  APP_EXECUTABLE="$APP_PATH/$TARGET_NAME"
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    PLIST_EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null || true)"
    if [[ -n "$PLIST_EXEC_NAME" ]]; then
      APP_EXECUTABLE="$APP_PATH/$PLIST_EXEC_NAME"
    fi
  fi

  if [[ -f "$APP_EXECUTABLE" ]]; then
    if nm -gU "$APP_EXECUTABLE" 2>/dev/null | grep -q '[[:space:]]_zk_screen_width$'; then
      log "symbol check: zk_screen_width linked into the app binary"
    else
      printf 'warning: zk_screen_width not found in %s\n' "$APP_EXECUTABLE" >&2
      printf 'warning: check that project.yml links build/ios/libzakuro_ios.a (OTHER_LDFLAGS -lzakuro_ios).\n' >&2
    fi
  fi
fi

APP_SIZE="$(du -sh "$APP_PATH" | awk '{print $1}')"
log "built app: $APP_PATH ($APP_SIZE)"
log "unsigned (CODE_SIGNING_ALLOWED=NO); sign with Sideloadly/AltStore on Windows."
log "next: scripts/package-ipa.sh \"$APP_PATH\" <name>"

cleanup_build_catalog
cleanup_generated_project
printf '%s\n' "$APP_PATH"