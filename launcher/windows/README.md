# 3ds2apple launcher for Windows (MVP)

Status: **source-complete MVP skeleton, not a shipped installer.** This checkout
compiles cleanly (0 errors), its **35 unit tests pass**, the host self-test passes
and the tool contracts were exercised against the real Rust CLIs. The graphical UI,
the Impactor signing run and the phone flows still need verification on a real
Windows PC with an iPhone/iPad; the exact steps are in
[docs/windows-launcher.md](../../docs/windows-launcher.md) (section 11).

Architecture correction (Lead, 2026-11-14): iOS cannot dlopen a loose unsigned
dylib from Documents. The **GamePack.dylib lives inside the signed app IPA**
(Frameworks/GamePack-<TITLEID>.dylib + bundle GameCatalog.json); Documents only
receives the user's **GameRom.cci + GameInfo.json**. Adding/removing a game
recomposes and reinstalls the IPA; pushed ROM data is expected to survive an
overwrite install/update (a clean uninstall clears app data; verify on device).

Shell-template identity is validated before signing: version >= 0.2.0-beta1,
build >= 9 (manifest and Info.plist), bundle catalogue schema 2 + empty for the
template, no Roms/. Device UDIDs are redacted in all UI/log output.

## What it does

1. **Import** a decrypted .3ds/.cci ROM you own. Only headers are read (title ID,
   product code, name) by the existing 3ds2apple-pack CLI; the ROM is not copied.
2. **Build** the per-game GamePack. Real AOT code needs Apple's iOS toolchain, so
   the build runs on your own macOS host through the existing builder-windows Build
   Agent; the launcher shows progress and extracts
   Frameworks/GamePack-<TITLEID>.dylib from the produced app.
3. **Install / update the app** (Device tab): the launcher composes a ROM-free IPA
   from the pinned shell template + every built pack + a generated GameCatalog.json,
   then signs and installs the **whole IPA** with the bundled official Impactor
   v2.7.2 + plumesign (unmodified, SHA-256 pinned, MIT + MPL-2.0 licences
   preserved). IPA signing covers the nested Frameworks dylibs.
4. **Push ROM data** (Push tab): only GameRom.cci and GameInfo.json go into
   Documents/Games/<TITLEID>/ through the device bridge CLI (devpush, task-16/20
   contract v1), with progress, resume, stall handling and read-back verification.
   GameInfo.json goes last; the shell shows "Data missing" until it verifies.

No ROM, key, IPA, generated C or Apple credential is stored in this repository.

## Stack

- .NET 10 + **Avalonia 12.1.5** desktop UI (same stack family S2Arm's Windows
  launcher uses; our code is original — S2Arm is an Apache-2.0 reference only).
- Projects: ThreeDsTwoApple.Launcher.Core (no UI: tool clients, contracts, IPA
  composition, signing, push) / ThreeDsTwoApple.Launcher.Desktop (Avalonia shell) /
  ThreeDsTwoApple.Launcher.Core.Tests (35 xUnit tests).
- All external work goes through CLI tools passed as argument arrays (never a
  shell string): 3ds2apple-pack, builder-windows, devpush, the official plumesign.
  The launcher never re-implements ROM parsing, the Build Agent protocol,
  AFC/house_arrest or signing.

## Layout

    launcher/windows/
      Launcher.slnx                     solution (Core + Desktop + tests)
      Directory.Build.props             shared C# settings
      build.ps1                         build / test / self-test wrapper
      src/ThreeDsTwoApple.Launcher.Core/
        LauncherServices.cs             composition root (tools, workspace, clients)
        SelfTest.cs                     --self-test host check
        Tools/                          ProcessRunner, PackCli (inspect/add/list/catalog/record/verify),
                                        BuilderCli (macOS Build Agent), ToolLocator
        BuildPipeline/IpaComposer.cs            shell template + packs + GameCatalog -> installable IPA
        BuildPipeline/BuildProviders.cs         Preview / MacAgentIpa / MacAgentPack (refuses until implemented)
        BuildPipeline/IpaPackExtractor.cs       transitional per-game IPA -> GamePack.dylib adoption
        Signing/                        Impactor pins/verifier, plumesign runner, error catalog,
                                        shell template manifest + whole-IPA install service
        Device/                         devpush/1 JSON/NDJSON client + read-only usbmuxd ListDevices
        Deploy/                         GameInfo.json writer, ROM+GameInfo push plan + verification
        LauncherState/                      %LOCALAPPDATA%/3ds2apple/launcher state + logs
      src/Launcher.Desktop/             Avalonia UI (Program, App, MainWindow, view model)
      tests/ThreeDsTwoApple.Launcher.Core.Tests/   35 xUnit tests
      vendor/impactor/             PINS.json + MIT / MPL-2.0 licence texts + source note
      shell/                            shell template IPA placement + manifest example (unchanged):
                                        the template is ROM-free and pinned; packs are injected at install time
      tools/                            fetch-impactor.ps1/.sh (verified official v2.7.2), prepare-dist.ps1
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
builder-windows / devpush; PowerShell 5.1+ for the packaging scripts.

