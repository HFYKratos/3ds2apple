# iOS app

The SwiftUI shell for 3ds2apple. It is an AOT-only app and ships **no game
data**. A game reaches the phone in two steps, both driven by the 3ds2apple
desktop launcher: (1) the launcher builds a version of this app that contains
the game's AOT pack (`Frameworks/GamePack-<TITLEID>.dylib` + a
`GameCatalog.json` entry) and installs it — executable code has to be signed as
part of the IPA; (2) it pushes the user's own game data (the decrypted ROM +
`GameInfo.json`) into this app's `Documents/Games/<TITLEID>/`, where it stays
across app updates. The shell reads the catalog as its game list, validates and
launches the pushed data, and never downloads or imports anything itself. It
displays the two 3DS screens, drives the Zakuro runtime and exposes input,
audio, fast-forward, save data, diagnostics and settings. The app is organised
as a home page, the running game, a settings page and a few supporting pages.

The UI follows the system language: Simplified Chinese gets Chinese, every other
language gets English. Static text lives in `Resources/<lang>.lproj/
Localizable.strings`; run-time text goes through the small `L10n` helper, so the
views do not carry duplicated strings.

## App structure

| Page | Contents |
|---|---|
| **Home** | The library from the build's `GameCatalog.json`, joined with the game data pushed into `Documents/Games`; last-played state and a per-card state badge (**AOT** / **Checking** / **Data missing** / **Error**). Tapping a game starts it; a game without pushed data explains that the launcher must push it, a broken push lists the exact validation error. Refresh button and pull-to-refresh rescan Documents. The empty state explains the desktop launcher. No on-phone import. Settings entry. |
| **Game** | The two screens on a `CAMetalLayer` (or the screen-readback fallback), status line (including the active fast-forward speed), on-screen controls, the optional "Preparing graphics" warm-up overlay and the in-game menu. Portrait stacks the controls below the screens; landscape puts them in a top bar and two side rails so they never cover the screens. |
| **Settings** | Display, Audio, Controls, Performance (frame cap, fast-forward, system Metal HUD, optional graphics warm-up), Storage and About sections. |
| **Save Manager** | The battery save files of the current game (size, date, export as ZIP, import, delete), the three instant save-state slots (save, load, delete) and the container usage. |
| **About** | Version, runtime state, acknowledgements and licence. |
| **In-game menu** | Opened from the pause button over the game: pause/resume, quick toggles (on-screen controls, mute, 1×/2×/4× fast-forward), Save State / Load State (slot 1), Reset, Display settings, Save Manager, Diagnostics, Exit. |

Opening the in-game menu pauses emulation: the frame loop and the audio engine
are stopped, the runtime handle and the last frame stay, and Resume continues the
same session (no reload). The overlay dims the paused frame and covers the
on-screen controls, so no input or audio advances behind it.

## Features

- Games are installed by the 3ds2apple desktop launcher in two steps: the AOT
  pack (`Frameworks/GamePack-<TITLEID>.dylib`) and its `GameCatalog.json` entry
  are part of the signed app build (adding a game = rebuild + reinstall), while
  the user's game data is pushed separately into `Documents/Games/<TITLEID>/`
  and persists across app updates. The shell never imports game data itself and
  ships none; a base shell with an empty catalog shows the launcher empty state.
  See "Game library: AOT packs in the app, game data in Documents" below.
- iOS file sharing is enabled (`UIFileSharingEnabled`,
  `LSSupportsOpeningDocumentsInPlace`), so the same `Documents` folder is
  visible in the Files app and through Finder/iTunes file sharing.
- Upper screen 400×240 and lower screen 320×240, arranged stacked, side by side
  or one at a time, optionally turned a quarter turn; the lower screen also acts
  as the 3DS touchscreen.
- On-screen buttons (D-pad, A/B/X/Y, L/R, Start/Select) with configurable
  opacity and optional haptic feedback, plus GameController support (MFi, Xbox,
  DualSense). In landscape the two button clusters sit in reserved side rails and
  L/R/Start/Select in a top bar, so the screens stay uncovered; the layout
  reflows when the device rotates.
- Audio through `zk_take_audio` and AVAudioEngine, with volume, mute and an IO
  buffer size preference.
- Instant save states: three slots per game, one file per slot under
  `Documents/states/<title id>/`. The in-game menu saves to and loads from slot 1;
  the Save Manager page manages all three.
- Save-data management: export the game's battery saves as a ZIP archive through
  the share sheet, import a ZIP archive or single save files back, and delete
  individual files. Import and delete are disabled while a game is running.
- Free-running frame loop capped at 60 Hz (or 30 Hz) and decoupled from the
  display refresh.
