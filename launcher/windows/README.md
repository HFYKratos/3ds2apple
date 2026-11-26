# 3ds2apple launcher for Windows (MVP)

Status: **launcher 0.1.5 (build 1, 0.1.5 release, 2026-11-20)** — portable data
folder beside the exe (LocalAppData only when read-only, with one-time migration),
hardware-aware compile line (cores/RAM + 3dsrecomp auto-parallelism), ROM metadata UI
from the pack CLI (SMDH `cover.png` icon, localized `displayNames`, `publisher`; no
editable name box), and the 0.2.5 (pre-reset numbering) SMDH icon fix: the pack CLI now
decodes the large icon at SMDH `0x24C0` with the 8x8-tile/Morton pixel layout, so
Library covers are the real game icons. Re-importing a
game that is already in the library passes `--force`, which re-extracts a stale extracted
cover and keeps an existing built GamePack (a user-supplied cover is never overwritten).
The legacy Build Agent path (`builder/{agent,cli,linux,windows}`, `MacAgent*` providers)
is deleted; the local 3dsrecomp + LLVM/LLD build is the only path and the single-file
exe no longer embeds `builder-windows.exe` (~1.24 MB smaller).
The 0.1.2 checkout also adds Library **Build now / Build all** with a recorded
build-compatibility cache (see below) and removes every device identifier from the
UI, log and diagnostics export. The current development checkout adds a Deploy
**Stop** action (cancels the running step and terminates its tool process tree) and
window-close cleanup (a running deploy is stopped and its 3dsrecomp/clang/lld/
devpush/plumesign processes are terminated before the launcher exits), and merges the
two duplicate "not built yet" Library strings into one status line. This checkout compiles cleanly (0 errors, warnings as
errors) and its **240 unit/integration tests pass**. The packaged single-file exe runs its clean-folder
`--self-test` on Linux/WSL with the embedded payload (32 PASS / 0 FAIL / 0 WARN), and on a
Windows host natively through `scripts/release/win-selftest.sh` (32 PASS / 0 FAIL / 0 WARN).
The UI has exactly two sections (Library, Deploy) plus a minimal Settings gear; it is
localized (English / 简体中文) and uses the iOS app icon. The user-facing package is a ZIP
with exactly one self-contained exe (the 0.1.5 package: 157,455,106 B, SHA-256
`e37a924e…b2e16`; the 0.1.4 package was 157,292,331 B; the package
embeds the LLVM 23.1.6 Windows toolchain, which dominates its size).
Synthetic (non-game) UI captures (pre-0.1.2) are in `docs/ui/v4-*.png`; the 0.1.2
Deploy-prerequisite and Settings renders are generated into `out/ui-smoke/` (gitignored)
by the developer-only `--ui-smoke` mode. The Windows 11 device path (import, local
compile, Impactor signing, devpush and launch) was verified by the maintainers on the
0.1.0 build; the 0.1.1-0.1.5 additions still need a device pass (device acceptance
steps: see the root [README.md](../../README.md) usage section).

Architecture correction (Lead, 2026-11-14): iOS cannot dlopen a loose unsigned
dylib from Documents. The **GamePack.dylib lives inside the signed app IPA**
(Frameworks/GamePack-<TITLEID>.dylib + bundle GameCatalog.json); Documents only
receives the user's **GameRom.cci + optional cover.png + GameInfo.json** (the
manifest is pushed last). Adding/removing a game
recomposes and reinstalls the IPA; pushed ROM data is expected to survive an
overwrite install/update (a clean uninstall clears app data; verify on device).

