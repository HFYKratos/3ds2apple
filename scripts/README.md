# Build scripts

Scripts for building the iOS runtime and shell, per-game AOT GamePacks, the
signable shell IPA, the release assets and the host-side self-checks. All outputs
go to gitignored directories: no ROM, generated C, dylib or IPA is committed.
Usage for end users lives in the root [README](../README.md); this file is the
developer guide for the scripts.

## iOS runtime and shell

| Script | Purpose |
|---|---|
| `build-zakuro-ios.sh` | Clone/pin Zakuro, apply `ios/zakuro-ios/patches/*.patch`, add the iOS crate and build `build/ios/libzakuro_ios.a` |
| `build-ios-app.sh` | `xcodegen` + `xcodebuild` for the unsigned shell `.app` (empty schema-2 catalog) |
| `package-ipa.sh` | Wrap an unsigned `.app` into `IPA/<name>.ipa` and print its SHA-256; `--manifest FILE` writes the launcher shell `manifest.json` (version/build from the app Info.plist, bundle id, bytes, SHA-256) |
| `build-gpu-diagnostic-ipa.sh` | Package the ROM-free shell as GPU A/B diagnostic IPAs (one Info.plist GPU profile each: `baseline`/`baseline2`/`baseline3`/`baseline4`/`mvk`/`renderer`/`sort`/`sort2`/`merge`/`capture`/`noblend`/`flat`/`2x3x`/`safe`/`combo`), with MoltenVK embedded; outputs stay under `out/gpu-diag*/` (gitignored) |

## GamePacks and shell IPA (launcher-first)

| Script | Purpose |
|---|---|
| `build-recomp-ios.sh` | Run 3dsrecomp on a user ROM and compile the generated C for `arm64-apple-ios` into `libgame.a` |
| `build-linked-ios-lib.sh` | Build the linked `libzakuro_ios.a` for one title and collect `build/ios/<name>/` |
| `build-game-pack.sh` | Build or adopt one per-game AOT pack package (`out/packages/<TITLE_ID>/{GameInfo.json,GamePack-*.dylib}`); macOS for a real link, `--fake`/`--dry-run` on any host |
| `build-multi-game-ipa.sh` | Allocate several packs into ONE unsigned shell IPA with a generated schema-2 `GameCatalog.json`; `--base-app` on macOS, `--fake-shell` layout preview anywhere |
| `lib/game-catalog.sh` | Shared `GameCatalog.json` writer/validator/installer; accepts schema 1 (legacy static link) and schema 2 (AOT packs) |
| `lib/desktop-aot.sh` | Shared helpers for the desktop AOT scripts: locate `3ds2apple-pack`, Mach-O/placeholder pack checks, catalogue title extraction |
| `lib/aot-common.sh` | Shared AOT helpers (title-ID normalisation, build-info/manifest parsing, `nm` symbol helpers, codegen flags) |
| `lib/zakuro-patches.sh` | Idempotent application of the local Zakuro patches |

`3ds2apple-pack` (in `builder/pack`) owns the pure desktop logic and prints the
exact script plan; `3ds2apple-pack build --queued --execute` runs
`build-recomp-ios.sh` → `build-linked-ios-lib.sh` → `build-game-pack.sh` on
macOS, and the macOS launcher drives the same scripts. The Windows launcher
compiles GamePacks with its own bundled 3dsrecomp + LLVM/LLD toolchain (see
[tools/winbuild/README.md](../tools/winbuild/README.md)).

## AOT build pipeline and flags

3ds2apple builds each game ahead of time:

```text
ROM → 3dsrecomp (generated C) → clang for arm64-apple-ios → libgame.a
    → linked into the app with libzakuro_ios.a → unsigned IPA / GamePack.dylib
```

The repository never stores the ROM, the generated C or the resulting IPA. The
per-game IPA carries a build-time `GameCatalog.json`; the phone only selects and
launches AOT code, it never recompiles a ROM on device.

### Split build

