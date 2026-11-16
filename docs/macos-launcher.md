# macOS launcher (Library -> Deploy v2, launcher 0.2.4)

> Status: launcher 0.2.4 build 7 (2026-11-16) · owner: macos-launcher ·
> uncommitted on purpose (Lead review). This revision syncs the macOS launcher
> with the Windows launcher 0.2.4: a portable data folder beside the .app (with
> Application Support fallback and one-time migration from <checkout>/out), ROM
> SMDH metadata on the Library cards (pack-CLI cover.png icon, 12-language
> displayNames following the app language, publisher; no editable name input),
> a detected compile-hardware line (logical cores / RAM / 3dsrecomp's automatic
> full-core parallelism) and the library restore from the workspace on launch.
> It builds on the task-35 MoltenVK revision (Frameworks/MoltenVK.framework is
> copied into the shell .app before signing: hardware PICA200 renderer + system
> Metal HUD) and keeps the v2 install->push chain and backend contracts.
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
| Library (游戏库) | One **导入 / Import** button opens the file picker and imports the chosen decrypted .3ds/.cci (no path/name fields, no explanatory card, no import sheet). Cards show the ROM's own SMDH icon extracted by the pack CLI (packages/<TITLEID>/cover.png, initials placeholder when the ROM has no icon), the localized SMDH title for the current app language, the publisher, phases and sizes; only **Refresh / Remove** are offered (no editable name input). No build/install/push buttons here. |
| Deploy (导入手机) | The selection list with checkboxes (one or several games), the target device, the detected compile-hardware line (N logical cores · X GB RAM · 3dsrecomp auto-parallelizes N jobs, memory-budgeted), **一键部署 / Deploy selected** and the ordered step list + log: check device & Apple ID -> compile GamePacks -> compose one ROM-free IPA -> verify IPA (real packs + schema-2 GameCatalog, no ROM) -> sign & install -> push each ROM+GameInfo -> verify -> Done ("可以打开手机 App 游玩"). |
| Settings (gear) | Only language, Apple ID/Xcode signing status (read-only, auto-detected Team ID), device status + installed app ID, logs (export/clear) and About/version. |

The button always runs the whole chain in order; there is no way to install the
bare shell or to install first and push later by hand. The two sections are
centered tabs in the header (no sidebar); Import is a single Library button, not
a top-level tab or a sheet. Readiness is probed automatically on every launch
and kept as a green/red light in the header (details in the tooltip and log).
Build modes, sign/install strategies, tool paths,
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
       <portable-data>/ipa/3ds2apple-library-<n>-games.ipa
       (Frameworks/GamePack-<TITLEID>.dylib + schema-2 GameCatalog.json;
       no Roms/, no GameRom)
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
    | Library: Import/Detect/Remove (SMDH name+icon+publisher)                       |
    | Deploy: batch compile + compose + verify + install + push + verify             |
    |  PackCLI (typed JSON)   InstallBackend        PushPlanner + DevpushCLI        |
    +------|-----------------------|---------------------------|-------------------+
           v                       v                           v
     3ds2apple-pack          xcodebuild/codesign/devicectl   tools/devpush (AFC)
     (builder/pack)          + IPA inspection                usbmuxd/house_arrest
           |                       |                           |
           v                       v                           v
  <data>/workspace/packages/  <data>/ipa/3ds2apple-library-*.ipa  Documents/Games/<TITLEID>/
  GamePack.dylib + cover.png  (shell+packs+catalog, signed)     GameRom.cci + GameInfo.json

  <data> = <folder containing the .app>/3ds2apple-data (portable), or
           ~/Library/Application Support/3ds2apple (read-only app folder fallback)

Components (launcher/macos/Sources):

