#!/usr/bin/env bash
# desktop-aot-selfcheck.sh — Linux/macOS self-check for the desktop AOT pipeline.
#
# Runs everywhere (no Xcode, no ROM, no macOS): synthetic NCSD header images are
# written to a temp directory and driven through the real binaries/scripts:
#
#   builder/pack (3ds2apple-pack): rom inspect, packages add/list/verify,
#     build --fake, catalog, build plan, pack --execute --fake-shell
#   scripts/build-game-pack.sh:    --fake package recording, --dry-run
#   scripts/build-multi-game-ipa.sh: multi-game preview IPA, placeholder
#     rejection, dry-run, catalogue-in-IPA verification
#   scripts/lib/game-catalog.sh:   schema v1/v2 validation incl. packFile
#
# Usage:
#   scripts/tests/desktop-aot-selfcheck.sh
#
# Requirements: bash, cargo (builds builder/pack if the binary is missing),
# python3, zip (via package-ipa.sh); unzip is optional for extra verification.
#
# Exit status: 0 when every check passes, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

# shellcheck source=../lib/desktop-aot.sh
source "${SCRIPTS_DIR}/lib/desktop-aot.sh"
# shellcheck source=../lib/game-catalog.sh
source "${SCRIPTS_DIR}/lib/game-catalog.sh"

CHECKS=0
FAILURES=0

pass() { CHECKS=$(( CHECKS + 1 )); printf '  ok   %s\n' "$1"; }
fail() { CHECKS=$(( CHECKS + 1 )); FAILURES=$(( FAILURES + 1 )); printf '  FAIL %s\n' "$1" >&2; }
section() { printf '\n[%s] %s\n' "$1" "$2"; }
expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
expect_contains() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing '$2')"; fi; }
expect_file() { if [[ -s "$2" ]]; then pass "$1"; else fail "$1 (missing or empty: $2)"; fi; }
expect_no_file() { if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 (unexpected file: $2)"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/desktop-aot-selfcheck.XXXXXX")"
cleanup() { rm -rf -- "${WORK}"; }
trap cleanup EXIT

FIXTURE="${ROOT}/builder/pack/tests/fixtures/catalog-multi.json"
OUT="${WORK}/out"
ROMS="${WORK}/roms"
IPA_DIR="${WORK}/ipa"
mkdir -p "${ROMS}"

# ---------------------------------------------------------------------------
section 1 "syntax and --help smoke tests (no Xcode needed)"
# ---------------------------------------------------------------------------
for script in \
  "${SCRIPTS_DIR}/build-game-pack.sh" \
  "${SCRIPTS_DIR}/build-multi-game-ipa.sh" \
  "${SCRIPTS_DIR}/lib/desktop-aot.sh" \
  "${SCRIPTS_DIR}/lib/game-catalog.sh"; do
  if bash -n "$script" 2>/dev/null; then
    pass "bash -n ${script#"$ROOT"/}"
  else
    fail "bash -n ${script#"$ROOT"/}"
    bash -n "$script" || true
  fi
done

for script in "${SCRIPTS_DIR}/build-game-pack.sh" "${SCRIPTS_DIR}/build-multi-game-ipa.sh"; do
  if "$script" --help >/dev/null 2>&1; then
    pass "--help ${script#"$ROOT"/}"
  else
    fail "--help ${script#"$ROOT"/}"
  fi
done

# Locate/build the Rust CLI (this is the desktop pipeline; a Rust toolchain is a
# documented prerequisite of the builder).
PACK_BIN=""
if [[ -n "${THREEDS2APPLE_PACK:-}" ]]; then
  PACK_BIN="${THREEDS2APPLE_PACK}"
fi
if [[ -z "$PACK_BIN" ]]; then
  PACK_BIN="$(desktop_aot_find_pack_bin "$ROOT" "" || true)"
fi
if [[ -z "$PACK_BIN" ]]; then
  printf '  ..  3ds2apple-pack not built yet; running cargo build -p builder-pack\n'
  if ( cd "${ROOT}/builder" && cargo build -q -p builder-pack --offline 2>/dev/null ); then
    :
  elif ( cd "${ROOT}/builder" && cargo build -q -p builder-pack ); then
    :
  else
    fail "build 3ds2apple-pack (cd builder && cargo build -p builder-pack)"
  fi
  PACK_BIN="$(desktop_aot_find_pack_bin "$ROOT" "" || true)"
