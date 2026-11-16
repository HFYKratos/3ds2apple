# macOS launcher (Library -> Deploy v2)

> Status: task-31 v2 flow revision (2026-11-16) · owner: mac-flow-v2 ·
> uncommitted on purpose (Lead review). Backend contracts (desktop CLI, device
> bridge, Xcode signing) are unchanged; this revision is the user-visible flow,
> the minimal Settings panel, the automatic install->push chain using the actual
> installed bundle ID, the IPA verification gate and the app-only package.
>
> Code: [launcher/macos](../launcher/macos) · flow spec:
> [launcher-flow-v2.md](launcher-flow-v2.md) · desktop pipeline:
> [desktop-aot.md](desktop-aot.md) · device bridge:
> [device-bridge.md](device-bridge.md) · architecture:
> [launcher-architecture.md](launcher-architecture.md)

The macOS launcher is the product front-end for the AOT-first model: the player
imports their own decrypted 3DS ROM into the **Library**, then on the **Deploy**
page selects one or several games and presses **one** button. The launcher
compiles one native GamePack per selected game on this Mac, composes a single
**ROM-free** library IPA containing every selected
Frameworks/GamePack-<TITLEID>.dylib plus a schema-2 GameCatalog.json, verifies
that IPA, signs and installs it with the player's own Apple ID (Xcode automatic
signing + devicectl), and then — automatically, as the next step of the same
action — pushes only each selected GameRom + GameInfo.json into the app's
Documents folder. It verifies the pushed files (size/sha + remote listing) and
finishes with an explicit **Done / 可以打开手机 App 游玩** state.

**Why the split:** iOS refuses to dlopen unsigned code copied into the app
container. Per-game AOT code must live inside the signed app bundle; only data
(GameRom.cci, GameInfo.json) is pushed to Documents/Games/<TITLEID>/. Adding or
removing a game means deploying again (the IPA is re-composed with exactly the
selected packs); ROM data already pushed to Documents is kept across reinstalls.

## 0. TL;DR

Build and run on a Mac with Xcode 15+ (tested with Xcode 26.6):

    cd launcher/macos
    PATH=/usr/local/bin:$PATH xcodegen generate --spec project.yml
    xcodebuild -project 3ds2apple-launcher.xcodeproj -scheme 3ds2apple-launcher \
      -configuration Release -destination 'platform=macOS' -derivedDataPath build build
    open build/Build/Products/Release/3ds2apple-launcher.app

Release builds are universal (arm64 + x86_64). Headless (CI-like) checks,
screenshots and the app-only ZIP on the shared build VM:

    bash scripts/vm-build.sh

