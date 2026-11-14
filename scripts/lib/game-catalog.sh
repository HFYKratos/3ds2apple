#!/usr/bin/env bash
# game-catalog.sh — GameCatalog.json helpers shared by the build/package scripts.
#
# Sourced (never executed) by:
#   scripts/build-ios-app.sh
#   scripts/build-game-ipa.sh
#   scripts/package-ipa.sh
# and unit-tested on Linux/macOS by scripts/tests/game-catalog-selfcheck.sh.
#
# GameCatalog.json is a BUILD ARTIFACT that ships inside the app bundle. It tells
# the shell which title IDs have AOT code linked in, so the phone only selects and
# launches a game; it never recompiles anything on device (S2ARM-style split).
# The schema is fixed and decoded by ios/app/Sources/GameCatalog.swift:
#
#   {"schemaVersion":1,"games":[
#     {"titleID":"0004000000055E00","displayName":"Pokémon Y",
#      "productCode":"CTR-P-EKJA","aot":true,"aotVersion":1,"notes":""}]}
#
# Schema 2 (the AOT-first pipeline) additionally carries the per-game pack
# ("packFile") and, when the package bundles the user ROM, the app-bundle ROM
# path ("romFile": "Roms/<TITLE_ID>.<cci|3ds|ncch|cxi>").
#
# Writing uses printf only; validation uses python3 (listed as a prerequisite in
# docs/build.md), so no JSON library is needed by the build itself.
#
# Compatibility: macOS system bash 3.2. No bash-4 features (no mapfile, no
# ${var,,}, no associative arrays).
#
# State set by game_catalog_validate (read after it returns 0):
#   GAME_CATALOG_COUNT        number of games
#   GAME_CATALOG_AOT_COUNT    number of games with "aot": true
#   GAME_CATALOG_AOT_LINES    one "<displayName> (<titleID>)" line per AOT game
#   GAME_CATALOG_ERROR        human-readable reason when it returns 1
# State used by game_catalog_install/game_catalog_cleanup:
#   GAME_CATALOG_INSTALLED    path installed into the app resources
#   GAME_CATALOG_BACKUP       saved copy of a pre-existing catalog (restored)

GAME_CATALOG_SCHEMA_VERSION=1

# Path inside the app dir (ios/app/<this>) / app bundle root file name.
GAME_CATALOG_RELATIVE_PATH="Resources/GameCatalog.json"
GAME_CATALOG_BUNDLE_NAME="GameCatalog.json"

# True for exactly 16 upper-case hex digits (canonical title ID form).
game_catalog_title_id_ok() {
  local value="${1:-}"
  [[ "${#value}" -eq 16 ]] || return 1
  case "$value" in
    *[!0-9A-F]*) return 1 ;;
  esac
  return 0
}

# Escape a one-line string for a JSON string literal.
game_catalog_json_escape() {
  printf '%s' "${1:-}" | sed -e 's/[[:cntrl:]]/ /g' -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Write an empty catalog (interpreter shell: no AOT games).
# Usage: game_catalog_write_empty DEST
game_catalog_write_empty() {
  local dest="${1:-}" dir
  GAME_CATALOG_ERROR=""
  if [[ -z "$dest" ]]; then
    GAME_CATALOG_ERROR="no destination path"
    return 1
  fi
  dir="$(dirname "$dest")"
  mkdir -p -- "$dir" || { GAME_CATALOG_ERROR="cannot create $dir"; return 1; }
  printf '{"schemaVersion":%s,"games":[]}\n' "$GAME_CATALOG_SCHEMA_VERSION" > "$dest" \
    || { GAME_CATALOG_ERROR="cannot write $dest"; return 1; }
  return 0
}

# Write a one-game catalog (used by the per-game AOT build).
# Usage: game_catalog_write_game DEST TITLE_ID DISPLAY_NAME PRODUCT_CODE AOT_VERSION [NOTES]
game_catalog_write_game() {
  local dest="${1:-}" title_id="${2:-}" display_name="${3:-}"
  local product_code="${4:-}" aot_version="${5:-1}" notes="${6:-}"
  local dir escaped_name escaped_code escaped_notes
  GAME_CATALOG_ERROR=""
  if [[ -z "$dest" ]]; then
    GAME_CATALOG_ERROR="no destination path"
    return 1
  fi
  game_catalog_title_id_ok "$title_id" \
    || { GAME_CATALOG_ERROR="title ID must be 16 upper-case hex digits (got '$title_id')"; return 1; }
  if [[ -z "$display_name" ]]; then
    GAME_CATALOG_ERROR="display name must not be empty"
    return 1
  fi
  case "$display_name" in
    *$'\n'*|*$'\r'*) GAME_CATALOG_ERROR="display name must be a single line"; return 1 ;;
  esac
  case "$aot_version" in
    ''|*[!0-9]*) GAME_CATALOG_ERROR="aotVersion must be a non-negative integer (got '$aot_version')"; return 1 ;;
  esac
  escaped_name="$(game_catalog_json_escape "$display_name")"
  escaped_code="$(game_catalog_json_escape "$product_code")"
  escaped_notes="$(game_catalog_json_escape "$notes")"
  dir="$(dirname "$dest")"
  mkdir -p -- "$dir" || { GAME_CATALOG_ERROR="cannot create $dir"; return 1; }
  printf '{"schemaVersion":%s,"games":[{"titleID":"%s","displayName":"%s","productCode":"%s","aot":true,"aotVersion":%s,"notes":"%s"}]}\n' \
    "$GAME_CATALOG_SCHEMA_VERSION" "$title_id" "$escaped_name" "$escaped_code" \
    "$aot_version" "$escaped_notes" > "$dest" \
    || { GAME_CATALOG_ERROR="cannot write $dest"; return 1; }
  return 0
}

