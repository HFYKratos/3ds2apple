# ios/app — 3ds2apple SwiftUI shell

Minimal SwiftUI app that links the Zakuro iOS static library
(`build/ios/libzakuro_ios.a`, arm64, **no JIT**, interpreter fallback only).

- **I1** (merged): the shell boots without a ROM, proves the static library is
  linked via `zk_screen_width()` / `zk_screen_height()`, and explains that no
  ROM is loaded.
- **I2-T1** (merged): import a decrypted `.3ds` / `.cci` from Files, copy it
  into `Documents/roms/`, and load it with `zk_create()` on a background serial
  queue. Failures show the readable `zk_last_error()` text.
- **I2-T2** (merged): a `CADisplayLink`-driven frame loop runs
  `zk_run_frame()` on the same serial queue and displays the upper 400×240 and
  lower 320×240 screens (`zk_read_screen` RGBA8 → `CGImage`) above each other,
  with an fps / frames / last-result status line.
- **I3-T1** (merged): input. A semi-transparent on-screen pad (D-pad,
  A/B/X/Y, Start/Select, L/R), the lower screen as the 3DS touchscreen, and
  MFi/Xbox/DualSense controllers all feed one `InputState`; `zk_set_input` runs
  on the runtime queue immediately before every `zk_run_frame`.