Real AOT builds additionally need a macOS host the user controls with Xcode and
the project's Build Agent (builder/README.md). The project never downloads Xcode.

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

Evidence from this checkout: solution build succeeded (0 errors; 0 warnings after
fixing obsolete XAML properties), **57/57 tests passed**, self-test OK. With the
real Rust tool binaries on DEVPUSH_EXE / THREEDS2APPLE_PACK / THREEDS2APPLE_BUILDER
the self-test reports PASS for all tools and one WARN (Impactor bundle not
downloaded in a source checkout). Real devpush was driven through its mock backend
with the launcher's exact command shapes. The Avalonia window was started under
Xvfb; real UI interaction is part of the Windows manual test plan.

## Assemble a distribution (release step)

    powershell -ExecutionPolicy Bypass -File tools/fetch-impactor.ps1   # official v2.7.2, verified
    powershell -ExecutionPolicy Bypass -File tools/prepare-dist.ps1 -Version 0.1.0
    # -SkipShell builds a preview package without the shell template IPA

prepare-dist.ps1 publishes the launcher self-contained (users install no .NET),
builds/copies Bin/3ds2apple-pack.exe, Bin/devpush.exe, Bin/builder-windows.exe, adds
the verified ThirdParty/Impactor bundle and the pinned Shell/ template IPA +
manifest, and writes SHA256SUMS.

The shell template IPA is a macOS build product (ROM-free, empty catalogue) —
follow [shell/README.md](shell/README.md). It is deliberately absent from git.

## Manual verification

Run the Windows test plan in [docs/windows-launcher.md](../../docs/windows-launcher.md)
(section 11). It covers --self-test, missing-tool messages, ROM import/detection,
preview vs Build Agent build, app IPA composition (including a template-with-ROM
rejection), Impactor sign-in, signing error mapping (9120 / 9401 / 1100 / anisette /
2FA), install/update of the app with one and then two games, ROM persistence across
reinstall, ROM-only push, resume/stall handling and verify-after-push.

## Dependencies on other tasks

- **task-16/20 device bridge**: devpush/1 contract v1 is implemented by
  Core/Device/DevPushClient.cs and checked against the real binary + mock backend;
  docs/device-bridge.md is authoritative. task-20 changed push-game to ROM+GameInfo
  only; our launcher already pushes exactly those two files directly via devpush.
  The Python wrapper (device-install/1) remains an optional consolidation point.
- **task-17 shell**: the shell loads the pack from the bundle GameCatalog and the
  ROM from Documents; the GameInfo.json split was agreed (pack metadata is
  informational/bundle-relative, ROM is verified when present). The ROM-free shell
  template IPA artifact must be built on macOS and handed to this distribution.
- **task-22 local LLVM/lld**: parallel investigation into building GamePacks without
  a macOS SDK; until it is proven, the macOS Build Agent remains the only real
  build path and the launcher says so (no fake success).
- **Lead**: THIRD_PARTY/NOTICE were already updated by task-16 for Impactor (MIT),
  apple-codesign (MPL-2.0), idevice (MIT) and S2Arm (Apache-2.0 reference); the
  launcher's own licence texts live in vendor/impactor/.

## Legal

Only use ROMs you own and have decrypted yourself. This launcher does not provide,
download or unlock games, keys, BIOS/firmware or Apple credentials. The bundled
Impactor/plumesign are third-party tools distributed under their own licences; the
composed app IPA is ROM-free (game data is pushed separately) and must not be
redistributed with game data. See the project root NOTICE and THIRD_PARTY.md.
