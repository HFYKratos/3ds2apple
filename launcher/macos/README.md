# 3ds2apple macOS launcher

A SwiftUI macOS app for the AOT-first product flow (v2: Library -> Deploy):

    Library: import your own decrypted .3ds/.cci, list/rename/remove games
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

- **Library** - game cards with placeholder artwork, title/Title ID, phase badge,
  ROM/GamePack sizes and one staged-data line; rename/remove only. Import is a
  single **导入 / Import** button that opens the file picker and imports the
  chosen decrypted .3ds/.cci in one action (no path field, name override or
  explanatory card).
- **Deploy** - device status, the checkbox selection list (one or several games),
  the single **一键部署 / Deploy selected** button, then the ordered step report
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
    "$BIN" --selfcheck                                    # 151 logic/flow/i18n/shell-runtime checks, exit 0/1
    "$BIN" --screenshot-dir screenshots --mock --lang all  # offscreen non-game UI PNGs

`scripts/vm-build.sh` does the whole Release build, the self-checks, the
dark/light + English/Chinese screenshots and the user-facing ZIP in one shot on a
Mac; it needs no ROM, phone, Apple ID or network. The ZIP is written to
**out/launchers/3ds2apple-launcher-<version>-macos-app.zip** (gitignored) and
contains only the .app. Regenerate the icon with `bash scripts/make-app-icon.sh`.

## Repository detection

The app finds the checkout in this order:

1. `THREEDS2APPLE_ROOT` environment variable,
2. walking up from the executable (covers a build inside the repo),
3. `~/3ds2apple`, `~/Projects/3ds2apple`, `~/repos/3ds2apple`.

The output tree defaults to `<checkout>/out` (gitignored). Tool binaries
(3ds2apple-pack, devpush, xcodegen) are auto-detected in the app bundle, the
checkout and PATH. Settings persist in `UserDefaults`; nothing is written outside
`out/`, `build/` and the system temporary/log directories.

## Layout

    Sources/
      LauncherMain.swift       entry point (app / --selfcheck / --screenshot-dir)
      AppModel.swift           state machine: library + one-click Deploy chain
      Models.swift             value types (game, deploy report, IPA inspection, push plan, ...)
      LauncherSettings.swift   small persisted state (language, installed library + bundle ID)
      CommandRunner.swift      async Process wrapper + mock runner
      Toolchain.swift          auto-detected tools + readiness probe + Team ID detection
      PackBackend.swift        typed 3ds2apple-pack CLI wrapper + JSON parsing
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

The task-35 MoltenVK revision on the macOS VM (Xcode 26.6, headless) produced:

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 6,720,464-byte executable), version 0.2.3 build 5.
- self-check: 151/151 checks passed (exit 0): the task-34 142 checks plus 9
  shell-runtime checks (verified MoltenVK source resolves and is the pinned
  arm64 MoltenVK 1.4.2 dylib, the pinned template carries it, copy into the
  shell app passes verification, and a shell without the framework /
  MetalHudEnabled / file sharing is refused; the composed-IPA inspection also
  refuses a shell without the runtime). A real xcodebuild-built unsigned shell
  .app got the framework copied in and verified, proving the pre-signing step.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light:
  Library (populated, empty, red not-ready), Deploy selection/running/Done/failed,
  minimal Settings. Import is a single button, so there is no import-sheet shot.
- app icon: valid multi-size AppIcon.icns; en/zh-Hans InfoPlist.strings carry the
  localized app name.
- artifact: out/launchers/3ds2apple-launcher-0.2.3-macos-app.zip
  (5,350,734 bytes, sha256
  6ffcf9c655342370f1237885115befc00666072af0617c0d6f228f32d5211c3a), one
  .app only (16 entries, 13,540,061 bytes uncompressed) including
  Contents/Resources/MoltenVK.framework (4,822,128 bytes, sha256 6cd58884…);
  a fresh extraction ran the 151 checks and reported x86_64 + arm64,
  version 0.2.3 build 5 on the VM. The packaged launcher is self-contained for
  device deploys (the user's Mac needs no shell template).
- embedded framework source: pinned out/shell/3ds2apple-shell.ipa 0.2.2 build
  10 (5,477,984 bytes, sha256 d05af5a7…); scripts/vm-build.sh refuses to package
  if the template or its MoltenVK binary is missing or not the pinned bytes.

Full architecture, contracts, build commands and the manual device-test
checklist are in [docs/macos-launcher.md](../../docs/macos-launcher.md).

## Licensing / attribution

Apache-2.0, same as the repository. The launcher contains no third-party code.
The S2Arm-study checkout (Apache-2.0) was read as an architectural reference only;
no source was copied. Signing is done by Apple's Xcode tooling with the user's own
Apple ID; the official Impactor is never bundled by this app. The app icon reuses
the project's own iOS shell icon.