- **I3-T4** (merged): audio. The runtime queue drains `zk_take_audio`
  (interleaved stereo i16 at Zakuro's 32730 Hz DSP rate) into a ring buffer;
  an `AVAudioSourceNode` plays it through `AVAudioEngine` without blocking the
  frame loop. Mute is persisted and the status line shows
  `audio: on|off|muted|failed`.
- **I3-T6** (this branch): performance HUD. Each frame is timed on the runtime
  serial queue with `mach_absolute_time()` — `renderFrame` total,
  `zk_run_frame`, both `zk_read_screen` calls, CGImage creation and the audio
  pump — and shown as avg/max/last milliseconds under the status line. Screen
  RGBA buffers and their `CGDataProvider` are reused instead of reallocated
  every frame. See "Performance HUD (I3-T6)" below for how to read it.

## Layout

| Path | Purpose |
|---|---|
| `project.yml` | XcodeGen spec — the source of truth, do not hand-edit `*.xcodeproj` |
| `Sources/App.swift` | `@main` SwiftUI entry point |
| `Sources/ContentView.swift` | UI: title, ROM card, dual-screen view, fps/frames status line |
| `Sources/ROMSession.swift` | ROM copy, `zk_create` / `zk_destroy`, `zk_last_error` text, relative-path persistence, display-link frame loop, per-frame timing |
| `Sources/ROMDocumentPicker.swift` | `UIDocumentPickerViewController` wrapper (`public.data`, opens files in place) |
| `Sources/ScreenImage.swift` | reusable RGBA8 screen buffer pool + `CGDataProvider` recycling → `CGImage` |
| `Sources/FrameTiming.swift` | `mach_absolute_time` phase accumulators + HUD snapshot types |
| `Sources/InputState.swift` | thread-safe input merge + `ZK_BUTTON_*` bit mapping |
| `Sources/GameControllerInput.swift` | MFi/Xbox/DualSense → `InputState` |
| `Sources/TouchControlsView.swift` | semi-transparent on-screen pad (D-pad, ABXY, Start/Select, L/R) |
| `Sources/AudioOutput.swift` | `zk_take_audio` i16 ring buffer → `AVAudioSourceNode`/`AVAudioEngine` |
| `../ZakuroBridge.h` | hand-written C ABI (`zk_*`), imported via the bridging header |
| `../../scripts/build-zakuro-ios.sh` | builds the static lib on macOS (I0) |

Generated `3ds2apple.xcodeproj/` and `build/` are **build artifacts**: never
commit them.

Device-side layout once a ROM is imported (inside the app container, never in
git):

```text
Documents/roms/<name>.3ds     # copied import; reused when the same name is picked again
Documents/data/<rom-stem>/    # data_dir passed to zk_create (saves/cache)
```

## Prerequisites (macOS build VM)

- macOS + Xcode 16.4 with the iOS 18.5 SDK (M0 baseline).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- The Zakuro static library, built once per FFI change:

  ```bash
  # from the repo root
  scripts/build-zakuro-ios.sh
  ls -lh build/ios/libzakuro_ios.a   # expected: ~52 MB, arm64
  ```

No iOS Simulator runtime is needed (and on this VM it is not installed).

## Quick path — automated build (I1-T2 scripts)

Once `scripts/build-ios-app.sh` and `scripts/package-ipa.sh` (build-infra,
I1-T2) are merged, prefer them over the manual steps below:

```bash
# from the repo root, on the macOS VM
scripts/build-ios-app.sh                 # xcodegen + xcodebuild; log under ios/app/build/logs/
scripts/build-ios-app.sh --keep-project  # keep ios/app/3ds2apple.xcodeproj for Xcode
scripts/package-ipa.sh                   # -> IPA/<name>.ipa + SHA256 (unsigned)
```

`build-ios-app.sh` fails fast when `<repo>/build/ios/libzakuro_ios.a` is missing
or empty, and removes the generated `.xcodeproj` afterwards unless it is
gitignored (it checks `git check-ignore`), so `git status` stays clean.
The manual commands and the linkage verification below remain the reference for
what the script does and the fallback when it is unavailable.

## Generate the Xcode project

Run from the repo root:

```bash
cd ios/app
xcodegen generate
```

This writes `ios/app/3ds2apple.xcodeproj`. Re-run it after any edit to
`project.yml` and after adding/removing a file under `Sources/` — XcodeGen
snapshots the directory listing at generation time.

> The generated `.xcodeproj` is a build artifact and is already covered by the
> root `.gitignore` (`ios/app/3ds2apple.xcodeproj/`, `ios/app/build/`), so
> `xcodegen` never dirties `git status`.

## Build (unsigned, device SDK)

```bash
cd ios/app

xcodebuild \
  -project 3ds2apple.xcodeproj \
  -target 3ds2apple \
  -sdk iphoneos \
  -configuration Release \
  SYMROOT="$PWD/build" \
  OBJROOT="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

Products:

- App bundle: `ios/app/build/Release-iphoneos/3ds2apple.app`
- Executable: `ios/app/build/Release-iphoneos/3ds2apple.app/3ds2apple`

`-target` (not `-scheme`) is deliberate: the VM has no simulator runtime, and
scheme builds resolve destinations and fail with `Found no destinations`
(docs/milestones.md, M0 pitfall 5). `CODE_SIGNING_*` are also set in
`project.yml`; passing them on the command line keeps ad-hoc invocations safe.

`ios/app/build/` matches the repo-root `.gitignore` `build/` pattern, so build
output never dirties git.

## Verify the static library really linked

```bash
# 1. The 8 zk_* entry points exist in the archive we link.
nm -g ../../build/ios/libzakuro_ios.a \
  | grep -E ' _zk_(create|run_frame|screen_width|screen_height|read_screen|take_audio|set_input|destroy)$'
# expected: 8 defined (T) symbols

# 2. The app binary is arm64 and (usually) still carries them.
APP=build/Release-iphoneos/3ds2apple.app
file "$APP/3ds2apple"
nm -g "$APP/3ds2apple" | grep ' _zk_' || echo "stripped — check the archive instead"
ls -lh "$APP/3ds2apple"
```

Runtime probe: the UI must show `Upper screen 400 × 240`, `Lower screen
320 × 240` (values come from the C calls — hardcoded strings would mean the
calls were optimized away) plus a `No ROM loaded` card. Device log:

```bash
idevicesyslog | grep '\[3ds2apple\]'
# [3ds2apple] zk_screen_width(0)=400 zk_screen_height(0)=240 zk_screen_width(1)=320 zk_screen_height(1)=240
# [3ds2apple] no ROM imported yet
```

Binary size: `zk_screen_width()` alone is tiny, but referencing `zk_create()`
makes the linker pull in the Zakuro loader/core, so the `.app` grows to tens of
MB (the static library is ~52 MB). That is expected, not a regression.

## ROM import (I2-T1)

The app ships no game data. You bring your own **decrypted** `.3ds` / `.cci`
(the loader does not handle encrypted ROMs or keys).

### Flow

1. Make the ROM visible to the Files app (AirDrop it to the phone, put it in
   iCloud Drive, or use a Files provider / USB drive), then tap
   **Import ROM…** in the app. The app also enables Files/iTunes document
   sharing (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` in
   `project.yml`), so a ROM dropped into the app's `Documents/` from Finder is
   visible to the picker too.
