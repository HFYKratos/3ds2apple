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

# Print the CPU architecture of a thin Mach-O ("arm64" or "x86_64"), or return 1.
# `file` is used instead of lipo because the helper also runs on Linux (the
# script selfchecks), and a GamePack is always a thin slice.
# Usage: desktop_aot_pack_arch FILE
desktop_aot_pack_arch() {
  local file="${1:-}" info
  [[ -n "$file" && -f "$file" ]] || return 1
  info="$(file -b "$file" 2>/dev/null || true)"
  case "$info" in
    *Mach-O*arm64*) printf 'arm64\n'; return 0 ;;
    *Mach-O*x86_64*) printf 'x86_64\n'; return 0 ;;
    *) return 1 ;;
  esac
}

# Expected CPU architecture for a clang target triple (arm64-apple-ios...,
# x86_64-apple-ios...-simulator). Prints the arch or returns 1.
# Usage: desktop_aot_target_arch TRIPLE
desktop_aot_target_arch() {
  case "${1:-}" in
    arm64*) printf 'arm64\n' ;;
    x86_64*) printf 'x86_64\n' ;;
    *) return 1 ;;
  esac
}

# True when a Mach-O's slice matches the given clang target triple's CPU.
# Usage: desktop_aot_pack_matches_target FILE TRIPLE
desktop_aot_pack_matches_target() {
  local file="${1:-}" triple="${2:-}" actual expected
  actual="$(desktop_aot_pack_arch "$file")" || return 1
  expected="$(desktop_aot_target_arch "$triple")" || return 1
  [[ "$actual" == "$expected" ]]
}

# True when the dylib exports the required GamePack ABI pack symbols
# (zk_gamepack_title_id / zk_gamepack_abi_version / zk_gamepack_register).
# The registration hook is required: a pack without it cannot hand its AOT code
# to the runtime. Used when adopting an already-built dylib.
# Usage: desktop_aot_pack_exports_gamepack FILE
desktop_aot_pack_exports_gamepack() {
  local file="${1:-}" symbols symbol
  [[ -n "$file" && -f "$file" ]] || return 1
  symbols="$(nm -gU "$file" 2>/dev/null || nm -g "$file" 2>/dev/null || true)"
  [[ -n "$symbols" ]] || return 1
  for symbol in _zk_gamepack_title_id _zk_gamepack_abi_version _zk_gamepack_register; do
    printf '%s\n' "$symbols" | grep -q " T $symbol$" || return 1
  done
  return 0
}

# Print the bundled-ROM record of a package from its GameInfo.json as
# "<file>\t<bytes>\t<sha256>", or print nothing when the package has no bundled
# ROM. Returns 1 when the manifest is unreadable/incomplete.
# Usage: desktop_aot_package_rom PACKAGE_DIR
desktop_aot_package_rom() {
  local dir="${1:-}"
  [[ -n "$dir" && -d "$dir" ]] || return 1
  python3 - "$dir" <<'PY'
import json
import os
import sys

directory = sys.argv[1]
path = os.path.join(directory, "GameInfo.json")
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except OSError as exc:
    sys.exit("desktop_aot_package_rom: cannot read %s: %s" % (path, exc))
file_name = data.get("romFile")
if file_name is None:
    sys.exit(0)
byte_count = data.get("romBytes")
sha256 = data.get("romSha256")
if (not isinstance(file_name, str) or not file_name
        or not isinstance(byte_count, int) or isinstance(byte_count, bool)
        or not isinstance(sha256, str) or len(sha256) != 64):
    sys.exit("desktop_aot_package_rom: %s has an incomplete romFile/romBytes/romSha256 record" % path)
sys.stdout.write("%s\t%d\t%s\n" % (file_name, byte_count, sha256))
PY
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
