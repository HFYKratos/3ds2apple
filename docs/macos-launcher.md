# macOS launcher (MVP)

> Status: task-29 two-section UI revision (2026-11-15) · owner: mac-ui ·
> not committed (Lead review). Backend contracts are unchanged from task-18;
> this revision is the UI, localization, icon and package work.
>
> Code: [launcher/macos](../launcher/macos) · UI spec: [launcher-ui.md](launcher-ui.md)
> · desktop pipeline: [desktop-aot.md](desktop-aot.md) · device bridge:
> [device-bridge.md](device-bridge.md) · architecture:
> [launcher-architecture.md](launcher-architecture.md)

The macOS launcher is the product front-end for the AOT-first model: the player
imports their own decrypted 3DS ROM, the launcher compiles one native GamePack per
game on the Mac, builds a **ROM-free library IPA** that contains the base shell,
Frameworks/GamePack-<TITLEID>.dylib and a bundle GameCatalog.json, signs and
installs it with the player's own Apple ID, and then pushes only the player's
ROM/game data plus GameInfo.json into the app's Documents folder.

**Why the split:** iOS refuses to dlopen unsigned code copied into the app
container. Per-game AOT code must live inside the signed app bundle; only data
(GameRom.cci, GameInfo.json) is pushed to Documents/Games/<TITLEID>/. Adding or
removing a game means rebuilding and reinstalling the library IPA (catalog and
embedded dylibs change); ROM data already pushed to Documents is kept across
reinstalls and only needs re-pushing after a clean install.

## 0. TL;DR

Build and run on a Mac with Xcode 15+ (tested with Xcode 26.6):

    cd launcher/macos
    PATH=/usr/local/bin:$PATH xcodegen generate --spec project.yml
    xcodebuild -project 3ds2apple-launcher.xcodeproj -scheme 3ds2apple-launcher \
      -configuration Release -destination 'platform=macOS' -derivedDataPath build build
    open build/Build/Products/Release/3ds2apple-launcher.app

Release builds are universal (arm64 + x86_64). Headless (CI-like) checks and
screenshots on the shared build VM:

    BIN=build/Build/Products/Release/3ds2apple-launcher.app/Contents/MacOS/3ds2apple-launcher
    "$BIN" --selfcheck
    "$BIN" --screenshot-dir screenshots --mock --lang all

or one shot: bash scripts/vm-build.sh (Release build + self-check + screenshots +
zip). scripts/make-app-icon.sh regenerates the app icon from the iOS shell icon.

Pure SwiftUI, no third-party dependencies, Apache-2.0. The launcher never
implements signing, Apple-ID authentication or USB/AFC itself.

## 1. User flow

1. Import: choose a decrypted .3ds/.cci (also .ncch/.cxi). The launcher reads only
   the NCSD/NCCH header, shows the detected titleID/product code/display name and
   queues a **ROM-free** package in out/packages/TITLEID. It also stages a
   gitignored copy of the player's game data in out/launcher-roms/TITLEID.ext for
   the later Documents push (hardlink when possible).
2. Build AOT: dry run (print the command plan), fake preview pack (placeholder,
   layout tests only) or real AOT build via the desktop CLI/scripts. The result is
   one real GamePack.dylib per game.
3. Build + install library: enter the Apple Developer Team ID, connect the device,
   press "Build and install library IPA". The launcher:
   - builds the ROM-free shell .app with xcodebuild automatic signing
     (-allowProvisioningUpdates);
   - runs 3ds2apple-pack pack --all --execute --base-app ... which embeds
     Frameworks/GamePack-TITLEID.dylib + GameCatalog.json and produces the
     unsigned library IPA (scripts/build-multi-game-ipa.sh);
   - unzips the IPA, code-signs every embedded GamePack and the staged .app with
     the same local Apple Development identity, then installs with xcrun devicectl.
   The official Impactor strategy builds the same unsigned IPA and opens it in
   Impactor for a manual sign/install instead.
4. Push game data: for each game, the launcher pushes
   Documents/Games/TITLEID/GameRom.cci and then GameInfo.json (last) over the
   device bridge (devpush/1), verifies the remote sizes and re-lists the folder.
   The shell shows "Data missing" for a catalog game until this push lands.
