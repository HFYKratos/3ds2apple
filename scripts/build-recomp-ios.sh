#!/usr/bin/env bash
# build-recomp-ios.sh — recompile one user ROM into arm64 iOS AOT C + librecomp.a.
#
# Per-game AOT pipeline (authoritative design: ios/zakuro-ios/RECOMP.md §3/§9):
#
#   # once per Zakuro checkout (clone + patch + baseline lib):
#   scripts/build-zakuro-ios.sh
#
#   # per game (this script): 3dsrecomp port -> build/game/<name>/code/librecomp.a
#   scripts/build-recomp-ios.sh ROM/<your-game>.3ds <name>
#
#   # per game (linked libs):  libzakuro_ios.a + libgame.a in build/ios/<name>/
#   scripts/build-linked-ios-lib.sh <name>
#
#   # per game (AOT IPA):      IPA/<name>-AOT.ipa
#   scripts/build-game-ipa.sh <name>
#
# Must run on macOS with Xcode (iOS SDK clang) and Rust/cargo. The user's ROM
# is read from ROM/ (gitignored) and is never copied into the repository;
# generated C, objects and archives stay under build/ (gitignored).
#
# Version freezing (RECOMP.md §5): the 3dsrecomp CLI is checked out at the
# revision that Zakuro's Cargo.lock pins for the `recomp-abi` crate, so the
# generated C uses the exact ABI the linked Zakuro accepts. If the Zakuro
# checkout is missing, a built-in fallback revision is used and a warning is
# printed; run scripts/build-zakuro-ios.sh first for the authoritative pin.
#
# 8 GB macOS VM: 3dsrecomp compiles the generated C in parallel by CPU count
# with no memory cap (RECOMP.md §3.2). If `port` is killed by the OOM killer,
# re-run with --auto-serial (or --serial-compile) to finish compiling the
# already-generated C serially with the documented flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Built-in fallback: recomp-abi rev pinned by Zakuro's Cargo.lock at the time
# RECOMP.md was written (§8.4: ABI 5 / generation 5). Prefer the Cargo.lock pin.
DEFAULT_RECOMP_REV="df82e6e3"

RECOMP_REPO_URL="https://github.com/fearkov/3dsrecomp"
IOS_TARGET="arm64-apple-ios16.0"

ROM_ARG=""
NAME_ARG=""
TITLE_ARG=""
RECOMP_DIR="${THREEDS_RECOMP_DIR:-${ROOT}/third_party/3dsrecomp}"
RECOMP_REV_ARG="${THREEDS_RECOMP_REV:-}"
RECOMP_BIN_ARG="${THREEDS_RECOMP_BIN:-}"
ZAKURO_DIR="${ZAKURO_DIR:-${ROOT}/third_party/zakuro}"
AUTO_SERIAL=0
SERIAL_COMPILE=0
KEEP_EXISTING=0
VERBOSE=0

usage() {
  cat <<'EOF'
Recompile one user ROM with 3dsrecomp into arm64 iOS AOT code.

Usage:
  scripts/build-recomp-ios.sh <rom> [name] [options]

Arguments:
  <rom>              Decrypted .3ds/.cci ROM path (relative to the repo root;
                     the ROM itself is gitignored and never copied into git)
  [name]             Short game name for build/game/<name>/ (default: derived
                     from the ROM file name, e.g. "Pokemon Y.cci" -> pokemon-y)

Options:
  --name NAME        Same as the [name] argument
  --title-id ID      16 hex digit title ID; normally extracted from the
                     generated src/main.rs (RECOMP.md §3.2)
  --recomp-rev REV   3dsrecomp revision; default: Zakuro Cargo.lock's
                     recomp-abi pin (env: THREEDS_RECOMP_REV)
  --recomp-dir DIR   3dsrecomp checkout (default: third_party/3dsrecomp;
                     env: THREEDS_RECOMP_DIR)
  --recomp-bin PATH  Reuse an already-built 3dsrecomp binary; skips
                     clone/build (env: THREEDS_RECOMP_BIN)
  --auto-serial      If `port` fails, retry compiling the generated C serially
                     (use on the 8 GB macOS VM; RECOMP.md §3.2)
  --serial-compile   Skip `port` and only compile the existing generated C in
                     build/game/<name>/code/ serially (recovery path)
  --keep-existing    Do not delete an existing build/game/<name>/ first
  --verbose          Stream 3dsrecomp/cargo output to the terminal as well
  -h, --help         Show this help and exit

Outputs (all gitignored):
  build/game/<name>/code/librecomp.a    arm64 iOS archive of the recompiled C
  build/game/<name>/src/main.rs         desktop project written by `port`
                                        (only its title ID is used on iOS)
  build/game/<name>/recomp-info.txt     rev / title ID / archive SHA256 summary
  build/logs/build-recomp-ios-<name>-*.log

Exit status: 0 on success, non-zero on failure (the log tail is printed).
EOF
}