- Fast-forward at 1× / 2× / 4× from Settings and the in-game menu: each
  presented frame advances the console 2 or 4 frames. See "Fast-forward" below
  for the presentation/audio policy and the automatic fallback.
- Presentation on a real `CAMetalLayer` (A1): Zakuro shows both screens through
  MoltenVK over Metal. When a presenter cannot be made the app falls back to the
  `zk_read_screen` + `CGImage` path.
- System Metal Performance HUD (FPS / GPU time / memory): a Settings switch
  shows or hides it on the presented layer at run time
  (`CAMetalLayer.developerHUDProperties`, iOS 16), off by default. See "System
  Metal HUD" below.
- Display settings: screen layout, screen rotation, aspect (fit / 4:3 / stretch),
  integer scaling, render resolution (1×–4×) and interface orientation. Layout,
  rotation, aspect and integer scaling apply immediately, also while a game
  runs; the render resolution resizes the presented drawable at once, while the
  internal 3D render scale is applied when a game loads. See "Display settings"
  below.
- AOT status (`AOT not loaded` / `AOT · linked`), emulation speed relative to
  the 3DS 60 Hz timeline, and a hard AOT-only launch rule: a game is never started
  through the interpreter.
- Storage page: save-data / legacy game-file / log / pipeline-cache usage and a
  "clear graphics pipeline cache" action (only while no game is running).
- Settings are persisted in `UserDefaults` and restored at launch.
- Optional first-load graphics warm-up, **off by default**: when enabled, the
  first frames after a load run behind an opaque "Preparing graphics" overlay
  until they are smooth (at least 2 s, then 90 consecutive frames without a
  >50 ms spike, capped at 5 s), with a Skip button; a later load of the same ROM
  uses a shorter run and a software renderer skips it. By default the game is
  revealed as soon as the ROM is loaded, because pipelines first used later
  still compile on a worker thread. In both modes the runtime keeps writing its
  pipeline cache while you play (the cache is saved every ~5 s and on exit), so
  later loads start warm.
- Language: the app follows the system language (Simplified Chinese or English)
  and re-renders if iOS reports a locale change while it runs. See
  "Localization" below.
- Diagnostics export from the home page and the in-game menu.

## Game library: AOT packs in the app, game data in Documents

A game on the phone has two halves:

| Half | Lives in | How it gets there |
|---|---|---|
| AOT pack + catalog entry (`GamePack-<TITLEID>.dylib`, `GameCatalog.json`) | the signed app bundle (`Frameworks/`, `Resources/`) | the desktop launcher builds the app with the pack and installs it — adding a game rebuilds/reinstalls the shell |
| Game data (the user's decrypted ROM + `GameInfo.json`) | `Documents/Games/<TITLEID>/` in the app container | the launcher pushes it through the device bridge over USB/Wi-Fi; it survives app reinstalls and updates |

The split is deliberate: iOS refuses to `dlopen` unsigned code copied into
Documents, so the AOT pack must be part of the signed IPA, while the large
per-user game data stays in Documents and can be pushed or replaced without
rebuilding the app.

```text
App bundle (signed)
  Frameworks/GamePack-<TITLEID>.dylib   per-game AOT code
  GameCatalog.json                      the game list + packFile/ABI per game

Documents/
  Games/<TITLEID>/            16 upper-case hex digits, e.g. 0004000000055E00
    GameInfo.json             launcher manifest (written last)
    GameRom.cci               user's decrypted game data
    cover.png                 optional
  Library/playHistory.json    last-played times (written by the shell)
  data/<save namespace>/      battery saves (written by the runtime)
  states/<save namespace>/    instant save-state slots
```

`GameInfo.json` is schemaVersion 1 and is authoritative for the pushed game
data: `titleID`, `displayName`, optional `productCode`/`saveNamespace` (defaults
to the title ID), a `rom` object with `file` + optional `size`/`sha256`, plus
optional `cover`, `launcherVersion`, `pushedAt` and `notes`. The `pack` object is
informational metadata about the pack the launcher embedded in the IPA (the shell
never loads a pack from Documents). Unknown fields are ignored; the game data
defaults to `GameRom.cci` / `GameRom.3ds`.

The shell validates the pushed game data in two passes:

1. **Scan** (fast; at launch, on returning to the foreground and on refresh): the
   folder name is a title ID, `GameInfo.json` parses and matches the folder, and
   the game data exists as a non-empty regular file inside the folder with the
   recorded size.
2. **Hash check** (background): the recorded SHA-256 of the ROM is streamed and
   verified; the card shows **Checking** until it finishes.

Home-page states: **AOT** (pack installed + data verified → playable),
**Data missing** (the catalog lists the game but the launcher has not pushed its
data yet; the tap explains the next step), **Checking**, and **Error** (a broken
push: missing file, unsafe path, size/hash mismatch — the tap lists exactly what
is wrong and how to fix it). The shell never launches a game with missing or
unverified game data, and there is no interpreter fallback. An unknown or
partial push (a folder without a usable `GameInfo.json`) is an error card, never
a game.

The launcher writes `GameInfo.json` **last**, so a directory only becomes usable
after all of its files are in place. The shell's scanner also rejects paths that
escape the game folder.

The app enables iOS file sharing (`UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace`), so the same folder is visible in the Files
app under **On My iPhone → 3ds2apple** and through Finder/iTunes file sharing.
There is no on-phone import UI.

An app updated from the previous self-contained build (games + ROM inside the
bundle) keeps those bundle games playable from the bundled ROM until the
launcher reinstalls with the pack and pushes the data; that path is the legacy
fallback, not the launcher-first flow.

### Simulator fixture and debug launch arguments

The shell can be driven headlessly without tapping:

- `-gamesRoot <path>` scans a different folder instead of `Documents/Games`
  (a relative path resolves against Documents, a `Documents/` prefix is
  accepted; an absolute path must stay inside the app container).
- `-openAOTTitleID <TITLEID>` starts that library game 0.5 s after the home
  page appears, through the same path a card tap uses.

A Simulator fixture never has to touch the real library. Build a Simulator shell
that already contains the game's pack + catalog entry, then push only game data:

```bash
UDID=3CBF5A62-AE12-47E8-803D-1D77BED85A66
scripts/build-ios-app-sim.sh --app shell \
    --game-pack build/sim/game/packages/0004000000055E00 \
    --game-title-id 0004000000055E00 --game-display-name "Pokemon Y"
APP=build/sim/shell/out/Release-iphonesimulator/3ds2apple.app
xcrun simctl install "$UDID" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$UDID" com.kratos.3ds2apple data)
GAME="$CONTAINER/Documents/GamesFixtures/0004000000055E00"
mkdir -p "$GAME"
cp "/path/to/your/game.cci" "$GAME/GameRom.cci"
cat > "$GAME/GameInfo.json" <<'JSON'
{"schemaVersion":1,"titleID":"0004000000055E00","displayName":"Pokemon Y",
 "rom":{"file":"GameRom.cci"}}
JSON
xcrun simctl launch "$UDID" com.kratos.3ds2apple \
    -gamesRoot Documents/GamesFixtures -openAOTTitleID 0004000000055E00
```

Omit the game-data fixture (or use an empty `-gamesRoot` folder) to see the
**Data missing** state of a catalog game; record a wrong `rom.size`/`sha256` to
exercise the per-game error state. The fixture files are user-owned local test
data: never commit them, and remove the fixture from the container when done.
[docs/build-simulator.md](../../docs/build-simulator.md) covers building the
x86_64 Simulator shell and its runtime.

## Display settings

| Setting | Values | Behaviour |
|---|---|---|
| Screen layout | Stacked (console), side by side, upper only, lower only | Immediately. Every layout is drawn by the `CAMetalLayer` presenter; the layer's drawable becomes the arrangement's own pixels (400×480 stacked, 720×240 side by side, 400×240 / 320×240 for a single screen). |
| Screen rotation | Upright, 90° clockwise, upside down, 90° counter-clockwise | Immediately. Turns the screens inside their area, e.g. the stacked console becomes two columns (480×400) a quarter turn clockwise. The touchscreen is mapped back into the screen's own pixels. |
| Aspect ratio | Fit (native), 4:3, Stretch | Immediately. Fit keeps the arrangement's shape; 4:3 fits the picture inside a 4:3 area with black bars; Stretch fills the game view's space and deliberately distorts the picture. |
| Integer scaling | On / off | Immediately, with Fit and 4:3 (Stretch ignores it): each 3DS pixel maps to a whole number of screen pixels and the layer magnifies with nearest-pixel filtering. |
| Render resolution | 1× / 2× / 3× / 4× | The presenter's drawable is the arrangement's own pixels times the factor and CoreAnimation scales it to the screen; the swapchain is resized through `zk_presenter_resize` and the following frame presents at the new size. The internal resolution the host-GPU 3D renderer draws at is set with `zk_set_render_scale` and read when a system loads, so a running game keeps its old internal scale until it is reloaded or restarted. The software renderer always draws at 1×; higher factors cost GPU time and memory. |
| Orientation | Automatic / portrait / landscape | Immediately: the app restricts the supported orientations and asks the window scene to rotate. The in-game layout reflows for portrait/landscape. iOS still decides in some situations (for example during a phone call). |

The 3DS screens stay upright in the app's interface, which iOS rotates with the
device; `Screen rotation` turns the pictures inside their area for playing with
the console held sideways. In landscape with the default stacked layout the
screens are fitted in the middle of the screen; side by side uses the width best.

## Audio settings

Volume and mute are applied to the running mixer immediately. The buffer size
preference (low latency 5 ms / balanced 10 ms / stable 20 ms) is passed to
`AVAudioSession`; changing it while a game is running restarts the audio engine
once. Audio runs during the optional graphics warm-up too, because the boot
sounds belong to loading. Fast-forward is silent: see "Fast-forward" below.

## Controls settings

The opacity slider controls the on-screen pad's background; haptics adds a light
impact on each button press. The controller row shows the connected
`GCController` name. Button remapping is not available in this build; the fixed
mapping is documented in the input section below.

## Performance settings

| Setting | Values | Behaviour |
|---|---|---|
| Frame cap | 60 / 30 fps | Immediately; the free-run loop never starts presented frames closer than 1/60 s (or 1/30 s). It is a cap, not a target. |
| Fast-forward | 1× / 2× / 4× | Immediately (also from the in-game menu); the next presented frame uses the new value. |
| System Metal HUD | On / off | Immediately on the presented `CAMetalLayer`; remembered for later loads. |
| First-load graphics warm-up (optional) | On / off, default off | Read when the next ROM load starts. The runtime's pipeline-cache persistence is unaffected. |

## Fast-forward

`1×` is normal speed. At `2×` or `4×` the frame loop runs the extra console
frames with `zk_run_frame` before the frame that is presented:

- Only the last frame of the group is presented and published (a `2×` presented
  frame shows the console after two frames), so the UI keeps receiving frames
  and input/pause/reset keep working on the same serial runtime queue.
- The extra frames do not read the screens and do not present, so fast-forward
  costs no screen copies and no swapchain presents.
- **Audio is muted while fast-forwarding**: the samples produced for every frame
  are drained from the runtime and dropped rather than queued for playback, so
  no stale audio is left to play when normal speed resumes. Returning to `1×`
  drops anything buffered and starts feeding audio again from the next frame.
- **Automatic fallback**: if the presented frame rate stays below 20 fps for two
  consecutive half-second windows, the app lowers the effective speed one step
  (4× → 2× → 1×) for the rest of the session, so a heavy scene cannot make the
  menu or input unresponsive. The Settings page and the status line show the
  effective speed (`fast-forward: 2× (auto)`), and choosing a speed again
  clears the fallback.
- The status line shows the effective speed (`fast-forward: 2×`), and the
  exported diagnostics records both the requested and the effective speed.
- Pause, Save State / Load State, Reset, Unload and moving to the background all
  stop the frame loop before touching the runtime, so a fast-forward group can
  never straddle a state change.

## Graphics warm-up (optional)

A cold pipeline cache makes the driver compile pipelines while the game runs.
The app can run the first frames after a load behind an opaque "Preparing
graphics" screen until frame times stop spiking (at least 2 s, 90 consecutive
frames without a >50 ms spike, at most 5 s; Skip ends it early). It is **off by
default** because a pipeline first used later still compiles on a worker thread
and can hitch, so the loading wait was judged not worth it. The 5-second
pipeline-cache persistence in the runtime is independent of this setting and
always runs: the cache is written while you play and on unload, so the second
load of a title starts warm. Enable the toggle in Settings → Performance to use
the overlay again; its result appears in the diagnostics (`warmup_*` fields) and
in the status line after the load.