5. Play: launch the shell; the library comes from the bundle catalog, the ROM
   from Documents. Adding another game repeats steps 1-4 (rebuild/reinstall IPA,
   push the new game data; existing Documents data is kept).

## 1.1 UI: two sections, Settings and languages (task-29)

The launcher matches the iPhone/iPad shell: minimal, two primary sections plus a
Settings panel (see [launcher-ui.md](launcher-ui.md)).

| Area | Content |
|---|---|
| Library (default) | game cards (placeholder artwork tile, name, Title ID/product code, one phase badge, ROM/GamePack sizes, one primary action: Build AOT / Install library / Push game data / How to play) + info button; grid empty state with one Import CTA; on-device library card with installed titles, library IPA and rebuild warning; inline progress card while a task runs |
| Import | drag-and-drop drop card (live app only) or file picker; detected NCSD/NCCH header; one primary "Queue this game"; inline import progress + log while a job runs; 4-step explanation |
| Settings (gear) | language (System / English / 简体中文), Apple ID + Team ID + signing explanation, device state/bundle ID, build mode, sign & install strategy, tool paths, diagnostics (readiness metrics, toolchain, notes), logs (export/clear), About (app icon, version, license) |
| Game detail dialog | package details + SHA-256, installed-library state, Documents push plan with per-file progress, Prepare/Push/Verify, build/library/push log |

Old top-level Build / Shell+library / Device-push / Activity / Diagnostics screens
were removed from navigation; their essential actions live on the game card, the
game detail dialog and the Settings panel.

**Language.** The UI follows the macOS UI language: Simplified Chinese variants
(zh, zh-Hans*, zh-CN/SG/MY) -> Chinese, everything else -> English. Settings can
force English or Simplified Chinese and the choice persists in UserDefaults
(`zl.language`). All UI chrome lives in
[launcher/macos/Sources/Localization.swift](../launcher/macos/Sources/Localization.swift);
pipeline output (stage details, task titles, Apple signing messages, CLI/devpush
logs) is diagnostic text and stays in its original wording by design. The Chinese
table reuses the iOS shell terms (游戏库, 导入, 设置, 安装, 推送, Apple ID).

**Icon and window.** `launcher/macos/Resources/AppIcon.icns` (+ 1024 px PNG) is
generated from the iOS shell app icon
(`ios/app/Assets.xcassets/AppIcon.appiconset/icon-1024.png`); it is embedded in
the bundle (CFBundleIconFile), installed as the application/Dock icon and shown in
the About panel. `Resources/en.lproj` and `Resources/zh-Hans.lproj`
InfoPlist.strings localize the app display name ("3ds2apple Launcher" /
"3ds2apple 启动器").