The pushed `GameInfo.json` now also carries the base metadata the launcher
already read from the ROM's SMDH at import time, so the iOS library card needs no
ROM parsing at all: `displayName` (the SMDH title for the launcher's current UI
language, English fallback), `displayNames` (every localized SMDH title, the
original languages preserved), `publisher`, optional `region` (from the SMDH
region-lockout bits, e.g. `EU` / `US` / `EU+AU` / `region-free`; omitted when
unknown), optional `cover` (the pushed `cover.png` file name; the icon is local
user data and is never committed), `rom.size`/`rom.sha256` (the real pushed data,
re-checked by the shell), `launcherVersion` and `pushedAt`. `schemaVersion` stays
1, every added field is optional, and older manifests keep parsing.

Shell-template identity is validated before signing: version >= 0.1.0, build >= 1
(manifest and Info.plist), bundle catalogue schema 2 + empty for the template, no
Roms/. The shipped template is **0.1.5 / build 1** (6,259,066 B, SHA-256
`72b08c96…b081e0`; rebuilt from current main for the 0.1.5 release; Zakuro stays
pinned to upstream fdf67b2 with patches 0001–0008, including the GPU presenter
layouts, so the device static library is 64,560,088 B sha256 `d5bd801e…`; the
shell's CFBundle version is numeric 0.1.5 and ThreeDS2ApplePackageVersion=0.1.5;
the pre-reset template was 0.2.2 build 10) and additionally contains
`Frameworks/MoltenVK.framework` (GPU renderer + Metal HUD); `IpaComposer` copies
every non-GamePack template entry, so the framework survives composition and is signed
with the app. Device identifiers (UDID, usbmux id, serial number, ECID) are never
written to the UI, the launcher log or the diagnostics export: UI/log text uses a
non-identifying description such as `iPhone (USB)`, and a full identifier only ever
travels as an internal devpush/plumesign command argument.

## What it does

1. **Library**: import a decrypted .3ds/.cci you own. Only headers are read (title ID,
   product code, name) by the existing 3ds2apple-pack CLI; the ROM is not copied. List,
   remove, and pre-build games: **Build now** on one card or **Build all** in the header
   compiles the GamePack ahead of a deploy and shows progress + the recorded cache state.
   Cards show the title, publisher, ROM size, GamePack size/state and the build-cache
   label (`Built · cache b1a2b3c4` or the exact reason a rebuild is needed); a game
   that was never built shows one combined status line (Deploy compiles it
   automatically, Build now compiles it ahead of time) instead of two near-duplicates. SHA-256
   values stay in the verification/log output and are not shown as raw digests in the UI.
   Install/push actions stay on the Deploy page.
2. **Deploy**: the page opens with a prerequisite panel — five green/red status lights
   (iPhone/iPad connected over USB, signing tools pinned to the Impactor v2.7.3 SHA-256,
   local build toolchain, devpush device bridge, shell template) with one short fix hint
   on every red row; **Refresh status** re-probes everything (opening Deploy does too) and
   **Open Impactor** covers the Apple-ID login the launcher cannot detect. Then tick one
   or many library games and press **一键部署 / Deploy selected**. The launcher first reads
   the connected phone (installed app version, installed games, deploy marker) and skips
   every step that is already current - the "Device state" card shows what it found and
   what the run will do (see "Device-aware incremental deploy" below). One action then runs,
   in order, with a live per-step state and one Retry button on failure:
   - compile each selected game locally (3dsrecomp + open-source LLVM/LLD on this PC; real
     packs already built are reused). The old macOS Build Agent / preview choices are gone
     and there is no silent fallback — a missing toolchain is one actionable error.
   - compose one ROM-free app IPA from the pinned shell template + all selected packs +
     a schema-2 GameCatalog.json, and **verify the packs + catalogue before signing**.
   - sign and install the whole IPA with the bundled official Impactor v2.7.3 + plumesign
     (unmodified, SHA-256 pinned, MIT + MPL-2.0 licences preserved).
   - push each selected GameRom.cci + optional cover.png + GameInfo.json (last) into
     Documents/Games/<TITLEID>/ via the device bridge (devpush contract v1) using the
     **actual installed bundle id**, with size/SHA verification and read-back.
   - mark done ("可以在手机上玩了") only after every selected game verified.
     While the chain runs a **Stop** button stops it: the cancellation token reaches
     compile/compose/install/push/verify, the running step's whole process tree is
     terminated (Windows falls back to `taskkill /T /F`), the stopped step is marked
     "Cancelled" and the page returns to a deployable state; compiled packs are kept
     for the next attempt. Closing the launcher window during a deploy runs the same
     cleanup before the window closes, so no background compiler/signer survives.