| File | Responsibility |
|---|---|
| LauncherMain.swift | entry point: SwiftUI app, --selfcheck, --screenshot-dir |
| AppModel.swift | state machine: library management + the one-click Deploy chain; tasks/logs; mock seeding |
| Models.swift | value types (game, task, deploy report, IPA inspection, device, push plan, readiness, failures) |
| PortableData.swift | portable data root: beside the .app first, Application Support fallback, one-time <checkout>/out + old-log migration |
| Hardware.swift | detected logical/physical cores and RAM; 3dsrecomp's auto-parallelism (report only, no jobs flag) |
| LauncherSettings.swift | small persisted state: language, checkout, portable data root, installed library + installed bundle ID |
| CommandRunner.swift | async Foundation.Process wrapper with streamed lines and cancellation; mock runner |
| Toolchain.swift | auto-detected tool paths + environment probe + Team ID detection from Xcode's local state |
| PackBackend.swift | desktop-CLI wrapper (rom inspect, packages add/list/verify, build, pack library IPA) + JSON parsing including displayNames/publisher/coverPath |
| GameInfoWriter.swift | ROM-oriented Documents GameInfo.json (pack object informational) |
| PushPlanner.swift | Documents/Games plan: GameRom + GameInfo (last); no dylib |
| InstallBackend.swift | shell build, IPA inspection (packs + schema-2 catalog + no ROM), MoltenVK embedding + nested signing, codesign + devicectl install, actual bundle ID read-back, Apple error mapper |
| ShellRuntime.swift | pinned MoltenVK.framework source (launcher-embedded / build/third_party / pinned template IPA), copy into the built shell .app and Metal/HUD readiness verification |
| DeviceBridge.swift | devpush/1 NDJSON client + unavailable bridge |
| MockBackends.swift | deterministic fixtures + mock CLI/installer/bridge used by mock, self-check and screenshots |
| SelfCheck*.swift | headless logic + flow + i18n checks (PASS/FAIL lines) |
| Localization.swift | LauncherLanguage resolution + complete English / zh-Hans string tables |
| SnapshotRenderer.swift | offscreen SwiftUI ImageRenderer screenshots (en+zh, dark+light) |
| Views/ | theme, components, header with centered tabs + readiness light, Library, Deploy, minimal Settings |
| Resources/ | app icon (.icns/.png, from the iOS icon) + en / zh-Hans InfoPlist.strings |
| scripts/vm-build.sh | Release build + self-check + screenshots + app-only ZIP under out/launchers |

## 4. Backend contracts (unchanged)

### 4.1 Desktop CLI: 3ds2apple-pack

The launcher never writes package metadata itself; builder/pack is the single
writer of GameInfo.json / GameCatalog.json. Commands used (--json, --out OUT):

    rom inspect ROM --json                  (titleID/displayName/displayNames/publisher/bytes)
    packages add --roms ROM --json          (no --display-name and no --include-rom: the CLI
                                             keeps the ROM's own SMDH title and the package
                                             stays ROM-free; JSON adds displayNames,
                                             publisher, coverPath)
    packages list --json                    (same SMDH metadata per package)
    build --queued [--execute] --json
    pack --title-id ID (repeatable) --execute --base-app APP --ipa-out DIR --ipa-name NAME --json
        (allocates the selected built packages into the shell app and runs
         scripts/build-multi-game-ipa.sh; the IPA carries Frameworks/GamePack-*.dylib
         + GameCatalog.json only, never Roms/ or GameRom)

Errors surface with the CLI exit code (0 ok, 1 validation/failure, 2 usage) and
the last meaningful output line as hint. Everything the launcher writes stays
inside the portable data root (<data>/workspace, /ipa, /build, /staging, /logs);
the pack CLI's own build scratch under <checkout>/build is regenerable and
gitignored.

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
      -derivedDataPath <data>/build/launcher-shell \
      CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
      DEVELOPMENT_TEAM=<detected team id> -allowProvisioningUpdates build
    # launcher: copy Frameworks/MoltenVK.framework (pinned 4,822,128 B, sha256
    # 6cd58884…) into the built .app, sign the nested framework + re-seal the
    # app (hardware renderer + CAMetalLayer Metal HUD); the deploy is refused
    # if the shell is not Metal/HUD ready
    3ds2apple-pack pack --title-id ... --execute --base-app <built .app> \
      --ipa-out <data>/ipa --ipa-name 3ds2apple-library-<n>-games
    unzip <data>/ipa/3ds2apple-library-<n>-games.ipa -d <data>/build/ipa-inspect
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

