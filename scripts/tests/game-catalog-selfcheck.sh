#!/usr/bin/env bash
# game-catalog-selfcheck.sh — Linux/macOS checks for the GameCatalog pipeline.
#
# Runs everywhere (no Xcode, no ROM, no macOS). Covers:
#   1. `bash -n` for the scripts that generate/validate/package the catalog;
#   2. GameCatalog.json generation + schema validation with fake data in a temp
#      directory (never writes to the repository):
#        empty shell catalog, one-game Pokémon Y catalog, JSON string escaping,
#        and every malformed-catalog rejection the build must fail on;
#   3. install/cleanup semantics: a pre-existing catalog is restored, a generated
#      one is removed, so `git status` stays clean after any build;
#   4. static wiring checks: the build/package scripts source the shared helper,
#      the shell build writes an empty catalog, the per-game build generates the
#      one-game catalog, verifies it inside the .app and removes it, the IPA name
#      is 3ds2apple-<game>-<version>.ipa, package-ipa.sh validates + reports it,
#      .gitignore covers the generated file and project.yml bundles Resources/;
#   5. `--help` smoke tests (they must not need macOS or a ROM).
#
# Usage:
#   scripts/tests/game-catalog-selfcheck.sh
#
# Exit status: 0 when every check passes, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

# shellcheck source=../lib/game-catalog.sh
source "${SCRIPTS_DIR}/lib/game-catalog.sh"

CHECKS=0
FAILURES=0

pass() {
  CHECKS=$((CHECKS + 1))
  printf '  ok   %s\n' "$1"
}
fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf '  FAIL %s\n' "$1" >&2
}
expect_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
expect_file() { # label path
  if [[ -s "$2" ]]; then pass "$1"; else fail "$1 (missing or empty: $2)"; fi
}
expect_contains() { # label needle haystack
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing '$2')"; fi
}
expect_no_file() { # label path
  if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1 (unexpected file: $2)"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/game-catalog-selfcheck.XXXXXX")"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

CATALOG_SH="${SCRIPTS_DIR}/build-ios-app.sh"
GAME_IPA_SH="${SCRIPTS_DIR}/build-game-ipa.sh"
PACKAGE_SH="${SCRIPTS_DIR}/package-ipa.sh"
HELPER=${SCRIPTS_DIR}/lib/game-catalog.sh

# ---------------------------------------------------------------------------
# 1. syntax
# ---------------------------------------------------------------------------
printf '[1/5] syntax (bash -n)\n'
for script in "$CATALOG_SH" "$GAME_IPA_SH" "$PACKAGE_SH" "$HELPER" "${SCRIPTS_DIR}/tests/aot-sim-harness.sh"; do
  if [[ -f "$script" ]] && bash -n "$script" 2>/dev/null; then
    pass "bash -n ${script#"$ROOT"/}"
  else
    fail "bash -n ${script#"$ROOT"/}"
    bash -n "$script" || true
  fi
done

# ---------------------------------------------------------------------------
# 2. generation + validation with fake data (temp dir only)
# ---------------------------------------------------------------------------
printf '\n[2/5] catalog generation and schema validation\n'
EMPTY_CATALOG="${WORK}/empty.json"
if game_catalog_write_empty "$EMPTY_CATALOG"; then
  pass "write empty catalog"
else
  fail "write empty catalog ($GAME_CATALOG_ERROR)"
fi
expect_eq "empty catalog is byte-exact" '{"schemaVersion":1,"games":[]}' "$(cat "$EMPTY_CATALOG")"
if game_catalog_validate "$EMPTY_CATALOG"; then
  pass "validate empty catalog"
  expect_eq "empty catalog games count" '0' "$GAME_CATALOG_COUNT"
  expect_eq "empty catalog AOT count" '0' "$GAME_CATALOG_AOT_COUNT"
  expect_contains "empty summary says interpreter shell" 'interpreter shell' "$(game_catalog_summary_text)"
else
  fail "validate empty catalog ($GAME_CATALOG_ERROR)"
fi

GAME_CATALOG="${WORK}/pokemon-y.json"
if game_catalog_write_game "$GAME_CATALOG" 0004000000055E00 "Pokémon Y" "CTR-P-EKJA" 1; then
  pass "write one-game catalog (Pokémon Y)"
else
  fail "write one-game catalog ($GAME_CATALOG_ERROR)"
