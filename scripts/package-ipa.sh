#!/usr/bin/env bash
# package-ipa.sh — wrap an unsigned .app built on macOS into an unsigned .ipa.
#
# The layout is the standard sideloading one:
#   Payload/<App>.app
#   <name>.ipa  (zip archive, no signature)
#
# Signing/installing happens later on Windows with Sideloadly / AltStore; this
# script never touches Apple IDs, certificates or device UDIDs, and it never
# runs `git add`. Output defaults to IPA/, which is gitignored.
#
# Usage:
#   scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app
#   scripts/package-ipa.sh <path/to/App.app> 3ds2apple-I1
#   scripts/package-ipa.sh <path/to/App.app> --name 3ds2apple-I1 --out-dir IPA
#
# Relative paths are resolved from the repository root. Re-running overwrites
# the target .ipa.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_ARG=""
NAME_ARG=""
OUT_DIR="IPA"

usage() {
  cat <<'EOF'
Package an unsigned .app bundle into an unsigned .ipa (Payload/<App>.app).

Usage:
  scripts/package-ipa.sh <path/to/App.app> [name] [options]

Arguments:
  <path/to/App.app>  App bundle produced by scripts/build-ios-app.sh
  [name]             Output file name without .ipa (default: bundle name,
                     e.g. 3ds2apple.app -> 3ds2apple.ipa)

Options:
  --name NAME        Output file name (alternative to the second argument)
  --out-dir DIR      Output directory (default: IPA/, gitignored)
  -h, --help         Show this help and exit

Output:
  <out-dir>/<name>.ipa   unsigned IPA; absolute path, SHA256 and size are printed

The script refuses to write onto a path tracked by git and never commits
anything. Sign the IPA on Windows with Sideloadly/AltStore.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[package-ipa] %s\n' "$*"
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "${ROOT}/$1" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      NAME_ARG="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1 (try --help)"
      ;;
    *)
      if [[ -z "$APP_ARG" ]]; then
        APP_ARG="$1"
      elif [[ -z "$NAME_ARG" ]]; then
        NAME_ARG="$1"
      else
        die "unexpected argument: $1 (try --help)"
      fi
      shift
      ;;
  esac
done

# --- validate the input bundle ----------------------------------------------
[[ -n "$APP_ARG" ]] || die "missing .app path
usage: scripts/package-ipa.sh <path/to/App.app> [name] [--out-dir DIR]"
[[ -n "$OUT_DIR" ]] || die "--out-dir must not be empty"

APP_PATH="$(resolve_path "$APP_ARG")"
while [[ "$APP_PATH" == */ && "$APP_PATH" != "/" ]]; do
  APP_PATH="${APP_PATH%/}"
done

[[ -e "$APP_PATH" ]] || die "app bundle not found: $APP_PATH"
[[ -d "$APP_PATH" ]] || die "not a directory: $APP_PATH (expected a .app bundle)"
case "$APP_PATH" in
  *.app) ;;
  *) die "not an .app bundle: $APP_PATH" ;;
esac
[[ -f "$APP_PATH/Info.plist" ]] \
  || die "missing Info.plist in $APP_PATH (not a valid .app bundle)"

if [[ -z "$NAME_ARG" ]]; then
  NAME_ARG="$(basename "$APP_PATH" .app)"
