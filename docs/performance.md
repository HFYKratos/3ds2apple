# Performance: any3ds study, our pipeline, and the measurement plan

Status: 2026-11-16 · owner: perf-any3ds (task-36) · no commits yet (working tree)

The user-reported low frame rate on a real iPhone had a known cause: the old
base shell (0.2.0-beta1/build 9) had no `Frameworks/MoltenVK.framework`, so the
3D fell back to the software PICA200, and the Metal HUD was off by default.
That is fixed in the 0.2.2/build 10 shell (MoltenVK 1.4.2 embedded, HUD default
on). This document does **not** re-litigate that fix. It covers what can be
measured next: our own telemetry, the lessons that are legally usable from
[mohammed-hajwani/any3ds](https://github.com/mohammed-hajwani/any3ds) (GPL-2.0,
read-only reference), opt-in build experiments, MoltenVK configuration, a
readback/fallback audit, and what still needs a real device.

Everything measured on this Linux host is marked **measured (host)**; every
number that needs an iPhone/iPad is marked **needs device**. The two are never
mixed.

## 1. Licence boundary (why there is no any3ds code here)

any3ds is **GPL-2.0** (`LICENSE`: "GNU GENERAL PUBLIC LICENSE Version 2, June
1991", commit `6d22a13`). 3ds2apple is Apache-2.0. Under that combination:

| Allowed | Not allowed |
|---|---|
| Read the project and its documentation to learn *architectural facts* (it uses a surface cache, one fragment shader, CPU vertex shading, per-command-list sync points, `-O1`/patch flags). | Copy or port any source file, function body, comment text, table, shader, or document wording. |
| Cite the repository and describe its design in our own words, with a link. | Vendor, link, translate, or mechanically rewrite GPL code into Swift/Rust. |
| Compare measured results (fps, frame-time splits) and design independent equivalents in our own code. | Use any3ds as a build tool or ship any artifact containing it. |

This change therefore **adds zero lines from any3ds**. The files touched are our
own (Swift shell, bash build scripts, docs). The only any3ds-derived inputs are
design observations, recorded as original prose in §2 and §5. GPL projects
(Azahar, Citra, Folium, ...) stay reference-only for the same reason; see
`THIRD_PARTY.md`. any3ds's own README states it contains no Nintendo code and
expects users to dump their own cartridge; we follow the same rule (no ROM, no
keys, nothing generated from a ROM in git).

## 2. any3ds vs our pipeline, as architectures

any3ds is a static ARM->C recompiler plus its own PICA200 model, and it now
draws on the host GPU through Vulkan. Its published numbers: Pokémon X in
Lumiose City at ~42 fps on an RTX 4060 laptop vs ~10 fps in software, on x86-64
Windows/Linux. Its own docs are honest that nothing was measured on arm64 or
iOS, which is exactly the platform our product ships on. Read its
`docs/architecture.md` and `docs/vulkan-renderer.md` for the statements below.

| Area | any3ds (GPL-2.0, reference only) | 3ds2apple today | What we can reuse |
|---|---|---|---|
| AOT codegen | One C function per guest function; decoded straight to C (no IR); flags computed eagerly; giant `switch`es for computed jumps; game built at `-O1` because `-O2` compile time/memory was out of reach; ~7x from `-O0`->`-O1`. | 3dsrecomp -> C -> clang; generated C compiled at `-O2 -ffp-contract=off -fno-math-errno` (scripts/build-recomp-ios.sh, scripts/build-game-pack.sh, tools/winbuild). Same eager flags/switch approach is upstream business, not ours to change here. | Nothing textual; the *measurement discipline* (profile before flags, keep a benchmark) is the lesson. See §5.1/§6. |
| GPU renderer | Own Vulkan renderer: CPU command-list parse, CPU vertex shading, one fragment shader for combiners/lighting/fog, render targets kept on the GPU by a surface cache, per-batch fallback to software, sync/readback only where 3DS memory must be observed. | Zakuro's PICA200 Vulkan renderer through MoltenVK/Metal on iOS; presenter draws the screens straight from GPU images to a `CAMetalLayer` (`metalDirect`), so there is **no per-frame screen readback** on the presented path. Software PICA200 remains the fallback. | Architectural only. Our renderer is upstream MIT code; we instrument and measure it, we do not port GPL renderer code. |
| Readback | Software path reads back; surface cache reads back only dirty targets at sync points. | Presented path: 0 screen readbacks (verified in code, §4). Readback only on the CGImage fallback or when the renderer itself is software. Per-frame `zk_perf` `xfr`/`fills` counters expose internal transfers. | "Measure readback before optimising it" is the reusable idea. |
| Threading | One host thread per guest thread but only one runs at a time (determinism); rasterisation split into row bands on all cores; CPU vertex shading also threaded; shader interpreter decodes each program once. | AOT guest code runs on the shell's runtime serial queue; Zakuro's Vulkan renderer compiles pipelines on worker threads; software PICA200 fallback is the only CPU raster path. iOS presents on the main thread/layer. | Band-parallel software raster would only matter on the software fallback (not the shipping GPU path); do not port. Our equivalent lever is the GPU path (see §5.4, §5.5). |
| Shader/pipeline cache | Shaders are baked to SPIR-V at build time; no Vulkan pipeline cache is described (pipeline objects keyed by state). | Zakuro persists a Vulkan pipeline cache under `XDG_CACHE_HOME` (the shell points it at the app Caches dir) and the shell has a bounded warm-up overlay; new draw combinations compile on Zakuro's compiler threads and fall back to a generic pipeline meanwhile. | Our pipeline cache is already the stronger design; measure warm vs cold instead of rebuilding it. |
| Frame pacing | Fixed-speed loop (`--speed 1`), software 30-frame live snapshots for tooling. | Free-run 60 fps cap (or CADisplayLink), audio ring buffer, automatic playback-speed reduction for slow titles; frame-loop label in diagnostics. | Nothing needed; keep measuring max frame, not only average. |

## 3. Our performance telemetry (what exists and what was added)

### 3.1 The runtime contract (already existed)

`ios/zakuro-ios/src/perf.rs` accumulates a window of `DEFAULT_LOG_INTERVAL = 60`
frames and prints one `zk_perf` line to stderr (visible via `idevicesyslog`).
Fields:

- `frame avg/max` - `zk_run_frame` wall time (emulation CPU + command-list work).
- `read top/bottom` - `zk_read_screen` time and call count (CGImage path only).
- `audio` - `zk_take_audio` time.
- `gpu ms/frame`, `non-gpu ms/frame` - CPU host time the renderer spent walking
  command lists vs everything else.
- `cpu M cyc/s` and `% of real time` - guest clock progress.
- `draws/xfr/fills` per frame - GPU work counters (transfers = the readback /
  display-transfer counter to watch).
- `interpreted %` and `AOT active/interpreting` - execution mode.
- `hot <thread>@0x<pc>x<hits>` - only with the `profiling` feature.

The C ABI also exposes `zk_last_frame_micros()`,
`zk_last_screen_read_micros(which)`, `zk_last_audio_take_micros()`,
`zk_recompiled_status()`, `zk_hardware_status()`, `zk_profiler_start()` and
`zk_profiler_hot_spots()`; the shell already calls the status functions on every
load and logs them.

### 3.2 Added in this change (badge + diagnostics)

Goal: a device tester can see AOT%, fps, renderer and per-frame CPU/present/read
split at a glance, and the exported report carries the same breakdown.

- **AOT% badge**: `ROMSession.AOTDiagnostics` now parses
  `interpreted X.XX% of N instructions` and `N instruction fallbacks` out of
  `zk_recompiled_status()`. The badge shows `AOT 99.98%` instead of the static
  `AOT pack` label when the runtime reported the figure (falls back to the old
  label if it did not). See `ROMSession.swift` (`aotPercent`,
  `interpretedPercent`, `instructionFallbacks`).
- **Per-frame row under the badge**: `CPU <ms> · present <ms> · read <ms>` from
  `FrameTimingSnapshot` phase averages (`zk_run_frame` / `zk_present` /
  `zk_read_screen`). `read` is `—` on the presented path, because there is no
  readback phase to measure there.
- **Diagnostics report**: new stable lines `aot_percent`,
  `aot_interpreted_percent`, `aot_fallbacks`, `timing_share_run_pct`,
  `timing_share_present_pct`, `timing_share_read_pct`,
  `timing_share_audio_pct`, `frame_budget_ms=16.67`,
  `frame_budget_used_pct`, `perf_log=...` and `metal_moltenvk_env=...`.
- **Localized**: new keys added to both `en.lproj` and `zh-Hans.lproj`
  (`AOT %@`, `CPU %@ ms · present %@ ms · read %@ ms`, 5-argument accessibility
  label).
- **No new log spam**: the only new log line is the one-shot
  `moltenvk_env=none` /`moltenvk_env=...` at launch, and the existing
  `zk_perf` window line is unchanged.

Limitation: this host has no Swift/Xcode toolchain, so the Swift edits were
reviewed and statically checked (`scripts/tests/perf-selfcheck.sh`) but not
compiled here. Building them on the macOS VM (`xcodebuild` via
`scripts/build-ios-app.sh`) is part of accepting this change. **needs device**
for the badge/diagnostics to be exercised against a real load.

## 4. GPU readback / software-fallback audit

Question: is there a remaining avoidable readback or silent software fallback,
now that MoltenVK is embedded?

Evidence, read from the current tree:

1. Source of truth `ios/zakuro-ios/src/presenter.rs`:
   - `presentation_mode()` returns `BackendMode::Direct` only for a presented
     system whose renderer reports `shows_directly()`; otherwise `Uploaded`;
     `Readback` only when there is no presenter at all.
   - `present_screen()` returns `PresentScreen::Gpu` when
     `system.gpu_screen(screen)` exists (shared device), and only falls back to
     `read_screen_scaled()` (CPU pixels) otherwise.
2. `ios/app/Sources/ROMSession.swift`: `zk_read_screen` is called only from the
   readback helpers used when `displayPath == .readback`; the presented frame
   loop calls `zk_present`. `displayPath` comes from
   `zk_present_mode()` (1 = metalDirect / 2 = metalUploaded / 0 = readback).
3. `ROMSession.joinLoad` logs `display:` and `hardware:` for every load and logs
   an explicit `PERFORMANCE WARNING` when `displayPath` is not Metal or
   `zk_hardware_status()` says software. The diagnostics export carries
   `display=`, `renderer_software=`, `hardware=`, `metal_moltenvk_embedded=`
   and the MoltenVK pipeline-cache state, so a device report can distinguish
   "software fallback" from "GPU path but slow" without guessing.
4. Ship artifact check (**measured (host)**, static): the template
   `out/shell/3ds2apple-shell.ipa` is 5,477,984 B, bundle
   `com.kratos.3ds2apple` version 0.2.2/build 10, contains
   `Frameworks/MoltenVK.framework/MoltenVK` (4,822,128 B) and
   `MetalHudEnabled = true` in `Info.plist`.

Conclusion: in the shell code there is **no avoidable per-frame screen
readback on the presented path**; the remaining readback is inherent to (a) no
presenter / no MoltenVK, or (b) the renderer itself being software. Any other
readback would be inside Zakuro's renderer and must be shown by the `xfr`/`fills`
counters plus `gpu ms/frame` in a device `zk_perf` capture (§6.1). **needs
device**: confirm the log shows `drawing on ... through Vulkan`, `present ...
direct`, and no `drawing in software` on the fixed shell.

## 5. Concrete optimisations, with expected impact

Projected impact is a hypothesis until §6 is run on a device; it is ordered by
(value / risk), and every item has an A/B method.

### 5.1 AOT compile flags: `-O3`, LTO, fast-math (opt-in, defaults unchanged)

Implemented as environment/flag options so release builds stay byte-identical
until evidence says otherwise:

- `scripts/lib/aot-common.sh` adds `aot_codegen_flags()` /
  `aot_codegen_link_flags()`, used by `scripts/build-recomp-ios.sh` (serial
  compile) and `scripts/build-game-pack.sh` (code-dir compile + link). Default
  is exactly `-O2 -ffp-contract=off -fno-math-errno`.
- `tools/winbuild/build-gamepack.sh` (no-Apple-SDK path) gains
  `--opt-level O1|O2|O3|Oz`, `--lto`, `--fast-math`, threaded through the
  compile, shim, link and selfcheck commands and printed in the dry-run plan.
- macOS/Xcode path: `THREEDS2APPLE_AOT_OPT`, `THREEDS2APPLE_AOT_LTO`,
  `THREEDS2APPLE_AOT_FAST_MATH` environment variables (documented in
  `scripts/AOT_BUILD.md`).

**measured (host, proxy, not proof)**: because this host has no clang for
arm64-Mach-O, flags were measured on a synthetic "recompiled guest code" C file
(ctx struct in memory, eager flags, computed `switch`, indirect calls, a few
float ops) built with gcc 15.2 on x86-64, plus a 4000-case switch compile:

| Build | ns/step (min of 3 runs, 20M steps) | .text bytes | notes |
|---|---|---|---|
| `-O2 -ffp-contract=off -fno-math-errno` | 1.646 | 3,369 | current default shape |
| `-O3` same flags | 1.632 | 3,351 | ~0.8% faster in this synthetic case |
| `-O3 -flto` | 1.649 | 3,351 | no gain here |
| 4000-case switch, `-O2` vs `-O3` compile | 1.97 s vs 1.95 s; 166,000 B object both | - | no compile-time blow-up in this small file |

This is a *negative* result for treating `-O3`/LTO as free wins: the synthetic
case is dominated by memory/indirect-call traffic, like much recompiled code.
any3ds's own lesson is the same direction: compilation flags were the biggest
single win at `-O0`->`-O1`, but `-O2` became impractical on the giant
computed-jump switches (their docs quote ~144 s vs ~15 s per example), and their
retail game stayed at `-O1`. Our generated C is already at `-O2`; treat
`-O3`/LTO as per-title experiments and measure build time, memory and frame
time. `-ffast-math` is **rejected as a default**: it changes rounding of guest
float code (PICA float24 semantics, fixed-point effects) and can change rendered
frames; only use it for an A/B with frame-hash comparison.

**needs device**: build one title with `THREEDS2APPLE_AOT_OPT=O3` (or
`--opt-level O3`), record build wall time/RSS on the VM, then A/B the same
scene with `zk_perf` (frame avg/max, cpu cyc/s, interpreted %) and a screenshot
hash. Keep `-O2` unless the device shows a real gain with identical frames.

### 5.2 Pipeline warm-up / first-use hitches

The shell runs a bounded graphics warm-up only when the setting is on (default
off) and always persists the pipeline cache; `zk_perf` frame `max` catches the
hitch. Expectation: the fixed 0.2.2 shell's first game load still compiles new
pipelines; a warm-cache second load is faster. **needs device**: compare
`zk_perf` line 2-3 (cold) vs after a relaunch (warm), and the diagnostics
`warmup_*` rows. If max frames stay >100 ms after the cache is warm, consider
defaulting warm-up back on for the first run per title; that is a product
decision, not implemented here.

### 5.3 MoltenVK configuration (safe opt-in A/B, nothing default)

MoltenVK reads its performance parameters from `MVK_CONFIG_*` environment
variables **before** its first `VkInstance`/`VkDevice` is created. The shell
creates that device on the first presented load, so `App.init` is early enough.

Added `ios/app/Sources/MoltenVKTuning.swift`: reads
`THREEDS2APPLE_MVK_CONFIG="NAME=value,NAME=value"` in `App.init` **before**
`MetalHUD.apply` / `MetalBackend.configureForLaunch` and calls `setenv` only for
allow-listed names. A normal launch has no variable and changes nothing
(`moltenvk_env=none` in diagnostics). The allow-list contains the 44
`MVK_CONFIG_*` names the pinned framework actually understands, obtained by
**measured (host)** `strings Frameworks/MoltenVK.framework/MoltenVK | grep
MVK_CONFIG_` on the 1.4.2 binary inside the 0.2.2 IPA, so a typo fails loudly
instead of being silently ignored. Defaults/semantics still come from
Khronos's MoltenVK_Configuration_Parameters.md for v1.4.2: read it before
enabling a key.

Candidate matrix (all off by default; A/B one at a time, same scene):

| Variable | Why it might help | Risk / note |
|---|---|---|
| `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0` | keep queue submits asynchronous (should be the default; assert A/B) | none expected |
| `MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1` | pre-fills Metal command buffers: less CPU allocation/encoding overhead per submission | more memory; measure `present` and `run` |
| `MVK_CONFIG_PREALLOCATE_DESCRIPTORS=1` | fewer descriptor-pool allocations under many draws | memory; a few % at best |
| `MVK_CONFIG_USE_MTLHEAP=1` | allocate resources from a Metal heap | allocation pattern only; check memory |
| `MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE=3` | bound in-flight frames (frame pacing / memory) | can throttle; watch fps stability |
| `MVK_CONFIG_PERFORMANCE_TRACKING=0`, `..._LOGGING_FRAME_COUNT=0`, `..._LOGGING_INLINE=0` | remove statistics/timer overhead when not diagnosing | loses MoltenVK perf logging |
| `MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1` | compile more shader/pipeline work in parallel during warm-up | CPU contention with the emulator; first-load only |
| `MVK_CONFIG_FAST_MATH_ENABLED=1` | MSL fast-math | precision of guest float rendering changes; A/B frames only |
| `MVK_CONFIG_USE_METAL_PRIVATE_API=1` | enables `logicOp` (a few games) | private API; compatibility, not a speed default |
| `MVK_CONFIG_LOG_LEVEL` / `MVK_CONFIG_DEBUG` | reduce logging overhead | loses the logs that diagnose fallbacks |

How to run it (device or Simulator **needs device/VM**): Xcode scheme launch
environment, or on Simulator `xcrun simctl spawn booted "<app>"` with the env
set, or a re-signed debug IPA; then `idevicesyslog | grep -E 'MoltenVK tuning|
zk_perf|Metal'`. The log line `MoltenVK tuning: applied ... before the first
device` proves ordering; `moltenvk_env=` in diagnostics records the run.

### 5.4 Surface cache / command-buffer mapping (design only, no port)

any3ds's biggest measured win on desktop was not the shader: it was keeping
render targets on the GPU (surface cache) and batching a command list into one
command buffer with ring buffers, syncing only where 3DS memory must be
observed. On our side the equivalent question is whether Zakuro's renderer
already does this for the presented path or re-transfers targets. We cannot
port any3ds code (GPL); what we can do is **measure** and, if the data says
transfer-bound, raise it upstream (MIT):

- read the `xfr`/`fills` per-frame counters and `gpu ms/frame` from a device
  `zk_perf` line;
- if `xfr` is large every frame (display transfers at 60 Hz are expected;
  render-target readbacks are not), compare `metalDirect` vs an uploaded
  software build, and capture a Metal frame in Xcode's GPU trace;
- if transfers dominate, the upstream change would be "keep render targets on
  the shared device and sync only on texture read/CPU read", which is the same
  architectural idea any3ds documents but must be implemented in Zakuro's MIT
  codebase, not ported.
Expected impact: potentially large (any3ds moved from ~3 fps to ~34.7 fps with
this step on desktop), but **unknown on iOS** and not attempted here; the
presenter direct path already removes the final screen readback, so the
remaining upside is internal render targets. **needs device**.

### 5.5 Vertex shading on the GPU path (candidate A/B, no code change here)

Zakuro's iOS hardware path keeps PICA vertex shading on the CPU by default;
upstream exposes `zk_set_hardware_option("gpu_shaders", "1")` and the shell does
not call it (`ios/zakuro-ios/README.md` §hardware functions). On titles with
vertex-heavy scenes this is a real per-frame CPU cost (the same stage any3ds
multithreads on the CPU). A/B with the option flipped, compare `zk_perf` run
time + visual correctness; if it wins, expose it behind a setting. **needs
device**; do not flip a default without frame comparison.

### 5.6 Frame pacing / audio (measurement only)

The shell's free-run loop and audio buffer already reduce playback speed when
frames are too slow rather than letting audio underrun. Before changing pacing,
record `zk_perf` `frame avg` vs `max` and the diagnostics `timing_ms_*` rows:
average-bound means genuine CPU/GPU cost, max-bound means compile/thermal
spikes. **needs device**.

## 6. What must be measured on a real device

No iPhone was available for this task. Nothing above is claimed as a device
result. The acceptance checklist for the 0.2.2 shell retest:

### 6.1 Capture a baseline (2-3 minutes, one scene)

```bash
# with the fixed 0.2.2/build10 shell + one AOT game installed and running
idevicesyslog | grep -E 'zk_create|zk_hardware|zk_perf|drawing on|MoltenVK|PERFORMANCE|metal backend|metal hud|MoltenVK tuning' | tee perf-baseline.log
```

Record from the **second or third** `zk_perf` window (steady state): `frame
avg/max`, `gpu`, `non-gpu`, `read` (expect 0 on presented), `cpu %`,
`interpreted %`, `draws/xfr/fills`. Export Diagnostics from the in-game menu and
keep the `timing_ms_*`, `timing_share_*`, `fps`, `display`, `hardware`,
`aot_percent` rows with it.

### 6.2 A/B matrix (one change at a time, same scene/route)

1. Presented GPU (`metalDirect`) vs a build without MoltenVK (software) - the
   headline comparison the old shell failed; expect a large gap, and this is
   the regression proof for the fix.
2. `THREEDS2APPLE_AOT_OPT=O3` game pack vs `O2` (same title, frame-hash the
   scene; record VM build time/memory too).
3. `THREEDS2APPLE_MVK_CONFIG=MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1` (and
   each §5.3 candidate alone) vs default.
4. Pipeline cache cold vs warm (relaunch) - first-load max frame vs steady.
5. Optional: `gpu_shaders` hardware option on vs off (§5.5), frames compared.

Acceptance for any change: faster steady-state frame time or fewer spikes,
same pictures (screenshot/frame hash), no new crash/thermal regression (20 min
soak), and the default build unchanged unless the win is confirmed.

### 6.3 Known unknowns that only a device can settle

- Actual M1/A-series MoltenVK throughput and whether `present` or `run`
  dominates on the fixed shell.
- Whether the remaining bottleneck after the MoltenVK fix is AOT CPU
  (interpreted %, cpu cyc/s below 100%), GPU submission, or thermal throttling.
- Whether `-O3`/LTO builds even finish in the 8 GB VM for a 230 MB game pack
  and what they do to frame max (pipeline compile timing interactions).
- MoltenVK tuning defaults vs the table in §5.3 (only the binary's accepted
  names are verified here; defaults and wins are not).
- Metal HUD visibility/FPS and any nested-framework re-signing failures
  (`plumesign`, Sideloadly/AltStore) - still the outstanding device item from
  the shell-aot-hud handoff.

## 7. Reproduce the host-side evidence

```bash
# 1. Build script defaults are unchanged, overrides work, and every script parses
bash scripts/tests/perf-selfcheck.sh

# 2. MoltenVK env names the pinned framework accepts (44)
unzip -p out/shell/3ds2apple-shell.ipa \
  Payload/3ds2apple.app/Frameworks/MoltenVK.framework/MoltenVK > /tmp/mvk
strings /tmp/mvk | grep -oE 'MVK_CONFIG_[A-Z0-9_]+' | sort -u

# 3. Shell artifact still carries MoltenVK + HUD
unzip -l out/shell/3ds2apple-shell.ipa | grep -E 'MoltenVK|Info.plist'
unzip -p out/shell/3ds2apple-shell.ipa Payload/3ds2apple.app/Info.plist | grep -A1 MetalHudEnabled
```

The synthetic flag benchmark source and the 4000-case switch generator are
scratch files under `/tmp` (not part of the repo; no game data involved): the
method is documented in §5.1 so it can be re-run with clang on the macOS VM.

## 8. Files changed by this task

| File | Change |
|---|---|
| `docs/performance.md` | this document |
| `ios/app/Sources/ROMSession.swift` | parse AOT%/fallbacks from `zk_recompiled_status`; add `perfText` to the badge state |
| `ios/app/Sources/GameView.swift` | two-row badge (AOT%/fps/renderer/HUD + CPU/present/read) |
| `ios/app/Sources/DiagnosticsReport.swift` | AOT%, timing shares, frame budget, MoltenVK env rows |
| `ios/app/Sources/MoltenVKTuning.swift` | new, allow-listed `MVK_CONFIG_*` env hook (default off) |
| `ios/app/Sources/App.swift` | apply MoltenVK tuning before the first device; log it |
| `ios/app/Resources/{en,zh-Hans}.lproj/Localizable.strings` | badge/perf/diagnostics keys |
| `scripts/lib/aot-common.sh` | `aot_codegen_flags` / `aot_codegen_link_flags` (default `-O2`) |
| `scripts/build-recomp-ios.sh`,`scripts/build-game-pack.sh` | use the helpers; env overrides documented |
| `tools/winbuild/build-gamepack.sh` | `--opt-level`, `--lto`, `--fast-math` behind explicit flags |
| `scripts/tests/perf-selfcheck.sh` | new static/behaviour check for this document's contract |
| `scripts/AOT_BUILD.md` | experiment flags documented |

No commits, no pushes, no ROM or generated game code touched.
