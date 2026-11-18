#!/usr/bin/env bash
# build-gpu-diagnostic-ipa.sh — package the ROM-free shell as GPU A/B
# diagnostic IPAs.
#
# Runs on the macOS build VM only (it needs the iOS SDK for the app build and
# the MoltenVK framework to embed). It builds the unsigned app once with
# scripts/build-ios-app.sh, then writes one diagnostic profile name into each
# copy's Info.plist (key GPUDiagnosticsProfile) and packages one unsigned IPA
# per profile with scripts/package-ipa.sh --require-moltenvk. The app reads the
# key in App.init (MoltenVKTuning.applyFromEnvironment) and applies that
# profile's allow-listed MoltenVK parameters and renderer switches before the
# first Vulkan device, so the IPAs differ in configuration without a rebuild.
#
# The IPAs contain no ROM, game data, keys or signature. They are build
# artifacts under out/ (gitignored): never commit them.
#
# Usage:
#   scripts/build-gpu-diagnostic-ipa.sh
#   scripts/build-gpu-diagnostic-ipa.sh --profiles "baseline mvk renderer"
#   MOLTENVK_FRAMEWORK=... scripts/build-gpu-diagnostic-ipa.sh --out-dir out/gpu-diag
#
# Profiles (see ios/app/Sources/MoltenVKTuning.swift and scripts/README.md):
#   baseline  measures the GPU's own execution time, changes nothing else
#             (first round; kept so old and new builds can be compared)
#   baseline2 baseline built from the 0.1.3 second-round library: the GPU line
#             also splits its time by render target (pass attribution)
#   mvk       baseline + the MoltenVK performance parameters
#   renderer  baseline + the renderer A/B switches (image clears, narrower
#             barriers between render passes)
#   sort      baseline2 + the opaque front-to-back draw sort
#             (ZAKURO_SORT_OPAQUE=1), the second round's early-Z candidate
#   baseline3 baseline built from the 0.1.3 third-round library: the GPU line
#             also carries the per-pass report (each pass's time, draws and
#             what ended the pass before it) and the work-operation counts
#   sort2     baseline3 + the relaxed opaque front-to-back sort, with its
#             sorted/draw and reason counters (ZAKURO_SORT_OPAQUE=1): the line
#             says whether it engaged and why not
#   merge     baseline3 + render-pass merging (ZAKURO_MERGE_PASSES=1): a draw
#             the guest gives no depth buffer into a depth-buffered pass keeps
#             that pass with its depth test and write off
#   capture   baseline3 + duplicate-capture skipping
#             (ZAKURO_DEDUPE_CAPTURE=1)
#   baseline4 baseline built from the 0.1.3 fourth-round library: the GPU line
#             also splits its draw time by draw state (blend, alpha test,
#             texture units, writes, estimated coverage) with the timestamps at
#             the class boundaries rather than one per draw, and counts what
#             safe skips left out
#   noblend   baseline4 + every blending draw written as if the blend were off
#             (ZAKURO_MEASURE_NOBLEND=1): how much of the draw time the blend
#             and its read of the destination cost. measurement only, the
#             picture is wrong
#   flat      baseline4 + every fragment drawn as one color instead of the
#             title's combiners, texture fetches and lighting
#             (ZAKURO_MEASURE_FLAT=1): how much fragment work they add.
#             measurement only, the picture is wrong
#   2x3x      baseline4 with the internal 3D renderer at 2x while the drawable
#             keeps 3x (THREEDS2APPLE_DIAG_RENDER_SCALE=2): how much of the GPU
#             time the 3x target's fill costs. measurement only, the picture is
#             the 2x one upscaled
#   safe      baseline4 + math-equivalent skips of draws that cannot change
#             either buffer (ZAKURO_SAFE_SKIPS=1): the picture must stay the
#             same, and safe_skips N/f says whether it engaged
#   combo     mvk + renderer, for the run after the A/B names a winner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

OUT_DIR="out/gpu-diag"
PROFILES="baseline4 noblend flat 2x3x safe"
STATICLIB="build/ios/libzakuro_ios.a"
APP_DIR="ios/app"
CONFIGURATION="Release"
SKIP_BUILD=0