fi
if game_catalog_validate "$GAME_CATALOG"; then
  pass "validate one-game catalog"
  expect_eq "one-game catalog games count" '1' "$GAME_CATALOG_COUNT"
  expect_eq "one-game catalog AOT count" '1' "$GAME_CATALOG_AOT_COUNT"
  expect_eq "one-game AOT line" 'Pokémon Y (0004000000055E00)' "$GAME_CATALOG_AOT_LINES"
  expect_contains "one-game summary has games count" 'games=1' "$(game_catalog_summary_text)"
  expect_contains "one-game summary has AOT title" 'Pokémon Y (0004000000055E00)' "$(game_catalog_summary_text)"
else
  fail "validate one-game catalog ($GAME_CATALOG_ERROR)"
fi
# The Swift side decodes these exact keys, so assert them with a real JSON parser.
if python3 - "$GAME_CATALOG" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
assert data["schemaVersion"] == 1
assert len(data["games"]) == 1
game = data["games"][0]
assert game["titleID"] == "0004000000055E00"
assert game["displayName"] == "Pokémon Y"
assert game["productCode"] == "CTR-P-EKJA"
assert game["aot"] is True
assert game["aotVersion"] == 1
assert game["notes"] == ""
PY
then
  pass "generated JSON matches the GameCatalog.swift schema"
else
  fail "generated JSON matches the GameCatalog.swift schema"
fi

# JSON string escaping: round-trip a display name with a quote and a backslash.
ESCAPED="${WORK}/escaped.json"
if game_catalog_write_game "$ESCAPED" 0004000000055E00 'A "quoted" \\ name' "" 2; then
  pass "write catalog with JSON-special characters"
else
  fail "write catalog with JSON-special characters ($GAME_CATALOG_ERROR)"
fi
if python3 - "$ESCAPED" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    game = json.load(handle)["games"][0]
backslash = chr(92)
expected = 'A "quoted" ' + backslash * 2 + " name"
assert game["displayName"] == expected, game["displayName"]
assert game["displayName"].count('"') == 2
assert game["displayName"].count(backslash) == 2
assert game["aotVersion"] == 2
PY
then
  pass "JSON escaping round-trips through a real parser"
else
  fail "JSON escaping round-trips through a real parser"
fi

# Invalid catalogs must be rejected (the build must not ship them).
expect_reject() { # label expected-message-fragment file
  if game_catalog_validate "$3"; then
    fail "$1 (unexpectedly accepted)"
  elif [[ "$GAME_CATALOG_ERROR" == *"$2"* ]]; then
    pass "$1"
  else
    fail "$1 (message '$GAME_CATALOG_ERROR' lacks '$2')"
  fi
}

printf '{"schemaVersion":1,"games":[{"titleID":"0004000000055e00","displayName":"x","productCode":"","aot":false,"aotVersion":0,"notes":""}]}' > "${WORK}/bad-lower.json"
expect_reject "reject lower-case title ID" "upper-case hex digits" "${WORK}/bad-lower.json"
printf '{"schemaVersion":3,"games":[]}' > "${WORK}/bad-schema.json"
expect_reject "reject schemaVersion 3" "unsupported schemaVersion" "${WORK}/bad-schema.json"
printf '{"schemaVersion":1,"games":[{"titleID":"0004000000055E00","displayName":"x","productCode":"","aot":true,"aotVersion":0,"notes":""}]}' > "${WORK}/bad-aot-version.json"
expect_reject "reject aot=true with aotVersion 0" "aotVersion" "${WORK}/bad-aot-version.json"
printf '{"schemaVersion":1,"games":[{"titleID":"0004000000055E00","displayName":"x","productCode":"","aot":false,"aotVersion":0,"notes":""},{"titleID":"0004000000055E00","displayName":"y","productCode":"","aot":false,"aotVersion":0,"notes":""}]}' > "${WORK}/bad-duplicate.json"
expect_reject "reject duplicate title IDs" "duplicate titleID" "${WORK}/bad-duplicate.json"
printf '{"schemaVersion":1,"games":[{"titleID":"0004000000055E00","displayName":"x","aot":true,"aotVersion":1,"notes":""}]}' > "${WORK}/bad-missing.json"
expect_reject "reject a game missing productCode" "missing productCode" "${WORK}/bad-missing.json"
printf '{"schemaVersion":1,"games":[]' > "${WORK}/bad-json.json"
expect_reject "reject malformed JSON" "not valid JSON" "${WORK}/bad-json.json"
printf '[]' > "${WORK}/bad-top.json"
expect_reject "reject a top-level array" "must be a JSON object" "${WORK}/bad-top.json"
printf '{"schemaVersion":1,"games":"nope"}' > "${WORK}/bad-games.json"
expect_reject "reject a non-array games field" "games must be an array" "${WORK}/bad-games.json"
printf '{"schemaVersion":1,"games":[{"titleID":"0004000000055E00","displayName":"x","productCode":"","aot":"yes","aotVersion":1,"notes":""}]}' > "${WORK}/bad-aot.json"
expect_reject "reject a non-boolean aot flag" "aot must be a boolean" "${WORK}/bad-aot.json"
if game_catalog_validate "${WORK}/does-not-exist.json"; then
  fail "reject a missing catalog file (unexpectedly accepted)"
