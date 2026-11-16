# Build scripts

Scripts for building the iOS runtime and shell, per-game AOT GamePacks, the
signable shell IPA, the release assets and the host-side self-checks. All outputs
go to gitignored directories: no ROM, generated C, dylib or IPA is committed.

## iOS runtime and shell

| Script | Purpose |
|---|---|
| `build-zakuro-ios.sh` | Clone/pin Zakuro, apply `ios/zakuro-ios/patches/*.patch`, add the iOS crate and build `build/ios/libzakuro_ios.a` |
| `build-ios-app.sh` | `xcodegen` + `xcodebuild` for the unsigned shell `.app` (empty schema-2 catalog) |
| `package-ipa.sh` | Wrap an unsigned `.app` into `IPA/<name>.ipa` and print its SHA-256; `--manifest FILE` writes the launcher shell `manifest.json` (version/build from the app Info.plist, bundle id, bytes, SHA-256) |
| `build-recomp-ios.sh` | Run 3dsrecomp on a user ROM and compile the generated C for `arm64-apple-ios` into `libgame.a` |
| `build-linked-ios-lib.sh` | Build the linked `libzakuro_ios.a` for one title and collect `build/ios/<name>/` |
| `build-game-ipa.sh` | Single-game statically-linked AOT IPA (runtime + `-lgame`, schema-1 catalog); the launcher-first product uses the pack pipeline below |

## GamePacks and shell IPA (launcher-first)

| Script | Purpose |
|---|---|
| `build-game-pack.sh` | Build or adopt one per-game AOT pack package (`out/packages/<TITLE_ID>/{GameInfo.json,GamePack-*.dylib}`); macOS for a real link, `--fake`/`--dry-run` on any host |
| `build-multi-game-ipa.sh` | Allocate several packs into ONE unsigned shell IPA with a generated schema-2 `GameCatalog.json`; `--base-app` on macOS, `--fake-shell` layout preview anywhere |
| `build-game-pack-llvm.sh` | Build a real GamePack dylib with **open-source LLVM/Clang + LLD, no Apple SDK/macOS** (Linux/WSL/Windows); wrapper over `tools/winbuild/build-gamepack.sh` — see [tools/winbuild/README.md](../tools/winbuild/README.md) |
| `lib/game-catalog.sh` | Shared `GameCatalog.json` writer/validator/installer; accepts schema 1 (legacy static link) and schema 2 (AOT packs) |
| `lib/desktop-aot.sh` | Shared helpers for the desktop AOT scripts: locate `3ds2apple-pack`, Mach-O/placeholder pack checks, catalogue title extraction |
| `lib/aot-common.sh` | Shared AOT helpers (title-ID normalisation, build-info/manifest parsing, `nm` symbol helpers, codegen flags) |
| `lib/zakuro-patches.sh` | Idempotent application of the local Zakuro patches |

## Self-checks

| Script | Purpose |
|---|---|
| `tests/aot-selfcheck.sh` | Linux/macOS checks for the AOT build scripts: `bash -n`, title-ID/manifest round-trip, `nm` regressions, `--help` smoke tests, repo hygiene |
| `tests/game-catalog-selfcheck.sh` | Catalog helper: generation, schema validation, builder/script wiring, `--help` checks (Linux and macOS) |
| `tests/desktop-aot-selfcheck.sh` | Desktop pipeline: synthetic ROM import, fake build, schema-v2 catalogue, preview IPA and script safety checks (no Xcode/ROM needed) |
| `tests/perf-selfcheck.sh` | Performance contract: `docs/performance.md`, diagnostics badge, AOT flags, MoltenVK hook |

## Release

| Script | Purpose |
|---|---|
| `release/assemble-release.sh` | Collect the release assets (Windows ZIP, macOS ZIP, ROM-free shell IPA), rename them to the canonical `3ds2apple-<ver>-{windows-x64,macos-universal,shell}` names, copy LICENSE/NOTICE/THIRD_PARTY, write `SHA256SUMS.txt` and run the verifier |
| `release/verify-release.sh` | Read-only release gate: archive/IPA contents, catalog checks, no ROM/pack/per-game data, SHA-256 verification |

## Quick start (shell)

```bash
scripts/build-zakuro-ios.sh
scripts/build-ios-app.sh
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple
```

## Quick start (launcher-first GamePacks)

The pure desktop work runs natively on Linux/Windows/macOS; the Apple
compile/link/package steps need macOS. The launchers drive this flow themselves.

```bash
# 1. desktop CLI (Rust workspace member; no Xcode needed)
(cd builder && cargo build -p builder-pack)
CLI=builder/target/debug/3ds2apple-pack

# 2. import the user's own decrypted ROMs and queue packs
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
```

The shell ships an empty schema-2 `GameCatalog.json`; the desktop pipeline writes
schema 2 with `packFile`/`packABIVersion`. See
[builder/README.md](../builder/README.md) for the package layout and catalog
schema and [docs/windows-launcher.md](../docs/windows-launcher.md) /
[docs/macos-launcher.md](../docs/macos-launcher.md) for the launcher flows.

Run the self-checks (no Xcode needed):

```bash
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/game-catalog-selfcheck.sh
bash scripts/tests/desktop-aot-selfcheck.sh
bash scripts/tests/perf-selfcheck.sh
```

See [AOT_BUILD.md](AOT_BUILD.md) for options, incremental builds and failure
diagnostics. The local Zakuro patches in `ios/zakuro-ios/patches/` are applied by
`build-zakuro-ios.sh` and again by the cargo path of `build-linked-ios-lib.sh`
(`scripts/lib/zakuro-patches.sh`); application is idempotent, a patch that no
longer applies is a warning (set `ZAKURO_STRICT_PATCHES=1` to make it fatal) and
the checkout under `third_party/` stays local and gitignored.

## Requirements

- macOS with Xcode and the iOS SDK for `build-ios-app.sh`,
  `build-recomp-ios.sh`, `build-linked-ios-lib.sh`, `build-game-ipa.sh` and the
  real `--from-libs`/`--base-app` modes of the desktop scripts.
- Rust with the `aarch64-apple-ios` target for the runtime.
- Rust/cargo for the desktop CLI (`builder/pack`); Linux/Windows need no Xcode
  for `--fake` packs, the fake-shell IPA preview or the printed macOS plan.
- `xcodegen` for the app project.
- Python 3 for helper scripts; `zip` (and `unzip` for verification) for IPA
  packaging/preview.

The game build step needs a local, decrypted ROM that you own. The repository
does not include ROMs or keys.

## Safety

- Every IPA built here is unsigned: sign and install it with the 3ds2apple
  launchers (bundled official Impactor/plumesign on Windows, Xcode on macOS) and
  your own Apple ID.
- Scripts never run `git add` and refuse to overwrite tracked files.
- `ROM/`, `IPA/`, `out/`, `build/`, `third_party/` and `.worktrees/` are
  local-only and gitignored.