1. resolve the staged ROM copy (<portable-data>/workspace/launcher-roms/
   <TITLEID>.<ext>) and write the GameInfo.json staging file;
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
     "launcherVersion":"0.2.2",
     "pushedAt":"...Z",
     "rom":{"file":"GameRom.cci","size":1446201088,"sha256":"..."},
     "pack":{"file":"Frameworks/GamePack-0004000000055E00.dylib","size":...,"sha256":"...","inBundle":true,"sourceFile":"GamePack.dylib"},
     "requiresFileSharing":true,"notes":""}

The shell loads the pack from the bundle catalog (the pack object is
informational) and the ROM from Documents; it verifies the ROM size/sha256 and
shows a per-game "Data missing" state until the push verifies. ROM data is never
put into the IPA.

### 4.6 Launcher 0.2.4 additions (Windows launcher parity)

**Portable data folder.** Every writable path derives from one root
(PortableData.swift):

1. `<folder containing the .app>/3ds2apple-data/` when writable (portable,
   preferred; a launcher copied to a USB stick keeps its data next to it),
2. `~/Library/Application Support/3ds2apple/` when the app folder is read-only,
   or when macOS runs the app from a read-only AppTranslocation path,
3. a temporary folder only when both are unusable; `THREEDS2APPLE_DATA_DIR`
   overrides the root for QA and the headless self-check.

Layout: `workspace/` (pack CLI `--out` tree + `launcher-roms/` push copies),
`logs/` (`launcher.log`, exported logs), `build/` (signed shell DerivedData and
IPA inspection scratch), `staging/` (GameInfo.json staging) and `ipa/`
(composed library IPAs). On the first launch with the new root the previous
`<checkout>/out` workspace and the old
`~/Library/Application Support/3ds2apple-launcher/launcher.log` are adopted
once: hardlink first (same APFS volume, instant and without extra space even for
multi-GB ROM copies), then a size-limited copy; `work/`, `staging/`, `build/`,
`ipa/` and `logs/` scratch is skipped and a `migration.json` marker records the
result. The legacy tree is never modified. The Library is rebuilt from the
workspace on launch (`restoreLibrary`), so imported games and their SMDH
metadata, packs and staged ROM copies survive restarts.

**ROM SMDH metadata.** `rom inspect`, `packages add`, `packages list` and
GameInfo.json now carry `displayNames` (BCP-47 map of the up-to-12 SMDH
languages: en, ja, fr, de, it, es, zh-Hans, ko, nl, pt, ru, zh-Hant),
`publisher` and a package-relative `cover.png` (extracted SMDH icon). The
Library card shows the cover icon, the title matching the UI language
(`zh-Hans`/`en`; fallback chain: exact language -> English -> displayName -> any
entry; `zh-Hant` intentionally falls back to English) and a `Publisher: …`
line; the editable name input and the rename flow are removed (Windows 0.2.4
semantics). A game whose ROM has no SMDH icon keeps the initials placeholder.
Packages imported with an older CLI only have `displayName`: re-importing the
same ROM from the Library passes `3ds2apple-pack packages add --force`
automatically, so the package is refreshed in place (SMDH names/publisher
recorded, an old/incorrect cover.png re-extracted, an already built GamePack
kept). A first import never forces. This is the "old scrambled cover" self-heal
path: the user just imports the same ROM again once.

**Compile-hardware line.** The Deploy page and the log report the detected
logical/physical cores and total RAM (Hardware.swift; sysctl
`hw.logicalcpu`/`hw.physicalcpu`/`hw.memsize` with Foundation fallbacks).
3dsrecomp has no jobs flag: it derives its worker count from the logical CPU
count (`std::thread::available_parallelism`) and a free-memory budget, so the
launcher only reports "N logical cores · X GB RAM · 3dsrecomp auto-parallelizes
N jobs, memory-budgeted" and never invents a compile-jobs setting. Batch builds
compile one pack at a time with that automatic full-core parallelism.