```bash
# 1. Recompile the game and compile its C for iOS.
scripts/build-recomp-ios.sh "ROM/game.cci" game-name --auto-serial

# 2. Build the linked runtime for that title.
scripts/build-linked-ios-lib.sh game-name

# 3. Adopt the pack into the launcher-first pipeline.
scripts/build-game-pack.sh game-name --title-id 0004000000055E00 --out out \
  --dylib <runtime-provided GamePack.dylib>
```

### Options

`build-recomp-ios.sh`: `--auto-serial`, `--serial-compile`, `--code-dir DIR`,
`--archive FILE`, `--title-id ID`, `--recomp-rev REV`, `--force`.
`build-linked-ios-lib.sh`: `--reuse`, `--title-id ID`, `--isolated-target`.
`build-game-pack.sh`/`build-multi-game-ipa.sh`: see `--help`; `--fake`/`--dry-run`
and `--fake-shell` need no Xcode or ROM.

### Performance experiments (opt-in; defaults unchanged)

A game pack is normally built at `-O2 -ffp-contract=off -fno-math-errno`. For an
A/B on one title only, override the flags without touching a script default.
Keep `-O2` unless a measurement with identical frames on a real **device** says
otherwise: performance work is data-driven, and `needs device` numbers are never
mixed with host measurements.

| Where | Knob | Effect |
|---|---|---|
| `scripts/build-recomp-ios.sh` / `scripts/build-game-pack.sh` | `THREEDS2APPLE_AOT_OPT=O1|O2|O3|Oz` | codegen level (default `O2`) |
| same | `THREEDS2APPLE_AOT_LTO=1` | add `-flto` to compile and link |
| same | `THREEDS2APPLE_AOT_FAST_MATH=1` | add `-ffast-math`; **changes guest float results**, measurement only |
| `tools/winbuild/build-gamepack.sh` (Windows/Linux LLVM path) | `--opt-level O1|O2|O3|Oz`, `--lto`, `--fast-math` | same flags, printed in the plan/log |
| shell | `THREEDS2APPLE_MVK_CONFIG="NAME=value,..."` | allow-listed `MVK_CONFIG_*` values applied before the first Vulkan device |

The runtime reports the `AOT%` badge and `zk_perf` counters; the plan is to
measure frame time, present time, GPU time and readbacks before changing codegen.

#### GPU A/B diagnostic IPAs (0.1.3)

`scripts/build-gpu-diagnostic-ipa.sh` builds the unsigned shell once and packages
one IPA per diagnostic GPU profile, differing only in the `GPUDiagnosticsProfile`
key written into each copy's `Info.plist`. `MoltenVKTuning.applyFromEnvironment`
reads that key in `App.init` and applies the profile's allow-listed `MVK_CONFIG_*`
values and renderer switches before the first Vulkan device, so the same code runs
with and without a candidate optimisation. The app logs the profile and everything
it applied (`gpu_profile=`, `renderer_env=`, `moltenvk_env=`), and every profile
sets `ZAKURO_GPU_TIMES=1` so the diagnostics carry the GPU's real execution time.

