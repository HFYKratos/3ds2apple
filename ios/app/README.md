# ios/app — 3ds2apple SwiftUI shell (I1 skeleton)

Minimal SwiftUI app that links the Zakuro iOS static library
(`build/ios/libzakuro_ios.a`, arm64, **no JIT**, interpreter fallback only) and
boots without a ROM.

I1 scope: the shell starts, proves the static library is linked by calling
`zk_screen_width()` / `zk_screen_height()`, and shows a "No ROM loaded"
placeholder. `zk_create()` is intentionally **not** called yet — ROM import is
I2.

## Layout

| Path | Purpose |
|---|---|
| `project.yml` | XcodeGen spec — the source of truth, do not hand-edit `*.xcodeproj` |
| `Sources/App.swift` | `@main` SwiftUI entry point |
| `Sources/ContentView.swift` | I1 UI: title, screen geometry from the static lib, no-ROM card |
| `../ZakuroBridge.h` | hand-written C ABI (`zk_*`), imported via the bridging header |
| `../../scripts/build-zakuro-ios.sh` | builds the static lib on macOS (I0) |

Generated `3ds2apple.xcodeproj/` and `build/` are **build artifacts**: never
commit them.

## Prerequisites (macOS build VM)

- macOS + Xcode 16.4 with the iOS 18.5 SDK (M0 baseline).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- The Zakuro static library, built once per FFI change:

  ```bash
  # from the repo root
  scripts/build-zakuro-ios.sh
  ls -lh build/ios/libzakuro_ios.a   # expected: ~52 MB, arm64
  ```

No iOS Simulator runtime is needed (and on this VM it is not installed).

## Quick path — automated build (I1-T2 scripts)

Once `scripts/build-ios-app.sh` and `scripts/package-ipa.sh` (build-infra,
I1-T2) are merged, prefer them over the manual steps below:

```bash
# from the repo root, on the macOS VM
scripts/build-ios-app.sh                 # xcodegen + xcodebuild; log under ios/app/build/logs/
scripts/build-ios-app.sh --keep-project  # keep ios/app/3ds2apple.xcodeproj for Xcode
scripts/package-ipa.sh                   # -> IPA/<name>.ipa + SHA256 (unsigned)
```

`build-ios-app.sh` fails fast when `<repo>/build/ios/libzakuro_ios.a` is missing
or empty, and removes the generated `.xcodeproj` afterwards unless it is
gitignored (it checks `git check-ignore`), so `git status` stays clean.
The manual commands and the linkage verification below remain the reference for
what the script does and the fallback when it is unavailable.

## Generate the Xcode project

Run from the repo root:

```bash
cd ios/app
xcodegen generate
```

This writes `ios/app/3ds2apple.xcodeproj`. Re-run it after any edit to
`project.yml`.

> The generated `.xcodeproj` is a build artifact and is not tracked yet (the
> Lead is adding `ios/app/3ds2apple.xcodeproj/` to `.gitignore`).
> `scripts/build-ios-app.sh` removes it after a run unless it is gitignored;
> for manual builds delete it before committing anything else.

## Build (unsigned, device SDK)

```bash
cd ios/app

xcodebuild \
  -project 3ds2apple.xcodeproj \
  -target 3ds2apple \
  -sdk iphoneos \
  -configuration Release \
  SYMROOT="$PWD/build" \
  OBJROOT="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

Products:

- App bundle: `ios/app/build/Release-iphoneos/3ds2apple.app`
- Executable: `ios/app/build/Release-iphoneos/3ds2apple.app/3ds2apple`

`-target` (not `-scheme`) is deliberate: the VM has no simulator runtime, and
scheme builds resolve destinations and fail with `Found no destinations`
(docs/milestones.md, M0 pitfall 5). `CODE_SIGNING_*` are also set in
`project.yml`; passing them on the command line keeps ad-hoc invocations safe.

`ios/app/build/` matches the repo-root `.gitignore` `build/` pattern, so build
output never dirties git.

## Verify the static library really linked

```bash
# 1. The 8 zk_* entry points exist in the archive we link.
nm -g ../../build/ios/libzakuro_ios.a \
  | grep -E ' _zk_(create|run_frame|screen_width|screen_height|read_screen|take_audio|set_input|destroy)$'
# expected: 8 defined (T) symbols