usage() {
  cat <<'EOF'
Package GPU A/B diagnostic shell IPAs (Run on the macOS build VM).

Usage:
  scripts/build-gpu-diagnostic-ipa.sh [options]

Options:
  --profiles "A B C"   profiles to package
                       (default: baseline4 noblend flat 2x3x safe)
                       known: baseline baseline2 baseline3 baseline4 mvk
                       renderer sort sort2 merge capture noblend flat 2x3x
                       safe combo
  --out-dir DIR        output directory (default: out/gpu-diag, gitignored)
  --staticlib PATH     Zakuro iOS static library, relative to repo root
                       (default: build/ios/libzakuro_ios.a)
  --app-dir DIR        XcodeGen project directory (default: ios/app)
  --configuration CFG  xcodebuild configuration (default: Release)
  --skip-build         reuse an existing app at
                       <app-dir>/build/<configuration>-iphoneos/3ds2apple.app
  -h, --help           show this help

Environment:
  MOLTENVK_FRAMEWORK   MoltenVK.framework directory to embed (required: a
                       diagnostic build needs the presented GPU path). When
                       unset, build/third_party/moltenvk and
                       build/third_party/MoltenVK are searched.

Outputs (all under the output directory):
  <name>.ipa                  one per profile, unsigned, no ROM/game data
  manifest.json               name, profile, bytes and SHA-256 per IPA
  README.txt                  the A/B procedure and what each profile does
  build-<timestamp>.log       the app build log
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[gpu-diag] %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profiles) PROFILES="${2:?--profiles needs a list}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?--out-dir needs a directory}"; shift 2 ;;
    --staticlib) STATICLIB="${2:?--staticlib needs a path}"; shift 2 ;;
    --app-dir) APP_DIR="${2:?--app-dir needs a directory}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:?--configuration needs a value}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'This script must run on macOS with Xcode installed.\n' >&2
  exit 1
fi

APP="$APP_DIR/build/${CONFIGURATION}-iphoneos/3ds2apple.app"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_LOG="$OUT_DIR/build-$STAMP.log"

# 1) the app: one build serves every profile, which differs only by the
# Info.plist key written into a copy below.
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  log "building the unsigned app (log: $BUILD_LOG)"
  "./scripts/build-ios-app.sh" --app-dir "$APP_DIR" --staticlib "$STATICLIB" --configuration "$CONFIGURATION" >"$BUILD_LOG" 2>&1 \
    || { tail -40 "$BUILD_LOG" >&2; die "build-ios-app.sh failed, see $BUILD_LOG"; }
  log "built: $APP"
fi
[[ -d "$APP" ]] || die "no app at $APP (build it or drop --skip-build)"

# 2) MoltenVK: a diagnostic build has to take the presented GPU path so the
# GPU time the A/B measures is the real one, and the system Metal HUD can
# attach to the layer.
MOLTENVK="${MOLTENVK_FRAMEWORK:-}"
if [[ -z "$MOLTENVK" ]]; then
  for candidate in \
    "build/third_party/moltenvk/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework" \
    "build/third_party/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework"; do
    if [[ -d "$candidate" ]]; then MOLTENVK="$candidate"; break; fi
  done
fi
[[ -n "$MOLTENVK" && -d "$MOLTENVK" ]] \
  || die "MOLTENVK_FRAMEWORK is not set and no downloaded framework was found; see ios/app/README.md (never committed)"
export MOLTENVK_FRAMEWORK="$MOLTENVK"
log "MoltenVK: $MOLTENVK"

