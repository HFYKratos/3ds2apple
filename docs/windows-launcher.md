# Windows launcher (MVP) — architecture, contracts and test plan

> Status: source-complete MVP skeleton, 2026-11-14 · task-21 (supersedes task-19
> flow) · companion to [windows-build.md](windows-build.md),
> [launcher-architecture.md](launcher-architecture.md),
> [device-bridge.md](device-bridge.md) (task-16/20) and [aot-first.md](aot-first.md).
> Code lives in [launcher/windows](../launcher/windows/README.md).
>
> **Architecture correction (Lead, 2026-11-14):** iOS cannot dlopen a loose,
> unsigned dylib pushed into Documents. GamePack.dylib therefore lives **inside
> the signed app IPA** (Frameworks/GamePack-<TITLEID>.dylib + bundle
> GameCatalog.json); Documents receives only **GameRom.cci + GameInfo.json**.
> Adding/removing a game recomposes and reinstalls the IPA; pushed ROM data is
> expected to persist across an overwrite install/update (a clean uninstall
> clears app data; verify on device). The earlier "push three files incl. the
> dylib" layout is obsolete and removed from this launcher.
>
> Nothing here claims a verified Windows/iPhone session. What was actually
> built/run in this checkout is section 10; the manual steps that still need a
> Windows PC + device are section 11.

## 1. Product flow

One app on the phone holds the whole library. Adding a game means recomposing and
reinstalling the app once; the game's ROM data is then pushed into Documents.

1. **Import** — the user selects a decrypted .3ds/.cci they own. Only headers are
   read (title ID, product code, display name, sizes). The game is queued as a
   package.
2. **Build** — a real GamePack needs Apple's iOS toolchain, so the launcher drives
   the user's macOS Build Agent (existing builder-windows + builder/agent). It
   shows log/progress, downloads the per-game result and adopts
   Frameworks/GamePack-<TITLEID>.dylib through the pack CLI. A clearly-labelled
   local preview build (placeholder; never installable) is also available.
3. **Install / update the app** — the launcher composes the installable IPA
   locally: pinned ROM-free shell template IPA + every built
   Frameworks/GamePack-<TITLEID>.dylib + generated GameCatalog.json (schema v2),
   never any ROM. It then signs and installs the whole IPA with the bundled
   official Impactor v2.7.2 plumesign CLI; IPA signing covers the nested dylibs.
4. **Push ROM data** — only GameRom.cci and GameInfo.json go into
   Documents/Games/<TITLEID>/ through the device bridge CLI (devpush/1), with
   per-file progress, resume-by-size, a 90 s stall watchdog and a read-back size
   verification. GameInfo.json is pushed last; the shell shows "Data missing"
   until the push completes and verifies.

The shell (task-17) loads code from the app bundle and game data from Documents.
No game data is in the IPA; no dylib is in Documents.