## System Metal HUD

The system Metal Performance HUD (FPS, GPU time, memory) attaches to the
`CAMetalLayer` the presented screens draw into. Settings → Performance → System
Metal HUD sets `CAMetalLayer.developerHUDProperties["mode"]` to `"default"` or
`"disabled"` at run time (iOS 16 API), and the preference is persisted and
re-applied whenever the layer is reused, so it survives page navigation and ROM
reloads. The app keeps the system HUD's device logging off; the app log and the
diagnostics report carry the frame timings instead.

The HUD can only appear when something enables it for the build: the packaged
test IPA sets `MetalHudEnabled` in `Info.plist` (`scripts/package-ipa.sh`), or the
device's Settings → Developer → Graphics HUD turns it on. When the build does not
enable it, the Settings row says so instead of pretending the switch worked. On
the screen-readback path there is no `CAMetalLayer`, so the switch has no visible
effect until a presented load runs.

## Localization

The UI follows the system language:

- a system language of Simplified Chinese (`zh-Hans`, `zh-CN`, `zh-SG`) shows
  Simplified Chinese;
- every other language, including Traditional Chinese, shows English (the
  development language).

All user-facing text comes from `Resources/en.lproj/Localizable.strings` and
`Resources/zh-Hans.lproj/Localizable.strings`. Static SwiftUI literals are
localizable keys by themselves; text built at run time (status lines, errors,
enum labels, formatted numbers) goes through `L10n.tr()`/`L10n.format()`, which
read the same tables, so there is one place per string rather than scattered
duplicates. A missing translation falls back to the English key.

