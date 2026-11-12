# Build scripts

Scripts for building the iOS static library, the app and per-game AOT IPAs.
All outputs go to gitignored directories; no ROM, generated C or IPA is
committed.

## Common

| Script | Purpose |
|---|---|
| `build-zakuro-ios.sh` | Clone/pin Zakuro, apply `ios/zakuro-ios/patches/*.patch`, add `ios/zakuro-ios`, build `build/ios/libzakuro_ios.a` |
| `build-ios-app.sh` | `xcodegen` + `xcodebuild` for the unsigned shell `.app` |
| `package-ipa.sh` | Wrap an unsigned `.app` into `IPA/<name>.ipa` and print its SHA256 |
| `build-recomp-ios.sh` | Run 3dsrecomp, compile generated C for `arm64-apple-ios` into `libgame.a` |
| `build-linked-ios-lib.sh` | Build the linked `libzakuro_ios.a` for one title and collect `build/ios/<name>/` |
| `build-game-ipa.sh` | Build the per-game app with `-lzakuro_ios -lgame` and package the AOT IPA |

## Quick start

```bash
scripts/build-zakuro-ios.sh
scripts/build-ios-app.sh
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple
```

For a game:

```bash
scripts/build-recomp-ios.sh "path/to/game.cci" <name> --auto-serial
scripts/build-linked-ios-lib.sh <name>
scripts/build-game-ipa.sh <name> --display-name "Game name"
```

See [AOT_BUILD.md](AOT_BUILD.md) for options, incremental builds and failure
diagnostics.

The local Zakuro patches in `ios/zakuro-ios/patches/` are applied by
`build-zakuro-ios.sh` and again by the cargo path of
`build-linked-ios-lib.sh` (`scripts/lib/zakuro-patches.sh`). Application is
idempotent: an already patched checkout is reported and skipped, a patch that
no longer applies is a warning (set `ZAKURO_STRICT_PATCHES=1` to make it
fatal). The checkout under `third_party/` stays local and gitignored.

## Requirements

- macOS with Xcode and the iOS SDK for `build-ios-app.sh`,
  `build-recomp-ios.sh`, `build-linked-ios-lib.sh` and `build-game-ipa.sh`.
- Rust with `aarch64-apple-ios` for the runtime.
- `xcodegen` for the app project.
- Python 3 for helper scripts.

The game build step needs a local, decrypted ROM that you own. The repository
does not include ROMs or keys.

## Safety

- The IPA is unsigned. Sign and install it with Sideloadly or AltStore and
  your own Apple ID.
- Scripts never run `git add` and refuse to overwrite tracked files.
- `ROM/`, `IPA/`, `build/`, `third_party/` and `.worktrees/` are local-only and
  gitignored.