3. **Settings** (gear): language, Apple ID / Open Impactor, device status/refresh, logs
   (show/export/open/self-test), about. The language picker keeps showing the current
   language after a switch (labels refresh in place; the persisted key format is
   unchanged). Build mode, tool paths, UDID and bundle-id overrides are no longer user
   settings — bundled tools are auto-detected, and the device UDID is internal only
   (never displayed or logged).

No ROM, key, IPA, generated C or Apple credential is stored in this repository.

### Build cache: what makes a GamePack reusable

Each successful local build records a **`buildCompatVersion`** marker plus the ROM
SHA-256 in `state.json` (user data, never in a log). The marker is composed of the
recompiler ABI/generation, GamePack dylib ABI, hand-written shim ABI, catalogue and
GameInfo schema versions, and the probed clang/ld64.lld versions. Deploy and both
"Build now"/"Build all" reuse a cached GamePack **only when the marker and the ROM
SHA-256 both still match** the current state; a launcher or shell update with an
unchanged build recipe keeps the cache, while a toolchain/shim/schema change or a
changed ROM forces a rebuild. The ROM is re-hashed whenever its size or last-write
time changed; the Library card only compares that cheap fingerprint and the recorded
marker, so no multi-GB ROM is read just to draw the card. The marker is deliberately
independent of the launcher and shell versions, so updating the launcher or the shell
template with an unchanged recipe keeps every GamePack. Packs built by a launcher
older than 0.1.2 have no marker yet: they are rebuilt once on the next Deploy or
"Build now", after which the cache applies normally.

### Device-aware incremental deploy (0.1.6-beta2)

Deploy no longer always composes, installs and pushes everything. Once the phone is
connected it reads the device state before building anything:

- `devpush app-attr --json` for the installed app identity: `CFBundleShortVersionString`,
  `CFBundleVersion` and the shell's own `ThreeDS2ApplePackageVersion`;
- `devpush ls Documents/Games` plus `stat` for each `GameRom.cci` / `GameInfo.json`;
- `Documents/.3ds2apple-deploy.json` — a launcher-written marker recording the app
  package version and, per installed game, the `buildCompatVersion`, GamePack SHA-256 and
  ROM SHA-256 of the last successful deploy.

Rules (implemented by `Deploy/DeviceDeployState.cs` `DeviceDeployPlanner` and unit
tested in `DeviceDeployTests.cs`; the Deploy page shows them in the "Device state" card
and the log):

| Phone state | Deploy action |
|---|---|
| App not installed | full flow: compile, compose, sign, install, push the selected games |
| App package version differs from the launcher shell (or an old shell does not report it) | recompose an IPA with the union of the installed games' GamePacks and the selected ones, overwrite-install (Documents and saves are preserved), then push only missing/outdated data |
| No marker on an existing install | unknown state: update once (union with every built library game) and seed the marker |
| App current, a GamePack build identity changed | recompose + overwrite-install, then push only changed data |
| App current, only data missing/outdated | push only; no reinstall |
| Phone has game data whose TITLEID is not in this library (orphaned) | the data is never touched/deleted; when an overwrite install is needed the deploy pauses with a warning and a confirmation button (import+build the ROMs to keep their app entries, or confirm: app entries disappear, GameRom/saves stay, and the marker records them as data-only) |
| Everything current | no-op: "already up to date" |