`L10n` resolves the language from `Bundle.preferredLocalizations`; adding a
language means adding `Resources/<language>.lproj/Localizable.strings` (all keys
must keep the same format specifiers). iOS restarts an app when the system
language changes; `LocalizationStore` still watches for a locale change while the
app runs and rebuilds the UI for new formatting. The Settings → About → Language
row shows the table in use, and the exported diagnostics include
`app_language=` / `system_language=`, so a device run proves which table iOS
picked.

The device log and the diagnostics report keep their technical keys and values
in English where they are meant for tooling; the UI text around them is
localized.

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
- Fast-forward is a property of the frame loop, so pause, save states, reset and
  unload suspend it together with the loop; resuming continues at the setting's
  speed. The in-game menu's speed control applies on resume.

## Build

Requires macOS, Xcode, Rust with `aarch64-apple-ios`, and `xcodegen`.
See [docs/build.md](../../docs/build.md).

```bash
scripts/build-zakuro-ios.sh      # libzakuro_ios.a
scripts/build-ios-app.sh         # xcodegen + xcodebuild
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple
```

The project is generated by XcodeGen; new source files and the `Resources`
folder are picked up when `xcodegen generate` runs. Do not edit the generated
`.xcodeproj`: it is ignored by git.

The shell this builds contains **no games**: it is the base app the desktop
launcher installs, and it shows the launcher empty state until games are pushed
into its Documents folder. `Info.plist` is generated by XcodeGen from the
target's `info:` block in `project.yml` into the gitignored
`ios/app/build/Info.plist`; iOS file sharing needs both
`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` there (the
`INFOPLIST_KEY_*` synthesis silently dropped `UIFileSharingEnabled`). Verify
after a build:

```bash
plutil -p ios/app/build/Release-iphoneos/3ds2apple.app/Info.plist \
  | grep -E "UIFileSharing|LSSupportsOpening"
```

The `GameCatalog.json` handling further down is legacy: it only matters for the
previous self-contained per-game IPA path and for adopting the games of an app
updated from it.

Localization resources: `Resources/en.lproj/Localizable.strings` and
`Resources/zh-Hans.lproj/Localizable.strings` are listed in `project.yml`
(`developmentLanguage: en`). XcodeGen turns the two `.lproj` folders into one
localized resource; Xcode compiles the tables into the app bundle. After a build
the bundle should contain `en.lproj/Localizable.strings` and
`zh-Hans.lproj/Localizable.strings`:

```bash
ls build/Release-iphoneos/3ds2apple.app/*.lproj
plutil -p build/Release-iphoneos/3ds2apple.app/zh-Hans.lproj/Localizable.strings | head
```

If the bundle has no `.lproj` folders, the app still builds and runs in English,
but no language switch happens; check that `xcodegen generate` picked up
`Resources` (its output lists the files it added) and that the `.strings` files
are valid UTF-8. The app's Settings → About → Language row and the diagnostics'
`app_language=` field show which table iOS selected.

