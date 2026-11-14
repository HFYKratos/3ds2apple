# 3ds2apple macOS launcher (MVP)

A SwiftUI macOS app that drives the AOT-first product flow:

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

## Status

- MVP: ROM import + title detection, GamePack build orchestration (dry run / fake
  preview / real macOS build), base-shell install wrapper with Apple-ID readiness
  checks and plain-language signing errors, Documents/Games push planner and
  runner, library/status UI, logs, environment diagnostics, mock/dry-run mode.
- The device bridge is task-16's `tools/devpush`; the launcher is written against
  the published contract v1 and runs in mock mode until that binary exists
  (`DEVPUSH_EXE` or `tools/devpush/target/release/devpush`).
- Real device install/push is documented manual-test only: the shared build VM
  has no Apple ID signing assets and no phone attached.

## Build and run (macOS 13+, Xcode 15+; tested with Xcode 26.6)

    cd launcher/macos
    PATH=/usr/local/bin:$PATH xcodegen generate --spec project.yml
    xcodebuild -project 3ds2apple-launcher.xcodeproj \
      -scheme 3ds2apple-launcher -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath build build
    open build/Build/Products/Debug/3ds2apple-launcher.app

Headless modes (used on the build VM and in CI-like checks):

    BIN=build/Build/Products/Debug/3ds2apple-launcher.app/Contents/MacOS/3ds2apple-launcher
    "$BIN" --selfcheck                         # logic self-checks, exit 0/1
    "$BIN" --screenshot-dir screenshots --mock # offscreen non-game UI PNGs

`scripts/vm-build.sh` does all three steps (build, self-check, screenshots) in one
shot on a machine with Xcode; it needs no ROM, phone, Apple ID or network.

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
      AppModel.swift           state machine: import -> build -> install -> push
      Models.swift             value types shared by pipeline, bridge and UI
      LauncherSettings.swift   paths/mode/team settings + checkout detection
      CommandRunner.swift      async Process wrapper + mock runner
      Toolchain.swift          toolchain/Apple-ID readiness probe
      PackBackend.swift        typed 3ds2apple-pack CLI wrapper + JSON parsing
      GameInfoWriter.swift     launcher -> shell GameInfo.json (push layout)
      PushPlanner.swift        Documents/Games/TITLEID plan, GameInfo.json last
      InstallBackend.swift     xcodebuild signing + devicectl install + error mapper
      DeviceBridge.swift       devpush contract v1 client (NDJSON) + mock bridge
      MockBackends.swift       deterministic fixtures, mock CLI/installer/bridge
      SelfCheck*.swift         headless logic checks (PASS/FAIL lines)
      SnapshotRenderer.swift   offscreen SwiftUI screenshots
      Views/                   theme, components, shell, seven screens
    scripts/vm-build.sh        build + self-check + screenshots on a Mac
    screenshots/               generated non-game UI evidence (committed)

## Modes

- **Live**: real CLI, real Xcode, real device bridge.
- **Mock / dry run**: `--selfcheck`/`--screenshot-dir` and the mock backends;
  deterministic fixtures, no ROM/device/Apple-ID. The sidebar shows a MOCK badge.
- **Dry run** (build mode): runs the desktop CLI in plan mode; writes nothing.
- **Fake preview pack**: labelled placeholder pack for layout tests; the push
  planner refuses it.
- **Real AOT build**: runs `3ds2apple-pack build --queued --execute`, which drives
  `scripts/build-recomp-ios.sh` and `scripts/build-game-pack.sh` on this Mac.

## Evidence / QA

The build VM run (Xcode 26.6, headless) produced:

- xcodebuild: BUILD SUCCEEDED, 0 errors.
- self-check: 71/71 checks passed (launcher CLI/JSON contracts, 2-file push plan,
  library-IPA allocation, devpush NDJSON events, Apple 9120/9401 mapping, log
  redaction, full mock import -> build -> library -> data-push flow).
- screenshots/launcher-<screen>-dark.png (7 screens) + two light-theme shots,
  generated offscreen with SwiftUI ImageRenderer; MOCK / DRY RUN badge visible.

Full architecture, contracts, build commands and the manual device-test checklist
are in [docs/macos-launcher.md](../../docs/macos-launcher.md).

## Licensing / attribution

Apache-2.0, same as the repository. The launcher contains no third-party code.
The S2Arm-study checkout (Apache-2.0) was read as an architectural reference only;
no source was copied. Signing is done by Apple's Xcode tooling with the user's own
Apple ID; the official Impactor is never bundled by this app.
