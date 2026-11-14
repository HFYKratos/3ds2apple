#!/usr/bin/env bash
# desktop-aot.sh — shared helpers for the desktop AOT-first scripts.
#
# Sourced (never executed) by:
#   scripts/build-game-pack.sh
#   scripts/build-multi-game-ipa.sh
# and exercised by scripts/tests/desktop-aot-selfcheck.sh.
#
# The JSON schemas (GameInfo.json, GameCatalog.json) are written by the Rust
# desktop CLI (builder/pack, binary 3ds2apple-pack) so there is exactly one
# schema writer; these helpers locate that binary and inspect pack files.
#
# Compatibility: macOS system bash 3.2. No bash-4 features.

# Locate the desktop CLI. Resolution order:
#   1. --pack-bin argument passed by the caller (second argument, may be empty)
#   2. $THREEDS2APPLE_PACK (absolute path or command name)
#   3. builder/target/release/3ds2apple-pack, then builder/target/debug/...
#   4. 3ds2apple-pack on PATH
# Prints the path on success, returns 1 otherwise.
# Usage: desktop_aot_find_pack_bin ROOT [EXPLICIT]
desktop_aot_find_pack_bin() {
  local root="${1:-}" explicit="${2:-}" candidate
  if [[ -n "$explicit" ]]; then
    if [[ -x "$explicit" ]]; then printf '%s\n' "$explicit"; return 0; fi
    if command -v "$explicit" >/dev/null 2>&1; then command -v "$explicit"; return 0; fi
    return 1
  fi
  if [[ -n "${THREEDS2APPLE_PACK:-}" ]]; then
    if [[ -x "${THREEDS2APPLE_PACK}" ]]; then printf '%s\n' "${THREEDS2APPLE_PACK}"; return 0; fi
    if command -v "${THREEDS2APPLE_PACK}" >/dev/null 2>&1; then command -v "${THREEDS2APPLE_PACK}"; return 0; fi
  fi
  for candidate in \
    "${root}/builder/target/release/3ds2apple-pack" \
    "${root}/builder/target/debug/3ds2apple-pack"; do
    if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  if command -v 3ds2apple-pack >/dev/null 2>&1; then
    command -v 3ds2apple-pack
    return 0
  fi
  return 1
}

# Print the "build the CLI" hint for the caller's error message.
desktop_aot_pack_bin_hint() {
  printf 'run (cd builder && cargo build -p builder-pack) or pass --pack-bin PATH / set THREEDS2APPLE_PACK'
}

# True when the first four bytes are a Mach-O magic (thin or universal).
# Usage: desktop_aot_pack_is_macho FILE
desktop_aot_pack_is_macho() {
  local file="${1:-}" magic
  [[ -n "$file" && -f "$file" ]] || return 1
  magic="$(od -An -tx1 -N4 "$file" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    cffaedfe|feedfacf|cefaedfe|feedface|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
  esac
  return 1
}

# True when the pack is the deterministic placeholder written by --fake.
# Usage: desktop_aot_pack_is_placeholder FILE
desktop_aot_pack_is_placeholder() {
  local file="${1:-}" magic
  [[ -n "$file" && -f "$file" ]] || return 1
  magic="$(head -c 31 "$file" 2>/dev/null || true)"
  [[ "$magic" == "3ds2apple-placeholder-gamepack" ]]
}

# SHA256 of a file as lower-case hex (shasum on macOS, sha256sum on Linux).
desktop_aot_sha256() {
  local file="${1:-}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    printf 'no sha256 tool found (need sha256sum or shasum)\n' >&2
    return 1
  fi
}

# Size of a file in bytes.
desktop_aot_file_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

# Print one titleID per line from a GameCatalog.json (sorted).
desktop_aot_catalog_title_ids() {
  local catalog="${1:-}"
  python3 - "$catalog" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
games = data.get("games") or []
for game in games:
    title_id = game.get("titleID")
    if not isinstance(title_id, str):
        sys.exit("GameCatalog.json: a game has no titleID")
    sys.stdout.write(title_id + "\n")
PY
}

# MARKETING_VERSION from ios/app/project.yml (fallback IPA version).
desktop_aot_project_version() {
  local root="${1:-}"
  local project="${root}/ios/app/project.yml"
  [[ -f "$project" ]] || return 1
  sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$project" \
    | tr -d '"[:space:]' | sed -n '1p'
}

# Validate that a value is a safe IPA file-name component.
desktop_aot_valid_version() {
  local value="${1:-}"
  [[ -n "$value" ]] || return 1
  case "$value" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}
