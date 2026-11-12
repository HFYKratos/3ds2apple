#!/usr/bin/env bash
# aot-selfcheck.sh — Linux/macOS checks for the per-game AOT build scripts.
#
# Runs everywhere (no Xcode, no ROM, no macOS):
#   1. `bash -n` on every script in scripts/ and scripts/{lib,tests}/;
#   2. the aot-common unit self-check (title ID normalisation/repair, build-info
#      parsing, nm symbol matching: exact last field + no-leading-whitespace);
#   3. static regressions for the two real VM bugs:
#        - `nm ... | grep -q` under `set -o pipefail` (SIGPIPE false negative)
#          must not come back, and symbol checks must use the shared aot_nm_*
#          helpers with the single AOT_EXPECTED_RECOMP_SYMBOLS list;
#        - title IDs written to build-info.txt/manifest.txt must go through the
#          validated/normalised value, and the manifest title must round-trip;
#      plus `--help` smoke tests for the three AOT scripts (they cannot run on
#      Linux, but argument parsing must not crash);
#   4. repo hygiene: build/ROM/IPA/archives must be gitignored and untracked.
#
# Usage:
#   scripts/tests/aot-selfcheck.sh
#
# Exit status: 0 when every check passes, 1 otherwise. The simulated end-to-end
# split/incremental run lives in scripts/tests/aot-sim-harness.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"

AOT_LOG_PREFIX="aot-selfcheck"
# shellcheck source=../lib/aot-common.sh
source "${SCRIPTS_DIR}/lib/aot-common.sh"

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

AOT_SCRIPTS=(build-recomp-ios.sh build-linked-ios-lib.sh build-game-ipa.sh)

# ---------------------------------------------------------------------------
# 1. syntax
# ---------------------------------------------------------------------------
printf '[1/4] syntax (bash -n)\n'
while IFS= read -r script; do
  if bash -n "$script" 2>/dev/null; then
    pass "bash -n ${script#"${ROOT}"/}"
  else
    fail "bash -n ${script#"${ROOT}"/}"
    bash -n "$script" || true
  fi
done < <(find "$SCRIPTS_DIR" -maxdepth 2 -type f -name '*.sh' | sort)

# ---------------------------------------------------------------------------
# 2. aot-common unit self-check
# ---------------------------------------------------------------------------
printf '\n[2/4] aot-common unit self-check (title ID + nm helpers)\n'
if aot_selfcheck; then
  pass "aot-common self-check"
else
  fail "aot-common self-check"
fi

# ---------------------------------------------------------------------------
# 3. static regressions
# ---------------------------------------------------------------------------
printf '\n[3/4] static regressions\n'
for name in "${AOT_SCRIPTS[@]}"; do
  path="${SCRIPTS_DIR}/${name}"
  if [[ ! -f "$path" ]]; then
    fail "${name} exists"
    continue
  fi
  pass "${name} exists"
  [[ -x "$path" ]] || fail "${name} is executable"

  if grep -q 'source "${SCRIPT_DIR}/lib/aot-common.sh"' "$path"; then
    pass "${name} sources lib/aot-common.sh"
  else
    fail "${name} sources lib/aot-common.sh (title/nm fixes are shared)"
  fi

  # Regression: `nm ... | grep -q` gave nm SIGPIPE -> false "missing symbol"
  # under `set -o pipefail` (first real VM run, fixed in main by 737336d).
  # Command lines only; the explanatory comments are allowed to mention it.
  pipeline_hits="$(awk '!/^[[:space:]]*#/ && /nm[^|]*\|[^|]*grep/ { print FNR ": " $0 }' "$path")"
  if [[ -z "$pipeline_hits" ]]; then
    pass "${name} has no 'nm | grep' pipeline"
  else
    fail "${name} pipes nm into grep (SIGPIPE under pipefail): ${pipeline_hits}"
  fi

  # Single source of truth for the 7 generated tables.
  if grep -q 'EXPECTED_RECOMP_SYMBOLS="\$AOT_EXPECTED_RECOMP_SYMBOLS"' "$path"; then
    pass "${name} uses the shared AOT_EXPECTED_RECOMP_SYMBOLS list"
  else
    fail "${name} does not use AOT_EXPECTED_RECOMP_SYMBOLS"
  fi

  # Regression: the first VM run wrote a title ID with trailing garbage
  # ("...5E00n") into build-info.txt. Every info-file title write must use the
  # normalised $TITLE_ID, never the raw option value.
  raw_title_writes="$(grep -n 'title_id=%s' "$path" | grep -v 'TITLE_ID' || true)"
  if [[ -z "$raw_title_writes" ]]; then
    pass "${name} writes only the validated \$TITLE_ID"
  else
    fail "${name} writes an unvalidated title ID: ${raw_title_writes}"
  fi
done

# Per-script guards that must not be weakened again.
if grep -q 'refusing to write recomp-info.txt' "${SCRIPTS_DIR}/build-recomp-ios.sh"; then
  pass "build-recomp-ios.sh refuses to write an invalid title ID"
else
  fail "build-recomp-ios.sh refuses to write an invalid title ID"
fi
if grep -q 'refusing to write build-info.txt' "${SCRIPTS_DIR}/build-linked-ios-lib.sh"; then
  pass "build-linked-ios-lib.sh refuses to write an invalid title ID"
else
  fail "build-linked-ios-lib.sh refuses to write an invalid title ID"
fi
if grep -q 'manifest title_id round-trip failed' "${SCRIPTS_DIR}/build-game-ipa.sh"; then
  pass "build-game-ipa.sh self-checks the manifest title ID"
else
  fail "build-game-ipa.sh self-checks the manifest title ID"
fi

for name in "${AOT_SCRIPTS[@]}"; do
  if out="$(bash "${SCRIPTS_DIR}/${name}" --help 2>&1)" && [[ "$out" == *Usage:* ]]; then
    pass "${name} --help"
  else
    fail "${name} --help"
  fi
done

# ---------------------------------------------------------------------------
# 4. repo hygiene
# ---------------------------------------------------------------------------
printf '\n[4/4] repo hygiene\n'
if command -v git >/dev/null 2>&1 \
  && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # `git check-ignore -q` accepts a single pathname only, so loop.
  ignore_failure=0
  for ignored_path in \
    build/ios/example/libgame.a \
    IPA/example.ipa \
    ROM/example.3ds \
    scripts/tmp/example.log; do
    git -C "$ROOT" check-ignore -q -- "$ignored_path" || ignore_failure=1
  done
  if [[ "$ignore_failure" -eq 0 ]]; then
    pass "build/ROM/IPA/archives/logs are gitignored"
  else
    fail "build/ROM/IPA/archives/logs are gitignored"
  fi

  tracked_artifacts="$(git -C "$ROOT" ls-files 2>/dev/null \
    | grep -Ei '\.(3ds|cci|cia|cxi|3dsx|nsp|xci|a|o|ipa|log|dylib|sav|dsv)$' || true)"
  if [[ -z "$tracked_artifacts" ]]; then
    pass "no ROM/generated/archive/IPA artifacts tracked by git"
  else
    fail "generated artifacts tracked by git: ${tracked_artifacts}"
  fi
else
  printf '  skip (not a git checkout)\n'
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
printf '\naot-selfcheck: %s checks, %s failure(s)\n' "$CHECKS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
