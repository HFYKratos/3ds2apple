#!/usr/bin/env bash
# build-game-ipa.sh — build the per-game AOT IPA (linked Zakuro + libgame.a).
#
# Per-game AOT pipeline (authoritative design: ios/zakuro-ios/RECOMP.md §3.4/§9):
#
#   scripts/build-zakuro-ios.sh              # once per Zakuro checkout
#   scripts/build-recomp-ios.sh <rom> <name> # 3dsrecomp -> librecomp.a
#   scripts/build-linked-ios-lib.sh <name>   # linked libs in build/ios/<name>/
#   scripts/build-game-ipa.sh <name>         # this script -> IPA/<name>-AOT.ipa
#
# The XcodeGen project in ios/app is generated as usual (no ios/app changes are
# needed); the two static archives are linked by overriding OTHER_LDFLAGS on the
# xcodebuild command line. The order is fixed and deliberate (RECOMP.md §3.4):
#
#   -L<repo>/build/ios/<name> -lzakuro_ios -lgame
#
# `-lzakuro_ios` first (creates the unresolved _recomp_* references), then
# `-lgame` (resolves them). Reversing it, or forgetting libgame.a, makes the
# link fail with undefined _recomp_* symbols - that is the intended guard
# against shipping an interpreter-only "AOT" build.
#
# The app remains unsigned (CODE_SIGNING_ALLOWED=NO); signing/installing is the
# user's job on Windows with Sideloadly/AltStore. Nothing is committed: libs,
# build logs, the IPA and its manifest all live in gitignored directories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIGURATION="Release"
APP_DIR_ARG="${ROOT}/ios/app"
LIB_DIR_ARG=""
OUT_DIR_ARG="${ROOT}/IPA"
IPA_NAME_ARG=""
BUNDLE_ID_ARG=""
DISPLAY_NAME_ARG=""
NAME_ARG=""
CLEAN_PROJECT=0
VERBOSE=0

EXPECTED_RECOMP_SYMBOLS="recomp_abi recomp_generation recomp_entry_count recomp_entries recomp_module_count recomp_modules recomp_origins"

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
  --lib-dir DIR      Per-game lib dir (default: build/ios/<name>)
  --app-dir DIR      XcodeGen project dir (default: ios/app)
  --configuration C  xcodebuild configuration (default: Release)
  --bundle-id ID     Per-game bundle identifier (default:
                     com.kratos.3ds2apple.<name>); lets the AOT app be
                     installed side by side with the interpreter shell
  --display-name T   Home-screen name (default: <name>)
  --out-dir DIR      IPA output dir (default: IPA/, gitignored)
  --ipa-name NAME    IPA base name without .ipa (default: <name>-AOT)
  --clean-project    Delete the generated 3ds2apple.xcodeproj afterwards
                     (default: keep; ios/app/3ds2apple.xcodeproj/ is gitignored)
  --verbose          Stream xcodebuild output to the terminal as well
  -h, --help         Show this help and exit

Outputs (all gitignored):
  IPA/<name>-AOT.ipa                     unsigned AOT IPA
  build/ios/<name>/manifest.txt          title ID, revs, SHA256 manifest
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

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

info_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

