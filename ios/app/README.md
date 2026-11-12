# iOS app

The SwiftUI shell for 3ds2apple. It imports the user's own ROM, displays the two
3DS screens, drives the Zakuro runtime and exposes input, audio, frame timing,
save data and settings. The app is organised as a home page, the running game, a
settings page and a few supporting pages.

## App structure

| Page | Contents |
|---|---|
| **Home** | Current game card (ROM name), Play / Load, Import / Change ROM, and tools: Settings, Save Manager, Diagnostics export, About. |
| **Game** | The two screens on a `CAMetalLayer` (or the screen-readback path), status line, performance HUD, on-screen controls, the "Preparing graphics" warm-up overlay and the in-game menu. |
| **Settings** | Display, Audio, Controls, Performance, Storage and About sections. |
| **Save Manager** | The battery save files of the current game (size, date, export as ZIP, import, delete), the three instant save-state slots (save, load, delete) and the container usage. |
| **About** | Version, runtime state, acknowledgements and licence. |
| **In-game menu** | Opened from the pause button over the game: pause/resume, Save State / Load State (slot 1), Reset, Display settings, Save Manager, Diagnostics, Exit. |

Opening the in-game menu pauses emulation: the frame loop and the audio engine
are stopped, the runtime handle and the last frame stay, and Resume continues the
same session (no reload). The overlay dims the paused frame and covers the
on-screen controls, so no input or audio advances behind it.

## Features

- Import a decrypted `.3ds` / `.cci` from the Files app; the file stays in the
  app's Documents directory and is never included in the app bundle.
- Upper screen 400×240 above lower screen 320×240, with the lower screen also
  acting as the 3DS touchscreen.
- On-screen buttons (D-pad, A/B/X/Y, L/R, Start/Select) with configurable
  opacity and optional haptic feedback, plus GameController support (MFi, Xbox,
  DualSense).
- Audio through `zk_take_audio` and AVAudioEngine, with volume, mute and an IO
  buffer size preference.
- Instant save states: three slots per game, one file per slot under
  `Documents/states/<game>/`. The in-game menu saves to and loads from slot 1;
  the Save Manager page manages all three.
- Save-data management: export the game's battery saves as a ZIP archive through
  the share sheet, import a ZIP archive or single save files back, and delete
  individual files. Import and delete are disabled while a game is running.
- Free-running frame loop capped at 60 Hz (or 30 Hz) and decoupled from the
  display refresh.
- Presentation on a real `CAMetalLayer` (A1): Zakuro shows both screens through
  MoltenVK over Metal, with the system Metal Performance HUD (FPS / GPU /
  memory) able to attach to it. When a presenter cannot be made the app falls
  back to the `zk_read_screen` + `CGImage` path.
- Display settings: screen layout, aspect, integer scaling, render resolution
  (1×/2×) and orientation. See "Display settings" below for what applies
  immediately.
- Performance HUD: `zk_run_frame`, presentation (`present`), the fallback
  screen reads/CGImages, and audio pump, in milliseconds; it can be hidden.
- AOT status (`linked, active` / `linked, interpreting` / `interpreter shell`)
  and emulation speed relative to the 3DS 60 Hz timeline.
- Storage page: save-data / ROM / log / pipeline-cache usage and a "clear
  graphics pipeline cache" action (only while no game is running).
- Settings are persisted in `UserDefaults` and restored at launch.
- First-run graphics warm-up: after the ROM loads, the first frames run behind an
  opaque "Preparing graphics" overlay until they are smooth (at least 2 s, then
  90 consecutive frames without a >50 ms spike, capped at 5 s), so the GPU
  pipeline compiles of a cold pipeline cache happen on a loading screen instead
  of freezing visible play. A Skip button ends it early; a later load of the same
  ROM (pipelines already on disk) uses a shorter run (12 quiet frames, 2 s cap),
  and a software renderer skips it.
- Diagnostics export from the home page and the in-game menu.

## Display settings

| Setting | Values | When it applies |
|---|---|---|
| Screen layout | Stacked (console), side by side, upper only, lower only | Next game load. The presented `CAMetalLayer` path draws the console layout; the other layouts load through the screen-readback path (slower). |
| Aspect ratio | Native (console), stretch to 4:3 | Immediately. "Stretch" deliberately distorts the picture to fill a 4:3 area. |
| Integer scaling | On / off | Immediately for the presented console image: each 3DS pixel maps to a whole number of screen pixels. |
| Render resolution | 1× (400×480) / 2× (800×960) | Immediately. The presenter's swapchain is resized through `zk_presenter_resize`; the following frame presents at the new size. |
| Orientation | Automatic / portrait / landscape | Immediately: the app restricts the supported orientations and asks the window scene to rotate. iOS still decides in some situations (for example during a phone call). |