else
  expect_contains "missing catalog message mentions the path" 'not found' "$GAME_CATALOG_ERROR"
fi

# Bundled game data (schema v2 romFile): valid forms accepted, unsafe forms
# rejected, and the staged app bundle must actually contain the file.
ROM_CATALOG="${WORK}/rom-catalog.json"
python3 - "$ROM_CATALOG" <<'PY'
import json
import sys

destination = sys.argv[1]
catalog = {
    "schemaVersion": 2,
    "games": [{
        "titleID": "0004000000055E00",
        "displayName": "Pokemon Y",
        "productCode": "CTR-P-EK2A",
        "packFile": "Frameworks/GamePack-0004000000055E00.dylib",
        "romFile": "Roms/0004000000055E00.cci",
        "aot": True,
        "aotVersion": 1,
        "packABIVersion": 1,
        "notes": "",
    }],
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(catalog, handle, ensure_ascii=False, separators=(",", ":"))
    handle.write("\n")
PY
if game_catalog_validate "$ROM_CATALOG"; then
  pass "validator accepts a bundle-relative romFile"
else
  fail "validator accepts a bundle-relative romFile ($GAME_CATALOG_ERROR)"
fi
for bad_rom in "Roms/000400000011C500.cci" "Roms/0004000000055E00.cia" "../Roms/0004000000055E00.cci" "Roms/0004000000055E00.cci/extra"; do
  python3 - "$ROM_CATALOG" "${WORK}/bad-rom.json" "$bad_rom" <<'PY'
import json
import sys

source, destination, rom = sys.argv[1], sys.argv[2], sys.argv[3]
with open(source, "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["games"][0]["romFile"] = rom
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
    handle.write("\n")
PY
  expect_reject "reject romFile '$bad_rom'" "romFile" "${WORK}/bad-rom.json"
done

# game_catalog_verify_rom_files: every catalogue romFile must be staged.
ROM_APP="${WORK}/rom-app"
mkdir -p "${ROM_APP}/Roms"
printf 'fake rom bytes' > "${ROM_APP}/Roms/0004000000055E00.cci"
if game_catalog_verify_rom_files "$ROM_CATALOG" "$ROM_APP"; then
  expect_eq "bundled ROM count is reported" '1' "$GAME_CATALOG_ROM_COUNT"
  pass "verify_rom_files accepts a staged ROM"
else
  fail "verify_rom_files accepts a staged ROM ($GAME_CATALOG_ERROR)"
fi
if [[ "$(game_catalog_rom_files "$ROM_CATALOG")" == *"Roms/0004000000055E00.cci"* ]]; then
  pass "rom_files lists the catalogue romFile"
else
  fail "rom_files lists the catalogue romFile"
fi
rm -f "${ROM_APP}/Roms/0004000000055E00.cci"
if game_catalog_verify_rom_files "$ROM_CATALOG" "$ROM_APP"; then
  fail "verify_rom_files rejects a missing staged ROM"
else
  expect_contains "missing-ROM message names the file" 'missing bundled game data' "$GAME_CATALOG_ERROR"
fi
if game_catalog_verify_rom_files "$ROM_CATALOG" "${WORK}/no-app"; then
  fail "verify_rom_files rejects a missing app bundle"
else
  pass "verify_rom_files rejects a missing app bundle"
fi

# ---------------------------------------------------------------------------
# 3. install / cleanup (the build must never leave the generated file behind)
# ---------------------------------------------------------------------------
printf '\n[3/5] install and cleanup\n'
FAKE_APP="${WORK}/repo/ios/app"
mkdir -p "${FAKE_APP}/Resources"
CATALOG_DEST="${FAKE_APP}/Resources/GameCatalog.json"

printf 'hand-written catalog\n' > "$CATALOG_DEST"
if game_catalog_install "$GAME_CATALOG" "$CATALOG_DEST"; then
  pass "install catalog into app resources"
else
  fail "install catalog into app resources ($GAME_CATALOG_ERROR)"
fi
expect_contains "installed catalog replaces the file" '"titleID":"0004000000055E00"' "$(cat "$CATALOG_DEST")"
game_catalog_cleanup
expect_eq "cleanup restores a pre-existing catalog" 'hand-written catalog' "$(cat "$CATALOG_DEST")"
rm -f -- "$CATALOG_DEST"
game_catalog_install "$GAME_CATALOG" "$CATALOG_DEST" >/dev/null
game_catalog_cleanup
expect_no_file "cleanup removes a generated catalog" "$CATALOG_DEST"

mkdir -p "${WORK}/bundle"
cp "$GAME_CATALOG" "${WORK}/bundle/GameCatalog.json"
if found="$(game_catalog_find_in_app "${WORK}/bundle")"; then
  expect_eq "find catalog at the app bundle root" "${WORK}/bundle/GameCatalog.json" "$found"
else
  fail "find catalog at the app bundle root"
fi
mkdir -p "${WORK}/bundle2/Resources"
cp "$GAME_CATALOG" "${WORK}/bundle2/Resources/GameCatalog.json"
if found="$(game_catalog_find_in_app "${WORK}/bundle2")"; then
  expect_eq "find catalog under Resources/ (hand-made bundle)" "${WORK}/bundle2/Resources/GameCatalog.json" "$found"
else
  fail "find catalog under Resources/ (hand-made bundle)"
fi
if game_catalog_find_in_app "${WORK}/no-bundle" >/dev/null; then
  fail "no catalog found in a bundle without one"
else
  pass "no catalog found in a bundle without one"
fi

# ---------------------------------------------------------------------------
# 4. static wiring checks
# ---------------------------------------------------------------------------
printf '\n[4/5] build/package script wiring\n'
wire_check() { # label file needle
  if grep -Fq -- "$3" "$2"; then pass "$1"; else fail "$1 (missing '$3' in ${2#"$ROOT"/})"; fi
}

wire_check "build-ios-app.sh sources the catalog helper" "$CATALOG_SH" 'source "${SCRIPT_DIR}/lib/game-catalog.sh"'
wire_check "build-ios-app.sh offers --game-catalog" "$CATALOG_SH" '--game-catalog)'
wire_check "build-ios-app.sh writes an empty catalog by default" "$CATALOG_SH" 'game_catalog_write_empty'
wire_check "build-ios-app.sh installs the catalog before xcodegen" "$CATALOG_SH" 'game_catalog_install'
wire_check "build-ios-app.sh cleans the catalog on exit" "$CATALOG_SH" 'cleanup_build_catalog'
wire_check "build-ios-app.sh keeps the Metal HUD injection" "$CATALOG_SH" 'MetalHudEnabled'
wire_check "build-ios-app.sh checks the catalog inside the app" "$CATALOG_SH" 'game_catalog_find_in_app'
wire_check "build-ios-app.sh never compiles on device / stays ROM-free" "$CATALOG_SH" 'no ROM'

wire_check "build-game-ipa.sh sources the catalog helper" "$GAME_IPA_SH" 'source "${SCRIPT_DIR}/lib/game-catalog.sh"'
wire_check "build-game-ipa.sh has --title-id" "$GAME_IPA_SH" '--title-id)'
wire_check "build-game-ipa.sh has --display-name" "$GAME_IPA_SH" '--display-name)'
wire_check "build-game-ipa.sh has --product-code" "$GAME_IPA_SH" '--product-code)'
wire_check "build-game-ipa.sh has --aot-version" "$GAME_IPA_SH" '--aot-version)'
wire_check "build-game-ipa.sh has --ipa-version" "$GAME_IPA_SH" '--ipa-version)'
wire_check "build-game-ipa.sh generates the one-game catalog" "$GAME_IPA_SH" 'game_catalog_write_game'
wire_check "build-game-ipa.sh installs the catalog before the build" "$GAME_IPA_SH" 'game_catalog_install'
wire_check "build-game-ipa.sh verifies the catalog in the app" "$GAME_IPA_SH" 'CATALOG_IN_APP='
wire_check "build-game-ipa.sh removes the catalog on exit" "$GAME_IPA_SH" 'game_catalog_cleanup'
wire_check "build-game-ipa.sh defaults to 3ds2apple-<game>-<version>.ipa" "$GAME_IPA_SH" '3ds2apple-${NAME}-${IPA_VERSION}'
wire_check "build-game-ipa.sh keeps the manifest title ID self-check" "$GAME_IPA_SH" 'manifest title_id round-trip failed'
wire_check "build-game-ipa.sh still delegates packaging" "$GAME_IPA_SH" 'scripts/package-ipa.sh" "$APP_PATH" --name "$IPA_NAME"'

wire_check "package-ipa.sh sources the catalog helper" "$PACKAGE_SH" 'source "${SCRIPT_DIR}/lib/game-catalog.sh"'
wire_check "package-ipa.sh validates the bundle catalog" "$PACKAGE_SH" 'game_catalog_validate'
wire_check "package-ipa.sh verifies bundled romFile files" "$PACKAGE_SH" 'game_catalog_verify_rom_files'
wire_check "package-ipa.sh reports games/AOT" "$PACKAGE_SH" 'CATALOG_REPORT'
wire_check "package-ipa.sh keeps --name/--out-dir compatibility" "$PACKAGE_SH" '--out-dir'

if grep -Fq '/ios/app/Resources/GameCatalog.json' "${ROOT}/.gitignore"; then
  pass ".gitignore covers the generated catalog"
else
  fail ".gitignore covers the generated catalog"
fi
if command -v git >/dev/null 2>&1 && [[ -e "${ROOT}/.git" ]]; then
  if git -C "$ROOT" check-ignore -q -- 'ios/app/Resources/GameCatalog.json'; then
    pass "git ignores ios/app/Resources/GameCatalog.json"
  else
    fail "git ignores ios/app/Resources/GameCatalog.json"
  fi
else
  printf '  skip (not a git checkout)\n'
fi
if grep -Fq -- '- path: Resources' "${ROOT}/ios/app/project.yml" \
    && grep -Fq 'buildPhase: resources' "${ROOT}/ios/app/project.yml"; then
  pass "project.yml bundles Resources/ (catalog ships in the .app)"
else
  fail "project.yml bundles Resources/ (catalog ships in the .app)"
fi
if [[ -s "${ROOT}/docs/build.md" ]] && grep -Fq 'GameCatalog.json' "${ROOT}/docs/build.md"; then
  pass "docs/build.md documents GameCatalog.json"
else
  fail "docs/build.md documents GameCatalog.json"
fi
if [[ -s "${ROOT}/scripts/AOT_BUILD.md" ]] && grep -Fq 'GameCatalog.json' "${ROOT}/scripts/AOT_BUILD.md"; then
  pass "scripts/AOT_BUILD.md documents the catalog asset step"
else
  fail "scripts/AOT_BUILD.md documents the catalog asset step"
fi

# ---------------------------------------------------------------------------
# 5. --help smoke tests
# ---------------------------------------------------------------------------
printf '\n[5/5] --help smoke tests\n'
if out="$(bash "$CATALOG_SH" --help 2>&1)" && [[ "$out" == *"--game-catalog"* ]]; then
  pass "build-ios-app.sh --help mentions --game-catalog"
else
  fail "build-ios-app.sh --help mentions --game-catalog"
fi
if out="$(bash "$GAME_IPA_SH" --help 2>&1)" && [[ "$out" == *"--product-code"* ]] && [[ "$out" == *"3ds2apple-<name>-<version>"* ]]; then
  pass "build-game-ipa.sh --help mentions --product-code and the IPA name"
else
  fail "build-game-ipa.sh --help mentions --product-code and the IPA name"
fi
if out="$(bash "$PACKAGE_SH" --help 2>&1)" && [[ "$out" == *"GameCatalog.json"* ]]; then
  pass "package-ipa.sh --help mentions GameCatalog.json"
else
  fail "package-ipa.sh --help mentions GameCatalog.json"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
printf '\ngame-catalog-selfcheck: %s checks, %s failure(s)\n' "$CHECKS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
