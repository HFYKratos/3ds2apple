#!/usr/bin/env bash
# build-zakuro-ios-sim.sh — build Zakuro's 3DS runtime as an iOS Simulator
# static library, next to the device library from build-zakuro-ios.sh.
#
# Why this exists
#   scripts/build-zakuro-ios.sh produces the device slice (aarch64-apple-ios)
#   only. The build VM is an Intel Mac, so its iPhone 17 Pro simulator runs
#   x86_64 and cannot link (or run) the arm64 device library. This script
#   builds the same runtime for x86_64-apple-ios (Rust's iOS Simulator target)
#   and leaves the device build untouched:
#
#     build/ios/libzakuro_ios.a        device, aarch64-apple-ios
#     build/ios/libzakuro_ios_sim.a    Simulator, x86_64-apple-ios  <- here
#
#   Set ZAKURO_SIM_TARGET=aarch64-apple-ios-sim to build the Apple-silicon
#   Simulator slice instead (not this VM; it is an Intel x86_64 host).
#
# What runs in the Simulator
#   Everything the shell's interpreter fallback needs: HLE kernel/services, the
#   CPU interpreter and the software PICA200 renderer, driven through
#   zk_create / zk_run_frame / zk_read_screen. That is the same path the device
#   shell uses for ROMs without linked AOT code, so no MoltenVK is needed.
#
# What does not
#   Hardware 3D on the host GPU. On iOS the Vulkan backend is MoltenVK over
#   Metal, and inside the Simulator that Metal device is the host Mac's. This
#   build VM has no Metal device (MTLCreateSystemDefaultDevice() returns nil;
#   its GPU is a virtual display with 3 MB VRAM), so a ZAKURO_IOS_HARDWARE
#   build would still fall back to software here. The Vulkan/MoltenVK code is
#   compiled in anyway (zakuro-core always enables the vulkan feature), so the
#   library stays behaviour-compatible with the device one, but the hardware
#   path cannot be exercised on this VM. See docs/build-simulator.md.
#
# Must run on macOS with Xcode and Rust (the iOS Simulator SDK). Usage:
#   scripts/build-zakuro-ios-sim.sh
#   ZAKURO_DIR=/path/to/zakuro scripts/build-zakuro-ios-sim.sh
#   ZAKURO_SIM_TARGET=aarch64-apple-ios-sim scripts/build-zakuro-ios-sim.sh
#   CARGO_BUILD_JOBS=2 scripts/build-zakuro-ios-sim.sh   # leave the VM headroom
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZAKURO_DIR="${ZAKURO_DIR:-$ROOT/third_party/zakuro}"
ZAKURO_REF="${ZAKURO_REF:-main}"
TARGET="${ZAKURO_SIM_TARGET:-x86_64-apple-ios}"
CARGO_JOBS="${CARGO_BUILD_JOBS:-3}"
OUT="$ROOT/build/ios/libzakuro_ios_sim.a"
INFO="$ROOT/build/ios/libzakuro_ios_sim.info.txt"

die() { printf 'build-zakuro-ios-sim: %s\n' "$*" >&2; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "this script must run on macOS with Xcode installed"
fi

case "$TARGET" in
  x86_64-apple-ios|aarch64-apple-ios-sim) ;;
  *) die "unsupported ZAKURO_SIM_TARGET '$TARGET' (use x86_64-apple-ios or aarch64-apple-ios-sim)" ;;
esac

if [[ ! -d "$ZAKURO_DIR/.git" ]]; then
  mkdir -p "$(dirname "$ZAKURO_DIR")"
  git clone --depth 1 --branch "$ZAKURO_REF" https://github.com/fearkov/zakuro "$ZAKURO_DIR"
fi

# Apply the local patches (MoltenVK lookup on iOS, pipeline-cache save
# interval). Idempotent: an already patched checkout is left as it is, and a
# patch that no longer applies is a warning, so upstream main can drift.
# shellcheck source=lib/zakuro-patches.sh
source "$ROOT/scripts/lib/zakuro-patches.sh"
apply_zakuro_patches "$ZAKURO_DIR"