log() {
  printf '[build-recomp-ios] %s\n' "$*"
}

warn() {
  printf '[build-recomp-ios] warning: %s\n' "$*" >&2
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
    --recomp-rev)
      [[ $# -ge 2 ]] || die "--recomp-rev requires a value"
      RECOMP_REV_ARG="$2"
      shift 2
      ;;
    --recomp-dir)
      [[ $# -ge 2 ]] || die "--recomp-dir requires a value"
      RECOMP_DIR="$2"
      shift 2
      ;;
    --recomp-bin)
      [[ $# -ge 2 ]] || die "--recomp-bin requires a value"
      RECOMP_BIN_ARG="$2"
      shift 2
      ;;
    --auto-serial)
      AUTO_SERIAL=1
      shift
      ;;
    --serial-compile)
      SERIAL_COMPILE=1
      shift
      ;;
    --keep-existing)
      KEEP_EXISTING=1
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
      if [[ -z "$ROM_ARG" ]]; then
        ROM_ARG="$1"
      elif [[ -z "$NAME_ARG" ]]; then
        NAME_ARG="$1"
      else
        die "unexpected argument: $1 (try --help)"
      fi
      shift
      ;;
  esac
done

[[ -n "$ROM_ARG" ]] || die "missing <rom> argument
usage: scripts/build-recomp-ios.sh <rom> [name] [options]"

# --- host / tool checks ------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  die "this script must run on macOS with Xcode (iOS SDK clang) installed.
       Detected $(uname -s); run it on the macOS VM."
fi

need_tool xcrun "Install Xcode and run: sudo xcode-select -s \"\$HOME/Applications/Xcode-16.4.0.app\""
need_tool git "Install the Xcode command line tools: xcode-select --install"
need_tool cargo "Install Rust (https://rustup.rs) and the aarch64-apple-ios target"
need_tool ar "Install the Xcode command line tools: xcode-select --install"
need_tool nm "Install the Xcode command line tools: xcode-select --install"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)" \
  || die "cannot locate the iOS SDK (xcrun --sdk iphoneos --show-sdk-path failed).
       Install the iOS platform in Xcode 16.4, then retry."
CC_BIN="$(xcrun --sdk iphoneos -f clang 2>/dev/null)" \
  || die "cannot locate the iOS SDK clang (xcrun --sdk iphoneos -f clang failed)."
case "$SDK_PATH" in
  *" "*)
    die "the iOS SDK path contains spaces, which 3dsrecomp's CC handling cannot
       represent: '$SDK_PATH'. Move Xcode to a path without spaces."
    ;;
esac
[[ -n "$SDK_PATH" && -d "$SDK_PATH" ]] || die "iOS SDK path is not a directory: $SDK_PATH"
[[ -n "$CC_BIN" && -x "$CC_BIN" ]] || die "iOS SDK clang is not executable: $CC_BIN"

# --- resolve ROM and name ----------------------------------------------------
ROM_ABS="$(resolve_path "$ROM_ARG")"
[[ -f "$ROM_ABS" ]] || die "ROM not found: $ROM_ABS (the ROM is gitignored; keep it under ROM/)"
[[ -r "$ROM_ABS" ]] || die "ROM is not readable: $ROM_ABS"
ROM_BYTES="$(wc -c < "$ROM_ABS" | tr -d '[:space:]')"
[[ "$ROM_BYTES" -gt 0 ]] || die "ROM is empty: $ROM_ABS"

case "$ROM_ABS" in
  *.cia)
    warn "input ends in .cia: 3dsrecomp rejects update CIAs and iOS FFI does not
       load update/DLC yet (RECOMP.md §6). Use the base-game .3ds/.cci ROM."
    ;;
esac

if [[ -z "$NAME_ARG" ]]; then
  NAME_ARG="$(printf '%s\n' "$(basename "$ROM_ABS")" \
    | sed -e 's/\.3ds$//' -e 's/\.cci$//' -e 's/\.cia$//' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9._-' '-' \
    | sed -e 's/^-*//' -e 's/-*$//')"
