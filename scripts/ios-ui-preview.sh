#!/usr/bin/env bash
# ios-ui-preview.sh - build the shell UI and screenshot it in the iOS Simulator.
#
# Runs on the macOS build VM (from any directory: the repository is resolved
# from this script's location). It builds a second, simulator-only app target
# (ios/preview/project.yml) that compiles the real shell sources and links an
# auto-generated C stub for the zk_* functions instead of the arm64 device
# libzakuro_ios.a, boots a headless simulator, seeds a synthetic game library
# and saves one PNG per screen under ios/preview/build/screenshots.
#
# Nothing outside ios/preview/build/ (gitignored) is written except the
# generated stub ios/preview/generated/ZakuroStub.c (also gitignored). No
# network access and no real ROM data: the seeded games are few-KB placeholders.
#
# Usage:
#   scripts/ios-ui-preview.sh
#   scripts/ios-ui-preview.sh --screens home,settings,quick,ingame,savemanager,about
#   scripts/ios-ui-preview.sh --dark --out-dir /tmp/ui-shots
#   scripts/ios-ui-preview.sh --no-build --keep-simulator
#
# Exit status: 0 when every requested screenshot was written, non-zero on the
# first failure (the failing command's output tail is printed).
#
# On the VM XcodeGen is usually in /usr/local/bin, which the VM's PATH does not
# always include:
#   PATH=/usr/local/bin:$PATH scripts/ios-ui-preview.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUNDLE_ID="com.kratos.3ds2apple.preview"
TARGET_NAME="3ds2apple-preview"
SCHEME="3ds2apple-preview"
PROJECT_SPEC="ios/preview/project.yml"
PROJECT_PATH="$ROOT/ios/preview/build/3ds2apple-preview.xcodeproj"
DERIVED_PATH="$ROOT/ios/preview/build/DerivedData"
APP_PATH="$DERIVED_PATH/Build/Products/Debug-iphonesimulator/$TARGET_NAME.app"
DEFAULT_OUT_DIR="ios/preview/build/screenshots"
OUT_DIR="$DEFAULT_OUT_DIR"
DEFAULT_SCREENS=(home settings quick ingame savemanager)
ALL_SCREENS=(home settings quick ingame savemanager about)
SCREENS=("${DEFAULT_SCREENS[@]}")
KEEP_SIMULATOR=0
NO_BUILD=0
VERBOSE=0
DARK=0
LAUNCH_DELAY=2
DEVICE_TYPE_NAME="iPhone 14 Pro Max"
SIM_UDID=""
CREATED_SIMULATOR=0
BOOTED_SIMULATOR=0
WORK_DIR=""
PNG_FILES=()

log() { printf '[ios-ui-preview] %s\n' "$*"; }
die() { printf '[ios-ui-preview] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Build and screenshot the 3ds2apple shell UI in the iOS Simulator (macOS only).

Usage:
  scripts/ios-ui-preview.sh [options]

Options:
  --screens LIST       Comma-separated screens to capture. Default:
                       home,settings,quick,ingame,savemanager
                       Known: home, settings, quick, ingame, savemanager, about
  --out-dir DIR        Screenshot directory (default: ios/preview/build/screenshots;
                       relative paths are resolved against the repository root)
  --dark               Force dark mode (ZKPREVIEW_DARK=1)
  --udid UDID          Use this simulator instead of picking/creating one
  --device-type NAME   Preferred device type (default: iPhone 14 Pro Max,
                       falling back to the first iPhone device type)
  --launch-delay SECS  Wait after launching before the screenshot (default: 2)
  --no-build           Reuse the existing build in ios/preview/build
  --keep-simulator     Leave the simulator booted (and keep a created one)
  --verbose            Stream xcodebuild output to the terminal as well
  -h, --help           Show this help and exit

Outputs:
  <out-dir>/<screen>.png   one screenshot per requested screen
  ios/preview/build/logs/build-<timestamp>.log   full xcodebuild log
  printed at the end: the absolute path of every screenshot

The script writes only under ios/preview/build/ (gitignored) and
ios/preview/generated/ (gitignored), shuts the simulator down (or deletes a
simulator it created) on exit, and never touches the network or real ROM data.
EOF
}

