# 3ds2apple macOS launcher

A SwiftUI macOS app for the AOT-first product flow (v2: Library -> Deploy),
aligned with the Windows launcher (current product version **0.1.4 build 1**;
CFBundleShortVersionString stays numeric **0.1.4**;
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
      -> push ONLY Documents/Games/<TITLEID>/GameRom.cci + cover.png (optional)
         + GameInfo.json (last) for each selected game with the actual installed
         bundle ID, verify size/sha + listing
      -> Done ("可以打开手机 App 游玩" / "Ready to play")

iOS will not dlopen unsigned code from the app container, so the AOT code lives
inside the signed IPA and Documents only receives game data. Deploying a new
selection re-composes the IPA; pushed ROM data persists across re-installs.

The pushed `GameInfo.json` also carries the base metadata the launcher already
read from the ROM's SMDH at import time, so the iOS library card needs no ROM
parsing: `displayName` is the SMDH title for the launcher's current UI language
(English fallback), `displayNames` keeps every original localized title, plus
optional `publisher`, optional `region` (SMDH region lockout: `EU`, `US`,
`EU+AU`, `region-free`; omitted when unknown), optional `cover` (`cover.png`, the
pushed SMDH icon; local user data, never committed), `rom.size`/`rom.sha256` of
the real pushed data, `launcherVersion` and `pushedAt`. `schemaVersion` stays 1
and every added field is optional, so older manifests keep parsing.

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
  Each card also has **导出 .32a / Export .32a** (enabled only for a real AOT
  GamePack) and the header has **导入 .32a / Import .32a**. The portable build
  package goes to `workspace/builds/<build-slug>.32a`: the GamePack, GameInfo,
  optional cover and the user's ROM when the CLI can find one
  (package copy, queued ROM path or `workspace/launcher-roms`). Import is
  validated by the Rust CLI (`3ds2apple-pack builds`) before anything is
  installed into `workspace/packages/<TITLEID>/`; an existing package asks for
  confirmation before it is replaced. Nothing is signed, installed or uploaded:
  a .32a can contain game data, so it stays local.
  **Export IPA** (also on each real-pack card) composes one unsigned, self-contained
  single-game IPA from the pinned shell template: the GamePack + the user's own ROM
  embedded as `Roms/<TITLEID>.<cci|3ds|ncch|cxi>` + a `GameCatalog.json` with
  `autoLaunch: true` and the matching `romFile` (the pack CLI writes the catalogue
  with `--auto-launch`; the launcher injects the embedded-data path) + the SMDH
  cover replacing every template `AppIcon*.png` (NSImage), zipped with `ditto`
  into `workspace/exports/<build-slug>-<version>-unsigned.ipa`. A missing ROM or an
  unsupported extension fails with a clear error; the staged bundle is checked to
  contain exactly one non-empty `Roms/` file named by the catalogue before zipping.
  The output is roughly GamePack + ROM in size. The UI shows the path and asks the
  user to sign it with Sideloadly/AltStore: **the IPA contains the user's own game
  data, so it stays in the local portable workspace and must never be uploaded or
  shared**. Nothing is signed, installed or uploaded.
  The Deploy page also has a collapsed **高级构建设置 / Advanced build settings**
  disclosure: optimization level (O1/O2/O3/Oz), LTO and fast-math, persisted in
  the launcher settings with **恢复默认值 / Reset to defaults**. Defaults keep the
  -O2 / no-LTO / no-fast-math baseline; the options are passed to
  `3ds2apple-pack build` (`--opt-level/--lto/--fast-math`), which forwards
  `THREEDS2APPLE_AOT_*` to the scripts for the next build.
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
contains the `.app` plus `LICENSE`, `NOTICE` and `THIRD_PARTY.md` at the ZIP root,
byte-identical to the repository files (enforced by
`scripts/release/verify-release.sh`); the licence texts ship inside the package
and are never separate Release assets. Regenerate the icon with
`bash scripts/make-app-icon.sh`.

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
      PushPlanner.swift        Documents/Games/TITLEID plan: ROM, cover.png, GameInfo.json last
      InstallBackend.swift     signed shell build, IPA inspection, codesign + devicectl, Apple error mapper
      ShellRuntime.swift       pinned MoltenVK.framework source + embedding / Metal-HUD readiness verification
      DeviceBridge.swift       devpush contract v1 client (NDJSON) + mock bridge
      MockBackends.swift       deterministic fixtures, mock CLI/installer/bridge
      SelfCheck*.swift         headless logic + flow + i18n checks
      Localization.swift       LauncherLanguage + complete en / zh-Hans strings
      SnapshotRenderer.swift   offscreen SwiftUI screenshots (en/zh, dark/light)
      Views/                   theme, components, centered-tab shell + readiness light, Library, Deploy, minimal Settings
    Resources/                 app icon (.icns/.png) + en/zh-Hans InfoPlist.strings
    scripts/vm-build.sh        Release build + self-check + screenshots + .app/licence-text ZIP in out/launchers
    scripts/make-app-icon.sh   regenerate the icon from the iOS app icon
    screenshots/               generated non-game UI evidence (committed)

## Evidence / QA

### launcher 0.1.5 build 1 (0.1.5 release, 2026-11-20)

The 0.1.5 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64), bundle com.kratos.3ds2apple.launcher, version 0.1.5 build 1.
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 6,259,066 bytes,
  sha256 72b08c96…, package version 0.1.5; the packaged app, freshly extracted
  from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs regenerated; the Settings version label shows
  "Version 0.1.5 (1)".