2. The picker opens with `public.data` — `.3ds` / `.cci` have no registered
   `UTType` on iOS, so the extension is validated after selection.
3. `ROMSession` copies the picked file to `Documents/roms/<name>` on a
   background serial queue. An existing file with the same name is reused
   instead of copied again, and the copy goes through a temporary name so an
   interrupted import cannot leave a truncated ROM.
4. `zk_create("Documents/roms/<name>", "Documents/data/<rom-stem>")` runs on the
   **same serial queue**, never on the main thread (it can take seconds).
5. Success → green `Loaded: <name>`. Failure → the readable
   `zk_last_error()` text is copied (`String(cString:)`) **inside the same
   queue block** because the error slot is thread-local, then shown in the card
   and logged with `NSLog` for `idevicesyslog`.
6. **Unload ROM** calls `zk_destroy` and returns to the no-ROM state; picking
   another ROM destroys the previous handle first. The imported file stays in
   Documents.
7. The last successfully loaded ROM's **relative** path is persisted in
   `UserDefaults` (`I2.lastROMRelativePath`) and offered as
   **Load “<name>”** after relaunch — relative because the absolute container
   path changes between installs and updates.

Only one handle exists at a time. Every `zk_*` call on it happens on the
`com.kratos.3ds2apple.zakuro-runtime` serial queue (threading rules:
`docs/integration.md`, `ios/zakuro-ios/README.md`).

### What to expect on device

| Phase | UI | Device log (`idevicesyslog`) |
|---|---|---|
| nothing imported | "No ROM loaded" + Import button | `no ROM imported yet` |
| importing | spinner + "Importing <name>…" | `imported ROM: …` or `reusing imported ROM: …` |
| loading | spinner + "Starting Zakuro…" | `zk_create: loading …` |
| loaded, before first frame | black screens + "Waiting for first frame…" | `zk_create OK after …`, `frame loop started` |
| running | both screens + `N fps · N frames · last: completed` + perf HUD (ms table) | frame-loop logs + one `perf:` line every ~2 s (see below) |
| input | overlay pad / touch / controller usable, "Controller: …" when a pad is connected | `controller support started` |
| audio | status line `audio: on`; game sound while frames run | `audio started: 32730 Hz stereo i16 → AVAudioEngine` |
| exit / fault | "Runtime stopped" or red "Could not load ROM"; last frame kept | `frame loop ending: …`, `frame loop stopped` |
| app backgrounded | "Runtime stopped … Load the ROM again" | `zk_destroy: runtime released` |

Quitting or relaunching the app never crashes: the handle is released on
Unload, on replace, on background, and (best effort) in `ROMSession.deinit`.

### Not in this task

- 3dsrecomp static linking, the GLES/Metal renderer and the performance
  baseline are separate I3 tasks (see `docs/pocket-native.md`).
- Hardware rendering (MoltenVK) is later; I2 uses the software screens.

## Frame loop (I2-T2)

Once `zk_create()` succeeds the app starts a 60 Hz `CADisplayLink` on the main
thread. Each tick enqueues at most one frame on the runtime serial queue — if
the previous frame is still running, the tick is dropped, so the loop never
builds up a backlog.

Per frame (runtime queue, one handle only):

1. Snapshot `InputState` and push it with `zk_set_input` (see "Input" below).
2. `zk_run_frame(system)`:

   | result | meaning | reaction |
   |---|---|---|
   | `0` `ZK_FRAME_COMPLETED` | frame rendered | read both screens, publish |
   | `1` `ZK_FRAME_EXITED` | game asked to exit | stop loop, `zk_destroy`, "Runtime stopped" |
   | `-1` `ZK_FRAME_FAULTED` | CPU fault | stop loop, `zk_destroy`, red error card |
   | `-2` `ZK_FRAME_BAD_HANDLE` | invalid handle | same as fault |

3. `zk_read_screen(system, 0, …)` → 400 × 240 × 4 = 384 000 bytes and
   `zk_read_screen(system, 1, …)` → 320 × 240 × 4 = 307 200 bytes of RGBA8.
   The pixel buffers come from a small pool (`ScreenFrameBufferPool`: two
   buffers per screen, one allocated on demand while old images are still
   alive, capped at three). A buffer is handed to `CGImage` through a
   `CGDataProvider` whose release callback recycles it once the image is
   gone — so a per-frame allocation and its 300–400 KB memset are avoided
   without ever writing a buffer the screen still shows. A short read is
   logged once and skipped so the previous frame stays on screen.
