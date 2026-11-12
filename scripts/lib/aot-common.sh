#!/usr/bin/env bash
# aot-common.sh — shared helpers for the per-game AOT build scripts.
#
# Sourced by:
#   scripts/build-recomp-ios.sh
#   scripts/build-linked-ios-lib.sh
#   scripts/build-game-ipa.sh
# and unit-tested on Linux by scripts/tests/aot-selfcheck.sh.
#
# It only defines functions/constants: sourcing never exits, builds, requires
# macOS or prints banners, so it stays testable on Linux. Callers pass their
# log prefix through AOT_LOG_PREFIX before sourcing.
#
# Compatibility: system bash 3.2 on macOS. No bash-4 features (no mapfile,
# no ${var,,}, no associative arrays).
#
# Two real bugs from the first VM run are fixed here for all three scripts:
#  1. title IDs read from hand-edited/stale build-info.txt can carry junk such
#     as a trailing "n" from an over-escaped `printf '...\\n'` ("...5E00n").
#     aot_normalize_title_id repairs that, prints a warning and is the *only*
#     way title IDs enter build-info.txt / manifest.txt.
#  2. `nm ... | grep -q` fails with SIGPIPE (141) under `set -o pipefail` as
#     soon as grep finds a match, so a valid symbol could be reported missing.
#     aot_nm_* dumps nm output to a file once and searches the file; matching is
#     anchored to the whole last field, so `_recomp_abi_extra` never satisfies
#     `_recomp_abi` (the old prefix bug).
#
# The seven generated tables the linked library references and libgame.a must
# export (scripts/AOT_BUILD.md §2.1/§8.2). Keep in sync with ios/zakuro-ios + recomp ABI.
AOT_EXPECTED_RECOMP_SYMBOLS="recomp_abi recomp_generation recomp_entry_count recomp_entries recomp_module_count recomp_modules recomp_origins"

# ---------------------------------------------------------------------------
# logging / small utilities
# ---------------------------------------------------------------------------

aot_warn() {
  printf '[%s] warning: %s\n' "${AOT_LOG_PREFIX:-aot}" "$*" >&2
}

# Trim leading/trailing whitespace (including CR) without external tools.
aot_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# True for exactly 16 upper-case hex digits (no 0x prefix). The build scripts
# and manifest.txt use the upper-case form from scripts/AOT_BUILD.md ("0004000000055E00").
aot_validate_title_id() {
  local value="$1"
  [[ "${#value}" -eq 16 ]] || return 1
  case "$value" in
    *[!0-9A-F]*) return 1 ;;
  esac
  return 0
}

# Print the canonical upper-case 16-hex title ID for VALUE, or return 1.
# Accepted/cleaned input: surrounding whitespace/CR, a 0x prefix, lower case,
# and the historical over-escaped-printf junk ("0004000000055E00n" or the
# literal two characters backslash+n). Anything else is rejected instead of
# silently truncated: "0004000000055E00FF" is *not* repaired because its suffix
# contains hex digits.
aot_normalize_title_id() {
  local raw="$1" value stripped candidate rest
  value="$(printf '%s' "$raw" | tr -d '[:space:]')"
  value="${value#0x}"
  value="${value#0X}"
  value="$(printf '%s' "$value" | tr 'a-f' 'A-F')"
  if aot_validate_title_id "$value"; then
    printf '%s' "$value"
    return 0
  fi
  # Historical corruption (2026-11-12 VM run): build-info.txt ended with the
  # two literal characters `\n`, i.e. "...5E00\n", from an over-escaped printf.
  # Drop literal backslashes and retry before treating the value as broken.
  stripped="$(printf '%s' "$value" | tr -d '\\')"
  if [[ "$stripped" != "$value" ]]; then
    stripped="$(printf '%s' "$stripped" | tr 'a-f' 'A-F')"
    if aot_validate_title_id "$stripped"; then
      aot_warn "stripped stray backslash(es) from title ID '$raw' -> '$stripped'"
      printf '%s' "$stripped"
      return 0
    fi
  fi
  # Repair "16 hex + non-hex junk" (e.g. the trailing 'n' left by `\n`), but
  # only when the suffix has no hex digits, so a real 17/18-hex typo still
  # fails validation and asks for --title-id.
  candidate="${stripped:0:16}"
  if aot_validate_title_id "$candidate"; then
    rest="${stripped:16}"
    case "$rest" in
      ''|*[0-9A-F]*) : ;;             # empty or has hex digits: not repairable
      *[!0-9A-F]*)                    # pure non-hex junk: repair, warn loudly
        aot_warn "repaired corrupted title ID '$raw' -> '$candidate'"
        printf '%s' "$candidate"
        return 0
        ;;
    esac
  fi
  return 1
}

