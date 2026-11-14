# 3ds2apple macOS launcher

A SwiftUI macOS app for the AOT-first product flow:

    import your own decrypted .3ds/.cci
      -> detect titleID / name from the header
      -> build one GamePack.dylib per game (desktop CLI + scripts/)
      -> build a ROM-free library IPA: shell + Frameworks/GamePack-<TITLEID>.dylib
         + GameCatalog.json, signed with your own Apple ID (xcodebuild + codesign
         + devicectl; no custom signing server)
      -> push ONLY Documents/Games/<TITLEID>/GameRom.cci + GameInfo.json with the
         device-bridge CLI (tools/devpush, contract devpush/1)
      -> verify on the device

iOS will not dlopen unsigned code from the app container, so the AOT code lives
inside the signed IPA and Documents only receives game data. Adding/removing a
game rebuilds + reinstalls the library IPA; pushed ROM data persists.

Nothing in the launcher implements signing or USB/AFC itself: it orchestrates
Xcode/devicectl and the device bridge, and it never stores an Apple ID, password,
certificate or device UDID.

## UI (two sections + Settings)

The launcher matches the iPhone/iPad shell: minimal, two top-level sections and a
Settings panel (never a top-level tab).

- **Library** - game cards with a placeholder artwork tile, title/Title ID, one
  status badge, ROM/GamePack sizes, one primary action per game (Build AOT /
  Install library / Push game data / How to play) and an info button that opens
  the per-game package/detail dialog. The on-device library status (installed
  games, library IPA, rebuild warning) lives under the grid.
- **Import** - drag a decrypted .3ds/.cci/.ncch/.cxi onto the drop card or use the
  file picker; the detected header (Title ID, product code, display name, sizes)
  is shown before the single primary "Queue this game" button.
- **Settings** (gear) - language (System / English / 简体中文), Apple ID + Team ID
  with the signing explanation, device state and bundle ID, build mode, sign &
  install strategy, tool paths, logs and diagnostics, and About.
- **Game detail dialog** - package details, GamePack hash, installed-library
  state, the Documents push plan with per-file progress, Prepare/Push/Verify, and
  the per-game build/library/push log.

Language: the interface follows the macOS system UI language (Simplified Chinese
-> zh-Hans, everything else -> English) and can be forced from Settings; the
choice persists in UserDefaults. All UI chrome is localized in
`Sources/Localization.swift`; raw pipeline output (stage details, logs, Apple
signing errors) stays in its original wording.

Icon: `Resources/AppIcon.icns` is generated from the iOS shell app icon
(`ios/app/Assets.xcassets/AppIcon.appiconset/icon-1024.png`) so both apps look
alike; the same icon is used for the bundle, the Dock/window and the About panel.
Regenerate it with `bash scripts/make-app-icon.sh`.

## Build and run (macOS 13+, Xcode 15+; tested with Xcode 26.6)

    cd launcher/macos
    PATH=/usr/local/bin:$PATH xcodegen generate --spec project.yml
    xcodebuild -project 3ds2apple-launcher.xcodeproj -scheme 3ds2apple-launcher \
      -configuration Release -destination 'platform=macOS' -derivedDataPath build build
    open build/Build/Products/Release/3ds2apple-launcher.app

Release builds are universal (arm64 + x86_64). Headless modes used on the build VM:

    BIN=build/Build/Products/Release/3ds2apple-launcher.app/Contents/MacOS/3ds2apple-launcher
    "$BIN" --selfcheck                                   # logic + i18n checks, exit 0/1
    "$BIN" --screenshot-dir screenshots --mock --lang all # offscreen non-game UI PNGs

`scripts/vm-build.sh` does the whole Release build, the self-checks, the
dark/light + English/Chinese screenshots and the distributable zip in one shot on
a Mac; it needs no ROM, phone, Apple ID or network. `scripts/make-app-icon.sh`
regenerates the app icon from the iOS icon.