python3 - "$ZAKURO_DIR" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
cargo = root / "Cargo.toml"
text = cargo.read_text()
original = text

if '"crates/zakuro-ios"' not in text:
    text = text.replace('    "crates/zakuro-core",', '    "crates/zakuro-core",\n    "crates/zakuro-ios",')

# Disable the Cranelift shader JIT for iOS (device and Simulator forbid
# executable memory for ordinary apps). This has to be set on the workspace
# dependency; per-dependency default-features = false is ignored for workspace
# dependencies on edition 2021. The Simulator library keeps the same feature
# set as the device one so behaviour matches.
text = re.sub(
    r'zakuro-gpu\s*=\s*\{\s*path\s*=\s*"crates/zakuro-gpu"\s*\}',
    'zakuro-gpu    = { path = "crates/zakuro-gpu", default-features = false }',
    text,
)
if text != original:
    cargo.write_text(text)
    print("patched workspace Cargo.toml")
else:
    print("workspace Cargo.toml already patched")
PY

rm -rf "$ZAKURO_DIR/crates/zakuro-ios"
cp -R "$ROOT/ios/zakuro-ios" "$ZAKURO_DIR/crates/zakuro-ios"

# Install the target's standard library. On a normal machine this is
# `rustup target add`; if the sysroot already has the target (an offline or
# manually installed rust-std, as on the Metal-less build VM whose upstream
# rust-lang.org downloads are very slow) it is skipped, because build machines
# must not re-download ~30 MB of std on every build.
SYSROOT="$(rustc --print sysroot)"
if [[ ! -d "$SYSROOT/lib/rustlib/$TARGET/lib" ]]; then
  rustup target add "$TARGET"
fi

cd "$ZAKURO_DIR"
CARGO_BUILD_JOBS="$CARGO_JOBS" cargo build -p zakuro-ios --release --target "$TARGET"

mkdir -p "$ROOT/build/ios"
cp "target/$TARGET/release/libzakuro_ios.a" "$OUT"

# --- verification -----------------------------------------------------------
[[ -s "$OUT" ]] || die "build produced no library at $OUT"

if command -v lipo >/dev/null 2>&1; then
  arch_info="$(lipo -info "$OUT")"
  printf '%s\n' "$arch_info"
  case "$TARGET" in
    x86_64-apple-ios)
      [[ "$arch_info" == *x86_64* ]] || die "the library is not the x86_64 Simulator slice"
      ;;
    aarch64-apple-ios-sim)
      [[ "$arch_info" == *arm64* || "$arch_info" == *aarch64* ]] || die "the library is not the arm64 Simulator slice"
      ;;
  esac
fi

if command -v nm >/dev/null 2>&1; then
  # Collect first: nm may exit non-zero on some archive members and writing
  # `nm ... | grep -q` under `set -o pipefail` turns that (and grep's early
  # SIGPIPE exit) into a false "symbol missing" failure. The symbols are there.
  symbols="$(nm -gU "$OUT" 2>/dev/null || true)"
  grep -q ' _zk_run_frame$' <<< "$symbols" || die "the library does not export zk_run_frame"
  printf 'exports zk_*: yes (%s zk_ symbols)\n' "$(grep -c ' _zk_[a-z_]\+$' <<< "$symbols" || true)"
fi

{
  printf 'target=%s\n' "$TARGET"
  printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'rustc=%s\n' "$(rustc --version 2>/dev/null || echo unknown)"
  printf 'zakuro_commit=%s\n' "$(git -C "$ZAKURO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'hardware_renderer_default=%s\n' "${ZAKURO_IOS_HARDWARE:-0}"
} > "$INFO"

printf 'built: %s\n' "$OUT"
printf 'info:  %s\n' "$INFO"