fi
NAME="${NAME_ARG%.ipa}"
[[ -n "$NAME" ]] || die "empty output name"
case "$NAME" in
  */*) die "output name must be a file name, not a path: $NAME" ;;
  .*) die "output name must not start with a dot: $NAME" ;;
esac

command -v zip >/dev/null 2>&1 || die "zip not found in PATH"
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  die "need shasum (macOS) or sha256sum (Linux) to compute the IPA checksum"
fi

OUT_DIR_ABS="$(resolve_path "$OUT_DIR")"
mkdir -p "$OUT_DIR_ABS"
OUT_DIR_ABS="$(cd "$OUT_DIR_ABS" && pwd)"
OUT_IPA="$OUT_DIR_ABS/$NAME.ipa"

# --- never overwrite something git tracks -----------------------------------
if command -v git >/dev/null 2>&1 && [[ -e "$ROOT/.git" ]]; then
  if git -C "$ROOT" ls-files --error-unmatch -- "$OUT_IPA" >/dev/null 2>&1; then
    die "refusing to write $OUT_IPA: it is tracked by git.
     IPA/build artifacts must never be committed; choose another --out-dir."
  fi
fi

if [[ -e "$OUT_IPA" ]]; then
  log "replacing existing $OUT_IPA"
fi

# --- stage Payload/ and zip --------------------------------------------------
STAGE=""
cleanup() {
  if [[ -n "${STAGE:-}" && -d "$STAGE" ]]; then
    rm -rf -- "$STAGE"
  fi
}
trap cleanup EXIT

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/3ds2apple-ipa.XXXXXX")"
mkdir -p "$STAGE/Payload"

APP_BASENAME="$(basename "$APP_PATH")"
log "staging $APP_BASENAME in Payload/"
cp -R "$APP_PATH" "$STAGE/Payload/"
[[ -d "$STAGE/Payload/$APP_BASENAME" ]] || die "failed to stage the app bundle"

# Optional embedded framework (used by the Metal/MoltenVK hardware-rendering
# build: the runtime dlopen()s MoltenVK from Frameworks/). Local only.
if [[ -n "${MOLTENVK_FRAMEWORK:-}" ]]; then
  [[ -d "$MOLTENVK_FRAMEWORK" ]] || die "MOLTENVK_FRAMEWORK is not a directory: $MOLTENVK_FRAMEWORK"
  mkdir -p "$STAGE/Payload/$APP_BASENAME/Frameworks"
  rm -rf "$STAGE/Payload/$APP_BASENAME/Frameworks/MoltenVK.framework"
  cp -R "$MOLTENVK_FRAMEWORK" "$STAGE/Payload/$APP_BASENAME/Frameworks/MoltenVK.framework"
  log "embedded MoltenVK.framework"
fi

# ROM transfer: expose Documents/ to Finder/iTunes and the Files app. The
# generated Info.plist does not reliably carry these keys from XcodeGen, so
# inject them into the staged bundle before zipping.
APP_PLIST="$STAGE/Payload/$APP_BASENAME/Info.plist"
if [[ -x /usr/libexec/PlistBuddy ]]; then
  /usr/libexec/PlistBuddy -c 'Delete :UIFileSharingEnabled' "$APP_PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Add :UIFileSharingEnabled bool true' "$APP_PLIST" >/dev/null
  /usr/libexec/PlistBuddy -c 'Delete :LSSupportsOpeningDocumentsInPlace' "$APP_PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Add :LSSupportsOpeningDocumentsInPlace bool true' "$APP_PLIST" >/dev/null
  # System Metal Performance HUD (FPS / GPU time / memory). Works for
  # development/self-built apps; useful while the Metal renderer is brought up.
  /usr/libexec/PlistBuddy -c 'Delete :MetalHudEnabled' "$APP_PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Add :MetalHudEnabled bool true' "$APP_PLIST" >/dev/null
else
  printf '[package-ipa] warning: PlistBuddy not found; document-sharing keys not injected\n' >&2
fi

log "zipping Payload/ -> $NAME.ipa"
( cd "$STAGE" && zip -qry "$STAGE/$NAME.ipa" Payload )
[[ -s "$STAGE/$NAME.ipa" ]] || die "zip produced an empty IPA"

mv -f "$STAGE/$NAME.ipa" "$OUT_IPA"

# --- report ------------------------------------------------------------------
sha256_of() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    sha256sum "$file" | awk '{print $1}'
  fi
}

SHA256="$(sha256_of "$OUT_IPA")"
SIZE="$(du -h "$OUT_IPA" | awk '{print $1}')"

if [[ "$OUT_IPA" == "$ROOT"/* ]] && command -v git >/dev/null 2>&1 && [[ -e "$ROOT/.git" ]]; then
  if git -C "$ROOT" check-ignore -q -- "$OUT_IPA" 2>/dev/null; then
    log "artifact is gitignored: $OUT_IPA"
  else
    printf 'warning: %s is not gitignored; do not `git add` it (IPA artifacts stay local).\n' \
      "$OUT_IPA" >&2
  fi
fi

printf '\n'
log "IPA:    $OUT_IPA"
printf 'SHA256: %s\n' "$SHA256"
printf 'SIZE:   %s\n' "$SIZE"
printf 'NOTE:   unsigned IPA — sign with Sideloadly/AltStore on Windows using your own Apple ID.\n'
printf '%s\n' "$OUT_IPA"