## Repository detection

The app finds the checkout in this order:

1. `THREEDS2APPLE_ROOT` environment variable,
2. walking up from the executable (covers a build inside the repo),
3. `~/3ds2apple`, `~/Projects/3ds2apple`, `~/repos/3ds2apple`.

The output tree defaults to `<checkout>/out` (gitignored). Settings persist in
`UserDefaults`; nothing is written outside `out/`, `build/` and the system
temporary/log directories.

## Layout

    Sources/
      LauncherMain.swift       entry point (app / --selfcheck / --screenshot-dir)
      Localization.swift       LauncherLanguage + complete en / zh-Hans strings
      AppModel.swift           state machine: import -> build -> install -> push
      Models.swift             value types shared by pipeline, bridge and UI
      LauncherSettings.swift   paths/mode/team/language settings + checkout detection
      CommandRunner.swift      async Process wrapper + mock runner
      Toolchain.swift          toolchain/Apple-ID readiness probe
      PackBackend.swift        typed 3ds2apple-pack CLI wrapper + JSON parsing
      GameInfoWriter.swift     launcher -> shell GameInfo.json (push layout)
      PushPlanner.swift        Documents/Games/TITLEID plan, GameInfo.json last
      InstallBackend.swift     xcodebuild signing + devicectl install + error mapper
      DeviceBridge.swift       devpush contract v1 client (NDJSON) + mock bridge
      MockBackends.swift       deterministic fixtures, mock CLI/installer/bridge
      SelfCheck*.swift         headless logic + i18n checks (PASS/FAIL lines)
      SnapshotRenderer.swift   offscreen SwiftUI screenshots (en/zh, dark/light)
      Views/                   theme, components, two-section shell, Library,
                               Import, Settings panel, game detail dialog
    Resources/                 app icon (.icns/.png) + en/zh-Hans InfoPlist.strings
    scripts/vm-build.sh        Release build + self-check + screenshots + zip on a Mac
    scripts/make-app-icon.sh   regenerate the icon from the iOS app icon
    screenshots/               generated non-game UI evidence (committed)

## Modes

- **Live**: real CLI, real Xcode, real device bridge.
- **Mock / dry run**: `--selfcheck`/`--screenshot-dir` and the mock backends;
  deterministic fixtures, no ROM/device/Apple-ID. The UI shows a MOCK badge.
- **Dry run** (build mode): runs the desktop CLI in plan mode; writes nothing.
- **Fake preview pack**: labelled placeholder pack for layout tests; not installable.
- **Real AOT build**: runs `3ds2apple-pack build --queued --execute`, which drives
  `scripts/build-recomp-ios.sh` and `scripts/build-game-pack.sh` on this Mac.

## Evidence / QA

The build VM run (Xcode 26.6, headless) produced:

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,506,784-byte executable), version 0.2.0 build 2.
- self-check: 108/108 checks passed (exit 0): the original launcher CLI/JSON/
  push/library/devpush/Apple-error/log-redaction/flow checks plus the new i18n
  checks (system language resolution, both string tables complete, iOS-shell
  terminology, persisted override, localized enum labels).
- screenshots: 16 non-game PNGs, English + Simplified Chinese, dark + light:
  Library (populated + empty), Import, build-running, game detail and Settings.
- app icon: valid multi-size AppIcon.icns in the app bundle; en/zh-Hans
  InfoPlist.strings carry the localized app name.

Full architecture, contracts, build commands and the manual device-test checklist
are in [docs/macos-launcher.md](../../docs/macos-launcher.md).

## Licensing / attribution

Apache-2.0, same as the repository. The launcher contains no third-party code.
The S2Arm-study checkout (Apache-2.0) was read as an architectural reference only;
no source was copied. Signing is done by Apple's Xcode tooling with the user's own
Apple ID; the official Impactor is never bundled by this app. The app icon reuses
the project's own iOS shell icon.
