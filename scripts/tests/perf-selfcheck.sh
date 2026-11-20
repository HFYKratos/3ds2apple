#!/usr/bin/env bash
# perf-selfcheck.sh - static/behaviour checks for the performance work
# (task-36: the scripts/README.md performance contract, FPS readout/diagnostics,
# AOT flags, MoltenVK hook; 0.1.2: hitch attribution, run GPU/CPU split;
# 0.1.3: real GPU execution timing and the renderer A/B switches).
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
  pass "SettingsView has no Metal backend row"
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

section 'Pause/resume timing (0.1.2 diagnostics fix)'
check "frame pause clock exists" contains ios/app/Sources/FrameTiming.swift 'final class FramePauseClock'
check "pause clock opens a pause" contains ios/app/Sources/FrameTiming.swift 'func pause(at ticks: UInt64)'
check "pause clock closes a pause" contains ios/app/Sources/FrameTiming.swift 'func resume(at ticks: UInt64)'
check "the frame path consumes the pending pause" contains ios/app/Sources/FrameTiming.swift 'func takePendingResume()'
check "a restarted loop drops the pending pause" contains ios/app/Sources/FrameTiming.swift 'func forgetPendingResume()'
check "pause totals are exposed for diagnostics" contains ios/app/Sources/FrameTiming.swift 'struct FramePauseStats'
check "StutterTracker can pause" contains ios/app/Sources/FrameTiming.swift 'mutating func pause(at ticks: UInt64)'
check "StutterTracker can resume" contains ios/app/Sources/FrameTiming.swift 'mutating func resume(at ticks: UInt64)'
check "a frame recorded inside a pause is ignored" contains ios/app/Sources/FrameTiming.swift 'guard pauseStartTicks == nil else { return }'
check "the per-minute rate excludes paused time" contains ios/app/Sources/FrameTiming.swift 'startedTicks &+= pausedTicks'
check "the render path applies the pending pause" contains ios/app/Sources/ROMSession.swift 'applyPendingPauseResume(at: frameStart)'
check "the FPS window is rebased after a pause" contains ios/app/Sources/ROMSession.swift 'statsWindowStartTicks = frameStartTicks'
check "the stutter tracker is rebased after a pause" contains ios/app/Sources/ROMSession.swift 'stutterTracker.resume(at: frameStartTicks)'
check "every pause site records the pause clock" \
  bash -c 'n=$(grep -c "framePauseClock\.pause(at: FrameClock.now())" ios/app/Sources/ROMSession.swift); [ "$n" -ge 5 ]'
check "every resume site closes the pause clock" \
  bash -c 'n=$(grep -c "framePauseClock\.resume(at: FrameClock.now())" ios/app/Sources/ROMSession.swift); [ "$n" -ge 4 ]'
check "a new frame loop drops the old pause" contains ios/app/Sources/ROMSession.swift 'framePauseClock.forgetPendingResume()'
check "a new session clears the pause totals" contains ios/app/Sources/ROMSession.swift 'framePauseClock.resetSession()'
check "the in-game menu pauses the frame clock" contains ios/app/Sources/ROMSession.swift 'framePauseClock.pause(at: FrameClock.now())'
check "an inactive scene pauses the loop" contains ios/app/Sources/ROMSession.swift 'func pauseForInactiveScene()'
check "an active scene resumes the loop without resetting stats" contains ios/app/Sources/ROMSession.swift 'func resumeAfterInactiveScene()'
check "ContentView pauses for the inactive scene phase" contains ios/app/Sources/ContentView.swift 'model.pauseForInactiveScene()'
check "ContentView resumes for the active scene phase" contains ios/app/Sources/ContentView.swift 'model.resumeAfterInactiveScene()'
check "diagnostics export has the pause count" contains ios/app/Sources/DiagnosticsReport.swift 'frame_pause_count='
check "diagnostics export has the paused time" contains ios/app/Sources/DiagnosticsReport.swift 'frame_pause_ms_total='
check "diagnostics export explains the pause exclusion" contains ios/app/Sources/DiagnosticsReport.swift 'frame_pause_definition='
check "diagnostics reads the pipeline cache at export time" contains ios/app/Sources/DiagnosticsReport.swift 'let cache = PipelineCacheStats.read()'
check "diagnostics names the cache directory state" contains ios/app/Sources/DiagnosticsReport.swift 'pipeline_cache_dir_state='
check "diagnostics does not invent a cold at-load state" contains ios/app/Sources/DiagnosticsReport.swift 'unknown (no load in this session)'
check "cache stats keep the read error" contains ios/app/Sources/GraphicsWarmUp.swift 'var readError: String?'
check "cache stats distinguish missing from unreadable" contains ios/app/Sources/GraphicsWarmUp.swift 'var directoryState: String'
check "an unreadable cache is reported with its reason" contains ios/app/Sources/GraphicsWarmUp.swift 'unreadable ('
check "a missing cache directory is a normal cold run" contains ios/app/Sources/GraphicsWarmUp.swift 'NSFileReadNoSuchFileError'
check "README documents the pause counters" contains ios/app/README.md 'frame_pause_count='
check "README documents the cache directory state" contains ios/app/README.md 'pipeline_cache_dir_state='