# Validate a catalog file against the fixed schema. Prints nothing on success;
# sets GAME_CATALOG_COUNT / GAME_CATALOG_AOT_COUNT / GAME_CATALOG_AOT_LINES.
# Makes GAME_CATALOG_ERROR available on failure.
# Usage: game_catalog_validate FILE
game_catalog_validate() {
  local file="${1:-}" output
  GAME_CATALOG_COUNT=0
  GAME_CATALOG_AOT_COUNT=0
  GAME_CATALOG_AOT_LINES=""
  GAME_CATALOG_ERROR=""
  if [[ -z "$file" ]]; then
    GAME_CATALOG_ERROR="no catalog file given"
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    GAME_CATALOG_ERROR="catalog file not found: $file"
    return 1
  fi
  if [[ ! -s "$file" ]]; then
    GAME_CATALOG_ERROR="catalog file is empty: $file"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    GAME_CATALOG_ERROR="python3 not found in PATH; it is required to validate GameCatalog.json (see docs/build.md requirements)"
    return 1
  fi

  # The validator is the only JSON parser in the pipeline; it also enforces the
  # contract GameCatalog.swift relies on (required keys, types, canonical title
  # IDs) so a malformed catalog fails the build instead of the app.
  if ! output="$(python3 - "$file" 2>&1 <<'PY'
import json
import sys


def fail(message):
    sys.stderr.write("GameCatalog.json: %s" % message)
    sys.exit(1)


try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
except OSError as exc:
    fail("cannot read: %s" % exc)
except ValueError as exc:
    fail("not valid JSON: %s" % exc)

if not isinstance(data, dict):
    fail("top level must be a JSON object")

schema_version = data.get("schemaVersion")
if isinstance(schema_version, bool) or not isinstance(schema_version, int):
    fail("schemaVersion must be the integer 1 or 2")
if schema_version not in (1, 2):
    fail("unsupported schemaVersion %r (expected 1 for the legacy statically linked"
         " single-game catalog, or 2 for the multi-game package catalog)" % (schema_version,))

games = data.get("games")
if not isinstance(games, list):
    fail("games must be an array")

required = ("titleID", "displayName", "productCode", "aot", "aotVersion", "notes")
seen = set()
aot_lines = []
for index, game in enumerate(games):
    where = "games[%d]" % index
    if not isinstance(game, dict):
        fail("%s must be an object" % where)
    missing = [key for key in required if key not in game]
    if missing:
        fail("%s is missing %s" % (where, ", ".join(missing)))
    title_id = game["titleID"]
    if not isinstance(title_id, str) or len(title_id) != 16 \
            or any(char not in "0123456789ABCDEF" for char in title_id):
        fail("%s.titleID must be 16 upper-case hex digits (got %r)" % (where, title_id))
    if title_id in seen:
        fail("duplicate titleID %s" % title_id)
    seen.add(title_id)
    display_name = game["displayName"]
    if not isinstance(display_name, str) or not display_name.strip():
        fail("%s.displayName must be a non-empty string" % where)
    if any(ord(char) < 32 for char in display_name):
        fail("%s.displayName must not contain control characters" % where)
    product_code = game["productCode"]
    if not isinstance(product_code, str) or len(product_code) > 32 \
            or any(ord(char) < 32 for char in product_code):
        fail("%s.productCode must be a string of at most 32 printable characters" % where)
    aot = game["aot"]
    if not isinstance(aot, bool):
        fail("%s.aot must be a boolean" % where)
    aot_version = game["aotVersion"]
    if isinstance(aot_version, bool) or not isinstance(aot_version, int) or aot_version < 0:
        fail("%s.aotVersion must be a non-negative integer" % where)
    if aot and aot_version < 1:
        fail("%s.aot is true but aotVersion is %d (must be >= 1)" % (where, aot_version))
    notes = game["notes"]
    if not isinstance(notes, str) or len(notes) > 500:
        fail("%s.notes must be a string of at most 500 characters" % where)
    # Multi-game extension (schemaVersion 2): every entry written by the desktop
    # pipeline names its app-bundle-relative AOT pack. An absent packFile is only
    # valid for the legacy static-link schemaVersion 1 catalog (see
    # ios/app/Sources/GameCatalog.swift + AOTPackageLoader.swift).
    if schema_version == 2 and not game.get("packFile"):
        fail("%s: schemaVersion 2 requires packFile 'Frameworks/GamePack-%s.dylib'"
             % (where, title_id))
    if "packFile" in game:
        pack_file = game["packFile"]
        expected_pack = "Frameworks/GamePack-%s.dylib" % title_id
        if not isinstance(pack_file, str) or pack_file != expected_pack:
            fail("%s.packFile must be '%s' (got %r)" % (where, expected_pack, pack_file))
        pack_abi = game.get("packABIVersion")
        if pack_abi is not None:
            if isinstance(pack_abi, bool) or not isinstance(pack_abi, int) or pack_abi < 1:
                fail("%s.packABIVersion must be an integer >= 1 (got %r)" % (where, pack_abi))
        registration = game.get("registrationSymbol")
        if registration is not None:
            if not isinstance(registration, str) or not registration \
                    or not all(char.isalnum() or char == "_" for char in registration):
                fail("%s.registrationSymbol must be a C identifier (got %r)"
                     % (where, registration))
        cover = game.get("coverFile")
        if cover is not None:
            expected_cover = "Covers/%s.png" % title_id
            if not isinstance(cover, str) or cover != expected_cover:
                fail("%s.coverFile must be '%s' (got %r)" % (where, expected_cover, cover))
        # Optional bundled game data (task-11): a package that carries the user
        # ROM names it here as Roms/<TITLE_ID>.<ext>; the shell hands that file
        # to zk_create(). Absent means "no bundled ROM" (the game cannot start
        # without an on-device import, which the AOT-first flow forbids).
        rom_file = game.get("romFile")
        if rom_file is not None:
            expected_stem = "Roms/%s." % title_id
            allowed_extensions = ("cci", "3ds", "ncch", "cxi")
            if (not isinstance(rom_file, str) or not rom_file.startswith(expected_stem)
                    or rom_file[len(expected_stem):] not in allowed_extensions):
                fail("%s.romFile must be 'Roms/%s.<cci|3ds|ncch|cxi>' (got %r)"
                     % (where, title_id, rom_file))
    if aot:
        aot_lines.append("%s (%s)" % (display_name, title_id))

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass
print("count=%d" % len(games))
print("aot_count=%d" % len(aot_lines))
for line in aot_lines:
    print("aot=%s" % line)
PY
)"; then
    GAME_CATALOG_ERROR="$output"
    return 1
  fi

  GAME_CATALOG_COUNT="$(printf '%s\n' "$output" | sed -n 's/^count=//p' | sed -n '1p')"
  GAME_CATALOG_AOT_COUNT="$(printf '%s\n' "$output" | sed -n 's/^aot_count=//p' | sed -n '1p')"
  GAME_CATALOG_AOT_LINES="$(printf '%s\n' "$output" | sed -n 's/^aot=//p')"
  case "$GAME_CATALOG_COUNT" in
    ''|*[!0-9]*) GAME_CATALOG_ERROR="could not parse the validator output"; return 1 ;;
  esac
  case "$GAME_CATALOG_AOT_COUNT" in
    ''|*[!0-9]*) GAME_CATALOG_ERROR="could not parse the validator output"; return 1 ;;
  esac
  return 0
}

