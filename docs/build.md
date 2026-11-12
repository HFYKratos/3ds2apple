# Build guide

This guide builds the app on macOS with Xcode and packages an unsigned IPA.
It does not include or require any game data in the repository; you need your
own legally obtained, decrypted `.3ds` / `.cci` for the game build step.

## Requirements

- macOS with Xcode and the iOS SDK (tested with Xcode 16.4 / iOS 18.5 SDK).
- Rust stable with the `aarch64-apple-ios` target.
- `xcodegen` (for the SwiftUI project).
- Python 3.
- For a game build: a local checkout/toolchain of
  [3dsrecomp](https://github.com/fearkov/3dsrecomp) and
  [Zakuro](https://github.com/fearkov/zakuro), or the scripts in this
  repository (they clone/pin them).

```bash
rustup target add aarch64-apple-ios
xcode-select -s /Applications/Xcode.app
```

## 1. Build the runtime static library

```bash
scripts/build-zakuro-ios.sh
```

The script clones/pins Zakuro into `third_party/`, adds the
`ios/zakuro-ios` crate, disables the shader JIT, builds for
`aarch64-apple-ios` and places `build/ios/libzakuro_ios.a`.

For a per-game AOT build, the linked variant is built with:

```bash
ZAKURO_LINKED_PROGRAM_ID=<16-hex-title-id> \
  cargo build -p zakuro-ios --release --features linked \
  --target aarch64-apple-ios
```

## 2. Build the shell app (no game)

```bash
scripts/build-ios-app.sh
```

This runs `xcodegen`, `xcodebuild` for `iphoneos` with code signing disabled,
and prints the `.app` path. It links the interpreter-only static library.

## 3. Build a per-game AOT IPA

The scripts implement the split pipeline: 3dsrecomp can run on Linux or macOS;
the generated C is compiled for iOS on macOS; the app links `libzakuro_ios.a`
and `libgame.a`.

```bash
# 3dsrecomp -> build/game/<name>/  (C + static archive)
scripts/build-recomp-ios.sh "path/to/game.cci" <name> --auto-serial

# linked runtime + game archive -> build/ios/<name>/
scripts/build-linked-ios-lib.sh <name>

# Xcode app + IPA -> IPA/<name>-AOT.ipa
scripts/build-game-ipa.sh <name> --display-name "Game name"
```

See [scripts/README.md](../scripts/README.md) and
[scripts/AOT_BUILD.md](../scripts/AOT_BUILD.md) for options, incremental
builds, serial-compile fallbacks and failure diagnostics.

### Verification

For a game build, the runtime logs whether the linked code was accepted. On
device, the app's status area shows `AOT: linked, active` when the generated
code is executing, or `linked, interpreting` when the title/ABI did not match
and the interpreter is used.

## 4. Package and install

```bash
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app <name>
```

The IPA is unsigned. Sign and install it with Sideloadly or AltStore using your
own Apple ID. The app is not intended for App Store distribution.

## Troubleshooting

- **Undefined `_recomp_*` symbols**: `-lzakuro_ios` must come before
  `-lgame`; the game archive resolves the generated tables.
- **`AOT: linked, interpreting`**: the linked code's title ID or ABI does not
  match the ROM/runtime. Rebuild with the matching title and the same pinned
  revisions.
- **`Found no destinations`**: use `-target`/`-sdk iphoneos` rather than a
  simulator scheme if the iOS simulator runtime is not installed.
- **`PRODUCT_NAME` empty / `.app` with no name**: keep `PRODUCT_NAME` and
  `EXECUTABLE_NAME` explicit in `ios/app/project.yml`.
- **No game data**: this repository never contains ROMs. The app asks for a
  ROM at runtime; the game build needs a local copy on the build machine.