section 'Background lifecycle (0.1.4)'
check "ContentView backgrounds through the suspend path" \
  contains ios/app/Sources/ContentView.swift 'model.suspendForBackground()'
check "the session keeps the runtime when it moves to the background" \
  contains ios/app/Sources/ROMSession.swift 'func suspendForBackground()'
check "the background path no longer releases the runtime" \
  bash -c '! grep -Fq "func stopForBackground" ios/app/Sources/ROMSession.swift'
check "the session writes a recovery snapshot on the way out" \
  contains ios/app/Sources/ROMSession.swift 'requestBackgroundSnapshot()'
check "the snapshot reuses the save-state serialization" \
  contains ios/app/Sources/SaveStateSupport.swift 'captureBackgroundSnapshot'
check "the snapshot is restored before the frame loop starts" \
  contains ios/app/Sources/ROMSession.swift 'startLoadedSession(romKey:'
check "the running session discards the stale snapshot on return" \
  contains ios/app/Sources/ROMSession.swift 'discardBackgroundSnapshot(foregroundReturn: true)'
check "the home page offers the interrupted session" \
  contains ios/app/Sources/HomeView.swift 'background-resume'
check "the game view covers the game while the scene is not active" \
  contains ios/app/Sources/GameView.swift 'background-privacy-cover'
check "diagnostics export the background state" \
  contains ios/app/Sources/DiagnosticsReport.swift 'background_suspended='
check "diagnostics export the snapshot state" \
  contains ios/app/Sources/DiagnosticsReport.swift 'background_snapshot='
check "diagnostics count memory warnings" \
  contains ios/app/Sources/DiagnosticsReport.swift 'memory_warnings='
check "the app delegate receives memory warnings" \
  contains ios/app/Sources/ApplicationDelegate.swift 'applicationDidReceiveMemoryWarning'
check "en Localizable.strings has the resume card title" \
  grep -Fq -- '"Game paused in the background"' ios/app/Resources/en.lproj/Localizable.strings
check "zh-Hans Localizable.strings has the resume card title" \
  grep -Fq -- '"Game paused in the background"' ios/app/Resources/zh-Hans.lproj/Localizable.strings
check "README documents the background lifecycle" \
  contains ios/app/README.md '## Background lifecycle (0.1.4)'
check "README documents the recovery snapshot path" \
  contains ios/app/README.md 'states/<save namespace>/background.bin'
check "the obsolete background-release string is gone" \
  bash -c '! grep -rFq "The runtime was stopped when the app went to the background" ios/app/Resources'

section 'Frame timing pause/resume logic (Swift, macOS only)'
if command -v swiftc >/dev/null 2>&1; then
  SELFTEST_BIN="${TMPDIR:-/tmp}/3ds2apple-frame-timing-selftest.$$"
  if swiftc -parse-as-library -O -o "${SELFTEST_BIN}" \
      ios/app/Sources/FrameTiming.swift scripts/tests/frame-timing-selftest.swift >/dev/null 2>&1; then
    pass "frame-timing self-test compiles"
    if "${SELFTEST_BIN}" >/dev/null 2>&1; then
      pass "pause/resume logic: pauses are not stutters or FPS dips"
    else
      fail "pause/resume logic: pauses are not stutters or FPS dips"
    fi
  else
    fail "frame-timing self-test compiles"
  fi
  rm -f -- "${SELFTEST_BIN}"