| Profile | What it adds |
|---|---|
| `baseline` | nothing but the GPU timing: the first round's control |
| `baseline2` | the second round's control: nothing but the GPU timing, and the GPU line also splits its time by render target (which pass cost what, with its passes and draws) |
| `baseline3` | the third round's control: the per-pass report (each pass's GPU milliseconds and draws, whether it had depth or drew into a twin, what ended the pass before it), the window's pass-break reasons and the work-operation counts |
| `mvk` | MoltenVK performance parameters: Metal argument buffers, prefill of Metal command buffers, MTLHeap, more active Metal command buffers, present through a command buffer, async queue submits |
| `renderer` | renderer A/B switches: image clears where they can be (no attachment load/store for a full clear, `ZAKURO_FAST_CLEARS=1`) and a narrower barrier between render passes (`ZAKURO_FAST_BARRIERS=1`) |
| `sort` | the second round's `baseline2` + opaque sort build, kept for an old IPA comparison |
| `sort2` | `baseline3` + the relaxed opaque front-to-back draw sort (`ZAKURO_SORT_OPAQUE=1`): alpha test and partial colour masks no longer keep a draw out, only a state that can change the picture does (depth writes, blending, logic ops, stencil writes, GPU-shaded vertices); the line gains `sorted N/f of M/f draws` and a per-reason count so a run that does not engage says why |
| `merge` | `baseline3` + render-pass merging (`ZAKURO_MERGE_PASSES=1`): a draw with no depth buffer into a depth-buffered pass keeps that pass with its depth test and write off, so a title that switches depth on and off does not end and begin a pass each time; the line gains `merged N/f` |
| `capture` | `baseline3` + duplicate-capture skipping (`ZAKURO_DEDUPE_CAPTURE=1`): a capture asked for again in the same batch with nothing drawn since is not recorded again; the line gains `captures_skipped N/f` when it happens |
| `baseline4` | the fourth round's control: the GPU draw time split by draw state (blend kind, alpha test, texture units, writes, estimated coverage) with the timestamps at class boundaries rather than one per draw; the line carries each class's ms/f, draws/f and estimated Mpx/f (`draw_classes`) and the `safe_skips` count |
| `noblend` | `baseline4` + every blending draw written as if the blend were off (`ZAKURO_MEASURE_NOBLEND=1`), measurement only: the drop in `gpu_exec` is what blending and its destination read cost |
| `flat` | `baseline4` + every fragment drawn as one color instead of the combiners, fetches and lighting (`ZAKURO_MEASURE_FLAT=1`), measurement only: the drop in `gpu_exec` is what the fragment work adds beyond fill and blending |
| `2x3x` | `baseline4` with the internal 3D renderer at 2x while the drawable keeps 3x (`THREEDS2APPLE_DIAG_RENDER_SCALE=2`), measurement only: the drop in `gpu_exec` is what the 3x target's fill costs |
| `safe` | `baseline4` + math-equivalent skips of draws whose state cannot change either buffer (`ZAKURO_SAFE_SKIPS=1`); the picture must be unchanged and `safe_skips N/f` says whether it engaged |
| `baseline5` | the fifth round's control: the same timing plus the fragment state per draw (`frag_lights`: draws/frame with the fragment lighting off, then with 1 to 8 lights; `fog`: draws/frame with the fog on; `frag_build <name> N/f` when a build past the default one runs), so a run says whether the fragment-work A/Bs can help the scene |
| `texonly` | `baseline5` + the fragment shader samples the texture units and outputs their sum and the vertex color, with no combiners, lighting, fog or alpha test (`ZAKURO_MEASURE_TEXONLY=1`), measurement only: `baseline5 - texonly` is the fragment ALU's cost and `texonly - flat` the texture fetch cost |
| `fragspec` | `baseline5` + the lighting state, the fog switch and each unit's wrapping compiled in as specialization constants (`ZAKURO_FRAG_SPECIALIZE=1`); math-equivalent, the picture must be unchanged and `frag_build specialized N/f` says the build engaged |
| `fastmath` | `baseline5` + `precise` dropped from the fragment shader (`ZAKURO_FRAG_FAST_MATH=1`), so the driver may contract and approximate; the picture must stay visually the same and `frag_build fastmath N/f` says it engaged |
| `baseline6` | the sixth round's control: the same timing and fragment-state report as `baseline5` with the fast-math and specialized fragment builds off, so a `combo` run is measured against the default build |
| `combo` | the sixth round's combination: `ZAKURO_FRAG_FAST_MATH=1` and `ZAKURO_FRAG_SPECIALIZE=1` together, which the renderer runs as its combined build (the specialized constants and no `precise`); math-equivalent apart from rounding, the picture must be confirmed scene by scene and `frag_build specfast N/f` says it engaged; the sixth round's candidate for the release default |
| `mvkrenderer` | the first round's confirmation run after its A/B: `mvk` + `renderer`, kept so that run can still be reproduced |