Phone-only ("orphaned") game data is never deleted and never silently dropped: the
Deploy page lists those games in the device-state card, and an overwrite install stops at
the warning/confirmation card unless the user explicitly confirms. After a confirmed
update the marker records those TITLEIDs as `dataOnly` (their GameRom/saves stay in
Documents, only the app entry is gone) and the device card keeps showing them; importing
the ROM and building its GamePack brings the game back on the next deploy.

The app is never uninstalled (a clean uninstall would clear Documents/saves). Skipped
steps are reported as `Skipped` with the reason; the marker is written after a successful
install/push, and a marker write failure only warns (the next deploy treats the phone
state as unknown and updates once). The macOS launcher keeps the previous full deploy
path for now: this incremental behaviour is Windows-only.

### Portable .32a build packages (Library export/import)

Each Library card has **Export .32a** next to **Build now** (enabled only for a
real AOT GamePack) and the Library header has **Import .32a**. The launcher only
passes paths and parses the pack CLI JSON; the Rust CLI
(`3ds2apple-pack builds export|import|list`, see
[builder/README.md](../../builder/README.md)) is the single writer/validator of
the format.

- Export writes `<portable data root>/workspace/builds/<build-slug>.32a`, a ZIP
  with `manifest.json` (schema v1), `GamePack-<TITLEID>.dylib`, `GameInfo.json`,
  optional `cover.png` and the user's `GameRom.<ext>` when the CLI can find it
  (the package copy, the queued ROM path or `workspace/launcher-roms`). Without a
  ROM the export still succeeds and the UI states that deploying it needs the
  original ROM.
- Import validates the ZIP/manifest/SHA-256/Mach-O structure, installs into
  `workspace/out/packages/<TITLEID>/`, marks the queue built and refreshes the
  Library so the game is immediately deployable. An existing package is reported
  as a conflict with a **Replace existing package** confirmation (unrelated user
  files in the package directory are kept).
- The result path (or the exact error) is shown inline in the Library and in the
  launcher log; the UI states that **a .32a can contain game data, so it must stay
  local** (never upload or commit it). Nothing is signed, installed or uploaded.
- Tests: `BuildPackageServiceTests.cs` (argument mapping, JSON parsing,
  conflict/replace, missing CLI, workspace state) and the Rust `builder/pack`
  tests (`builds::tests` + the CLI round trip in `tests/cli_local.rs`).

### Unsigned single-game IPA export (Library row "Export IPA")