The app is built unsigned and signed later on the user's machine with Sideloadly
or AltStore.

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
| `HomeView.swift` | Home page: the Documents/Games library grid, last-played dates, per-card state badge (AOT / Checking / Error), the exact per-game validation error on tap, the launcher empty state, refresh control, settings entry. |
| `GameView.swift` | Running game: responsive portrait/landscape layout, screens, status line, on-screen controls, warm-up overlay, in-game menu. |
| `InGameMenuView.swift` | Paused overlay menu (resume, save states, reset, display settings, save manager, diagnostics, exit) and quick toggles. |
| `SettingsView.swift` | Settings page and the in-game quick display settings; the persisted-setting binding. |
| `SaveManagerView.swift` | Battery save list (export as ZIP, import, delete) and the instant save-state slots (save, load, delete), with progress and errors. |
| `AboutView.swift` | Version, runtime state, acknowledgements, licence, language in use. |
| `AppSettings.swift` | Persisted settings model (enums for layout, screen rotation, aspect, interface orientation, buffer size, frame cap, playback speed, Metal HUD and warm-up switches) and the UserDefaults keys. |
| `DiagnosticsReport.swift` | Diagnostics report text, the shared diagnostics file type and screen geometry helpers. |
| `StorageInspector.swift` | Container folder sizes, save-data file list, pipeline-cache clearing, and `AtomicFileWriter` for temporary-file-then-rename writes. |
| `SaveStateSupport.swift` | Instant save states: three slots per game, the runtime's size → copy → load protocol on the serial runtime queue, the pause/audio-drop around save and load, and the slot list. |
| `SaveDataStore.swift` | Battery save-data folder, file list, ZIP export, ZIP/file import and delete. |
| `ZipArchive.swift` | Small ZIP writer (stored entries) and reader (stored and deflated entries) used for save-data backups. |
| `SaveArchivePicker.swift` | Files picker for importing a save-data ZIP or individual save files. |
| `ROMSession.swift` | Runtime handle, AOT-only game launch gate, frame loop, presenter lifecycle, input/audio plumbing, pause/resume/reset and the settings that change runtime behaviour. |
| `MetalScreenView.swift` | `UIView` with a `CAMetalLayer` the presenter draws into (A1); drawable size for the chosen layout/rotation and the render scale (1×–4×), plus the integer-scaling magnification filter. |
| `ScreenGeometry.swift` | The drawable size of each layout/rotation and the box the screens occupy for the aspect/integer-scale settings. |
| `GameInfo.swift` | The launcher's `Documents/Games/<TITLEID>/GameInfo.json` manifest (schema 1): authoritative display title, save namespace and pushed game-data size/SHA-256; the pack fields are informational metadata about the pack embedded in the IPA. |
| `InstalledGame.swift` | Scans `Documents/Games` for pushed game data, validates it (folder/title ID, manifest, ROM presence/size/path containment) and verifies the recorded SHA-256 in the background. |
| `GameCatalog.swift` | The bundle `GameCatalog.json` schema (v2, v1 compatible): the build's game list plus per-game `packFile`/ABI/`registrationSymbol`. A base shell may ship an empty catalog. |
| `GameLibrary.swift` | The library: bundle catalog joined with the pushed `Documents/Games` data, per-card states (AOT / Checking / Data missing / Error), background SHA-256 checks and `Documents/Library/playHistory.json`. No ROM importing. |
| `AOTPackageLoader.swift` | Resolves/loads the per-game `GamePack.dylib` from the signed app bundle, validates title/ABI/registration symbols before use, hands the launch the pushed (or legacy bundled) ROM, documents the C ABI, and falls back to the statically linked single-game build. |
| `DebugLaunch.swift` | Headless launch hooks: `-openAOTTitleID` (start a library game) and `-gamesRoot` (scan a Simulator fixture folder instead of Documents/Games). |
| `LegacyGameData.swift` | One-time migration for apps updated from 0.1.x: cartridge lookup for the statically linked title, play times, and renaming ROM-named save folders to the title-id namespace. |
| `ScreenImage.swift` | Reusable RGBA buffers and `CGImage` conversion. |
| `InputState.swift` | Thread-safe merge of touch, overlay and controller input. |
| `TouchControlsView.swift` | On-screen button controls: the portrait pad and the landscape top bar / side rails (opacity and haptics options). |
| `GameControllerInput.swift` | GameController-to-3DS button mapping. |
| `AudioOutput.swift` | Ring buffer and AVAudioEngine output (volume, mute, buffer duration). |
| `FrameTiming.swift` | Per-phase frame timing for the diagnostics report and the fast-forward auto-fallback. |
| `GraphicsWarmUp.swift` | Optional first-load graphics warm-up state/plan (off by default), its persisted "warmed" marker and pipeline-cache filesystem stats. |
| `Localization.swift` | `L10n` lookup/format helpers, the resolved display language, and the locale-change observer that rebuilds the UI. |
| `AppLog.swift` | In-app log capture and the diagnostics report assembly. |
| `ShareSheet.swift` | System share sheet for exported diagnostics. |
| `Resources/en.lproj/Localizable.strings` | English UI strings (development language; keys are the English text). |
| `Resources/zh-Hans.lproj/Localizable.strings` | Simplified Chinese translations of the same keys. |

`ios/ZakuroBridge.h` is the C bridge; all calls that take a runtime handle must
run on the single serial queue owned by `ROMSession`.

## Presentation (A1)

The app has one presentation path and one fallback:

