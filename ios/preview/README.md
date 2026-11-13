# iOS Simulator UI preview

A second, simulator-only app that shows one real screen of the shell at a time,
so UI changes can be reviewed without a device, a ROM, or the Zakuro static
library.

The macOS build VM cannot link the shell for the simulator: `libzakuro_ios.a`
is an arm64 device build and has no simulator slice. The preview target
therefore compiles the real `ios/app/Sources` (minus `App.swift`, whose
`@main` is replaced by `PreviewMain.swift`) and links
`generated/ZakuroStub.c`: empty implementations of every `zk_*` function
the Swift sources reference. Nothing starts a console; the preview app never
calls `zk_create`.

| File | Purpose |
|---|---|
| `project.yml` | XcodeGen spec for the `3ds2apple-preview` app target |
| `PreviewMain.swift` | `@main` app plus the `ZKPREVIEW_SCREEN` switch |
| `generated/ZakuroStub.c` | generated C stubs, gitignored, do not edit |
| `../scripts/gen-zakuro-stub.py` | generate the stubs from `ios/ZakuroBridge.h` and the Swift sources |
| `../scripts/ios-ui-preview.sh` | build, boot a simulator, seed a fake library, screenshot every screen |

## Requirements

Run on the macOS VM (macOS 26.7, Xcode 26.6 with an iOS Simulator runtime
installed) from the repository root:

- Xcode with `xcodebuild`, `xcrun simctl` and an installed iOS runtime.
  If no runtime is installed: Xcode > Settings > Components, or
  `xcodebuild -downloadPlatform iOS`.
- XcodeGen 2.46. On the VM it is in `/usr/local/bin`, which is not always on
  PATH: `PATH=/usr/local/bin:$PATH scripts/ios-ui-preview.sh`.
- Python 3.

## Usage

    scripts/ios-ui-preview.sh
    scripts/ios-ui-preview.sh --screens home,settings,quick,ingame,savemanager,about
    scripts/ios-ui-preview.sh --dark --out-dir /tmp/ui-shots
    scripts/ios-ui-preview.sh --no-build --keep-simulator
    scripts/ios-ui-preview.sh --help

Screens: `home` (default), `settings`, `quick`, `ingame`, `savemanager`,
`about`. The default set is `home,settings,quick,ingame,savemanager`.
PNGs go to `ios/preview/build/screenshots/<screen>.png` and the script prints
their absolute paths at the end. `--dark` sets `ZKPREVIEW_DARK=1`, and
`--launch-delay` tunes the wait between launch and screenshot.

## What the script does

1. Generates `ios/preview/generated/ZakuroStub.c` from
   `ios/ZakuroBridge.h` and the `zk_*` identifiers in
   `ios/app/Sources` (fails non-zero if a declaration cannot be generated
   or the Swift sources call an undeclared `zk_*` function).
2. Runs `xcodegen generate --spec ios/preview/project.yml --project
   ios/preview/build --project-root <repo root>`, so the generated project is
   `ios/preview/build/3ds2apple-preview.xcodeproj` (gitignored) and the
   spec's paths stay repository-relative.
3. Builds unsigned with `xcodebuild ... -sdk iphonesimulator -configuration
   Debug -destination 'generic/platform=iOS Simulator'`.
4. Picks the newest available iOS runtime and prefers an `iPhone 14 Pro Max`
   device type (falling back to the first iPhone), creates a device when none
   exists, boots it headless and waits with `simctl bootstatus -b`.
5. Installs the app, writes three synthetic `GameEntry` records to
   `Documents/Library/library.json` plus few-KB placeholder files under
   `Documents/roms/` (never real ROM data), then launches once per screen
   with `SIMCTL_CHILD_ZKPREVIEW_SCREEN=<screen>` and captures
   `xcrun simctl io <udid> screenshot`.
6. Shuts the simulator down (or deletes it when the script created it) unless
   `--keep-simulator` is passed.

Everything is local: no network access, and nothing outside
`ios/preview/build/` and the gitignored `ios/preview/generated/` is written.

## Environment variables read by the preview app

- `ZKPREVIEW_SCREEN` - screen to show (default `home`; unknown values fall
  back to home without crashing).
- `ZKPREVIEW_DARK=1` - force dark mode (the in-game screen is dark anyway).

The simulator passes variables to the app only with the `SIMCTL_CHILD_`
prefix, which the script adds.

## Known caveats

- The stubs return 0 or NULL, so runtime-derived values are neutral in the
  screenshots: `zk_screen_width()` is 0, `zk_linked_code()` is 0, and the
  bundled game catalog is empty. The home screen's AOT badge therefore reads
  "interpreter" for every seeded game. Layout must not depend on those values.
- The preview compiles whatever is in `ios/app/Sources` right now. If the
  working tree does not compile, the preview does not compile either; fix the
  shell first.
- `PreviewMain.swift` mirrors the initializer labels of the views in
  `ios/app/Sources`. If a view's parameter list changes, update the matching
  case here too.
- Never edit the generated Xcode project under `ios/preview/build/`; it is
  regenerated on every run.
- If `simctl` has no available iOS runtime the script stops with a hint
  (download one in Xcode or with `xcodebuild -downloadPlatform iOS`).
- Xcode 26.6 is the last Intel-compatible Xcode; the project deliberately builds
  both simulator slices so the Intel VM can install the app.

## Manual equivalent

    python3 scripts/gen-zakuro-stub.py
    xcodegen generate --spec ios/preview/project.yml --project ios/preview/build --project-root "$(pwd)"
    xcodebuild -project ios/preview/build/3ds2apple-preview.xcodeproj \
        -scheme 3ds2apple-preview -sdk iphonesimulator -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath ios/preview/build/DerivedData build
    # then: simctl boot/install/launch/screenshot as described above