4. `CGImage` → `@Published` on the main queue; SwiftUI shows the upper screen
   above the lower one with `scaledToFit`, preserving the ratio reported by
   `zk_screen_width()` / `zk_screen_height()`.
5. `zk_take_audio` is drained after the frame and pushed into the audio ring
   buffer (see "Audio (I3-T4)"); like every other step it runs on the runtime
   queue, never on the main thread.

Status line: `NN fps · N frames · last: completed|exited|faulted|bad handle`,
followed by `audio:` and `AOT:` state. fps is measured over a 0.5 s window and
is the *emulated* frame rate — the pure interpreter is usually far below 60
fps, so many display-link ticks are dropped.

I3-T6 instrumentation wraps the steps above in `mach_absolute_time()`
timestamps on the runtime queue (`FrameTimingWindow` in
`Sources/FrameTiming.swift`) and publishes a snapshot to the main queue every
0.5 s, next to the fps update. Only the immutable snapshot crosses threads; the
HUD itself does no measurement and never touches the runtime handle.

Lifecycle: the loop stops **and** the handle is destroyed on **Unload**, on
**Change ROM**, when the app goes to the **background** (`scenePhase ==
.background`), on exit/fault, and in `ROMSession.deinit`. `zk_destroy` guards a
nil handle, so there is never a double destroy. The last frame stays visible
after a stop until the next load or unload clears the screens.

## Input (I3-T1)

All input sources are merged into one lock-protected `InputState` and pushed by
exactly one place: `ROMSession.renderFrame()` calls

```c
zk_set_input(system, buttons, circleX, circleY, touch, touchX, touchY);
```

on the runtime serial queue **immediately before** each `zk_run_frame()` — the
same one-queue/one-handle rule as the rest of the runtime. The UI and the
controller handlers only write into `InputState`; nothing else touches the
handle.

### Button mapping

`buttons` is the 3DS HID bitmask (`ZK_BUTTON_*` in `ios/ZakuroBridge.h`):

| 3DS button | Bit | On-screen control | Controller |
|---|---|---|---|
| A | `1 << 0` | A | A / Cross |
| B | `1 << 1` | B | B / Circle |
| Select | `1 << 2` | Select | Options / Share |
| Start | `1 << 3` | Start | Menu / Options |
| Right | `1 << 4` | ▶ | D-pad right |
| Left | `1 << 5` | ◀ | D-pad left |
| Up | `1 << 6` | ▲ | D-pad up |
| Down | `1 << 7` | ▼ | D-pad down |
| R | `1 << 8` | R | R1 / RB |
| L | `1 << 9` | L | L1 / LB |
| X | `1 << 10` | X | X / Square |
| Y | `1 << 11` | Y | Y / Triangle |
| ZL | `1 << 14` | — | L2 / LT |
| ZR | `1 << 15` | — | R2 / RT |

The overlay D-pad is the digital 3DS D-pad. The Circle Pad (analog,
`circleX` / `circleY`, −1…1) comes from the controller's left thumbstick; the
overlay has no analog stick yet (see limits).

### On-screen controls

- Semi-transparent pad below the screens: L / Select / Start / R row, D-pad on
  the left, A/B/X/Y on the right.
- **Hide controls / Show controls** in the ROM card; the choice persists
  (`@AppStorage("I3.showTouchControls")`). Hiding the pad releases every
  on-screen button so nothing stays stuck.
- The lower screen is the 3DS touchscreen while a runtime is loaded: drag/tap
  maps into 320×240 bottom-screen pixels and is released on lift-off.

### Controllers

- GameController framework; any `GCExtendedGamepad` (MFi, Xbox, DualSense).
  Hot-plug is supported via `GCControllerDidConnect` / `…DidDisconnect`.
- D-pad, A/B/X/Y, L1/R1, L2/R2 (→ ZL/ZR), Menu (→ Start), Options (→ Select);
  left thumbstick → Circle Pad.
- The connected controller's name appears under the screens.
- Controller and on-screen pad can be used at the same time (masks are ORed).

### Lifecycle / reset

Input is cleared on Unload, Change ROM, app background, runtime exit/fault and
in `deinit`, so a held button or touch never leaks into the next runtime.
`deinit` also stops the controller observers.

