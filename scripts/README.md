# Build scripts

Scripts for building the iOS static library, the app, per-game AOT IPAs and the
desktop AOT-first packages. All outputs go to gitignored directories; no ROM,
generated C, dylib or IPA is committed.

## Common

| Script | Purpose |
|---|---|
| `build-zakuro-ios.sh` | Clone/pin Zakuro, apply `ios/zakuro-ios/patches/*.patch`, add `ios/zakuro-ios`, build `build/ios/libzakuro_ios.a` |
| `build-ios-app.sh` | `xcodegen` + `xcodebuild` for the unsigned shell `.app` |
| `package-ipa.sh` | Wrap an unsigned `.app` into `IPA/<name>.ipa` and print its SHA256 |
| `build-recomp-ios.sh` | Run 3dsrecomp, compile generated C for `arm64-apple-ios` into `libgame.a` |
| `build-linked-ios-lib.sh` | Build the linked `libzakuro_ios.a` for one title and collect `build/ios/<name>/` |
| `build-game-ipa.sh` | Build the per-game app with `-lzakuro_ios -lgame`, add the one-game `GameCatalog.json`, package the AOT IPA |
| `build-game-pack.sh` | Build/adopt one per-game AOT pack package (`out/packages/<TITLE_ID>/{GameInfo.json,GamePack.dylib}`); macOS for a real `--dylib`/`--from-libs` pack, `--fake`/`--dry-run` on any host |
| `build-multi-game-ipa.sh` | Allocate several per-game packs into ONE unsigned shell IPA with a generated schema-v2 `GameCatalog.json`; `--base-app` on macOS, `--fake-shell` layout preview anywhere |
| `build-game-pack-llvm.sh` | Build a real GamePack dylib with **open-source LLVM/Clang + LLD, no Apple SDK/macOS** (Linux/WSL/Windows); wrapper over `tools/winbuild/build-gamepack.sh`, same output layout as `build-game-pack.sh`; see `tools/winbuild/README.md` and `docs/windows-build.md` §7 |
| `build-ios-app-sim.sh` | Runtime-simulator workstream (not part of the AOT-first desktop pipeline): build the iOS Simulator app variant |
| `build-zakuro-ios-sim.sh` | Runtime-simulator workstream: build the x86_64/Simulator Zakuro static library |
| `ios-ui-preview.sh` | Build and screenshot the shell UI in the iOS Simulator on the macOS VM (auto-generated `zk_*` stubs; no device, no static library, no ROM) |
| `lib/game-catalog.sh` | Shared `GameCatalog.json` writer/validator/installer used by the build and package scripts; validator accepts schema v1 (legacy static link) and v2 (multi-game packs) |
| `lib/desktop-aot.sh` | Shared helpers for the desktop AOT scripts: locate `3ds2apple-pack`, Mach-O/placeholder pack checks, catalogue title extraction |
| `dev-transfer.sh` | One-command, hash-verified dev artifact transfer (random-token VPS relay: push/fetch/side-load/list/clean, direct-LAN mode, doctor, speedtest); ops notes in [../docs/dev-transfer.md](../docs/dev-transfer.md) |
| `tests/dev-transfer-selfcheck.sh` | Offline self-check for `dev-transfer.sh` (+ optional 16 MiB network round trip with `DT_NETWORK_TEST=1`) |
| `tests/game-catalog-selfcheck.sh` | Self-check for the catalog helper (runs on Linux and macOS) |
| `tests/desktop-aot-selfcheck.sh` | Self-check for the desktop AOT pipeline: synthetic ROM import, fake build, schema-v2 catalogue, preview IPA, script safety checks (no Xcode/ROM needed) |

## Quick start

```bash
scripts/build-zakuro-ios.sh
scripts/build-ios-app.sh
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple
```

For one game (single-game static-link IPA, schema-v1 catalog):