## 5. Modes

| Mode | How | What it does |
|---|---|---|
| Live | normal app launch | real CLI, real Xcode/codesign/devicectl, real devpush |
| Mock | --selfcheck, --screenshot-dir | deterministic fixtures; no ROM, phone, Apple ID or network |

The header always shows MOCK / DRY RUN vs LIVE so a demo can never be mistaken
for a real device run. Build/install modes are not user-selectable any more.

## 6. Build and test on the macOS VM

Environment: macOS 26.7.3 VM (8 vCPU, 12 GB, QEMU), Xcode 26.6 (17F113),
xcodegen 2.46.0, no Aqua GUI session, no Apple ID signing assets, no attached
iPhone. The app is built and exercised headlessly; UI is drawn offscreen with
SwiftUI ImageRenderer.

    cd ~/3ds2apple/launcher/macos
    bash scripts/vm-build.sh

The script runs xcodegen, xcodebuild -configuration Release (universal), the
207-check self-check, the dark/light + en/zh screenshots and builds
out/launchers/3ds2apple-launcher-<version>-macos-app.zip (only the .app inside);
it fails on a bundle version/build mismatch. The headless self-check/screenshot
runs with `THREEDS2APPLE_DATA_DIR=/tmp/zl-launcher-data-vm` so the VM tree stays
clean; the live app resolves its own portable root beside the .app.

For launcher 0.2.4 (build 7) the script needs the pinned ROM-free shell template
`out/shell/3ds2apple-shell.ipa` 0.2.3 build 11 (5,487,675 bytes, sha256
831357db…) to embed the pinned Frameworks/MoltenVK.framework. Only the template's
framework bytes are hash-pinned again (MoltenVK 1.4.2, 4,822,128 bytes,
sha256 6cd58884…).

## 7. Manual device test (not executable on the shared VM)

Prerequisites: a Mac with Xcode signed in to the player's own Apple ID; iPhone/iPad
on iOS 17+ with Developer Mode; USB cable; the 3ds2apple checkout with
build/ios/libzakuro_ios.a built; decrypted ROMs the player owns.

1. Library -> Import a ROM -> the card appears with the ROM's SMDH cover icon,
   its localized title for the app language and the publisher (remove optional;
   there is no rename).
2. Deploy -> select one or two games -> press 一键部署 / Deploy selected.
3. Expected: the Deploy page shows the detected hardware line (cores · RAM ·
   3dsrecomp auto-parallelism); preflight shows the detected Team ID and device;
   step 2 builds the GamePacks; step 3 composes one IPA under
   `<portable-data>/ipa`; step 4 reports "N pack(s), schema-2 catalogue, no ROM";
   step 5 installs and shows the actual installed bundle ID; step 6 pushes
   GameRom + GameInfo per game; step 7 says 可以打开手机 App 游玩 / Ready to play.
   Settings > About shows the resolved data folder (portable vs Application
   Support fallback) and the compile hardware.
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
- Logs and exported logs live under the portable data root
  (`<data>/logs/launcher.log`; Application Support fallback when the app folder
  is read-only) and pass a redactor that replaces UDID-shaped, SHA-1-shaped and
  e-mail-shaped values before storing/exporting.
- ROM copies (`<data>/workspace/launcher-roms`), packages, packs, IPAs and
  generated C stay in the data root / gitignored directories; only the
  launcher's own source, docs and non-game UI screenshots are committed.
  SMDH cover.png files are the user's own ROM metadata and are never committed
  either.
- The launcher contains no third-party code. S2Arm-study (Apache-2.0) was read as
  an architectural reference only; no source was copied. Signing is Apple tooling;
  official Impactor is never bundled. Repository license: Apache-2.0.

## 9. Known limitations / next steps

1. Device-attached end-to-end (install + push + shell launch) is not verified on
   the shared VM: no phone and no Apple ID there. Section 7 is the acceptance
   procedure. That is the remaining gap for this revision.