## Audio settings

Volume and mute are applied to the running mixer immediately. The buffer size
preference (low latency 5 ms / balanced 10 ms / stable 20 ms) is passed to
`AVAudioSession`; changing it while a game is running restarts the audio engine
once. Audio runs during the graphics warm-up too, because the boot sounds belong
to loading.

## Controls settings

The opacity slider controls the on-screen pad's background; haptics adds a light
impact on each button press. The controller row shows the connected
`GCController` name. Button remapping is not available in this build; the fixed
mapping is documented in the input section below.

## Screen layout and pause behaviour

- The frame loop runs on the session's serial runtime queue. Pausing stops it
  (generation-guarded, so a frame already queued becomes a no-op) and stops the
  audio engine; the runtime handle is kept. Resuming starts a new loop and
  restarts the audio engine.
- Reset releases the runtime and loads the same ROM again with the same per-ROM
  save data directory; battery saves are kept.
- Exit releases the runtime and returns to the home page. The ROM file and save
  data stay in the app container.
- Moving the app to the background releases the runtime (iOS may jettison a
  backgrounded process); the home page then offers to load the ROM again.

## Build

Requires macOS, Xcode, Rust with `aarch64-apple-ios`, and `xcodegen`.
See [docs/build.md](../../docs/build.md).

```bash
scripts/build-zakuro-ios.sh      # libzakuro_ios.a
scripts/build-ios-app.sh         # xcodegen + xcodebuild
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple
```

The project is generated by XcodeGen; new source files are picked up when
`xcodegen generate` runs. The app is built unsigned and signed later on the
user's machine with Sideloadly or AltStore.

The presented path additionally needs `MoltenVK.framework` inside the app (it is
loaded at run time, not linked; the binary is never committed). The build and
packaging steps are in [METAL.md](../zakuro-ios/METAL.md) §8, and
`scripts/package-ipa.sh` embeds the framework when `MOLTENVK_FRAMEWORK` is set.
Without it the app still builds and runs, on the readback path.

## Source layout

| File | Responsibility |
|---|---|
| `App.swift` | SwiftUI entry point; cache directory, logging and the app delegate. |
| `ApplicationDelegate.swift` | UIKit delegate used for the orientation preference. |
| `ContentView.swift` | Root router: home page or game for the current session phase; applies settings to the session. |
| `HomeView.swift` | Home page: current game card, Play/Import, tools. |
| `GameView.swift` | Running game: screens, status line, performance HUD, on-screen controls, warm-up overlay, in-game menu. |
| `InGameMenuView.swift` | Paused overlay menu (resume, save states, reset, display settings, save manager, diagnostics, exit) and quick toggles. |
| `SettingsView.swift` | Settings page and the in-game quick display settings; the persisted-setting binding. |
| `SaveManagerView.swift` | Battery save list (export as ZIP, import, delete) and the instant save-state slots (save, load, delete), with progress and errors. |
| `AboutView.swift` | Version, runtime state, acknowledgements, licence. |
| `AppSettings.swift` | Persisted settings model (enums for layout, aspect, orientation, buffer size, frame cap) and the UserDefaults keys. |
| `DiagnosticsReport.swift` | Diagnostics report text, the shared diagnostics file type and screen geometry helpers. |
| `StorageInspector.swift` | Container folder sizes, save-data file list, pipeline-cache clearing, and `AtomicFileWriter` for temporary-file-then-rename writes. |
| `SaveStateSupport.swift` | Instant save states: three slots per game, the runtime's size → copy → load protocol on the serial runtime queue, the pause/audio-drop around save and load, and the slot list. |
| `SaveDataStore.swift` | Battery save-data folder, file list, ZIP export, ZIP/file import and delete. |
| `ZipArchive.swift` | Small ZIP writer (stored entries) and reader (stored and deflated entries) used for save-data backups. |
| `SaveArchivePicker.swift` | Files picker for importing a save-data ZIP or individual save files. |
| `ROMSession.swift` | Runtime handle, ROM import, frame loop, presenter lifecycle, input/audio plumbing, pause/resume/reset and the settings that change runtime behaviour. |
| `MetalScreenView.swift` | `UIView` with a `CAMetalLayer` the presenter draws into (A1); drawable resolution (1×/2×). |
| `ROMDocumentPicker.swift` | Files document picker wrapper. |
| `ScreenImage.swift` | Reusable RGBA buffers and `CGImage` conversion. |
| `InputState.swift` | Thread-safe merge of touch, overlay and controller input. |
| `TouchControlsView.swift` | On-screen button overlay (opacity and haptics options). |
| `GameControllerInput.swift` | GameController-to-3DS button mapping. |
| `AudioOutput.swift` | Ring buffer and AVAudioEngine output (volume, mute, buffer duration). |
| `FrameTiming.swift` | Per-phase frame timing for the HUD. |
| `GraphicsWarmUp.swift` | First-run graphics warm-up state/plan, its persisted "warmed" marker and pipeline-cache filesystem stats. |
| `AppLog.swift` | In-app log capture and the diagnostics report assembly. |
| `ShareSheet.swift` | System share sheet for exported diagnostics. |