Each Library card with a real AOT GamePack has **Export IPA** next to
**Export .32a**/**Build now**. It composes one unsigned single-game IPA from the
pinned ROM-free shell template:

1. the pack CLI writes a schema-2 `GameCatalog.json` for the one title with
   `--auto-launch` (the additive root field `autoLaunch: true`; the iOS shell
   opens the game as soon as its library is ready);
2. `IpaComposer` composes the template + the single `Frameworks/GamePack-<TITLEID>.dylib`
   into a ROM-free app IPA;
3. the IPA is rewritten to carry the autoLaunch catalogue and to replace every
   template `AppIcon*.png` with the game's SMDH cover resized to the template
   pixel size (SkiaSharp; the 48x48 SMDH icon is upscaled, which is soft but
   recognisable). A missing/unreadable cover keeps the template icons and adds a
   warning;
4. the result is verified (Payload/*.app, no `Roms/`, schema-2 catalogue with the
   title + autoLaunch, GamePack present, SHA-256) and written to
   `<portable data root>/workspace/exports/<build-slug>-<version>-unsigned.ipa`.

The UI shows the output path plus **unsigned IPA: sign it with Sideloadly or
AltStore before installing**. Nothing is signed, installed or uploaded. Tests:
`SingleGameIpaExportTests` (icon generator, IPA structure/catalogue, missing
cover fallback, template/pack/catalog failures).

## Stack

- .NET 10 + **Avalonia 12.1.6** desktop UI (same stack family S2Arm's Windows
  launcher uses; our code is original — S2Arm is an Apache-2.0 reference only).
- Projects: ThreeDsTwoApple.Launcher.Core (no UI: tool clients, contracts, batch
  Deploy pipeline + device-aware deploy planner + composed-IPA verifier, IPA composition,
  signing, push, localization catalog, embedded single-file payload, build-compatibility
  cache) / ThreeDsTwoApple.Launcher.Desktop (Avalonia shell) /
  ThreeDsTwoApple.Launcher.Core.Tests (240 xUnit tests).
- All external work goes through CLI tools passed as argument arrays (never a
  shell string): 3ds2apple-pack, devpush, the official plumesign.
  The launcher never re-implements ROM parsing, the AOT compile/link,
  AFC/house_arrest or signing.

## Layout

    launcher/windows/
      Launcher.slnx                     solution (Core + Desktop + tests)
      Directory.Build.props             shared C# settings
      build.ps1                         build / test / self-test wrapper
      src/ThreeDsTwoApple.Launcher.Core/
        LauncherServices.cs             composition root (tools, workspace, clients)
        SelfTest.cs                     --self-test host check
        Localization/Localization.cs    English + zh-Hans UI catalogue, OS detection, override
        Distribution/DistributionLayout.cs  embedded payload inventory + first-run extraction
        Tools/                          ProcessRunner + process-tree killer/shutdown registry, PackCli
                                        (inspect/add/list/catalog/record/verify), ToolLocator
        Deploy/DeployOrchestrator.cs            one-click Build->Compose->Install->Push->Verify chain + injected interfaces
        Deploy/ComposedIpaVerifier.cs           hard gate: all real packs + non-empty schema-2 catalogue before signing
        BuildPipeline/IpaComposer.cs            shell template + packs + GameCatalog -> installable IPA
        BuildPipeline/LocalWinbuildPackProvider.cs  3dsrecomp + LLVM/LLD local build (the only Deploy path)
        BuildPipeline/BuildCompatibility.cs     buildCompatVersion marker + build-cache reuse policy
        BuildPipeline/LibraryBuildService.cs    Library "Build now"/"Build all" (same cache rules as Deploy)
        BuildPipeline/BuildProviders.cs         build provider contract + preview placeholder (not offered by the v2 UI)
        BuildPipeline/GamePackInspector.cs      Mach-O check so only real AOT packs are installed
        BuildPipeline/BuildSlug.cs              deterministic ASCII build slug for the local build
        Signing/                        Impactor pins/verifier, plumesign runner, error catalog,
                                        shell template manifest + whole-IPA install service
        Device/                         devpush/1 JSON/NDJSON client + read-only usbmuxd ListDevices
        Deploy/                         GameInfo.json writer, ROM+GameInfo push plan + verification
        LauncherState/                      persistent state + logs (portable workspace)
      Portable/                           <exe-dir>/3ds2apple-data layout policy, writability
                                          probe, one-time LocalAppData workspace migration
      Hardware/                           logical/physical cores + RAM probe for the compile line
      src/Launcher.Desktop/             Avalonia UI (Program, App, MainWindow, view model,
                                        Localization/LocalizedText, Assets/app.ico + placeholder)
      tests/ThreeDsTwoApple.Launcher.Core.Tests/   240 xUnit tests (incl. DeployFlowTests + DeviceDeployTests +
                                                  DeployCancellationTests + ProcessRunnerTests + BuildCacheTests +
                                                  ComposedIpaVerifierTests)
      vendor/impactor/             PINS.json + MIT / MPL-2.0 licence texts + source note
      shell/                            shell template IPA placement + manifest example (unchanged):
                                        the template is ROM-free and pinned; packs are injected at install time
      docs/ui/                          rendered UI evidence (English + 简体中文 screenshots)
      tools/                            fetch-impactor.ps1/.sh (verified official v2.7.3),
                                        prepare-dist.ps1 (multi-file dev package),
                                        prepare-dist-singlefile.sh/.ps1 (exe + licence-text ZIP)
      .gitignore                        excludes bin/obj and downloaded third-party binaries

Directory names are chosen so the repository-wide ignore rules cannot hide them:
build/ would hide Build/, workspace/ would hide Workspace/, third_party/ would hide
third_party/ - so the source dirs are BuildPipeline/ and LauncherState/ and the pinned
Impactor metadata lives under vendor/impactor/ (verified with git check-ignore).

## Requirements

End user (Windows): Windows 10 22H2/11 x86_64; Apple Devices (or iTunes) for the
USB device service; USB data cable; iPhone/iPad with Developer Mode, trusted and
unlocked during install/push; the user's own legally acquired decrypted ROMs.

Developer: .NET 10 SDK (NuGet once); optional Rust for 3ds2apple-pack /
devpush; PowerShell 5.1+ for the packaging scripts.

Real AOT builds run locally: 3dsrecomp + the official LLVM 23.1.6 toolchain and
the hand-written Darwin stubs in tools/winbuild (see tools/winbuild/README.md). No Mac,
no Xcode and no Build Agent are required; the old remote macOS Build Agent stack
was deleted on 2026-11-16.

## Build and test on Windows

    cd launcher/windows
    powershell -ExecutionPolicy Bypass -File build.ps1 -Task all
    # or:
    dotnet build Launcher.slnx -c Debug
    dotnet test tests/ThreeDsTwoApple.Launcher.Core.Tests/ThreeDsTwoApple.Launcher.Core.Tests.csproj
    dotnet run --project src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj -- --self-test
    dotnet run --project src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj

## Build and test on Linux/WSL (what CI can do)

    export DOTNET_ROOT=$HOME/.dotnet10
    export PATH=$HOME/.dotnet10:$PATH
    dotnet build Launcher.slnx
    dotnet test tests/ThreeDsTwoApple.Launcher.Core.Tests
    dotnet src/Launcher.Desktop/bin/Debug/net10.0/3ds2apple-launcher.dll --self-test

Evidence from this checkout: solution build succeeded (0 errors, warnings as
errors), **125/125 tests passed** (3 consecutive runs). The final single-file package
`out/launchers/3ds2apple-windows-single-0.2.2.zip` (150,011,456 B, SHA-256
`37e659542ba6499d7154a00543bc2d6ab4b894a51a8706f98ff2d1e5107b4782`) contains exactly one
`3ds2apple-launcher.exe` (156,653,598 B, SHA-256
`42568da15a6de4856b32e8e363c9410240de6f67abd023435c1e1f5360d74207`). It embeds the
0.2.2/build-10 shell template (incl. MoltenVK framework), pinned official Impactor
v2.7.3/plumesign, the Bin tool CLIs, 3dsrecomp.exe and the official LLVM 23.1.6 payload
(326 embedded files, staged explicitly with `THREEDS2APPLE_LLVM_DIR`). Its clean-folder `--self-test` PASSes on the Linux/WSL host
(first-run extraction exercised with an isolated HOME) and on real Windows 11 (all checks
PASS, no warnings, shell template v0.2.2). Real Windows window captures in English and
Simplified Chinese, plus a headless render of the red not-ready status light, are under
`docs/ui/v4-*.png`.

## Assemble a distribution (release step)

    powershell -ExecutionPolicy Bypass -File tools/fetch-impactor.ps1   # official v2.7.3, verified
    powershell -ExecutionPolicy Bypass -File tools/prepare-dist.ps1 -Version 0.2.2
    # -SkipShell builds a preview package without the shell template IPA

prepare-dist.ps1 publishes the launcher self-contained multi-file (developer mode:
users install no .NET), builds/copies Bin/3ds2apple-pack.exe, Bin/devpush.exe,
adds the verified ThirdParty/Impactor bundle and the pinned
shell template IPA + manifest, and writes SHA256SUMS.

## Single-file one-exe distribution (task-28)

The shipped Windows package is a ZIP containing `3ds2apple-launcher.exe`
(self-contained .NET single-file) plus `LICENSE`, `NOTICE` and `THIRD_PARTY.md` at
the ZIP root, byte-identical to the repository files and enforced by
`scripts/release/verify-release.sh`. Release builds embed the
ROM-free shell IPA + manifest, the pinned official Impactor/plumesign + licence texts,
`Bin/3ds2apple-pack.exe`, `Bin/devpush.exe` and
LICENSE/NOTICE/THIRD_PARTY as resources; on first run they are extracted to
`%LOCALAPPDATA%\3ds2apple\distribution\<version>\` and every tool/service resolves from
there. `THREEDS2APPLE_DIST` and the multi-file layout still work for development.

    # stage shell/manifest.json + shell/3ds2apple-shell.ipa, vendor/impactor (verified),
    # and Bin/*.exe first (see shell/README.md, tools/fetch-impactor.sh)
    launcher/windows/tools/prepare-dist-singlefile.sh    # output defaults to out/launchers/
    # Windows twin: powershell -ExecutionPolicy Bypass -File tools/prepare-dist-singlefile.ps1
    unzip -l dist/3ds2apple-windows-single-<version>.zip   # exe + LICENSE + NOTICE + THIRD_PARTY.md
    # clean-folder check: copy only the exe into an empty folder and run --self-test

Staged payload inputs are git-ignored (`Bin/`, `shell/*.ipa`, `shell/manifest.json`,
`vendor/impactor/*.exe`); the release ZIP is never committed.

The shell template IPA is a macOS build product (ROM-free, empty catalogue) —
follow [shell/README.md](shell/README.md). It is deliberately absent from git.

## Manual verification

Check the packaged exe with its clean-folder `--self-test` (payload, shell
template, bundled Impactor/LLVM, tool probes) and Settings → self-test. The
end-to-end device flow (ROM import → local build → IPA composition → Impactor
sign-in → install/update → ROM-only push → verify-after-push) is the root
[README.md](../../README.md) usage section; signing error mapping stays in the
launcher error catalog (9120 / 9401 / 1100 / anisette / 2FA).

## Dependencies on other tasks

- **task-16/20 device bridge**: devpush/1 contract v1 is implemented by
  Core/Device/DevPushClient.cs and checked against the real binary + mock backend;
  [tools/devpush/README.md](../../tools/devpush/README.md) is authoritative. The
  launcher pushes GameRom.cci + cover.png (optional) + GameInfo.json directly via devpush.
- **task-17 shell**: the shell loads the pack from the bundle GameCatalog and the
  ROM from Documents; the GameInfo.json split was agreed (pack metadata is
  informational/bundle-relative, ROM is verified when present). The ROM-free shell
  template IPA artifact must be built on macOS and handed to this distribution.
- **task-22 local LLVM/lld**: implemented and now the only build path: GamePacks
  are compiled locally with 3dsrecomp + LLVM/LLD, so the launcher no longer needs
  a macOS host (the old Build Agent path was deleted on 2026-11-16).
- **Lead**: THIRD_PARTY/NOTICE were already updated by task-16 for Impactor (MIT),
  apple-codesign (MPL-2.0), idevice (MIT) and S2Arm (Apache-2.0 reference); the
  launcher's own licence texts live in vendor/impactor/.

## Legal

Only use ROMs you own and have decrypted yourself. This launcher does not provide,
download or unlock games, keys, BIOS/firmware or Apple credentials. The bundled
Impactor/plumesign are third-party tools distributed under their own licences; the
composed app IPA is ROM-free (game data is pushed separately) and must not be
redistributed with game data. See the project root NOTICE and THIRD_PARTY.md.
