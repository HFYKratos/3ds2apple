#!/usr/bin/env bash
# Build Zakuro's 3DS runtime as an iOS arm64 static library.
#
# Must run on macOS with Xcode + Rust (aarch64-apple-ios target).
# Usage:
#   scripts/build-zakuro-ios.sh
#   ZAKURO_DIR=/path/to/zakuro scripts/build-zakuro-ios.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZAKURO_DIR="${ZAKURO_DIR:-$ROOT/third_party/zakuro}"
# Pinned upstream revision (2026-11-19): main's comment-cleanup commit after
# 3fe7b15. The local patches in ios/zakuro-ios/patches are rebased onto exactly
# this revision, so the library build is reproducible while upstream main moves.
# ZAKURO_REF is for local experiments only, never for a release build.
ZAKURO_PIN="fdf67b2b6398a7ad0dc2309b09ea4c03c45e9d8"
ZAKURO_REF="${ZAKURO_REF:-$ZAKURO_PIN}"
# The host's recomp-abi crate (pinned by Zakuro's Cargo.lock) and the 3dsrecomp
# CLI scripts/build-recomp-ios.sh runs must be the same revision: recomp-abi is
# the Rust twin of the C the CLI generates, so one revision on both sides is the
# reproducible pair. Keep this equal to build-recomp-ios.sh's DEFAULT_RECOMP_REV.
RECOMP_REV="4b6de5d884b0d8bc337e16c07b84a0824e55a0e1"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS with Xcode installed." >&2
  exit 1
fi

if [[ ! -d "$ZAKURO_DIR/.git" ]]; then
  if [[ -e "$ZAKURO_DIR" ]]; then
    echo "error: $ZAKURO_DIR exists but is not a git checkout; remove it (it is gitignored build state)." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$ZAKURO_DIR")"
  git init -q "$ZAKURO_DIR"
  git -C "$ZAKURO_DIR" remote add origin https://github.com/fearkov/zakuro
  # `git fetch origin <sha>` is not served by every host (GitHub refuses it),
  # so fetch main alone when the pin is the tip and deepen until the pinned
  # commit is there otherwise. http.version=HTTP/1.1 survives the flaky HTTP/2
  # framing some networks show on github.com.
  git_net() { git -C "$ZAKURO_DIR" -c http.version=HTTP/1.1 "$@"; }
  if ! git_net fetch -q --depth 1 origin "$ZAKURO_REF" 2>/dev/null; then
    git_net fetch -q --depth 1 origin main || {
      echo "error: cannot fetch Zakuro from https://github.com/fearkov/zakuro" >&2
      exit 1
    }
    depth=1
    while ! git_net rev-parse --verify -q "$ZAKURO_REF^{commit}" >/dev/null 2>&1; do
      [[ "$depth" -lt 1024 ]] || break
      depth=$((depth * 2))
      git_net fetch -q --deepen "$depth" origin main || break
    done
  fi
  git_net rev-parse --verify "$ZAKURO_REF^{commit}" >/dev/null 2>&1 || {
    echo "error: cannot resolve pinned Zakuro revision $ZAKURO_REF" >&2
    exit 1
  }
  git_net checkout -q --detach "$ZAKURO_REF"
else
  have="$(git -C "$ZAKURO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  want="$(git -C "$ZAKURO_DIR" rev-parse --verify -q "${ZAKURO_REF}^{commit}" 2>/dev/null || true)"
  if [[ -z "$want" ]]; then
    echo "[zakuro] warning: cannot resolve $ZAKURO_REF in $ZAKURO_DIR; remove it and re-run" >&2
  elif [[ "$have" != "$want" ]]; then
    echo "[zakuro] warning: checkout is at $have, but this script pins $ZAKURO_REF" >&2
    echo "[zakuro]          remove $ZAKURO_DIR and re-run for a reproducible build" >&2
  fi
fi

# Apply the local patches (MoltenVK lookup on iOS, pipeline-cache save
# interval, GPU execution timings and the renderer A/B switches). Idempotent: an
# already patched checkout is left as it is, and a patch that no longer applies
# is a warning, so a locally moved checkout can still be used for experiments.
# shellcheck source=lib/zakuro-patches.sh
source "$ROOT/scripts/lib/zakuro-patches.sh"
apply_zakuro_patches "$ZAKURO_DIR"

# Pin the host's recomp-abi (and the build-only recomp3ds crate when the lock
# has it) to the same 3dsrecomp revision the generated C comes from. A lock left
# on another revision still runs, because recomp-abi accepts every interface
# version from OLDEST_ABI (4) up, but a release build keeps one revision on both
# sides. Set ZAKURO_SYNC_RECOMP=0 to keep the lock as upstream wrote it.
if [[ "${ZAKURO_SYNC_RECOMP:-1}" == "1" && -f "$ZAKURO_DIR/Cargo.lock" ]]; then
  python3 - "$ZAKURO_DIR/Cargo.lock" "$RECOMP_REV" <<'PY'
import re
import sys
from pathlib import Path

lock = Path(sys.argv[1])
rev = sys.argv[2]
text = lock.read_text()
new, count = re.subn(r"(git\+https://github\.com/fearkov/3dsrecomp#)[0-9a-f]{40}", r"\g<1>" + rev, text)
if new != text:
    lock.write_text(new)
print(f"[zakuro] pinned recomp-abi to {rev[:12]} ({count} lock entries)")
PY
fi

python3 - "$ZAKURO_DIR" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
cargo = root / "Cargo.toml"
text = cargo.read_text()

if '"crates/zakuro-ios"' not in text:
    text = text.replace('    "crates/zakuro-core",', '    "crates/zakuro-core",\n    "crates/zakuro-ios",')

# Disable the Cranelift shader JIT for iOS (no executable memory on device).
# This has to be set on the workspace dependency; per-dependency
# `default-features = false` is ignored for workspace dependencies on
# edition 2021.
text = re.sub(
    r'zakuro-gpu\s*=\s*\{\s*path\s*=\s*"crates/zakuro-gpu"\s*\}',
    'zakuro-gpu    = { path = "crates/zakuro-gpu", default-features = false }',
    text,
)
cargo.write_text(text)
print("patched workspace Cargo.toml")
PY

rm -rf "$ZAKURO_DIR/crates/zakuro-ios"
cp -R "$ROOT/ios/zakuro-ios" "$ZAKURO_DIR/crates/zakuro-ios"

rustup target add aarch64-apple-ios
cd "$ZAKURO_DIR"
cargo build -p zakuro-ios --release --target aarch64-apple-ios

mkdir -p "$ROOT/build/ios"
cp target/aarch64-apple-ios/release/libzakuro_ios.a "$ROOT/build/ios/libzakuro_ios.a"
echo "built: $ROOT/build/ios/libzakuro_ios.a"