2. The portable-folder policy itself was exercised on the VM through the
   headless resolution/migration self-checks and the /tmp QA override; the live
   "start the .app from Finder/Applications on a real Mac" path and a genuinely
   read-only app folder still need one manual run on a user Mac.
3. The new SMDH cards need packages imported/refreshed with the current pack
   CLI; games imported with an older CLI keep the fallback name/old cover until
   the same ROM is imported again once (the launcher then passes `--force`
   automatically and the pack CLI re-extracts the cover without losing the built
   GamePack).
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
8. The MoltenVK embedding is verified up to the unsigned shell .app (real
   xcodebuild shell + pinned framework copy + Info.plist, 207/207 self-checks in
   launcher 0.2.4).
   Signing the nested MoltenVK.framework on a real device (Xcode/devicectl or
   Windows plumesign) and the actual Metal HUD/FPS on hardware remain device-only
   acceptance items. The packaged launcher carries the framework itself; a
   launcher built with plain xcodebuild (no scripts/vm-build.sh) falls back to
   build/third_party/MoltenVK.framework or the pinned out/shell template in the
   checkout, and the deploy is refused if neither is present.

## 10. Build and test evidence (launcher 0.2.4 + task-35 MoltenVK + task-34, 2026-11-16)

Environment: macOS 26.7.3 VM (8 vCPU / 12 GB, QEMU on the CachyOS host), Xcode
26.6 (17F113), xcodegen 2.46.0, no Aqua GUI session, no Apple ID signing assets,
no attached iPhone/iPad. Sources were synced to ~/3ds2apple on the VM and built
over SSH with launcher/macos/scripts/vm-build.sh. The task-35 build used an
isolated checkout on the same VM (~/3ds2apple-moltenvk, sources synced over
SSH) so the task-34 checkout was untouched.

### launcher 0.2.4 (portable data / SMDH metadata / hardware line, 2026-11-16)

Environment: macOS 26.7.3 VM (8 vCPU / 12 GB, QEMU on the CachyOS host), Xcode
26.6 (17F113), xcodegen 2.46.0, no Aqua GUI session, no Apple ID signing assets,
no attached iPhone/iPad. Sources were synced to ~/3ds2apple over SSH and built
with launcher/macos/scripts/vm-build.sh; the run needed no ROM.

- xcodebuild: BUILD SUCCEEDED (Release), 0 errors; universal binary
  (lipo x86_64 arm64, 7,120,032-byte executable), bundle
  com.kratos.3ds2apple.launcher, version 0.2.4 build 7.
- self-check: **207/207 passed** (exit 0). New groups: portable data root
  (portable win, Application Support fallback, forced fallback, AppTranslocation,
  explicit override, temp last resort, writable probe), one-time migration
  (legacy workspace + cover adopted, build scratch skipped, legacy tree
  untouched, marker written, second run no-op, old log adopted once), ROM SMDH
  JSON contract (rom inspect displayNames/publisher; packages add/list
  displayNames/publisher/coverPath; GameInfo.json metadata + rom.path; legacy
  JSON still parses), name selection per UI language (zh-Hans/zh-CN/en/de/zh-Hant,
  no-map/only-ja fallbacks, publisher trim, cover resolution) and the hardware
  line (detected cores, one job per logical core, 12 GB formatting, localized
  line) and the forced re-import path (a first import does not force; importing a
  ROM that is already in the library passes `--force` so the pack CLI
  re-extracts the SMDH cover in place, logs the flag and keeps one game entry /
  the built GamePack).
- screenshots: 18 non-game PNGs at 2x (English + Simplified Chinese, dark +
  light) with SMDH cover icons, localized titles, publisher lines, the Deploy
  hardware line and Settings showing Version 0.2.4 (6), data folder and compile
  hardware.
- artifact: out/launchers/3ds2apple-launcher-0.2.4-macos-app.zip =
  5,495,796 bytes, sha256
  8c34398f7a25709598626769adc56d146ea89ff9f3718313c7c0d796f719d28b; one .app
  only (16 entries, 13,939,629 bytes uncompressed) including
  Contents/Resources/MoltenVK.framework; a fresh extraction ran 207/207 checks
  and reported x86_64 + arm64, version 0.2.4 build 7.
