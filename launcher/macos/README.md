# 3ds2apple macOS launcher

A SwiftUI macOS app for the AOT-first product flow (v2: Library -> Deploy):

    Library: import your own decrypted .3ds/.cci, list/rename/remove games
      -> Deploy: select one or several games, press one button:
         batch compile one GamePack.dylib per game (local AOT)
      -> compose ONE ROM-free library IPA: shell + Frameworks/GamePack-<TITLEID>.dylib
         + schema-2 GameCatalog.json
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

## UI (two sections + minimal Settings)

- **Library** - game cards with placeholder artwork, title/Title ID, phase badge,
  ROM/GamePack sizes and one staged-data line; rename/remove only. Import is a
  sheet (drag a decrypted .3ds/.cci or use the picker).
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
    "$BIN" --selfcheck                                    # 132 logic/flow/i18n checks, exit 0/1
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
      DeviceBridge.swift       devpush contract v1 client (NDJSON) + mock bridge
      MockBackends.swift       deterministic fixtures, mock CLI/installer/bridge
      SelfCheck*.swift         headless logic + flow + i18n checks
      Localization.swift       LauncherLanguage + complete en / zh-Hans strings
      SnapshotRenderer.swift   offscreen SwiftUI screenshots (en/zh, dark/light)
      Views/                   theme, components, shell, Library, Deploy, minimal Settings, Import sheet
    Resources/                 app icon (.icns/.png) + en/zh-Hans InfoPlist.strings
    scripts/vm-build.sh        Release build + self-check + screenshots + app-only ZIP in out/launchers
    scripts/make-app-icon.sh   regenerate the icon from the iOS app icon
    screenshots/               generated non-game UI evidence (committed)

## Evidence / QA

The task-31 v2 build on the macOS VM (Xcode 26.6, headless) produced:

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,141,296-byte executable), version 0.2.1 build 3.
- self-check: 132/132 checks passed (exit 0): CLI/JSON/push-plan/IPA-inspection/
  Team-ID/devpush/Apple-error/log-redaction checks, the full mock Deploy chain
  (success, never-install-bare-shell failure paths, retry, invalid-IPA refusal)
  and the two-language UI checks.
- screenshots: 20 non-game PNGs, English + Simplified Chinese, dark + light:
  Library (populated + empty), Import sheet, Deploy selection/running/Done/failed,
  minimal Settings.
- app icon: valid multi-size AppIcon.icns; en/zh-Hans InfoPlist.strings carry the
  localized app name.
- artifact: out/launchers/3ds2apple-launcher-0.2.1-macos-app.zip
  (3,978,571 bytes, sha256
  07b7956695a0a948dc623d9df6a17e0adfbe8c46967a2b2f45608748d9217b8e), one
  .app only; a fresh extraction ran the 132 checks and rendered the zh
  screenshots on the VM.

Full architecture, contracts, build commands and the manual device-test
checklist are in [docs/macos-launcher.md](../../docs/macos-launcher.md).

## Licensing / attribution

Apache-2.0, same as the repository. The launcher contains no third-party code.
The S2Arm-study checkout (Apache-2.0) was read as an architectural reference only;
no source was copied. Signing is done by Apple's Xcode tooling with the user's own
Apple ID; the official Impactor is never bundled by this app. The app icon reuses
the project's own iOS shell icon.