### Known limits

- No analog Circle Pad on the on-screen pad (use a controller); no C-stick
  (right thumbstick is ignored).
- Touchscreen is basic: single contact, no multi-touch, and the drag competes
  with the `ScrollView` when it starts on the lower screen.
- No tilt/gyro, microphone, rumble or haptics yet.
- Input is sampled once per frame (before `zk_run_frame`); a tap shorter than
  one frame can be missed.
- Pokémon Y language-screen check: D-pad ▼/▲ + A.

## Audio (I3-T4)

`zk_take_audio` returns interleaved stereo **i16** samples at Zakuro's
`AUDIO_SAMPLE_RATE` (3DS DSP, 32730 Hz). It is drained on the runtime serial
queue right after each successful frame and pushed into a fixed ring buffer;
an `AVAudioSourceNode` (float32, 32730 Hz, 2 ch) plays that buffer through
`AVAudioEngine`. The engine's mixer converts to the device sample rate, so the
frame loop never waits for audio and no audio work happens on the main thread.

| Piece | Value |
|---|---|
| Source format | float32, 32730 Hz, 2 channels, non-interleaved |
| Ring capacity | 32 730 frames (≈1 s), interleaved i16 |
| Scratch batch | 16 384 frames per frame; whatever the runtime has is drained |
| Overflow policy | drop the **oldest** buffered audio so latency stays bounded |
| Underrun policy | render block pads the remainder with silence (no blocking) |
| Audio session | `.playback` (ignores the silent switch), IO buffer 10 ms |

### Lifecycle

- Started after a successful `zk_create` (same main-thread hop as the display
  link). `audio: on` appears in the status line.
- Stopped and cleared on **Unload**, **Change ROM**, when the app goes to the
  **background**, and on runtime exit/fault; the audio session is deactivated
  with `.notifyOthersOnDeactivation`.
- **Mute audio / Unmute audio** in the ROM card, persisted via
  `@AppStorage("I3.audioMuted")`. Muting drops buffered audio immediately so
  unmuting never replays stale sound.
- Degradation: if the audio session or engine cannot start, the app keeps
  running and the status line shows `audio: failed` plus the reason.

### Why it can sound choppy before 3dsrecomp

The loop is driven by the display link, not by the audio clock. The runtime
produces 32730 samples per **emulated** second; while emulation runs below real
time (e.g. 20–30 fps of a 60 fps game) it produces only 30–50 % of the samples
the device consumes, so the ring underruns and short silent gaps are expected.
This is a speed problem, not an audio-buffer bug — AOT/3dsrecomp and the
renderer work raise fps and the gaps shrink. Nothing outside the audio pipeline
is affected.

## Performance HUD (I3-T6)

The screens card shows a compact timing table below the fps/status line as soon
as a runtime is loaded. Every value is in **milliseconds**, measured on the
runtime serial queue with `mach_absolute_time()` (monotonic — wall-clock or
timezone changes cannot skew it) and refreshed twice per second together with
the fps line.

| Row | What it times |
|---|---|
| `total` | the whole `renderFrame` work item: input snapshot + `zk_set_input` + `zk_run_frame` + both `zk_read_screen` calls + both CGImages + the audio pump (measured up to, not including, the main-queue publish) |
| `run` | `zk_run_frame(system)` alone — the emulated/rendered 3DS frame |
| `read top` | `zk_read_screen(system, 0, …)`: copy of the 400 × 240 RGBA8 upper screen |
| `read bottom` | `zk_read_screen(system, 1, …)`: copy of the 320 × 240 RGBA8 lower screen |
| `CGImage` | both CGImage creations of the frame (data provider + image object; no pixel copy — the image borrows the RGBA buffer, or the transient `Data` on the pool-exhaustion fallback) |
| `audio` | `zk_take_audio` drain into the audio ring buffer |

Columns:

- `avg` — mean over the last 0.5 s window.
- `max` — worst single frame since the frame loop started (reset on every
  successful load/ROM change; the whole table is cleared on Unload).
- `last` — the most recent executed frame. `—` until a phase has a sample.

The original status line (`N fps`, `N frames`, `last: completed|exited|faulted|bad handle`,
`audio: on|off|muted|failed`, `AOT: linked, active|linked, interpreting|interpreter shell|?`)
stays above the table and is still the first thing to check.