cleanup() {
  _status=$?
  trap - EXIT INT TERM
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ -n "$SIM_UDID" ]]; then
    if [[ "$KEEP_SIMULATOR" -eq 1 ]]; then
      log "keeping simulator $SIM_UDID (--keep-simulator)"
    elif [[ "$CREATED_SIMULATOR" -eq 1 ]]; then
      xcrun simctl delete "$SIM_UDID" >/dev/null 2>&1 || true
      log "deleted temporary simulator $SIM_UDID"
    elif [[ "$BOOTED_SIMULATOR" -eq 1 ]]; then
      xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
      log "shut down simulator $SIM_UDID"
    fi
  fi
  exit "$_status"
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$2"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --screens)
      [[ $# -ge 2 ]] || die "--screens requires a comma-separated list"
      _raw="$2"
      IFS=',' read -r -a _parsed <<< "$_raw"
      SCREENS=()
      for _screen in "${_parsed[@]}"; do
        _screen="$(printf '%s' "$_screen" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        [[ -n "$_screen" ]] || continue
        SCREENS+=("$_screen")
      done
      [[ ${#SCREENS[@]} -gt 0 ]] || die "--screens did not contain a screen name"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a path"
      OUT_DIR="$2"
      shift 2
      ;;
    --device-type)
      [[ $# -ge 2 ]] || die "--device-type requires a name"
      DEVICE_TYPE_NAME="$2"
      shift 2
      ;;
    --udid)
      [[ $# -ge 2 ]] || die "--udid requires a simulator UDID"
      SIM_UDID="$2"
      shift 2
      ;;
    --launch-delay)
      [[ $# -ge 2 ]] || die "--launch-delay requires a number of seconds"
      LAUNCH_DELAY="$2"
      shift 2
      ;;
    --keep-simulator) KEEP_SIMULATOR=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --dark) DARK=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

for _screen in "${SCREENS[@]}"; do
  _known=0
  for _allowed in "${ALL_SCREENS[@]}"; do
    if [[ "$_screen" == "$_allowed" ]]; then
      _known=1
    fi
  done
  [[ "$_known" -eq 1 ]] || die "unknown screen '$_screen' (known: ${ALL_SCREENS[*]})"
done

case "$LAUNCH_DELAY" in
  ''|*[!0-9]*) die "--launch-delay must be a whole number of seconds" ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || die "this script needs macOS with Xcode and the iOS Simulator (host: $(uname -s))"
need_tool xcrun "xcrun not found; install Xcode and run xcode-select --install"
need_tool xcodebuild "xcodebuild not found; install Xcode and run xcode-select"
need_tool xcodegen "XcodeGen not found; install it (brew install xcodegen). On the VM it is in /usr/local/bin, so try: PATH=/usr/local/bin:$PATH scripts/ios-ui-preview.sh"
need_tool python3 "python3 not found; the zk_* stub generator needs Python 3"
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild is not usable; select Xcode with xcode-select -s /Applications/Xcode.app"

case "$OUT_DIR" in
  /*) : ;;
  *) OUT_DIR="$ROOT/$OUT_DIR" ;;
esac
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/3ds2apple-preview.XXXXXX")"
trap cleanup EXIT INT TERM

# --- stub + project ---------------------------------------------------------
if [[ "$NO_BUILD" -eq 0 ]]; then
  log "generating the zk_* C stub (the simulator cannot link libzakuro_ios.a)"
  python3 "$ROOT/scripts/gen-zakuro-stub.py" --repo-root "$ROOT"

  log "generating the Xcode project (ios/preview/build)"
  mkdir -p "$ROOT/ios/preview/build"
  xcodegen generate \
    --spec "$ROOT/$PROJECT_SPEC" \
    --project "$ROOT/ios/preview/build" \
    --project-root "$ROOT"
  [[ -d "$PROJECT_PATH" ]] || die "xcodegen did not create $PROJECT_PATH"
fi

# --- build ------------------------------------------------------------------
if [[ "$NO_BUILD" -eq 0 ]]; then
  mkdir -p "$ROOT/ios/preview/build/logs"
  _build_log="$ROOT/ios/preview/build/logs/build-$(date +%Y%m%d-%H%M%S).log"
  log "building $TARGET_NAME (Debug, iOS Simulator, unsigned); log: $_build_log"
  _status=0
  if [[ "$VERBOSE" -eq 1 ]]; then
    set +e
    xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -sdk iphonesimulator \
      -configuration Debug -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DERIVED_PATH" build 2>&1 | tee "$_build_log"
    _status="${PIPESTATUS[0]}"
    set -e
  else
    set +e
    xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -sdk iphonesimulator \
      -configuration Debug -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DERIVED_PATH" build >"$_build_log" 2>&1
    _status=$?
    set -e
  fi
  if [[ "$_status" -ne 0 ]]; then
    printf '\n' >&2
    tail -n 80 "$_build_log" >&2
    die "xcodebuild failed (full log: $_build_log)"
  fi
  log "build ok"
fi

[[ -d "$APP_PATH" ]] || die "app not found at $APP_PATH (run without --no-build to build it first)"
_host_arch="$(uname -m)"
_archs="$(xcrun lipo -archs "$APP_PATH/$TARGET_NAME" 2>/dev/null || true)"
if [[ -z "$_archs" ]]; then
  log "warning: could not read the app's architectures; continuing"
elif ! printf '%s\n' "$_archs" | tr ' ' '\n' | grep -qx "$_host_arch"; then
  die "the built app has no $_host_arch slice (archs: $_archs); the simulator on this Mac cannot install it. Delete $DERIVED_PATH, rerun, and check ONLY_ACTIVE_ARCH in ios/preview/project.yml"
fi

# --- simulator --------------------------------------------------------------
cat > "$WORK_DIR/pick_simulator.py" <<'PY'
import json
import subprocess
import sys


def simctl(*args):
    return json.loads(subprocess.check_output(["xcrun", "simctl"] + list(args) + ["--json"]))


wanted = sys.argv[1] if len(sys.argv) > 1 else "iPhone 14 Pro Max"

try:
    runtimes = simctl("list", "runtimes")["runtimes"]
except Exception as error:
    sys.stderr.write("could not list simulator runtimes: %s\n" % error)
    sys.exit(3)


def version_key(runtime):
    key = []
    for part in runtime.get("version", "0").split("."):
        key.append(int(part) if part.isdigit() else 0)
    return key


ios_runtimes = [r for r in runtimes
                if r.get("platform") == "iOS" and r.get("isAvailable")]
ios_runtimes.sort(key=version_key, reverse=True)
if not ios_runtimes:
    sys.stderr.write(
        "no installed and available iOS Simulator runtime was found.\n"
        "Open Xcode > Settings > Components and download an iOS simulator\n"
        "runtime (or run: xcodebuild -downloadPlatform iOS), then rerun.\n"
    )
    sys.exit(3)

runtime = ios_runtimes[0]
device_types = simctl("list", "devicetypes")["devicetypes"]
chosen = next((d for d in device_types if d.get("name") == wanted), None)
if chosen is None:
    chosen = next((d for d in device_types
                   if str(d.get("name", "")).startswith("iPhone")), None)
if chosen is None:
    sys.stderr.write("no iPhone Simulator device type is installed.\n")
    sys.exit(4)

devices = simctl("list", "devices")["devices"].get(runtime["identifier"], [])
matching = [d for d in devices
            if d.get("deviceTypeIdentifier") == chosen["identifier"]
            and d.get("isAvailable", True)]
matching.sort(key=lambda d: 0 if d.get("state") == "Booted" else 1)
udid = matching[0]["udid"] if matching else ""
print("%s|%s|%s|%s" % (runtime["identifier"], chosen["identifier"],
                       chosen.get("name", ""), udid))
PY

if [[ -n "$SIM_UDID" ]]; then
  log "using simulator from --udid: $SIM_UDID"
else
  log "picking an installed iOS runtime and an iPhone device type"
  _picked="$(python3 "$WORK_DIR/pick_simulator.py" "$DEVICE_TYPE_NAME")" \
    || die "no usable iOS Simulator runtime/device type (see the message above)"
  IFS='|' read -r _runtime_id _device_type_id _device_type_label _existing_udid <<< "$_picked"
  if [[ -n "$_existing_udid" ]]; then
    SIM_UDID="$_existing_udid"
    log "reusing simulator $SIM_UDID ($_device_type_label, $_runtime_id)"
  else
    log "creating simulator ($_device_type_label, $_runtime_id)"
    SIM_UDID="$(xcrun simctl create "$TARGET_NAME" "$_device_type_id" "$_runtime_id")" \
      || die "could not create a simulator"
    CREATED_SIMULATOR=1
  fi
fi
[[ -n "$SIM_UDID" ]] || die "could not determine a simulator UDID"

log "booting simulator $SIM_UDID (headless)"
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true
BOOTED_SIMULATOR=1
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null \
  || die "simulator $SIM_UDID did not finish booting (is the runtime installed?)"

# A fixed status bar keeps the screenshots comparable between runs.
xcrun simctl status_bar "$SIM_UDID" override --time "9:41" \
  --batteryState charged --batteryLevel 100 --wifiBars 3 >/dev/null 2>&1 || true

log "installing $APP_PATH"
xcrun simctl install "$SIM_UDID" "$APP_PATH" || die "simctl install failed"

log "seeding a synthetic game library into the app container"
_container="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)" \
  || die "could not find the data container for $BUNDLE_ID"

write_placeholder_rom() {
  _rom_path="$1"
  printf '3ds2apple UI preview placeholder (synthetic, not a ROM)\n' > "$_rom_path"
  dd if=/dev/zero bs=1024 count=4 >> "$_rom_path" 2>/dev/null || true
}

_docs="$_container/Documents"
mkdir -p "$_docs/Library" "$_docs/roms"
rm -f "$_docs/Library/library.json"
write_placeholder_rom "$_docs/roms/Pokemon Y.cci"
write_placeholder_rom "$_docs/roms/Super Mario 3D Land.3ds"
write_placeholder_rom "$_docs/roms/Animal Crossing New Leaf.cci"
cat > "$_docs/Library/library.json" <<'JSON'
[
  {
    "id": "0B7B5F0A-2C3C-4A11-9F3D-111111111111",
    "title": "Pokémon Y",
    "fileName": "Pokemon Y.cci",
    "relativePath": "roms/Pokemon Y.cci",
    "titleID": "0004000000055E00",
    "productCode": "CTR-P-EK2A",
    "coverRelativePath": null,
    "importedAt": "2026-11-10T09:00:00Z",
    "lastPlayedAt": "2026-11-13T08:30:00Z",
    "sizeBytes": 4096
  },
  {
    "id": "0B7B5F0A-2C3C-4A11-9F3D-222222222222",
    "title": "Super Mario 3D Land",
    "fileName": "Super Mario 3D Land.3ds",
    "relativePath": "roms/Super Mario 3D Land.3ds",
    "titleID": "0004000000030600",
    "productCode": "CTR-P-AREJ",
    "coverRelativePath": null,
    "importedAt": "2026-11-09T09:00:00Z",
    "lastPlayedAt": "2026-11-11T19:05:00Z",
    "sizeBytes": 4096
  },
  {
    "id": "0B7B5F0A-2C3C-4A11-9F3D-333333333333",
    "title": "Animal Crossing: New Leaf",
    "fileName": "Animal Crossing New Leaf.cci",
    "relativePath": "roms/Animal Crossing New Leaf.cci",
    "titleID": "0004000000086400",
    "productCode": "CTR-P-ECJE",
    "coverRelativePath": null,
    "importedAt": "2026-11-08T09:00:00Z",
    "lastPlayedAt": null,
    "sizeBytes": 4096
  }
]
JSON

# Settings live in UserDefaults; start every run from the defaults.
xcrun simctl spawn "$SIM_UDID" defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

# --- screenshots ------------------------------------------------------------
for _screen in "${SCREENS[@]}"; do
  _png="$OUT_DIR/$_screen.png"
  log "screen '$_screen': launching"
  if ! SIMCTL_CHILD_ZKPREVIEW_SCREEN="$_screen" SIMCTL_CHILD_ZKPREVIEW_DARK="$DARK" \
      xcrun simctl launch --terminate-running-process "$SIM_UDID" "$BUNDLE_ID" >/dev/null; then
    die "simctl launch failed for screen '$_screen'"
  fi
  sleep "$LAUNCH_DELAY"
  if ! xcrun simctl io "$SIM_UDID" screenshot "$_png" >/dev/null 2>&1; then
    die "simctl screenshot failed for screen '$_screen'"
  fi
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  [[ -s "$_png" ]] || die "screenshot for '$_screen' is empty: $_png"
  PNG_FILES+=("$_png")
  log "saved $_png"
done

printf '\nScreenshots (absolute paths):\n'
for _png in "${PNG_FILES[@]}"; do
  printf '%s\n' "$_png"
done
log "done: ${#PNG_FILES[@]} screenshot(s) in $OUT_DIR"
if [[ "$KEEP_SIMULATOR" -eq 1 ]]; then
  log "simulator $SIM_UDID is still booted; attach with 'open -a Simulator' or launch with:"
  printf "  xcrun simctl launch %s %s\n" "$SIM_UDID" "$BUNDLE_ID"
fi