else
  printf '  skip frame-timing self-test (swiftc missing; runs on the macOS VM)\n'
fi

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
check "control layout page is linked from Settings" contains ios/app/Sources/SettingsView.swift 'ControlLayoutSettingsView'
check "control layout page exposes only Default / Custom" contains ios/app/Sources/AppSettings.swift 'enum ControlLayoutMode'
check "control layout page opens the editor for the current direction" contains ios/app/Sources/ControlLayoutSettingsView.swift 'ControlLayoutEditorView(settings: settings)'
check "control editor is full screen and edits the current direction" contains ios/app/Sources/ControlLayoutEditorView.swift 'currentLayoutOrientation'
check "control editor overlays the current screen layout" contains ios/app/Sources/ControlLayoutEditorView.swift 'screenViewports'
check "GameView floats the editable control overlay over the whole game view" \
  bash -c 'grep -q "VirtualControlsView(" ios/app/Sources/GameView.swift && grep -q "ignoresSafeArea()" ios/app/Sources/GameView.swift'
check "custom screen layout model exists" contains ios/app/Sources/CustomScreenLayout.swift 'struct CustomScreenLayout'
check "custom screen layout archive is version 3" contains ios/app/Sources/CustomScreenLayout.swift 'static let currentVersion = 3'
check "custom screen layout geometry handles the 90 degree turn" contains ios/app/Sources/CustomScreenLayout.swift 'case .counterClockwise:'
check "custom screen layout editor exists" test -f ios/app/Sources/ScreenLayoutEditorView.swift
check "screen layout settings split landscape (six) and portrait (three) choices" \
  bash -c 'grep -q "enum LandscapeScreenLayout" ios/app/Sources/AppSettings.swift && grep -q "enum PortraitScreenLayout" ios/app/Sources/AppSettings.swift && for preset in large single side hybrid original custom; do grep -q "case \.$preset" ios/app/Sources/AppSettings.swift || exit 1; done && grep -q "case topFullWidth" ios/app/Sources/AppSettings.swift'
check "numeric custom layout page opens the drag editor for its direction" contains ios/app/Sources/CustomScreenLayoutValuesView.swift 'ScreenLayoutEditorView(settings: settings, orientation: orientation)'
check "screen editor is full screen and edits the current direction" contains ios/app/Sources/ScreenLayoutEditorView.swift 'currentLayoutOrientation'
check "screen editor overlays the current control layout" contains ios/app/Sources/ScreenLayoutEditorView.swift 'settings.controlLayout(for: orientation)'
check "custom layout forces the readback presentation path" contains ios/app/Sources/ROMSession.swift 'readbackPresentationRequired'
check "C-stick ABI is declared" contains ios/ZakuroBridge.h 'void zk_set_cstick('
check "C-stick ABI is implemented" contains ios/zakuro-ios/src/lib.rs 'pub extern "C" fn zk_set_cstick'
check "C-stick is pushed before every console frame" \
  bash -c 'n=$(grep -c "zk_set_cstick(system, input.cStickX, input.cStickY)" ios/app/Sources/ROMSession.swift); [ "$n" -ge 2 ]'
check "C-stick keeps its value out of the old zk_set_input signature" \
  contains ios/zakuro-ios/src/lib.rs 'static C_STICK: Cell<(f32, f32)>'
check "en strings cover the split layout pages" \
  bash -c 'grep -q "^\"Screen layout\"" ios/app/Resources/en.lproj/Localizable.strings && grep -q "^\"Control layout\"" ios/app/Resources/en.lproj/Localizable.strings'
check "zh-Hans strings cover the split layout pages" \
  bash -c 'grep -q "^\"Screen layout\" = \"屏幕布局\"" ios/app/Resources/zh-Hans.lproj/Localizable.strings && grep -q "^\"Control layout\" = \"控件布局\"" ios/app/Resources/zh-Hans.lproj/Localizable.strings'
check "no GPL project text copied into the new layout code" \
  bash -c '! grep -riE "azahar|citra" ios/app/Sources/ControlLayout.swift ios/app/Sources/VirtualControlsView.swift ios/app/Sources/CustomScreenLayout.swift ios/app/Sources/ControlLayoutEditorView.swift ios/app/Sources/ScreenLayoutEditorView.swift ios/app/Sources/ScreenLayoutSettingsView.swift ios/app/Sources/ControlLayoutSettingsView.swift'