Run it on the macOS build VM after `scripts/build-zakuro-ios.sh` and
`scripts/build-ios-app.sh`; `MOLTENVK_FRAMEWORK` names the downloaded framework
to embed (never committed). It prints each IPA's path, bytes and SHA-256, writes
`manifest.json` and an `out/gpu-diag/README.txt` with the device A/B procedure.
Use the real GPU execution time (`gpu_exec_ms_per_frame=` in the diagnostics,
`zk_gpu:` line in the log), the frame interval and a system Metal HUD screenshot
for the same scene and duration per profile: a profile that lowers `gpu_exec`
while the shaded fragment count stays the same changed GPU scheduling or
bandwidth, not the emulated shading. The per-pass report (`zk_passes:`, carried
inside `gpu_times_line=`) and the `pass_breaks` counters are what a pass-merge
candidate is judged from, and the sort's `sorted`/reason counters say whether
the draw sort engaged at all; a candidate with under 5% real GPU-time gain, or
any picture change, stays off in the release build. The fourth round's
`draw_classes` line (draw-state GPU time buckets, estimated pixels per class)
and the `noblend`/`flat`/`2x3x` measurement profiles are how a 3x scene that is
fill bound is shown to be fill bound: no math-equivalent change can then
recover the fragments without changing the picture, and `safe` measures the one
candidate class that can.

The fifth round works on the fragment shader itself. `texonly` splits the
fragment cost the `flat` profile left in two (texture fetch against ALU:
combiners, fragment lighting, fog, procedural texture), and `frag_lights`/`fog`
say whether the lighting and fog the two math-equivalent candidates
(`fragspec`, a fragment shader with the lighting, fog and unit wrapping taken
as specialization constants, and `fastmath`, the same shader built without
`precise` so the driver may contract and approximate) act on are there in the
scene at all. Both must lower `gpu_exec` with the picture unchanged (fastmath
may round a least significant bit) and say `frag_build ... N/f`; under 5%
gain, no access path.

The sixth round combines the fifth round's two math-equivalent candidates. The
`combo` profile sets both `ZAKURO_FRAG_FAST_MATH=1` and
`ZAKURO_FRAG_SPECIALIZE=1`; the renderer then runs a combined build of
`raster.frag` with the specialization constants of the `fragspec` build and
without the `precise` of the `fastmath` build, counted in
`frag_build specfast N/f`. `baseline6` is the same build's control with the
fragment builds off, so `baseline6 - combo` is the saving a release default
would carry. Build the pair with
`scripts/build-gpu-diagnostic-ipa.sh --out-dir out/gpu-diag6` and run the same
scene on the device for both profiles per the procedure above; if `combo` is
within the measurement noise of `fastmath` alone (round five), the default
keeps only `fastmath`, because the specialized build costs one more pipeline
shape per lighting/fog/wrapping state and its first-load compile time.

**Release default in 0.1.3:** `fastmath` only. `MoltenVKTuning.releaseRendererDefaults`
applies `ZAKURO_FRAG_FAST_MATH=1` when no diagnostic GPU profile is set (kill
switch: `THREEDS2APPLE_RENDERER_OPTIONS=ZAKURO_FRAG_FAST_MATH=0`);
`fragspec`, `combo` and `specfast` remain diagnostic-only.

Visual checkpoints (each item must be confirmed to look identical between
`baseline6` and `combo`; any visible difference means no default): two titles
and several scenes per title, one run still and one moving per scene —
title/menu and HUD (text edges, gradients, icons, alpha-tested sprites); a lit
field or room (light falloff, highlights, specular speckle, shadows); a foggy
or distant view (fog colour and bands); water or a transparent surface
(blending, reflections, what shows through); alpha-tested edges (foliage,
fences, hair, particles); dark-to-bright gradients and the sky (banding,
dithering, one-LSB steps); effects that mix lighting and fog (glow, torches,
particles). In the moving runs look for shimmering or crawling in gradients
and alpha edges, not for missing objects. A zero `specfast` count on a scene
means the specialized half did not engage there; say so in the report.