- artifact: out/launchers/3ds2apple-launcher-0.1.5-macos-app.zip
  (5,532,777 bytes, sha256
  bba678ce0862794b2de73a2901bf25410db355900a31c3a50254725cb9e6407c); GitHub
  Release v0.1.5. Real iPhone acceptance is still NOT done (issue #1).
### launcher 0.1.5-beta1 build 1 (local 0.1.5-beta1 pre-release, 2026-11-20)

The 0.1.5-beta1 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,155,312-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.5 build 1.
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 6,141,225 bytes,
  sha256 21ee0de8…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing keys and
  reports CFBundleShortVersionString 0.1.5 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs regenerated; the Settings version label changed
  to "Version 0.1.5 (1)", so the four Settings screenshots changed and the other
  fourteen stayed byte-identical.
- artifact: out/launchers/3ds2apple-launcher-0.1.5-beta1-macos-app.zip
  (5,532,861 bytes, sha256
  1176c7e74602ca99b50ee5f7aa6e214e44d221604b96915c7bd62b679f7030bc), one .app
  plus LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root (THIRD_PARTY.md is the new
  397,553-byte file with the Rust transitive licence list). Only packaging,
  compliance and tooling changed since 0.1.4, so game behaviour is expected to
  be identical. Real iPhone acceptance is still NOT done (issue #1).

### launcher 0.1.4 build 1 (0.1.4 release, 2026-11-19)

The 0.1.4 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,155,136-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.4 build 1.
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 6,141,211 bytes,
  sha256 8f3e24a3…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing Info.plist keys
  and reports CFBundleShortVersionString 0.1.4 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light;
  the Settings version label is unchanged ("Version 0.1.4 (1)"), so all 18 stayed
  byte-identical to the committed ones (no regeneration needed).
- artifact: out/launchers/3ds2apple-launcher-0.1.4-macos-app.zip
  (5,509,291 bytes, sha256
  d7e006323597076fcbeeaa7327abc98c10b3cd8689ccd56a2b1cd5df1023a0f3), one .app
  plus LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root (19 entries, 13,996,641 bytes
  uncompressed) including Contents/Resources/MoltenVK.framework. The launcher
  embeds the MoltenVK framework, but the macOS package is not self-contained yet
  (a checkout + Xcode + the built tools are required). Real iPhone acceptance is
  still NOT done (issue #1).

### launcher 0.1.4-beta2 build 1 (local 0.1.4-beta2 pre-release, 2026-11-19)

The 0.1.4-beta2 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,155,312-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.4 build 1 (the numeric CFBundle
  version; the product version is 0.1.4-beta2).
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 6,141,225 bytes,
  sha256 350009ba…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing Info.plist keys
  and reports CFBundleShortVersionString 0.1.4 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light;
  the bundle version shown in Settings is unchanged ("Version 0.1.4 (1)"), so all
  18 stayed byte-identical to the committed ones (no regeneration needed).
- artifact: out/launchers/3ds2apple-launcher-0.1.4-beta2-macos-app.zip
  (5,509,373 bytes, sha256
  d639595ae33fbe4cd1ff6ce93d006e49ade19ee48d084541b9d20eff31545c4b), one .app
  plus LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root (19 entries, 13,996,817 bytes
  uncompressed) including Contents/Resources/MoltenVK.framework. The launcher
  embeds the MoltenVK framework, but the macOS package is not self-contained yet
  (a checkout + Xcode + the built tools are required). Real iPhone acceptance is
  still NOT done (issue #1).

### launcher 0.1.4-beta1 build 1 (local 0.1.4-beta1 pre-release, 2026-11-19)

The 0.1.4-beta1 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,155,312-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.4 build 1 (the numeric CFBundle
  version; the product version is 0.1.4-beta1).
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 6,140,904 bytes,
  sha256 2b80bdf8…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing Info.plist keys
  and reports CFBundleShortVersionString 0.1.4 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light
  (Library SMDH icons/names/publisher; Deploy hardware line and GameInfo push
  steps; Settings "Version 0.1.4 (1)" + data folder + compile hardware); the 4
  Settings shots were regenerated for 0.1.4, the other 14 stayed byte-identical.
- artifact: out/launchers/3ds2apple-launcher-0.1.4-beta1-macos-app.zip
  (5,509,368 bytes, sha256
  000a46a36c2272024477a81fb3d72174a3aa945f9c873b508640e92439616978), one .app
  plus LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root (19 entries, 13,996,817 bytes
  uncompressed) including Contents/Resources/MoltenVK.framework. The launcher
  embeds the MoltenVK framework, but the macOS package is not self-contained yet
  (a checkout + Xcode + the built tools are required). Real iPhone acceptance is
  still NOT done (issue #1).

### launcher 0.1.3 build 1 (final 0.1.3 release, 2026-11-18)

The 0.1.3 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,155,520-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.3 build 1.
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 6,100,961 bytes,
  sha256 54d26a8f…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing Info.plist keys
  and reports CFBundleShortVersionString 0.1.3 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light
  (Library SMDH icons/names/publisher; Deploy hardware line and GameInfo push
  steps; Settings "Version 0.1.3 (1)" + data folder + compile hardware); the 4
  Settings shots were regenerated for 0.1.3, the other 14 stayed byte-identical.
- artifact: out/launchers/3ds2apple-launcher-0.1.3-macos-app.zip
  (5,509,112 bytes, sha256
  913b82c74db5889e04493ed60793c6d8afaa0164e220784e807ff5707e42484b), one .app
  plus LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root (19 entries, 13,996,574 bytes
  uncompressed) including Contents/Resources/MoltenVK.framework. The launcher
  embeds the MoltenVK framework, but the macOS package is not self-contained yet
  (a checkout + Xcode + the built tools are required). Real iPhone acceptance is
  still NOT done (issue #1).

### launcher 0.1.2 build 1 (final 0.1.2 release, 2026-11-17)

The 0.1.2 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,155,520-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.2 build 1.
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 5,803,595 bytes,
  sha256 843dded9…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing Info.plist keys
  and reports CFBundleShortVersionString 0.1.2 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light
  (Library SMDH icons/names/publisher; Deploy hardware line and GameInfo push
  steps; Settings "Version 0.1.2 (1)" + data folder + compile hardware); all 18
  are byte-identical to the committed ones (macOS launcher UI is unchanged).
- artifact: out/launchers/3ds2apple-launcher-0.1.2-macos-app.zip
  (5,509,112 bytes, sha256
  31df25b13846f1414c98e8395686bf4da85ba7d277120a6292c33116b052a2a6), one .app
  plus LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root (19 entries, 13,996,574 bytes
  uncompressed) including Contents/Resources/MoltenVK.framework. The launcher
  embeds the MoltenVK framework, but the macOS package is not self-contained yet
  (a checkout + Xcode + the built tools are required). Real iPhone acceptance is
  still NOT done: the shared VM has no attached iPhone and no Apple ID signing
  assets; the manual checklist is section **Real-device acceptance** below.

### launcher 0.1.1 build 1 (rebuilt 0.1.1, 2026-11-17)

The 0.1.2 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,155,472-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.2 build 1.
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 5,800,569 bytes,
  sha256 83a8c86e…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing Info.plist keys
  and reports CFBundleShortVersionString 0.1.2 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light
  (Library SMDH icons/names/publisher; Deploy hardware line and GameInfo push
  steps; Settings "Version 0.1.2 (1)" + data folder + compile hardware); the 4
  Settings shots were regenerated for 0.1.2, the other 14 stayed byte-identical.
- artifact: out/launchers/3ds2apple-launcher-0.1.2-macos-app.zip
  (5,509,098 bytes, sha256
  3b027d8c506c7286f387c06b49eb6e679855e32528fee535efd288d27e780cd9), one .app
  plus LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root (19 entries, 13,996,526 bytes
  uncompressed) including Contents/Resources/MoltenVK.framework. The launcher
  embeds the MoltenVK framework, but the macOS package is not self-contained yet
  (a checkout + Xcode + the built tools are required). Real iPhone acceptance is
  still NOT done: the shared VM has no attached iPhone and no Apple ID signing
  assets; the manual checklist is section **Real-device acceptance** below.

### launcher 0.1.1 build 1 (rebuilt 0.1.1, 2026-11-17)

The 0.1.1 package on the macOS VM (macOS 26.7.3, Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,155,584-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.1 build 1.
- self-check: **212/212 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 5,628,924 bytes,
  sha256 a7b26136…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing Info.plist keys
  and reports CFBundleShortVersionString 0.1.1 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 212/212.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light
  (Library SMDH icons/names/publisher; Deploy hardware line and GameInfo push
  steps; Settings "Version 0.1.1 (1)" + data folder + compile hardware); the
  rebuild regenerated all 18 shots byte-identically to the committed ones.
- artifact: out/launchers/3ds2apple-launcher-0.1.1-macos-app.zip
  (5,509,099 bytes, sha256
  720a9472c2488c846577f8566dec6bf8df1b8970e9a5c4872a91fa8b2b14da95), one .app
  plus LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root (19 entries, 13,996,638 bytes
  uncompressed) including Contents/Resources/MoltenVK.framework. The launcher
  embeds the MoltenVK framework, but the macOS package is not self-contained yet
  (a checkout + Xcode + the built tools are required). Real iPhone acceptance is
  still NOT done: the shared VM has no attached iPhone and no Apple ID signing
  assets; the manual checklist is section **Real-device acceptance** below.

### launcher 0.1.0 build 1 (product version reset, 2026-11-16)

The rebuilt 0.1.0 build 1 package on the macOS VM (Xcode 26.6, headless):

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (x86_64 + arm64, 7,154,240-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.1.0 build 1.
- self-check: **207/207 checks passed** (exit 0), including the shell-runtime
  identity check: the pinned ROM-free shell template is exactly 5,487,673 bytes,
  sha256 b54a00f4…, carries the pinned 4,822,128-byte MoltenVK 1.4.2 framework
  (sha256 6cd58884…), keeps the Metal HUD + Documents file-sharing Info.plist keys
  and reports CFBundleShortVersionString 0.1.0 / CFBundleVersion 1. The packaged
  app, freshly extracted from the ZIP, also passed 207/207.
- screenshots: 18 non-game PNGs, English + Simplified Chinese, dark + light
  (Library SMDH icons/names/publisher, Deploy hardware line, Settings
  "Version 0.1.0 (1)" + data folder + compile hardware); the 4 Settings shots were
  regenerated for the reset, the other 14 stayed byte-identical.
- artifact: out/launchers/3ds2apple-launcher-0.1.0-macos-app.zip
  (5,498,294 bytes, sha256
  d44416dd7120f2492a2016577eece1ef60c823593a1543154edd6677a88439f7), one
  .app only (16 entries, 13,973,837 bytes uncompressed) including
  Contents/Resources/MoltenVK.framework. The launcher embeds the MoltenVK
  framework, but the macOS package is not self-contained yet (a checkout + Xcode +
  the built tools are required). The already-published 0.1.0 asset predates the
  licence-text packaging change; releases from 0.1.1 on carry
  LICENSE/NOTICE/THIRD_PARTY.md at the ZIP root.
- real iPhone acceptance is NOT done: the shared VM has no attached iPhone and no
  Apple ID signing assets. Signing/install/push need the player's own Xcode
  account and a USB device; the manual checklist is section **Real-device
  acceptance** below.
- raw VM logs: /tmp/zl-010-build.log, /tmp/zl-launcher-selfcheck.log,
  /tmp/zl-launcher-selfcheck-packaged.log; copied to
  out/launchers/build-logs-macos-0.1.0/ in the WSL tree.

### historical: pre-reset 0.2.4 build 7 record

The Windows-0.2.4-sync revision (launcher 0.2.4, **build 7** with the task-8
forced re-import self-heal) on the macOS VM (Xcode 26.6, headless), 2026-11-16:

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
- shell template pin at that time: `out/shell/3ds2apple-shell.ipa` 0.2.3
  build 11 (5,487,675 bytes, sha256 831357db…); the embedded
  Frameworks/MoltenVK.framework is still the pinned 4,822,128-byte MoltenVK 1.4.2
  (sha256 6cd58884…). The 0.1.0 build 1 rebuild is pinned at the top of this
  section.
- artifact: out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip
  (5,495,796 bytes, sha256
  8c34398f7a25709598626769adc56d146ea89ff9f3718313c7c0d796f719d28b), one
  .app only (16 entries, 13,939,629 bytes uncompressed) including
  Contents/Resources/MoltenVK.framework. The shell template still came from the
  checkout (the macOS package is not self-contained).

## Real-device acceptance

Run this once on a Mac with a real iPhone/iPad; the shared build VM cannot do it
(no device, no Apple ID signing assets). Prerequisites: a Mac with Xcode signed
in to your own Apple ID; iPhone/iPad on iOS 16+ with Developer Mode enabled; USB
cable; the checkout with `build/ios/libzakuro_ios.a` built; decrypted ROMs you
own.

1. Library -> Import a ROM: the card appears with the ROM's SMDH cover icon, the
   localized title for the app language and the publisher (remove is optional;
   there is no rename).
2. Deploy -> select one or two games -> press 一键部署 / Deploy selected.
3. Expected: the Deploy page shows the detected hardware line (cores · RAM ·
   3dsrecomp auto-parallelism); preflight shows the detected Team ID and device;
   step 2 builds the GamePacks; step 3 composes one IPA under
   `<portable-data>/ipa`; step 4 reports "N pack(s), schema-2 catalogue, no ROM";
   step 5 installs and shows the actual installed bundle ID; step 6 pushes
   GameRom + GameInfo per game; step 7 says 可以打开手机 App 游玩 / Ready to play.
   Settings > About shows the resolved data folder and the compile hardware.
4. Device triage: 9120 -> re-sign-in Xcode Accounts; 9401 -> trust/Developer
   Mode/free-account limit; "no signing assets" -> add Apple ID in Xcode; device
   not found -> cable/Trust/unlock; push stall -> reconnect and retry (the push
   is idempotent, GameInfo goes last).
5. Re-deploying with a different selection re-composes the IPA; pushed Documents
   data is kept. After a clean app reinstall, re-deploy to push the data again.
6. Cleanup: no ROM/IPA/dylib/GameInfo.json from a test may be committed to git.

Build commands for the launcher are above; the end-user flow is documented in
the root [README.md](../../README.md).

## Licensing / attribution

Apache-2.0, same as the repository. The launcher contains no third-party code.
The S2Arm-study checkout (Apache-2.0) was read as an architectural reference only;
no source was copied. Signing is done by Apple's Xcode tooling with the user's own
Apple ID; the official Impactor is never bundled by this app. The app icon reuses
the project's own iOS shell icon.