```bash
scripts/build-recomp-ios.sh "path/to/game.cci" <name> --auto-serial
scripts/build-linked-ios-lib.sh <name>
scripts/build-game-ipa.sh <name> \
  --title-id 0004000000055E00 \
  --display-name "Game name" \
  --product-code CTR-P-EKJA
```

## AOT-first desktop pipeline (preview)

The AOT-first flow builds one package per game on the computer and one shell IPA
that carries several packs (schema-v2 `GameCatalog.json`). The pure
desktop work runs natively on Linux/Windows/macOS; the Apple
compile/link/package steps need macOS (see `docs/desktop-aot.md`). A phase-2
prototype can also compile/link the GamePack on Linux/Windows with open-source
LLVM/LLD and no Apple SDK: `scripts/build-game-pack-llvm.sh` (see
`tools/winbuild/README.md` and `docs/windows-build.md` §7).

```bash
# 1. desktop CLI (Rust workspace member; no Xcode needed)
(cd builder && cargo build -p builder-pack)
CLI=builder/target/debug/3ds2apple-pack

# 2. import the user's own decrypted ROMs, queue packs, preview on Linux/Windows
"$CLI" packages add --roms "ROM/game.cci"
"$CLI" build --queued            # print the exact macOS script plan
"$CLI" build --queued --fake     # local placeholder packs (not installable)
"$CLI" catalog --all

# 3. macOS: real packs and one multi-game shell IPA
scripts/build-game-pack.sh <name> --title-id 0004000000055E00 \
  --display-name "Game name" --out out --dylib <runtime-provided GamePack.dylib>
scripts/build-multi-game-ipa.sh --packages-dir out/packages --all \
  --base-app ios/app/build/Release-iphoneos/3ds2apple.app

# Linux/Windows layout preview (fake shell + placeholders; NOT installable)
scripts/build-multi-game-ipa.sh --packages-dir out/packages --all \
  --allow-placeholder-dylibs --fake-shell

# or drive steps 2-3 through the CLI
"$CLI" pack --all --execute --base-app ios/app/build/Release-iphoneos/3ds2apple.app
```

Every AOT IPA carries a build-time `GameCatalog.json` in the app bundle: it
lists the title IDs whose AOT code is available, so the phone only selects and
launches a game and never recompiles a ROM. The plain shell build
(`build-ios-app.sh`) ships an empty catalog (interpreter-only, legacy) and
removes the file afterwards, so `git status` stays clean. The desktop pipeline
writes schema version 2 with `packFile`/`packABIVersion`; the single-game scripts
keep writing schema version 1, which the shell still accepts. See
[../docs/build.md](../docs/build.md#3-two-ipa-tracks-shell-ipa-vs-game-ipa) and
[../docs/desktop-aot.md](../docs/desktop-aot.md).

Run the script self-checks (no Xcode needed):

```bash
bash scripts/tests/game-catalog-selfcheck.sh
bash scripts/tests/desktop-aot-selfcheck.sh
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/aot-sim-harness.sh
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
  `build-recomp-ios.sh`, `build-linked-ios-lib.sh`, `build-game-ipa.sh` and the
  real `--from-libs`/`--base-app` modes of the desktop scripts.
- Rust with `aarch64-apple-ios` for the runtime.
- Rust/cargo for the desktop CLI (`builder/pack`); Linux/Windows need no Xcode
  for `--fake` packs, the fake-shell IPA preview or the printed macOS plan.
- `xcodegen` for the app project.
- Python 3 for helper scripts; `zip` (and `unzip` for verification) for IPA
  packaging/preview.

The game build step needs a local, decrypted ROM that you own. The repository
does not include ROMs or keys.

## Safety

- The IPA is unsigned. Sign and install it with Sideloadly or AltStore and
  your own Apple ID.
- Scripts never run `git add` and refuse to overwrite tracked files.
- `ROM/`, `IPA/`, `out/`, `build/`, `third_party/` and `.worktrees/` are local-only
  and gitignored.