`ios/ZakuroBridge.h` is the C bridge; all calls that take a runtime handle must
run on the single serial queue owned by `ROMSession`.

## Presentation (A1)

The two screens are presented in one of two ways, chosen when a ROM loads:

| Path | What happens | HUD |
|---|---|---|
| **CAMetalLayer (A1)** | The app owns a `MetalScreenView` (`UIView` + `CAMetalLayer`), makes a Zakuro Vulkan presenter for it (`zk_presenter_create`) and loads the ROM with `zk_create_presented`. After every `zk_run_frame` it calls `zk_present`; the screens go straight from the renderer's GPU images to the swapchain. | `present` row; no screen reads, no `CGImage` |
| **CGImage readback (fallback)** | `zk_create` + `zk_read_screen` for each screen, converted to `CGImage` and shown by SwiftUI. Also used for the alternate screen layouts, which one presented drawable cannot rearrange. | `read top` / `read bottom` / `CGImage` rows |

- Both screens are in the one layer: Zakuro's presenter draws the upper (3D)
  screen over the lower (2D) one in the console's 400×480 shape, so no 2D
  composition in Swift is needed. The on-screen touch surface maps a normalised
  touch to lower-screen pixels with `zk_present_touch_map`. During the first-run
  graphics warm-up the same presenter path runs behind the opaque overlay, so
  the warm-up frames are the real presentation workload.
- The fallback triggers automatically when `zk_presenter_create` returns `NULL`
  (for example no MoltenVK in the app, or a device that cannot make a Vulkan
  device), when `zk_create_presented` fails (the load is retried once with
  `zk_create`), or after about a second of `zk_present` failures. A presented
  load whose renderer stays in software still uses the Metal layer: the
  presenter uploads the CPU pixels, so the app still never builds a `CGImage`.
- The Metal view and presenter are created on the main queue and kept for the
  app's lifetime, so a later load reuses the same layer and Vulkan device. The
  frame loop stops presenting when the runtime stops (Unload, background,
  exit/fault); the presenter is released with the app. The swapchain rebuilds
  after a size change (render resolution, rotation, split view), which costs one
  out-of-date present.
- Because there is a real Metal layer, the system Metal Performance HUD
  (`MetalHudEnabled` in the test IPA's `Info.plist`, or Settings → Developer →
  Graphics HUD) overlays the app. On the readback path it does not appear.

## Input

- The on-screen pad and a connected hardware controller are merged by
  `InputState`; the session reads one snapshot on the runtime queue immediately
  before `zk_run_frame` and calls `zk_set_input` there.
- Controller mapping: D-pad → D-pad, A/B/X/Y → A/B/X/Y, L1/R1 → L/R, L2/R2 →
  ZL/ZR, Menu → Start, Options → Select, left stick → Circle Pad.
- Dragging on the lower screen (or on the lower part of the presented layer)
  sends touchscreen coordinates in lower-screen pixels. A touch started on the
  upper screen is ignored.
- Input is cleared on pause, unload, background and reset, so a held button
  cannot survive a state change.

## ROM handling

- The ROM is copied into `Documents/roms/`; saves and runtime data go under
  `Documents/data/<game>/`.
- The repository ships no ROMs, keys or game data.
- The app works only with decrypted dumps the user obtained from their own
  console.

## Save data

Two kinds of data stay on the device:

| Data | Where | Managed by |
|---|---|---|
| Battery saves | `Documents/data/<game>/` | The game's own save menu writes them; the Save Manager lists, exports, imports and deletes them. |
| Instant save states | `Documents/states/<game>/slot1.bin` … `slot3.bin` | Save State / Load State in the in-game menu (slot 1) and the Save Manager (all three slots). |

Battery saves:

- The Save Manager lists every file under the current game's data directory with
  its size and modification date.
- **Export battery saves as a ZIP…** packs those files into a ZIP archive and
  opens the share sheet, so a backup can go to Files, iCloud Drive or AirDrop.
  Paths inside the archive are relative to the game's data directory.
