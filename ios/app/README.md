# iOS app

The SwiftUI shell for 3ds2apple. It imports the user's own ROM, displays the two
3DS screens, drives the Zakuro runtime and exposes input, audio, frame timing
and settings. The app is organised as a home page, the running game, a settings
page and a few supporting pages.

## App structure

| Page | Contents |
|---|---|
| **Home** | Current game card (ROM name), Play / Load, Import / Change ROM, and tools: Settings, Save Manager, Diagnostics export, About. |
| **Game** | The two screens on a `CAMetalLayer` (or the screen-readback path), status line, performance HUD, on-screen controls, the "Preparing graphics" warm-up overlay and the in-game menu. |
| **Settings** | Display, Audio, Controls, Performance, Storage and About sections. |
| **Save Manager** | Read-only list of the battery saves the runtime has written into the per-game data directory, and the container usage. |
| **About** | Version, runtime state, acknowledgements and licence. |
| **In-game menu** | Opened from the pause button over the game: pause/resume, Save State / Load State, Reset, Display settings, Save Manager, Diagnostics, Exit. |

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
| `SaveManagerView.swift` | Read-only battery-save list and container usage. |
| `AboutView.swift` | Version, runtime state, acknowledgements, licence. |
| `AppSettings.swift` | Persisted settings model (enums for layout, aspect, orientation, buffer size, frame cap) and the UserDefaults keys. |
| `DiagnosticsReport.swift` | Diagnostics report text, the shared diagnostics file type and screen geometry helpers. |
| `StorageInspector.swift` | Container folder sizes, save-data file list, pipeline-cache clearing. |
| `SaveStateSupport.swift` | Single place the UI asks whether the runtime can take/restore instant save states. |
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

The runtime writes battery saves into `Documents/data/<game>/`; the Save Manager
page lists those files with sizes and dates and shows the container usage. Save
data import/export and instant save states are not available in this build: the
in-game menu labels the Save State / Load State buttons as unavailable instead of
writing a file that could not be loaded back. Save files are never deleted or
moved by the app UI.

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
- Button remapping, save-state slots and save-data import/export are not
  available in this build.
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
line per pause/resume/reset, and a `perf:` line every ~2 s with the HUD phases.

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