- shell template: pinned out/shell/3ds2apple-shell.ipa 0.2.3 build 11
  (5,487,675 bytes, sha256 831357db…) — the pin was updated with the shell
  revision; the embedded framework is still the pinned 4,822,128-byte MoltenVK
  1.4.2 dylib (sha256 6cd58884…).
- raw VM logs: /tmp/zl-024-build2.log, /tmp/zl-launcher-selfcheck.log,
  /tmp/zl-launcher-selfcheck-packaged.log, /tmp/zl-launcher-build.log (kept on
  the VM and copied to out/launchers/build-logs-macos-0.2.4/ in the WSL tree).

### task-35 (MoltenVK into the launcher-built shell, launcher 0.2.3 build 5 - historical)

Root cause carried over from shell-aot-hud: the launcher built the iOS shell
itself and never copied MoltenVK.framework, so device deploys ran the software
PICA200 renderer (low fps, no CAMetalLayer/Metal HUD). The fix lives in
ShellRuntime.swift + InstallBackend.buildShellApp: the verified framework is
copied into the shell .app before signing/compose, the nested framework is
signed and the app re-sealed, and installLibrary re-checks + re-signs it.

- Framework pin: Frameworks/MoltenVK.framework/MoltenVK = 4,822,128 bytes,
  sha256 6cd5888490d08b36356d04c50c05e2eda5b9bcb3d0338ece693a28987de96aff
  (MoltenVK 1.4.2 ios-arm64 Mach-O dylib). Pinned template:
  out/shell/3ds2apple-shell.ipa 0.2.2 build 10 = 5,477,984 bytes, sha256
  d05af5a74570f24f5235378f3b2e46a3ecbbdff5a0dce6f8c504d08d8506a5aa.
- Sources in priority order: the launcher's own
  Contents/Resources/MoltenVK.framework (embedded by scripts/vm-build.sh from
  the pinned template), build/third_party/MoltenVK.framework, then the pinned
  out/shell template (extracted read-only). Anything that does not match the
  pin is refused.
- Real-shell proof on the VM: ios/app was built unsigned with xcodebuild
  (** BUILD SUCCEEDED **, 0 errors, 3 pre-existing warnings; shell 0.2.2 build
  10, Info.plist MetalHudEnabled / UIFileSharingEnabled /
  LSSupportsOpeningDocumentsInPlace = true) and had no Frameworks/ directory.
  The launcher's ShellRuntime then copied the pinned framework into that real
  .app and verifyShellApp returned 0 problems (4,822,128-byte framework,
  plist keys intact). This is the exact pre-signing copy the Deploy chain does
  after xcodebuild.
- Deploy guards: composed-IPA inspection requires Frameworks/MoltenVK.framework,
  installLibrary signs the nested framework before the app, and 9 new
  self-check assertions cover source resolution/pin, template integrity,
  copy+verify and refusal of shells without the framework, MetalHudEnabled or
  file sharing.
- Launcher build: xcodebuild BUILD SUCCEEDED (Release), 0 errors, universal
  x86_64 + arm64 (6,720,464-byte executable), com.kratos.3ds2apple.launcher,
  version 0.2.3 build 5.
- Self-check: **151/151 passed** (exit 0); the packaged fresh extraction also
  reported 151/151.
- Artifact: out/launchers/3ds2apple-launcher-0.2.3-macos-app.zip =
  5,350,734 bytes, sha256
  6ffcf9c655342370f1237885115befc00666072af0617c0d6f228f32d5211c3a, only the
  .app (16 entries, 13,540,061 bytes uncompressed) including
  Contents/Resources/MoltenVK.framework; the launcher is self-contained for
  device deploys. 18 screenshots regenerated: 14 byte-identical to task-34 and
  the 4 Settings shots differ only because About now shows 0.2.3.
