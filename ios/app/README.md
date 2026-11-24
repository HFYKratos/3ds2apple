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
| **Home** | The library from the build's `GameCatalog.json`, joined with the game data pushed into `Documents/Games`. Each card has a square art area at the icon's native 1:1 aspect: the game's own SMDH cover art (launcher-pushed `cover.png`, else the build's bundled cover, else the gradient placeholder) fills the square edge to edge with no inset frame (the gradient is only the placeholder when no cover is available), and a corner badge appears only when a game needs attention (**Checking** / **Data missing** / **Error**; a ready game has no AOT badge, since the app only runs AOT code and the AOT state stays in the log and the diagnostics export). Under the art the card is deliberately compact: the title for the app language (up to two lines, truncated), the publisher, then the pushed game size · last-played state. There is **no explanatory paragraph under the grid**. iPhone shows two columns, iPad three. Tapping a game starts it; a game without pushed data explains that the launcher must push it, a broken push lists the exact validation error. Pull-to-refresh rescans Documents, and the library also rescans at launch and when the app returns to the foreground; there is no refresh button. Long-pressing a card opens its context menu; **Delete Game** asks a second confirmation and then deletes the game (see "Deleting a game" below). The empty state explains the desktop launcher. No on-phone import. Settings entry. |
| **Game** | The two screens on a `CAMetalLayer` (or the screen-readback fallback) arranged by the split landscape / portrait screen layout choices, filling the whole screen, with the on-screen controls floating over the picture, a floating FPS pill and pause button and the in-game menu. There is no title bar or reserved control pad any more. When a title starts the 3DS software keyboard, a full-screen keyboard overlay collects the text and the applet's buttons while the frame loop is stopped; answering resumes the game. |
| **Settings** | An iOS inset-grouped List of eight category rows with SF Symbol icons (0.1.7-beta5): General, System, Gamepad, Graphics, Layout, Sound, Debug and Other, plus a real **Reset All Settings** action in its own section. Each category is a large-titled grouped page of rows with an explanation and a trailing control; the system semantic colours follow the light/dark appearance because the settings stack no longer forces dark. See "Settings screens (0.1.7)" below. |
| **Save Manager** | A game picker over the whole library (the selection is remembered; opened from the in-game menu it starts on the running game): the selected game's battery save files (size, date, export as ZIP, import, delete), its three instant save-state slots (delete without the game, save/load only while that game runs) and the container usage. The page re-reads the selected game's files when it opens, when the library changes and after every action; there is no refresh button. |
| **About** | Product page: app icon, name, version and build, one-line positioning, links (repository, releases, issues, README, licence, third-party notices), acknowledgements and the legal notice. A compact runtime card with the AOT state, the presentation path and the FPS appears only while a game is loaded; everything else stays in the log and the diagnostics. |
| **In-game menu** | Opened from the floating gear button over the game: the same iOS-style card that slides up from the bottom in portrait and is centred (scaled in) in landscape, following the system light/dark appearance. The header is still **MENU** with the power / restart / quick-save / quick-load capsule and the **X** that resumes; the rows now follow the reference emulator's in-game menu: **Save state**, **Virtual controls**, **Screen layout**, **Swap screens** (toggle), **Rotate screen clockwise**, **Global Settings**, **Per-Application Settings** (per-game overrides stored by title ID) and **Close game**. Sub-pages open inline inside the sheet (Save state, Virtual controls, Screen layout, Per-Application Settings). Save Manager / Export logs / Fast-forward / Sound are intentionally not in this menu (they stay in Settings/Debug). Tapping the dimmed area above (portrait) or outside (landscape) the card resumes the game. |

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
- Upper screen 400×240 and lower screen 320×240, arranged by the split screen
  layout settings - a landscape choice (Large screen / Single screen / Side by
  side / Hybrid / Original / Custom layout) and a separate portrait choice
  (Default / Original / Custom layout) - optionally turned a quarter turn; the
  lower screen also acts as the 3DS touchscreen.
- On-screen buttons (D-pad, A/B/X/Y, L/R, Start/Select) with configurable
  opacity and optional haptic feedback, plus GameController support (MFi, Xbox,
  DualSense). The game picture fills the whole screen and the controls float over
  it as a full-screen overlay in both orientations; the shipped default positions
  are converted from the ModernCenteredX2 reference skin (round 5; geometry only),
  a hand-edited layout can move them in-game, and the layout reflows when the
  device rotates.
- Audio through `zk_take_audio` and AVAudioEngine, with volume, mute and an IO
  buffer size preference.
- Instant save states: three slots per game, one file per slot under
  `Documents/states/<title id>/`. The in-game menu saves to and loads from slot 1;
  the Save Manager page lists and deletes the selected game's slots even while it
  is not running, and saves or loads them only while that game runs. A background
  recovery snapshot lives next to the slots
  (`Documents/states/<save namespace>/background.bin`, named by
  `Documents/states/background.json`; see "Background lifecycle (0.1.4)").
- Save-data management: the Save Manager's game picker manages every game in the
  library, not just the one that was last started: export the selected game's
  battery saves as a ZIP archive through the share sheet, import a ZIP archive or
  single save files back, and delete individual files. Import and delete are
  disabled while a game is running.
- Deleting a game: long-pressing a Home page card opens its context menu; its
  **Delete Game** action asks a second time and then removes the game from this
  device — its pushed game data
  (`Documents/Games/<TITLEID>/`: ROM, `GameInfo.json`, pushed cover), its battery
  saves (`Documents/data/<save namespace>/`), its instant save states
  (`Documents/states/<save namespace>/`), its play history and its per-game
  settings/cover override. **This cannot be undone.** The AOT pack is part of the
  signed app and cannot be removed at run time, so the title is hidden from the
  library instead and pushing the game's data again with the desktop launcher
  brings it back. The Home page and the Save Manager update immediately; there is
  no refresh button.
- Free-running frame loop capped at 60 Hz (or 30 Hz) and decoupled from the
  display refresh.
- Fast-forward at 1× / 2× / 4× from Settings and the in-game menu: each
  presented frame advances the console 2 or 4 frames. See "Fast-forward" below
  for the presentation/audio policy and the automatic fallback.
- Presentation on a real `CAMetalLayer` (A1): Zakuro shows both screens through
  MoltenVK over Metal; the launcher's shell template embeds
  `Frameworks/MoltenVK.framework`. When a presenter cannot be made the app falls
  back to the `zk_read_screen` + `CGImage` path and logs a performance warning.
- System Metal Performance HUD (FPS / GPU time / memory): **off by default**
  since 0.1.6-beta3; a Settings switch shows or hides it on the presented layer
  (`CAMetalLayer.developerHUDProperties`, iOS 16) and existing installs are
  migrated to off once (the marker makes the migration run only once, so a
  manual switch afterwards wins). See "System Metal HUD" below.
- Optional in-game FPS counter, **on by default**: the only performance readout
  the game view draws. The switch lives in Settings → Layout → Performance monitoring; the counter is
  a translucent pill floating in the top-trailing safe-area corner over the
  picture in both orientations (the pause button sits next to it in portrait and
  at the bottom centre in landscape). Everything else (AOT state, renderer path,
  CPU/present/read timings, Metal HUD state) stays in the device log and the
  diagnostics export. See "In-game FPS counter" below.
- Display settings: separate landscape and portrait screen layout choices (six
  landscape presets, three portrait presets, plus two numeric custom layout
  pages), screen rotation and interface orientation. Every layout preset is drawn
  by the `CAMetalLayer` presenter (round 3 adds the Large screen / Hybrid /
  portrait Default arrangements, presenter ABI 5–7) and applies immediately; only
  the two Custom layouts use the readback path and apply from the next game load.
  Round 4 removed the aspect-ratio and integer-scaling rows only; the render
  resolution (1×–4×) stays (a change applies from the next game load — the
  runtime builds its renderer then). See "Display settings" below.
- AOT status (`AOT not loaded` / `AOT · linked` / `AOT · package`), the
  `zk_recompiled()` / `zk_recompiled_status()` proof recorded for every load,
  emulation speed relative to the 3DS 60 Hz timeline, and a hard AOT-only launch
  rule: a game is never started through the interpreter — a title the runtime
  would interpret is stopped and shown a **red** error naming the runtime's own
  reason.
- Storage page: save-data / legacy game-file / log / pipeline-cache usage and a
  "clear graphics pipeline cache" action (only while no game is running).
- Settings are persisted in `UserDefaults` and restored at launch.
- Games are revealed as soon as they load: the runtime writes its pipeline cache
  while you play (saved every ~5 s and on exit), so later loads start warm. A
  pipeline first used later may compile on a worker thread and hitch briefly;
  the optional first-load "Preparing graphics" warm-up was removed in 0.1.1.
- Language: the app follows the system language (Simplified Chinese or English)
  and re-renders if iOS reports a locale change while it runs. See
  "Localization" below.
- Diagnostics export from the home page and the in-game menu.

## Game library: AOT packs in the app, game data in Documents

A game on the phone has two halves:

| Half | Lives in | How it gets there |
|---|---|---|
| AOT pack + catalog entry (`GamePack-<TITLEID>.dylib`, `GameCatalog.json`) | the signed app bundle (`Frameworks/`, `Resources/`) | the desktop launcher builds the app with the pack and installs it — adding a game rebuilds/reinstalls the shell |
| Game data (the user's decrypted ROM + `GameInfo.json` + optional `cover.png`) | `Documents/Games/<TITLEID>/` in the app container | the launcher pushes it through the device bridge over USB/Wi-Fi; it survives app reinstalls and updates |

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
    cover.png                 launcher-pushed SMDH icon (optional; local user data)
  Library/playHistory.json    last-played times (written by the shell)
  data/<save namespace>/      battery saves (written by the runtime)
  states/<save namespace>/    instant save-state slots
  states/<save namespace>/background.bin   background recovery snapshot (0.1.4)
  states/background.json      the game that snapshot belongs to (0.1.4)
```

`GameInfo.json` is schemaVersion 1 and is authoritative for the pushed game
data: `titleID`, `displayName`, optional `productCode`/`saveNamespace` (defaults
to the title ID), a `rom` object with `file` + optional `size`/`sha256`, plus
optional `cover`, `launcherVersion`, `pushedAt` and `notes`. The `pack` object is
informational metadata about the pack the launcher embedded in the IPA (the shell
never loads a pack from Documents). Unknown fields are ignored; the game data
defaults to `GameRom.cci` / `GameRom.3ds`.

Base library metadata comes from the launcher too — the phone never parses the
ROM: the launcher already read the SMDH icon/titles/publisher/region at import
time and pushes them in the same manifest. `displayName` is the title for the
launcher's UI language; the additive `displayNames` object keeps every original
localized title and the app re-picks for its own language (`zh-Hans`/`en`) before
falling back to `displayName`, then the catalog name, then the title ID.
`publisher` and `region` (SMDH region lockout: `EU`, `US`, `EU+AU`,
`region-free`) are optional and simply omitted when unknown; `cover` is
`"cover.png"` when the icon was pushed. `rom.size` is cross-checked against the
real file during the scan and the card shows that size (formatted MB/GB). The
card's art area is square (1:1) in every state, matching the 48×48 SMDH icon the
launcher exports: the icon is enlarged to fill it and is never stretched or
cropped, so the cover never sits in a 16:9 banner.
Older launchers that push none of these fields stay fully compatible: the card
falls back to the catalog `displayName`, hides the publisher row and draws the
square gradient placeholder instead of an icon.

The shell validates the pushed game data in two passes:

1. **Scan** (fast; at launch, when the app returns to the foreground and on
   pull-to-refresh): the
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

### Deleting a game

Long-press a game's icon on the Home page to open its context menu, then choose
**Delete Game**: it asks a second time and nothing is removed until the dialog's
**Delete** button is pressed. Deleting removes, in one go:

| Data | Where |
|---|---|
| Pushed game data (ROM, `GameInfo.json`, pushed cover) | `Documents/Games/<TITLEID>/` |
| Battery saves | `Documents/data/<save namespace>/` |
| Instant save states | `Documents/states/<save namespace>/` |
| Play history and the per-game settings/cover marker | `Documents/Library/playHistory.json`, the game's persisted settings |

**This cannot be undone** — export the battery saves first (Save Manager →
**Export ZIP…**) if they should be kept. The AOT pack is compiled into the signed
app and cannot be removed at run time, so the title is recorded in
`Documents/Library/removedGames.json` and hidden from the library (the Save
Manager's game picker hides it too). Pushing the game's data again with the
desktop launcher clears that record and the game appears again. The Home page and
the Save Manager update immediately because both observe the same library. The
Home page only offers the action while no game is running; a runtime that is
somehow still active is stopped and released before the files are removed.

### Simulator fixture and debug launch arguments

The shell can be driven headlessly without tapping:

- `-gamesRoot <path>` scans a different folder instead of `Documents/Games`
  (a relative path resolves against Documents, a `Documents/` prefix is
  accepted; an absolute path must stay inside the app container).
- `-openAOTTitleID <TITLEID>` starts that library game 0.5 s after the home
  page appears, through the same path a card tap uses.
- `-openLayoutPage` opens the screen layout page (Settings → Layout: the
  landscape and portrait preset rows and the two custom layout rows) straight
  away, for headless screenshots.
- `-openLayoutPicker landscape|portrait` opens that direction's screen layout
  radio picker straight away, for headless screenshots of the picker itself.
- `-openCustomLayoutPage landscape|portrait` opens the numeric custom layout
  page for that direction, for headless screenshots of the percent fields.
- `-openLayoutEditor screen|control` opens one of the two full-screen layout
  editors directly, for headless screenshots of the editors themselves; the
  `screen-landscape` / `control-landscape` variants force the landscape
  direction (the editors otherwise open for the direction the device is in).
- `-previewGameView` shows the running-game view without a ROM or game pack: two
  synthetic screen images (gradient, 1 px grid and a clear TOP / BOTTOM label,
  400×240 and 320×240) are drawn through the real layout geometry, with the
  floating FPS/pause controls and the on-screen control overlay. The preview path
  needs no ROM, pack or user data and never changes the normal game path.
- `-previewScreenLayout <layout>` applies one screen layout choice for this
  launch only (in memory, never persisted). With `-previewLandscape` the values
  are the landscape choices: `large`, `single`, `side`, `hybrid`,
  `original`, `custom`; without it they are the portrait choices:
  `default`, `original`, `custom`. A value of the other direction is logged
  and ignored.
- `-previewLandscape` forces the landscape appearance for headless screenshots
  (the app asks its window scene to rotate and the game view uses the landscape
  arrangement even before the rotation lands).
- `-previewPauseMenu` opens the iOS-style in-game menu over the preview picture,
  for headless screenshots (portrait bottom sheet or landscape card).
- `-previewControlEdit` enters the in-game control edit mode over the preview
  picture (draggable controls + Done pill), for headless screenshots.
- `-openControlOptions visibility|size|opacity` opens one virtual-control options
  sheet in that pause menu, for headless screenshots.

A full screen-layout tour needs no game data at all:

```sh
# Landscape presets (terminate first: simctl launch ignores new arguments while the app runs)
for layout in large single side hybrid original custom; do
  xcrun simctl terminate <UDID> com.kratos.3ds2apple 2>/dev/null || true
  xcrun simctl launch <UDID> com.kratos.3ds2apple \
    -previewGameView -previewScreenLayout "$layout" -previewLandscape
  sleep 2
  xcrun simctl io <UDID> screenshot "landscape-$layout.png"
done
# Portrait presets
for layout in default original custom; do
  xcrun simctl terminate <UDID> com.kratos.3ds2apple 2>/dev/null || true
  xcrun simctl launch <UDID> com.kratos.3ds2apple \
    -previewGameView -previewScreenLayout "$layout"
  sleep 2
  xcrun simctl io <UDID> screenshot "portrait-$layout.png"
done
# Round-4 control options (ROM-free preview)
xcrun simctl launch <UDID> com.kratos.3ds2apple -previewGameView -previewPauseMenu
xcrun simctl launch <UDID> com.kratos.3ds2apple -previewGameView -previewPauseMenu -openControlOptions visibility
xcrun simctl launch <UDID> com.kratos.3ds2apple -previewGameView -previewPauseMenu -openControlOptions size
xcrun simctl launch <UDID> com.kratos.3ds2apple -previewGameView -previewControlEdit
```

The preview arguments are inert in normal launches (a person never passes them).

A Simulator fixture never has to touch the real library: install a Simulator
build of the shell that already contains the game's pack + catalog entry, then
copy only the game data into a separate fixture folder inside the app container
and launch with the arguments above (`xcrun simctl launch ... -gamesRoot
Documents/GamesFixtures -openAOTTitleID <TITLEID>`).

Omit the game-data fixture (or use an empty `-gamesRoot` folder) to see the
**Data missing** state of a catalog game; record a wrong `rom.size`/`sha256` to
exercise the per-game error state. The fixture files are user-owned local test
data: never commit them, and remove the fixture from the container when done.

## Settings screens (0.1.7)

Settings is an iOS **inset-grouped List** (0.1.7-beta4): one section of category
rows with an SF Symbol and the category name, plus a separate section with the
destructive **Reset All Settings** action. There is no forced dark appearance any
more: the system semantic background, card, label and separator colours follow
the light/dark appearance exactly like the rest of iOS. The navigation title is
the localized **Settings** with the large-title style, and every category page is
a large-titled inset-grouped list whose rows have a title, a one-line explanation
and a trailing control (switch, value menu, slider or navigation arrow). The
layout was sketched from reference
screenshots of another emulator's settings app; no code or text from that
project is used (it is GPL and reference-only for this repo).

**General / System / Gamepad / Graphics / Layout / Sound / Debug / Other:**

- **General** (0.2.0): **Run speed limit** (`settings.runSpeedLimit`, on by
  default). On, the game runs at the Default speed (or Turbo speed while Turbo
  is active) and is capped at 4×. Off, every presented frame advances guest
  frames until the 60 Hz hardware time budget is used — no 4× clamp — the
  Turbo button has no extra effect, audio is muted and the page shows an orange
  **High power use** warning about heat and battery drain. **Check for updates**
  (`settings.checkForUpdates`, `UpdateChecker`) checks GitHub when the page
  opens and at most once per 24 hours in the background; **Update channel**
  (`settings.updateChannel`, Stable / Beta) selects full releases only or
  pre-releases too; an available update posts a local notification
  (`UNUserNotificationCenter`, permission requested when first needed) and the
  Update status row shows up-to-date / update-available / check-failed.
  **Turbo limit** (`settings.turboLimit`): on, the on-screen Turbo button uses
  **Turbo speed** (2× / 3× / 4×, `settings.turboSpeed`) and the runtime may
  lower it automatically below 20 fps; off, holding Turbo runs unlimited guest
  frames (no auto slowdown, audio muted, same heat/battery warning). **Default
  speed** is 1× / 2× / 3× / 4× (`settings.playbackSpeed`). The old
  Fast-forward and read-only Frame limiter rows are gone.
- **Layout**: the screen layout page entry (landscape/portrait preset rows and
  the two numeric custom pages), **Screen rotation**, **Orientation lock**
  (`settings.orientation`), the **Swap screens** switch (`settings.swapScreens`)
  and a **Performance monitoring** group with the **FPS counter**
  (`settings.showFPS`) and the **System Metal HUD** (`settings.systemMetalHUD`,
  with the exact reason hint when the HUD cannot appear).
- **Gamepad**: on-screen controls on/off, overlay opacity, haptics and the
  connected controller name; control positions are still edited in-game from the
  pause menu (see "Editable layouts").
- **Graphics**: render resolution 1×–4× with the exact pixel caption,
  **Screen aspect** (Fit / 4:3 / Stretch, `settings.screenAspect`) and
  **Integer scaling** (`settings.integerScale`, whole-console-pixel nearest
  magnification for Fit/4:3) — both are real settings applied immediately to the
  preset screen layouts; the custom layouts place each screen explicitly and
  ignore them. Then the two experimental GPU switches
  (`settings.gpuVertexShaders` / `UI.experimental.gpuVertexShaders`,
  `settings.preciseShading` / `UI.experimental.preciseShading`); the old
  read-only Renderer row was removed in 0.1.7-beta5. Both experimental switches
  are read once in `App.init` before the renderer's first device, so their rows
  carry a **Restart required** badge and only take effect after force-quitting
  and relaunching the app. `gpuVertexShaders` forces the GPU vertex-shading
  path (`ZAKURO_GPU_SHADERS=1`); `preciseShading` turns off the release
  fast-math fragment build (`ZAKURO_FRAG_FAST_MATH=0`). Both default to off.
- **System** (0.1.7-beta5): the real system/appearance rows — **Appearance**
  (System / Light / Dark, `settings.appearance`, applied at the app root as a
  SwiftUI colour scheme), **Device**, **System version**, **App version** and
  **Package**. The old storage/version/language/About rows moved to Other.
- **Other**: the storage snapshot (installed games, save data, legacy files,
  app logs, graphics pipeline cache), the pipeline-cache clear action with its
  confirmation and "available when no game is running" gate, version/build, the
  active language and the About product page (icon, links, acknowledgements,
  legal notice). The category uses the `ellipsis.circle` icon and the About page
  is still one row inside it.
- **Sound**: volume, mute and the audio buffer size.
- **Debug**: AOT verification rows (localized AOT state, AOT coverage and the
  interpreted percentage parsed from the runtime's `AOTDiagnostics` status text,
  plus the instruction-fallback count when reported), the Save Manager, the CPU
  profiler page and the diagnostics/log export with its kept-file hint (same
  `Documents/Diagnostics` copy and share sheet as before). The profiler samples
  raw guest PCs while a game runs and adds a small per-step cost; it is for
  diagnosis only and stays on for the current game load.

**Reset All Settings** (bottom of the main page) asks for confirmation and then
removes the app's whole `UserDefaults` domain
(`removePersistentDomain(forName: Bundle.main.bundleIdentifier!)`); it shows a
"relaunch to apply" alert because the live settings object keeps its in-memory
values until the next launch. Game data, battery saves and the diagnostics
export live in Documents and are **not** reset.

Settings is still opened from the home page. It is not reachable while a game is
running (the game view replaces the home page), so the CPU profiler's "Start
sampling" control and the Debug page's AOT rows can only be used once Settings
has an in-game entry point; the Debug page says when no game is running.

## Display settings

| Setting | Values | Behaviour |
|---|---|---|
| Landscape screen layout | Large screen (default) / Single screen / Side by side / Hybrid / Original / Custom layout | The **landscape** choice, selected from a radio picker the row opens. All six choices apply immediately; the first five are `CAMetalLayer` presenter arrangements: **Large screen** = upper screen 400x240 at the left with the lower screen scaled by 1/2.25 at its upper right (ABI 5); **Single screen** = upper screen maximised; **Side by side** = both screens side by side at their native sizes; **Hybrid** = upper screen 400x240 at the left with the small upper screen above the small lower screen in the right column (ABI 6); **Original** = native stack. **Custom layout** uses the numeric custom rectangles on the readback path, so it applies from the next game load. The arrangements are described under "Editable layouts". |
| Portrait screen layout | Default (default) / Original / Custom layout | The separate **portrait** choice, selected from its own radio picker. **Default** is the top-full-width presenter arrangement (upper 400x240 above the lower screen scaled to 400x300, ABI 7); **Original** uses the presenter's native stack; both apply immediately. **Custom layout** uses the numeric custom rectangles on the readback path and applies from the next game load. |
| Custom layouts | Landscape custom layout / Portrait custom layout | Each row opens a numeric page for that direction: sections **Upper screen** and **Lower screen**, each with **X position**, **Y position**, **Width** and **Height** as integer percentages of the game view (0–100). The page edits the existing `CustomScreenLayout` archive (archive version 3; older archives migrate on read) and applies from the next game load; **Edit by dragging** opens the full-screen drag editor for the same direction. The shipped defaults are the placements measured from the reference screenshots. |
| Screen rotation | Upright, 90° clockwise, upside down, 90° counter-clockwise | Immediately. Turns the screens inside their area, e.g. the stacked console becomes two columns (480×400) a quarter turn clockwise. The touchscreen is mapped back into the screen's own pixels. |
| Resolution | 1× / 2× / 3× / 4× | The presenter's drawable is the arrangement's own pixels times the factor and CoreAnimation scales it to the screen; the swapchain is resized through `zk_presenter_resize` at once. The internal resolution the host-GPU 3D renderer draws at is set with `zk_set_render_scale` and read when a system loads, so a running game keeps its old internal scale until it is reloaded or restarted. The software renderer always draws at 1×; higher factors cost GPU time and memory. The caption under the picker follows the selection and states its pixel size. |
| Orientation | Automatic / portrait / landscape | Immediately: the app restricts the supported orientations and asks the window scene to rotate. The in-game layout reflows for portrait/landscape. iOS still decides in some situations (for example during a phone call). |

**Round-4 display cleanup.** The **Aspect ratio** (画面比例) and **Integer
scaling** rows are gone: the layout presets are GPU presenter arrangements that
do not use those readback knobs, and only the Custom layouts still place each
screen natively inside its rectangle. The **Resolution** setting remains and,
like before, the runtime's internal 3D scale applies from the next game load.
The old stored aspect/integer keys are kept but ignored.

The 3DS screens stay upright in the app's interface, which iOS rotates with the
device; `Screen rotation` turns the pictures inside their area for playing with
the console held sideways. The running game fills the whole screen - there is no
title bar, rounded card or reserved control pad any more - and the FPS/pause
controls float over the picture. The layout presets are presenter arrangements;
aspect ratio and integer scaling no longer have UI (round 4) and the custom
layouts place each screen explicitly in the whole game view (screen rotation and
each screen's native shape still apply).

## Audio settings

Volume and mute are applied to the running mixer immediately. The buffer size
preference (low latency 5 ms / balanced 10 ms / stable 20 ms) is passed to
`AVAudioSession`; changing it while a game is running restarts the audio engine
once. Fast-forward is silent: see "Fast-forward" below.

## Controls settings

Settings → Gamepad keeps the on-screen-controls switch, the global overlay
opacity, haptics and the connected `GCController` name. There is **no
full-screen editor link** any more: all control layout editing happens in the
game through the pause menu's **Virtual controls** card (round 4) — Edit layout,
Toggle controls, Adjust size, Adjust opacity and Reset virtual controls. See
"Editable layouts" below.

## Editable layouts (controls and screens)

Requirement 7 (complete virtual controls) and requirement 8 (screen layout) are
two areas. Controls are edited in-game from the pause menu's **Virtual controls**
card; the screen layout was split in round 2 into an independent landscape
choice (six options) and an independent portrait choice (three options), each
selected from its own radio picker, with the numeric custom pages and the
round-4 drag editor described below.

- **Default control layout (round 5 skin, round 6 device adjustments).** The shipped positions are converted
  from the **ModernCenteredX2** reference skin (a Delta `.deltaskin` zip read
  only for its numeric `items[].frame` rectangles; no artwork or text copied):
  landscape mapping 896x414 pt and portrait 414x896 pt, centres and sizes
  normalised to our full-screen overlay (skin frames divided by the mapping
  size, five decimals; the delta-emulator reference itself scales the same way).
  Round 6 (final screenshot revision) puts the whole **portrait** set in the free
  band below the picture: the shoulder row ZL/L/Select/Start/R/ZR is one line at
  y=0.755 just below the picture (bottom ~0.73), the main set sits at y=0.87 and
  the C-stick goes to the bottom-right corner at (0.92, 0.935) with size 0.08;
  the set occupies roughly 0.73–0.96. The **D-pad** is ONE cross-shaped control
  (round 7): the four directions keep independent placements/elements as input,
  visibility and size semantics (arm thickness 0.12681 in landscape / 0.12440
  in portrait so it matches the skin D-pad frame; the placement centres are the
  four arm positions), but the runtime and both editors draw and drag a single
  rounded plus. A touch reports the arm under the finger and a press-and-slide
  changes direction; old profiles need no migration. L/R and Start/Select match
  their skin
  frame heights; the capsule widthRatio is unchanged. The skin's ZL/ZR and
  C-stick are absent, so ZL/ZR sit just above L/R and the landscape C-stick sits
  above the A-B-X-Y cluster; all controls use opacity 0.85. An untouched beta3
  (round-5) or older shipped profile migrates to this table; a customised
  profile is kept. A stored profile that is still the previous
  shipped default (compared within tolerance) is migrated to the new default on
  load; a profile the user moved is kept. **Reset virtual controls** restores the
  new default.
- **Controls (in-game pause menu).** The overlay draws the full New 3DS set:
  D-pad, A/B/X/Y, L/R, ZL/ZR, Start/Select, the Circle Pad and the C-stick. It is
  a full-screen floating layer over the picture in both orientations and takes no
  layout space, so hiding it never moves the image. The pause menu's **Virtual
  controls** page (opened from the in-game menu's first row) has: **Show virtual controls**, **Show performance
  stats** (the FPS pill), **Haptic feedback**, **Edit layout**, **Toggle
  controls**, **Adjust size**, **Adjust opacity** and **Reset virtual controls**.
  - **Edit layout** closes the menu, keeps the runtime paused, hides the pause/FPS
    HUD and returns to the frozen game picture with the on-screen controls
    draggable (a light haptic tick when a control is picked up). Dragging moves a
    control live; a **Done** pill in the exact centre of the screen (round 8; the
hint sits above it and the empty area stays inert) saves the current direction's profile,
    leaves edit mode and resumes the game directly (no extra pause/resume).
  - **Toggle controls** opens a checkbox sheet for A, B, X, Y, L, R, ZL, ZR,
    Start, Select, the D-pad (all four directions as one group), the Circle Pad
    and the C-stick. Visibility is global (not per orientation), persists, and a
    hidden control is neither drawn nor hit-testable.
  - **Adjust size** opens one slider per row above, 10%-200% in 5% steps, default
    100%. The scale is global per row, applies to the running overlay (analog
    sticks included) and persists; the D-pad group scales all four directions.
  - **Adjust opacity** opens the existing global overlay-opacity slider
    (15%-100%).
  - **Reset virtual controls** asks for confirmation and restores the shipped
    positions for both orientations, every row to 100% and all controls visible.
  - The D-pad is drawn and edited as **one cross**: dragging it moves all four
    directional placements together, snapping uses the cross centre, and the
    Toggle controls / Adjust size sheets keep their single D-pad row.
  - Round 0.1.6 adds four app-only on-screen buttons: **Turbo/Fast-forward**
    (a toggle drawn with forward.fill; it uses the General page's Turbo speed
    and a second tap restores the Default speed), **Quick save** (tap: quick
    slot + "Quick saved" toast),
    **Quick load** (tap: load the quick slot + "Quick loaded" toast) and **Swap
    screens** (tap: swap which screen is shown top/bottom, persisted and applied
    to the GPU presenter immediately). They appear in Toggle controls / Adjust
    size like every other row.
  - 0.1.6-beta2 makes control visibility **per device direction** (defaults:
    C-stick/ZL/ZR hidden in both; portrait also hides the D-pad) and migrates
    the old global hidden set once. Both editors now use one stationary canvas
    drag gesture: the item is hit-tested on start, a local preview follows the
    finger and the profile is committed once on release (tap selects, moving
    controls no longer carry the gesture, so the jitter videos are fixed).
  The old Settings → Gamepad full-screen editor and its Default/Custom mode are
  no longer exposed: every change is stored immediately from the in-game editor
  (the profile archive and the per-row visibility/size scales are global). The
  reference layout app's behaviour rows (slide buttons, relative stick centre,
  D-pad slide, Combo Button) are not implemented; they are noted as future work.
  0.1.7-beta3 redesigned the whole in-game menu as a bottom card (portrait) /
  centred card (landscape) with a MENU header, power / restart / quick save /
  quick load / X icon buttons and grouped rows with SF Symbols; 0.1.7-beta4
  moves it to the iOS grouped style (system semantic colours, slide/scale-in over
  a dimmed background, tap outside to resume). 0.2.0 keeps that look and adopts
  the reference emulator's in-game option set: Save state, Virtual controls,
  Screen layout, Swap screens, Rotate screen clockwise, Global Settings,
  Per-Application Settings and Close game, with the top icon actions unchanged.
  Save Manager, Export logs, Fast-forward and Sound are not duplicated here:
  they remain in Settings (General/Sound) and Debug (Save Manager, export).
  **Per-Application Settings** stores a small override record per title ID
  (`UI.perGameOverrides`) for Screen rotation, Swap screens, Integer scaling and
  Screen aspect; a row left on "Use global" falls back to the global setting,
  and a Clear action removes the record. Amiibo, cheats and multiplayer are
  deliberately not shown as rows (see TODO.md).
- **Analog sticks.** The Circle Pad is a real analog stick: dragging inside it
  reports -1…1 on both axes (a 14% dead zone is removed, so a resting finger is
  exactly 0) into `InputState.circleX/circleY` and `zk_set_input`. It is not a
  second D-pad. The C-stick works the same way and reaches the runtime through
  the additive `zk_set_cstick` C ABI (see below), because `zk_set_input` predates
  the New 3DS nub. A hardware controller's left stick feeds the Circle Pad and
  its right stick feeds the C-stick; on-screen and controller vectors add up and
  clamp to 1.0.
- **Screens: landscape choice.** Settings → Layout → **Landscape screen layout**
  shows the current landscape choice; tapping the row opens a radio
  picker with the six landscape layouts in this order:
  - **Large screen** (default) - the upper screen 400x240 at the left and the
    lower screen scaled by 1/2.25 at its upper right (presenter
    `.largeTopRight`, ABI 5);
  - **Single screen** - the upper screen only, maximised and centred
    (presenter `.upperOnly`);
  - **Side by side** - upper screen left, lower screen right at their native
    sizes (presenter `.sideBySide`);
  - **Hybrid** - the upper screen 400x240 at the left and a right column with
    the small upper screen above the small lower screen (presenter `.hybrid`,
    ABI 6; the presenter emits the upper screen twice);
  - **Original** - both screens stacked at their native sizes (presenter
    `.stacked`);
  - **Custom layout** - the landscape rectangles from the numeric custom page
    (readback).
- **Screens: portrait choice.** Settings → Layout → **Portrait screen layout**
  shows the current portrait choice; its radio picker offers:
  - **Default** (default) - top full width: upper screen 400x240 on top, lower
    screen scaled to 400x300 below it (presenter `.topFullWidth`, ABI 7);
  - **Original** - the native stack, top-aligned (presenter `.stacked`);
  - **Custom layout** - the portrait rectangles from the numeric custom page
    (readback).
- **Custom layouts (numeric pages).** Settings → Layout → **Landscape custom
  layout** / **Portrait custom layout** open one numeric page per direction:
  sections **Upper screen** and **Lower screen**, each with **X position**,
  **Y position**, **Width** and **Height** as integer percentages of the game
  view (0-100; the reference layout app shows framebuffer pixels instead). The
  page edits the existing `CustomScreenLayout` archive (percent <-> normalised
  rectangle, archive version 3; older archives are migrated on read) and applies
  from the next game load. Round 8 adds a **live preview** below the two input
  sections: a centered game-view-like canvas (about 180x390 pt in portrait,
  320x150 pt in landscape) draws the current **TOP** screen in blue and the
  **BOTTOM** screen in purple, with Top/Bottom labels, updating immediately as a
  percentage is typed. Opening or editing a page also selects that direction's
  Custom layout; the optional **Edit by dragging** button opens the full-screen
  drag editor for the same direction. Since round 0.1.6 a custom layout is a
  normal GPU presenter arrangement: the app aspect-fits each screen inside the
  user's rectangle and hands the two normalised viewports to the presenter
  (layout id 8) and its touch map; only a non-upright screen rotation keeps the
  readback fallback. The drag editor keeps a local preview while a finger moves
  (one commit on release, no jitter), separates tap-to-select from drag, has no
  corner resize dot (pinch or the numeric page resize), no grey top banner, and
  forces the app into the direction being edited (landscape editing runs in
  landscape). The one clear **Done** pill is centered on the screen (round 8).
  The layout page has no "how it works" section and no reset button.
- **Shipped default rectangles.** The custom-layout defaults are the placements
  measured from the reference screenshots, in percent of the game view:
  - landscape: upper {0, 0, 35, 47}, lower {4, 46, 27, 45};
  - portrait: upper {0, 0, 74, 21}, lower {7, 22, 59, 21}.
  They were measured on a 20:9 reference screen; the screens keep their own
  aspect inside the rectangles, so on a wider or narrower game view the picture
  is letterboxed inside the rectangle instead of being distorted.
- **Why the custom layouts use the readback path.** Every preset is a presenter
  arrangement; the round-3 presenter patch (0008) adds LargeTopRight, Hybrid and
  TopFullWidth to the upstream fixed arrangements (presenter ABI 5–7). Only the
  arbitrary per-screen Custom layouts cannot be drawn by the presenter: they
  switch the session to the readback presentation path (`zk_create` +
  `zk_read_screen`) the app already uses when MoltenVK is unavailable, and the
  two screen images are placed by `CustomScreenGeometry` (the lower screen's
  touch surface uses the same rectangles). The no-presenter emergency fallback
  still mirrors every arrangement through `ScreenGeometry.layoutViewports`; for
  Hybrid that fallback draws the upper screen twice (large and small-top),
  exactly like the presenter.
- **Compatibility (round-2 split).** The persisted shapes are unchanged:
  `CustomScreenLayout` stays Codable with the same fields (now archive version
  3; older versions migrate on read) and the control profiles stay the versioned
  `UI.controlLayoutPortrait` / `UI.controlLayoutLandscape` data. The round-1
  single screen choice (`UI.screenLayoutMode`) is migrated once:
  - `original` -> landscape Original + portrait Original;
  - `single` / `side` / `hybrid` -> that landscape choice, portrait Default;
  - `large` and the older `standard` / `automatic` / `preset` /
    `customMetal` values -> landscape Large screen, portrait Default;
  - `custom` (and the removed `freeform`) -> Custom layout in both directions;
  - the new keys are `UI.landscapeScreenLayout` and
    `UI.portraitScreenLayout`; the removed "upper only" / "lower only" flags
    heal to both screens shown;
  - the control choice (new `UI.controlLayoutMode`): an install that has 0.1.2
    layout data is treated as Custom so its saved positions keep applying; a
    fresh install starts on Default;
  - round 4 removes the display's aspect-ratio and integer-scaling settings
    (their stored keys stay but are ignored); the render resolution (1×–4×),
    rotation and presenter resize paths are unchanged — the resolution's internal
    3D scale still applies from the next game load;
  - round 4 adds the global in-game control options: `UI.hiddenControlItems`
    (hidden rows) and `UI.controlSizeScales` (per-row 10%-200% scale). Both are
    global, persist and default to all visible / 100%; the control profile
    archives are unchanged.

## Performance settings

| Setting | Values | Behaviour |
|---|---|---|
| Frame cap | 60 / 30 fps | Immediately; the free-run loop never starts presented frames closer than 1/60 s (or 1/30 s). It is a cap, not a target. |
| Fast-forward | 1× / 2× / 4× | Immediately (also from the in-game menu); the next presented frame uses the new value. |
| System Metal HUD | On / off, **default off** | Immediately on the presented `CAMetalLayer`; remembered across launches and also written as `MTL_HUD_ENABLED` / `MetalHUDForceEnabled` for the next Metal device. 0.1.6-beta3 turns it off for every install once (`UI.systemMetalHUDDefaultOffMigrated`); after that the stored switch value wins. |
| Show FPS counter | On / off, **default on** | The in-game FPS readout: a translucent floating pill in the top-trailing safe-area corner in both orientations; also toggled from the pause menu's Virtual controls card (Show performance stats). No other performance text is drawn over the game; the rest stays in the log and diagnostics. |

In 0.1.7-beta2 the rows above live on **Settings → Layout → Performance
monitoring**; the experimental GPU switches are under **Graphics**, AOT
verification is under **Debug**, and **Reset All Settings** clears the app's
UserDefaults domain (Documents data is kept).

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
  (4× → 3× → 2× → 1×) for the rest of the session, so a heavy scene cannot make
  the menu or input unresponsive. The Settings page and the status line show the
  effective speed (`fast-forward: 2× (auto)`), and choosing a speed again
  clears the fallback. The fallback is disabled while unlimited speed is active.
- **Unlimited speed** (0.2.0): with **Run speed limit** off, or with **Turbo
  limit** off while the Turbo button is held, the frame loop runs
  `zk_run_frame` in a loop until one 60 Hz presentation interval is used
  instead of stopping at the 4× clamp. Only the final frame is presented, audio
  is muted (the unlimited mute is separate from the player's Save-audio switch
  and is restored when limited speed returns), and the page warns about heat and
  battery drain. A 4096-frame guard keeps a faulty runtime from spinning.
- The status line shows the effective speed (`fast-forward: 2×`), and the
  exported diagnostics records both the requested and the effective speed.
- Pause, Save State / Load State, Reset, Unload and moving to the background all
  stop the frame loop before touching the runtime, so a fast-forward group can
  never straddle a state change.

## In-game FPS counter

Settings → Layout → Performance monitoring → **FPS counter** (on by default) is the only
performance readout the game view draws. It is a small translucent pill floating
in the top-trailing safe-area corner over the picture in both orientations; the
pause button sits next to it in portrait and at the bottom centre in landscape
(the top corners belong to L/R there). The old portrait title bar and the
landscape top strip are gone.

The counter shows the presented frames per second over the last 0.5 s window
(`59 fps`, or `fps …` until the first frame is measured). The rest of the old
status badge — AOT state, renderer path (`Metal GPU` / `Metal upload` / `CPU
render`), Metal HUD state and the CPU/present/read timing breakdown — is still
recorded and exported, but only in the device log and the diagnostics report.
The optional first-load "Preparing graphics" warm-up was removed in 0.1.1; a
load always reveals the game as soon as it is loaded, and the runtime's pipeline
cache still warms later loads by itself.

## System Metal HUD

The system Metal Performance HUD (FPS, GPU time, memory) attaches to the
`CAMetalLayer` the presented screens draw into. Settings → Layout → Performance
monitoring → System Metal HUD sets `CAMetalLayer.developerHUDProperties["mode"]` to `"default"` or
`"disabled"` at run time (iOS 16 API), and the preference is persisted and
re-applied whenever the layer is reused, so it survives page navigation and ROM
reloads. The app keeps the system HUD's device logging off; the app log and the
diagnostics report carry the frame timings instead.

**Off by default since 0.1.6-beta3.** New installs start with the HUD off, and a
one-time migration turns it off for existing installs as well (marker
`UI.systemMetalHUDDefaultOffMigrated`). The migration runs exactly once; after
that the Settings switch is the stored value and is respected, whether the user
turns the HUD on or off.
`App.init` applies the choice before the first Metal device is created:
`MetalHUD.apply` sets `MTL_HUD_ENABLED=1` in the environment and the documented
`MetalHUDForceEnabled` default, and `MetalScreenView.applySystemMetalHUD` sets
`developerHUDProperties["mode"]` on the layer as soon as the view exists (before
`zk_create_presented`, so the first frame already has it).

The HUD can only appear when all of these hold:

- the build enables it — `MetalHudEnabled` in `Info.plist`
  (`ios/app/project.yml`, re-injected by `scripts/build-ios-app.sh` and
  `scripts/package-ipa.sh`), or the device's Settings → Developer → Graphics HUD
  turns it on;
- the screens go through the presented `CAMetalLayer` — the GPU path, which
  needs `Frameworks/MoltenVK.framework` embedded by the launcher's shell
  template. On the CPU readback path there is no Metal layer to attach to;
- the Metal HUD preference is on (off by default since 0.1.6-beta3).

The Settings row explains the exact reason when the HUD cannot appear (build gate
missing, or the running game is on the CPU readback path); the diagnostics report
records the same state (`system_metal_hud*` fields).

## AOT proof

The old multi-segment badge (AOT / FPS / renderer / Metal HUD) is gone: the
in-game overlay only shows the FPS counter. Every load still writes the AOT
proof to the device log and to the diagnostics
report — never just "assume it is AOT":

```text
AOT: linked_code=1 linked_program=0004000000055E00 recompiled=1 registered_pack=0004000000055E00 pack=Frameworks/GamePack-...dylib status=<runtime text>
```

`zk_linked_code()` / `zk_linked_program_id()` describe the build, `zk_recompiled(handle)`
says what the loaded system actually runs, and `zk_recompiled_status(handle)`
carries the runtime's own fallback/interpretation text. When
`zk_recompiled()` is 0 the runtime handle is destroyed, nothing is presented, and
the home page shows a red "No AOT build for this game" error with that status —
there is no silent interpreter fallback.

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

New keys are appended at the end of both tables in a block for the change that
added them; the English and Chinese tables must keep the same key set and the same
format specifiers, and a key whose UI was removed is deleted from both (there is
no in-app refresh button left to label, for example). `scripts/tests/` keeps a
selfcheck per area; see the test scripts for the exact assertions.

`L10n` resolves the language from `Bundle.preferredLocalizations`; adding a
language means adding `Resources/<language>.lproj/Localizable.strings` (all keys
must keep the same format specifiers). iOS restarts an app when the system
language changes; `LocalizationStore` still watches for a locale change while the
app runs and rebuilds the UI for new formatting. The exported diagnostics
include `app_language=` / `system_language=`, so a device run proves which
table iOS picked.

The device log and the diagnostics report keep their technical keys and values
in English where they are meant for tooling; the UI text around them is
localized.

## Screen layout and pause behaviour

- The frame loop runs on the session's serial runtime queue. Pausing stops it
  (generation-guarded, so a frame already queued becomes a no-op) and stops the
  audio engine; the runtime handle is kept. Resuming starts a new loop and
  restarts the audio engine.
- The picture fills the whole game view; the pause/menu button floats over it
  (next to the FPS pill in the top-trailing corner in portrait, at the bottom
  centre in landscape). The in-game menu keeps the same z-order above the
  picture, the controls and the HUD.
- Paused wall time is excluded from the frame statistics. The in-game menu, a
  save-state operation, the software keyboard, scene transitions and a move to the
  background record when the pause starts and ends; the first frame after a resume rebases the
  start-to-start interval and restarts the 0.5 s FPS window instead of measuring
  the pause. A three-second keyboard pause therefore resumes at a normal frame
  rate instead of logging `fps=0.5` with one multi-second `stutter=` spike, and
  the diagnostics header reports the pause separately as `frame_pause_count=` /
  `frame_pause_ms_total=` / `frame_pause_ms_last=`. The system Metal HUD's own
  first sample after a pause still includes the pause (MoltenVK measures
  present-to-present); that is outside the app's statistics.
- Reset releases the runtime and loads the same ROM again with the same per-ROM
  save data directory; battery saves are kept.
- Exit releases the runtime and returns to the home page. The ROM file and save
  data stay in the app container.
- Losing scene activity without backgrounding (Control Center, the app switcher,
  an incoming call, a system alert) only pauses: the loop and the audio engine
  stop, and returning resumes the same session with its statistics preserved
  and the inactive minutes excluded. 0.1.4 treats a move to the background the
  same way instead of releasing the runtime; see "Background lifecycle (0.1.4)".
- Fast-forward is a property of the frame loop, so pause, save states, reset and
  unload suspend it together with the loop; resuming continues at the setting's
  speed. The in-game menu's speed control applies on resume.
- A title that starts the 3DS software keyboard stops the game the same way: its
  request is published, the frame loop is stopped and the audio engine is shut
  down while the overlay is up. Answering resumes the loop and the engine from
  the frame the title waited in; the overlay's text, limit, buttons and confirming
  rule all come from the applet request, so it works for any title that uses the
  keyboard.

## Background lifecycle (0.1.4)

- A move to the background keeps the session. `scenePhase` drives it:
  `.inactive` pauses the frame loop (Control Center, the app switcher, an incoming
  call, a system alert), `.background` additionally clears input and takes the
  recovery snapshot, and `.active` resumes the same console with the frame
  statistics preserved and the paused minutes excluded. The home page is not
  shown; the runtime handle is not released on the way out.
- The audio engine stops with the loop and starts again on return. The in-game
  menu and the software keyboard keep their own pause: a game backgrounded while
  the menu is open stays paused until the menu's Resume is used (a save-state
  operation that finishes while backgrounded leaves the loop to the return to the
  active scene).
- A load that is still running when the app backgrounds finishes in the
  background; its frame loop starts on the return to the foreground instead of
  running while the process is suspended.
- **Recovery snapshot.** iOS may still jettison a backgrounded process under
  memory pressure. `ROMSession.suspendForBackground()` asks
  `SaveStateSupport.captureBackgroundSnapshot` to serialize the console into
  `Documents/states/<save namespace>/background.bin` and to write
  `Documents/states/background.json` (title id, display name, namespace,
  timestamp, bytes); the write runs inside a UIKit background task. The capture
  is skipped when the process has less than 700 MiB of jetsam headroom, when the
  disk has less than 1 GiB free, while a save-state operation is running, or when
  no game is loaded. After a cold launch the home page shows a "Game paused in
  the background" card: **Resume** starts the game and applies the snapshot once
  the runtime is loaded; **Discard** (or starting the game from its own card)
  removes the snapshot. The files are deleted as soon as the running session
  comes back to the foreground, so a snapshot can never replace newer progress;
  Unload and Reset delete them too.
- **Privacy cover.** While the scene is not active the game view draws an opaque
  "Paused" cover above the menu and the keyboard overlay, so the app switcher
  snapshot and the lock screen do not show the game.
- **Memory warnings.** `applicationDidReceiveMemoryWarning` is logged
  (`[3ds2apple] memory warning: ...`) and counted as `memory_warnings=` in the
  diagnostics. The runtime owns the large allocations, so the shell reports the
  warning rather than freeing memory; the same headroom rule guards the snapshot.

Device verification for this change:

1. Load a game and let it run, then press Home (or switch to another app) and
   wait 10 s; return: the game is still on its picture and keeps running, and the
   home page does not appear. Repeat with a 1-minute stay, with a switch to
   another app, and after locking and unlocking the screen.
2. The device log shows `scene background: paused (frame loop and audio stopped,
   runtime kept)` on the way out and `scene active: frame loop resumed` on the
   way back; the exported diagnostics report `background_suspended=0` after the
   return and a `frame_pause_count=` / `frame_pause_ms_total=` increment for the
   stay.
3. Background the game, swipe the app away in the app switcher (an explicit
   kill), relaunch: the home page offers "Game paused in the background"; Resume
   continues that scene instead of a fresh boot. After a normal return to the
   foreground `Documents/states/background.json` is gone.
4. Open the app switcher while playing: its snapshot shows the "Paused" cover,
   not the game.

## Build

Requires macOS, Xcode, Rust with `aarch64-apple-ios`, and `xcodegen`.
See [scripts/README.md](../../scripts/README.md).

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
are valid UTF-8. The diagnostics' `app_language=` field shows which table iOS
selected.

The app is built unsigned and signed later on the user's machine with Sideloadly
or AltStore.

The presented path additionally needs `MoltenVK.framework` inside the app (it is
loaded at run time, not linked; the binary is never committed). The build and
packaging steps are in [METAL.md](../zakuro-ios/METAL.md) §8, and
`scripts/package-ipa.sh` embeds the framework when `MOLTENVK_FRAMEWORK` points at
the downloaded `MoltenVK.framework` directory; `--require-moltenvk` turns a
missing framework into a packaging error (the launcher shell template build uses
it). The framework is the only piece that makes the CAMetalLayer/presented path
and the Metal HUD possible. Without it the app still builds and runs, on the
readback path — the device log then carries a `PERFORMANCE WARNING` line and the
diagnostics record `display=CGImage readback` / `renderer_software=1`.
```bash
# 1) download the iOS release (build/ is gitignored; the binary is never committed)
curl -L -o build/third_party/MoltenVK-ios.tar \
  https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar
tar -C build/third_party -xf build/third_party/MoltenVK-ios.tar
MVK="$(pwd)/build/third_party/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64"
# 2) build the shell app, then embed MoltenVK while packaging the template IPA
scripts/build-ios-app.sh --keep-project
MOLTENVK_FRAMEWORK="$MVK/MoltenVK.framework" scripts/package-ipa.sh \
  ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple-shell --require-moltenvk
```

## Source layout

| File | Responsibility |
|---|---|
| `App.swift` | SwiftUI entry point; cache directory, logging and the app delegate. |
| `ApplicationDelegate.swift` | UIKit delegate used for the orientation preference. |
| `ContentView.swift` | Root router: home page or game for the current session phase; applies settings to the session. |
| `HomeView.swift` | Home page: the Documents/Games library grid (two columns on iPhone, three on iPad; square 1:1 SMDH cover art that fills the card edge to edge with no icon frame, an attention-state badge in the corner (no AOT badge on a ready game); compact title/publisher/size/last-played text; no explanatory paragraph under the grid), last-played dates, the exact per-game validation error on tap, the launcher empty state, a long-press context menu with the Delete Game action, its second confirmation and result banner, pull-to-refresh, settings entry. |
| `GameView.swift` | Running game: full-bleed picture from the split landscape / portrait screen layout choices, the floating full-screen on-screen controls (per-row visibility and size scale), the optional floating FPS pill and pause button, in-game menu, round-4 in-game control edit mode and the 3DS software-keyboard overlay; also the ROM-free `-previewGameView` path. |
| `GameViewPreview.swift` | Synthetic TOP / BOTTOM test images (gradient, 1 px grid, 400×240 and 320×240) for the ROM-free `-previewGameView` screenshots. |
| `InGameMenuView.swift` | The 0.2.0 in-game menu: iOS-grouped bottom sheet in portrait / centred card in landscape, system semantic colours, MENU header with power / restart / quick-save / quick-load / X icon buttons, tap-outside-to-resume, spring transitions, and the reference emulator's rows — Save state, Virtual controls, Screen layout, Swap screens, Rotate screen clockwise, Global Settings, Per-Application Settings (per-title-ID overrides) and Close game; secondary pages (Save state, Virtual controls, Screen layout, Per-Application Settings) push inside the sheet. |
| `SettingsView.swift` | Settings main page: an iOS inset-grouped List of the eight category rows (SF Symbol + label) in one section and the destructive **Reset All Settings** action in another, with the real reset (confirmation, `removePersistentDomain` for the app bundle and a relaunch prompt), the persisted-setting binding and the in-game quick display sheet. The category pages themselves live in `SettingsPages.swift`. |
| `SettingsPages.swift` | The eight settings category pages and their shared iOS inset-grouped rows/captions (system semantic colours, light/dark follows the system, inline sub-page titles and no extra disclosure chevron). 0.1.7-beta5 layout: General (Check for updates + Update status, Turbo limit, Turbo speed 2×/3×/4×, Default speed 1×/2×/3×/4×), Layout (screen layout entry, rotation, orientation lock, swap screens and the Performance monitoring group), Gamepad, Graphics (resolution, Screen aspect, Integer scaling, the two experimental GPU switches; no Renderer row), System (Appearance + device/app info), Sound, Debug and Other (storage/version/language and the About page, moved from System). |
| `CPUProfilerView.swift` | The debug CPU profiler page: starts guest-PC sampling while a game runs and lists hot spots. Diagnosis only. |
| `SaveManagerView.swift` | Game picker over the library, the selected game's battery save list (export as ZIP, import, delete) and its instant save-state slots (delete offline; save/load while that game runs), with progress and errors; re-reads the selected game's files on open, on library changes and after actions (no refresh button). |
| `AboutView.swift` | Product page: app icon, name, version/build, project links, acknowledgements and legal notice; a compact runtime status card only while a game is loaded. |
| `AppSettings.swift` | Persisted settings model (separate landscape and portrait screen layout enums, screen rotation, interface orientation, appearance, buffer size, frame cap, run speed limit, default/turbo playback speeds, Turbo limit, Check for updates, update channel, Metal HUD and FPS-counter switches, the two next-launch experimental GPU switches, the round-4 hidden-control rows, per-row size scales and the per-title-ID presentation overrides) and the UserDefaults keys, including the round-1 single-choice migration (`migratedScreenLayouts`) and the render scale (1×–4×). |
| `UpdateChecker.swift` | GitHub release checker for the General page and the daily background update notification: /releases request, Stable/Beta channel filtering, semver comparison with CFBundleShortVersionString, a 24-hour background throttle and a local notification via UNUserNotificationCenter (permission requested on first use, one notification per version). |
| `DiagnosticsReport.swift` | Diagnostics report text, the shared diagnostics file type and screen geometry helpers. |
| `StorageInspector.swift` | Container folder sizes, save-data file list, pipeline-cache clearing, and `AtomicFileWriter` for temporary-file-then-rename writes. |
| `SaveStateSupport.swift` | Instant save states: three slots per game, the runtime's size → copy → load protocol on the serial runtime queue, the pause/audio-drop around save and load, and the slot list. |
| `SaveDataStore.swift` | Battery save-data folder, file list, ZIP export, ZIP/file import and delete. |
| `ZipArchive.swift` | Small ZIP writer (stored entries) and reader (stored and deflated entries) used for save-data backups. |
| `SaveArchivePicker.swift` | Files picker for importing a save-data ZIP or individual save files. |
| `ROMSession.swift` | Runtime handle, AOT-only game launch gate, frame loop, presenter lifecycle, input/audio plumbing, software-keyboard polling/answer and the pause it causes, pause/resume/reset and the settings that change runtime behaviour. |
| `MetalScreenView.swift` | `UIView` with a `CAMetalLayer` the presenter draws into (A1); drawable size for the chosen layout/rotation and the render scale (1×–4×), plus the nearest-pixel magnification filter. |
| `ScreenGeometry.swift` | The drawable size of each layout/rotation (including the round-3 presenter layouts 543x240, 578x240 and 400x540), the box the screens occupy, `layoutViewports` mirroring all eight presenter arrangements in the fallback/preview path (hybrid draws the upper screen twice), and the custom-only readback placement. |
| `GameViewGeometry.swift` | The game view's full-bleed box model shared by `GameView` and the layout editors: device/safe-area metrics, picture stage (the whole game view) and control container (the whole screen) rectangles, control frames (with the round-4 per-row size scale), alignment snapping and the preview screen viewports. |
| `GameInfo.swift` | The launcher's `Documents/Games/<TITLEID>/GameInfo.json` manifest (schema 1): authoritative display title, localized `displayNames`/`publisher`/`region` (optional SMDH base info), save namespace and pushed game-data size/SHA-256; the pack fields are informational metadata about the pack embedded in the IPA. |
| `InstalledGame.swift` | Scans `Documents/Games` for pushed game data, validates it (folder/title ID, manifest, ROM presence/size/path containment), resolves the pushed `cover.png` and verifies the recorded SHA-256 in the background. |
| `GameCatalog.swift` | The bundle `GameCatalog.json` schema (v2, v1 compatible): the build's game list plus per-game `packFile`/ABI/`registrationSymbol`. A base shell may ship an empty catalog. |
| `GameLibrary.swift` | The library: bundle catalog joined with the pushed `Documents/Games` data, per-card title/publisher/size/cover (catalog fallback + placeholder), per-card states (Checking / Data missing / Error) and AOT availability, background SHA-256 checks, `Documents/Library/playHistory.json` and `Documents/Library/removedGames.json` (games deleted on this device, hidden until the launcher pushes the data again); `deleteGame` removes a game's data, saves, save states and per-game state. No ROM importing. |
| `AOTPackageLoader.swift` | Resolves/loads the per-game `GamePack.dylib` from the signed app bundle, validates title/ABI/registration symbols before use, hands the launch the pushed (or legacy bundled) ROM, documents the C ABI, and falls back to the statically linked single-game build. |
| `DebugLaunch.swift` | Headless launch hooks: `-openAOTTitleID` (start a library game), `-gamesRoot` (scan a Simulator fixture folder instead of Documents/Games), `-openLayoutPage` / `-openLayoutPicker landscape\|portrait` / `-openCustomLayoutPage landscape\|portrait` / `-openLayoutEditor screen\|control` (layout screenshots; the `-landscape` variants force that direction), `-previewGameView` / `-previewScreenLayout <layout>` / `-previewLandscape` (ROM-free game-view screenshots, the layout choice picked by direction), and `-previewPauseMenu` / `-previewControlEdit` / `-openControlOptions visibility\|size\|opacity` (round-4 control option screenshots). |
| `LegacyGameData.swift` | One-time migration for apps updated from 0.1.x: cartridge lookup for the statically linked title, play times, and renaming ROM-named save folders to the title-id namespace. |
| `ScreenImage.swift` | Reusable RGBA buffers and `CGImage` conversion. |
| `InputState.swift` | Thread-safe merge of touch, overlay and controller input. |
| `KeyboardRequest.swift` | One 3DS software-keyboard request: the schema-1 JSON decode, the applet's confirmation rules (`Request::accepts`), UTF-16 limit handling and the localized rejection lines. |
| `KeyboardOverlayView.swift` | The full-screen overlay that answers a software-keyboard request: hint, pre-filled text field, character counter, applet buttons and validation; portrait and landscape, above the system keyboard. |
| `ControlLayout.swift` | Editable control layout model: the full New 3DS control set, normalised placements (position, size, opacity), per-orientation profiles and their versioned Codable persistence. The shipped defaults are converted from the ModernCenteredX2 reference skin (numeric frames only; round 6 puts the portrait shoulder row and main set in the band below the picture, round 7 renders the D-pad as one cross) and an untouched beta3/older shipped default is migrated on load. |
| `VirtualControlsView.swift` | Runtime overlay: draws one button / analog stick per control with its own gesture (multi-touch), plus the single cross-shaped D-pad (`DpadCrossShape`) whose touch position selects the direction; reports ZK_BUTTON_* bits, Circle Pad and C-stick vectors; skips the rows hidden in the pause menu and applies the per-row size scale. |
| `ControlLayoutEditorView.swift` | Legacy full-screen control layout editor kept for the `-openLayoutEditor control` screenshot hook; the app no longer links it (round-4 editing happens in-game). It draws/moves the D-pad as one cross and edits its group size/opacity/reset. |
| `ControlLayoutSettingsView.swift` | Legacy control layout page (not linked from Settings since round 4); kept for compatibility of the old screenshot hook. |
| `InGameControlEditOverlay.swift` | Round-4 in-game control editing: draggable controls over the frozen paused picture (gestures attach before `.position`, so each control's hit area is its own shape), the D-pad as one draggable cross, per-row visibility/size, a Done pill centered on the screen that saves the current direction and resumes the game. |
| `ControlOptionsViews.swift` | The pause menu's virtual-control option sheets: Toggle controls (per-row checkboxes), Adjust size (10%-200% slider per row) and Adjust opacity (the global overlay opacity). |
| `CustomScreenLayout.swift` | Custom screen layout model (archive v3 with the ratio-lock flag; older archives migrate to the round-2 measured defaults) plus `CustomScreenGeometry`: per-orientation screen rectangles, rotation, integer scaling. |
| `ScreenLayoutEditorView.swift` | Full-screen custom screen layout drag editor (one direction per editor, opened from the numeric custom page's "Edit by dragging"): full-screen game-view canvas with the current control layout overlaid for reference, direct screen drag, a ≥44 pt corner handle or pinch to resize, edge snapping and one clear Done pill centered on the screen (round-8; hint above it, no bottom toolbar). |
| `CustomScreenLayoutValuesView.swift` | The numeric custom screen layout page of one direction: Upper screen / Lower screen sections with X position, Y position, Width and Height as integer percentages of the game view, a live centered preview canvas (blue TOP / purple BOTTOM) under them, editing the CustomScreenLayout archive; also the "Edit by dragging" entry. |
| `ScreenLayoutSettingsView.swift` | The screen layout page under Settings → Layout: the landscape six-choice row, the portrait three-choice row (each opening a radio picker sheet), the two custom layout rows and no reset / "how it works" section. |
| `GameControllerInput.swift` | GameController-to-3DS button mapping. |
| `AudioOutput.swift` | Ring buffer and AVAudioEngine output (volume, mute, buffer duration). |
| `FrameTiming.swift` | Per-phase frame timing for the diagnostics report and the fast-forward auto-fallback. |
| `GraphicsWarmUp.swift` | Pipeline-cache filesystem stats used by Storage and the diagnostics report. The first-load warm-up types in this file are no longer reachable: the option was removed in 0.1.1. |
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
- Every preset is a presenter arrangement (ABI 1–7: stacked, side by side,
  upper only, lower only, large top, large top right, hybrid, top full width).
  Only the two Custom layouts skip the presenter and use the readback path above
  (`CustomScreenGeometry`); switching paths applies from the next game load.
  The no-presenter fallback mirrors all arrangements in
  `ScreenGeometry.layoutViewports` (hybrid draws the upper screen twice).
- The fallback triggers automatically when `zk_presenter_create` returns `NULL`
  (for example no MoltenVK in the app, or a device that cannot make a Vulkan
  device), when `zk_create_presented` fails (the load is retried once with
  `zk_create`), or after about a second of `zk_present` failures. A presented
  load whose renderer stays in software still uses the Metal layer: the
  presenter uploads the CPU pixels, so the app still never builds a `CGImage`.
- The Metal view and presenter are created on the main queue and kept for the
  app's lifetime, so a later load reuses the same layer and Vulkan device. The
  frame loop stops presenting when the runtime stops (Unload, exit/fault) or the
  app is in the background (0.1.4: the loop stops, the runtime, presenter and
  Vulkan device are kept and used again on return); the presenter is released with the app. A display change (layout,
  rotation, render scale) resizes the layer's drawable and the presenter's
  swapchain on the runtime queue, so the next frame uses it; that costs one
  out-of-date present. For the render scale that only resizes the drawable: the
  internal 3D render scale itself is set with `zk_set_render_scale` and read when
  a system loads, so an already loaded game keeps its internal scale until it is
  reloaded or restarted.
- Because there is a real Metal layer, the system Metal Performance HUD can
  attach to it: Settings → Layout → Performance monitoring → System Metal HUD sets
  `developerHUDProperties` on the layer (`mode: "default"` / `"disabled"`) at run
  time; it is on by default and the build's `MetalHudEnabled` (or the device's
  Developer settings) also has to enable it. On the readback path there is no
  layer, so the HUD does not appear. The readback fallback is also logged as a
  performance warning, because it means the 3D is drawing in software.
- The presenter needs `Frameworks/MoltenVK.framework` in the app bundle (loaded
  at run time, never linked into the static library). The launcher's 0.1.0+ shell
  template embeds it; a plain build without it still runs, but on the CPU
  readback path.

## Input

- The on-screen controls and a connected hardware controller are merged by
  `InputState`; the session reads one snapshot on the runtime queue immediately
  before `zk_run_frame` and calls `zk_set_cstick` then `zk_set_input` there. The
  overlay is editable (see "Editable layouts") and floats over the whole screen
  in both orientations.
- Controller mapping: D-pad → D-pad, A/B/X/Y → A/B/X/Y, L1/R1 → L/R, L2/R2 →
  ZL/ZR, Menu → Start, Options → Select, left stick → Circle Pad, right stick →
  C-stick.
- The C-stick has no parameter in `zk_set_input` (that signature is older than
  the New 3DS). `zk_set_cstick(system, x, y)` in `ios/zakuro-ios/src/lib.rs`
  stores the vector in a thread-local slot and the next `zk_set_input` on the
  same thread merges it; the value starts at (0, 0) and is clamped to -1…1, so an
  app that never calls it keeps a centred C-stick. The call is additive: the
  existing ABI and every existing caller are unchanged.
- Dragging on the lower screen sends touchscreen coordinates in lower-screen
  pixels; on the presented layer the runtime finds the lower screen from the
  current layout and rotation, so only that part of the layer is a touch
  surface. A touch on the upper screen is ignored.
- Input is cleared on pause, unload, background and reset, so a held button
  cannot survive a state change.

## Software keyboard (3DS text input)

A 3DS title that needs a name, a message or a password starts the console's
software-keyboard library applet and waits for the answer; without an answer the
game looks frozen on its last frame. The app answers it:

- **Detection.** After every completed `zk_run_frame`, the session asks
  `zk_keyboard_pending()` — a cheap flag check. When it turns 1, the session reads
  the request with `zk_keyboard_request_json()` (schema 1: hint, initial text,
  `maxLength` in UTF-16 units, button labels left to right, and the confirming
  button's rule), publishes it to the main queue and **stops the frame loop**. The
  title is waiting on the applet, so further frames would only burn CPU and audio
  (the desktop frontend stops emulating while it types for the same reason);
  input is cleared and the audio engine is stopped like the in-game menu does.
  The wait is recorded as a pause, so the resumed `perf:`/diagnostics numbers
  exclude it instead of counting it as one huge stutter.
- **Overlay.** `GameView` shows `KeyboardOverlayView` over the paused picture: a
  full-screen dim layer (the on-screen controls and the pause button cannot be
  reached while the applet is open) with a glass card that shows the applet's hint,
  a `TextField` pre-filled with the initial text, an `n/maxLength` UTF-16 counter,
  the applet's buttons left to right, and — while the confirming rule rejects the
  text — a localized line saying why the last button is disabled. The card scrolls
  above the system keyboard, so portrait and landscape both work; the keyboard
  comes up automatically. On China-region iPhones the first focus can make iOS
  show a one-time wireless-data permission alert; see the known-issue section
  below.
- **Validation.** The confirming button is enabled only when the text passes the
  applet's rule, mirrored exactly (`Request::accepts` in Zakuro's keyboard
  service): `anything`, `notEmpty`, `notEmptyNotBlank`, `notBlank`,
  `fixedLength` (exactly `maxLength` UTF-16 units). The other buttons — typically
  Cancel — are always enabled and close the applet with their index. A rule from a
  newer runtime is treated as `anything` so the player cannot get stuck; a
  one-button request whose rule rejects the text has nothing to cancel with, like
  the console.
- **Length.** The field enforces `maxLength` in UTF-16 units (an emoji counts as
  two and is kept or dropped whole); the runtime truncates the answer to the same
  limit and to the shared block the title reads it from, so an overlong answer
  cannot corrupt the console.
- **Answer and resume.** A button calls
  `ROMSession.answerKeyboard(text:button:)`. The applet call
  (`zk_answer_keyboard`) runs on the runtime serial queue; the session then
  resumes the loop from the frame the title waited in and restarts the audio
  engine. The overlay disappears immediately; a refused answer (for example the
  title closed the applet itself) is logged and the game continues.
- **Edges.** Backgrounding, unload and reset release the runtime and clear the
  overlay with it; a request is published once, not on every polled frame; an
  unreadable JSON document is closed with the leftmost button instead of freezing
  the title; the typed text is never written to the log, only its length.

## Known issue: China-region iOS asks to allow wireless data on the first text input

On a China-region (国行) iPhone, the first time the app puts a system text input
on screen — the 3DS software-keyboard overlay's text field becoming first
responder is the only place this app does it — iOS may show the one-time
「允许 3ds2apple 使用无线数据？」 alert (关闭 / 无线局域网 / 无线局域网与蜂窝数据).
This is a known iOS system bug, not a request from the app:

- **The app has no networking code.** No `URLSession`, no `Network.framework`, no
  `CFNetwork`; the built binary has no `socket`/`connect`/`getaddrinfo`/`nw_*`
  symbols, no `NSLocalNetworkUsageDescription`/`NSBonjourServices` and no network
  entitlements. iOS Settings reports 0 cellular data for the app. (Zakuro's only
  TCP code is its desktop netplay room; the iOS build never starts it.)
- **The alert comes from UIKit's own text-input setup.** On China-region devices,
  making the text field the first responder starts
  `com.apple.assistant.dictation` and a `nw_path_evaluator_start` from
  SystemConfiguration; CommCenter attributes that path check to the app's PID and
  shows the first-network-use prompt. The device log has no `nw_connection`, no
  URL and no traffic.
- **It is a reported system issue.** Apple Developer Forums thread 822198 lists it
  as a known issue, and other developers reproduce it on iOS 26.5/27 with an empty
  project containing a single `UITextField` (<https://www.v2ex.com/t/1230881>).
  The only complete workaround is to leave the system text-input path entirely
  (a self-drawn keyboard), which this product does not do because it would lose
  the system IME.

**What to do:** choose **不允许** (Don't Allow) or **仅限无线局域网** (WLAN only) — the
game, the 3DS keyboard overlay and every other feature keep working, because the
app never uses the network. iOS may show the prompt again after reinstalling the
app; it is a per-installation system permission, not an app setting.

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
| Background recovery snapshot | `Documents/states/<save namespace>/background.bin`, named by `Documents/states/background.json` | Written when the app moves to the background (0.1.4) and deleted when the session returns to the foreground or is unloaded; after a cold launch the home page offers Resume. |
| Deleted-game record | `Documents/Library/removedGames.json` | The Home page's delete action writes it; pushing the game's data again with the launcher clears it. |

The save namespace is the title ID by default; a launcher may set `saveNamespace`
in `GameInfo.json` (for example to share saves between two regional builds). The
folder is sanitized, so two games can never share a save-data directory unless
the launcher deliberately gives them the same namespace.

Battery saves:

- The page opens with a game picker listing every game in the library (including
  pushed games that were never started). It remembers the last game picked and,
  opened from the in-game menu, starts on the running game; "No game" empties the
  page and Restore default selects the running game or the first one. Battery
  saves can be managed while the game is not running.
- The page re-reads the selected game's files when it opens, whenever the library
  changes (a game deleted on the Home page disappears from the picker) and after
  every action. There is no refresh button: the app also rescans
  `Documents/Games` when it returns to the foreground.
- The Save Manager lists every file under the selected game's data directory with
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
- The in-game menu's quick buttons use slot 1. The Save Manager page lists the
  selected game's three slots with size and date and offers Save / Load / Delete
  for each: Delete works without the game running, while Save and Load need that
  exact game running because the runtime serializes its live console.
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

- The 3D can be drawn on the GPU through MoltenVK (the launcher's shell template
  embeds it); otherwise it is Zakuro's software PICA200 renderer. A device build
  that feels slow is almost always missing the framework: the log then says
  `PERFORMANCE WARNING ... draws in software`, and the diagnostics show
  `CPU render` (`renderer_software=1`). The presented path is experimental and a presenter is reused for
  the whole app run.
- 3D stereo, frame interpolation and texture packs exist in the presenter but
  are not exposed by the app UI.
- The readback fallback (no MoltenVK / no Vulkan device) still shows every
  layout and rotation, but it copies both screens to the CPU each frame and is
  slower than the presented path; its stretch mode divides the space between the
  two screens rather than reproducing the presenter's exact sub-screen split.
- The 3DS software keyboard is answered by the app's own overlay: the hint,
  initial text, limit, buttons and confirming rule come from the game, but the
  console's keyboard graphics are not emulated and the title is paused while the
  overlay is open. A one-button request whose rule rejects the text has no cancel
  button, like the console.
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
- Button remapping is not available in this build (positions/size/opacity are
  editable; which key a control reports is fixed). Save states are not
  interchangeable between games or runtime versions, and only battery saves are
  exported and imported; instant states stay in the app container.
- Custom layouts now use the GPU presenter too (layout id 8 with two arbitrary
  normalised viewports, round 0.1.6): the app aspect-fits each screen inside the
  user rectangle. 0.1.6-beta2 also sends the screen-rotation value
  (zk_presenter_set_custom_rotation) so all four custom rotations render on the
  GPU, and zk_presenter_set_screen_swap applies the Swap screens button to any
  layout immediately. Since 0.1.6-beta4 the Swift touch maps also send the
  swap flag (and the rotation for custom layouts) to the presenter touch
  helpers, so touches land on the screen that is actually shown after a swap.
  Only a device where no presenter can be made keeps the older readback
  fallback. The presenter side needs the
  round-0.1.6 library/patch 0009; an older library falls back to readback.
  The custom rectangles still apply from the next game load.
- The shipped default controls come from the ModernCenteredX2 reference skin,
  with the round-6 device-feedback adjustments: the portrait shoulder row sits
  on one line at y=0.755 just below the picture and the main set at y=0.87, so
  every control is in the free band; the D-pad is one cross-shaped control (the
  four directions stay separate elements for input, visibility and size). The skin is read only for numbers; its artwork is not used. The
  reference layout app's behaviour rows (slide buttons, relative stick centre,
  D-pad slide, Combo Button) are future work; the available options are
  visibility, size scale, opacity and reset.
- Hidden controls are not drawn in the in-game editor either: re-enable a row in
  **Toggle controls** before moving it. The per-row size scale is global (one
  value for both orientations), matching the visibility choice.
- The two Custom layouts ignore the display-format box (they place each screen by
  a fraction of the whole game view); screen rotation and each screen's native
  shape still apply.
- The round-2 custom-layout defaults were measured on a 20:9 reference screen:
  the rectangles are normalised to the game view and the screens keep their own
  aspect inside them, so a different screen shape can show letterboxing inside a
  custom rectangle (the numeric page makes the value easy to adjust).
- The C-stick needs a shell built with the current `libzakuro_ios.a`: the symbol
  `zk_set_cstick` is new (added additively). Building from source
  (`scripts/build-zakuro-ios.sh`) produces it; a shell built from an older
  library would fail to link rather than silently drop the C-stick.
- A pipeline first used during play compiles on a worker thread and draws
  through the generic fallback meanwhile, so a title can hitch briefly on first
  use. The optional first-load "Preparing graphics" warm-up was removed in
  0.1.1. Completing shader AOT is out of scope: it cannot cover every runtime
  shader/pipeline combination, and a first run has no cache to load.
- Fast-forward mutes the game audio while it is active, and the automatic
  fallback gives up extra frames when a scene is too slow (see
  "Fast-forward"). It cannot make a game that already runs below 20 fps
  faster.
- The system Metal HUD is off by default since 0.1.6-beta3, and it only works
  when the build enables it (`MetalHudEnabled`), and only on the presented
  `CAMetalLayer` path (so not on a software/readback load). The Settings page
  shows the reason when the switch cannot work, and the diagnostics report
  records it.
- Only English and Simplified Chinese are included. Traditional Chinese and
  other languages use English.
- iOS 16+ only; the app is not distributed through the App Store.

## Diagnostics

The game view draws only the FPS counter (`59 fps`); the AOT source, the renderer
and the Metal HUD state are no longer shown over the game. They remain in the
in-game menu and the diagnostics report, which also keep the fuller status line,
including `fast-forward: 2×` and `(auto)` markers that appear only above 1×. The
device log carries one line per load
(`zk_presenter_create`, `display:`, `hardware:`), an `AOT:` line per load with
`linked_code` / `linked_program` / `recompiled` / `registered_pack` / `pack` /
`status` (an `AOT REFUSED:` line plus a red home-page error when the gate stops
the game), one `metal backend:` line at launch (whether MoltenVK is embedded),
a `PERFORMANCE WARNING` line when the 3D falls back to software rendering, and
the pipeline-cache state at
launch/load/after `zk_destroy`, one line recording that the warm-up option is
gone, a `frame cap:` / `render scale:` line when those settings change (the
render-scale line notes that the internal 3D scale applies on the next load),
one line per pause/resume/reset, one `frame timing: excluded a <n> s pause ...`
line per resume that followed a pause, one `save state:` line per save/load/delete,
one `library:` line per scan (entry counts per source) with a `library entry:`
line and the per-game validation messages for every game, the
`-gamesRoot`/`-openAOTTitleID` arguments and the preview hooks
(`-previewGameView`, `-previewScreenLayout`, `-previewLandscape`) when used,
one `save data:` line per export/import/delete, and a `perf:` line every ~2 s
with the per-phase timings.

The exported diagnostics header adds the build, device, session phase
(`paused=`), the runtime state, the active settings (`frame_cap=`,
`screen_layout=` (the current direction's presenter arrangement, or
`readback-<choice>`), `landscape_layout=`, `portrait_layout=`,
`screen_layout_readback=`, `virtual_controls_hidden=`,
`control_size_scales=`, `screen_aspect=` (stored/ignored),
`integer_scale=` (stored/ignored), `render_scale=`,
`render_scale_applies=`, `orientation=`, `audio_volume=`, `audio_muted=`,
`audio_buffer_ms=`, `touch_controls=`, `controls_opacity=`, `haptics=`,
`playback_speed=`, `playback_speed_effective=`,
`playback_speed_auto_reduced=`, `fps_counter=`, `system_metal_hud=`,
`screen_rotation=`, `presented_native_pixels=`, `presented_drawable_pixels=`,
`system_metal_hud_build_enabled=`, `aot_diagnostics=`, `aot_linked_code=`,
`aot_recompiled=`, `aot_recompiled_status=`, `aot_pack=`,
`metal_moltenvk_embedded=`, `metal_hud_enabled=`, `renderer_software=`,
`app_language=`, `system_language=`), `warmup_enabled=0` with the
`warmup_note=removed-in-0.1.1` marker (the first-load warm-up is gone; pipeline
cache persistence is unchanged) and the `pipeline_cache*` fields: the export now
reads the cache directory at export time with the same
`PipelineCacheStats.read()` the app log uses, so `pipeline_cache_dir=` is the
real `Library/Caches/zakuro/pipelines` path and `pipeline_cache=` its real file
count/size even when the report is exported from the home screen before any game
loaded. `pipeline_cache_dir_state=` is `ok`, `missing (not created yet)` (a cold
first run) or `unreadable: <reason>` (permissions/I/O) instead of a bare
`unknown`; `pipeline_cache_at_load=` keeps the state the session's load began
with and reads `unknown (no load in this session)` when nothing was loaded. The
pause block `frame_pause_count=` / `frame_pause_ms_total=` /
`frame_pause_ms_last=` / `frame_pause_definition=` records the paused wall time
the frame statistics excluded. 0.1.2 adds the hitch-attribution fields:
`timing_ms_run_gpu=`, `timing_ms_run_cpu=`, `timing_ms_interval=`,
`timing_share_run_gpu_pct=`, `timing_share_run_cpu_pct=`,
`pipeline_cache_at_load=` / `_files=` / `_bytes=`, plus the `stutter_*`
additions documented under "Performance data capture" below. The previous and
current session logs follow. These values make renderer, presentation,
scheduler, settings, fast-forward, language and warm-up changes measurable on
device.

### GPU execution timing and A/B builds (0.1.3)

`timing_ms_run_gpu=` is the host time the renderer's command walk took, not the
GPU's execution time. Diagnostic builds additionally measure the GPU itself with
Vulkan timestamp queries and export:

- `gpu_timing_enabled=` — 1 when the GPU's own times are measured, 0 on a
  normal build (the diagnostic switch is off).
- `gpu_exec_ms_per_frame=` — the GPU's real execution time per frame, averaged
  over the last 60-frame `zk_perf` window: the number the system Metal HUD shows
  as GPU time. Use this field for before/after comparisons.
- `gpu_times_line=` — the window's breakdown: time per kind of GPU work
  (`draw`, `upload`, `clear`, `transfer`, `capture`, `copy`, `download`,
  `barrier`, `upright`, `readback`), render passes, barriers, draws, the host's
  waits for the GPU and the shaded vertices/primitives/fragments per frame. It
  also lists the render targets by GPU time
  (`target 0xADDR WxH[+d] X.XXms/f (N passes, M draws)`),
  so the largest render pass can be named. The per-pass report (`zk_passes:`)
  has the dominant target's passes in recording order with each one's GPU
  milliseconds, draws, depth/twin and what ended the pass before it (a depth
  switch, a texture upload, a transfer, a capture, ...), plus the window's
  `pass_breaks` and the kinds of work the batches started (`ops ...`). When
  the opaque sort is on the line carries `sorted N/f of M/f draws in R/f runs`
  and the reason each draw was held or not (`no-depth`, `blend`,
  `gpu-vertices`, ...), and `merge`'s `merged N draws/f` or `capture`'s
  `captures_skipped N/f`. The fourth round also splits the draw time by draw
  state (`draw_classes blend/alpha/tex/write/coverage X.XXms/f N/f Y.YYMpx/f`,
  the most expensive class first) and counts the math-equivalent skips
  (`safe_skips N/f D.DDMpx/f`). A candidate that lowers `gpu_exec` while the
  shaded fragment count stays the same changed GPU scheduling or bandwidth, not
  the emulated shading.
- `gpu_profile=` / `gpu_profile_definition=` — the diagnostic GPU profile the IPA
  was built with (`baseline`, `baseline2`, `baseline3`, `baseline4`, `baseline5`,
  `baseline6`, `mvk`, `renderer`, `sort`, `sort2`, `merge`, `capture`, `noblend`,
  `flat`, `2x3x`, `safe`, `texonly`, `fragspec`, `fastmath`, `mvkrenderer`,
  `combo`) and what it applies.
  `baseline3` is the third-round control (per-pass report, pass breaks, work
  counts), `sort2` adds the relaxed opaque front-to-back draw sort
  (`ZAKURO_SORT_OPAQUE=1`), `merge` adds render-pass merging
  (`ZAKURO_MERGE_PASSES=1`) and `capture` adds duplicate-capture skipping
  (`ZAKURO_DEDUPE_CAPTURE=1`); all must leave the picture unchanged.
  `baseline4` is the fourth-round control (draw-state GPU time buckets with
  estimated pixels and the safe-skip count). `noblend`
  (`ZAKURO_MEASURE_NOBLEND=1`) and `flat` (`ZAKURO_MEASURE_FLAT=1`) are
  measurement profiles whose picture is deliberately wrong: what the blend and
  the fragment work cost. `2x3x` (`THREEDS2APPLE_DIAG_RENDER_SCALE=2`) draws
  the internal 3D at 2x while the drawable stays at the setting's 3x, which
  measures the 3x target's fill cost (the presented picture is the upscaled 2x
  one). `safe` (`ZAKURO_SAFE_SKIPS=1`) skips draws that cannot change either
  buffer and must leave the picture exactly as it is.
  `baseline5` is the fifth-round control: the same timing plus the fragment
  state per draw in the GPU line (`frag_lights`: the draws per frame with the
  fragment lighting off, then with 1 to 8 lights; `fog`: the draws with the
  fog on), so a run says whether the fragment-work A/Bs can help the scene.
  `texonly` (`ZAKURO_MEASURE_TEXONLY=1`) samples the textures and little
  else (measurement only, the picture is wrong; `baseline5 - texonly` is the
  fragment ALU's cost). `fragspec` (`ZAKURO_FRAG_SPECIALIZE=1`) has
  the lighting, fog and unit wrapping compiled in as constants, and `fastmath`
  (`ZAKURO_FRAG_FAST_MATH=1`) drops `precise`; both must leave the
  picture unchanged and say `frag_build ... N/f` when they engage, and the GPU
  line reports four build counters (fast-math, texonly, specialized, specfast).
  `baseline6` is the sixth round's control (the same timing as `baseline5` with
  the fragment builds off). `combo` sets both switches at once; the renderer
  then runs a combined build of `raster.frag` (the specialization constants
  without `precise`, counted as `frag_build specfast N/f`). The release default
  from 0.1.3 is `fastmath` only (`ZAKURO_FRAG_FAST_MATH=1`, applied by
  `MoltenVKTuning.releaseRendererDefaults` when no diagnostic profile is set;
  `THREEDS2APPLE_RENDERER_OPTIONS=ZAKURO_FRAG_FAST_MATH=0` disables it): the
  combined build measured within noise of fast-math alone, and the specialized
  build needs one more pipeline shape per lighting/fog/wrapping state.
  `mvkrenderer` is the old `mvk` + `renderer` combination, kept so the first
  round's confirmation run can still be reproduced.

`scripts/build-gpu-diagnostic-ipa.sh` (on the macOS build VM) packages one IPA
per profile, differing only in that Info.plist key; the app applies the profile's
allow-listed MoltenVK parameters and renderer switches in `App.init`, before the
first Vulkan device. Install one profile at a time (they share the bundle id),
run the same scene at 3x for the same duration per profile, and send the
diagnostics exports: the fields above plus the frame interval and a Metal HUD
screenshot are what the optimization decision is made from. The app logs the
profile and what it applied (`gpu_profile=`, `renderer_env=`, `moltenvk_env=`).
See `scripts/README.md` for the profile table and the procedure, and
`ios/zakuro-ios/README.md` for the switches themselves.

## Performance data capture

The shell records rolling stutter statistics while a game runs, so a hitch on a
device can be reported without a debugger, a Mac or a cable. A stutter is one
presented frame that the measured work item or a scheduling gap held for more
than 33.3 ms (two 60 Hz slots); a frame over 100 ms is severe. The counters are
session-wide; the report keeps the 20 most recent spikes with their relative
time, start-to-start interval, held-up duration, work item, command-walk share,
phase and presented frame number.

Paused wall time is not a stutter: the counters, the per-minute rate and the
worst frame exclude the in-game menu, save-state, software-keyboard and scene
transitions (reported separately as `frame_pause_*`). The start-to-start
interval of the first frame after a resume is rebased, so a multi-second
keyboard pause no longer shows up as one `stutter=` spike or a `fps=` dip.

### Hitch attribution (0.1.2)

The phase attribution changed in 0.1.2 so the numbers answer "what costs the
frame?" instead of "what was the interval?":

- `run-gpu` is the software GPU's command-list walk inside `zk_run_frame` (the
  `gpu` column of the periodic `zk_perf` line). A pipeline a scene first uses is
  created during the walk and stalls the frame that waits for it, so a large
  `run-gpu` spike is the pipeline-compile suspect.
- `run-cpu` is the rest of `zk_run_frame`: emulated CPU and HLE services. A
  scene whose `timing_ms_run_cpu` average is the largest column is CPU-bound;
  raising the render scale or changing the CAMetalLayer cannot fix that.
- `present` is `zk_present` (on the Metal path mostly the FIFO wait for the
  display when the frame finished early; a long `present` maximum is a
  swapchain/GPU stall, not a vsync wait).
- `other` is now only the gap between the previous frame's end and this frame's
  start (a frame block the scheduler ran late), not "start-to-start interval
  minus this frame's work". The old definition blamed the frame *after* a long
  frame for the long frame's work, so one hitch was reported twice (once as
  `run`, once as `other`) and `stutter_count=`/`stutter_per_min=` were roughly
  double the physical number. A 0.1.2 report legitimately shows about half the
  stutter count of a 0.1.1 report for the same run; that is the dedup, not a
  performance regression.
- `stutter_gpu_walk_bound_frames=` counts frames whose command walk alone
  overran the 60 Hz budget; `stutter_pipeline_compile_suspects=` counts severe
  stutters attributed to `run-gpu` (the first-use compile signature).

The header also splits the work item in the timing block (`timing_ms_run_gpu=`,
`timing_ms_run_cpu=`, `timing_share_run_gpu_pct=`, `timing_share_run_cpu_pct=`)
and adds `timing_ms_interval=` (start to start). `pipeline_cache_at_load=` /
`_files=` / `_bytes=` record the cache state the load began with, which is the
A/B baseline for compile hitches.

`stutter_event=` lines now carry `interval=` (start to start), `ms=` (how long
the player was held up), `work=` (measured work item) and `gpu=` (command walk
inside it), so a cold-cache compile (`gpu` close to `ms`) is distinguishable
from a CPU hitch (`work` large, `gpu` small). The 0.1.1 phase name `run` is gone
from the export: anything that parsed the old `stutter_phase_share=` string needs
the new `run-gpu` / `run-cpu` labels.

#### What the 2026-11-17 device log of a retail title showed

- The severe hitches (562-930 ms on a cold cache, 100-180 ms on a warm one)
  land on the windows where `draws` jumps and `zk_perf`'s `gpu` column covers
  almost all of the frame time: first-use pipeline creation in the command walk,
  inside `zk_run_frame` - not `present`, and not the pipeline-cache write (that
  runs on the upstream compiler thread and is one 290 KB file per save).
- The title's main-menu low-frame stretch (45-55 fps, `run` average 18-22 ms) had
  `gpu` 4.5-5.7 ms and `cpu` 74-91% of real time in the same windows: it is
  CPU-bound emulation, not the 3x render scale, present/vsync or the drawable.
  The layer was already triple-buffered ("Created 3 swapchain images") and
  nothing wrote CAMetalLayer properties per frame, so layer tuning cannot reach
  60 fps there.
- A cold pipeline cache makes a first session's scene compiles visible; the same
  scene on a warm cache compiles much less. The cache is flushed by `zk_destroy`
  (a clean Unload or exit). 0.1.4 no longer destroys the runtime when the app is
  backgrounded, and the runtime still saves the cache every 5 s while it runs, so
  a process the system jettisons in the background keeps the compiles from the
  last few seconds; a force-quit while playing still loses the compiles since the
  last save.

#### A/B a change on device

1. Reinstall (or delete the app's Caches), load the game and let the first
   scene compile: record `pipeline_cache_at_load=`,
   `timing_ms_run_gpu=` maximum, `stutter_pipeline_compile_suspects=` and the
   worst `stutter_event=`.
2. Play, Unload the game and check the log for
   `pipeline cache after zk_destroy:`; load again. `pipeline_cache_at_load=`
   must show the cache and the compile numbers must drop. A second session that
   still compiles is a cache-persistence bug, not a renderer problem.
3. For a CPU-bound scene (`timing_ms_run_cpu=` dominates) change one variable
   per capture (render scale, frame cap) or use the `THREEDS2APPLE_MVK_CONFIG`
   A/B in `scripts/README.md` §5.3; for a `run-gpu` spike compare cold vs warm
   cache only.

The diagnostics header carries the block `stutter_definition=`,
`stutter_count=`, `stutter_per_min=`, `stutter_severe_count=`,
`stutter_worst_ms=`, `stutter_top_phase=`, `stutter_gpu_walk_bound_frames=`,
`stutter_pipeline_compile_suspects=`, `stutter_phase_share=`,
`stutter_events=`, the pause block `frame_pause_count=` /
`frame_pause_ms_total=` / `frame_pause_ms_last=` / `frame_pause_definition=` and
the background block `background_suspended=` / `background_snapshot=` /
`memory_warnings=` / `background_definition=`, followed by one `stutter_event=`
line per spike. The frame
path only does a few tick comparisons; nothing is written to disk while the
game runs and the tracker takes no lock (it is read on the runtime queue at the
existing 0.5 s stats boundary). The same numbers are appended to the periodic
`perf:` log line as `| stutter=<count> (<n>/min, worst <ms>, <top phase>)`.

### Capture steps (2-3 minutes)

1. Start the game and play the scene that hitches for 2-3 minutes. The first
   seconds after a load are not representative (GPU pipelines still compile on
   first use), so drive past them and, if possible, capture a second run as well.
2. Open the in-game menu (pause button) and tap **Export logs** (Simplified
   Chinese UI: **导出日志**). Opening the menu pauses the frame loop, so the
   numbers stop changing at the moment you tap it; the menu pause itself is
   excluded from them and reported as `frame_pause_*`.
3. The share sheet opens with the report, and the same file is also kept on the
   device as `Documents/Diagnostics/3ds2apple-diagnostics-yyyyMMdd-HHmmss.txt`
   (the newest 5 are kept). The export entry exists twice: the in-game menu
   above, and the home page's **Settings -> Debug -> Export logs** (设置 -> 调试 ->
   导出日志). Use the in-game menu for performance data: unloading a game resets
   the frame/stutter counters, so a report exported from Settings after returning
   home has the counter block at 0 even though the session log (including the
   periodic `perf:` lines) is complete. Use either retrieval path:
   - **Files app**: *On My iPhone/iPad -> 3ds2apple -> Diagnostics*, then share
     the newest `3ds2apple-diagnostics-*.txt`. After the export the in-game menu
     shows the exact kept path (`Saved to Documents/Diagnostics/<file>.txt`);
     the folder keeps only the 5 most recent exports.
   - **devpush** (from the desktop launcher's `tools/devpush`, USB or Wi-Fi):

     ```sh
     tools/devpush/target/release/devpush ls --bundle-id com.kratos.3ds2apple --path Documents/Diagnostics
     tools/devpush/target/release/devpush get --bundle-id com.kratos.3ds2apple --remote Documents/Diagnostics/3ds2apple-diagnostics-20261116-181500.txt --local ./3ds2apple-diagnostics.txt
     ```

     Replace the file name with the one printed by `ls` (or shown in the in-game
     menu). `--container app` is the default and the correct one for Documents;
     add `--udid <UDID>` only when more than one device is connected.
4. Send the text file together with the details below.

### What to report with the file

- game name and title ID (`game=`; filled in when the export is made while the
  game is loaded) and what was happening (battle, menu, cutscene, ...);
- device model and iOS version (`device=`) and the app build (`app=`);
- AOT proof: `aot=`, `aot_percent=`, `aot_interpreted_percent=`,
  `aot_fallbacks=`, `aot_recompiled=`;
- renderer path: `display=`, `hardware=`, `metal_moltenvk_embedded=`;
- HUD state: `system_metal_hud=`, `system_metal_hud_build_enabled=`,
  `system_metal_hud_plist=`;
- FPS counter / warm-up state: `fps_counter=`, `warmup_enabled=` (always 0 since
  0.1.1, when the first-load warm-up was removed), `warmup_note=`;
- the `stutter_*` block (0.1.2 adds `stutter_gpu_walk_bound_frames=` and
  `stutter_pipeline_compile_suspects=`) and `pipeline_cache_at_load=`, plus the
  `perf:`/`zk_perf` lines in the current-session log around the hitch;
- whether the hitch appeared on the first run after install or on later runs,
  and which non-default settings (frame cap, render scale, fast-forward, Metal
  HUD, FPS counter) were active.

The same export is also reachable from the home page's Settings page (More ->
Export logs). The frame and stutter counters are cleared when a game is unloaded,
so export from the in-game menu (or the pause overlay) when the numbers matter;
the Settings copy still carries the complete session log, including the periodic
`perf:` lines and all `zk_perf`/runtime lines.

The report carries no UDID, serial number, Apple ID or signing identity (device
model and iOS version are included); it does contain the app log, so treat it as
user data and share it deliberately.