fi
NAME="$NAME_ARG"
[[ -n "$NAME" ]] || die "could not derive a game name; pass one explicitly"
case "$NAME" in
  .|..|*/*|.*) die "invalid game name: '$NAME' (use letters, digits, '.', '_', '-')" ;;
esac
if ! printf '%s\n' "$NAME" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  die "invalid game name: '$NAME' (use letters, digits, '.', '_', '-')"
fi

OUT_DIR="${ROOT}/build/game/${NAME}"
CODE_DIR="${OUT_DIR}/code"
ARCHIVE="${CODE_DIR}/librecomp.a"
INFO_FILE="${OUT_DIR}/recomp-info.txt"
LOG_DIR="${ROOT}/build/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/build-recomp-ios-${NAME}-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG_FILE"

log "repo root:  $ROOT"
log "rom:        $ROM_ABS (${ROM_BYTES} bytes)"
log "game name:  $NAME"
log "output:     $OUT_DIR"
log "ios target: $IOS_TARGET"
log "ios sdk:    $SDK_PATH"
log "build log:  $LOG_FILE"

# --- title ID helpers --------------------------------------------------------
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

extract_title_id() {
  local main_rs="${OUT_DIR}/src/main.rs"
  local raw
  [[ -f "$main_rs" ]] || return 1
  raw="$(grep -oE '0x[0-9A-Fa-f]{16}' "$main_rs" | head -n 1 || true)"
  [[ -n "$raw" ]] || return 1
  normalize_title_id "$raw"
}

# --- archive validation (RECOMP.md §3.2/§8.2) --------------------------------
EXPECTED_RECOMP_SYMBOLS="recomp_abi recomp_generation recomp_entry_count recomp_entries recomp_module_count recomp_modules recomp_origins"

archive_has_symbol() {
  local archive="$1" symbol="$2"
  nm -g "$archive" 2>/dev/null | grep -q "[[:space:]]_${symbol}\$"
}

validate_archive() {
  local archive="$1"
  [[ -f "$archive" ]] || die "generated archive is missing: $archive"
  [[ -s "$archive" ]] || die "generated archive is empty: $archive"

  local lipo_info
  lipo_info="$(xcrun lipo -info "$archive" 2>&1)" \
    || die "xcrun lipo failed on $archive: $lipo_info"
  case "$lipo_info" in
    *arm64*) ;;
    *) die "archive is not an arm64 iOS archive (expected arm64):
       $lipo_info
       Check CC='$(xcrun --sdk iphoneos -f clang) -target $IOS_TARGET -isysroot <sdk>'." ;;
  esac

  local missing=""
  local symbol
  for symbol in $EXPECTED_RECOMP_SYMBOLS; do
    if ! archive_has_symbol "$archive" "$symbol"; then
      missing="$missing $symbol"
    fi
  done
  [[ -z "$missing" ]] || die "archive is missing 3dsrecomp table symbols:$missing
       The C was probably not compiled by 3dsrecomp's port step. See RECOMP.md §3.2."
}

# --- serial compile fallback (RECOMP.md §3.2) --------------------------------
serial_compile() {
  local c_files
  local file
  shopt -s nullglob
  c_files=("${CODE_DIR}"/*.c)
  shopt -u nullglob
  [[ "${#c_files[@]}" -gt 0 ]] \
    || die "no generated C files in ${CODE_DIR}; run without --serial-compile first.
       (--serial-compile only recompiles C that 3dsrecomp already generated.)"

  log "serial compile: ${#c_files[@]} C files with $(basename "$CC_BIN") (this is slow)"
  local index=0 total="${#c_files[@]}"
  for file in "${c_files[@]}"; do
    local base
    base="$(basename "$file")"
    index=$((index + 1))
    if (( index % 20 == 0 || index == total )); then
      log "  serial compile: ${index}/${total} (${base})"
    fi
    if ! ( cd "$CODE_DIR" && "$CC_BIN" \
        -target "$IOS_TARGET" -isysroot "$SDK_PATH" \
        -O2 -ffp-contract=off -fno-math-errno -w \
        -fPIC -fvisibility=hidden -I. \
        -c "$base" -o "${base%.c}.o" ) >>"$LOG_FILE" 2>&1; then
      printf '\n--- serial compile failed: last 40 lines of %s ---\n' "$LOG_FILE" >&2
      tail -n 40 "$LOG_FILE" >&2
      die "serial compile failed for $base; full log: $LOG_FILE"
    fi
  done

  log "serial compile: archiving ${#c_files[@]} objects -> $(basename "$ARCHIVE")"
  if ! ( cd "$CODE_DIR" && rm -f librecomp.a && ar rcs librecomp.a ./*.o ) >>"$LOG_FILE" 2>&1; then
    printf '\n--- ar failed: last 40 lines of %s ---\n' "$LOG_FILE" >&2
    tail -n 40 "$LOG_FILE" >&2
    die "ar failed while creating $ARCHIVE"
  fi
  COMPILE_MODE="serial"
}

# --- run_stage helper --------------------------------------------------------
COMPILE_MODE="port"
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

# --- resolve the 3dsrecomp revision (RECOMP.md §5) ---------------------------
resolve_recomp_rev() {
  if [[ -n "$RECOMP_REV_ARG" ]]; then
    printf '%s\n' "$RECOMP_REV_ARG"
    return 0
  fi

  local lock="${ZAKURO_DIR}/Cargo.lock"
  if [[ -f "$lock" ]]; then
    local source_line rev
    source_line="$(grep -A4 '^name = "recomp-abi"$' "$lock" 2>/dev/null \
      | grep 'fearkov/3dsrecomp' | head -n 1 || true)"
    if [[ -n "$source_line" ]]; then
      rev="$(printf '%s\n' "$source_line" | sed -nE 's/.*#([0-9a-fA-F]{7,40})".*/\1/p' | head -n 1)"
      if [[ -n "$rev" ]]; then
        printf '%s\n' "$rev"
        return 0
      fi
    fi
  fi

  warn "Zakuro Cargo.lock pin not found (${lock}); using built-in fallback
       revision ${DEFAULT_RECOMP_REV}. Run scripts/build-zakuro-ios.sh first
       so the recomp-abi pin is authoritative (RECOMP.md §5)."
  printf '%s\n' "$DEFAULT_RECOMP_REV"
}