- Raw VM logs: /tmp/zl-launcher-build.log, /tmp/zl-launcher-selfcheck.log,
  /tmp/zl-launcher-selfcheck-packaged.log, /tmp/zl-package-list.txt,
  /tmp/zl-shell-build.log.

### task-34 (polish, launcher 0.2.2 build 4 - historical)

Results:

- xcodebuild: BUILD SUCCEEDED, Release, 0 errors. Universal binary
  (lipo: x86_64 arm64), 6,541,632-byte executable; bundle id
  com.kratos.3ds2apple.launcher; version 0.2.2 (build 4).
- Self-check: **142/142 passed** (exit 0): all task-31 checks (CLI/JSON/GameInfo/
  push-plan, library-IPA inspection rules, Team ID detection, devpush contract,
  Apple-error translation, log redaction, library rename/remove, the full mock
  Deploy chain and 45+ localization checks) plus the new automatic readiness and
  single-action import assertions: ready fixture is green, a missing tool and
  missing Apple ID signing are red, the launch check turns green automatically,
  is written to the log and refreshes the device list; one Import action stages
  the ROM data and lands the game in the library.
- Screenshots: 18 non-game PNGs at 2x, SwiftUI ImageRenderer drawn offscreen,
  English + Simplified Chinese, dark + light, no game pixels: library
  (populated/empty/red not-ready), deploy selection, deploy running, deploy done,
  deploy failed, minimal Settings. The header shows the centered 游戏库/部署 tabs
  and the persistent green/red readiness light; the Library page has exactly one
  导入 button and no import sheet or explanatory path/name card.

| Evidence | Files |
|---|---|
| Library | [dark en](../launcher/macos/screenshots/launcher-library-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-library-dark-zh.png) · [light en](../launcher/macos/screenshots/launcher-library-light-en.png) · [empty](../launcher/macos/screenshots/launcher-library-empty-dark-en.png) |
| Library, red "未完成准备" light | [dark en](../launcher/macos/screenshots/launcher-library-not-ready-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-library-not-ready-dark-zh.png) |
| Deploy selection | [dark en](../launcher/macos/screenshots/launcher-deploy-selected-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-deploy-selected-dark-zh.png) |
| Deploy running | [dark en](../launcher/macos/screenshots/launcher-deploy-running-dark-en.png) |
| Deploy Done | [dark en](../launcher/macos/screenshots/launcher-deploy-done-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-deploy-done-dark-zh.png) |
| Deploy failed + Retry | [dark en](../launcher/macos/screenshots/launcher-deploy-failed-dark-en.png) |
| Minimal Settings | [dark en](../launcher/macos/screenshots/launcher-settings-dark-en.png) · [dark zh](../launcher/macos/screenshots/launcher-settings-dark-zh.png) · [light en](../launcher/macos/screenshots/launcher-settings-light-en.png) |

- User-facing artifact (gitignored, project tree only — not temp_transfer):
  `out/launchers/3ds2apple-launcher-0.2.2-macos-app.zip`
  (3,864,954 bytes,
  sha256 `fce3c8fd3d71066737eac12c3c4edb73c5c2a75cd96d8c3b285f72f81943833a`),
  plus its `.sha256` sidecar. The ZIP contains exactly one
  3ds2apple-launcher.app (13 entries, 8,538,356 bytes uncompressed): binary
  (x86_64 + arm64), Info.plist, PkgInfo, AppIcon.icns/png, en + zh-Hans
  InfoPlist.strings. No screenshots, README, ROM, IPA, dylib or game data. The
  previous 0.2.1 ZIP remains on disk but is superseded by the task-35 0.2.3
  ZIP (5,350,734 bytes, sha256 6ffcf9c6…).
- Package verification: unzip -t OK; a fresh extraction ran --selfcheck 142/142
  on the VM and reported lipo x86_64 arm64, version 0.2.2 build 4.
- Raw VM logs kept on the build VM: /tmp/zl-polish-build.log,
  /tmp/zl-launcher-selfcheck.log, /tmp/zl-launcher-shots-*.log,
  /tmp/zl-launcher-shots.tgz, /tmp/zl-polish-verify/.
