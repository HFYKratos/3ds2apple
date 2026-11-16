#!/usr/bin/env bash
# perf-selfcheck.sh - static/behaviour checks for the performance work
# (task-36: docs/performance.md, badge/diagnostics, AOT flags, MoltenVK hook).
#
# Runs on a plain Linux host: no Xcode, no clang, no ROM. It checks the
# contracts this change introduced and the shell artifact it builds on.
#
# Exit status: 0 all checks pass, 1 one or more failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

checks=0
failures=0
pass() { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n' "$1" >&2; }
check() { # description command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "${description}"; else fail "${description}"; fi
}
contains() { # file needle
  grep -Fq -- "$2" "$1"
}
section() { printf '\n%s\n' "$1"; }

section 'AOT build flags (scripts/lib/aot-common.sh)'
for script in scripts/lib/aot-common.sh scripts/build-recomp-ios.sh \
              scripts/build-game-pack.sh tools/winbuild/build-gamepack.sh; do
  check "bash -n ${script}" bash -n "${script}"
done
default_flags="$(bash -c 'source scripts/lib/aot-common.sh; aot_codegen_flags')"
if [[ "${default_flags}" == "-O2 -ffp-contract=off -fno-math-errno" ]]; then
  pass "default codegen flags are the documented -O2 baseline"
else
  fail "default codegen flags changed: '${default_flags}'"
fi
o3_flags="$(bash -c 'source scripts/lib/aot-common.sh; THREEDS2APPLE_AOT_OPT=O3; aot_codegen_flags')"
check "THREEDS2APPLE_AOT_OPT=O3 selects -O3" grep -Fq -- "-O3 -ffp-contract=off" <<<"${o3_flags}"
lto_flags="$(bash -c 'source scripts/lib/aot-common.sh; THREEDS2APPLE_AOT_LTO=1; aot_codegen_flags')"
check "THREEDS2APPLE_AOT_LTO=1 adds -flto" grep -Fq -- "-flto" <<<"${lto_flags}"
fm_flags="$(bash -c 'source scripts/lib/aot-common.sh; THREEDS2APPLE_AOT_FAST_MATH=1; aot_codegen_flags' 2>/dev/null)"
check "THREEDS2APPLE_AOT_FAST_MATH=1 adds -ffast-math" grep -Fq -- "-ffast-math" <<<"${fm_flags}"
bad_flags="$(bash -c 'source scripts/lib/aot-common.sh; THREEDS2APPLE_AOT_OPT=nonsense; aot_codegen_flags' 2>/dev/null)"
check "invalid THREEDS2APPLE_AOT_OPT falls back to -O2" grep -Fq -- "-O2 -ffp-contract=off" <<<"${bad_flags}"
check "build-recomp-ios.sh uses the shared helper" \
  contains scripts/build-recomp-ios.sh 'aot_codegen_flags'
check "build-game-pack.sh uses the shared helper" \
  contains scripts/build-game-pack.sh 'aot_codegen_flags'
check "winbuild has --opt-level" contains tools/winbuild/build-gamepack.sh '--opt-level)'
check "winbuild has --lto" contains tools/winbuild/build-gamepack.sh '--lto)'
check "winbuild has --fast-math" contains tools/winbuild/build-gamepack.sh '--fast-math)'
check "winbuild threads CODEGEN_CFLAGS into the compile" \
  contains tools/winbuild/build-gamepack.sh 'CODEGEN_CFLAGS'
check "winbuild default opt level is O2" grep -Fq -- 'OPT_LEVEL="${OPT_LEVEL_ARG:-O2}"' tools/winbuild/build-gamepack.sh

section 'Shell badge and diagnostics'
check "AOTDiagnostics parses interpreted %" contains ios/app/Sources/ROMSession.swift 'interpretedPercent'
check "AOTDiagnostics exposes AOT %" contains ios/app/Sources/ROMSession.swift 'aotPercent'
check "AOTDiagnostics counts instruction fallbacks" contains ios/app/Sources/ROMSession.swift 'instructionFallbacks'
check "badge state carries the per-frame row" contains ios/app/Sources/ROMSession.swift 'perfText'
check "GameView renders the per-frame row" contains ios/app/Sources/GameView.swift 'state.perfText'
check "diagnostics report has aot_percent" contains ios/app/Sources/DiagnosticsReport.swift 'aot_percent='
check "diagnostics report has timing shares" contains ios/app/Sources/DiagnosticsReport.swift 'timing_share_run_pct='
check "diagnostics report has frame budget" contains ios/app/Sources/DiagnosticsReport.swift 'frame_budget_used_pct='
check "en Localizable.strings has AOT %@" grep -Fq -- '"AOT %@"' ios/app/Resources/en.lproj/Localizable.strings
check "zh-Hans Localizable.strings has AOT %@" grep -Fq -- '"AOT %@"' ios/app/Resources/zh-Hans.lproj/Localizable.strings
check "en Localizable.strings has the CPU/present/read row" grep -Fq -- '"CPU %@ ms · present %@ ms · read %@ ms"' ios/app/Resources/en.lproj/Localizable.strings
check "zh-Hans Localizable.strings has the CPU/present/read row" grep -Fq -- '"CPU %@ ms · present %@ ms · read %@ ms"' ios/app/Resources/zh-Hans.lproj/Localizable.strings

section 'MoltenVK tuning hook (default off)'
check "MoltenVKTuning exists" test -f ios/app/Sources/MoltenVKTuning.swift
check "hook is gated by THREEDS2APPLE_MVK_CONFIG" contains ios/app/Sources/MoltenVKTuning.swift 'THREEDS2APPLE_MVK_CONFIG'
check "hook sets env before the first device in App.init" \
  awk '/MoltenVKTuning.applyFromEnvironment\(\)/{found=NR} /MetalHUD.apply\(enabled:/{hud=NR} END{exit !(found && hud && found < hud)}' \
      ios/app/Sources/App.swift
# Every allow-listed name starts with MVK_CONFIG_ (a typo would be ignored by MoltenVK).
if awk '/static let supportedKeys/,/]/' ios/app/Sources/MoltenVKTuning.swift | grep -oE '"[A-Z0-9_]+"' | grep -vq '^"MVK_CONFIG_'; then
  fail "MoltenVKTuning allow-list has a non-MVK_CONFIG_ key"
else
  pass "MoltenVKTuning allow-list only contains MVK_CONFIG_* names"
fi
check "normal launch keeps framework defaults (no unconditional setenv)" \
  grep -Fq -- 'applied.isEmpty' ios/app/Sources/MoltenVKTuning.swift

section 'Performance document contract'
check "docs/performance.md exists" test -f docs/performance.md
for needle in 'GPL-2.0' 'reference only' 'any3ds' 'needs device' 'zk_perf' 'MVK_CONFIG_' 'AOT%' 'THREEDS2APPLE_AOT_OPT'; do
  check "docs/performance.md mentions ${needle}" grep -Fq -- "${needle}" docs/performance.md
done
check "scripts/AOT_BUILD.md documents the experiment flags" \
  grep -Fq -- 'THREEDS2APPLE_AOT_OPT' scripts/AOT_BUILD.md

section 'Licence boundary'
if grep -rlE 'any3ds' ios scripts tools --include='*.swift' --include='*.sh' --include='*.c' --include='*.rs' \
     | grep -v -- 'scripts/tests/perf-selfcheck.sh' >/dev/null 2>&1; then
  fail "code under ios/ scripts/ tools/ mentions any3ds (kernel of a GPL copy?)"
else
  pass "no code under ios/ scripts/ tools/ references any3ds"
fi
if grep -Fq -- 'any3ds' docs/performance.md; then
  pass "any3ds is cited only in the performance document"
else
  fail "docs/performance.md does not cite any3ds"
fi

section 'Shell artifact (0.2.2+ carries MoltenVK and the HUD gate)'
IPA="out/shell/3ds2apple-shell.ipa"
if [[ -f "${IPA}" ]]; then
  check "shell IPA contains MoltenVK.framework" \
    bash -c 'unzip -l "$1" | grep -q "Frameworks/MoltenVK.framework/MoltenVK"' _ "${IPA}"
  if command -v python3 >/dev/null 2>&1; then
    hud="$(unzip -p "${IPA}" Payload/3ds2apple.app/Info.plist 2>/dev/null | \
      python3 -c 'import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(d.get("MetalHudEnabled"))' 2>/dev/null || true)"
    if [[ "${hud}" == "True" ]]; then pass "shell Info.plist enables MetalHudEnabled"; else
      fail "shell Info.plist MetalHudEnabled is '${hud}' (expected True)"; fi
  else
    printf '  skip shell Info.plist check (python3 missing)\n'
  fi
else
  printf '  skip shell artifact checks (out/shell/3ds2apple-shell.ipa absent)\n'
fi

section 'Repository hygiene'
if git status --porcelain | grep -E '^(.. )?(ROM/|IPA/|build/)' >/dev/null 2>&1; then
  fail "ROM/, IPA/ or build/ has changes staged/untracked"
else
  pass "no ROM/, IPA/ or build/ artifacts in git status"
fi
if git status --porcelain | grep -E '\.(cci|3ds|cxi)$' >/dev/null 2>&1; then
  fail "a ROM file shows up in git status"
else
  pass "no ROM files in git status"
fi

printf '\nperf-selfcheck: %s checks, %s failure(s)\n' "${checks}" "${failures}"
[[ "${failures}" -eq 0 ]]