### Performance contract (licence boundary and measurement)

- any3ds is **GPL-2.0** and is read as an architecture reference only — no code
  or text is copied. GPL projects are `reference only`; see
  [THIRD_PARTY.md](../THIRD_PARTY.md).
- Numbers that need an iPhone/iPad are marked `needs device`; host numbers are
  never presented as device results. The shipping device path is AOT + Metal via
  `MVK_CONFIG_`-driven MoltenVK, with the `AOT%` badge and `zk_perf` counters as
  the source of truth.
- Codegen experiments use `THREEDS2APPLE_AOT_OPT` / `THREEDS2APPLE_AOT_LTO` /
  `THREEDS2APPLE_AOT_FAST_MATH` and `THREEDS2APPLE_MVK_CONFIG` as listed above.

### GameCatalog and shell manifest

`build-ios-app.sh` writes an empty schema-2 `GameCatalog.json`
(`{"schemaVersion":2,"games":[]}`) for the ROM-free shell and removes it after the
build; the per-game/multi-game pipeline writes schema 2 with
`packFile`/`packABIVersion` (see [builder/README.md](../builder/README.md)).
`package-ipa.sh --manifest FILE` writes the launcher's shell `manifest.json`
(schemaVersion 1: version/build from the app Info.plist, bundle id, bytes and
SHA-256), which the launchers pin and cross-check.

The catalog is a build artifact: installed for the duration of the build and
removed (or restored) on exit, including failures, so a finished build leaves
`git status` clean.

### Diagnostics

The app shows `AOT: linked, active` (linked code accepted),
`AOT: linked, interpreting` (title/ABI mismatch, interpreter fallback) or
`AOT: interpreter shell` (no linked code). Runtime logs use
`zk_create: …`, `AOT active/inactive: …` and `zk_perf: …`.

### Serial compile fallback and troubleshooting

Large generated files can exhaust memory on an 8 GB build VM:
`scripts/build-recomp-ios.sh "ROM/game.cci" game-name --serial-compile` (or
`--code-dir` to reuse an existing C tree).

| Symptom | Likely cause |
|---|---|
| `missing librecomp.a` | 3dsrecomp step did not finish; check its log |
| Undefined `_recomp_*` at app link | `libgame.a` missing or listed before `libzakuro_ios.a` |
| `AOT: linked, interpreting` | title ID/interface mismatch; rebuild both sides |
| `no space left on device` | generated C and object files are large; clean `build/` |
| `the built app contains no GameCatalog.json` | `Resources/` is no longer bundled by `ios/app/project.yml`, or xcodegen ran before the catalog install |
| `invalid GameCatalog.json` | corrupted catalog or a broken `--game-catalog` input (title IDs are 16 upper-case hex digits) |

## Self-checks

| Script | Purpose |
|---|---|
| `tests/aot-selfcheck.sh` | Linux/macOS checks for the AOT build scripts: `bash -n`, title-ID/manifest round-trip, `nm` regressions, `--help` smoke tests, repo hygiene |
| `tests/game-catalog-selfcheck.sh` | Catalog helper: generation, schema validation, builder/script wiring, `--help` checks (Linux and macOS) |
| `tests/desktop-aot-selfcheck.sh` | Desktop pipeline: synthetic ROM import, fake build, schema-v2 catalogue, preview IPA and script safety checks (no Xcode/ROM needed) |
| `tests/perf-selfcheck.sh` | Performance contract: this file's performance section, diagnostics badge, AOT flags, MoltenVK hook |
| `tests/release-selfcheck.sh` | Release gate: synthetic Windows/macOS zips prove `verify-release.sh` accepts launcher + licence texts and rejects missing/altered/extra texts, extra files and ROM payloads (offline, mktemp only) |

## Release

