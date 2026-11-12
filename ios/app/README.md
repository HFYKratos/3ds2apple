# ios/app — 3ds2apple SwiftUI shell

Minimal SwiftUI app that links the Zakuro iOS static library
(`build/ios/libzakuro_ios.a`, arm64, **no JIT**, interpreter fallback only).

- **I1** (merged): the shell boots without a ROM, proves the static library is
  linked via `zk_screen_width()` / `zk_screen_height()`, and explains that no
  ROM is loaded.
- **I2-T1** (this branch): import a decrypted `.3ds` / `.cci` from Files, copy
  it into `Documents/roms/`, and load it with `zk_create()` on a background
  serial queue. Failures show the readable `zk_last_error()` text. The frame
  loop (`zk_run_frame`) is still **not** wired — that is I2-T2.

## Layout

| Path | Purpose |
|---|---|
| `project.yml` | XcodeGen spec — the source of truth, do not hand-edit `*.xcodeproj` |
| `Sources/App.swift` | `@main` SwiftUI entry point |
| `Sources/ContentView.swift` | UI: title, ROM import card, screen geometry from the static lib |
| `Sources/ROMSession.swift` | ROM copy + `zk_create` / `zk_destroy` on one serial queue, `zk_last_error` text, relative-path persistence |
| `Sources/ROMDocumentPicker.swift` | `UIDocumentPickerViewController` wrapper (`public.data`, opens files in place) |
| `../ZakuroBridge.h` | hand-written C ABI (`zk_*`), imported via the bridging header |
| `../../scripts/build-zakuro-ios.sh` | builds the static lib on macOS (I0) |

Generated `3ds2apple.xcodeproj/` and `build/` are **build artifacts**: never
commit them.

Device-side layout once a ROM is imported (inside the app container, never in
git):

```text
Documents/roms/<name>.3ds     # copied import; reused when the same name is picked again
Documents/data/<rom-stem>/    # data_dir passed to zk_create (saves/cache)
```

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
`project.yml` and after adding/removing a file under `Sources/` — XcodeGen
snapshots the directory listing at generation time.

> The generated `.xcodeproj` is a build artifact and is already covered by the
> root `.gitignore` (`ios/app/3ds2apple.xcodeproj/`, `ios/app/build/`), so
> `xcodegen` never dirties `git status`.

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

Runtime probe: the UI must show `Upper screen 400 × 240`, `Lower screen
320 × 240` (values come from the C calls — hardcoded strings would mean the
calls were optimized away) plus a `No ROM loaded` card. Device log:

```bash
idevicesyslog | grep '\[3ds2apple\]'
# [3ds2apple] zk_screen_width(0)=400 zk_screen_height(0)=240 zk_screen_width(1)=320 zk_screen_height(1)=240
# [3ds2apple] no ROM imported yet
```

Binary size: `zk_screen_width()` alone is tiny, but referencing `zk_create()`
makes the linker pull in the Zakuro loader/core, so the `.app` grows to tens of
MB (the static library is ~52 MB). That is expected, not a regression.

## ROM import (I2-T1)

The app ships no game data. You bring your own **decrypted** `.3ds` / `.cci`
(the loader does not handle encrypted ROMs or keys).

### Flow

1. Make the ROM visible to the Files app (AirDrop it to the phone, put it in
   iCloud Drive, or use a Files provider / USB drive), then tap
   **Import ROM…** in the app.
2. The picker opens with `public.data` — `.3ds` / `.cci` have no registered
   `UTType` on iOS, so the extension is validated after selection.
3. `ROMSession` copies the picked file to `Documents/roms/<name>` on a
   background serial queue. An existing file with the same name is reused
   instead of copied again, and the copy goes through a temporary name so an
   interrupted import cannot leave a truncated ROM.
4. `zk_create("Documents/roms/<name>", "Documents/data/<rom-stem>")` runs on the
   **same serial queue**, never on the main thread (it can take seconds).
5. Success → green `Loaded: <name>`. Failure → the readable
   `zk_last_error()` text is copied (`String(cString:)`) **inside the same
   queue block** because the error slot is thread-local, then shown in the card
   and logged with `NSLog` for `idevicesyslog`.
6. **Unload ROM** calls `zk_destroy` and returns to the no-ROM state; picking
   another ROM destroys the previous handle first. The imported file stays in
   Documents.
7. The last successfully loaded ROM's **relative** path is persisted in
   `UserDefaults` (`I2.lastROMRelativePath`) and offered as
   **Load “<name>”** after relaunch — relative because the absolute container
   path changes between installs and updates.

Only one handle exists at a time. Every `zk_*` call on it happens on the
`com.kratos.3ds2apple.zakuro-runtime` serial queue (threading rules:
`docs/integration.md`, `ios/zakuro-ios/README.md`).

### What to expect on device

| Phase | UI | Device log (`idevicesyslog`) |
|---|---|---|
| nothing imported | "No ROM loaded" + Import button | `no ROM imported yet` |
| importing | spinner + "Importing <name>…" | `imported ROM: …` or `reusing imported ROM: …` |
| loading | spinner + "Starting Zakuro…" | `zk_create: loading …` |
| success | green "Loaded: <name>" + Change/Unload | `zk_create OK after …` |
| failure | red "Could not load ROM" + error text | `zk_create failed after …: <zk_last_error>` |

Quitting or relaunching the app never crashes: the handle is released on
Unload, on replace, and (best effort) in `ROMSession.deinit`.

### Not in this task

- `zk_run_frame` / the frame loop and on-screen video are I2-T2/I2-T3.
- Audio, input and saves UI are I3.

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
| `git status` shows `ios/app/3ds2apple.xcodeproj/` | Should not happen — the root `.gitignore` covers it. If it does, check `.gitignore` still contains `ios/app/3ds2apple.xcodeproj/` and `ios/app/build/`. |
| Import button does nothing / picker dismisses immediately | The picker is a `UIDocumentPickerViewController` wrapped in a SwiftUI sheet; if it misbehaves on device, report to ios-shell — the fallback is SwiftUI `.fileImporter` (same system picker). |
| "Unsupported file “x”. Choose a decrypted .3ds or .cci ROM." | Only `.3ds` / `.cci` are accepted; the picker allows `public.data` because iOS has no ROM UTTypes. |
| "Could not read the selected file: …" | Copying the security-scoped URL failed (provider offline, no free space, wrong extension). Re-pick the file and check device free space. |
| Red "Could not load ROM" with `zk_create: failed to load …` | `zk_last_error()` text from the loader — encrypted/unsupported ROM or missing keys. Not a UI bug; check the ROM with qa. |
| Picking the same filename twice | The existing `Documents/roms/<name>` is reused; delete the app (or that file) to force a fresh copy. |
| Need to inspect imported ROMs | They live in the app container under `Documents/roms/`, data under `Documents/data/`; deleting the app removes them. |

## Rebuild after changes

```bash
cd ios/app
xcodegen generate   # after project.yml changes or new/removed Sources/*.swift files
# ... edit Sources/*.swift ...
xcodebuild ... build   # same command as above
```

`scripts/build-ios-app.sh` already runs `xcodegen generate` on every invocation,
so it picks up new source files automatically.

## Rules

- No ROMs, keys, BIOS/sysdata, IPAs, static libraries, generated C, or
  credentials in git. This directory contains source only.
- No CPU JIT: the runtime is built with the Cranelift shader JIT disabled.
- `ios/app/` is the ios-shell agent's write scope; `ios/zakuro-ios/` belongs to
  runtime-ffi, `scripts/` to build-infra.