| Path | What happens | Frame timing |
|---|---|---|
| **CAMetalLayer (A1)** | The app owns a `MetalScreenView` (`UIView` + `CAMetalLayer`), makes a Zakuro Vulkan presenter for it (`zk_presenter_create`) and loads the ROM with `zk_create_presented`. The presenter lays out the chosen screen arrangement in the layer's drawable (`zk_presenter_set_layout` / `zk_presenter_set_orientation`); after every `zk_run_frame` the app calls `zk_present` and the screens go straight from the renderer's GPU images to the swapchain. | `present` phase; no screen reads, no `CGImage` |
| **CGImage readback (fallback)** | `zk_create` + `zk_read_screen` for each screen, converted to `CGImage` and shown by SwiftUI in the same layout/rotation. Only when no presenter can be made. | `read top` / `read bottom` / `CGImage` phases |

- Both screens are in the one layer: Zakuro's presenter arranges them itself, so
  no 2D composition in Swift is needed. The on-screen touch surface maps a
  normalised touch to lower-screen pixels with `zk_present_touch_map`, passing
  the same layout and rotation the presenter uses (a rotated screen is mapped
  back into its own upright pixels).
- The fallback triggers automatically when `zk_presenter_create` returns `NULL`
  (for example no MoltenVK in the app, or a device that cannot make a Vulkan
  device), when `zk_create_presented` fails (the load is retried once with
  `zk_create`), or after about a second of `zk_present` failures. A presented
  load whose renderer stays in software still uses the Metal layer: the
  presenter uploads the CPU pixels, so the app still never builds a `CGImage`.
- The Metal view and presenter are created on the main queue and kept for the
  app's lifetime, so a later load reuses the same layer and Vulkan device. The
  frame loop stops presenting when the runtime stops (Unload, background,
  exit/fault); the presenter is released with the app. A display change (layout,
  rotation, render scale) resizes the layer's drawable and the presenter's
  swapchain on the runtime queue, so the next frame uses it; that costs one
  out-of-date present. For the render scale that only resizes the drawable: the
  internal 3D render scale itself is set with `zk_set_render_scale` and read when
  a system loads, so an already loaded game keeps its internal scale until it is
  reloaded or restarted.
- Because there is a real Metal layer, the system Metal Performance HUD can
  attach to it: Settings → Performance → System Metal HUD sets
  `developerHUDProperties` on the layer (`mode: "default"` / `"disabled"`) at run
  time, and the build's `MetalHudEnabled` (or the device's Developer settings)
  must also enable it. On the readback path there is no layer, so the HUD does
  not appear.

## Input

- The on-screen controls and a connected hardware controller are merged by
  `InputState`; the session reads one snapshot on the runtime queue immediately
  before `zk_run_frame` and calls `zk_set_input` there. In portrait the pad sits
  below the screens; in landscape the D-pad and A/B/X/Y clusters sit in reserved
  left/right rails and L/R/Select/Start in a top bar, so they never cover the
  screens.
- Controller mapping: D-pad → D-pad, A/B/X/Y → A/B/X/Y, L1/R1 → L/R, L2/R2 →
  ZL/ZR, Menu → Start, Options → Select, left stick → Circle Pad.
- Dragging on the lower screen sends touchscreen coordinates in lower-screen
  pixels; on the presented layer the runtime finds the lower screen from the
  current layout and rotation, so only that part of the layer is a touch
  surface. A touch on the upper screen is ignored.
- Input is cleared on pause, unload, background and reset, so a held button
  cannot survive a state change.

## ROM handling

- Game data is the user's decrypted ROM. The desktop launcher pushes it into
  `Documents/Games/<TITLEID>/GameRom.cci` (or the file name declared in
  `GameInfo.json`); the shell reads it in place and never copies or imports it.
- The AOT code for each game is part of the signed app (`Frameworks/`), never in
  Documents: iOS will not `dlopen` an unsigned dylib copied there.
- An app updated from the previous self-contained build may still have its ROM
  inside the app bundle and keeps launching that way until the launcher
  reinstalls and pushes the data; an app updated from the 0.1.x shell may still
  have its old cartridge under `Documents/roms/`, read only by the legacy
  statically linked single-game build.
- The repository ships no ROMs, keys or game data. The app works only with
  decrypted dumps the user obtained from their own console.

## Save data

Two kinds of data stay on the device:

| Data | Where | Managed by |
|---|---|---|
| Battery saves | `Documents/data/<save namespace>/` | The game's own save menu writes them; the Save Manager lists, exports, imports and deletes them. |
| Instant save states | `Documents/states/<save namespace>/slot1.bin` … `slot3.bin` | Save State / Load State in the in-game menu (slot 1) and the Save Manager (all three slots). |