## 2. Architecture

    +--------------------------- macOS launcher (SwiftUI) --------------------------+
    | Import/Detect   Build AOT    Shell + library install      Device push          |
    |      |             |                  |                        |               |
    |  PackCLI       BuildPipeline    InstallBackend          PushPlanner + DevpushCLI
    |  (typed JSON)  (dry/fake/real)  (xcodebuild/pack/codesign/devicectl)          |
    +------|--------------|------------------|-------------------------|-------------+
           v              v                  v                         v
     3ds2apple-pack   scripts/*.sh   build-multi-game-ipa.sh     tools/devpush (AFC)
     (builder/pack)   (AOT build)    + codesign + devicectl      usbmuxd/house_arrest
           |              |                  |                         |
           v              v                  v                         v
      out/packages/   GamePack.dylib   IPA/3ds2apple-library.ipa   Documents/Games/
      (ROM-free)      (per game)       (shell+packs+catalog,       TITLEID/
                                        signed, installed)          GameRom.cci
                                                                    GameInfo.json

Components (launcher/macos/Sources):

| File | Responsibility |
|---|---|
| LauncherMain.swift | entry point: SwiftUI app, --selfcheck, --screenshot-dir |
| AppModel.swift | state machine for import -> build -> library install -> data push; stages/tasks/logs; mock seeding |
| Models.swift | value types (game, task, device, push plan, readiness, failures) |
| LauncherSettings.swift | checkout/out paths, team ID, build mode, strategy, installed-library state |
| CommandRunner.swift | async Foundation.Process wrapper with streamed lines and cancellation; mock runner |
| Toolchain.swift | locates checkout, pack CLI, devpush, xcodegen, Xcode/devicectl, signing assets |
| PackBackend.swift | desktop-CLI wrapper (rom inspect, packages add/list/verify, build, pack library IPA) + JSON parsing |
| GameInfoWriter.swift | ROM-oriented Documents GameInfo.json (pack object informational) |
| PushPlanner.swift | Documents/Games plan: GameRom + GameInfo (last); no dylib |
| InstallBackend.swift | readiness, xcodebuild signing, library IPA unpack + codesign + devicectl install, Impactor manual path, Apple error translation |
| DeviceBridge.swift | devpush/1 NDJSON client + unavailable bridge |
| MockBackends.swift | deterministic fixtures + mock pack CLI/bridge used by mock, self-check and screenshots |
| SelfCheck*.swift | headless logic checks (exit 0/1) |
| Localization.swift | LauncherLanguage resolution + complete English / zh-Hans string tables |
| SnapshotRenderer.swift | offscreen SwiftUI ImageRenderer screenshots (en+zh, dark+light) |
| Views/* | theme, components, two-section shell (sidebar/top bar), Library, Import, Settings panel, game detail dialog |
| Resources/ | app icon (.icns/.png, from the iOS icon) + en / zh-Hans InfoPlist.strings |
| scripts/make-app-icon.sh | regenerates the app icon from the iOS shell icon |

## 3. Backend contracts

### 3.1 Desktop CLI: 3ds2apple-pack

The launcher never writes package metadata itself; builder/pack is the single
writer of GameInfo.json / GameCatalog.json. Commands used (--json, --out OUT):

    rom inspect ROM --json
    packages add --roms ROM --json          (no --include-rom: packages stay ROM-free)
    packages list --json
    build --queued [--fake|--execute] --json
    pack --all --execute --base-app APP --ipa-out DIR --ipa-name 3ds2apple-library --json
        (allocates built packages into the shell app and runs
         scripts/build-multi-game-ipa.sh; the IPA carries Frameworks/GamePack-*.dylib
         + GameCatalog.json only, never Roms/ or GameRom)

Errors surface with the CLI exit code (0 ok, 1 validation/failure, 2 usage) and the
last meaningful output line as hint. Everything stays inside out/, build/ and IPA/
(all gitignored).

### 3.2 AOT build

Real build mode runs 3ds2apple-pack build --queued --execute, which drives
scripts/build-recomp-ios.sh (ROM -> generated C) and scripts/build-game-pack.sh
(arm64 compile + GamePack.dylib link + package record). Dry run prints the plan,
fake mode writes labelled placeholder packs; the library/push flow refuses
placeholder packs in real installs. The real AOT compile is not re-implemented by
the launcher and is documented in desktop-aot.md.

### 3.3 Shell + library install (Xcode signing + devicectl)

    xcodegen generate (ios/app)
    xcodebuild -project ios/app/3ds2apple.xcodeproj -scheme 3ds2apple \
      -configuration Debug -destination 'generic/platform=iOS' \
      -derivedDataPath build/launcher-shell \
      CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
      DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates build
    3ds2apple-pack pack --all --execute --base-app <built .app> \
      --ipa-out IPA --ipa-name 3ds2apple-library
    unzip IPA/3ds2apple-library.ipa -d <temp>
    codesign -f -s <Apple Development identity> <app>/Frameworks/GamePack-*.dylib
    codesign -f -s <Apple Development identity> [--entitlements <from signed app>] <app>
    codesign --verify --deep --strict <app>
    xcrun devicectl device install app --device <UDID> <app>

Readiness checks (Diagnostics and Shell + library screens): xcodebuild version,
xcode-select path, xcrun devicectl, security find-identity count, provisioning
profile count, Team ID (player-entered), shell runtime build/ios/libzakuro_ios.a.
Certificate names/identities are never logged; the identity hash is only passed to
codesign.

Apple signing errors are translated to plain language by AppleErrorMapper:

| Pattern | Plain-language title | Hint |
|---|---|---|
| 9120 | signing session rejected | sign out/in of Xcode Accounts, approve 2FA, retry |
| 9401 | account/certificate cannot install | trust, Developer Mode, free-account limits, unlocked device |
| no signing certificate / 0 valid identities | no valid certificate for the team | let Xcode create it with automatic signing |
| no profiles for / provisioning profile | no provisioning profile matches the bundle ID | set Team ID, automatic signing, unique bundle ID |
| requires a development team | Team ID missing | enter the 10-character Team ID |
| not signed in / session expired | Xcode not signed in | Xcode -> Settings -> Accounts |
| Developer Mode | device blocks development apps | enable Developer Mode on the device |
| failed to verify code signature / AMFI | device rejected the signature | trust cert, refresh profile, 7-day expiry |
| maximum number of apps / free account | free Apple ID limit | delete another sideloaded app |
| device locked / not paired / not found | connection state | unlock, Trust, reconnect |
| expired | profile/certificate expired | rebuild + reinstall to refresh |

Impactor strategy: if /Applications/Impactor.app exists the launcher builds the
same unsigned library IPA and opens it in Impactor; the player signs in and installs
there. The official Impactor binary is never bundled, pinned or copied by this app.

### 3.4 Documents push (devpush/1)

Only game data is pushed; the AOT code is already in the signed IPA. The bridge
(task-16/20, tools/devpush) speaks NDJSON with --json, schema devpush/1
(begin|progress|warn|done|error), stable exit codes, 90 s stall watchdog.

Commands used, all --json --container app:

    devices                          device list
    app-attr --bundle-id ID          shell installed / file sharing / version
    mkdir --bundle-id ID --path P    idempotent directory creation
    put --bundle-id ID --local F --remote P
                                     begin/progress/done {remotePath,bytes,sha256}
    stat --bundle-id ID --path P     remote size check after each put
    ls --bundle-id ID --path DIR     remote listing for verification

Push algorithm per game (2 files, manifest last):

1. Planner validates that the game is in the installed library IPA and that the
   staged ROM data exists (out/launcher-roms), then writes GameInfo.json staging.
2. mkdir Documents/Games/TITLEID.
3. put GameRom.cci, then put GameInfo.json LAST; stream progress; after each put
   stat the remote size and compare with the local file.
4. app-attr checks the shell is installed; ls confirms both file names.

The game must already be in the installed library IPA; otherwise the launcher
refuses with "Library out of date" and points at rebuild + reinstall. ROM data
already pushed stays on the phone when the IPA is reinstalled; a clean install
(removed app) requires re-pushing it.

The second, optional wrapper builder/device/device_cli.py (device-install/1)
offers status, sign-install via official Impactor plumesign, and push-game (which
also pushes exactly GameRom.cci + GameInfo.json and takes the local GamePack only
as metadata). The launcher uses raw devpush/1 for now and detects the wrapper in
Diagnostics; wiring its sign-install NDJSON is a documented next step.

### 3.5 On-device layout and GameInfo.json

    <signed app bundle>/
      Frameworks/GamePack-<TITLEID>.dylib    AOT code (signed with the app)
      GameCatalog.json                       titleID -> packFile/packABIVersion/...
    Documents/Games/<TITLEID>/
      GameInfo.json                          written last by the launcher
      GameRom.cci                            the player's own game data

GameInfo.json (schemaVersion 1) example:

    {"schemaVersion":1,
     "titleID":"0004000000055E00",
     "displayName":"Pokemon Y",
     "productCode":"CTR-P-EK2A",
     "aot":true,"aotVersion":1,"packABIVersion":1,
     "registrationSymbol":"zk_gamepack_register",
     "packInBundle":true,
     "saveNamespace":"0004000000055E00",
     "launcherVersion":"0.1.0",
     "pushedAt":"...Z",
     "rom":{"file":"GameRom.cci","size":1446201088,"sha256":"..."},
     "pack":{"file":"Frameworks/GamePack-0004000000055E00.dylib","size":...,"sha256":"...","inBundle":true,"sourceFile":"GamePack.dylib"},
     "requiresFileSharing":true,"notes":""}

The shell loads the pack from the bundle catalog (the pack object is
informational) and the ROM from Documents; it verifies the ROM size/sha256 and
shows a per-game "Data missing" state until the push verifies. ROM data is never
put into the IPA.

## 4. Modes

| Mode | How | What it does |
|---|---|---|
| Live | normal app launch | real CLI, real Xcode/codesign/devicectl, real devpush |
| Mock / dry run | --selfcheck, --screenshot-dir, mock backends | deterministic fixtures; no ROM, phone, Apple ID or network |
| Build dry run | build mode Dry run | CLI plan only; nothing written |
| Fake preview | build mode Fake preview pack | labelled placeholder packs; real install/push refuses them |
| Real AOT | build mode Real AOT build | scripts/build-recomp-ios.sh + build-game-pack.sh |

The sidebar always shows MOCK / DRY RUN vs LIVE so a demo can never be mistaken
for a real device run.

## 5. Build and test on the macOS VM

Environment: macOS 26.7.3 VM (8 vCPU, 12 GB, QEMU), Xcode 26.6 (17F113),
xcodegen 2.46.0, no Aqua GUI session (SSH only), no Apple ID signing assets, no
attached iPhone. The app is built and exercised headlessly; UI is drawn offscreen
with SwiftUI ImageRenderer.

Commands (also launcher/macos/scripts/vm-build.sh):

    cd ~/3ds2apple/launcher/macos
    PATH=/usr/local/bin:$PATH xcodegen generate --spec project.yml
    xcodebuild -project 3ds2apple-launcher.xcodeproj -scheme 3ds2apple-launcher \
      -configuration Release -destination 'platform=macOS' -derivedDataPath build build
    APP=build/Build/Products/Release/3ds2apple-launcher.app
    "$APP/Contents/MacOS/3ds2apple-launcher" --selfcheck
    "$APP/Contents/MacOS/3ds2apple-launcher" --screenshot-dir screenshots --theme dark  --lang all --mock
    "$APP/Contents/MacOS/3ds2apple-launcher" --screenshot-dir screenshots --theme light --lang all --mock

scripts/vm-build.sh runs all of the above and assembles
/tmp/zl-macos-ui/3ds2apple-launcher-<version>-macos-universal.zip.
Results are in section 9 (build log tail, self-check summary, screenshots, zip).

## 6. Manual device test (not executable on the shared VM)

Prerequisites: a Mac with Xcode signed in to the player's own Apple ID; iPhone/iPad
on iOS 17+ with Developer Mode; USB cable; the 3ds2apple checkout with
build/ios/libzakuro_ios.a built; a decrypted ROM the player owns.

A. Library install
1. Diagnostics -> Refresh environment: Xcode, devicectl, checkout, shell runtime
   green; after signing in to Xcode: at least one certificate and profile.
2. Shell + library: enter Team ID, connect/unlock/Trust the device, Detect devices.
3. Build at least one GamePack first (Build AOT, real mode). Then press Build and
   install library IPA. Expected stages: Check Apple ID readiness -> Build signed
   shell app -> Embed GamePacks + GameCatalog -> Sign packs + install -> Verify.
   Expected: the shell appears on the device; log ends "library installed"; the
   packaging log shows Frameworks/GamePack-<TITLEID>.dylib and no Roms/ entry.
4. Failure triage: 9120 -> re-sign-in Xcode Accounts; 9401 -> trust/Developer
   Mode/free-account limit; "no signing assets" -> add Apple ID in Xcode;
   device not found -> cable/Trust/unlock.

B. Game data push
1. Device push: select game + device; Prepare shows exactly two files
   (GameRom.cci, GameInfo.json last) with the ROM sha256 from the staged copy.
2. Press Push to device: progress per file, then "verified on device"; the game
   card becomes ON DEVICE and the shell replaces "Data missing" with the game.
3. Recovery: cable/Wi-Fi drop -> stall_timeout after 90 s; reconnect and push
   again (files overwritten, manifest last).
4. Reinstall/update: rebuilding the library IPA for another game keeps
   Documents/Games data; after a clean app reinstall re-push the game data.

C. Cleanup: no ROM/IPA/dylib/GameInfo.json from a test may be committed to git.

## 7. Privacy, security, licensing

- No Apple ID, password, certificate name, provisioning profile or device UDID is
  stored or logged by the launcher. Signing is Xcode automatic signing with the
  player's own account; the launcher passes only the Team ID and bundle ID and uses
  the local identity hash for codesign.
- Logs are local (~/Library/Application Support/3ds2apple-launcher/launcher.log)
  and pass a redactor that replaces UDID-shaped, SHA-1-shaped and e-mail-shaped
  values before storing/exporting.
- ROM copies (out/launcher-roms), packages, IPAs and generated C stay in
  gitignored directories; only the launcher's own source, docs and non-game UI
  screenshots are committed.
- The launcher contains no third-party code. S2Arm-study (Apache-2.0) was read as
  an architectural reference only; no source was copied. Signing is Apple tooling;
  official Impactor is never bundled. Repository license: Apache-2.0.

## 8. Known limitations / next steps

1. Device-attached end-to-end (library install + data push + shell launch) is not
   verified on the shared VM: no phone and no Apple ID there. Section 6 is the
   acceptance procedure.
2. devpush integration is contract-level: the launcher parser matches the real
   tools/devpush --mock-dir CLI events/exit codes, and the bridge's own mock tests
   pass; a real USB device run is the first follow-up (task-20 contract).
3. builder/device/device_cli.py (device-install/1 wrapper) is detected and shown
   in Diagnostics but not yet driven; the launcher uses raw devpush for pushes and
   xcodebuild/codesign/devicectl for installs. Add the wrapper adapter after a
   real device exercise of the Impactor/plumesign path.
4. Real AOT compilation is orchestration only; the existing scripts are unchanged.
5. Free Apple IDs: 3 apps/device and 7-day profiles; reinstall to refresh.
6. Windows launcher (task-19) reuses the same library-IPA + Documents-data split.
7. Localized chrome only: pipeline output (stage details, task titles, Apple
   signing messages, raw CLI/devpush logs) is produced by the backends and stays
   in its original English wording by design. Buttons, labels, empty states,
   settings, dialogs and the static hints are fully localized in both languages.
8. The headless language evidence forces the Settings override (the VM has no Aqua
   session to change the system language live); the system-language path itself is
   covered by the self-check (preferred-language resolution) instead of a GUI run.

## 9. Build and test evidence (task-29 UI revision, 2026-11-15)

Environment: macOS 26.7.3 VM (8 vCPU / 12 GB, QEMU on the CachyOS host), Xcode
26.6 (17F113), xcodegen 2.46.0, no Aqua GUI session, no Apple ID signing assets,
no attached iPhone/iPad. Launcher sources were synced to ~/3ds2apple on the VM and
built over SSH (Release).

Commands (launcher/macos/scripts/vm-build.sh):

    PATH=/usr/local/bin:$PATH xcodegen generate --spec project.yml
    xcodebuild -project 3ds2apple-launcher.xcodeproj -scheme 3ds2apple-launcher \
      -configuration Release -destination 'platform=macOS' -derivedDataPath build build
    <app>/Contents/MacOS/3ds2apple-launcher --selfcheck
    <app>/Contents/MacOS/3ds2apple-launcher --screenshot-dir screenshots --theme dark  --lang all --mock
    <app>/Contents/MacOS/3ds2apple-launcher --screenshot-dir screenshots --theme light --lang all --mock
    ditto -c -k --sequesterRsrc --keepParent 3ds2apple-launcher-0.2.0-macos-universal <zip>

Results:

- xcodebuild: BUILD SUCCEEDED, Release, 0 errors. Universal binary
  (lipo: x86_64 arm64), 7,506,784-byte executable; bundle id
  com.kratos.3ds2apple.launcher; version 0.2.0 (build 2).
  Non-blocking warnings only: pre-existing CommandRunner Sendable/NSLock
  Swift-6-mode notes and the traditional-headermap warning.
- App icon: Contents/Resources/AppIcon.icns (1,273,753 bytes, 11 PNG sizes,
  verified with an iconutil round-trip) + AppIcon-1024.png, generated from
  ios/app/Assets.xcassets/AppIcon.appiconset/icon-1024.png. Localized app name:
  en.lproj "3ds2apple Launcher", zh-Hans.lproj "3ds2apple 启动器" (read back with
  PlistBuddy in the build log).
- Self-check: 108/108 passed (exit 0): the 71 original launcher checks plus 37 new
  localization checks (system language resolution including zh-Hant -> English
  fallback, both string tables complete, iOS-shell terminology, localized enum
  labels/format helpers, persisted override with unknown-value fallback, and the
  new --lang CLI option).
- Screenshots: 16 non-game PNGs at 2x, SwiftUI ImageRenderer drawn offscreen,
  English + Simplified Chinese, dark + light, no game pixels:

| File | Content |
|---|---|
| [library-populated en dark](../launcher/macos/screenshots/launcher-library-dark-en.png) / [zh](../launcher/macos/screenshots/launcher-library-dark-zh.png) | Library grid: AOT-ready + IN LIBRARY with Push action, queued game with Build action, failed game with error, on-device library card |
| [library-empty dark](../launcher/macos/screenshots/launcher-library-empty-dark-en.png) / [light](../launcher/macos/screenshots/launcher-library-empty-light-en.png) | empty-library state with one Import CTA |
| [import en dark](../launcher/macos/screenshots/launcher-import-dark-en.png) / [zh dark](../launcher/macos/screenshots/launcher-import-dark-zh.png) | Import drop card, detected NCSD header, one Queue button, next-steps card |
| [import light en](../launcher/macos/screenshots/launcher-import-light-en.png) / [light zh](../launcher/macos/screenshots/launcher-import-light-zh.png) | light appearance of Import |
| [build-running dark](../launcher/macos/screenshots/launcher-build-running-dark-en.png) | Library while an AOT build runs (busy bar + progress card) |
| [game-detail dark](../launcher/macos/screenshots/launcher-game-detail-dark-en.png) | per-game dialog: package details, Documents push plan with progress, logs, actions |
| [settings en dark](../launcher/macos/screenshots/launcher-settings-dark-en.png) / [zh dark](../launcher/macos/screenshots/launcher-settings-dark-zh.png) / [en light](../launcher/macos/screenshots/launcher-settings-light-en.png) / [zh light](../launcher/macos/screenshots/launcher-settings-light-zh.png) | Settings panel: language, Apple ID/Team ID, device, build mode, sign & install, tools, diagnostics, logs, About (app icon) |

The light-theme Library variants are also in the folder
([en](../launcher/macos/screenshots/launcher-library-light-en.png) /
[zh](../launcher/macos/screenshots/launcher-library-light-zh.png)).

- Package (not committed; on the DSH/WSL host):
  /mnt/f/temp_transfer/dist/macos-ui/3ds2apple-launcher-0.2.0-macos-universal.zip
  (9,302,168 bytes, sha256 9df2529cda69012c6bd09eed57aba58d33ceccceebb5a9704716b1e391a4f7f7)
  plus a short README.md and .sha256 sidecar. The zip contains the .app, the 16
  screenshots, README.md and PACKAGE-README.txt.
- Package verification: unzip -t OK; a fresh extraction on the VM ran
  --selfcheck 108/108 and rendered the zh screenshots; lipo reports x86_64 arm64;
  CFBundleShortVersionString 0.2.0, CFBundleIconFile AppIcon; content listing has
  no .cci/.3ds/.ipa/.dylib/GameRom/GamePack entries.
- Device-bridge contract probe (real tools/devpush release binary, mock backend,
  no device) from task-18 still applies: capabilities, devices, app-attr, mkdir,
  two puts (GameRom.cci then GameInfo.json last), stat, ls and an error path match
  the parser. A real USB device run remains the first follow-up (no device on VM).
- Raw VM logs kept on the build VM: /tmp/zl-launcher-build.log,
  /tmp/zl-launcher-selfcheck.log, /tmp/zl-launcher-shots-*.log, /tmp/zl-vm-build.out.