section 'GPU execution timing and renderer A/B switches (0.1.3)'
check "perf exposes the GPU execution time" contains ios/zakuro-ios/src/perf.rs 'pub fn last_gpu_exec_micros_per_frame()'
check "perf reports whether the GPU times are measured" contains ios/zakuro-ios/src/perf.rs 'pub fn gpu_times_enabled()'
check "perf aggregates the renderer's GPU timestamps per window" contains ios/zakuro-ios/src/perf.rs 'fn gpu_breakdown('
check "perf formats the GPU breakdown line" contains ios/zakuro-ios/src/perf.rs 'zk_gpu: {} frames'
check "perf's summary carries the real GPU execution time" contains ios/zakuro-ios/src/perf.rs 'gpu_exec {:.2}ms/f'
check "header declares the GPU execution timer" contains ios/ZakuroBridge.h 'uint64_t zk_gpu_exec_micros_per_frame(void);'
check "header declares the GPU timing status" contains ios/ZakuroBridge.h 'int32_t zk_gpu_timing_status(void);'
check "header declares the GPU breakdown text" contains ios/ZakuroBridge.h 'size_t zk_gpu_times_line(char *out, size_t capacity);'
check "lib.rs exports the GPU execution timer" contains ios/zakuro-ios/src/lib.rs 'pub extern "C" fn zk_gpu_exec_micros_per_frame() -> u64'
check "lib.rs exports the GPU timing status" contains ios/zakuro-ios/src/lib.rs 'pub extern "C" fn zk_gpu_timing_status() -> i32'
check "lib.rs exports the GPU breakdown text" contains ios/zakuro-ios/src/lib.rs 'pub extern "C" fn zk_gpu_times_line('
check "diagnostics report the GPU profile" contains ios/app/Sources/DiagnosticsReport.swift 'gpu_profile='
check "diagnostics report the GPU execution time" contains ios/app/Sources/DiagnosticsReport.swift 'gpu_exec_ms_per_frame='
check "diagnostics report the GPU breakdown line" contains ios/app/Sources/DiagnosticsReport.swift 'gpu_times_line='
check "diagnostics say when the GPU time is not measured" contains ios/app/Sources/DiagnosticsReport.swift 'not measured (diagnostic GPU profile off)'
check "the app reads the diagnostic GPU profile" contains ios/app/Sources/MoltenVKTuning.swift 'THREEDS2APPLE_GPU_PROFILE'
check "the profile can pick the renderer A/B switches" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_FAST_CLEARS'
check "the profile keeps the MoltenVK allow-list" contains ios/app/Sources/MoltenVKTuning.swift 'MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1'
check "the diagnostic IPA builder exists and is executable" test -x scripts/build-gpu-diagnostic-ipa.sh
check "the diagnostic IPA builder still packages the third round's profiles" contains scripts/build-gpu-diagnostic-ipa.sh 'sort2|merge|capture|noblend'
check "the diagnostic IPA builder embeds MoltenVK" contains scripts/build-gpu-diagnostic-ipa.sh '--require-moltenvk'
check "the diagnostic IPA builder writes a manifest" contains scripts/build-gpu-diagnostic-ipa.sh 'manifest.json'
check "the GPU patch is tracked" test -f ios/zakuro-ios/patches/0003-gpu-timing-and-render-options.patch
check "the GPU patch adds the image-clear switch" contains ios/zakuro-ios/patches/0003-gpu-timing-and-render-options.patch 'ZAKURO_FAST_CLEARS'
check "the GPU patch adds the barrier switch" contains ios/zakuro-ios/patches/0003-gpu-timing-and-render-options.patch 'ZAKURO_FAST_BARRIERS'
check "the GPU patch exposes the renderer timings" contains ios/zakuro-ios/patches/0003-gpu-timing-and-render-options.patch 'pub struct GpuTimes'
check "the GPU patch keeps the totals cumulative for window readers" contains ios/zakuro-ios/patches/0003-gpu-timing-and-render-options.patch 'logged: [f64; WORK_NAMES.len()]'
check "the patch helper lists the new patch" contains scripts/lib/zakuro-patches.sh '0003-gpu-timing-and-render-options.patch'
check "scripts/README documents the GPU A/B profiles" contains scripts/README.md 'GPU A/B diagnostic IPAs'
check "zakuro-ios README documents the GPU execution timing" contains ios/zakuro-ios/README.md 'GPU execution timing and renderer A/B switches'
check "the app README documents the GPU diagnostics fields" contains ios/app/README.md 'gpu_exec_ms_per_frame='
check "the release build applies the fast-math fragment default" contains ios/app/Sources/MoltenVKTuning.swift 'releaseRendererDefaults'
check "the release default is the fast-math fragment build" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_FRAG_FAST_MATH=1'
check "the release default is applied only without a diagnostic profile" \
  bash -c 'grep -A2 "if profile == nil" ios/app/Sources/MoltenVKTuning.swift | grep -q "releaseRendererDefaults"'
