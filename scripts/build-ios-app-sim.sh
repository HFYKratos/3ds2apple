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
# Outputs (all under the gitignored build/):
#   build/sim/shell/out/Release-iphonesimulator/3ds2apple.app
#   build/sim/harness/out/Release-iphonesimulator/3ds2apple-sim-harness.app
#
# This script only builds (and optionally installs); booting/launching the
# Simulator is documented in docs/build-simulator.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/build/ios/libzakuro_ios_sim.a"
OUTDIR="$ROOT/build/sim"
APP="both"
CONFIG="Release"
INSTALL=0
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
  log "harness binary: $(lipo -info "$HARNESS_APP/3ds2apple-sim-harness" 2>/dev/null)"
}

SHELL_APP=""
HARNESS_APP=""
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
