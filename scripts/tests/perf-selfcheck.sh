#!/usr/bin/env bash
# perf-selfcheck.sh - static/behaviour checks for the performance work
# (task-36: the scripts/README.md performance contract, FPS readout/diagnostics,
# AOT flags, MoltenVK hook; 0.1.2: hitch attribution, run GPU/CPU split).
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

section 'Shell FPS readout and diagnostics'
check "AOTDiagnostics parses interpreted %" contains ios/app/Sources/ROMSession.swift 'interpretedPercent'
check "AOTDiagnostics exposes AOT %" contains ios/app/Sources/ROMSession.swift 'aotPercent'
check "AOTDiagnostics counts instruction fallbacks" contains ios/app/Sources/ROMSession.swift 'instructionFallbacks'
check "session exposes the FPS readout" contains ios/app/Sources/ROMSession.swift 'var fpsText'
check "GameView draws the FPS readout" contains ios/app/Sources/GameView.swift 'model.fpsText'
check "GameView tags the FPS readout for UI smoke" contains ios/app/Sources/GameView.swift 'fps-hud'
check "FPS readout is a persisted setting" contains ios/app/Sources/AppSettings.swift 'showFPS'
check "Settings exposes the FPS switch" contains ios/app/Sources/SettingsView.swift 'settings-fps-hud'
check "diagnostics report has the FPS counter state" contains ios/app/Sources/DiagnosticsReport.swift 'fps_counter='
check "diagnostics report has aot_percent" contains ios/app/Sources/DiagnosticsReport.swift 'aot_percent='
check "diagnostics report has timing shares" contains ios/app/Sources/DiagnosticsReport.swift 'timing_share_run_pct='
check "diagnostics report has frame budget" contains ios/app/Sources/DiagnosticsReport.swift 'frame_budget_used_pct='
check "diagnostics report records the removed warm-up" contains ios/app/Sources/DiagnosticsReport.swift 'warmup_note=removed-in-0.1.1'
check "en Localizable.strings has the FPS counter label" grep -Fq -- '"Show FPS counter"' ios/app/Resources/en.lproj/Localizable.strings
check "zh-Hans Localizable.strings has the FPS counter label" grep -Fq -- '"Show FPS counter"' ios/app/Resources/zh-Hans.lproj/Localizable.strings
check "en Localizable.strings has the FPS accessibility label" grep -Fq -- '"Frames per second: %@"' ios/app/Resources/en.lproj/Localizable.strings
check "zh-Hans Localizable.strings has the FPS accessibility label" grep -Fq -- '"Frames per second: %@"' ios/app/Resources/zh-Hans.lproj/Localizable.strings
# The in-game HUD only shows FPS: the old multi-segment badge and the removed
# first-load warm-up option must stay out of the UI sources.
if grep -Fq -- 'Metal backend' ios/app/Sources/SettingsView.swift; then
  fail "SettingsView still shows the Metal backend row"
else
  pass "SettingsView has no Metal backend row (About keeps it)"
fi
if grep -Fq -- 'First-load graphics warm-up' ios/app/Sources/SettingsView.swift ios/app/Sources/GameView.swift; then
  fail "a first-load warm-up option/overlay string is still in the UI sources"
else
  pass "no first-load warm-up option/overlay in the UI sources"
fi
if grep -Fq -- 'runtime-status-badge' ios/app/Sources/GameView.swift; then
  fail "GameView still carries the old runtime-status-badge"
else
  pass "the old multi-segment runtime badge is gone"
fi

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

section 'Performance contract (scripts/README.md)'
check "scripts/README.md exists" test -f scripts/README.md
for needle in 'GPL-2.0' 'reference only' 'any3ds' 'needs device' 'zk_perf' 'MVK_CONFIG_' 'AOT%' 'THREEDS2APPLE_AOT_OPT'; do
  check "scripts/README.md mentions ${needle}" grep -Fq -- "${needle}" scripts/README.md
done
check "scripts/README.md documents the experiment flags" \
  grep -Fq -- 'THREEDS2APPLE_AOT_OPT' scripts/README.md

section 'Hitch attribution and run split (0.1.2)'
check "C ABI declares the GPU-busy timer" contains ios/ZakuroBridge.h 'uint64_t zk_last_frame_gpu_busy_micros(void);'
check "lib.rs exports the GPU-busy timer" contains ios/zakuro-ios/src/lib.rs 'pub extern "C" fn zk_last_frame_gpu_busy_micros() -> u64'
check "perf.rs keeps a per-frame GPU-busy delta" contains ios/zakuro-ios/src/perf.rs 'LAST_FRAME_GPU_BUSY_MICROS'
check "perf.rs reports the last frame's command walk" contains ios/zakuro-ios/src/perf.rs 'pub fn last_frame_gpu_busy_micros()'
check "FrameTiming splits run into GPU and CPU" contains ios/app/Sources/FrameTiming.swift 'var runGPU = FramePhaseStats()'
check "FrameTiming keeps the run CPU rest" contains ios/app/Sources/FrameTiming.swift 'var runCPU = FramePhaseStats()'
check "FrameTiming records the frame interval" contains ios/app/Sources/FrameTiming.swift 'var frameInterval = FramePhaseStats()'
check "stutter gap is measured from the previous frame's end" contains ios/app/Sources/FrameTiming.swift 'let gapTicks = intervalTicks > previousWorkTicks'
check "stutter attribution splits the work item" contains ios/app/Sources/FrameTiming.swift 'runGpuTicks'
check "pipeline-compile suspects are counted" contains ios/app/Sources/FrameTiming.swift 'pipelineCompileSuspects'
check "ROMSession reads the GPU-busy timer after a frame" contains ios/app/Sources/ROMSession.swift 'zk_last_frame_gpu_busy_micros()'
check "ROMSession records the frame interval" contains ios/app/Sources/ROMSession.swift 'timingWindow.record(.frameInterval'
check "ROMSession snapshots the cache at load" contains ios/app/Sources/ROMSession.swift 'pipelineCacheAtLoad = cacheAtLoad'
check "diagnostics split run into GPU and CPU" contains ios/app/Sources/DiagnosticsReport.swift 'timing_ms_run_gpu='
check "diagnostics report the frame interval" contains ios/app/Sources/DiagnosticsReport.swift 'timing_ms_interval='
check "diagnostics report the compile suspects" contains ios/app/Sources/DiagnosticsReport.swift 'stutter_pipeline_compile_suspects='
check "diagnostics report the cache state at load" contains ios/app/Sources/DiagnosticsReport.swift 'pipeline_cache_at_load='
check "diagnostics event has interval and gpu columns" contains ios/app/Sources/DiagnosticsReport.swift 'interval=%.2f ms=%.2f work=%.2f gpu=%.2f'
check "CAMetalLayer keeps the three-drawable swapchain" contains ios/app/Sources/MetalScreenView.swift 'maximumDrawableCount = 3'
check "README documents the 0.1.2 attribution" contains ios/app/README.md 'stutter_pipeline_compile_suspects='
check "README documents the device A/B method" contains ios/app/README.md '### A/B a change on device'