# --- build / reuse the 3dsrecomp CLI ----------------------------------------
RECOMP_REV_USED="prebuilt"
RECOMP_SOURCE="prebuilt (--recomp-bin)"

build_recomp_cli() {
  ( cd "$RECOMP_DIR" && cargo build --release )
}

if [[ -n "$RECOMP_BIN_ARG" ]]; then
  RECOMP_BIN="$(resolve_path "$RECOMP_BIN_ARG")"
  [[ -x "$RECOMP_BIN" ]] || die "--recomp-bin is not executable: $RECOMP_BIN"
  log "using prebuilt 3dsrecomp: $RECOMP_BIN"
else
  RECOMP_DIR="$(resolve_path "$RECOMP_DIR")"
  RECOMP_SOURCE="$RECOMP_DIR"
  RECOMP_REV_USED="$(resolve_recomp_rev)"
  case "$RECOMP_REV_USED" in
    *[!0-9a-fA-F]*) die "invalid 3dsrecomp revision: '$RECOMP_REV_USED' (expected a git rev)" ;;
  esac
  log "3dsrecomp: $RECOMP_DIR"
  log "3dsrecomp rev: $RECOMP_REV_USED"

  if [[ ! -d "$RECOMP_DIR/.git" ]]; then
    if [[ -e "$RECOMP_DIR" ]]; then
      die "$RECOMP_DIR exists but is not a git checkout.
       Remove it (it is gitignored build state) or pass --recomp-dir/--recomp-bin."
    fi
    mkdir -p "$(dirname "$RECOMP_DIR")"
    log "cloning $RECOMP_REPO_URL (one-time) ..."
    git clone "$RECOMP_REPO_URL" "$RECOMP_DIR"
  fi

  if ! git -C "$RECOMP_DIR" rev-parse --verify -q "${RECOMP_REV_USED}^{commit}" >/dev/null 2>&1; then
    log "fetching 3dsrecomp rev $RECOMP_REV_USED ..."
    git -C "$RECOMP_DIR" fetch --tags --quiet origin || warn "git fetch --tags failed"
    git -C "$RECOMP_DIR" fetch --quiet origin "$RECOMP_REV_USED" 2>/dev/null \
      || warn "git fetch origin $RECOMP_REV_USED failed (will rely on existing objects)"
  fi
  git -C "$RECOMP_DIR" rev-parse --verify -q "${RECOMP_REV_USED}^{commit}" >/dev/null 2>&1 \
    || die "3dsrecomp revision '$RECOMP_REV_USED' is not available in $RECOMP_DIR.
       Check network access or pass --recomp-rev <rev>."
  log "checking out 3dsrecomp @ $RECOMP_REV_USED ..."
  git -C "$RECOMP_DIR" checkout --quiet --detach "$RECOMP_REV_USED"

  log "building the 3dsrecomp CLI (cargo build --release) ..."
  run_stage "cargo build (3dsrecomp)" build_recomp_cli
  RECOMP_BIN="${RECOMP_DIR}/target/release/3dsrecomp"
  [[ -x "$RECOMP_BIN" ]] || die "3dsrecomp CLI was not produced at $RECOMP_BIN"