fi
if [[ -n "$PACK_BIN" && -x "$PACK_BIN" ]]; then
  pass "found desktop CLI: ${PACK_BIN#"$ROOT"/}"
  if "$PACK_BIN" --help 2>/dev/null | grep -q 'packages'; then
    pass "3ds2apple-pack --help lists the package commands"
  else
    fail "3ds2apple-pack --help lists the package commands"
  fi
else
  fail "3ds2apple-pack binary not found ($(desktop_aot_pack_bin_hint))"
fi

# ---------------------------------------------------------------------------
section 2 "synthetic ROM headers -> import/queue/fake-build/catalog"
# ---------------------------------------------------------------------------
if ! python3 - "$ROMS" <<'PY'
import struct
import sys
from pathlib import Path

roms = Path(sys.argv[1])


def ncsd(title_id, product_code):
    partition = 0x4000
    data = bytearray(partition + 0x200)
    data[0x100:0x104] = b"NCSD"
    data[0x104:0x108] = struct.pack("<I", len(data) // 512)
    data[0x108:0x110] = struct.pack("<Q", title_id)
    data[0x120:0x124] = struct.pack("<I", partition // 512)
    ncch = memoryview(data)[partition:]
    ncch[0x100:0x104] = b"NCCH"
    ncch[0x104:0x108] = struct.pack("<I", 4)
    ncch[0x112:0x114] = struct.pack("<H", 2)
    ncch[0x118:0x120] = struct.pack("<Q", title_id)
    encoded = product_code.encode("ascii")
    ncch[0x150:0x150 + len(encoded)] = encoded
    return bytes(data)


(roms / "Pokémon Y.cci").write_bytes(ncsd(0x0004000000055E00, "CTR-P-EK2A"))
(roms / "Pokémon Alpha Sapphire.cci").write_bytes(ncsd(0x000400000011C500, "CTR-P-ECLA"))
PY
then
  fail "write synthetic ROM headers (python3)"
fi
expect_file "synthetic ROM 1 exists" "${ROMS}/Pokémon Y.cci"
expect_file "synthetic ROM 2 exists" "${ROMS}/Pokémon Alpha Sapphire.cci"

if [[ -n "$PACK_BIN" ]]; then
  if INSPECT="$("$PACK_BIN" --json rom inspect "${ROMS}/Pokémon Y.cci" "${ROMS}/Pokémon Alpha Sapphire.cci" 2>&1)"; then
    pass "rom inspect exits 0"
    if printf '%s' "$INSPECT" | python3 -c '
import json, sys
data = json.load(sys.stdin)
games = {g["titleID"]: g for g in data["roms"]}
assert games["0004000000055E00"]["productCode"] == "CTR-P-EK2A", games
assert games["000400000011C500"]["productCode"] == "CTR-P-ECLA", games
assert games["0004000000055E00"]["displayName"] == "Pokémon Y", games
'; then
      pass "rom inspect detects titleID/productCode/displayName"
    else
      fail "rom inspect detects titleID/productCode/displayName"
    fi
  else
    fail "rom inspect exits 0 ($INSPECT)"
  fi

  if "$PACK_BIN" --out "$OUT" packages add --roms "${ROMS}/Pokémon Y.cci" "${ROMS}/Pokémon Alpha Sapphire.cci" >/dev/null 2>&1; then
    pass "packages add imports two ROMs"
  else
    fail "packages add imports two ROMs"
  fi
  expect_file "package dir for Pokémon Y" "${OUT}/packages/0004000000055E00/GameInfo.json"
  expect_file "package dir for Alpha Sapphire" "${OUT}/packages/000400000011C500/GameInfo.json"
  expect_file "import queue file" "${OUT}/aot-queue.json"

  if LIST="$("$PACK_BIN" --out "$OUT" --json packages list 2>&1)"; then
    if printf '%s' "$LIST" | python3 -c '
import json, sys
data = json.load(sys.stdin)
packages = data["packages"]
assert len(packages) == 2, packages
assert {p["state"] for p in packages} == {"queued"}, packages
'; then
      pass "packages list shows two queued packages"
    else
      fail "packages list shows two queued packages"
    fi
  else
    fail "packages list --json"
  fi

  # The real macOS plan is printable on Linux (fake/dry-run link step).
  if PLAN="$("$PACK_BIN" --out "$OUT" build --queued 2>&1)"; then
    expect_contains "build plan names the recomp step" "scripts/build-recomp-ios.sh" "$PLAN"
    expect_contains "build plan names the pack step" "scripts/build-game-pack.sh" "$PLAN"
    expect_contains "build plan passes --out" "--out" "$PLAN"
    expect_no_file "build plan writes nothing (dry run)" "${OUT}/packages/0004000000055E00/GamePack.dylib"
  else
    fail "build plan (build --queued without --execute/--fake) ($PLAN)"
  fi

  if "$PACK_BIN" --out "$OUT" build --queued --fake >/dev/null 2>&1; then
    pass "build --queued --fake writes placeholder packs"
  else
    fail "build --queued --fake writes placeholder packs"
  fi
  expect_file "placeholder pack exists" "${OUT}/packages/0004000000055E00/GamePack.dylib"
  if desktop_aot_pack_is_placeholder "${OUT}/packages/0004000000055E00/GamePack.dylib"; then
    pass "fake pack is a labelled placeholder"
  else
    fail "fake pack is a labelled placeholder"
  fi

  if VERIFY="$("$PACK_BIN" --out "$OUT" --json packages verify 2>&1)"; then
    if printf '%s' "$VERIFY" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert len(data["packages"]) == 2, data
for package in data["packages"]:
    assert package["ok"] is True, package
    assert any("placeholder" in issue for issue in package["issues"]), package
'; then
      pass "packages verify succeeds and flags placeholders"
    else
      fail "packages verify succeeds and flags placeholders"
    fi
  else
    fail "packages verify --json"
  fi

  if "$PACK_BIN" --out "$OUT" catalog >/dev/null 2>&1; then
    pass "catalog command exits 0"
  else
    fail "catalog command exits 0"
  fi
  CATALOG="${OUT}/packages/GameCatalog.json"
  if cmp -s "$CATALOG" "$FIXTURE"; then
    pass "generated catalogue is byte-identical to the golden schema-v2 fixture"
  else
    fail "generated catalogue matches the golden fixture (diff: $(diff "$CATALOG" "$FIXTURE" | head -2 | tr '\n' ' '))"
  fi
  CATALOG_SHA="$(desktop_aot_sha256 "$CATALOG")"
  if "$PACK_BIN" --out "$OUT" catalog >/dev/null 2>&1 \
      && [[ "$(desktop_aot_sha256 "$CATALOG")" == "$CATALOG_SHA" ]]; then
    pass "catalogue generation is deterministic"
  else
    fail "catalogue generation is deterministic"
  fi
  # S3: --fake and --execute are mutually exclusive (never silently ignored).
  if "$PACK_BIN" --out "$OUT" build --queued --fake --execute >/dev/null 2>"${WORK}/conflict.err"; then
    fail "build --fake --execute is rejected"
  else
    if grep -q 'cannot be used with' "${WORK}/conflict.err"; then
      pass "build --fake --execute is rejected (clap conflict)"
    else
      fail "build --fake --execute is rejected (clap conflict)"
    fi
  fi

  # S4: --queued --force rebuilds built packages; plain --queued has nothing to do.
  if "$PACK_BIN" --out "$OUT" build --queued --fake >/dev/null 2>"${WORK}/noforce.err"; then
    fail "build --queued without --force refuses already built packages"
  else
    if grep -q 'pass --force' "${WORK}/noforce.err"; then
      pass "build --queued without --force refuses already built packages"
    else
      fail "build --queued without --force refuses already built packages"
    fi
  fi
  if "$PACK_BIN" --out "$OUT" build --queued --force --fake >/dev/null 2>&1; then
    pass "build --queued --force rebuilds built packages"
  else
    fail "build --queued --force rebuilds built packages"
  fi

  # N6: pack --all with no packages errors before writing an empty catalogue.
  EMPTY_OUT="${WORK}/out-empty"
  if "$PACK_BIN" --out "$EMPTY_OUT" pack --all --fake-shell >/dev/null 2>"${WORK}/pack-empty.err"; then
    fail "pack --all with no packages errors cleanly"
  else
    if grep -q 'no built packages' "${WORK}/pack-empty.err" \
        && [[ ! -e "${EMPTY_OUT}/packages/GameCatalog.json" ]]; then
      pass "pack --all with no packages errors cleanly"
    else
      fail "pack --all with no packages errors cleanly"
    fi
  fi

  # S2: a rejected ROM is reported, the accepted one is still built, exit 1.
  printf 'not a rom' > "${WORK}/not-a-rom.3ds"
  if "$PACK_BIN" --out "${WORK}/out-s2" build --roms "${ROMS}/Pokémon Y.cci" \
      "${WORK}/not-a-rom.3ds" --fake >/dev/null 2>"${WORK}/partial.err"; then
    fail "build --roms with a rejected ROM exits non-zero"
  else
    pass "build --roms with a rejected ROM exits non-zero"
  fi
  if [[ -f "${WORK}/out-s2/packages/0004000000055E00/GamePack.dylib" ]]; then
    pass "build --roms still builds the accepted ROM after a rejection"
  else
    fail "build --roms still builds the accepted ROM after a rejection"
  fi

  if game_catalog_validate "$CATALOG"; then
    expect_eq "catalogue validator counts two games" "2" "$GAME_CATALOG_COUNT"
    SUMMARY="$(game_catalog_summary_text)"
    expect_contains "catalogue summary lists Pokémon Y" "0004000000055E00" "$SUMMARY"
    expect_contains "catalogue summary lists Alpha Sapphire" "000400000011C500" "$SUMMARY"
  else
    fail "catalogue validator accepts the generated schema-v2 catalogue ($GAME_CATALOG_ERROR)"
  fi

  # Validator must reject a wrong packFile / packABIVersion (schema v2 safety).
  python3 - "$CATALOG" "${WORK}/bad-packfile.json" <<'PY'
import json, sys
source, destination = sys.argv[1], sys.argv[2]
with open(source, "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["games"][0]["packFile"] = "Frameworks/Other.dylib"
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
    handle.write("\n")
PY
  if game_catalog_validate "${WORK}/bad-packfile.json" 2>/dev/null; then
    fail "validator rejects a mismatched packFile"
  else
    pass "validator rejects a mismatched packFile"
  fi
  python3 - "$CATALOG" "${WORK}/bad-packabi.json" <<'PY'
import json, sys
source, destination = sys.argv[1], sys.argv[2]
with open(source, "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["games"][0]["packABIVersion"] = 0
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
    handle.write("\n")
PY
  if game_catalog_validate "${WORK}/bad-packabi.json" 2>/dev/null; then
    fail "validator rejects packABIVersion 0"
  else
    pass "validator rejects packABIVersion 0"
  fi

  # N7: a schemaVersion 2 entry must name its packFile (the Rust writer rule).
  python3 - "$CATALOG" "${WORK}/bad-schema2-no-pack.json" <<'PY'
import json, sys
source, destination = sys.argv[1], sys.argv[2]
with open(source, "r", encoding="utf-8") as handle:
    data = json.load(handle)
for game in data["games"]:
    game.pop("packFile", None)
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
    handle.write("\n")
PY
  if game_catalog_validate "${WORK}/bad-schema2-no-pack.json" 2>/dev/null; then
    fail "validator rejects schema-2 entries without packFile"
  else
    pass "validator rejects schema-2 entries without packFile"
  fi

  # -------------------------------------------------------------------------
  section 3 "one shell IPA with several game packs (fake-shell preview)"
  # -------------------------------------------------------------------------
  if "${SCRIPTS_DIR}/build-multi-game-ipa.sh" --packages-dir "$OUT/packages" --all \
      --allow-placeholder-dylibs --fake-shell --pack-bin "$PACK_BIN" \
      --out-dir "$IPA_DIR" >"${WORK}/multi.log" 2>&1; then
    pass "build-multi-game-ipa.sh --fake-shell exits 0"
  else
    fail "build-multi-game-ipa.sh --fake-shell exits 0 ($(tail -2 "${WORK}/multi.log" | tr '\n' ' '))"
  fi
  IPA="$(ls "${IPA_DIR}"/*.ipa 2>/dev/null | head -1 || true)"
  if [[ -n "$IPA" && -f "$IPA" ]]; then
    pass "multi-game IPA written: $(basename "$IPA")"
  else
    fail "multi-game IPA written"
  fi
  MANIFEST="$(ls "${IPA_DIR}"/*.pack-manifest.txt 2>/dev/null | head -1 || true)"
  expect_file "pack manifest written" "${MANIFEST:-/nonexistent}"
  if command -v unzip >/dev/null 2>&1 && [[ -n "${IPA:-}" ]]; then
    LISTING="$(unzip -l "$IPA" 2>/dev/null || true)"
    expect_contains "IPA carries the catalogue" "Payload/3ds2apple.app/GameCatalog.json" "$LISTING"
    expect_contains "IPA carries GamePack for Pokémon Y" "Frameworks/GamePack-0004000000055E00.dylib" "$LISTING"
    expect_contains "IPA carries GamePack for Alpha Sapphire" "Frameworks/GamePack-000400000011C500.dylib" "$LISTING"
    unzip -p "$IPA" "Payload/3ds2apple.app/GameCatalog.json" > "${WORK}/embedded-catalog.json" 2>/dev/null || true
    if cmp -s "$CATALOG" "${WORK}/embedded-catalog.json"; then
      pass "embedded catalogue equals the generated schema-v2 catalogue"
    else
      fail "embedded catalogue equals the generated catalogue"
    fi
  else
    pass "skipped unzip checks (unzip not installed)"
  fi

  # Placeholder packs must be refused without the explicit preview flag.
  if "${SCRIPTS_DIR}/build-multi-game-ipa.sh" --packages-dir "$OUT/packages" --all \
      --fake-shell --pack-bin "$PACK_BIN" --out-dir "${WORK}/ipa-reject" >/dev/null 2>&1; then
    fail "placeholder packs are rejected without --allow-placeholder-dylibs"
  else
    pass "placeholder packs are rejected without --allow-placeholder-dylibs"
  fi

  # Dry run writes no IPA.
  if "${SCRIPTS_DIR}/build-multi-game-ipa.sh" --packages-dir "$OUT/packages" --all \
      --allow-placeholder-dylibs --fake-shell --dry-run --pack-bin "$PACK_BIN" \
      --out-dir "${WORK}/ipa-dry" >/dev/null 2>&1; then
    if ls "${WORK}/ipa-dry"/*.ipa >/dev/null 2>&1; then
      fail "multi-game --dry-run writes no IPA"
    else
      pass "multi-game --dry-run writes no IPA"
    fi
  else
    fail "multi-game --dry-run exits 0"
  fi

  # -------------------------------------------------------------------------
  section 4 "per-game pack script (--fake recording) and gitignore coverage"
  # -------------------------------------------------------------------------
  if "${SCRIPTS_DIR}/build-game-pack.sh" pokemon-y-00055e00 --title-id 0004000000055E00 \
      --display-name "Pokémon Y" --product-code CTR-P-EK2A --out "${WORK}/packout" \
      --fake --pack-bin "$PACK_BIN" >/dev/null 2>&1; then
    pass "build-game-pack.sh --fake records a package"
  else
    fail "build-game-pack.sh --fake records a package"
  fi
  expect_file "build-game-pack.sh writes GameInfo.json" "${WORK}/packout/packages/0004000000055E00/GameInfo.json"
  expect_file "build-game-pack.sh writes GamePack.dylib" "${WORK}/packout/packages/0004000000055E00/GamePack.dylib"
  if "${SCRIPTS_DIR}/build-game-pack.sh" pokemon-y-00055e00 --title-id 0004000000055E00 \
      --out "${WORK}/packout" --fake --dry-run --pack-bin "$PACK_BIN" 2>/dev/null | grep -q 'package_dir='; then
    pass "build-game-pack.sh --dry-run prints the plan"
  else
    fail "build-game-pack.sh --dry-run prints the plan"
  fi

  if command -v git >/dev/null 2>&1 && [[ -e "${ROOT}/.git" ]]; then
    if git -C "$ROOT" check-ignore -q "out/packages/0004000000055E00/GamePack.dylib"; then
      pass "git ignores package output (out/)"
    else
      fail "git ignores package output (out/)"
    fi
    if git -C "$ROOT" check-ignore -q "builder/pack/tests/fixtures/catalog-multi.json"; then
      fail "golden catalogue fixture is not gitignored"
    else
      pass "golden catalogue fixture is tracked (not gitignored)"
    fi
  else
    pass "skipped gitignore checks (git repository not available)"
  fi
fi

# ---------------------------------------------------------------------------
printf '\ndesktop-aot-selfcheck: %s checks, %s failure(s)\n' "$CHECKS" "$FAILURES"
if [[ "$FAILURES" -ne 0 ]]; then
  exit 1
fi
