# 3ds2apple macOS launcher

A SwiftUI macOS app for the AOT-first product flow (v2: Library -> Deploy),
aligned with the Windows launcher (current product version **0.1.0 build 1**;
0.2.x numbers below are the pre-reset history):

    Library: import your own decrypted .3ds/.cci; cards show the ROM's own SMDH
             cover.png icon, the localized title for the app language and the
             publisher (read-only, no name input), and games can be removed
      -> Deploy: select one or several games, press one button:
         batch compile one GamePack.dylib per game (local AOT)
      -> compose ONE ROM-free library IPA: shell + Frameworks/GamePack-<TITLEID>.dylib
         + schema-2 GameCatalog.json
      -> embed the verified Frameworks/MoltenVK.framework in the shell before signing
         (hardware PICA200/Metal renderer + system Metal HUD; no software fallback)
      -> verify that IPA (real packs + catalogue, no ROM) before anything is installed
      -> sign with your own Apple ID via Xcode automatic signing + devicectl install,
         reading back the bundle ID of the app that was actually installed
      -> push ONLY Documents/Games/<TITLEID>/GameRom.cci + GameInfo.json for each
         selected game with the actual installed bundle ID, verify size/sha + listing
      -> Done ("可以打开手机 App 游玩" / "Ready to play")

iOS will not dlopen unsigned code from the app container, so the AOT code lives
inside the signed IPA and Documents only receives game data. Deploying a new
selection re-composes the IPA; pushed ROM data persists across re-installs.

Nothing in the launcher implements signing or USB/AFC itself: it orchestrates
Xcode/devicectl and the device bridge, and it never stores an Apple ID, password,
certificate or device UDID.

## UI (two centered sections + minimal Settings)

Navigation is exactly two tabs centered in the header (**游戏库 / Library** and
**部署 / Deploy**) plus a gear for Settings; there is no sidebar. The launcher
shows a persistent readiness light next to the gear: green **已完成准备 / Ready**
after the automatic startup probe passes, red **未完成准备 / Not ready** when a
local tool or the Apple ID/Xcode signing is missing (raw details live in the
tooltip and the log — there is no manual "check" button).

- **Library** - game cards with the ROM's own SMDH icon (packages/<TITLEID>/
  cover.png), the localized SMDH title for the app language, publisher,
  title/Title ID, phase badge, ROM/GamePack sizes and one staged-data line;
  remove only (no editable name input, no build/install/push buttons). Import is
  a single **导入 / Import** button that opens the file picker and imports the
  chosen decrypted .3ds/.cci in one action (no path field, name override or
  explanatory card). A game whose ROM has no SMDH icon keeps the initials
  placeholder. Importing a ROM that is already in the library re-imports its
  package with ``--force`` (SMDH cover/metadata self-heal, built GamePack kept).