# 3) one IPA per profile.
STAGE="$OUT_DIR/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
MANIFEST="$OUT_DIR/manifest.json"
printf '{\n  "schemaVersion": 1,\n  "generatedAt": "%s",\n  "moltenvk": "%s",\n  "profiles": [\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MOLTENVK" > "$MANIFEST"
FIRST=1
for profile in $PROFILES; do
  case "$profile" in
    baseline|baseline2|baseline3|baseline4|mvk|renderer|sort|sort2|merge|capture|noblend|flat|2x3x|safe|combo) ;;
    *) die "unknown profile: $profile (known: baseline baseline2 baseline3 baseline4 mvk renderer sort sort2 merge capture noblend flat 2x3x safe combo)" ;;
  esac
  # keep the bundle's own name: the profile is an Info.plist key, not an app
  # rename, so every IPA unzips to Payload/3ds2apple.app
  mkdir -p "$STAGE/$profile"
  copy="$STAGE/$profile/3ds2apple.app"
  cp -R "$APP" "$copy"
  plutil -replace GPUDiagnosticsProfile -string "$profile" "$copy/Info.plist" 2>/dev/null \
    || plutil -insert GPUDiagnosticsProfile -string "$profile" "$copy/Info.plist"
  name="3ds2apple-gpu-$profile"
  log "packaging $name ($profile)"
  "$SCRIPT_DIR/package-ipa.sh" "$copy" --name "$name" --out-dir "$OUT_DIR" --require-moltenvk \
    >>"$BUILD_LOG" 2>&1 || { tail -30 "$BUILD_LOG" >&2; die "package-ipa.sh failed for $profile"; }
  ipa="$OUT_DIR/$name.ipa"
  [[ -f "$ipa" ]] || die "expected IPA not written: $ipa"
  bytes="$(wc -c < "$ipa" | tr -d '[:space:]')"
  sha="$(shasum -a 256 "$ipa" | awk '{print $1}')"
  if [[ "$FIRST" -eq 1 ]]; then FIRST=0; else printf ',\n' >> "$MANIFEST"; fi
  printf '    {"name": "%s", "profile": "%s", "bytes": %s, "sha256": "%s"}' \
    "$name" "$profile" "$bytes" "$sha" >> "$MANIFEST"
  log "$ipa ($bytes bytes, sha256 $sha)"
done
printf '\n  ]\n}\n' >> "$MANIFEST"
rm -rf "$STAGE"

# 4) what to do with them.
cat > "$OUT_DIR/README.txt" <<'EOF'
3ds2apple GPU A/B diagnostic IPAs

What they are: the unsigned ROM-free shell, built from this repository, with
the MoltenVK framework embedded. Each IPA carries one diagnostic GPU profile;
nothing else in the code differs between them. They contain no ROM, game data,
keys or signature. Install one at a time (they share the bundle id, so
installing the next replaces the previous), and only on a device with the
tester's own game data pushed by the launcher.

Profiles
  baseline3 measures the GPU's real execution time (ZAKURO_GPU_TIMES=1) and is
            the control for the third round. The zk_gpu line lists the render
            targets by GPU time (passes and draws each) and carries the
            per-pass report: each pass's GPU milliseconds and draws, whether it
            had depth or drew into a twin, what ended the pass before it, and
            the window's pass-break reasons. It also counts the kinds of work
            the batches started (transfer, capture, upload, ...).
  sort2     baseline3 + the relaxed opaque front-to-back draw sort
            (ZAKURO_SORT_OPAQUE=1): opaque draws whose state allows it (depth
            test and write on, no blend or logic op, no stencil writes) are
            recorded nearest first so the early depth test drops the fragments
            hidden behind them. The line gains `sorted N/f of M/f draws` and a
            per-reason count (no-depth, blend, gpu-vertices, ...) whenever the
            sort is on, so a run that does not engage says why; the picture
            must stay the same.
  merge     baseline3 + render-pass merging (ZAKURO_MERGE_PASSES=1): a draw
            the guest gives no depth buffer, into a color buffer a pass with
            depth is already drawing into, keeps that pass with its depth test
            and write off, so the pass does not end and begin again. The line
            gains `merged N/f`; the picture must stay the same.
  capture   baseline3 + duplicate-capture skipping
            (ZAKURO_DEDUPE_CAPTURE=1): a capture asked for again in the same
            batch, with nothing drawn since, is not recorded again. The line
            gains `captures_skipped N/f` when it happens.
  baseline4 the fourth round's control: the zk_gpu line carries draw_classes,
            the GPU draw time split by draw state (blend kind, alpha test,
            texture units, writes, estimated coverage) with the timestamps
            written at the class boundaries instead of once per draw. Each
            class reports ms/f, draws/f and estimated Mpx/f (its triangles'
            area, console pixels times the render scale squared), so the
            blended and opaque draws are told apart and the estimated pixels
            show how much overdraw the frame has. The timestamps are written
            only where the class changes, so a scene with few state changes
            pays almost nothing for the buckets; the class milliseconds can add
            up to slightly less than the draw total (twin draws and the setup
            between passes carry no class); compare within this round's
            baseline4 rather than with a third-round build, which has no class
            timestamps.
  noblend   baseline4 + ZAKURO_MEASURE_NOBLEND=1: every blending draw is
            written as if the blend were off. The picture is wrong; the drop
            in gpu_exec is what blending and its read of the destination cost.
  flat      baseline4 + ZAKURO_MEASURE_FLAT=1: every fragment is drawn as one
            color, the title's combiners, texture fetch, lighting, procedural
            texture and fog neutralized. The picture is wrong; the drop in
            gpu_exec is what the fragment work costs beyond fill and blending,
            and the difference from noblend separates the two.
  2x3x      baseline4 + THREEDS2APPLE_DIAG_RENDER_SCALE=2: the internal 3D
            renderer draws at 2x while the Metal drawable keeps the setting's
            3x, so the presented picture is the 2x one upscaled. The drop in
            gpu_exec against baseline4 is the 3x target's fill cost. Quality
            is visibly lower: this is a measurement, not a product.
  safe      baseline4 + ZAKURO_SAFE_SKIPS=1: draws whose state cannot change
            either buffer are left out as a whole (nothing written, depth and
            stencil writes off, or a blend that leaves the destination as it
            is). The picture must stay exactly the same; the line gains
            safe_skips N/f and the Mpx/f they would have covered, so a run
            where the count is 0 says the candidate cannot help that title.
  baseline  the first round's control, kept so an old IPA and a new one can be
            compared on the same scene.
  baseline2 the second round's control (render-target pass attribution).
  sort      the second round's sort build, kept for an old IPA comparison.
  mvk       baseline + MoltenVK performance parameters: Metal argument buffers,
            prefill of Metal command buffers, MTLHeap, more Metal command
            buffers in flight, present via command buffer, async queue submits.
  renderer  baseline + the renderer's 0.1.3 A/B switches: image clears where
            they can be (no attachment load/store for a full clear) and a
            narrower barrier between render passes.
  combo     mvk + renderer, for the confirmation run after the A/B names a
            winner.

