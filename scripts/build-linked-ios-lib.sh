#!/usr/bin/env bash
# build-linked-ios-lib.sh — build (or adopt) the per-game `linked` libs.
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
# Split/incremental path (2026-11-12 VM run): cargo does not have to rebuild for
# every step. Existing artifacts can be adopted instead:
#
#   scripts/build-linked-ios-lib.sh pokemon-y --reuse
#       # reuse a validated build/ios/<name>/libzakuro_ios.a and build-info.txt,
#       # refresh the metadata (no cargo, no Zakuro checkout).
#   scripts/build-linked-ios-lib.sh pokemon-y --libgame /path/to/librecomp.a
#       # use an already-built arm64 archive as libgame.a (build/game/... not
#       # required); the linked Zakuro library is still built for the title ID.
#
# If build/game/<name>/code/librecomp.a is missing but
# build/ios/<name>/libgame.a already exists, the existing archive is reused with
# a warning (the split build copied it there manually).
#
# Title ID: pass it explicitly or let the script read it from the output of
# scripts/build-recomp-ios.sh (recomp-info.txt or src/main.rs). It is always
# validated as 16 hex digits; a corrupted legacy value such as "0004000000055E00n"
# is repaired with a warning instead of being baked in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AOT_LOG_PREFIX="build-linked-ios-lib"
# shellcheck source=lib/aot-common.sh
source "${SCRIPT_DIR}/lib/aot-common.sh"

ZAKURO_DIR="${ZAKURO_DIR:-${ROOT}/third_party/zakuro}"
IOS_TARGET="aarch64-apple-ios"

TITLE_ARG=""
NAME_ARG=""
LIB_DIR_ARG=""
LIBGAME_ARG=""
ISOLATED_TARGET=0
REUSE=0
VERBOSE=0

EXPECTED_RECOMP_SYMBOLS="$AOT_EXPECTED_RECOMP_SYMBOLS"

NM_DUMP=""
cleanup_nm_dump() {
  [[ -z "${NM_DUMP:-}" ]] || rm -f -- "$NM_DUMP"
}
trap cleanup_nm_dump EXIT