sanitize_bundle_component() {
  printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9.' '-' \
    | sed -e 's/--*/-/g' -e 's/^-*//' -e 's/-*$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      NAME_ARG="$2"
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
case "$NAME" in
  .|..|*/*|.*) die "invalid game name: '$NAME' (use letters, digits, '.', '_', '-')" ;;
esac
if ! printf '%s\n' "$NAME" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  die "invalid game name: '$NAME' (use letters, digits, '.', '_', '-')"
fi
[[ -n "$CONFIGURATION" ]] || die "--configuration must not be empty"

APP_DIR="$(resolve_path "$APP_DIR_ARG")"
LIB_DIR="$(resolve_path "${LIB_DIR_ARG:-build/ios/${NAME}}")"
OUT_DIR="$(resolve_path "$OUT_DIR_ARG")"
[[ -d "$APP_DIR" ]] || die "app directory not found: $APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd)"
[[ -f "${APP_DIR}/project.yml" ]] || die "no project.yml in $APP_DIR (ios/app contract)"
[[ -d "$LIB_DIR" ]] || die "per-game lib dir not found: $LIB_DIR
       Run scripts/build-linked-ios-lib.sh $NAME first."

LIB_ZAKURO="${LIB_DIR}/libzakuro_ios.a"
LIB_GAME="${LIB_DIR}/libgame.a"
BUILD_INFO="${LIB_DIR}/build-info.txt"
[[ -f "$LIB_ZAKURO" ]] || die "missing $LIB_ZAKURO (run scripts/build-linked-ios-lib.sh $NAME)"
[[ -f "$LIB_GAME" ]] || die "missing $LIB_GAME (run scripts/build-linked-ios-lib.sh $NAME)"

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
IPA_NAME="${IPA_NAME_ARG:-${NAME}-AOT}"
IPA_NAME="${IPA_NAME%.ipa}"
[[ -n "$IPA_NAME" ]] || die "--ipa-name must not be empty"
case "$IPA_NAME" in
  */*) die "--ipa-name must be a file name, not a path: $IPA_NAME" ;;
esac

TITLE_ID="$(info_value "$BUILD_INFO" title_id || true)"
RECOMP_REV="$(info_value "$BUILD_INFO" recomp_rev || true)"
ZAKURO_REV="$(info_value "$BUILD_INFO" zakuro_rev || true)"

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
lipo_arch_ok() {
  local file="$1" lipo_info
  lipo_info="$(xcrun lipo -info "$file" 2>&1)" || return 1
  case "$lipo_info" in
    *arm64*) return 0 ;;
    *) warn "not an arm64 archive: $lipo_info"; return 1 ;;
  esac
}

check_linked_lib() {
  local file="$1" undefined
  lipo_arch_ok "$file" || die "libzakuro_ios.a is not arm64: $file"
  undefined="$(nm -u "$file" 2>/dev/null | awk '{print $NF}' | grep '^_recomp_' | sort -u || true)"
  [[ -n "$undefined" ]] || die "$file has no undefined _recomp_* symbols.
       That is the interpreter-only shell library, not the linked variant.
       Run scripts/build-linked-ios-lib.sh $NAME (and make sure its build used
       --features linked). See RECOMP.md §3.3."
  local count missing symbol
  count="$(printf '%s\n' "$undefined" | wc -l | tr -d '[:space:]')"
  missing=""
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    printf '%s\n' "$undefined" | grep -qx "_${symbol}" || missing="$missing _${symbol}"
  done
  [[ -z "$missing" ]] || die "$file is missing undefined symbols:$missing (RECOMP.md §8.2)"
  [[ "$count" -eq 7 ]] || die "$file has ${count} undefined _recomp_* symbols; expected 7.
       Run scripts/build-linked-ios-lib.sh $NAME to rebuild the linked variant."
}

check_game_archive() {
  local file="$1" missing=""
  lipo_arch_ok "$file" || die "libgame.a is not arm64: $file"
  local symbol
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    nm -g "$file" 2>/dev/null | grep -q "_${symbol}\$" || missing="$missing _${symbol}"
  done
  [[ -z "$missing" ]] || die "$file does not export generated tables:$missing
       Re-run scripts/build-recomp-ios.sh <rom> $NAME (RECOMP.md §3.2)."
}

check_linked_lib "$LIB_ZAKURO"
check_game_archive "$LIB_GAME"

LOG_DIR="${ROOT}/build/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-game-ipa-${NAME}-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE"

PROJECT="${APP_DIR}/3ds2apple.xcodeproj"
BUILD_ROOT="${APP_DIR}/build"
EXPECTED_APP="${BUILD_ROOT}/${CONFIGURATION}-iphoneos/3ds2apple.app"

log "repo root:     $ROOT"
log "game name:     $NAME"
log "title id:      ${TITLE_ID:-unknown}"
log "lib dir:       $LIB_DIR"
log "bundle id:     $BUNDLE_ID"
log "display name:  $DISPLAY_NAME"
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

  # RECOMP.md §3.4: same directory holds both archives and the order is fixed.
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
  FOUND_APP="$(find "$BUILD_ROOT" -maxdepth 6 -type d -name '*.app' 2>/dev/null | head -n 1 || true)"
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
if nm -gU "$APP_EXECUTABLE" 2>/dev/null | grep -q '[[:space:]]_recomp_abi$'; then
  log "AOT link check: _recomp_abi present in the app binary"