It writes the user-facing artifact to **out/launchers/** (gitignored):
`3ds2apple-launcher-<version>-macos-app.zip` — one .app, nothing else (no
screenshots, README or game/build data inside the ZIP). The screenshots are
checked in under [launcher/macos/screenshots](../launcher/macos/screenshots) as
non-game UI evidence. Pure SwiftUI, no third-party dependencies, Apache-2.0. The
launcher never implements signing, Apple-ID authentication or USB/AFC itself.

## 1. User flow (v2)

Navigation is exactly two top-level sections plus a gear:

| Area | Content |
|---|---|
| Library (游戏库) | Import a decrypted .3ds/.cci (drag/drop or picker in a sheet), list the games, rename or remove each one. No build/install/push buttons here. |
| Deploy (导入手机) | The selection list with checkboxes (one or several games), the target device, **一键部署 / Deploy selected** and the ordered step list + log: check device & Apple ID -> compile GamePacks -> compose one ROM-free IPA -> verify IPA (real packs + schema-2 GameCatalog, no ROM) -> sign & install -> push each ROM+GameInfo -> verify -> Done ("可以打开手机 App 游玩"). |
| Settings (gear) | Only language, Apple ID/Xcode signing status (read-only, auto-detected Team ID), device status + installed app ID, logs (export/clear) and About/version. |

The button always runs the whole chain in order; there is no way to install the
bare shell or to install first and push later by hand. Import is a sheet of the
Library, not a top-level tab. Build modes, sign/install strategies, tool paths,
Team ID input, device UDID and bundle-ID overrides are removed from the UI:

- tools (3ds2apple-pack, devpush, xcodegen) are auto-detected inside the app
  bundle, the checkout and PATH;
- the Apple Developer Team ID is read from Xcode's local provisioning profiles
  (Settings -> Accounts owns the account; the launcher never asks for it);
- the bundle ID used for the Documents push is read back from the app that was
  actually installed (build result / device bridge confirmation), never from a
  template or a stale persisted value.

## 2. Deploy pipeline (single action)

    1. preflight: Apple ID signing assets + detected Team ID; a paired device;
       staged game data exists for every selected library game
    2. batch compile: 3ds2apple-pack build --queued --execute for the selected
       title IDs (real local AOT build; fake packs only in mock/self-check mode);
       every GameInfo.json must report a real macho pack
    3. compose: xcodebuild the signed ROM-free shell .app, then
       3ds2apple-pack pack --title-id <each> --execute --base-app ... ->
       IPA/3ds2apple-library-<n>-games.ipa (Frameworks/GamePack-<TITLEID>.dylib
       + schema-2 GameCatalog.json; no Roms/, no GameRom)
    4. verify IPA (before anything is installed): unpack, read
       CFBundleIdentifier and GameCatalog.json, require schemaVersion 2, a
       catalogue entry and the Frameworks/GamePack-<TITLEID>.dylib file for every
       selected title, and refuse any bundled ROM (Roms/ or romFile entries)
    5. sign & install: codesign the embedded GamePacks + app with the local
       Apple Development identity, xcrun devicectl device install app; the
       actual installed bundle ID is read back from the app's Info.plist and
       confirmed through the device bridge
    6. push: for each selected game, mkdir Documents/Games/<TITLEID>, put
       GameRom.<ext>, stat (size), put GameInfo.json LAST, stat, app-attr and ls
       verification — all with the actual installed bundle ID
    7. Done: the report shows every step succeeded; the UI says
       "可以打开手机 App 游玩 / Ready to play"

Failures leave the Deploy page on the failing step with the message + hint and a
Retry button; a failed compile, an invalid IPA or a failed install never reaches
the push, and a failed compile never installs anything.

## 3. Architecture

    +--------------------------- macOS launcher (SwiftUI) --------------------------+
    | Library: Import/Detect/Rename/Remove   Deploy: batch compile + compose +      |
    |                                        verify + install + push + verify      |
    |  PackCLI (typed JSON)   InstallBackend        PushPlanner + DevpushCLI        |
    +------|-----------------------|---------------------------|-------------------+
           v                       v                           v
     3ds2apple-pack          xcodebuild/codesign/devicectl   tools/devpush (AFC)
     (builder/pack)          + IPA inspection                usbmuxd/house_arrest
           |                       |                           |
           v                       v                           v
      out/packages/         IPA/3ds2apple-library-*.ipa    Documents/Games/TITLEID/
      GamePack.dylib        (shell+packs+catalog, signed)   GameRom.cci + GameInfo.json

Components (launcher/macos/Sources):

| File | Responsibility |
|---|---|
| LauncherMain.swift | entry point: SwiftUI app, --selfcheck, --screenshot-dir |
| AppModel.swift | state machine: library management + the one-click Deploy chain; tasks/logs; mock seeding |
| Models.swift | value types (game, task, deploy report, IPA inspection, device, push plan, readiness, failures) |
| LauncherSettings.swift | small persisted state: language, checkout/out paths, installed library + installed bundle ID |
| CommandRunner.swift | async Foundation.Process wrapper with streamed lines and cancellation; mock runner |
| Toolchain.swift | auto-detected tool paths + environment probe + Team ID detection from Xcode's local state |
| PackBackend.swift | desktop-CLI wrapper (rom inspect, packages add/list/verify, build, pack library IPA) + JSON parsing |
| GameInfoWriter.swift | ROM-oriented Documents GameInfo.json (pack object informational) |
| PushPlanner.swift | Documents/Games plan: GameRom + GameInfo (last); no dylib |
| InstallBackend.swift | shell build, IPA inspection (packs + schema-2 catalog + no ROM), codesign + devicectl install, actual bundle ID read-back, Apple error mapper |
| DeviceBridge.swift | devpush/1 NDJSON client + unavailable bridge |
| MockBackends.swift | deterministic fixtures + mock CLI/installer/bridge used by mock, self-check and screenshots |
| SelfCheck*.swift | headless logic + flow + i18n checks (PASS/FAIL lines) |
| Localization.swift | LauncherLanguage resolution + complete English / zh-Hans string tables |
| SnapshotRenderer.swift | offscreen SwiftUI ImageRenderer screenshots (en+zh, dark+light) |
| Views/ | theme, components, two-section shell, Library, Deploy, minimal Settings, Import sheet |
| Resources/ | app icon (.icns/.png, from the iOS icon) + en / zh-Hans InfoPlist.strings |
| scripts/vm-build.sh | Release build + self-check + screenshots + app-only ZIP under out/launchers |

## 4. Backend contracts (unchanged)

### 4.1 Desktop CLI: 3ds2apple-pack

The launcher never writes package metadata itself; builder/pack is the single
writer of GameInfo.json / GameCatalog.json. Commands used (--json, --out OUT):

    rom inspect ROM --json
    packages add --roms ROM --json          (no --include-rom: packages stay ROM-free)
    packages list --json
    build --queued [--execute] --json
    pack --title-id ID (repeatable) --execute --base-app APP --ipa-out DIR --ipa-name NAME --json
        (allocates the selected built packages into the shell app and runs
         scripts/build-multi-game-ipa.sh; the IPA carries Frameworks/GamePack-*.dylib
         + GameCatalog.json only, never Roms/ or GameRom)

Errors surface with the CLI exit code (0 ok, 1 validation/failure, 2 usage) and
the last meaningful output line as hint. Everything stays inside out/, build/ and
IPA/ (all gitignored).

### 4.2 AOT build

The Deploy chain runs 3ds2apple-pack build --queued --execute for the selected
title IDs, which drives scripts/build-recomp-ios.sh (ROM -> generated C) and the
pack link (arm64 GamePack.dylib + package record). Mock mode writes labelled
placeholder packs; the Deploy chain refuses any manifest whose pack format is not
a real "macho", so a preview pack can never be installed. Dry-run/fake build
modes are no longer user-visible.

### 4.3 Shell + library install (Xcode signing + devicectl)

    xcodegen generate (ios/app)
    xcodebuild -project ios/app/3ds2apple.xcodeproj -scheme 3ds2apple \
      -configuration Debug -destination 'generic/platform=iOS' \
      -derivedDataPath build/launcher-shell \
      CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
      DEVELOPMENT_TEAM=<detected team id> -allowProvisioningUpdates build
    3ds2apple-pack pack --title-id ... --execute --base-app <built .app> \
      --ipa-out IPA --ipa-name 3ds2apple-library-<n>-games
    unzip IPA/3ds2apple-library-<n>-games.ipa -d <temp>
      # verify: Payload/*.app/Info.plist CFBundleIdentifier,
      #         GameCatalog.json schemaVersion 2 + one game per selected title,
      #         Frameworks/GamePack-<TITLEID>.dylib exists for every selected title,
      #         no Roms/ and no romFile entries
    codesign -f -s <Apple Development identity> <app>/Frameworks/GamePack-*.dylib
    codesign -f -s <Apple Development identity> [--entitlements <from signed app>] <app>
    codesign --verify --deep --strict <app>
    xcrun devicectl device install app --device <UDID> <app>
    # read back CFBundleIdentifier from the installed app's Info.plist; persist it

Readiness checks are shown on Deploy/Settings: xcodebuild version, xcode-select
path, xcrun devicectl, security find-identity count, provisioning profile count,
detected Team ID (from provisioning profiles; certificate subject as fallback),
and the shell runtime build/ios/libzakuro_ios.a. Certificate names/identities are
never logged.

Apple signing errors are translated to plain language by AppleErrorMapper (same
table as before: 9120, 9401, no certificate, no profile, missing team, not signed
in, Developer Mode, code signature/AMFI, free-account app limit, locked/unpaired
device, expired profile).

### 4.4 Documents push (devpush/1, automatic after install)

Only game data is pushed; the AOT code is already in the signed IPA. The bridge
(task-16/20, tools/devpush) speaks NDJSON with --json, schema devpush/1, stable
exit codes and a 90 s stall watchdog.

Commands used, all --json --container app:

    devices                          device list
    app-attr --bundle-id ID          installed / file sharing / version
    mkdir --bundle-id ID --path P    idempotent directory creation
    put --bundle-id ID --local F --remote P
                                     begin/progress/done {remotePath,bytes,sha256}
    stat --bundle-id ID --path P     remote size check after each put
    ls --bundle-id ID --path DIR     remote listing for verification

Push algorithm per game (2 files, manifest last), using the **actual installed
bundle ID** from step 4.3—not the template manifest value:

1. resolve the staged ROM copy (out/launcher-roms/<TITLEID>.<ext>) and write the
   GameInfo.json staging file;
2. mkdir Documents/Games/TITLEID;
3. put GameRom.cci, then put GameInfo.json LAST; stream progress; after each put
   stat the remote size and compare with the local file; persist the actual
   bundle ID;
4. app-attr confirms the installed app; ls confirms both file names; only then is
   the game marked on device and the Deploy report Done.

The game must be in the composed IPA; the compose step always includes exactly
the selected games, so a mismatch cannot silently happen. ROM data already
pushed stays on the phone when the IPA is reinstalled; a clean install (removed
app) requires deploying again.

### 4.5 On-device layout and GameInfo.json

    <signed app bundle>/
      Frameworks/GamePack-<TITLEID>.dylib    AOT code (signed with the app)
      GameCatalog.json                       schema 2: titleID -> packFile/packABIVersion/...
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
     "launcherVersion":"0.2.1",
     "pushedAt":"...Z",
     "rom":{"file":"GameRom.cci","size":1446201088,"sha256":"..."},
     "pack":{"file":"Frameworks/GamePack-0004000000055E00.dylib","size":...,"sha256":"...","inBundle":true,"sourceFile":"GamePack.dylib"},
     "requiresFileSharing":true,"notes":""}

The shell loads the pack from the bundle catalog (the pack object is
informational) and the ROM from Documents; it verifies the ROM size/sha256 and
shows a per-game "Data missing" state until the push verifies. ROM data is never
put into the IPA.

## 5. Modes

| Mode | How | What it does |
|---|---|---|
| Live | normal app launch | real CLI, real Xcode/codesign/devicectl, real devpush |
| Mock | --selfcheck, --screenshot-dir | deterministic fixtures; no ROM, phone, Apple ID or network |

The sidebar always shows MOCK / DRY RUN vs LIVE so a demo can never be mistaken
for a real device run. Build/install modes are not user-selectable any more.

## 6. Build and test on the macOS VM

Environment: macOS 26.7.3 VM (8 vCPU, 12 GB, QEMU), Xcode 26.6 (17F113),
xcodegen 2.46.0, no Aqua GUI session, no Apple ID signing assets, no attached
iPhone. The app is built and exercised headlessly; UI is drawn offscreen with
SwiftUI ImageRenderer.

    cd ~/3ds2apple/launcher/macos
    bash scripts/vm-build.sh

The script runs xcodegen, xcodebuild -configuration Release (universal), the
self-check, the dark/light + en/zh screenshots and builds
out/launchers/3ds2apple-launcher-<version>-macos-app.zip (only the .app inside).

## 7. Manual device test (not executable on the shared VM)

Prerequisites: a Mac with Xcode signed in to the player's own Apple ID; iPhone/iPad
on iOS 17+ with Developer Mode; USB cable; the 3ds2apple checkout with
build/ios/libzakuro_ios.a built; decrypted ROMs the player owns.

1. Library -> Import a ROM -> it appears in the list (rename/remove optional).
2. Deploy -> select one or two games -> press 一键部署 / Deploy selected.
3. Expected: preflight shows the detected Team ID and device; step 2 builds the
   GamePacks; step 3 composes one IPA; step 4 reports "N pack(s), schema-2
   catalogue, no ROM"; step 5 installs and shows the actual installed bundle ID;
   step 6 pushes GameRom + GameInfo per game; step 7 says
   可以打开手机 App 游玩 / Ready to play.
4. Device triage: 9120 -> re-sign-in Xcode Accounts; 9401 -> trust/Developer
   Mode/free-account limit; "no signing assets" -> add Apple ID in Xcode;
   device not found -> cable/Trust/unlock; push stall -> reconnect and retry
   (the push is idempotent, GameInfo goes last).
5. Releasing ROMs: re-deploy with a different selection re-composes the IPA;
   pushed Documents data is kept. After a clean app reinstall re-deploy to push
   the data again.
6. Cleanup: no ROM/IPA/dylib/GameInfo.json from a test may be committed to git.

## 8. Privacy, security, licensing

- No Apple ID, password, certificate name, provisioning profile or device UDID is
  stored or logged by the launcher. Signing is Xcode automatic signing with the
  player's own account; the launcher detects the Team ID and uses the local
  identity hash for codesign.
- The actual installed bundle ID is not a secret: it is read back from the
  installed app and persisted only to drive the Documents push.
- Logs are local (~/Library/Application Support/3ds2apple-launcher/launcher.log)
  and pass a redactor that replaces UDID-shaped, SHA-1-shaped and e-mail-shaped
  values before storing/exporting.
- ROM copies (out/launcher-roms), packages, IPAs and generated C stay in
  gitignored directories; only the launcher's own source, docs and non-game UI
  screenshots are committed.
- The launcher contains no third-party code. S2Arm-study (Apache-2.0) was read as
  an architectural reference only; no source was copied. Signing is Apple tooling;
  official Impactor is never bundled. Repository license: Apache-2.0.

## 9. Known limitations / next steps

1. Device-attached end-to-end (install + push + shell launch) is not verified on
   the shared VM: no phone and no Apple ID there. Section 7 is the acceptance
   procedure.
2. devpush integration is contract-level on the VM: the parser matches the real
   tools/devpush --mock-dir events/exit codes and the mock bridge drives the full
   deploy chain in the self-check; a real USB run is the first follow-up.
3. Real AOT compilation is orchestration only; the scripts are unchanged.
4. Free Apple IDs: 3 apps/device and 7-day profiles; reinstall to refresh.
5. Minimal Settings shows read-only signing/device state; it does not embed
   Impactor. Impactor-based manual signing stays a documented alternative, not a
   launcher flow.
6. Localized chrome only: pipeline output (step details, Apple signing messages,
   raw CLI/devpush logs) is produced by the backends and stays in its original
   English wording by design.
7. Offscreen ImageRenderer screenshots occasionally show minor badge-spacing
   artifacts (the same view tree renders normally in the live app); the evidence
   PNGs are mock/non-game only.

## 10. Build and test evidence (task-31 v2 flow, 2026-11-16)

Environment: macOS 26.7.3 VM (8 vCPU / 12 GB, QEMU on the CachyOS host), Xcode
26.6 (17F113), xcodegen 2.46.0, no Aqua GUI session, no Apple ID signing assets,
no attached iPhone/iPad. Sources were synced to ~/3ds2apple on the VM and built
over SSH with launcher/macos/scripts/vm-build.sh.

Results:

- xcodebuild: BUILD SUCCEEDED, Release, 0 errors. Universal binary
  (lipo: x86_64 arm64), 7,141,296-byte executable; bundle id
  com.kratos.3ds2apple.launcher; version 0.2.1 (build 3).
- Self-check: **132/132 passed** (exit 0): CLI/JSON/GameInfo/push-plan checks,
  library-IPA inspection rules (missing pack, schema-1/empty catalogue, selected
  title missing, bundled ROM, missing bundle ID), Team ID detection, devpush
  contract, Apple-error translation, log redaction, library rename/remove and the
  full mock Deploy chain (success + never-install-bare-shell failure paths + retry
  + invalid-IPA refusal), plus 45+ localization checks (system language resolution,
  both tables complete, v2 Library/Deploy terminology, one-click deploy and
  "可以打开手机 App 游玩" wording, persisted override).
- Screenshots: 20 non-game PNGs at 2x, SwiftUI ImageRenderer drawn offscreen,
  English + Simplified Chinese, dark + light, no game pixels:
  library (populated/empty), import sheet, deploy selection, deploy running,
  deploy done, deploy failed, minimal Settings.

| Evidence | Files |
|---|---|
| Library | [dark en](../launcher/macos/screenshots/launcher-library-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-library-dark-zh.png) · [light en](../launcher/macos/screenshots/launcher-library-light-en.png) · [empty](../launcher/macos/screenshots/launcher-library-empty-dark-en.png) |
| Import sheet | [dark en](../launcher/macos/screenshots/launcher-import-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-import-dark-zh.png) |
| Deploy selection | [dark en](../launcher/macos/screenshots/launcher-deploy-selected-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-deploy-selected-dark-zh.png) |
| Deploy running | [dark en](../launcher/macos/screenshots/launcher-deploy-running-dark-en.png) |
| Deploy Done | [dark en](../launcher/macos/screenshots/launcher-deploy-done-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-deploy-done-dark-zh.png) |
| Deploy failed + Retry | [dark en](../launcher/macos/screenshots/launcher-deploy-failed-dark-en.png) |
| Minimal Settings | [dark en](../launcher/macos/screenshots/launcher-settings-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-settings-dark-zh.png) · [light en](../launcher/macos/screenshots/launcher-settings-light-en.png) |

- User-facing artifact (gitignored, project tree only — not temp_transfer):
  `out/launchers/3ds2apple-launcher-0.2.1-macos-app.zip`
  (3,978,571 bytes,
  sha256 `07b7956695a0a948dc623d9df6a17e0adfbe8c46967a2b2f45608748d9217b8e`),
  plus its `.sha256` sidecar. The ZIP contains exactly one
  3ds2apple-launcher.app (13 entries, 9,139,716 bytes uncompressed): binary
  (x86_64 + arm64), Info.plist, PkgInfo, AppIcon.icns/png, en + zh-Hans
  InfoPlist.strings. No screenshots, README, ROM, IPA, dylib or game data.
- Package verification: unzip -t OK; a fresh extraction ran --selfcheck 132/132
  and rendered the zh screenshots on the VM; lipo reports x86_64 arm64; version
  0.2.1 build 3.
- Raw VM logs kept on the build VM: /tmp/zl-launcher-build.log,
  /tmp/zl-launcher-selfcheck.log, /tmp/zl-launcher-shots-*.log,
  /tmp/zl-launcher-shots.tgz.