usage() {
  cat <<'EOF'
Build (or adopt) the per-game `linked` libzakuro_ios.a and collect libgame.a.

Usage:
  scripts/build-linked-ios-lib.sh <name> [options]
  scripts/build-linked-ios-lib.sh <title-id> <name> [options]

Arguments:
  <name>             Short game name used by build-recomp-ios.sh
                     (open build/game/<name>/)
  <title-id>         Optional 16 hex digit ROM title ID; when omitted it is
                     read from build/game/<name>/recomp-info.txt or src/main.rs
                     (or pass --title-id)

Options:
  --title-id ID      16 hex digit title ID (e.g. 0004000000055E00); validated
                     and normalised (lower case / 0x prefix accepted)
  --name NAME        Same as the <name> argument
  --reuse            Do not run cargo: reuse the existing, validated
                     build/ios/<name>/libzakuro_ios.a (which must show the 7
                     undefined _recomp_* symbols) and refresh build-info.txt.
                     Useful for split builds and re-runs before packaging.
  --libgame PATH     Use an already-built arm64 iOS archive as libgame.a
                     (instead of build/game/<name>/code/librecomp.a); makes the
                     3dsrecomp output tree optional on this machine.
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
    --reuse)
      REUSE=1
      shift
      ;;
    --libgame)
      [[ $# -ge 2 ]] || die "--libgame requires a value"
      LIBGAME_ARG="$2"
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
aot_is_valid_name "$NAME" \
  || die "invalid game name: '$NAME' (use letters, digits, '.', '_', '-')"

ZAKURO_DIR="$(resolve_path "$ZAKURO_DIR")"
LIB_DIR="$(resolve_path "${LIB_DIR_ARG:-build/ios/${NAME}}")"
GAME_DIR="${ROOT}/build/game/${NAME}"
GAME_ARCHIVE="${GAME_DIR}/code/librecomp.a"
RECOMP_INFO="${GAME_DIR}/recomp-info.txt"
BUILD_INFO="${LIB_DIR}/build-info.txt"
LIB_ZAKURO="${LIB_DIR}/libzakuro_ios.a"
LIB_GAME="${LIB_DIR}/libgame.a"

# --- resolve the title ID ----------------------------------------------------
# Build path order: --title-id, recomp-info.txt, generated src/main.rs, then an
# existing build-info.txt. Reuse path order: --title-id, existing build-info.txt
# (that is the title the library was actually built for), then recomp-info.txt.
resolve_title_id() {
  local cand norm
  if [[ -n "$TITLE_ARG" ]]; then
    if norm="$(aot_normalize_title_id "$TITLE_ARG")"; then
      TITLE_ID="$norm"
      TITLE_ID_SOURCE="--title-id"
      return 0
    fi
    aot_warn "--title-id is not a valid 16 hex digit title ID: '$TITLE_ARG'"
    return 1
  fi
  if [[ "$REUSE" -eq 1 ]]; then
    cand="$(aot_info_value "$BUILD_INFO" title_id || true)"
    if [[ -n "$cand" ]]; then
      if norm="$(aot_normalize_title_id "$cand")"; then
        TITLE_ID="$norm"
        TITLE_ID_SOURCE="build-info.txt"
        return 0
      fi
      aot_warn "invalid title_id='$cand' in $BUILD_INFO (ignored)"
    fi
  fi
  cand="$(aot_info_value "$RECOMP_INFO" title_id || true)"
  if [[ -n "$cand" ]]; then
    if norm="$(aot_normalize_title_id "$cand")"; then
      TITLE_ID="$norm"
      TITLE_ID_SOURCE="recomp-info.txt"
      return 0
    fi
    aot_warn "invalid title_id='$cand' in $RECOMP_INFO (ignored)"
  fi
  if norm="$(aot_title_id_from_rust "${GAME_DIR}/src/main.rs" || true)"; then
    TITLE_ID="$norm"
    TITLE_ID_SOURCE="src/main.rs"
    return 0
  fi
  if [[ "$REUSE" -ne 1 ]]; then
    cand="$(aot_info_value "$BUILD_INFO" title_id || true)"
    if [[ -n "$cand" ]]; then
      if norm="$(aot_normalize_title_id "$cand")"; then
        TITLE_ID="$norm"
        TITLE_ID_SOURCE="build-info.txt (previous run)"
        return 0
      fi
    fi
  fi
  return 1
}

if ! resolve_title_id; then
  die "could not determine a valid 16 hex digit title ID (got nothing usable).
       Run scripts/build-recomp-ios.sh first (it extracts the title ID from the
       generated src/main.rs), or pass --title-id 0004000000055E00."
fi

# Cross-check the title against the other metadata sources so a stale
# build-info.txt or recomp-info.txt cannot silently mismatch the linked library.
if [[ "$REUSE" -ne 1 ]]; then
  OTHER_TITLE="$(aot_info_value "$BUILD_INFO" title_id || true)"
  if [[ -n "$OTHER_TITLE" ]]; then
    OTHER_TITLE="$(aot_normalize_title_id "$OTHER_TITLE" 2>/dev/null || true)"
    if [[ -n "$OTHER_TITLE" && "$OTHER_TITLE" != "$TITLE_ID" ]]; then
      warn "existing $BUILD_INFO is for title $OTHER_TITLE but this build resolves
       $TITLE_ID ($TITLE_ID_SOURCE); the old library will be replaced."
    fi
  fi
fi

# --- host / tool checks ------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  die "this script must run on macOS with Xcode + Rust installed.
       Detected $(uname -s); run it on the macOS VM (iOS static libs need the iOS SDK)."
fi

need_tool xcrun "Install Xcode and select it: sudo xcode-select -s \"\$HOME/Applications/Xcode-16.4.0.app\""
need_tool git "Install the Xcode command line tools: xcode-select --install"
need_tool nm "Install the Xcode command line tools: xcode-select --install"
if [[ "$REUSE" -ne 1 ]]; then
  need_tool cargo "Install Rust (https://rustup.rs) and the aarch64-apple-ios target"
fi

LOG_DIR="${ROOT}/build/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-linked-ios-lib-${NAME}-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE"

log "repo root:  $ROOT"
log "game name:  $NAME"
log "title id:   $TITLE_ID (source: $TITLE_ID_SOURCE)"
log "lib dir:    $LIB_DIR"
log "mode:       $([[ "$REUSE" -eq 1 ]] && echo reuse || echo cargo-build)"
log "build log:  $LOG_FILE"

# --- validation (RECOMP.md §2.1/§8.2) ----------------------------------------
validate_linked_lib() {
  local file="$1" undefined count missing symbol lines
  [[ -s "$file" ]] || die "linked library is missing or empty: $file"
  aot_lipo_arch_ok "$file" \
    || die "linked library is not arm64: $file (lipo: $AOT_LIPO_INFO)"

  NM_DUMP="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-nm.XXXXXX")"
  aot_nm_dump "$file" "$NM_DUMP" -u \
    || die "nm -u failed on $file (RECOMP.md §8.2)"
  undefined="$(aot_nm_symbols_with_prefix "$NM_DUMP" '_recomp_')"
  rm -f -- "$NM_DUMP"
  NM_DUMP=""
  if [[ -z "$undefined" ]]; then
    die "linked library has no undefined _recomp_* symbols: $file
       That looks like the interpreter-only shell library. Did the build use
       --features linked and get copied from the right target dir?"
  fi
  count="$(printf '%s\n' "$undefined" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  lines=$'\n'"$undefined"$'\n'
  missing=""
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    case "$lines" in
      *$'\n'"_${symbol}"$'\n'*) : ;;
      *) missing="$missing _${symbol}" ;;
    esac
  done
  [[ -z "$missing" ]] || die "linked library is missing expected undefined symbols:$missing
       (RECOMP.md §8.2 expects exactly 7: $EXPECTED_RECOMP_SYMBOLS)"
  [[ "$count" -eq 7 ]] || die "linked library has ${count} undefined _recomp_* symbols; expected exactly 7.
       Found: $(printf '%s\n' "$undefined" | tr '\n' ' ')"
}