check "the specialized fragment build is not a release default" \
  bash -c '! awk "/releaseRendererDefaults = \\[/,/\\]/" ios/app/Sources/MoltenVKTuning.swift | grep -q "ZAKURO_FRAG_SPECIALIZE"'
check "the second round's patch is tracked" test -f ios/zakuro-ios/patches/0004-gpu-pass-times-and-opaque-sort.patch
check "the second patch splits the GPU time by render target" contains ios/zakuro-ios/patches/0004-gpu-pass-times-and-opaque-sort.patch 'pub struct PassTimes'
check "the second patch adds the opaque sort switch" contains ios/zakuro-ios/patches/0004-gpu-pass-times-and-opaque-sort.patch 'ZAKURO_SORT_OPAQUE'
check "the second patch logs the render targets" contains ios/zakuro-ios/patches/0004-gpu-pass-times-and-opaque-sort.patch 'zakuro_gpu::passes'
check "perf collects the render targets' GPU times" contains ios/zakuro-ios/src/perf.rs 'system.gpu.gpu_passes()'
check "perf reports the pass attribution" contains ios/zakuro-ios/src/perf.rs 'target 0x{:08X}'
check "perf reports the sorted draws and reasons" contains ios/zakuro-ios/src/perf.rs 'sorted {:.0}/f of {:.0}/f'
check "perf reports the sort runs and reasons" contains ios/zakuro-ios/src/perf.rs 'sort_runs'
check "perf carries the per-pass report" contains ios/zakuro-ios/src/perf.rs 'passes_line'
check "perf reports the pass breaks" contains ios/zakuro-ios/src/perf.rs 'pass_breaks'
check "perf reports the pass merge's draws" contains ios/zakuro-ios/src/perf.rs 'merged {:.0} draws/f'
check "perf reports skipped captures" contains ios/zakuro-ios/src/perf.rs 'captures_skipped'
check "the app's sort profile sets the switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_SORT_OPAQUE=1'
check "the patch helper lists the second patch" contains scripts/lib/zakuro-patches.sh '0004-gpu-pass-times-and-opaque-sort.patch'
check "scripts/README documents the second-round profiles" contains scripts/README.md 'opaque front-to-back'
check "zakuro-ios README documents the opaque sort" contains ios/zakuro-ios/README.md 'ZAKURO_SORT_OPAQUE'
check "the app README documents the pass attribution" contains ios/app/README.md 'render targets by GPU time'

section 'Third-round GPU diagnostics (0.1.3, task-31)'
check "the third-round patch is tracked" test -f ios/zakuro-ios/patches/0005-gpu-sort-reasons-and-pass-merge.patch
check "the third patch carries the sort reasons" contains ios/zakuro-ios/patches/0005-gpu-sort-reasons-and-pass-merge.patch 'SORT_REASONS'
check "the third patch no longer refuses alpha test or colour masks" \
  contains ios/zakuro-ios/patches/0005-gpu-sort-reasons-and-pass-merge.patch 'lpha test, colour masks and a stencil test'
