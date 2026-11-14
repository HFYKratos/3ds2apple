#!/usr/bin/env bash
# run-sim-probe.sh - run tools/winbuild/sim-probe inside the iOS Simulator on the
# macOS build VM to prove a cross-built (LLVM/LLD, no Apple SDK) GamePack dylib
# dlopen()s there and its GamePack ABI forwards the recomp tables.
#
# Part of 3ds2apple (Apache-2.0). Run this ON THE macOS VM (reference only: this
# host app is built with Xcode; the GamePack dylib under test is NOT).
#
# Usage (on the VM, from the repo root):
#   tools/winbuild/sim-probe/run-sim-probe.sh <GamePack-sim.dylib> [--udid UDID]
#
# What it does: builds a tiny app bundle with the SDK, embeds the dylib in
# <app>/Frameworks/, boots the iPhone 17 Pro simulator if needed, installs the
# app, launches it with SIMCTL_CHILD_GAMEPACK_PATH pointing at the embedded
# dylib, streams the probe log, then shuts the simulator down (pass
# --keep-booted to leave it running). Exit status is the probe's.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
DYLIB=""
UDID="${SIM_UDID:-3CBF5A62-AE12-47E8-803D-1D77BED85A66}"
KEEP=0
BUNDLE_ID="com.kratos.3ds2apple.winbuildprobe"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) [[ $# -ge 2 ]] || { echo "--udid requires a value" >&2; exit 2; }; UDID="$2"; shift 2 ;;
    --keep-booted) KEEP=1; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) [[ -z "${DYLIB}" ]] || { echo "unexpected argument: $1" >&2; exit 2; }; DYLIB="$1"; shift ;;
  esac
done
[[ -n "${DYLIB}" && -f "${DYLIB}" ]] || { echo "usage: run-sim-probe.sh <GamePack-sim.dylib>" >&2; exit 2; }

nohup caffeinate -dimsu >/dev/null 2>&1 &
WORK="${ROOT}/build/sim/winbuild-probe"
APP="${WORK}/gamepack-probe.app"
export PATH="/usr/local/bin:${PATH}"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

echo "== building the simulator probe app (Xcode clang, reference host only)"
rm -rf "${WORK}"
mkdir -p "${APP}/Frameworks"
xcrun --sdk iphonesimulator clang -arch x86_64 -mios-simulator-version-min=16.0 \
  -isysroot "${SDK}" -O2 -Wall -Wextra -Wno-unused-parameter \
  "${HERE}/main.c" -o "${APP}/gamepack-probe" -ldl
cp "${HERE}/Info.plist" "${APP}/Info.plist"
cp "${DYLIB}" "${APP}/Frameworks/GamePack-sim.dylib"
echo "   app: ${APP}"

echo "== booting simulator ${UDID}"
xcrun simctl boot "${UDID}" 2>/dev/null || true
xcrun simctl bootstatus "${UDID}" -b
xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
xcrun simctl uninstall "${UDID}" "${BUNDLE_ID}" 2>/dev/null || true
xcrun simctl install "${UDID}" "${APP}"
CONTAINER="$(xcrun simctl get_app_container "${UDID}" "${BUNDLE_ID}" app)"
PACK="${CONTAINER}/Frameworks/GamePack-sim.dylib"
echo "== embedded pack: ${PACK}"
echo "== launching probe"
set +e
SIMCTL_CHILD_GAMEPACK_PATH="${PACK}" xcrun simctl launch --console-pty "${UDID}" "${BUNDLE_ID}" 2>&1 | tee "${WORK}/probe.log"
STATUS=${PIPESTATUS[0]}
set -e
echo "== probe exit status: ${STATUS}"
if [[ "${KEEP}" -eq 0 ]]; then xcrun simctl shutdown all || true; fi
exit "${STATUS}"