# One-line human readable summary, e.g.
#   games=1; AOT: Pokémon Y (0004000000055E00)
#   games=0; interpreter shell (no AOT games)
game_catalog_summary_text() {
  local joined=""
  if [[ "${GAME_CATALOG_COUNT:-0}" -eq 0 ]]; then
    printf 'games=0; interpreter shell (no AOT games)'
    return 0
  fi
  if [[ "${GAME_CATALOG_AOT_COUNT:-0}" -eq 0 ]]; then
    printf 'games=%s; no AOT games (interpreter only)' "$GAME_CATALOG_COUNT"
    return 0
  fi
  joined="$(printf '%s\n' "$GAME_CATALOG_AOT_LINES" \
    | awk 'NF { printf "%s%s", (n++ ? "; " : ""), $0 }')"
  printf 'games=%s; AOT: %s' "$GAME_CATALOG_COUNT" "$joined"
}

# Install SOURCE as the build-time catalog in the app resources (DEST). A
# pre-existing file is backed up and restored by game_catalog_cleanup; no
# generated catalog is ever left behind (.gitignore covers it as a safeguard).
# Usage: game_catalog_install SOURCE DEST
game_catalog_install() {
  local source="${1:-}" destination="${2:-}"
  GAME_CATALOG_ERROR=""
  GAME_CATALOG_INSTALLED=""
  GAME_CATALOG_BACKUP=""
  if [[ -z "$source" || ! -f "$source" ]]; then
    GAME_CATALOG_ERROR="catalog to install not found: $source"
    return 1
  fi
  if [[ -z "$destination" ]]; then
    GAME_CATALOG_ERROR="no catalog destination given"
    return 1
  fi
  mkdir -p "$(dirname "$destination")" \
    || { GAME_CATALOG_ERROR="cannot create the destination directory for $destination"; return 1; }
  if [[ -e "$destination" ]]; then
    GAME_CATALOG_BACKUP="$(mktemp "${TMPDIR:-/tmp}/3ds2apple-catalog-backup.XXXXXX")" \
      || { GAME_CATALOG_BACKUP=""; GAME_CATALOG_ERROR="mktemp failed"; return 1; }
    if ! cp -f -- "$destination" "$GAME_CATALOG_BACKUP"; then
      rm -f -- "$GAME_CATALOG_BACKUP"
      GAME_CATALOG_BACKUP=""
      GAME_CATALOG_ERROR="cannot back up the existing catalog: $destination"
      return 1
    fi
  fi
  # Record the target before copying so the EXIT trap removes a partial file.
  GAME_CATALOG_INSTALLED="$destination"
  if ! cp -f -- "$source" "$destination"; then
    GAME_CATALOG_ERROR="cannot copy $source -> $destination"
    return 1
  fi
  return 0
}