- **Deploy** - device status, the checkbox selection list (one or several games),
  the single **一键部署 / Deploy selected** button, the detected compile-hardware
  line (logical cores · RAM · 3dsrecomp's automatic full-core parallelism), then
  the ordered step report
  (check device & Apple ID -> compile -> compose IPA -> verify IPA -> sign &
  install -> push game data -> Done) with inline logs; failures leave a Retry
  button; success shows an explicit Done state.
- **Settings** (gear) - language (System / English / 简体中文), Apple ID/Xcode
  signing status (read-only, auto-detected Team ID), device status + installed
  app ID, logs (export/clear), About. No build-mode, tool-path, UDID, bundle-ID or
  sign/install-strategy controls.

Language: the interface follows the macOS system UI language (Simplified Chinese
-> zh-Hans, everything else -> English) and can be forced from Settings; the
choice persists in UserDefaults. All UI chrome is localized in
`Sources/Localization.swift`; raw pipeline output stays in its original wording.

Icon: `Resources/AppIcon.icns` is generated from the iOS shell app icon, so both
apps look alike; the same icon is used for the bundle, the Dock/window and the
About panel. Regenerate it with `bash scripts/make-app-icon.sh`.

## Build and run (macOS 13+, Xcode 15+; tested with Xcode 26.6)

    cd launcher/macos
    PATH=/usr/local/bin:$PATH xcodegen generate --spec project.yml
    xcodebuild -project 3ds2apple-launcher.xcodeproj -scheme 3ds2apple-launcher \
      -configuration Release -destination 'platform=macOS' -derivedDataPath build build
    open build/Build/Products/Release/3ds2apple-launcher.app

Release builds are universal (arm64 + x86_64). Headless modes used on the build VM:

    BIN=build/Build/Products/Release/3ds2apple-launcher.app/Contents/MacOS/3ds2apple-launcher
    "$BIN" --selfcheck                                    # 207 logic/flow/i18n/shell-runtime checks, exit 0/1
    "$BIN" --screenshot-dir screenshots --mock --lang all  # offscreen non-game UI PNGs

`scripts/vm-build.sh` does the whole Release build, the self-checks, the
dark/light + English/Chinese screenshots and the user-facing ZIP in one shot on a
Mac; it needs no ROM, phone, Apple ID or network. The ZIP is written to
**out/launchers/3ds2apple-launcher-<version>-macos-app.zip** (gitignored) and
contains only the .app. Regenerate the icon with `bash scripts/make-app-icon.sh`.

## Portable data folder (0.2.4)

Every writable path comes from one portable data root, the same policy as the
Windows launcher 0.2.4:

1. `<folder containing the .app>/3ds2apple-data/` when that folder is writable
   (portable, preferred; a launcher copied to a USB stick keeps its data next to
   it),
2. `~/Library/Application Support/3ds2apple/` when the app folder is read-only,
   or when macOS runs the app from a read-only AppTranslocation path,
3. a temporary folder only when both are unusable.
   `THREEDS2APPLE_DATA_DIR` overrides the root for QA (the self-check uses it).

Layout under the root: `workspace/` (pack CLI output tree + `launcher-roms/`
game-data copies for the device push), `logs/` (launcher.log + exported logs),
`build/` (signed shell DerivedData + IPA inspection scratch), `staging/`
(GameInfo staging) and `ipa/` (composed library IPAs). On the first launch with
the new root the previous `<checkout>/out` workspace and the old launcher log are
adopted once (hardlink first, then a size-limited copy, then a `migration.json`
marker; the legacy tree is left untouched). Imported games are restored from the
workspace on every launch, so a restart no longer empties the library.

The checkout is still auto-detected for the read-only tool inputs in this order:
`THREEDS2APPLE_ROOT`, walking up from the executable, then `~/3ds2apple`,
`~/Projects/3ds2apple`, `~/repos/3ds2apple`. Tool binaries (3ds2apple-pack,
devpush, xcodegen) are auto-detected in the app bundle, the checkout and PATH.
Settings persist in `UserDefaults`; the launcher writes only inside the portable
data root (and regenerable build products in the checkout when a developer runs
it from a source tree).

## Layout

    Sources/
      LauncherMain.swift       entry point (app / --selfcheck / --screenshot-dir)
      AppModel.swift           state machine: library + one-click Deploy chain
      Models.swift             value types (game, deploy report, IPA inspection, push plan, ...)
      PortableData.swift       portable data root policy + one-time <checkout>/out migration
      Hardware.swift           logical/physical cores + RAM probe for the compile line
      LauncherSettings.swift   small persisted state (language, portable root, installed library + bundle ID)
      CommandRunner.swift      async Process wrapper + mock runner
      Toolchain.swift          auto-detected tools + readiness probe + Team ID detection
      PackBackend.swift        typed 3ds2apple-pack CLI wrapper + JSON parsing (incl. SMDH displayNames/publisher/coverPath)
      GameInfoWriter.swift     launcher -> shell GameInfo.json (push layout)
      PushPlanner.swift        Documents/Games/TITLEID plan, GameInfo.json last
      InstallBackend.swift     signed shell build, IPA inspection, codesign + devicectl, Apple error mapper
      ShellRuntime.swift       pinned MoltenVK.framework source + embedding / Metal-HUD readiness verification
      DeviceBridge.swift       devpush contract v1 client (NDJSON) + mock bridge
      MockBackends.swift       deterministic fixtures, mock CLI/installer/bridge
      SelfCheck*.swift         headless logic + flow + i18n checks
      Localization.swift       LauncherLanguage + complete en / zh-Hans strings
      SnapshotRenderer.swift   offscreen SwiftUI screenshots (en/zh, dark/light)
      Views/                   theme, components, centered-tab shell + readiness light, Library, Deploy, minimal Settings
    Resources/                 app icon (.icns/.png) + en/zh-Hans InfoPlist.strings
    scripts/vm-build.sh        Release build + self-check + screenshots + app-only ZIP in out/launchers
    scripts/make-app-icon.sh   regenerate the icon from the iOS app icon
    screenshots/               generated non-game UI evidence (committed)

## Evidence / QA

The evidence below is the pre-reset 0.2.4 build 7 record (0.2.x numbering,
kept for history); the 0.1.0 build 1 package is rebuilt and re-verified on the
VM by the 0.1.0 packaging task. Original record: the Windows-0.2.4-sync
revision (launcher 0.2.4, **build 7** with the task-8 forced re-import
self-heal) on the macOS VM (Xcode 26.6, headless), 2026-11-16:

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,120,032-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.2.4 build 7.
- self-check: **207/207 checks passed** (exit 0), including the new checks for
  portable data root resolution/fallback/migration, SMDH displayNames/publisher/
  coverPath parsing, localized name selection, the hardware line and the
  re-import `--force` path (first import never forces; re-importing an existing
  game forces the pack CLI so an old SMDH cover is re-extracted in place and the
  built GamePack is kept). The packaged app, freshly extracted from the ZIP, also
  passed 207/207.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light:
  Library (SMDH icons, localized names, publisher; populated/empty/red light),
  Deploy selection (hardware line) / running / Done / failed, minimal Settings
  (Version 0.2.4 (6), data folder, compile hardware).
- portable data root: the headless run logs
  `data root: /tmp/zl-launcher-data-vm [explicit]`; the live app resolves
  `<app folder>/3ds2apple-data` first and falls back to Application Support.
  The migration self-check adopts a synthetic old `<checkout>/out` tree without
  touching it (packages + cover.png adopted, `work/` scratch skipped, marker
  written once).
- shell template pin updated to the ROM-free shell (pre-reset values below;
  the 0.1.0 build 1 rebuild is pinned by `ShellRuntime.swift`/task-13)
  `out/shell/3ds2apple-shell.ipa` 0.2.3 build 11 (5,487,675 bytes, sha256
  831357db…); the embedded Frameworks/MoltenVK.framework is still the pinned
  4,822,128-byte MoltenVK 1.4.2 (sha256 6cd58884…).
- artifact: out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip
  (5,495,796 bytes, sha256
  8c34398f7a25709598626769adc56d146ea89ff9f3718313c7c0d796f719d28b), one
  .app only (16 entries, 13,939,629 bytes uncompressed) including
  Contents/Resources/MoltenVK.framework. The packaged launcher is self-contained
  for device deploys (the user's Mac needs no shell template).
- real iPhone acceptance is NOT done: the shared VM has no attached iPhone and no
  Apple ID signing assets. Signing/install/push need the player's own Xcode
  account and a USB device; the manual checklist is in
  [docs/macos-launcher.md](../../docs/macos-launcher.md) section 7.

Full architecture, contracts, build commands and the manual device-test
checklist are in [docs/macos-launcher.md](../../docs/macos-launcher.md).

## Licensing / attribution

Apache-2.0, same as the repository. The launcher contains no third-party code.
The S2Arm-study checkout (Apache-2.0) was read as an architectural reference only;
no source was copied. Signing is done by Apple's Xcode tooling with the user's own
Apple ID; the official Impactor is never bundled by this app. The app icon reuses
the project's own iOS shell icon.