validate_game_archive() {
  local file="$1" missing="" symbol
  [[ -s "$file" ]] || die "libgame archive is missing or empty: $file"
  aot_lipo_arch_ok "$file" \
    || die "libgame archive is not arm64: $file (lipo: $AOT_LIPO_INFO)"
  NM_DUMP="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-nm.XXXXXX")"
  aot_nm_dump "$file" "$NM_DUMP" -g \
    || die "nm -g failed on $file"
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    aot_nm_has_symbol "$NM_DUMP" "_${symbol}" || missing="$missing _${symbol}"
  done
  rm -f -- "$NM_DUMP"
  NM_DUMP=""
  [[ -z "$missing" ]] || die "libgame archive does not export generated tables:$missing
       Check that build-recomp-ios.sh produced an iOS arm64 archive with 3dsrecomp
       port, or pass --libgame <path/to/librecomp.a>."
}

write_build_info() {
  aot_validate_title_id "$TITLE_ID" \
    || die "refusing to write build-info.txt: title ID '$TITLE_ID' is not 16 hex digits."
  {
    printf 'name=%s\n' "$NAME"
    printf 'title_id=%s\n' "$TITLE_ID"
    printf 'title_id_source=%s\n' "${TITLE_ID_SOURCE:-unknown}"
    printf 'zakuro_rev=%s\n' "$ZAKURO_REV"
    printf 'recomp_rev=%s\n' "${RECOMP_REV:-unknown}"
    printf 'rom_basename=%s\n' "${ROM_BASENAME:-unknown}"
    printf 'libzakuro_ios=%s\n' "$LIB_ZAKURO"
    printf 'libzakuro_ios_bytes=%s\n' "$(wc -c < "$LIB_ZAKURO" | tr -d '[:space:]')"
    printf 'libzakuro_ios_sha256=%s\n' "$(aot_sha256 "$LIB_ZAKURO")"
    printf 'libgame=%s\n' "$LIB_GAME"
    printf 'libgame_source=%s\n' "${LIBGAME_SOURCE:-$GAME_ARCHIVE}"
    printf 'libgame_bytes=%s\n' "$(wc -c < "$LIB_GAME" | tr -d '[:space:]')"
    printf 'libgame_sha256=%s\n' "$(aot_sha256 "$LIB_GAME")"
    printf 'cargo_target_dir=%s\n' "${TARGET_ROOT:-reused}"
    printf 'isolated_target=%s\n' "$ISOLATED_TARGET"
    printf 'reuse=%s\n' "$REUSE"
    printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$BUILD_INFO"
}

# --- choose libgame.a source ------------------------------------------------
GAME_SRC=""
if [[ -n "$LIBGAME_ARG" ]]; then
  GAME_SRC="$(resolve_path "$LIBGAME_ARG")"
  [[ -f "$GAME_SRC" ]] || die "--libgame file not found: $GAME_SRC"
  LIBGAME_SOURCE="$GAME_SRC (--libgame)"
elif [[ -f "$GAME_ARCHIVE" ]]; then
  GAME_SRC="$GAME_ARCHIVE"
  LIBGAME_SOURCE="$GAME_ARCHIVE"
elif [[ -f "$LIB_GAME" ]]; then
  GAME_SRC="$LIB_GAME"
  LIBGAME_SOURCE="$LIB_GAME (existing split-build archive)"
  warn "missing $GAME_ARCHIVE; reusing the existing $LIB_GAME
       (split-build path: the archive was placed there manually)."
else
  die "missing recompiled archive: $GAME_ARCHIVE
       Run scripts/build-recomp-ios.sh <rom> $NAME first, pass
       --libgame <path/to/librecomp.a>, or copy the split-build libgame.a into
       $LIB_DIR."
fi

# --- reuse path: no cargo, just validate + refresh metadata -----------------
if [[ "$REUSE" -eq 1 ]]; then
  [[ -f "$LIB_ZAKURO" ]] || die "--reuse needs an existing linked library: $LIB_ZAKURO
       Run without --reuse (cargo build) first, or copy the split-build
       libzakuro_ios.a into $LIB_DIR."
  log "reusing linked library: $LIB_ZAKURO"
  validate_linked_lib "$LIB_ZAKURO"
  validate_game_archive "$GAME_SRC"
  mkdir -p "$LIB_DIR"
  if [[ "$(cd "$(dirname "$GAME_SRC")" && pwd)/$(basename "$GAME_SRC")" \
        != "$(cd "$LIB_DIR" && pwd)/libgame.a" ]]; then
    cp -f "$GAME_SRC" "$LIB_GAME"
  fi
  ZAKURO_REV="$(aot_info_value "$BUILD_INFO" zakuro_rev || true)"
  [[ -n "$ZAKURO_REV" ]] || ZAKURO_REV="unknown"
  RECOMP_REV="$(aot_info_value "$RECOMP_INFO" recomp_rev || true)"
  ROM_BASENAME="$(aot_info_value "$RECOMP_INFO" rom_basename || true)"
  write_build_info
  log "per-game linked libs ready (reused, no cargo build)"
  log "  libzakuro_ios.a: $LIB_ZAKURO"
  log "  libgame.a:       $LIB_GAME"
  log "  build info:      $BUILD_INFO"
  log "next: scripts/build-game-ipa.sh ${NAME}"
  printf '%s\n' "$LIB_DIR"
  exit 0
fi

# --- build prerequisites (only needed for the cargo build path) -------------
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

[[ -d "$ZAKURO_DIR" || ! -e "$ZAKURO_DIR" ]] || die "Zakuro path is not a directory: $ZAKURO_DIR"
validate_game_archive "$GAME_SRC"

ensure_zakuro_checkout

if ! command -v rustup >/dev/null 2>&1; then
  warn "rustup not found; assuming the aarch64-apple-ios target is installed"
else
  # Capture the list first, then match it in the shell. Piping rustup into
  # `grep -qx` can give rustup SIGPIPE (141) under `set -o pipefail` - the same
  # bug class as `nm | grep -q` (see scripts/lib/aot-common.sh) - which would
  # look like "target missing" and re-run `rustup target add` every build.
  INSTALLED_TARGETS="$(rustup target list --installed 2>/dev/null || true)"
  case $'\n'"$INSTALLED_TARGETS"$'\n' in
    *$'\n'"$IOS_TARGET"$'\n'*) : ;;
    *)
      log "adding Rust target: $IOS_TARGET"
      rustup target add "$IOS_TARGET"
      ;;
  esac
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