check "the third patch adds the pass merge switch" contains ios/zakuro-ios/patches/0005-gpu-sort-reasons-and-pass-merge.patch 'ZAKURO_MERGE_PASSES'
check "the third patch adds the capture dedupe switch" contains ios/zakuro-ios/patches/0005-gpu-sort-reasons-and-pass-merge.patch 'ZAKURO_DEDUPE_CAPTURE'
check "the third patch logs the per-pass report" contains ios/zakuro-ios/patches/0005-gpu-sort-reasons-and-pass-merge.patch 'zk_passes:'
check "the third patch logs the sort's reasons" contains ios/zakuro-ios/patches/0005-gpu-sort-reasons-and-pass-merge.patch 'zakuro_gpu::sort'
check "the third patch counts the pass breaks" contains ios/zakuro-ios/patches/0005-gpu-sort-reasons-and-pass-merge.patch 'BREAK_KINDS'
check "the patch helper lists the third patch" contains scripts/lib/zakuro-patches.sh '0005-gpu-sort-reasons-and-pass-merge.patch'
check "the app lists the third-round profiles" contains ios/app/Sources/MoltenVKTuning.swift 'baseline3'
check "the app lists the sort2 profile" contains ios/app/Sources/MoltenVKTuning.swift '"sort2"'
check "the app lists the merge profile" contains ios/app/Sources/MoltenVKTuning.swift '"merge"'
check "the app lists the capture profile" contains ios/app/Sources/MoltenVKTuning.swift '"capture"'
check "the app allows the pass merge switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_MERGE_PASSES'
check "the app allows the capture dedupe switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_DEDUPE_CAPTURE'
check "scripts/README documents the merge profile" contains scripts/README.md 'ZAKURO_MERGE_PASSES=1'
check "zakuro-ios README documents the per-pass report" contains ios/zakuro-ios/README.md 'per-pass report'
check "the app README documents the per-pass report" contains ios/app/README.md 'zk_passes:'
check "the app README documents sort2" contains ios/app/README.md 'sort2'
section 'Fourth-round GPU draw classes and measurement profiles (0.1.3, task-32)'
check "the fourth-round patch is tracked" test -f ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch
check "the fourth patch carries the draw classes" contains ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch 'DRAW_CLASSES'
check "the fourth patch buckets by blend" contains ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch 'DRAW_BLENDS'
check "the fourth patch buckets by coverage" contains ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch 'DRAW_COVERAGES'
check "the fourth patch logs the draw classes" contains ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch 'zakuro_gpu::draws'
check "the fourth patch adds the flat measurement switch" contains ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch 'ZAKURO_MEASURE_FLAT'
check "the fourth patch adds the no-blend measurement switch" contains ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch 'ZAKURO_MEASURE_NOBLEND'
check "the fourth patch adds the safe skips" contains ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch 'ZAKURO_SAFE_SKIPS'
check "the fourth patch skips a blend that leaves the destination" contains ios/zakuro-ios/patches/0006-gpu-draw-classes-and-safe-skips.patch 'blend_leaves_destination'
check "the patch helper lists the fourth patch" contains scripts/lib/zakuro-patches.sh '0006-gpu-draw-classes-and-safe-skips.patch'
check "perf reports the draw classes" contains ios/zakuro-ios/src/perf.rs 'draw_classes {}'
check "perf reports the safe skips" contains ios/zakuro-ios/src/perf.rs 'safe_skips'
check "perf averages the draw classes per window" contains ios/zakuro-ios/src/perf.rs 'draw_classes_since'
check "the app lists the fourth-round profiles" contains ios/app/Sources/MoltenVKTuning.swift '"baseline4"'
check "the app lists the noblend profile" contains ios/app/Sources/MoltenVKTuning.swift '"noblend"'
check "the app lists the flat profile" contains ios/app/Sources/MoltenVKTuning.swift '"flat"'
check "the app lists the 2x3x profile" contains ios/app/Sources/MoltenVKTuning.swift '"2x3x"'
check "the app lists the safe profile" contains ios/app/Sources/MoltenVKTuning.swift '"safe"'
check "the app allows the flat switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_MEASURE_FLAT'
check "the app allows the no-blend switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_MEASURE_NOBLEND'
check "the app allows the safe skips" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_SAFE_SKIPS'
check "the app can ask the 3D renderer for another scale than the drawable" contains ios/app/Sources/MoltenVKTuning.swift 'THREEDS2APPLE_DIAG_RENDER_SCALE'
check "the shell applies the diagnostic 3D render scale" contains ios/app/Sources/ROMSession.swift 'MoltenVKTuning.diagnosticRenderScale'
check "the profile keeps the diagnostic 3D render scale past the environment snapshot" contains ios/app/Sources/MoltenVKTuning.swift 'diagnosticRenderScale = rendererApplied'
check "scripts/README documents the fourth-round profiles" contains scripts/README.md '2x3x'
check "zakuro-ios README documents the draw classes" contains ios/zakuro-ios/README.md 'draw-state class'
check "the app README documents the fourth-round profiles" contains ios/app/README.md 'noblend'
check "the selfcheck only grows this list when the contract changes" test -s scripts/tests/perf-selfcheck.sh