# Remove the build-time catalog (or restore the pre-existing one). Idempotent.
game_catalog_cleanup() {
  if [[ -n "${GAME_CATALOG_INSTALLED:-}" ]]; then
    if [[ -n "${GAME_CATALOG_BACKUP:-}" && -f "$GAME_CATALOG_BACKUP" ]]; then
      mv -f -- "$GAME_CATALOG_BACKUP" "$GAME_CATALOG_INSTALLED" 2>/dev/null || true
    else
      rm -f -- "$GAME_CATALOG_INSTALLED" 2>/dev/null || true
    fi
    GAME_CATALOG_INSTALLED=""
    GAME_CATALOG_BACKUP=""
  fi
  if [[ -n "${GAME_CATALOG_BACKUP:-}" ]]; then
    rm -f -- "$GAME_CATALOG_BACKUP" 2>/dev/null || true
    GAME_CATALOG_BACKUP=""
  fi
  return 0
}

# Print the path of the catalog inside a built .app bundle (bundle root, or
# Resources/ for hand-made bundles), or return 1 when the app has none.
# Usage: game_catalog_find_in_app APP_PATH
game_catalog_find_in_app() {
  local app_dir="${1:-}" candidate
  [[ -n "$app_dir" && -d "$app_dir" ]] || return 1
  for candidate in \
    "$app_dir/$GAME_CATALOG_BUNDLE_NAME" \
    "$app_dir/$GAME_CATALOG_RELATIVE_PATH"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}