The save namespace is the title ID by default; a launcher may set `saveNamespace`
in `GameInfo.json` (for example to share saves between two regional builds). The
folder is sanitized, so two games can never share a save-data directory unless
the launcher deliberately gives them the same namespace.

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
- The readback fallback (no MoltenVK / no Vulkan device) still shows every
  layout and rotation, but it copies both screens to the CPU each frame and is
  slower than the presented path; its stretch mode divides the space between the
  two screens rather than reproducing the presenter's exact sub-screen split.
- A game runs only when this build has its AOT code — normally
  `Frameworks/GamePack-<TITLEID>.dylib` listed in the bundle `GameCatalog.json`
  — and its pushed game data has passed validation. An app updated from an older
  build may still use a bundled ROM or a statically linked 0.1.x `libgame.a`.
  There is no interpreter fallback.
- Adding a game rebuilds and reinstalls the shell: the AOT pack must be signed
  inside the IPA. Only the (large) game data is pushed afterwards and is kept
  across later updates, so adding a second game does not need the first game's
  data re-pushed.
- A catalog game shows **Data missing** until the launcher's data push finishes.
  The push writes `GameInfo.json` last, so a half-finished push is never treated
  as a game.
- The first scan after a large push reads the game data once to verify the
  SHA-256 the launcher recorded. That check runs in the background and the card
  shows **Checking** until it finishes; a push without recorded hashes skips the
  check. A size or hash mismatch blocks launch with an error card.
- The first release does not include camera, microphone, online play or a full
  game library UI.
- Button remapping is not available in this build. Save states are not
  interchangeable between games or runtime versions, and only battery saves are
  exported and imported; instant states stay in the app container.
- The "Preparing graphics" warm-up is off by default. A pipeline first used
  during play compiles on a worker thread and draws through the generic fallback
  meanwhile, so a title can hitch briefly on first use; enabling the optional
  warm-up moves the first-load compiles behind a loading screen but cannot cover
  pipelines first used later. Completing shader AOT is out of scope: it cannot
  cover every runtime shader/pipeline combination, and a first run has no cache
  to load.
- Fast-forward mutes the game audio while it is active, and the automatic
  fallback gives up extra frames when a scene is too slow (see
  "Fast-forward"). It cannot make a game that already runs below 20 fps
  faster.
- The system Metal HUD switch only works when the build or the device enables
  the HUD, and only on the presented `CAMetalLayer` path.
- Only English and Simplified Chinese are included. Traditional Chinese and
  other languages use English.
- iOS 16+ only; the app is not distributed through the App Store.

## Diagnostics

The status line in the game view includes:

```text
audio: on
AOT · linked   fast-forward: 2×
loop: free-run · cap 60 fps   display: CAMetalLayer · GPU direct
warm-up ready in 2.40 s · 146 frames · max 586 ms · 3 spiky (>50 ms)
```

The `fast-forward: 2×` and `(auto)` markers appear only above 1×. The `warm-up …`
line appears once an enabled warm-up finished (it replaces the "Preparing
graphics…" overlay), or says it was not needed for a software renderer; it is
absent by default because the optional warm-up setting is off. The device log
carries one line per load
(`zk_presenter_create`, `display:`, `hardware:`), the pipeline-cache state at
launch/load/after `zk_destroy`, one `graphics warm-up:` line with the same
timing, a `frame cap:` / `render scale:` line when those settings change (the
render-scale line notes that the internal 3D scale applies on the next load),
one line per pause/resume/reset, one `save state:` line per save/load/delete,
one `library:` line per scan (entry counts per source) with a `library entry:`
line and the per-game validation messages for every game, the
`-gamesRoot`/`-openAOTTitleID` arguments when the debug hooks are used,
one `save data:` line per export/import/delete, and a `perf:` line every ~2 s
with the per-phase timings.

The exported diagnostics header adds the build, device, session phase
(`paused=`), the runtime state, the active settings (`frame_cap=`,
`screen_layout=`, `screen_aspect=`, `integer_scale=`, `render_scale=`,
`render_scale_applies=`, `orientation=`, `audio_volume=`, `audio_muted=`,
`audio_buffer_ms=`, `touch_controls=`, `controls_opacity=`, `haptics=`,
`playback_speed=`, `playback_speed_effective=`,
`playback_speed_auto_reduced=`, `warmup_enabled=`, `system_metal_hud=`,
`screen_rotation=`, `presented_native_pixels=`, `presented_drawable_pixels=`,
`system_metal_hud_build_enabled=`, `app_language=`, `system_language=`), the
`warmup_*` fields (`outcome`, duration, frames, max frame, spike count, plan
limit, whether the pipelines were already cached) and the `pipeline_cache*`
fields (directory, file count, size, newest file), followed by the previous and
current session logs. These values make renderer, presentation, scheduler,
settings, fast-forward, language and graphics warm-up changes measurable on
device.