Procedure (same scene, same duration, one profile per run)
  1. Install one IPA (Sideloadly/AltStore, user's own signing). Start the app,
     set Settings -> Performance -> Render resolution to 3x, let the same scene
     settle for ~10 s, then record for 60 s without touching the screen.
  2. Note the system Metal HUD's GPU time and fps (or take a screenshot with
     the HUD on) AND export diagnostics (Settings -> More -> Export logs;
     the file is also in Documents/Diagnostics and pullable with devpush get).
  3. Repeat for every profile in the same scene and order (background/exit the
     app between runs so the pipeline cache is warm from the second run on;
     report which run was cold).
  4. Send the diagnostics files: they carry gpu_profile=, gpu_exec_ms_per_frame=,
     gpu_times_line= (per-kind GPU time, render-target pass attribution,
     per-pass time/draws/break reasons, work-operation counts, passes,
     barriers, draws, host waits, fragments, and when the opaque sort is on
     `sorted N/f of M/f draws` with the reasons) and the frame interval.

Compare baseline4 with noblend, flat and 2x3x on the same scene: those three
are measurements, so their picture is expected to differ. baseline4 - flat is
what the fragment work (combiners, fetches, lighting) costs; baseline4 -
noblend is what blending and its destination read cost; 2x3x is what the 3x
target's fill costs, and it is the number that says the scene is fill-rate
bound. Compare baseline4 against the same scene's third-round control only with care:
the class timestamps add a small, bounded number of query writes, so a
sub-millisecond difference is the measurement, not a regression. Then compare
safe with baseline4, where the picture must be the same:
only a math-equivalent change with at least a 3-5% real GPU-time gain at 3x
and no picture change goes into the release build; otherwise the 3x behaviour
stays exactly as it is. A profile that lowers gpu_exec while the shaded
fragments stay the same changed GPU scheduling or bandwidth, not the emulated
shading.

Reading the files
  gpu_exec_ms_per_frame is the real GPU execution time from the renderer's own
  timestamp queries, averaged over 60-frame windows; the system Metal HUD shows
  the same number. timing_ms_run_gpu is the host command-walk time and is not
  the GPU's time. The zk_gpu: line splits the GPU time into draw/clear/upload/
  copy/capture/barrier and reports render passes, barriers, draws, host waits
  and shaded vertices/primitives/fragments per frame; a profile that halves
  gpu_exec while the fragments stay the same did its work on GPU scheduling or
  bandwidth rather than on shading.
EOF

log "wrote $MANIFEST and $OUT_DIR/README.txt"
ls -l "$OUT_DIR"/*.ipa