### How to read it

1. Start from `total`. At 28 fps one executed frame occupies the runtime queue
   for ≈ 1/28 s ≈ **35 ms**, so `total` should sit near 35 ms; the 26 fps
   interpreter baseline is ≈ 38 ms. `total` covers runtime-queue work only —
   display-link ticks dropped by the backpressure gate are not counted, which
   is why `fps ≈ 1000 / total` is the expected relation.
2. Compare `run` with `total`. On Pokémon Y (AOT linked, active) `run` is
   expected to be ~85–95 % of `total`. If `run / total` is below ~70 %,
   presentation or the audio pump is eating the frame — that is the part a
   renderer/audio change can still win. At ~95 %, only emulation/AOT work
   raises fps.
3. `read top` and `read bottom` copy 384 000 + 307 200 bytes per frame. Expect
   well under 1 ms each; sustained > 2 ms is unusual on this hardware and worth
   reporting together with fps.
4. `CGImage` is normally ~0.1–0.8 ms for both screens. A sustained rise means
   CoreGraphics setup is getting expensive; a backlog of retained images shows
   up in the `total` gap in point 7 instead (transient buffer allocations when
   the pool runs dry), not in this row.
5. `audio` is normally < 0.5 ms and runs after `zk_run_frame`, so it does not
   lengthen the emulated frame itself; it still adds to `total` (and therefore
   to the frame interval), so a sustained rise costs fps.
6. `total` much smaller than `1000 / fps` (e.g. 8 ms with 20 fps) means the
   runtime queue is fast but ticks are being dropped: look at the main thread
   (SwiftUI redrawing, another main-thread task), not at Zakuro.
7. A sustained gap where `total` is clearly larger than
   `run + read top + read bottom + CGImage + audio` comes from the small
   uncounted parts of the work item: the input snapshot, the stats/log
   bookkeeping at window boundaries, and — only when the buffer pool has no
   free buffer left — the transient 300–400 KB allocation. Named phases plus
   that gap should add up to `total`.

The same values are logged every ~2 s as one `perf:` line for
`idevicesyslog`, so a 20-minute soak can be analysed without screenshots:

```text
[3ds2apple] perf: fps=28.3 frames=1420 | total=35.1/41.2/34.8 run=32.4/38.9 readTop=0.42/0.61 readBottom=0.33/0.52 image=0.31/0.58 audio=0.12/0.44 ms (avg/max; total avg/max/last)
```

### Expected ranges (Pokémon Y, iPhone 14 Pro Max, first 5 minutes)

| Row | 28 fps AOT (linked, active) | Notes |
|---|---|---|
| `total` | 33–40 ms | tracks `1000 / fps` |
| `run` | 30–37 ms | dominates when the emulated frame is CPU-bound |
| `read top` | 0.1–0.8 ms | 384 KB copy |
| `read bottom` | 0.1–0.7 ms | 307 KB copy |
| `CGImage` | 0.1–0.8 ms | both images, no pixel copy |
| `audio` | 0.05–0.5 ms | depends on how many samples the frame produced |

These are order-of-magnitude expectations, not budgets: the ratio between rows
is what identifies the bottleneck, and thermal throttling/device generation
shift the absolute values. When reporting a performance problem, record the
whole row with fps and the AOT status.

### What the HUD cannot tell you

- It does not split `zk_run_frame` into CPU emulation vs PICA software
  rasterisation; a slow renderer shows up inside `run`.
- It does not time the main thread (SwiftUI `Image` drawing). Use Instruments'
  Time Profiler for that, or compare `total` with `1000 / fps` as above.
- It does not time `zk_create` / ROM import / audio-engine start (startup
  one-offs, logged separately).
- It only runs while frames execute: after a clean exit or fault the last
  snapshot stays visible with `fps = 0`; Unload or backgrounding releases the
  runtime and clears the screens (and therefore the table).

## Package an unsigned IPA

`scripts/package-ipa.sh` (I1-T2, owned by build-infra) automates this, writing
`IPA/<name>.ipa` plus a SHA256; the manual equivalent:

```bash
cd ios/app/build/Release-iphoneos
rm -rf Payload 3ds2apple-unsigned.ipa
mkdir -p Payload
cp -R 3ds2apple.app Payload/
zip -qry 3ds2apple-unsigned.ipa Payload
shasum -a 256 3ds2apple-unsigned.ipa
```