# 2. The app binary is arm64 and (usually) still carries them.
APP=build/Release-iphoneos/3ds2apple.app
file "$APP/3ds2apple"
nm -g "$APP/3ds2apple" | grep ' _zk_' || echo "stripped — check the archive instead"
ls -lh "$APP/3ds2apple"
```

Runtime probe: the UI must show `Upper screen 400 × 240` and
`Lower screen 320 × 240` (values come from the C calls — hardcoded strings
would mean the calls were optimized away), and the device log gets one line:

```bash
idevicesyslog | grep '\[3ds2apple\]'
# [3ds2apple] zk_screen_width(0)=400 zk_screen_height(0)=240 zk_screen_width(1)=320 zk_screen_height(1)=240
```

## Package an unsigned IPA

`scripts/package-ipa.sh` (I1-T2, owned by build-infra) automates this, writing
`IPA/<name>.ipa` plus a SHA256; the manual equivalent:

```bash
cd ios/app/build/Release-iphoneos
rm -rf Payload 3ds2apple-unsigned.ipa
mkdir -p Payload
cp -R 3ds2apple.app Payload/
zip -qry 3ds2apple-unsigned.ipa Payload
shasum -a 256 3ds2apple-unsigned.ipa
```

Keep the `.ipa` under `build/` or `IPA/` (both gitignored). Signing/installing
happens on the user's machine with Sideloadly/AltStore; the Apple ID is entered
only there and must never be written to the repo or shared with agents.

## How the link settings resolve

`SRCROOT` is the directory containing `3ds2apple.xcodeproj`, i.e. `ios/app`:

| Build setting | Raw value | Resolves to |
|---|---|---|
| `SWIFT_OBJC_BRIDGING_HEADER` | `$(SRCROOT)/../ZakuroBridge.h` | `ios/ZakuroBridge.h` |
| `HEADER_SEARCH_PATHS` | `$(SRCROOT)/..` | `ios/` |
| `OTHER_LDFLAGS` | `-L$(SRCROOT)/../../build/ios -lzakuro_ios` | `<repo>/build/ios/libzakuro_ios.a` |

If the repo is moved, nothing needs changing — all three are repo-relative.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ld: library not found for -lzakuro_ios` | Static lib missing: run `scripts/build-zakuro-ios.sh` on the VM and check `ls ../../build/ios/libzakuro_ios.a`. |
| `Undefined symbols for architecture arm64` after adding the lib | The Rust staticlib needs system frameworks not linked automatically. Add what the linker names (typical: `-framework Security`, `-framework CoreFoundation`, `-lc++`) to `OTHER_LDFLAGS` in `project.yml`, then re-run `xcodegen generate`. Report the exact linker output to the Lead/ios-shell instead of guessing silently. |
| `error: Found no destinations` | Build with `-target 3ds2apple -sdk iphoneos`, not `-scheme`/`-destination`. |
| `xcodebuild: error: requires Xcode` / `unable to find utility "xcodebuild"` | Select the VM's Xcode: `sudo xcode-select -s "$HOME/Applications/Xcode-16.4.0.app"` (M0 installed Xcode under `~/Applications`). |
| `.app` has an empty/odd name | `PRODUCT_NAME` / `EXECUTABLE_NAME` must stay explicit in `project.yml` (docs/milestones.md, M0 pitfall 6). |
| `error: bridging header '.../ZakuroBridge.h' does not exist` | Confirm `ios/ZakuroBridge.h` exists and the build setting is `$(SRCROOT)/../ZakuroBridge.h`. |
| `xcodegen: command not found` | `brew install xcodegen`. |
| `git status` shows `ios/app/3ds2apple.xcodeproj/` | Generated project is untracked until `.gitignore` covers it; `scripts/build-ios-app.sh` auto-removes it (or keeps it deliberately with `--keep-project`). Manual: `rm -rf ios/app/3ds2apple.xcodeproj` (regenerated on demand). `ios/app/build/` is already covered by the root `build/` ignore rule. |

## Rebuild after changes

```bash
cd ios/app
xcodegen generate   # only needed if project.yml changed
# ... edit Sources/*.swift ...
xcodebuild ... build   # same command as above
```

## Rules

- No ROMs, keys, BIOS/sysdata, IPAs, static libraries, generated C, or
  credentials in git. This directory contains source only.
- No CPU JIT: the runtime is built with the Cranelift shader JIT disabled.
- `ios/app/` is the ios-shell agent's write scope; `ios/zakuro-ios/` belongs to
  runtime-ffi, `scripts/` to build-infra.