## 2. On-device layout

    App bundle (signed by the user's Apple ID via plumesign):
      Payload/3ds2apple.app/
        Frameworks/GamePack-<TITLEID>.dylib     one per built game (code)
        GameCatalog.json                       schema v2: titleID/displayName/productCode/
                                               aot/aotVersion/packFile/packABIVersion=1/
                                               registrationSymbol(default zk_gamepack_register)
        ...shell resources; NO Roms/ entries, NO game data

    Documents/                                  (not part of the IPA; survives an overwrite install/update (a clean uninstall clears app data; verify on device))
      Games/<TITLEID>/                          TITLEID = 16 upper-case hex
        GameRom.cci                             user's decrypted ROM (raw)
        GameInfo.json                           schemaVersion 1; ROM size/sha256 verified;
                                                pack{} is informational / bundle-relative

Adding or removing a game: recompose IPA -> reinstall (overwrite, Documents kept).
Pushing ROM: only the two Documents files per title.

## 3. Prerequisites (Windows)

- Windows 10 22H2 or Windows 11, x86_64.
- Microsoft "Apple Devices" (or iTunes) installed and running: it provides the
  Apple device service on 127.0.0.1:27015 used by the bridge and by plumesign
  (usbmuxd_unavailable is reported when missing).
- USB data cable; phone unlocked; "Trust This Computer?" accepted; Developer Mode
  enabled on the phone (iOS 16+).
- For real AOT builds: a macOS host the user controls with Xcode + the project's
  Build Agent paired (builder/README.md). No Apple SDK is downloaded by this project.
- The user's own, legally acquired, decrypted ROMs.

## 4. Architecture

    launcher/windows/
      Launcher.slnx
      src/ThreeDsTwoApple.Launcher.Core/       no UI; testable without Windows
        LauncherServices.cs                    composition root: locator/workspace/clients
        SelfTest.cs                            --self-test report (CI/WSL + Windows smoke)
        Tools/ProcessRunner.cs                 argv-only runner, UTF-8 lines, timeouts, kill-tree
        Tools/ToolLocator.cs                   env -> Settings -> distribution layout -> PATH
        Tools/PackCli.cs                       inspect/add/list/catalog/record/verify wrappers
        Tools/BuilderCli.cs                    builder-windows build + NDJSON progress
        BuildPipeline/BuildProviders.cs                Preview / MacAgentIpa / MacAgentPack (refuses)
        BuildPipeline/IpaPackExtractor.cs              per-game IPA -> GamePack.dylib adoption (Mach-O checked)
        BuildPipeline/IpaComposer.cs                   template + packs + GameCatalog -> installable IPA
        Signing/ImpactorBundle.cs              pinned Impactor/plumesign verify + launch Impactor
        Signing/AppleErrorCatalog.cs           error text -> stable code + actionable fix
        Signing/PlumeSignRunner.cs             official plumesign argv/runner + success marker
        Signing/ShellInstallService.cs         verify template -> sign+install whole IPA -> retry
        Signing/ShellManifest.cs (in service)  pinned template identity
        Device/DevPushClient.cs                devpush/1 JSON/NDJSON client
        Device/UsbMuxClient.cs                 read-only ListDevices (numeric device id for plumesign)
        Deploy/GameInfoWriter.cs               pushed GameInfo.json (schema 1; pack informational)
        Deploy/GamePush.cs                     2-file push plan (ROM, GameInfo last) + verify service
        LauncherState/LauncherWorkspace.cs         %LOCALAPPDATA%/3ds2apple/launcher state + logs
      src/Launcher.Desktop/                    Avalonia 12.1.5 window: Library/Import, Build,
                                               App & Device, Push, Settings & Diagnostics
      tests/ThreeDsTwoApple.Launcher.Core.Tests/   35 xUnit tests (parsers, composer, signing, push)
      vendor/impactor/                    PINS.json, MIT + MPL-2.0 licence texts, source note
      shell/                                   shell template placement + manifest example
      tools/fetch-impactor.ps1/.sh             download + SHA-256 verify official v2.7.2
      tools/prepare-dist.ps1                   self-contained distribution + SHA256SUMS

Directory names stay visible to git: the repository-wide build/, workspace/ and
third_party/ ignore rules would otherwise hide launcher sources or pinned metadata, so
the directories are BuildPipeline/, LauncherState/ and vendor/impactor/ (verified with
git check-ignore and git status).

Dependency direction is one-way: Desktop -> Core -> external CLIs. Core never
starts a shell; every external tool runs as an argv array with streamed output and
explicit exit-code handling.

## 5. Tool contracts

### 5.1 3ds2apple-pack (existing Rust CLI, builder/pack)

The launcher never parses ROMs or writes package manifests itself. Commands used
(global --out DIR and --json come before the subcommand):

    headers:  3ds2apple-pack --out <ws>/out --json rom inspect <rom>
    import:   3ds2apple-pack --out <ws>/out --json packages add --roms <rom> [--display-name N]
    list:     3ds2apple-pack --out <ws>/out --json packages list
    adopt:    3ds2apple-pack --out <ws>/out --json packages record --title-id ID --pack FILE [--display-name N] [--product-code C]
    catalog:  3ds2apple-pack --out <ws>/out --json catalog --title-id ID [--title-id ID...] --catalog-out FILE
    preview:  3ds2apple-pack --out <ws>/out --json build --queued --fake
    verify:   3ds2apple-pack --out <ws>/out --json packages verify

Real output captured in this checkout for rom inspect (Pokemon Y.cci, headers only):

    {
      "errors": [],
      "roms": [{
        "bytes": 1807118336, "container": "ncsd", "contentBytes": 1807101952,
        "displayName": "Pokemon Y", "path": "ROM/Pokemon Y.cci",
        "productCode": "CTR-P-EK2A", "titleID": "0004000000055E00", "titleVersion": 2
      }]
    }

packages add reports titleID/displayName/productCode/packageDir/romPath/status;
packages list adds aotVersion/state/pack{sha256,bytes,format}/issues. Exit 0 ok,
1 validation/errors (JSON errors[]), 2 usage. Tests use the real JSON shapes.

### 5.2 builder-windows (macOS Build Agent, existing Rust frontend)

    builder-windows build --host <profile> --rom <ROM> --name <ascii-slug> \
        --display-name <name> --out <download-dir> --json

Exit codes (shared with zkb): 0 ok, 1 build failed, 2 usage/config, 3 transport,
4 canceled, 5 local I/O, 64+ internal. --json streams protocol events; the
launcher maps stage/message/progress to UI progress/log and finds the downloaded
.ipa in the output directory (or from event paths). Build slug =
BuildSlug.From(displayName, titleID) -> ASCII lower-case + last 8 title-id digits.

The launcher extracts Payload/<app>/Frameworks/GamePack-<TITLEID>.dylib from that
IPA, rejects a non-Mach-O payload (this catches --fake placeholders), and records
it with packages record so the Rust CLI stays the single manifest writer. That
per-game-IPA path is transitional: a dedicated Agent packbuild stage is designed in
[windows-build.md](windows-build.md) section 5; the launcher has a provider that
refuses explicitly until it exists (no fake success). Until task-22 proves a local
LLVM/lld path, the macOS Build Agent is the only real build path.

### 5.3 App IPA composition (new, on Windows)

Inputs: pinned shell template IPA (Shell/manifest.json), the real packs, and the
catalogue produced by 3ds2apple-pack catalog. The composer
(Core/BuildPipeline/IpaComposer.cs):

- requires at least one real pack; every pack is Mach-O checked and title-ID unique;
- asks the pack CLI for GameCatalog.json (single schema writer), validates the
  games count/packFile paths, and fills the optional registrationSymbol +
  packABIVersion=1 contract fields;
- copies every template zip entry while preserving Unix mode bits (important for
  the app executable and frameworks), replaces GameCatalog.json, injects
  Frameworks/GamePack-<TITLEID>.dylib (mode 0755);
- refuses a template that contains any Roms/ entry (base_shell_not_rom_free);
- never writes a ROM or game data into the IPA; returns path/size/sha256/game count.

Output: workspace/work/app-ipa/3ds2apple-app-<N>games-<timestamp>.ipa, handed to
the signing/install step. Recompose+reinstall is the update mechanism for adding or
removing games.

### 5.4 devpush — device bridge CLI (task-16/20, contract devpush/1)

[device-bridge.md](device-bridge.md) is authoritative; tools/devpush is the only
implementation. The frozen v1 summary below was checked against the real binary +
mock backend in this checkout. With --json all stdout is NDJSON lines:
{"schema":"devpush/1","type":"begin|progress|warn|done|error"}.

Commands used by the launcher:

    devpush capabilities [--json]                     -> version, schema, commands[], features{}
    devpush devices [--json]                          -> devices[{udid,name,model,iosVersion,connection,paired}]
    devpush app-attr --bundle-id ID [--json]          -> {installed,dataContainer,appBundleVersion,fileSharingEnabled}
    devpush mkdir --bundle-id ID --path P             -> create Documents/Games/<TITLEID>
    devpush put --bundle-id ID --local F --remote P   -> progress lines + done{remotePath,bytes,sha256}
    devpush stat --bundle-id ID --path P              -> {path,isDir,size,mtime} (path_not_found when absent)
    devpush ls / put-tar / free / uninstall           -> available; the launcher only needs mkdir/put/stat

Semantics: --container app (default) = house_arrest VendContainer for a
developer-signed app; paths are container-relative. --udid optional (auto-picks the
only device; device_not_found/device_ambiguous otherwise). Exit codes: 0 ok,
1 internal, 2 usage, 3 device/usbmux, 4 pairing/locked, 5 app/container,
6 stall_timeout, 7 AFC/path/io, 8 install_failed, 9 unsupported/developer-mode.
A 90 s no-payload-progress watchdog aborts container/file ops (installs exempt).
--mock-dir (or DEVPUSH_MOCK_DIR) runs the whole contract on a filesystem backend —
used for phone-less dry runs and CI.

task-20 update: the task-16 Python wrapper's push-game also pushes only ROM then
GameInfo (its --pack is metadata-only and never uploaded; done reports
packLocation:"ipa", files[]=2). This launcher implements the same split directly
on devpush; optionally consolidating on the wrapper later keeps one Apple error
catalog. docs/device-bridge.md sections 4.1/6 remain authoritative.

### 5.5 Official Impactor v2.7.2 + plumesign (bundled, unmodified, pinned)

The only Windows signing path; we do not implement Apple ID auth or signing. The
whole composed IPA is signed, so the nested Frameworks dylibs are covered.

    plumesign sign --package <composed.ipa> --apple-id [--register-and-install --udid <deviceNumber>]
                   -o <signed.ipa> [--custom-name 3ds2apple] [--custom-identifier BUNDLE_ID]
    plumesign device --udid <deviceNumber> --install <signed app/ipa>   (already-registered retry)

- Binaries: Impactor-windows-x86_64-portable.exe and plumesign-windows-x86_64.exe,
  official release files, SHA-256 pinned in Core/Signing/ImpactorBundle.cs and
  vendor/impactor/PINS.json: f493cd99...e88ef (18,213,888 B) and
  b965e51a...a2fe0 (10,718,720 B), matching the GitHub REST API release digests
  (checked 2026-11-14). Verified before every use; mismatch = refuse to sign.
- Licences: Impactor MIT (Copyright 2025 Samara M); embedded apple-codesign 0.29.0
  MPL-2.0. Both texts + provenance note + PINS.json are in vendor/impactor/
  and copied next to the binaries by tools/fetch-impactor.ps1.
- Account lives in %APPDATA%/PlumeImpactor/accounts.json (managed by Impactor).
  The launcher only starts Impactor for sign-in, then invokes plumesign; RUST_LOG=info
  is forced by the runner so the "Installation complete" marker cannot be hidden.
- plumesign --udid takes the numeric usbmux device number, not the UDID, so the
  launcher reads it via a read-only usbmuxd ListDevices request (Device/UsbMuxClient.cs).
- Retry policy: "already exists on this team" -> sign-only then device --install;
  9401 App ID taken -> user changes bundle id in Settings; anisette/network failures
  -> actionable message + manual retry (no hidden retry loop).

### 5.6 GameInfo.json (pushed to Documents, schema 1)

    {
      "schemaVersion": 1,
      "titleID": "0004000000055E00",
      "displayName": "Pokémon Y",
      "productCode": "CTR-P-EK2A",
      "aot": true,
      "aotVersion": 1,
      "packABIVersion": 1,
      "registrationSymbol": "zk_gamepack_register",
      "saveNamespace": "0004000000055E00",
      "pack": { "file": "Frameworks/GamePack-0004000000055E00.dylib",
                "size": 42102784, "sha256": "<64 hex>" },
      "packBundled": true,
      "rom":  { "file": "GameRom.cci", "size": 1807118336, "sha256": "<64 hex>" },
      "launcherVersion": "3ds2apple-launcher-windows/0.1.0",
      "pushedAt": "2026-11-14T15:00:00Z"
    }

pack{} (and packBundled) are informational: the file path is app-bundle-relative,
NOT a Documents file, and the shell loads the dylib through the bundle
GameCatalog. (The task-20 wrapper's push-game writes the local dylib name plus
packLocation:"ipa" instead; both forms are informational and tolerated.)

Per docs/device-bridge.md section 6 (device-bridge confirmation, 2026-11-14):
push-game / verify-game never enforce pack.file or the pack metadata — they
validate only GameInfo.titleID and the ROM size/sha256, so a push can never fail
because of this difference. The bundle GameCatalog is authoritative for pack
location/name; a canonical-form requirement would be a shell-contract change, not
a bridge change.

rom{} is verified by the shell when present; until the push verifies it shows
"Data missing". Unknown fields are ignored; pack{} is omitted entirely when no
pack hash was recorded. GamePack ABI unchanged: zk_gamepack_title_id /
zk_gamepack_abi_version (=1) / zk_gamepack_register(uint32)->0.

### 5.7 Shell template manifest (Shell/manifest.json)

    {
      "schemaVersion": 1,
      "fileName": "3ds2apple-shell.ipa",
      "version": "0.2.0",
      "bundleId": "com.kratos.3ds2apple",
      "sha256": "<64 hex>",
      "bytes": 12345678,
      "build": 9,
      "minIosVersion": "16.0"
    }

Identity is validated twice before anything is signed (QA S1):
- Shell/manifest.json must have version >= 0.2.0-beta1 and build >= 9
  (missing/older values are rejected with shell_template_incompatible);
- the actual IPA must carry matching Info.plist CFBundleShortVersionString /
  CFBundleVersion (binary or XML plist), a bundle GameCatalog.json with schema 2
  and an empty games list for the template, and no Roms/ entries.
A template that fails any rule is refused before composing/signing; the error in
the UI/log names the failing field and the fix. The template is a per-build
artifact (ROM-free, empty catalogue) and is not committed.

## 6. Error catalog (UI shows title + detail + fix)

| Code | Trigger | What the user does |
|---|---|---|
| free_appid_limit | Apple 9120 / 10 app ids / maximum number of app ids | Wait for the 7-day free-account window or use a paid account; changing the id does not help until reset |
| free_app_limit | maximum number of installed apps / 3 apps | Delete another sideloaded app, then retry |
| app_id_taken | Apple 9401 / app id with identifier ... not available | Change the shell bundle id in Settings to a unique value, retry |
| apple_session_expired | 1100 / session expired / please log in again | Sign in again in Impactor, wait for the team list, retry |
| login_identity_rejected | Impactor -80046 | Sign in again with the user's own Apple ID |
| account_not_selected | No account selected | Select the account in Impactor (or re-add it), retry |
| apple_id_wrong / two_factor_wrong | -2097x/-20101, -21669/2FA text | Re-authenticate in Impactor, complete the code prompt |
| signing_server_unreachable | anisette DNS/connect errors | Check network/proxy/VPN; retry in a minute |
| device_already_registered | already exists on this team | Automatic sign-only + device install retry; if repeated, remove/re-add the Apple ID |
| ipa_needs_repack | zip64 / unreadable IPA / invalid app name | Rebuild the shell template / reinstall the launcher package |
| entitlement_mismatch | mismatchedapplicationidentifierentitlement | Remove the app, sign in again, reinstall |
| device_not_found | no device / disconnected | USB cable, unlock, Trust, Apple Devices running |
| device_install_failed | install failure text | Keep phone unlocked, retry; expired certificate -> sign in again |
| impactor_missing | pinned bundle missing/modified | Reinstall the package or run tools/fetch-impactor.ps1 |
| shell_template_incompatible | template version/build below 0.2.0-beta1/build 9, mismatched Info.plist, empty-schema-2 catalogue missing, catalogue not empty, or Roms/ present | Rebuild the ROM-free template on macOS with the current shell task and repack |
| shell_invalid | template manifest/hash/zip invalid | Rebuild the ROM-free shell template on macOS and repack the distribution |
| base_shell_not_rom_free | template contains a Roms/ entry | The template is not the launcher build; use the ROM-free shell template |
| pack_missing / pack_duplicate / pack_placeholder | no/invalid/duplicate pack | Build the game with the macOS Build Agent (preview placeholders are rejected) |
| catalog_failed | pack CLI catalogue missing/mismatched | Rebuild/record packages, update 3ds2apple-pack |
| generic_signing_failure | unrecognised text | Read the log line; raw text stays visible, never swallowed |

Raw tool output is data and is displayed, never executed or turned into a command.
Tests cover the 9120-vs-3-apps ordering, 9401 before the generic bucket, 1100/
session, anisette, already-registered, composer catalogue validation and the
generic fallback.

## 7. Security and privacy

- No Apple ID, password, 2FA code, certificate, provisioning profile, device UDID
  or SSH private key is ever read or logged by the launcher; sign-in happens in
  Impactor. Device UDIDs are shown/logged only in redacted form (first 8…last 4,
  via Core/Util/Privacy.cs); the full value is passed only to device/signing
  commands and stored nowhere (QA S2).
- The ROM is read locally (headers for import, full read for push SHA-256 and for
  the Build Agent upload). The Build Agent upload is the existing builder behaviour:
  the user's own host over SSH, deleted at job end by default.
- The composed IPA contains code only (shell + packs + catalogue), never ROMs.
- No telemetry, crash upload, signing service or project server.
- Process calls are argv arrays, never shell strings; output is bounded, UTF-8.
- Workspace under %LOCALAPPDATA%/3ds2apple/launcher holds state.json, composed app
  IPAs, staging metadata, logs and the pack-CLI output tree (user data, never git).
- The launcher refuses placeholder packs for composition (Mach-O check), unverified
  Impactor/plumesign, an unverified template, and any template that contains ROMs.

## 8. Licensing / notices

- Launcher code: original work in this repository (project Apache-2.0).
- Avalonia (MIT), .NET (MIT): package dependencies.
- Impactor (MIT) + apple-codesign (MPL-2.0, embedded): bundled unmodified official
  binaries, SHA-256 pinned, licence texts in vendor/impactor/ (byte-identical
  to the canonical task-16 copies under scripts/impactor/licenses/).
- S2Arm (Apache-2.0) studied as a reference; no code copied.
- 3dsrecomp has no LICENSE: only invoked as a build tool on the macOS host, never
  vendored/redistributed; its generated C is never committed.
- Lead: NOTICE/THIRD_PARTY updated by task-16 for Impactor/apple-codesign/idevice/
  S2Arm; adding Avalonia/.NET rows is optional if the list should stay exhaustive.

## 9. Verification performed in this checkout (WSL)

Environment: WSL2 Linux x86_64, local .NET SDK 10.0.403, Rust 1.99; no Windows,
no iPhone, no Apple ID, no macOS host session.

    # solution build
    dotnet build Launcher.slnx -c Debug
    -> Build succeeded. 0 Error(s)

    # unit tests (57, incl. IpaComposer + template-identity/privacy tests)
    dotnet test tests/ThreeDsTwoApple.Launcher.Core.Tests/ThreeDsTwoApple.Launcher.Core.Tests.csproj
    -> Passed! Failed: 0, Passed: 57, Skipped: 0

    # host self-test, bare source tree
    dotnet launcher/windows/src/Launcher.Desktop/bin/Debug/net10.0/3ds2apple-launcher.dll --self-test
    -> PASS version, pinned Impactor digests, PINS.json cross-check, workspace state,
       GameInfo round-trip (pack informational/bundle-relative), GameInfo without pack,
       devpush/1 parser, push layout, build slug
       WARN 3ds2apple-pack/devpush/builder-windows/Impactor bundle absent (source tree)
       SELF-TEST OK with 4 warnings

    # same self-test with the real Rust tool binaries
    DEVPUSH_EXE=... THREEDS2APPLE_PACK=... THREEDS2APPLE_BUILDER=... dotnet ... --self-test
    -> PASS for 3ds2apple-pack 0.1.0, devpush 0.1.0, builder-windows 0.1.0
       SELF-TEST OK with 1 warning (only the not-downloaded Impactor bundle)

    # real desktop CLI (headers of the local ROM only)
    builder/target/release/3ds2apple-pack --version -> 3ds2apple-pack 0.1.0
    ... --json rom inspect "ROM/Pokemon Y.cci"      -> titleID 0004000000055E00 etc.
    ... packages add / packages list                -> imported, queued

    # real devpush binary + mock backend, launcher command shapes
    devpush --json capabilities                     -> devpush/1, 16 commands, stallSeconds 90
    devpush --mock-dir ... --json app-attr/mkdir/put/ls/stat
                                                    -> begin/progress/done{remotePath,bytes,sha256}
    devpush --mock-dir ... put to missing bundle    -> type=error, code=app_missing, exitCode 5

    # task-20 wrapper mock smoke test for the ROM+GameInfo split (host-side; no phone)
    devpush --mock-dir /tmp/dp-mock --json install --ipa /tmp/Shell.ipa --bundle-id com.kratos.3ds2apple
    DEVPUSH_EXE=... DEVPUSH_MOCK_DIR=/tmp/dp-mock python3 builder/device/device_cli.py push-game --json \
        --bundle-id com.kratos.3ds2apple --title-id 0004000000055D00 \
        --game-info /tmp/game/GameInfo.json --rom /tmp/game/GameRom.cci --pack /tmp/game/GamePack.dylib
    -> steps "1/2 GameRom.cci", "2/2 GameInfo.json"; done ok:true verified:true files.length=2;
       packLocation:"ipa"; mock container Documents/Games/0004000000055D00/ contains exactly
       GameInfo.json + GameRom.cci (verified in this checkout 2026-11-14)

    # pinned Impactor hashes vs official release metadata (GitHub API, 2026-11-14)
    Impactor-windows-x86_64-portable.exe f493cd99...e88ef 18,213,888 B match
    plumesign-windows-x86_64.exe       b965e51a...a2fe0 10,718,720 B match

    # fetch guard (no download; pins only)
    bash tools/fetch-impactor.sh --print-pins       -> two pinned rows
    bash tools/fetch-impactor.sh --verify /tmp/empty -> [missing] x2, exit 1

    # licence text equality with task-16 canonical copies
    Impactor MIT 6e91aca9...a3e on both paths; apple-codesign MPL-2.0 3f3d9e00...d04 on both

    # UI smoke (Xvfb, dev convenience only)
    Avalonia window started and captured; the frame showed the window shell only
    (headless rendering artefact) - real UI verification is Windows test item 1.

Evidence files were kept outside git (/tmp); no ROM, generated C, IPA, binary or
runtime state was added to the repository.

## 10. Known gaps / not done

- No Windows runtime verification: not run on Windows, win-x64 publish not produced
  here, no installer/SmartScreen flow. Section 11 is the acceptance path.
- No real Apple ID/Impactor/plumesign run; signing error mapping is text-tested only.
  **Composed-IPA signing of nested dylibs was not verified on a device** — this is
  the key real-device check in section 11 item 9 (iPhone + Apple ID required).
- No real device: devpush is contract-tested with a fake process layer and with the
  real binary's mock backend; a real USB/Wi-Fi AFC transfer remains for QA.
- No shell template IPA artifact in this checkout; install is intentionally disabled
  without Shell/manifest.json + IPA (shell/README.md).
- macOS Build Agent packbuild stage is a design proposal (windows-build.md section 5);
  real builds use the existing per-game IPA extraction path. task-22's local
  LLVM/lld investigation runs in parallel; the Agent path stays until it is proven.
- Avalonia UI only smoke-started under Xvfb.
- No macOS launcher work here (task-18).

## 11. Manual test plan (Windows PC + iPhone/iPad)

Prepare: launcher package (or dotnet run from source), a local decrypted .3ds/.cci
you own, a paired macOS Build Agent for real packs, the phone by USB with Developer
Mode/Trust, and the bundled Impactor/plumesign (tools/fetch-impactor.ps1).

1. Launcher starts, header shows the version; Settings -> Run self-test prints PASS
   for pinned digests and PINS.json; tool rows show ready/missing honestly.
2. Missing tools: rename Bin/3ds2apple-pack.exe -> import refused with instructions;
   delete ThirdParty/Impactor -> install and "Open Impactor" refused with
   impactor_missing; restore files.
3. Import: browse a ROM (drag-and-drop is not wired in this MVP). Expect title row
   with 16-hex title ID, display name, product code; a CIA/encrypted file is
   rejected with the CLI message. Restart: library restored from state.json.
4. Preview build: Build tab -> Preview -> Build. Expect placeholder pack labelled
   not installable; composing/installing must refuse it (Mach-O check / no real pack).
5. Real build (needs macOS host): Build tab -> macOS Build Agent -> host profile ->
   Build. Expect agent log/progress then "real GamePack" with a 64-hex SHA-256.
   Confirm on the Mac that the job cleaned up the ROM.
6. Device: connect phone, unlock, Trust. App & Device -> Refresh devices lists it.
7. Sign-in: Open Impactor -> sign in with a free Apple ID -> close/minimise.
8. First install: with one built game -> Install/update app. Expect compose log
   (template + 1 pack + GameCatalog), plumesign progress, app on home screen.
   Negative cases: template-with-ROM (manually put a Roms/ file into Shell/*.ipa ->
   base_shell_not_rom_free), corrupted template hash -> shell_invalid, free Apple ID
   9120 / 9401 / 1100 / anisette -> catalog title/detail/fix.
9. Device validation of the new architecture: open the shell on the phone; with the
   ROM not yet pushed the game must show "Data missing" (proves the bundle pack
   loaded/catalogued but the ROM is absent). This also exercises nested-dylib
   signing: if the pack dylib signature were not covered by the IPA, the app would
   fail to load it (record the result; this is the key acceptance item).
10. Push: Push tab -> Push selected game ROM. Expect two files (GameRom.cci then
    GameInfo.json), progress, then verified. On the phone the game launches from the
    ROM in Documents.
11. Update with a second game: build game 2, App & Device -> Install/update app
    (2 packs); expect reinstall without uninstall. Confirm game 1's ROM data is
    still in Documents and game 1 still launches; game 2 shows Data missing until
    its ROM is pushed.
12. Remove a game: remove from library, reinstall; on the phone the game disappears
    from the library (its Documents ROM may remain orphaned; document behaviour).
13. Resume/stall: push a large ROM, unplug/re-plug USB mid-transfer -> bridge
    auto-selects USB and/or a stall_timeout error; re-run push -> already-pushed
    file skipped by size, rest completes; verify reports no problems.
14. Mock dry run (no phone): start a mock device, install a dummy IPA, then push one
    game's data with the exact commands below (also in docs/device-bridge.md section 2 and
    validated in this checkout 2026-11-14; signing itself still needs a real device):

        tools/devpush/target/release/devpush --mock-dir /tmp/dp-mock --json install \
            --ipa /tmp/Shell.ipa --bundle-id com.kratos.3ds2apple
        DEVPUSH_EXE=$PWD/tools/devpush/target/release/devpush DEVPUSH_MOCK_DIR=/tmp/dp-mock \
          python3 builder/device/device_cli.py push-game --json \
            --bundle-id com.kratos.3ds2apple --title-id 0004000000055D00 \
            --game-info /tmp/game/GameInfo.json --rom /tmp/game/GameRom.cci \
            --pack /tmp/game/GamePack.dylib

    Expected: steps "1/2 GameRom.cci", "2/2 GameInfo.json"; done verified:true with
    files.length==2 and packLocation:"ipa"; Documents/Games/<TITLEID>/ holds exactly
    GameInfo.json + GameRom.cci. (The wrapper writes pack.file as the local dylib name plus
    packLocation:"ipa"; this launcher writes a bundle-relative Frameworks path plus
    packBundled:true. Both are informational per the shell contract — the bundle
    GameCatalog remains authoritative. Do not fail a push because of that difference.)

## 12. Coordination and follow-ups for Lead

- task-20 device-bridge: contract v1 + ROM-only push-game implemented; our client
  was checked against the real binary/mock; docs/device-bridge.md authoritative.
  The Python wrapper (device-install/1) is an optional consolidation point for
  signing/Apple-error-catalog; the launcher currently stays Python-free.
- task-17 shell: template/bundle-catalog/Documents split agreed; base shell template
  IPA must still be produced on macOS (shell/README.md) and handed to the Windows
  distribution. Shell must load the pack from the bundle and the ROM from Documents.
- task-22: keep macOS Build Agent as the real build path until the local LLVM/lld
  GamePack build is proven; then the packbuild provider can be switched.
- build-infra: implement the Agent packbuild stage (windows-build.md section 5) to
  stop building a whole IPA per game.
- Lead/integration: review launcher/windows/.gitignore (bin/obj and downloaded
  binaries untracked); do not commit Shell/*.ipa, composed IPAs or .exe; update
  .internal/PROJECT_HANDOFF.md with the new architecture + evidence paths.
## 13. Experimental local build (task-26): 3dsrecomp + LLVM/LLD on the Windows PC

> Status: implemented and unit-tested in `launcher/windows`; **off by default**. The mac build
> Agent remains the supported path until a runtime end-to-end check on a real phone is signed off.
> This section documents what is wired and what was actually proven.

The launcher can now build a per-game GamePack **on the Windows PC itself**, with no Mac and no
Apple SDK, using the open-source toolchain proven in [windows-build.md](windows-build.md) §7-8:

1. **ROM → generated C → arm64 objects** — `3dsrecomp.exe port <rom> <work>/recomp --name <slug>`.
   The launcher sets the child environment so 3dsrecomp's compile step targets iOS with the
   hand-written Darwin headers:
   `CC=clang.exe --target=arm64-apple-ios16.0`, `AR=<llvm>/llvm-ar.exe`,
   `CPATH=<repo>/tools/winbuild/darwin-stubs/include`, `PATH=<llvm>/bin;%PATH%`.
   (3dsrecomp splits `CC` on spaces and runs the first word as the program, so no wrapper script
   is needed and the bundled LLVM install path may contain spaces.)
2. **GamePack link** — compile `zk_gamepack_shim.c` with `clang.exe`
   (`-nostdinc -isystem <clang resource> -isystem <darwin-stubs> -DZK_GAMEPACK_TITLE_ID=...`), then
   `ld64.lld.exe -arch arm64 -platform_version ios 16.0.0 16.0.0 -dylib -undefined dynamic_lookup
   -dead_strip -install_name @rpath/GamePack-<TITLE>.dylib`. The dylib carries only the game code;
   libSystem and `zk_register_gamepack` resolve from the signed app at `dlopen()` time (same contract
   as the Xcode-built pack).
3. **Validation + record** — the launcher checks the output is a thin arm64 Mach-O dylib, then
   `3ds2apple-pack packages record` writes `GameInfo.json` (the single schema writer). IPA
   composition/catalogue/signing are unchanged (§1 steps 3-4).

**Tool requirements** (all checked before a build; missing pieces are reported, never faked):

| Tool | Source | Notes |
|---|---|---|
| `3dsrecomp.exe` | built once from the pinned upstream revision (Rust) | cloned at build time, never vendored (no upstream LICENSE file; Cargo.toml declares MIT) |
| `clang.exe`, `llvm-ar.exe`, `ld64.lld.exe` | official LLVM 21.1.8 release | Apache-2.0 WITH LLVM-exception; SHA-256 pins in `tools/winbuild/llvm-manifest.json`; user-installed or bundled unmodified with licence |
| `tools/winbuild/darwin-stubs/include` | this repo | hand-written ISO C declarations; no Apple header |
| `ios/zakuro-ios/gamepack/zk_gamepack_shim.c`, `ios/zakuro-ios/include` | this repo | pack ABI shim/header |
| `3ds2apple-pack.exe` | this repo (`builder/pack`) | package record / catalogue |

**Feature flag and UI:** `LauncherStateDocument.LocalBuildEnabled` (Settings →
“Experimental local build”, default off) controls whether the provider and its build-mode entry
exist at all; `LauncherServices.CreateBuildProvider(LocalWinbuild)` returns null while the flag is
off so nothing can silently use the experimental path. On enable, Settings also takes explicit
paths for `3dsrecomp.exe` and the LLVM bin folder (tool overrides, same mechanism as the other
tools). Readiness gains a “local build (3dsrecomp + LLVM/LLD)” row and `HostReadiness.CanLocalBuild`.

**Tests (no Windows/phone needed):** 6 new unit tests in
`launcher/windows/tests/.../LocalWinbuildPackProviderTests.cs` cover the exact recompile env/argv,
the shim/link/record command construction, missing-tool and recompile/link failure codes, rejection
of a non-Mach-O link output before recording, and the feature flag gating provider creation. Full
suite: **63/63 passing** (`dotnet test`, .NET 10); `dotnet build` of the Core + Avalonia Desktop
projects: 0 warnings / 0 errors.

**Proven outside the launcher (see windows-build.md §8):** 3dsrecomp ran on a Linux host with the
same CC/CPATH trick, generated C identical (combined SHA-256) to the macOS-VM-generated tree, and
the LLVM/LLD device GamePack built from that fresh C is byte-identical (same SHA-256) to the
task-22 pack. The LLVM-built x86_64 simulator pack also ran in the real iOS Simulator shell/harness
with AOT active and 0.00% interpreted instructions.

**Limits / honest gaps:**

* No real Windows PC was available: the provider is unit-tested and the identical command shapes
  were exercised on Linux; the Windows-native 3dsrecomp build/link still needs a first-run smoke
  test on hardware (see the manual test plan §11).
* The local build currently targets **device (arm64)** only; simulator packs need a second compile
  pass for `x86_64-apple-ios16.0-simulator` (the toolchain supports it, the launcher does not offer
  it).
* Generated C and intermediate objects stay in the launcher workspace (never in git, never in the
  IPA); the ROM is read from the user's library path only.
* Codegen is upstream LLVM, not Apple clang: runtime correctness was checked in the simulator
  (AOT active, 0.00% interpreted) but a device AOT run is still part of the device acceptance.

## 14. Two-section UI, localization and icon (task-28, 2026-11-15)

The Windows launcher now matches [launcher-ui.md](launcher-ui.md): **Library** and **Import** are
the only top-level sections, and Settings is a gear button (not a tab). The old Build / App & Device
/ Push / Settings tabs are gone; their essential actions live on each game card (one primary action
plus an overflow menu for build / install / push / verify / remove) and inside Settings.

- **Library**: empty state with one Import button; otherwise minimal game cards (placeholder icon,
  name, localized state badge, one status line, primary action + overflow menu).
- **Import**: pick a decrypted .3ds/.cci, optional display-name override, inline progress only while
  an import job runs, plus the "what happens next" steps.
- **Settings** (gear): Apple ID/signing explanation + Open Impactor / Install app, device state and
  prerequisites, build mode (preview / macOS Build Agent / experimental local) and build host, tool
  paths, language override, logs + diagnostics + self-test + workspace, about/licences.
- **Theme**: Fluent light/dark via ThemeDictionaries (no hard-coded dark window), one accent color,
  generous spacing; CJK-capable font stack (Segoe UI, Microsoft YaHei UI, Noto Sans CJK SC).

**Localization** (`Core/Localization/Localization.cs`)

- English + Simplified Chinese, 169 keys; en/zh-Hans key and placeholder parity is enforced by unit
  tests and by `--self-test`.
- OS language detection: `zh`/`zh-CN`/`zh-Hans`/`zh-SG` -> zh-Hans; Traditional Chinese and
  everything else -> English (documented fallback). The System / English / 简体中文 override is
  persisted as `state.json: language` (`system` | `en` | `zh-Hans`).
- Switching language re-localizes all visible UI live (the view model swaps the `LocalizedText`
  instance); raw log/diagnostic output stays unmodified.
- The desktop `--ui-smoke` dev mode rendered English and Simplified Chinese under Xvfb
  for Library, Import and Settings (`launcher/windows/docs/ui/launcher-en.png`,
  `launcher-zh.png`, `import-en.png`, `settings-en.png`, `settings-zh.png`; see the README there).

**Icon**: the iOS app icon (`ios/app/Assets.xcassets/AppIcon.appiconset/icon-1024.png`) generated
`launcher/windows/src/Launcher.Desktop/Assets/app.ico` (16/24/32/48/64/128/256 px) plus a 128 px
placeholder for cards. `ApplicationIcon` sets the exe icon and the window declares
`Icon="/Assets/app.ico"`; the published PE was checked to contain `RT_ICON` (3) and
`RT_GROUP_ICON` (14) resources.

## 15. Single-file one-executable distribution (task-28, 2026-11-15)

The user-facing Windows package is a ZIP that contains **exactly one file**:
`3ds2apple-launcher.exe` (self-contained .NET 10, no runtime install). Release builds publish
single-file with `IncludeNativeLibrariesForSelfExtract` + compression.

**Embedded payload (14 files for the 0.1.0 build)**

| Path in extraction | Source |
|---|---|
| `Shell/manifest.json`, `Shell/3ds2apple-shell.ipa` | pinned ROM-free base shell template (4,023,719 B) |
| `ThirdParty/Impactor/Impactor-windows-x86_64-portable.exe` | official v2.7.2, SHA-256 pinned |
| `ThirdParty/Impactor/plumesign-windows-x86_64.exe` | official v2.7.2, SHA-256 pinned |
| `ThirdParty/Impactor/LICENSE-Impactor-MIT.txt`, `LICENSE-apple-codesign-MPL-2.0.txt`, `README-source-and-licenses.txt`, `PINS.json` | licence/source notices |
| `Bin/3ds2apple-pack.exe`, `Bin/builder-windows.exe`, `Bin/devpush.exe` | cross-built Rust CLIs (x86_64-pc-windows-gnu) |
| `licenses/LICENSE`, `licenses/NOTICE`, `licenses/THIRD_PARTY.md` | project licences/notices |

- The Core project embeds these as `Payload/...` resources when `Configuration=Release` and the
  staged files exist (Debug/test builds stay small and do not need the git-ignored payload).
- On first run `DistributionLayout.Prepare()` extracts them to
  `%LOCALAPPDATA%\3ds2apple\distribution\<version>\` (atomic writes + `payload-manifest.json`
  marker with size/SHA-256 per file), then every service/tool resolves from that root. A
  `THREEDS2APPLE_DIST` override and the multi-file developer layout (`Bin/`, `Shell/`,
  `ThirdParty/` next to the exe) still work.
- Build: `launcher/windows/tools/prepare-dist-singlefile.sh [output-dir]` (WSL; also
  `prepare-dist-singlefile.ps1` for Windows release engineers). It verifies the shell SHA-256,
  requires the verified Impactor bundle + Bin tools, publishes single-file, deletes loose PDBs and
  ZIPs only the exe.

**Verification evidence (2026-11-15, this checkout)**

- Package: `/mnt/f/temp_transfer/dist/windows-single/3ds2apple-windows-single-0.1.0.zip`
  - ZIP SHA-256 `7b4fc1f6470da3c5373a30e3f91e7be4a7985e331f4a88c69f490fa23b19967f`
    (71,802,897 B); `unzip -l` shows a single entry `3ds2apple-launcher.exe`.
  - exe SHA-256 `aad4f20149d76dcd9f8c7f31d648ed4ad70d77ea32d7bd552ae9887badb3f016`;
    PE32+ GUI x86-64, icon resources present.
- Clean-folder run: exe copied alone into `.../windows-single/clean-run/`, the previous
  `%LOCALAPPDATA%\3ds2apple` removed, then `./3ds2apple-launcher.exe --self-test` via WSL interop:
  exit 0, `SELF-TEST OK with 1 warning` (the only warning is the "outside a source checkout"
  PINS.json cross-check). PASS lines include: extraction to
  `C:\Users\...\AppData\Local\3ds2apple\distribution\0.1.0`, 14-file embedded payload,
  extracted files present, single-file extraction target outside the exe folder, ROM-free shell
  template v0.2.0-beta1, Impactor bundle ready, Bin tools probe 0.1.0, 169-key en/zh catalogue.
- Regression: `dotnet test` **111/111 passed** (63 pre-existing + 48 new localization/payload
  tests), 3 consecutive runs.

**Known gaps**

- The exe is not code-signed (SmartScreen may warn on first launch).
- First run extracts ~46 MB into `%LOCALAPPDATA%`; later runs only size-check the marker.
- The GUI was rendered under Xvfb and the XAML/bindings/theme load; real Windows interaction,
  Impactor sign-in and device flows still need the manual test plan (section 11).
- `prepare-dist-singlefile.ps1` mirrors the exercised `.sh` script but was not run in this
  checkout (no Windows host).