| Script | Purpose |
|---|---|
| `release/assemble-release.sh` | Collect the two platform launcher zips (Windows + macOS), rename them to the canonical `3ds2apple-<ver>-{windows-x64,macos-universal}.zip` names and run the verifier; the licence texts travel inside the zips, so no `SHA256SUMS`/separate license/shell assets are collected |
| `release/verify-release.sh` | Read-only release gate: exactly the two platform zips; each archive is exactly launcher (`.exe` / `.app`) + `LICENSE`/`NOTICE`/`THIRD_PARTY.md` with digests equal to the repository files; no ROM/pack/IPA data |

The full release policy (two assets only, bilingual release notes,
immutable tags) is in [CONTRIBUTING.md](../CONTRIBUTING.md#release-policy).

## Quick start (shell)

```bash
scripts/build-zakuro-ios.sh
scripts/build-ios-app.sh
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple
```

## Quick start (launcher-first GamePacks)

The pure desktop work runs natively on Linux/Windows/macOS; the Apple
compile/link/package steps need macOS. The launchers drive this flow themselves.

```bash
# 1. desktop CLI (Rust workspace member; no Xcode needed)
(cd builder && cargo build -p builder-pack)
CLI=builder/target/debug/3ds2apple-pack

# 2. import the user's own decrypted ROMs and queue packs
"$CLI" packages add --roms "ROM/game.cci"
"$CLI" build --queued            # print the exact macOS script plan
"$CLI" build --queued --fake     # local placeholder packs (not installable)
"$CLI" catalog --all

# 3. macOS: real packs and one multi-game shell IPA
scripts/build-game-pack.sh <name> --title-id 0004000000055E00 \
  --display-name "Game name" --out out --dylib <runtime-provided GamePack.dylib>
scripts/build-multi-game-ipa.sh --packages-dir out/packages --all \
  --base-app ios/app/build/Release-iphoneos/3ds2apple.app

# Linux/Windows layout preview (fake shell + placeholders; NOT installable)
scripts/build-multi-game-ipa.sh --packages-dir out/packages --all \
  --allow-placeholder-dylibs --fake-shell
```

The shell ships an empty schema-2 `GameCatalog.json`; the desktop pipeline writes
schema 2 with `packFile`/`packABIVersion`. See
[builder/README.md](../builder/README.md) for the package layout and catalog
schema and the launcher READMEs for the launcher flows.

Run the self-checks (no Xcode needed):

```bash
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/game-catalog-selfcheck.sh
bash scripts/tests/desktop-aot-selfcheck.sh
bash scripts/tests/perf-selfcheck.sh
```

The local Zakuro patches in `ios/zakuro-ios/patches/` are applied by
`build-zakuro-ios.sh` and again by the cargo path of
`build-linked-ios-lib.sh` (`scripts/lib/zakuro-patches.sh`); application is
idempotent, a patch that no longer applies is a warning (set
`ZAKURO_STRICT_PATCHES=1` to make it fatal) and the checkout under
`third_party/` stays local and gitignored.

## Requirements

- macOS with Xcode and the iOS SDK for `build-ios-app.sh`,
  `build-recomp-ios.sh`, `build-linked-ios-lib.sh` and the real
  `--from-libs`/`--base-app` modes of the desktop scripts.
- Rust with the `aarch64-apple-ios` target for the runtime.
- Rust/cargo for the desktop CLI (`builder/pack`); Linux/Windows need no Xcode
  for `--fake` packs, the fake-shell IPA preview or the printed macOS plan.
- `xcodegen` for the app project.
- Python 3 for helper scripts; `zip` (and `unzip` for verification) for IPA
  packaging/preview.

The game build step needs a local, decrypted ROM that you own. The repository
does not include ROMs or keys.

## Safety

- Every IPA built here is unsigned: sign and install it with the 3ds2apple
  launchers (bundled official Impactor/plumesign on Windows, Xcode on macOS) and
  your own Apple ID.
- Scripts never run `git add` and refuse to overwrite tracked files.
- `ROM/`, `IPA/`, `out/`, `build/`, `third_party/` and `.worktrees/` are
  local-only and gitignored.