Keep the `.ipa` under `build/` or `IPA/` (both gitignored). Signing/installing
happens on the user's machine with Sideloadly/AltStore; the Apple ID is entered
only there and must never be written to the repo or shared with agents.

## How the link settings resolve

`SRCROOT` is the directory containing `3ds2apple.xcodeproj`, i.e. `ios/app`:

| Build setting | Raw value | Resolves to |
|---|---|---|
| `SWIFT_OBJC_BRIDGING_HEADER` | `$(SRCROOT)/../ZakuroBridge.h` | `ios/ZakuroBridge.h` |
| `HEADER_SEARCH_PATHS` | `$(SRCROOT)/..` | `ios/` |
| `OTHER_LDFLAGS` | `-L$(SRCROOT)/../../build/ios -lzakuro_ios` | `<repo>/build/ios/libzakuro_ios.a` |

If the repo is moved, nothing needs changing — all three are repo-relative.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ld: library not found for -lzakuro_ios` | Static lib missing: run `scripts/build-zakuro-ios.sh` on the VM and check `ls ../../build/ios/libzakuro_ios.a`. |
| `Undefined symbols for architecture arm64` after adding the lib | The Rust staticlib needs system frameworks not linked automatically. Add what the linker names (typical: `-framework Security`, `-framework CoreFoundation`, `-lc++`) to `OTHER_LDFLAGS` in `project.yml`, then re-run `xcodegen generate`. Report the exact linker output to the Lead/ios-shell instead of guessing silently. |
| `error: Found no destinations` | Build with `-target 3ds2apple -sdk iphoneos`, not `-scheme`/`-destination`. |
| `xcodebuild: error: requires Xcode` / `unable to find utility "xcodebuild"` | Select the VM's Xcode: `sudo xcode-select -s "$HOME/Applications/Xcode-16.4.0.app"` (M0 installed Xcode under `~/Applications`). |
| `.app` has an empty/odd name | `PRODUCT_NAME` / `EXECUTABLE_NAME` must stay explicit in `project.yml` (docs/milestones.md, M0 pitfall 6). |
| `error: bridging header '.../ZakuroBridge.h' does not exist` | Confirm `ios/ZakuroBridge.h` exists and the build setting is `$(SRCROOT)/../ZakuroBridge.h`. |
| `xcodegen: command not found` | `brew install xcodegen`. |
| `git status` shows `ios/app/3ds2apple.xcodeproj/` | Should not happen — the root `.gitignore` covers it. If it does, check `.gitignore` still contains `ios/app/3ds2apple.xcodeproj/` and `ios/app/build/`. |
| Import button does nothing / picker dismisses immediately | The picker is a `UIDocumentPickerViewController` wrapped in a SwiftUI sheet; if it misbehaves on device, report to ios-shell — the fallback is SwiftUI `.fileImporter` (same system picker). |
| "Unsupported file “x”. Choose a decrypted .3ds or .cci ROM." | Only `.3ds` / `.cci` are accepted; the picker allows `public.data` because iOS has no ROM UTTypes. |
| "Could not read the selected file: …" | Copying the security-scoped URL failed (provider offline, no free space, wrong extension). Re-pick the file and check device free space. |
| Red "Could not load ROM" with `zk_create: failed to load …` | `zk_last_error()` text from the loader — encrypted/unsupported ROM or missing keys. Not a UI bug; check the ROM with qa. |
| Picking the same filename twice | The existing `Documents/roms/<name>` is reused; delete the app (or that file) to force a fresh copy. |
| Need to inspect imported ROMs | They live in the app container under `Documents/roms/`, data under `Documents/data/`; deleting the app removes them. |
| Screens stay black / "Waiting for first frame…" after "Loaded" | Check `idevicesyslog` for `frame loop started` and any `zk_read_screen(which=…) returned … of … bytes` line. If the log shows `frame loop ending: …` right away, `zk_run_frame` returned 1/-1/-2 — the core faulted (stderr has details). |
| Very low fps | Expected for the pure interpreter. Record fps **and the HUD row values** for qa — the I3 performance baseline. If `run` dominates `total`, the fix is AOT/3dsrecomp; if the read/CGImage/audio rows dominate, report that too. |
| HUD shows `—` for a row | That phase has no sample yet. Everything is `—` until the first 0.5 s stats window publishes (≈13 completed frames at 26 fps); a loop that stopped earlier keeps `—` for the phases it never sampled. |
| HUD numbers frozen while fps is 0 | Expected after a clean exit or fault: the last snapshot stays visible. Unload/background stops the runtime and clears the screens (and HUD); load again to restart the counters. |
| HUD `total` is high but `run` is low | Time is going to presentation/bookkeeping inside `renderFrame`, not emulation: check `read top`/`read bottom`/`CGImage`/`audio`; if those are low too, the gap is the input snapshot, stats bookkeeping or a buffer-pool-exhaustion allocation — capture the `perf:` line and fps. |
| HUD `total` is much lower than `1000 / fps` | The runtime queue is not the limiter; ticks are being dropped. Look at the main thread (SwiftUI redraw, another main-thread task) with Instruments. |
| Memory warnings / jetsam while loaded | The screen buffer pool is capped at 3 buffers per screen (≈2 MB total) and then falls back to transient `Data`, so its memory cannot grow without bound; if memory still grows, retention is elsewhere (frames, audio ring, runtime). Capture memory numbers and the HUD rows for qa. |
| Can't find the HUD | It lives inside the screens card, directly under the fps/status line, visible from "Loaded" onward; it refreshes twice per second. |
| App returns from background showing "Runtime stopped" | Intentional: iOS may jettison backgrounded processes, so the runtime is released when the scene backgrounds. Tap **Load “<name>”** to restart. |
| Red card after `frame loop ending: …` | `zk_run_frame` returned `-1`/`-2`; the last good frame stays on screen. Import or Load again to restart. |
| Screens look stretched or letterboxed | The view keeps the aspect ratios reported by `zk_screen_width/height` (400×240, 320×240) with `scaledToFit`; bars only appear if the source frame size changes. |
| On-screen buttons do nothing | Confirm a runtime is loaded ("Loaded: <name>") and frames are running (fps line); input is pushed once per frame inside `renderFrame`. With no runtime there is nothing to drive. |
| Controller connected but ignored | Look for the "Controller: …" line. If it is absent the pad is not a `GCExtendedGamepad`, or the app was backgrounded. Reattach and check `idevicesyslog` for `controller support started`. |
| A button stays pressed | Should not happen — Unload, Change ROM, app background and hiding the pad all clear input. If it does, report the exact sequence. |
| Touchscreen taps do nothing | Touch is only sent while a runtime is loaded, and only on the **lower** screen area; coordinates map to 320×240 pixels. |
| No sound at all | Check the status line: `audio: on` means the engine started; `audio: muted` means the mute toggle is on; `audio: failed` shows why. `idevicesyslog` logs `audio session failed` / `audio engine failed` / `audio started`. The `.playback` category ignores the iPhone silent switch. |
| Sound is choppy / cuts in and out | Expected while emulation runs below real time: samples are produced at emulated speed but consumed at wall-clock 32730 Hz, so the ring underruns and gaps are silenced. Raising fps is the fix (AOT/3dsrecomp, renderer). |
| Pops or clicks | Persistent popping is usually engine restarts (Change ROM / background) or a too-small IO buffer; `setPreferredIOBufferDuration(0.01)` is 10 ms. Buffer underruns themselves become silent gaps, not loud pops. |
| Audio still playing after Unload / background | Should not happen — Unload, Change ROM, background and exit all stop the engine and deactivate the session. Report it if it does. |
| Pitch or playback speed sounds wrong | The engine declares Zakuro's `AUDIO_SAMPLE_RATE` (`AudioOutput.sampleRate = 32730`). If `zakuro-core` changes it, update that one constant; the mixer handles the device conversion. |

## Rebuild after changes

```bash
cd ios/app
xcodegen generate   # after project.yml changes or new/removed Sources/*.swift files
# ... edit Sources/*.swift ...
xcodebuild ... build   # same command as above
```

`scripts/build-ios-app.sh` already runs `xcodegen generate` on every invocation,
so it picks up new source files automatically.

## Rules

- No ROMs, keys, BIOS/sysdata, IPAs, static libraries, generated C, or
  credentials in git. This directory contains source only.
- No CPU JIT: the runtime is built with the Cranelift shader JIT disabled.
- `ios/app/` is the ios-shell agent's write scope; `ios/zakuro-ios/` belongs to
  runtime-ffi, `scripts/` to build-infra.
