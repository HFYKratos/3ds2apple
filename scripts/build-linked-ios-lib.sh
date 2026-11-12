#!/usr/bin/env bash
# build-linked-ios-lib.sh — build the per-game `linked` libzakuro_ios.a.
#
# Per-game AOT pipeline (authoritative design: ios/zakuro-ios/RECOMP.md §3.3/§9):
#
#   scripts/build-zakuro-ios.sh              # once: Zakuro checkout + baseline lib
#   scripts/build-recomp-ios.sh <rom> <name> # 3dsrecomp port -> librecomp.a
#   scripts/build-linked-ios-lib.sh <name>   # this script -> build/ios/<name>/
#   scripts/build-game-ipa.sh <name>         # IPA/<name>-AOT.ipa
#
# This script copies ios/zakuro-ios into the Zakuro checkout (refreshing the
# crate), builds the `linked` variant with the ROM's title ID baked in at build
# time (ZAKURO_LINKED_PROGRAM_ID), and collects both static archives that the
# app link needs:
#
#   build/ios/<name>/libzakuro_ios.a   linked Zakuro runtime (7 undefined _recomp_*)
#   build/ios/<name>/libgame.a         arm64 iOS archive from 3dsrecomp (tables)
#
# Must run on macOS with Xcode + Rust (aarch64-apple-ios). Nothing is committed:
# the libs live under build/ and are gitignored.
#
# Title ID: pass it explicitly or let the script read it from the output of
# scripts/build-recomp-ios.sh (build/game/<name>/src/main.rs or recomp-info.txt).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ZAKURO_DIR="${ZAKURO_DIR:-${ROOT}/third_party/zakuro}"
IOS_TARGET="aarch64-apple-ios"

TITLE_ARG=""
NAME_ARG=""
LIB_DIR_ARG=""
ISOLATED_TARGET=0
VERBOSE=0

# The linked build must reference exactly these 7 tables from the generated C
# archive (RECOMP.md §2.1/§8.2); libgame.a resolves them at the app link.
EXPECTED_RECOMP_SYMBOLS="recomp_abi recomp_generation recomp_entry_count recomp_entries recomp_module_count recomp_modules recomp_origins"

usage() {
  cat <<'EOF'
Build the per-game `linked` libzakuro_ios.a and collect libgame.a.

Usage:
  scripts/build-linked-ios-lib.sh <name> [options]
  scripts/build-linked-ios-lib.sh <title-id> <name> [options]

Arguments:
  <name>             Short game name used by build-recomp-ios.sh
                     (open build/game/<name>/)
  <title-id>         Optional 16 hex digit ROM title ID; when omitted it is
                     read from build/game/<name>/src/main.rs or recomp-info.txt
                     (or pass --title-id)

Options:
  --title-id ID      16 hex digit title ID (e.g. 0004000000055E00)
  --name NAME        Same as the <name> argument
  --zakuro-dir DIR   Zakuro checkout (default: third_party/zakuro;
                     env: ZAKURO_DIR)
  --lib-dir DIR      Output dir (default: build/ios/<name>)
  --isolated-target  Use build/cargo-target/<name> as CARGO_TARGET_DIR instead
                     of the shared Zakuro target dir (RECOMP.md §3.3 suggests
                     isolation for back-to-back multi-game builds; it costs a
                     full dependency rebuild, so the shared cache is default)
  --verbose          Stream cargo output to the terminal as well
  -h, --help         Show this help and exit

Outputs (all gitignored):
  build/ios/<name>/libzakuro_ios.a   linked variant; must show 7 undefined
                                     _recomp_* symbols (resolved by libgame.a)
  build/ios/<name>/libgame.a         arm64 iOS archive of the generated C
  build/ios/<name>/build-info.txt    title ID / revs / sizes / SHA256 manifest
  build/logs/build-linked-ios-lib-<name>-*.log

Exit status: 0 on success, non-zero on failure (the log tail is printed).
EOF
}

log() {
  printf '[build-linked-ios-lib] %s\n' "$*"
}

warn() {
  printf '[build-linked-ios-lib] warning: %s\n' "$*" >&2
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
  # Reads `key=value` from a build info/manifest file.
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

normalize_title_id() {
  local value="$1"
  value="${value#0x}"
  value="${value#0X}"
  printf '%s\n' "$value" | tr 'a-f' 'A-F'
}

validate_title_id() {
  local value="$1"
  case "$value" in
    ''|*[!0-9A-F]*) return 1 ;;
  esac
  [[ "${#value}" -eq 16 ]] || return 1
  return 0
}

POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title-id)
      [[ $# -ge 2 ]] || die "--title-id requires a value"
      TITLE_ARG="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      NAME_ARG="$2"
      shift 2
      ;;
    --zakuro-dir)
      [[ $# -ge 2 ]] || die "--zakuro-dir requires a value"
      ZAKURO_DIR="$2"
      shift 2
      ;;
    --lib-dir)
      [[ $# -ge 2 ]] || die "--lib-dir requires a value"
      LIB_DIR_ARG="$2"
      shift 2
      ;;
    --isolated-target)
      ISOLATED_TARGET=1
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
      POS+=("$1")
      shift
      ;;
  esac
done

[[ "${#POS[@]}" -le 2 ]] || die "too many arguments (try --help)"
if [[ "${#POS[@]}" -eq 2 ]]; then
  TITLE_ARG="${POS[0]}"
  NAME_ARG="${POS[1]}"
elif [[ "${#POS[@]}" -eq 1 ]]; then
  if [[ "${POS[0]}" =~ ^(0[xX])?[0-9a-fA-F]{16}$ ]]; then
    TITLE_ARG="${POS[0]}"
  else
    NAME_ARG="${POS[0]}"
  fi
fi

[[ -n "$NAME_ARG" ]] || die "missing <name> argument
usage: scripts/build-linked-ios-lib.sh <name> [options]
       scripts/build-linked-ios-lib.sh <title-id> <name> [options]"
NAME="$NAME_ARG"
case "$NAME" in
  .|..|*/*|.*) die "invalid game name: '$NAME' (use letters, digits, '.', '_', '-')" ;;
esac
if ! printf '%s\n' "$NAME" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  die "invalid game name: '$NAME' (use letters, digits, '.', '_', '-')"
fi

ZAKURO_DIR="$(resolve_path "$ZAKURO_DIR")"
LIB_DIR="$(resolve_path "${LIB_DIR_ARG:-build/ios/${NAME}}")"
GAME_DIR="${ROOT}/build/game/${NAME}"
GAME_ARCHIVE="${GAME_DIR}/code/librecomp.a"
RECOMP_INFO="${GAME_DIR}/recomp-info.txt"
BUILD_INFO="${LIB_DIR}/build-info.txt"

# --- resolve the title ID (RECOMP.md §3.2) -----------------------------------
if [[ -z "$TITLE_ARG" ]]; then
  TITLE_ARG="$(info_value "$RECOMP_INFO" title_id || true)"
fi
if [[ -z "$TITLE_ARG" ]]; then
  MAIN_RS="${GAME_DIR}/src/main.rs"
  if [[ -f "$MAIN_RS" ]]; then
    TITLE_ARG="$(grep -oE '0x[0-9A-Fa-f]{16}' "$MAIN_RS" | head -n 1 | sed -e 's/^0[xX]//' || true)"
  fi
fi
if [[ -z "$TITLE_ARG" ]]; then
  TITLE_ARG="$(info_value "$BUILD_INFO" title_id || true)"
fi

TITLE_ID="$(normalize_title_id "$TITLE_ARG")"
validate_title_id "$TITLE_ID" || die "could not determine a valid 16 hex digit title ID (got '$TITLE_ID').
       Run scripts/build-recomp-ios.sh first (it extracts the title ID from the
       generated src/main.rs), or pass --title-id 0004000000055E00."

# --- host / tool checks ------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  die "this script must run on macOS with Xcode + Rust installed.
       Detected $(uname -s); run it on the macOS VM (iOS static libs need the iOS SDK)."
fi

need_tool cargo "Install Rust (https://rustup.rs) and the aarch64-apple-ios target"
need_tool git "Install the Xcode command line tools: xcode-select --install"
need_tool xcrun "Install Xcode and select it: sudo xcode-select -s \"\$HOME/Applications/Xcode-16.4.0.app\""
need_tool nm "Install the Xcode command line tools: xcode-select --install"

[[ -d "$ZAKURO_DIR" || ! -e "$ZAKURO_DIR" ]] || die "Zakuro path is not a directory: $ZAKURO_DIR"
[[ -f "$GAME_ARCHIVE" ]] || die "missing recompiled archive: $GAME_ARCHIVE
       Run scripts/build-recomp-ios.sh <rom> $NAME first."

LOG_DIR="${ROOT}/build/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-linked-ios-lib-${NAME}-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE"

log "repo root:  $ROOT"
log "game name:  $NAME"
log "title id:   $TITLE_ID"
log "zakuro:     $ZAKURO_DIR"
log "lib dir:    $LIB_DIR"
log "build log:  $LOG_FILE"

# --- zinc/prerequisites ------------------------------------------------------
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

ensure_zakuro_checkout() {
  local cargo_toml="${ZAKURO_DIR}/Cargo.toml"
  if [[ ! -d "${ZAKURO_DIR}/.git" || ! -f "$cargo_toml" ]]; then
    log "Zakuro checkout missing; running scripts/build-zakuro-ios.sh (one-time setup)"
    ZAKURO_DIR="$ZAKURO_DIR" "$ROOT/scripts/build-zakuro-ios.sh"
    return 0
  fi
  if ! grep -q '"crates/zakuro-ios"' "$cargo_toml"; then
    log "zakuro-ios workspace member missing; running scripts/build-zakuro-ios.sh (one-time setup)"
    ZAKURO_DIR="$ZAKURO_DIR" "$ROOT/scripts/build-zakuro-ios.sh"
  fi
}

ensure_zakuro_checkout

if ! command -v rustup >/dev/null 2>&1; then
  warn "rustup not found; assuming the aarch64-apple-ios target is installed"
elif ! rustup target list --installed 2>/dev/null | grep -qx "$IOS_TARGET"; then
  log "adding Rust target: $IOS_TARGET"
  rustup target add "$IOS_TARGET"
fi

# Refresh the crate copy: the checkout must build the current ios/zakuro-ios
# (RECOMP.md §3.3 step 1 does the first copy; re-copying is idempotent).
CRATE_DST="${ZAKURO_DIR}/crates/zakuro-ios"
mkdir -p "$(dirname "$CRATE_DST")"
log "refreshing crate: $CRATE_DST"
rm -rf -- "$CRATE_DST"
cp -R "${ROOT}/ios/zakuro-ios" "$CRATE_DST"

# --- choose the cargo target dir (RECOMP.md §3.3) ----------------------------
if [[ "$ISOLATED_TARGET" -eq 1 ]]; then
  CARGO_TARGET_DIR_ABS="${ROOT}/build/cargo-target/${NAME}"
  mkdir -p "$CARGO_TARGET_DIR_ABS"
  export CARGO_TARGET_DIR="$CARGO_TARGET_DIR_ABS"
  log "cargo target dir (isolated): $CARGO_TARGET_DIR"
elif [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
  log "cargo target dir (inherited CARGO_TARGET_DIR): $CARGO_TARGET_DIR"
else
  log "cargo target dir (shared): ${ZAKURO_DIR}/target"
fi
TARGET_ROOT="${CARGO_TARGET_DIR:-${ZAKURO_DIR}/target}"
case "$TARGET_ROOT" in
  /*) ;;
  *) TARGET_ROOT="${ZAKURO_DIR}/${TARGET_ROOT}" ;;
esac
LIB_BUILT="${TARGET_ROOT}/${IOS_TARGET}/release/libzakuro_ios.a"

# Force the crate (and its build.rs env check) to rebuild for this title even
# when a previous game was built in the same target dir (RECOMP.md §3.3).
log "cargo clean -p zakuro-ios (force per-game relink; dependency cache is kept)"
( cd "$ZAKURO_DIR" && cargo clean -p zakuro-ios ) >>"$LOG_FILE" 2>&1 \
  || warn "cargo clean -p zakuro-ios returned non-zero (continuing; see $LOG_FILE)"

do_linked_build() {
  ( cd "$ZAKURO_DIR" && \
      ZAKURO_LINKED_PROGRAM_ID="$TITLE_ID" \
      cargo build -p zakuro-ios --release --features linked --target "$IOS_TARGET" )
}

log "building linked libzakuro_ios.a for ${TITLE_ID} (RECOMP.md §3.3 step 2)"
run_stage "cargo build (zakuro-ios --features linked)" do_linked_build

[[ -f "$LIB_BUILT" ]] || die "linked library was not produced: $LIB_BUILT"

# --- validate the linked library (RECOMP.md §2.1/§8.2) ----------------------
lipo_arch_ok() {
  local file="$1" lipo_info
  lipo_info="$(xcrun lipo -info "$file" 2>&1)" || return 1
  case "$lipo_info" in
    *arm64*) return 0 ;;
    *) warn "not an arm64 archive: $lipo_info"; return 1 ;;
  esac
}

collect_recomp_symbols() {
  # $1 = nm mode flags (e.g. "-u" or "-g"), $2 = file
  local mode="$1" file="$2"
  nm "$mode" "$file" 2>/dev/null | awk '{print $NF}' | grep '^_recomp_' | sort -u || true
}

validate_linked_lib() {
  local file="$1"
  [[ -s "$file" ]] || die "linked library is empty: $file"
  lipo_arch_ok "$file" || die "linked library is not arm64: $file"

  local undefined count missing
  undefined="$(collect_recomp_symbols -u "$file")"
  if [[ -z "$undefined" ]]; then
    die "linked library has no undefined _recomp_* symbols: $file
       That looks like the interpreter-only shell library. Did the build use
       --features linked and got copied from the right target dir?"
  fi
  count="$(printf '%s\n' "$undefined" | wc -l | tr -d '[:space:]')"
  missing=""
  local symbol
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    if ! printf '%s\n' "$undefined" | grep -qx "_${symbol}"; then
      missing="$missing _${symbol}"
    fi
  done
  [[ -z "$missing" ]] || die "linked library is missing expected undefined symbols:$missing
       (RECOMP.md §8.2 expects exactly 7: $(printf '%s ' $EXPECTED_RECOMP_SYMBOLS))"
  [[ "$count" -eq 7 ]] || die "linked library has ${count} undefined _recomp_* symbols; expected exactly 7.
       See RECOMP.md §8.2: $(printf '%s\n' "$undefined" | tr '\n' ' ')"
}

validate_game_archive() {
  local file="$1"
  [[ -s "$file" ]] || die "libgame archive is empty: $file"
  lipo_arch_ok "$file" || die "libgame archive is not arm64: $file"
  local missing=""
  local symbol
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    if ! nm -g "$file" 2>/dev/null | grep -q "[[:space:]]_${symbol}\$"; then
      missing="$missing _${symbol}"
    fi
  done
  [[ -z "$missing" ]] || die "libgame archive does not export generated tables:$missing
       Check that build-recomp-ios.sh produced $GAME_ARCHIVE with 3dsrecomp port."
}

validate_linked_lib "$LIB_BUILT"
validate_game_archive "$GAME_ARCHIVE"

# --- collect per-game libs ---------------------------------------------------
mkdir -p "$LIB_DIR"
cp -f "$LIB_BUILT" "${LIB_DIR}/libzakuro_ios.a"
cp -f "$GAME_ARCHIVE" "${LIB_DIR}/libgame.a"

LIB_ZAKURO="${LIB_DIR}/libzakuro_ios.a"
LIB_GAME="${LIB_DIR}/libgame.a"

ZAKURO_REV="unknown"
if [[ -d "${ZAKURO_DIR}/.git" ]]; then
  ZAKURO_REV="$(git -C "$ZAKURO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
RECOMP_REV="$(info_value "$RECOMP_INFO" recomp_rev || true)"
ROM_BASENAME="$(info_value "$RECOMP_INFO" rom_basename || true)"

{
  printf 'name=%s\n' "$NAME"
  printf 'title_id=%s\n' "$TITLE_ID"
  printf 'zakuro_rev=%s\n' "$ZAKURO_REV"
  printf 'recomp_rev=%s\n' "${RECOMP_REV:-unknown}"
  printf 'rom_basename=%s\n' "${ROM_BASENAME:-unknown}"
  printf 'libzakuro_ios=%s\n' "$LIB_ZAKURO"
  printf 'libzakuro_ios_bytes=%s\n' "$(wc -c < "$LIB_ZAKURO" | tr -d '[:space:]')"
  printf 'libzakuro_ios_sha256=%s\n' "$(sha256_of "$LIB_ZAKURO")"
  printf 'libgame=%s\n' "$LIB_GAME"
  printf 'libgame_bytes=%s\n' "$(wc -c < "$LIB_GAME" | tr -d '[:space:]')"
  printf 'libgame_sha256=%s\n' "$(sha256_of "$LIB_GAME")"
  printf 'cargo_target_dir=%s\n' "$TARGET_ROOT"
  printf 'isolated_target=%s\n' "$ISOLATED_TARGET"
  printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BUILD_INFO"

log "per-game linked libs ready"
log "  libzakuro_ios.a: $LIB_ZAKURO"
log "  libgame.a:       $LIB_GAME"
log "  build info:      $BUILD_INFO"
log "next: scripts/build-game-ipa.sh ${NAME}"
log "  (the app must link -L build/ios/${NAME} -lzakuro_ios -lgame, in that order)"
printf '%s\n' "$LIB_DIR"