- **Import battery saves from a ZIP or file…** merges an archive (or one save
  file) back into the game's data directory. The archive may come from this app,
  a desktop tool, or from compressing the game's folder in the Files app: the
  folder wrapper is dropped, macOS metadata entries are skipped, and both stored
  and deflated entries are read.
- Import and delete are disabled while a game is running, because the runtime may
  keep save files open; the page says so. Files are replaced through a temporary
  file and a rename, so an interrupted import cannot leave a half-written save.

Instant save states:

- A slot is a snapshot of the whole console — CPU, kernel objects, services, GPU
  state and the memories — compressed by the runtime into one file of tens of
  MiB. The runtime's saved-state C ABI is a size → copy → load protocol; the app
  serializes on the runtime's serial queue with the frame loop and the audio
  engine stopped, copies the blob and writes the file through a temporary file.
- Loading pauses the game, restores the console and drops the audio buffered
  before the load (the DSP state jumped back too). The last frame stays on screen
  until the restored console draws the next one, then the same session continues;
  the in-game menu closes and resumes after a successful load.
- The in-game menu's quick buttons use slot 1. The Save Manager page lists all
  three slots with size and date and offers Save / Load / Delete for each.
- A save briefly holds the runtime's snapshot and the app's copy of it — about
  twice the compressed state, tens of MiB — and writes the app's copy straight
  from its buffer, so no third copy is made. A load memory-maps the slot file and
  lets the runtime check and unpack it.
- A short copy (the state changed size between the two ABI calls) is retried once
  with the reported length, and a failed write leaves the previous slot intact.
- Save states are device-local and are not exported by the Save Manager. The
  runtime checks the title, format version and console model when loading and
  refuses a state from another game or runtime version without touching the
  running console.

## Known limitations

- The 3D can be drawn on the GPU through MoltenVK (hardware-rendering build);
  otherwise it is Zakuro's software PICA200 renderer. The presented path is
  experimental and a presenter is reused for the whole app run.
- 3D stereo, frame interpolation and texture packs exist in the presenter but
  are not exposed by the app UI.
- Screen layouts other than stacked, and the 2× render resolution, are limited
  by the presented path's single 400×480 drawable; see "Display settings".
- Games run only when a matching recompiled `libgame.a` is linked into the app.
  A generic interpreter-only build exists but is much slower.
- The first release does not include camera, microphone, online play or a full
  game library UI.
- Button remapping is not available in this build. Save states are not
  interchangeable between games or runtime versions, and only battery saves are
  exported and imported; instant states stay in the app container.
- The first run with an empty pipeline cache waits up to 5 s on the
  "Preparing graphics" screen (skippable). A pipeline first used long after the
  warm-up still compiles on a worker thread and draws through the generic
  fallback meanwhile; a title can hitch briefly there. Completing shader AOT is
  out of scope: it cannot cover every runtime shader/pipeline combination, and a
  first run has no cache to load.
- iOS 16+ only; the app is not distributed through the App Store.

## Diagnostics

The status line in the game view includes:

```text
57 fps  2,247 frames  last: completed  audio: on
AOT: linked, active   speed: 95% of 60 Hz
loop: free-run · cap 60 fps   display: CAMetalLayer · GPU direct
warm-up ready in 2.40 s · 146 frames · max 586 ms · 3 spiky (>50 ms)
```

and, when the custom HUD is enabled, a millisecond HUD for
`total / run / present / audio` (presented) or
`total / run / read top / read bottom / CGImage / audio` (fallback). The
`warm-up …` line appears once a load's graphics warm-up finished (it replaces
the "Preparing graphics…" overlay); it is absent when the overlay is skipped
for a software renderer. The device log carries one line per load
(`zk_presenter_create`, `display:`, `hardware:`), the pipeline-cache state at
launch/load/after `zk_destroy`, one `graphics warm-up:` line with the same
timing, a `frame cap:` / `render scale:` line when those settings change, one
line per pause/resume/reset, one `save state:` line per save/load/delete, one
`save data:` line per export/import/delete, and a `perf:` line every ~2 s with
the HUD phases.

The exported diagnostics header adds the build, device, session phase
(`paused=`), the runtime state, the active settings (`frame_cap=`,
`screen_layout=`, `screen_aspect=`, `integer_scale=`, `render_scale=`,
`orientation=`, `audio_volume=`, `audio_muted=`, `audio_buffer_ms=`,
`touch_controls=`, `controls_opacity=`, `haptics=`, `custom_hud=`), the
`warmup_*` fields (`outcome`, duration, frames, max frame, spike count, plan
limit, whether the pipelines were already cached) and the `pipeline_cache*`
fields (directory, file count, size, newest file), followed by the previous and
current session logs. These values make renderer, presentation, scheduler,
settings and first-run warm-up changes measurable on device.
