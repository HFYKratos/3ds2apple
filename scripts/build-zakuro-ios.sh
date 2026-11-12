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
ZAKURO_REF="${ZAKURO_REF:-main}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS with Xcode installed." >&2
  exit 1
fi

if [[ ! -d "$ZAKURO_DIR/.git" ]]; then
  mkdir -p "$(dirname "$ZAKURO_DIR")"
  git clone --depth 1 --branch "$ZAKURO_REF" https://github.com/fearkov/zakuro "$ZAKURO_DIR"
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