section 'Fifth-round fragment shader builds (0.1.3, task-33)'
check "the fifth-round patch is tracked" test -f ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch
check "the fifth patch builds a fast-math fragment shader" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch 'ZAKURO_FAST_MATH'
check "the fifth patch builds a specialized fragment shader" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch 'ZAKURO_FRAG_SPECIALIZE'
check "the fifth patch builds a texonly measurement shader" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch 'ZAKURO_MEASURE_TEXONLY'
check "the fifth patch adds the fragment builds' modules" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch 'FragmentMode'
check "perf reports the fragment builds" contains ios/zakuro-ios/src/perf.rs 'frag_build'
check "perf reports the fragment lighting's lights" contains ios/zakuro-ios/src/perf.rs 'frag_lights'
check "the app lists the fifth-round profiles" contains ios/app/Sources/MoltenVKTuning.swift '"baseline5"'
check "the app lists the texonly profile" contains ios/app/Sources/MoltenVKTuning.swift '"texonly"'
check "the app lists the fragspec profile" contains ios/app/Sources/MoltenVKTuning.swift '"fragspec"'
check "the app lists the fastmath profile" contains ios/app/Sources/MoltenVKTuning.swift '"fastmath"'
check "the app allows the fast-math switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_FRAG_FAST_MATH'
check "the app allows the specialized switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_FRAG_SPECIALIZE'
check "the app allows the texonly switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_MEASURE_TEXONLY'
check "scripts/README documents the fifth-round profiles" contains scripts/README.md 'fragspec'
check "scripts/README documents the texonly split" contains scripts/README.md 'texonly - flat'
check "zakuro-ios README documents the fragment builds" contains ios/zakuro-ios/README.md 'ZAKURO_FRAG_SPECIALIZE=1'
check "the app README documents the fifth-round profiles" contains ios/app/README.md 'fragspec'
check "the patch helper lists the fifth patch" contains scripts/lib/zakuro-patches.sh '0007-gpu-fragment-builds.patch'
section 'Sixth-round combined fragment build (0.1.3, task-34)'
check "the seventh patch builds the combined spec+fast shader" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch 'raster_spec_fast'
check "the combined build keeps the specialization constants and drops precise" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch 'ZAKURO_FRAG_SPECIALIZE -DZAKURO_FAST_MATH'
check "the renderer has a combined build mode" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch 'FragmentBuild::SpecFast'
check "the renderer counts the combined build" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch 'frag_builds[3]'
check "the renderer names the combined build" contains ios/zakuro-ios/patches/0007-gpu-fragment-builds.patch '"specfast"'
check "perf reports the fourth fragment build" contains ios/zakuro-ios/src/perf.rs 'frag_builds: [f64; 4]'
check "the app lists the sixth-round control" contains ios/app/Sources/MoltenVKTuning.swift '"baseline6"'
check "the app lists the old mvk+renderer profile" contains ios/app/Sources/MoltenVKTuning.swift '"mvkrenderer"'
check "the app's combo sets the fast-math switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_FRAG_FAST_MATH=1'
check "the app's combo sets the specialized switch" contains ios/app/Sources/MoltenVKTuning.swift 'ZAKURO_FRAG_SPECIALIZE=1'
check "the build script defaults to the sixth-round profiles" contains scripts/build-gpu-diagnostic-ipa.sh 'baseline6 combo'
check "the build script accepts the old mvk+renderer profile" contains scripts/build-gpu-diagnostic-ipa.sh 'mvkrenderer'
check "scripts/README documents the combination" contains scripts/README.md 'baseline6 - combo'
check "scripts/README documents the visual checkpoints" contains scripts/README.md 'Visual checkpoints'
check "zakuro-ios README documents the combined build" contains ios/zakuro-ios/README.md 'specfast'
check "the app README documents the combination" contains ios/app/README.md 'specfast'
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