else
  die "the app binary does not contain _recomp_abi, so libgame.a was not linked.
       Check the OTHER_LDFLAGS override and the -lzakuro_ios -lgame order (RECOMP.md §3.4).
       Full build log: $LOG_FILE"
fi
UNDEFINED_RECOMP="$(nm -u "$APP_EXECUTABLE" 2>/dev/null | awk '{print $NF}' | grep '^_recomp_' | sort -u || true)"
[[ -z "$UNDEFINED_RECOMP" ]] || die "the app binary still has undefined _recomp_* symbols:
$(printf '%s\n' "$UNDEFINED_RECOMP")
       The link must have failed instead; inspect $LOG_FILE"
if nm -gU "$APP_EXECUTABLE" 2>/dev/null | grep -q '[[:space:]]_zk_linked_code$'; then
  log "AOT link check: zk_linked_code present (linked build diagnostics available)"
else
  warn "zk_linked_code not found in the app binary (Swift may not call it yet; not fatal)"
fi

# --- package IPA (delegates to scripts/package-ipa.sh) ----------------------
[[ -x "${ROOT}/scripts/package-ipa.sh" ]] || die "missing executable: ${ROOT}/scripts/package-ipa.sh"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
IPA_PATH="${OUT_DIR}/${IPA_NAME}.ipa"

log "packaging IPA via scripts/package-ipa.sh -> $IPA_PATH"
"${ROOT}/scripts/package-ipa.sh" "$APP_PATH" --name "$IPA_NAME" --out-dir "$OUT_DIR"
[[ -f "$IPA_PATH" ]] || die "package-ipa.sh finished but $IPA_PATH is missing"

IPA_SHA="$(sha256_of "$IPA_PATH")"
IPA_BYTES="$(wc -c < "$IPA_PATH" | tr -d '[:space:]')"
IPA_SIZE="$(du -h "$IPA_PATH" | awk '{print $1}')"

# --- manifest ---------------------------------------------------------------
MANIFEST="${LIB_DIR}/manifest.txt"
{
  printf 'name=%s\n' "$NAME"
  printf 'title_id=%s\n' "${TITLE_ID:-unknown}"
  printf 'bundle_id=%s\n' "$BUNDLE_ID"
  printf 'display_name=%s\n' "$DISPLAY_NAME"
  printf 'configuration=%s\n' "$CONFIGURATION"
  printf 'recomp_rev=%s\n' "${RECOMP_REV:-unknown}"
  printf 'zakuro_rev=%s\n' "${ZAKURO_REV:-unknown}"
  printf 'libzakuro_ios_sha256=%s\n' "$(sha256_of "$LIB_ZAKURO")"
  printf 'libgame_sha256=%s\n' "$(sha256_of "$LIB_GAME")"
  printf 'app=%s\n' "$APP_PATH"
  printf 'ipa=%s\n' "$IPA_PATH"
  printf 'ipa_bytes=%s\n' "$IPA_BYTES"
  printf 'ipa_sha256=%s\n' "$IPA_SHA"
  printf 'xcode=%s\n' "$(xcodebuild -version 2>/dev/null | head -n 1 || echo unknown)"
  printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MANIFEST"

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
log "  bundle:   $BUNDLE_ID (display name: $DISPLAY_NAME)"
log "install: sideload the unsigned IPA with Sideloadly/AltStore (user's Apple ID)."
if [[ -n "$TITLE_ID" ]]; then
  log "on-device checks (idevicesyslog): expect zk_linked_code()==1,"
  log "  zk_linked_program_id()==0x${TITLE_ID}, zk_recompiled()==1 after load;"
  log "  zk_recompiled()==0 means the loader fell back (see AOT_BUILD.md §失败诊断)."
fi
printf '%s\n' "$IPA_PATH"