# --- validate + collect per-game libs --------------------------------------
validate_linked_lib "$LIB_BUILT"

mkdir -p "$LIB_DIR"
cp -f "$LIB_BUILT" "$LIB_ZAKURO"
if [[ "$(cd "$(dirname "$GAME_SRC")" && pwd)/$(basename "$GAME_SRC")" \
      != "$(cd "$LIB_DIR" && pwd)/libgame.a" ]]; then
  cp -f "$GAME_SRC" "$LIB_GAME"
fi

ZAKURO_REV="unknown"
if [[ -d "${ZAKURO_DIR}/.git" ]]; then
  ZAKURO_REV="$(git -C "$ZAKURO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
RECOMP_REV="$(aot_info_value "$RECOMP_INFO" recomp_rev || true)"
ROM_BASENAME="$(aot_info_value "$RECOMP_INFO" rom_basename || true)"

write_build_info

log "per-game linked libs ready"
log "  libzakuro_ios.a: $LIB_ZAKURO"
log "  libgame.a:       $LIB_GAME"
log "  build info:      $BUILD_INFO"
log "next: scripts/build-game-ipa.sh ${NAME}"
log "  (the app must link -L build/ios/${NAME} -lzakuro_ios -lgame, in that order)"
printf '%s\n' "$LIB_DIR"