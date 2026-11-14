#!/usr/bin/env bash
# Fetch and verify the official Impactor v2.7.2 + plumesign Windows binaries.
#
# Modes:
#   tools/fetch-impactor.sh                 fetch (if missing) and verify into vendor/impactor
#   tools/fetch-impactor.sh --verify DIR    verify files already present in DIR
#   tools/fetch-impactor.sh --print-pins    print "name<TAB>sha256<TAB>bytes<TAB>url" per pinned binary
#
# The SHA-256 values are the same ones compiled into the launcher and checked by
# tools/fetch-impactor.ps1 on Windows. A mismatch deletes the file and exits non-zero.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$ROOT/vendor/impactor/PINS.json"
DEST="$ROOT/vendor/impactor"
MODE="fetch"
if [[ $# -ge 1 ]]; then
  case "$1" in
    --print-pins) MODE="print" ;;
    --verify) MODE="verify"; DEST="$2" ;;
    --fetch) MODE="fetch" ;;
    *) echo "usage: $0 [--print-pins | --verify DIR]" >&2; exit 2 ;;
  esac
fi

read_pins() {
  python3 - "$PINS" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
for binary in doc["binaries"]:
    print(binary["fileName"] + "\t" + binary["sha256"] + "\t" + str(binary["bytes"]) + "\t" + doc["downloadBase"] + binary["fileName"])
PY
}

if [[ "$MODE" == "print" ]]; then
  read_pins
  exit 0
fi

mkdir -p "$DEST"
failures=0
while IFS=$'\t' read -r name sha bytes url; do
  target="$DEST/$name"
  if [[ "$MODE" == "fetch" ]]; then
    if [[ ! -f "$target" ]]; then
      echo "[download] $url"
      if ! curl -fL --retry 3 -o "$target.part" "$url"; then
        rm -f "$target.part"
        echo "[error] download failed: $url" >&2
        failures=$((failures + 1))
        continue
      fi
      mv "$target.part" "$target"
    fi
  fi
  if [[ ! -f "$target" ]]; then
    echo "[missing] $name"
    failures=$((failures + 1))
    continue
  fi
  actual_sha="$(sha256sum "$target" | cut -d' ' -f1)"
  actual_bytes="$(stat -c '%s' "$target" 2>/dev/null || stat -f '%z' "$target")"
  if [[ "$actual_sha" != "$sha" || "$actual_bytes" != "$bytes" ]]; then
    echo "[MISMATCH] $name sha256=$actual_sha bytes=$actual_bytes expected $sha / $bytes"
    rm -f "$target"
    failures=$((failures + 1))
  else
    printf '[ok] %s  %.16s...\n' "$name" "$sha"
  fi
done < <(read_pins)

for companion in LICENSE-Impactor-MIT.txt LICENSE-apple-codesign-MPL-2.0.txt README-source-and-licenses.txt PINS.json; do
  if [[ ! -f "$DEST/$companion" ]]; then
    cp "$ROOT/vendor/impactor/$companion" "$DEST/$companion" 2>/dev/null || true
  fi
  if [[ ! -f "$DEST/$companion" ]]; then
    echo "[missing] $companion"
    failures=$((failures + 1))
  fi
done

if [[ "$failures" -gt 0 ]]; then
  echo "Impactor bundle is NOT ready ($failures problem(s))." >&2
  exit 1
fi
echo "Impactor v2.7.2 + plumesign verified (SHA-256 pinned, official unmodified release)."