fi

# --- run port with the iOS clang (RECOMP.md §3.2) ----------------------------
CC_STRING="${CC_BIN} -target ${IOS_TARGET} -isysroot ${SDK_PATH}"
log "CC: ${CC_STRING}"
log "AR: ar"

if [[ "$SERIAL_COMPILE" -eq 1 ]]; then
  [[ -d "$CODE_DIR" ]] || die "--serial-compile needs generated C in $CODE_DIR.
       Run this script once without --serial-compile first."
  serial_compile
else
  if [[ -d "$OUT_DIR" && "$KEEP_EXISTING" -ne 1 ]]; then
    log "removing previous output: $OUT_DIR"
    rm -rf -- "$OUT_DIR"
  fi
  mkdir -p "$OUT_DIR"

  log "running: 3dsrecomp port (generation + parallel iOS clang compile)"
  log "  this can take a long time for large games; follow: tail -f \"$LOG_FILE\""
  port_status=0
  ( cd "$ROOT" && CC="$CC_STRING" AR=ar "$RECOMP_BIN" port "$ROM_ABS" "$OUT_DIR" --name "$NAME" ) \
    >>"$LOG_FILE" 2>&1 || port_status=$?
  if [[ "$port_status" -ne 0 ]]; then
    if [[ "$AUTO_SERIAL" -eq 1 ]] && compgen -G "${CODE_DIR}/*.c" >/dev/null; then
      warn "3dsrecomp port failed (status ${port_status}); --auto-serial: compiling the
       generated C serially instead (8 GB VM memory fallback, RECOMP.md §3.2)."
      serial_compile
    else
      printf '\n--- 3dsrecomp port failed: last 100 lines of %s ---\n' "$LOG_FILE" >&2
      tail -n 100 "$LOG_FILE" >&2
      die "3dsrecomp port failed (status ${port_status}); full log: $LOG_FILE
       On a low-memory macOS VM retry with --auto-serial (or --serial-compile)."
    fi
  fi
fi

# --- validate + extract title ID --------------------------------------------
validate_archive "$ARCHIVE"

TITLE_ID=""
if [[ -n "$TITLE_ARG" ]]; then
  TITLE_ID="$(normalize_title_id "$TITLE_ARG")"
else
  TITLE_ID="$(extract_title_id || true)"
fi
validate_title_id "$TITLE_ID" || die "could not determine a valid 16 hex digit title ID
       (got '$TITLE_ID'). The generated src/main.rs should contain a 0x<16 hex>
       literal (RECOMP.md §3.2); if it is missing, pass --title-id explicitly."
TITLE_ID="$(normalize_title_id "$TITLE_ID")"

ARCHIVE_SHA="$(sha256_of "$ARCHIVE")"
ARCHIVE_BYTES="$(wc -c < "$ARCHIVE" | tr -d '[:space:]')"

{
  printf 'name=%s\n' "$NAME"
  printf 'title_id=%s\n' "$TITLE_ID"
  printf 'recomp_rev=%s\n' "$RECOMP_REV_USED"
  printf 'recomp_dir=%s\n' "$RECOMP_SOURCE"
  printf 'compile_mode=%s\n' "$COMPILE_MODE"
  printf 'ios_target=%s\n' "$IOS_TARGET"
  printf 'sdk=%s\n' "$SDK_PATH"
  printf 'archive=%s\n' "$ARCHIVE"
  printf 'archive_bytes=%s\n' "$ARCHIVE_BYTES"
  printf 'archive_sha256=%s\n' "$ARCHIVE_SHA"
  printf 'rom_basename=%s\n' "$(basename "$ROM_ABS")"
  printf 'rom_bytes=%s\n' "$ROM_BYTES"
  printf 'rom_sha256=%s\n' "$(sha256_of "$ROM_ABS")"
  printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$INFO_FILE"

log "recompiled code ready"
log "  archive:  $ARCHIVE (${ARCHIVE_BYTES} bytes)"
log "  sha256:   $ARCHIVE_SHA"
log "  title id: $TITLE_ID"
log "  info:     $INFO_FILE"
log "next: scripts/build-linked-ios-lib.sh ${TITLE_ID} ${NAME}"
log "      (or simply: scripts/build-linked-ios-lib.sh ${NAME})"
printf '%s\n' "$ARCHIVE"