section 'Licence boundary'
if grep -rlE 'any3ds' ios scripts tools --include='*.swift' --include='*.sh' --include='*.c' --include='*.rs' \
     | grep -v -- 'scripts/tests/perf-selfcheck.sh' >/dev/null 2>&1; then
  fail "code under ios/ scripts/ tools/ mentions any3ds (kernel of a GPL copy?)"
else
  pass "no code under ios/ scripts/ tools/ references any3ds"
fi
if grep -Fq -- 'any3ds' scripts/README.md; then
  pass "any3ds is cited only in the performance notes"
else
  fail "scripts/README.md does not cite any3ds"
fi

section 'Shell artifact (0.1.0+ carries MoltenVK and the HUD gate)'
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

section 'Virtual controls and screen layouts (0.1.1)'
check "control layout model exists" test -f ios/app/Sources/ControlLayout.swift
check "control layout has the Circle Pad" contains ios/app/Sources/ControlLayout.swift 'case circlePad'
check "control layout has the C-stick" contains ios/app/Sources/ControlLayout.swift 'case cStick'
check "control layout carries ZL/ZR" contains ios/app/Sources/ControlLayout.swift 'case buttonZL'
check "layout persistence is versioned" contains ios/app/Sources/ControlLayout.swift 'currentVersion'
check "per-orientation control profiles exist" contains ios/app/Sources/AppSettings.swift 'controlLayoutLandscape'
check "runtime overlay draws the editable layout" contains ios/app/Sources/VirtualControlsView.swift 'struct VirtualControlsView'
check "analog stick reports a vector (not D-pad bits)" contains ios/app/Sources/VirtualControlsView.swift 'onCirclePad'
check "layout editor can move, resize and reset" contains ios/app/Sources/ControlLayoutEditorView.swift 'Reset this control'
check "layout page is linked from Settings" contains ios/app/Sources/SettingsView.swift 'LayoutSettingsView'
check "GameView uses the editable overlay in both orientations" \
  bash -c 'n=$(grep -c "VirtualControlsView(" ios/app/Sources/GameView.swift); [ "$n" -ge 2 ]'
check "free screen layout model exists" contains ios/app/Sources/CustomScreenLayout.swift 'struct CustomScreenLayout'
check "free screen layout geometry handles the 90 degree turn" contains ios/app/Sources/CustomScreenLayout.swift 'case .counterClockwise:'
check "free screen layout editor exists" test -f ios/app/Sources/ScreenLayoutEditorView.swift
check "free layout forces the readback presentation path" contains ios/app/Sources/ROMSession.swift 'readbackPresentationRequired'
check "Metal custom zoom/position keeps the Metal layer" contains ios/app/Sources/GameView.swift 'screenLayoutMode == .customMetal'
check "C-stick ABI is declared" contains ios/ZakuroBridge.h 'void zk_set_cstick('
check "C-stick ABI is implemented" contains ios/zakuro-ios/src/lib.rs 'pub extern "C" fn zk_set_cstick'
check "C-stick is pushed before every console frame" \
  bash -c 'n=$(grep -c "zk_set_cstick(system, input.cStickX, input.cStickY)" ios/app/Sources/ROMSession.swift); [ "$n" -ge 2 ]'
check "C-stick keeps its value out of the old zk_set_input signature" \
  contains ios/zakuro-ios/src/lib.rs 'static C_STICK: Cell<(f32, f32)>'
check "en strings cover the layout editors" contains ios/app/Resources/en.lproj/Localizable.strings '"Edit portrait controls"'
check "zh-Hans strings cover the layout editors" contains ios/app/Resources/zh-Hans.lproj/Localizable.strings '"编辑竖屏按键"'
check "no GPL project text copied into the new layout code" \
  bash -c '! grep -riE "azahar|citra" ios/app/Sources/ControlLayout.swift ios/app/Sources/VirtualControlsView.swift ios/app/Sources/CustomScreenLayout.swift ios/app/Sources/ControlLayoutEditorView.swift ios/app/Sources/ScreenLayoutEditorView.swift ios/app/Sources/LayoutSettingsView.swift'

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