# Read `key=value` from a build-info/manifest file. Strips CR/whitespace.
aot_info_value() {
  local file="$1" key="$2" line
  [[ -f "$file" ]] || return 1
  line="$(grep -m 1 -E "^${key}=" "$file" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  line="${line#*=}"
  line="${line%$'\r'}"
  aot_trim "$line"
}

# Extract a 0x<16 hex> title ID literal from 3dsrecomp's src/main.rs.
aot_title_id_from_rust() {
  local file="$1" raw
  [[ -f "$file" ]] || return 1
  # sed, not `head`: sed consumes the whole file, so nothing gets SIGPIPE.
  raw="$(grep -oE '0x[0-9A-Fa-f]{16}' "$file" | sed -n '1p' || true)"
  [[ -n "$raw" ]] || return 1
  raw="${raw#0x}"
  raw="${raw#0X}"
  aot_normalize_title_id "$raw"
}

# Resolve the game title ID from explicit option -> build-info -> recomp-info
# -> generated src/main.rs. Sets AOT_TITLE_ID / AOT_TITLE_SOURCE; returns 1 if
# no valid title ID can be found. A mismatch between two valid sources is
# reported as a warning (usually the linked library was not rebuilt).
aot_resolve_title_id() {
  local root="$1" name="$2" explicit="${3:-}"
  local cand norm found="" found_src="" other
  AOT_TITLE_ID=""
  AOT_TITLE_SOURCE=""

  if [[ -n "$explicit" ]]; then
    if norm="$(aot_normalize_title_id "$explicit")"; then
      AOT_TITLE_ID="$norm"
      AOT_TITLE_SOURCE="--title-id"
      return 0
    fi
    aot_warn "--title-id is not a valid 16 hex digit title ID: '$explicit'"
    return 1
  fi

  # 1) build-info.txt (written by build-linked-ios-lib.sh; authoritative for
  #    what the linked libzakuro_ios.a was built with)
  cand="$(aot_info_value "${root}/build/ios/${name}/build-info.txt" title_id || true)"
  if [[ -n "$cand" ]]; then
    if norm="$(aot_normalize_title_id "$cand")"; then
      found="$norm"
      found_src="build/ios/${name}/build-info.txt"
    else
      aot_warn "invalid title_id='$cand' in build/ios/${name}/build-info.txt (ignored)"
    fi
  fi

  # 2) recomp-info.txt (written by build-recomp-ios.sh / adopted archive)
  other="$(aot_info_value "${root}/build/game/${name}/recomp-info.txt" title_id || true)"
  if [[ -n "$other" ]]; then
    if norm="$(aot_normalize_title_id "$other")"; then
      if [[ -z "$found" ]]; then
        found="$norm"
        found_src="build/game/${name}/recomp-info.txt"
      elif [[ "$norm" != "$found" ]]; then
        aot_warn "title ID mismatch: $found_src has '$found' but build/game/${name}/recomp-info.txt has '$norm'; the linked library may not match the generated code (rebuild both for the same title)"
      fi
    else
      aot_warn "invalid title_id='$other' in build/game/${name}/recomp-info.txt (ignored)"
    fi
  fi

  # 3) generated desktop project from 3dsrecomp port
  if [[ -z "$found" ]]; then
    if norm="$(aot_title_id_from_rust "${root}/build/game/${name}/src/main.rs" || true)"; then
      found="$norm"
      found_src="build/game/${name}/src/main.rs"
    fi
  fi

  [[ -n "$found" ]] || return 1
  AOT_TITLE_ID="$found"
  AOT_TITLE_SOURCE="$found_src"
  return 0
}

# Validate a short game name used as an untrusted path component.
aot_is_valid_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  case "$name" in
    .|..|*/*|.*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [[ "${name:0:1}" == [A-Za-z0-9] ]] || return 1
  return 0
}

aot_sha256() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    sha256sum "$file" | awk '{print $1}'
  fi
}

# True when xcrun lipo -info reports arm64. Sets AOT_LIPO_INFO for messages.
aot_lipo_arch_ok() {
  local file="$1" info
  AOT_LIPO_INFO=""
  info="$(xcrun lipo -info "$file" 2>&1)" || {
    AOT_LIPO_INFO="$info"
    return 1
  }
  AOT_LIPO_INFO="$info"
  case "$info" in
    *arm64*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# nm helpers (pipefail/SIGPIPE-safe, exact last-field matching)
# ---------------------------------------------------------------------------

# Dump `nm <flags...> FILE` to OUT once. Returns 1 when no output was produced.
# Callers reuse the dump for several symbol checks instead of piping nm into
# `grep -q` (which made grep exit early -> nm got SIGPIPE -> pipefail reported
# a false missing symbol on the first real VM run).
aot_nm_dump() {
  local file="$1" out="$2"
  shift 2
  nm "$@" "$file" > "$out" 2>/dev/null || true
  [[ -s "$out" ]]
}

# True when SYMBOL appears as the whole last whitespace-separated field of any
# line in an nm dump. `(^|[[:space:]])` accepts nm's "address type symbol" and
# bare "U symbol" forms; the `$` anchor prevents `_recomp_abi_extra` from
# satisfying `_recomp_abi` (prefix-matching regression).
aot_nm_has_symbol() {
  local dump="$1" symbol="$2"
  [[ -n "$symbol" && -f "$dump" ]] || return 1
  grep -qE "(^|[[:space:]])${symbol}$" "$dump"
}

# Print the sorted unique last fields of an nm dump that start with PREFIX.
aot_nm_symbols_with_prefix() {
  local dump="$1" prefix="$2"
  [[ -f "$dump" ]] || return 1
  # awk reads the whole file and sort consumes everything: no early-exit pipe.
  awk -v p="$prefix" 'NF && index($NF, p) == 1 { print $NF }' "$dump" | sort -u
}

# ---------------------------------------------------------------------------
# self-check (also invoked by scripts/tests/aot-selfcheck.sh on Linux)
# ---------------------------------------------------------------------------

aot_selfcheck() {
  local failures=0 checks=0 work
  work="$(mktemp -d "${TMPDIR:-/tmp}/aot-selfcheck.XXXXXX")" || {
    aot_warn "could not create a temp dir for the self-check"
    return 1
  }

  _aot_sc_pass() {
    checks=$((checks + 1))
    printf '  ok   %s\n' "$1"
  }
  _aot_sc_fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf '  FAIL %s\n' "$1" >&2
  }
  _aot_sc_eq() { # label expected actual
    if [[ "$2" == "$3" ]]; then _aot_sc_pass "$1"; else
      _aot_sc_fail "$1 (expected '$2', got '$3')"
    fi
  }
  _aot_sc_true() { # label status
    if [[ "$2" -eq 0 ]]; then _aot_sc_pass "$1"; else _aot_sc_fail "$1"; fi
  }
  _aot_sc_false() { # label status
    if [[ "$2" -ne 0 ]]; then _aot_sc_pass "$1"; else _aot_sc_fail "$1"; fi
  }

  printf 'aot-common self-check\n'

  # --- title ID normalisation -------------------------------------------------
  local tid
  if tid="$(aot_normalize_title_id '0004000000055E00')"; then
    _aot_sc_eq "normalize: plain" '0004000000055E00' "$tid"
  else
    _aot_sc_fail "normalize: plain (unexpected failure)"
  fi
  tid="$(aot_normalize_title_id ' 0004000000055e00 ' || true)"
  _aot_sc_eq "normalize: trim + lower -> upper" '0004000000055E00' "$tid"
  tid="$(aot_normalize_title_id '0x0004000000055E00' || true)"
  _aot_sc_eq "normalize: 0x prefix" '0004000000055E00' "$tid"
  tid="$(aot_normalize_title_id '0004000000055E00n' 2>/dev/null || true)"
  _aot_sc_eq "normalize: repair trailing n (over-escaped printf)" '0004000000055E00' "$tid"
  tid="$(aot_normalize_title_id '0004000000055E00\n' 2>/dev/null || true)"
  _aot_sc_eq "normalize: repair literal backslash-n" '0004000000055E00' "$tid"
  tid="$(aot_normalize_title_id '0004000000055E00'"$(printf '\r')" || true)"
  _aot_sc_eq "normalize: CRLF-stripped value" '0004000000055E00' "$tid"
  aot_normalize_title_id '0004000000055E0' >/dev/null 2>&1
  _aot_sc_false "normalize: reject 15 hex digits" "$?"
  aot_normalize_title_id '0004000000055E0G' >/dev/null 2>&1
  _aot_sc_false "normalize: reject non-hex inside the 16-digit window" "$?"
  aot_normalize_title_id '0004000000055E00FF' >/dev/null 2>&1
  _aot_sc_false "normalize: refuse truncating a 18-hex value" "$?"
  aot_normalize_title_id '' >/dev/null 2>&1
  _aot_sc_false "normalize: reject empty" "$?"
  if aot_validate_title_id '0004000000055E00'; then _aot_sc_pass "validate: canonical"; else _aot_sc_fail "validate: canonical"; fi
  if aot_validate_title_id '0004000000055e00'; then _aot_sc_fail "validate: lowercase must be rejected"; else _aot_sc_pass "validate: lowercase rejected"; fi

  # --- build-info parsing -----------------------------------------------------
  printf 'title_id=0004000000055E00\r\nrecomp_rev=abc1234\n' > "$work/build-info.txt"
  _aot_sc_eq "info_value: CRLF line trimmed" '0004000000055E00' \
    "$(aot_info_value "$work/build-info.txt" title_id || echo '<missing>')"
  _aot_sc_eq "info_value: second key" 'abc1234' \
    "$(aot_info_value "$work/build-info.txt" recomp_rev || echo '<missing>')"
  aot_info_value "$work/build-info.txt" nope >/dev/null 2>&1
  _aot_sc_false "info_value: missing key returns 1" "$?"

  # --- src/main.rs extraction -------------------------------------------------
  printf 'const PROGRAM_ID: u64 = 0x0004000000055E00;\nconst X: u64 = 0x0004000000055E0A;\n' \
    > "$work/main.rs"
  _aot_sc_eq "title_id_from_rust: first literal" '0004000000055E00' \
    "$(aot_title_id_from_rust "$work/main.rs" || echo '<missing>')"

  # --- title resolution -------------------------------------------------------
  mkdir -p "$work/root/build/ios/pokemon-y" "$work/root/build/game/pokemon-y"
  printf 'title_id=0004000000055E00n\n' > "$work/root/build/ios/pokemon-y/build-info.txt"
  if aot_resolve_title_id "$work/root" pokemon-y ''; then
    _aot_sc_eq "resolve: repaired build-info title" '0004000000055E00' "$AOT_TITLE_ID"
    _aot_sc_eq "resolve: source is build-info" 'build/ios/pokemon-y/build-info.txt' "$AOT_TITLE_SOURCE"
  else
    _aot_sc_fail "resolve: repaired build-info title"
  fi
  if aot_resolve_title_id "$work/root" pokemon-y '0004000000055E00'; then
    _aot_sc_eq "resolve: explicit --title-id wins" '--title-id' "$AOT_TITLE_SOURCE"
  else
    _aot_sc_fail "resolve: explicit --title-id wins"
  fi
  aot_resolve_title_id "$work/root" unknown-game '' >/dev/null 2>&1
  _aot_sc_false "resolve: fails when no source exists" "$?"

  # --- nm dump / symbol matching (no nm binary needed) ------------------------
  cat > "$work/nm-archive.txt" <<'NM'
Archive : librecomp.a
librecomp.a(recomp.o):
0000000000000000 T _recomp_abi
0000000000000008 T _recomp_generation
0000000000000010 T _recomp_entry_count
0000000000000018 T _recomp_entries
0000000000000020 T _recomp_module_count
0000000000000028 T _recomp_modules
0000000000000030 T _recomp_origins
0000000000000038 T _recomp_abi_extra_decoy
_recomp_no_address_type_bare
NM
  if aot_nm_has_symbol "$work/nm-archive.txt" '_recomp_abi'; then
    _aot_sc_pass "nm: address/type line matches"
  else
    _aot_sc_fail "nm: address/type line matches"
  fi
  if aot_nm_has_symbol "$work/nm-archive.txt" '_recomp_no_address_type_bare'; then
    _aot_sc_pass "nm: line without leading whitespace matches"
  else
    _aot_sc_fail "nm: line without leading whitespace matches"
  fi
  if aot_nm_has_symbol "$work/nm-archive.txt" '_recomp_generation_extra'; then
    _aot_sc_fail "nm: prefix decoy must not match"
  else
    _aot_sc_pass "nm: prefix decoy does not match"
  fi
  local sym count
  sym="$(aot_nm_symbols_with_prefix "$work/nm-archive.txt" '_recomp_')"
  count="$(printf '%s\n' "$sym" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  _aot_sc_eq "nm: collected names include decoy + bare line" '9' "$count"
  _aot_sc_eq "nm: first collected table" '_recomp_abi' "$(printf '%s\n' "$sym" | sed -n '1p')"

  # --- misc ------------------------------------------------------------------
  printf 'payload\n' > "$work/hash.txt"
  local digest
  digest="$(aot_sha256 "$work/hash.txt")"
  _aot_sc_eq "sha256: digest length" '64' "${#digest}"
  if aot_is_valid_name 'pokemon-y'; then _aot_sc_pass "name: valid"; else _aot_sc_fail "name: valid"; fi
  if aot_is_valid_name '../etc'; then _aot_sc_fail "name: path traversal rejected"; else _aot_sc_pass "name: path traversal rejected"; fi
  if aot_is_valid_name '.hidden'; then _aot_sc_fail "name: dotfile rejected"; else _aot_sc_pass "name: dotfile rejected"; fi

  rm -rf -- "$work"

  printf 'aot-common self-check: %s checks, %s failure(s)\n' "$checks" "$failures"
  [[ "$failures" -eq 0 ]]
}