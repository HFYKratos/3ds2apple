# 3ds2apple desktop pack pipeline (`builder/`)

> **Status:** `builder/` contains only the pack pipeline. The Rust Build Agent
> front ends that used to live here were deleted after the Windows launcher
> started compiling GamePacks locally with 3dsrecomp + open-source LLVM/LLD; that
> design record is preserved in git history.

## Components

| Path | What it is | Verified by |
|---|---|---|
| `builder/pack` (`3ds2apple-pack`) | Desktop AOT-first pipeline: ROM header detection (NCSD/NCCH), SMDH title/publisher/icon/region metadata (localized `displayNames`, `publisher`, `region` from the region lockout, 48x48 `cover.png`), import queue, per-game package manifests, self-contained packages with a bundled user ROM (`--include-rom`), deterministic schema-v2 catalogue allocation, macOS script plan, fake/preview packs + preview multi-game IPA | `cargo test -p builder-pack` (unit + CLI integration on Linux); `scripts/tests/desktop-aot-selfcheck.sh` |
| `builder/core` (`builder-core`) | Tiny shared library: streaming SHA-256 helpers (`sha256_file` / `sha256_hex`) used by the pack pipeline. | `cargo test -p builder-core` |

## Build and test

```bash
cd builder
cargo build --workspace          # binary: target/debug/3ds2apple-pack
cargo test --workspace
target/debug/3ds2apple-pack --help
```

## Desktop AOT-first pipeline (`builder/pack`)

The AOT-first route builds one package per game and one shell IPA that carries
several packages, instead of one IPA per game. `3ds2apple-pack` owns the pure
desktop logic (detect, queue, package manifests, catalogue, command plan); the
compile/link/package steps themselves run in the launchers.

```bash
cd builder && cargo build -p builder-pack
target/debug/3ds2apple-pack --help

target/debug/3ds2apple-pack packages add --roms "../ROM/Game.cci"
target/debug/3ds2apple-pack build --queued          # print the macOS plan
target/debug/3ds2apple-pack build --queued --fake   # local preview packs
target/debug/3ds2apple-pack catalog --all
target/debug/3ds2apple-pack pack --all --execute --fake-shell --ipa-out ../IPA
```

Advanced build settings (Deploy page, collapsed by default) change the AOT codegen
attributes of the next build; the defaults reproduce the documented baseline:

    target/debug/3ds2apple-pack build --queued --execute --opt-level O3 --lto --fast-math
    # validation: --opt-level is O1|O2|O3|Oz; an unknown value is rejected

Every plan step/command carries `THREEDS2APPLE_AOT_OPT` / `_LTO` / `_FAST_MATH`
(the AOT scripts read them, see [scripts/README.md](../scripts/README.md) §5.1), so
the default `-O2` build command is byte-for-byte unchanged. The macOS plan JSON
also reports `buildOptions` and `cacheMarker` (`opt=...;lto=...;fastmath=...`),
the same marker the launchers record in their build-cache key.

Self-contained packages copy the user's ROM into the package as
`GameRom.<ext>`, hashed and recorded as `romFile`/`romSha256`/`romBytes`, so the
phone never imports game data. Pass `--include-rom` to `packages add`,
`packages record` or `build --roms`; `packages verify` re-hashes the copy and
the catalogue names it as `Roms/<TITLE_ID>.<ext>`:

```bash
target/debug/3ds2apple-pack packages add --roms "../ROM/Game.cci" --include-rom
target/debug/3ds2apple-pack packages verify
```

A launcher-first shell must not carry that provenance into its
`GameCatalog.json`: the game data is pushed to the phone's Documents/Games, not
bundled inside the app. The launchers therefore drop `romFile`/`romSha256`/
`romBytes` from every entry when they compose the multi-game shell catalogue
(`IpaComposer.NormalizeCatalog`); an entry with a catalogue `romFile` makes the
iOS AOT loader require `Roms/<TITLE_ID>.<ext>` inside the app bundle and refuse
to launch the game. The legacy self-contained paths (the single-game IPA export
and `scripts/build-multi-game-ipa.sh --include-rom`) add the field back because
they really do embed the ROM.

Import also reads the game metadata from the NCCH ExeFS: the SMDH title table
gives localized names (BCP-47 keys `ja`/`en`/`fr`/`de`/`it`/`es`/`zh-Hans`/
`ko`/`nl`/`pt`/`ru`/`zh-Hant`), the publisher, the region-lockout bits
(application settings 0x2018 -> `JP`/`US`/`EU`/`AU`/`CN`/`KR`/`TW`,
`region-free`, joined with `+`; omitted when unknown) and the 48x48 icon, which
is written to the package as `cover.png`. `GameInfo.json` gains additive
optional `displayNames`, `publisher`, `region` and `coverPath` fields (schema
version stays 1; `displayName` remains the English/default title), and the same
fields plus the absolute `coverPath` are exposed by `packages add --json` /
`packages list --json` for launchers. Only ~14 KiB of the ROM is read and the
extracted cover stays in the gitignored output tree.

## Packages, `GameInfo.json` and `GameCatalog.json`

A package is one directory per title (`out/packages/<TITLE_ID>/`):

```text
GameInfo.json               manifest + provenance (schemaVersion 1)
GamePack-<TITLE_ID>.dylib   per-game AOT GamePack (or GamePack.dylib before it is
                            embedded; the launcher records the app-bundle path)
GameRom.<ext>               optional copy of the user's ROM (--include-rom); never committed
cover.png                   SMDH cover extracted from the ROM (or a user-supplied one)
```

`GameInfo.json` carries the title ID, display name plus the localized
`displayNames` map, publisher, region, product code, AOT version, the pack
file/size/SHA-256 and (when the ROM is bundled) the ROM file/size/SHA-256. Launchers read
it after `packages add` and copy the fields they need. `GameCatalog.json`
(schema 2) is what the shell reads from the app bundle:

```json
{"schemaVersion":2,"games":[
  {"titleID":"0004000000055E00","displayName":"Example Game",
   "productCode":"CTR-P-EK2A","aot":true,"aotVersion":1,
   "packFile":"Frameworks/GamePack-0004000000055E00.dylib",
   "packABIVersion":1}]}
```

The optional root field `autoLaunch: true` marks a single-game catalogue: the shell
opens the only listed game as soon as its library is ready instead of showing the
game list (`3ds2apple-pack catalog --auto-launch`, used by the launchers' single-game
IPA export). It is rejected for multi-game catalogues.

`packFile` is app-bundle-relative, games are sorted by title ID and unique (the
allocation is deterministic), and schema-1 (legacy static-link) catalogues are
still accepted. The GamePack C ABI is versioned by `GAMEPACK_ABI_VERSION`
(currently 1), declared by `ios/zakuro-ios/include/zakuro_gamepack.h` and
implemented by the runtime in `ios/zakuro-ios`; a pack registers itself with
`zk_gamepack_register` when the shell `dlopen()`s it.

## Portable .32a build packages

`3ds2apple-pack builds` writes and reads the portable, self-contained build
package the desktop launchers expose as **Export .32a / Import .32a**. It is a
ZIP container named `<build-slug>.32a` with these root entries:

    manifest.json                  schema v1, the single source of truth (first entry)
    GamePack-<TITLEID>.dylib       real arm64 Mach-O GamePack
    GameInfo.json                  package manifest as exported (records the bundled ROM)
    cover.png                      optional SMDH cover
    GameRom.<ext>                  optional copy of the user's ROM

manifest schema v1 fields: `format` (`3ds2apple-build`), `schemaVersion` (1),
`titleID`, `displayName`, `productCode`, `aotVersion`, `appVersion`, `builtAt`
(ISO-8601 UTC), `platform`, `toolchain` (`clang`, `llvm`), `buildOptions`
(`optLevel` O1|O2|O3|Oz, `lto`, `fastMath`), `pack` (`file`, `bytes`,
`sha256`, `format` `gamepack-macho`, `abiVersion`), `gameInfoSha256`,
optional `coverSha256`, `rom` (`included`, optional `file`/`bytes`/`sha256`)
and `sourceLauncher` (`os`, `version`).

    target/debug/3ds2apple-pack --out out builds export --title-id <TITLEID>
    target/debug/3ds2apple-pack --out out builds export --all
    target/debug/3ds2apple-pack --out out builds list --json
    target/debug/3ds2apple-pack --out out builds import <file>.32a [--replace]

Export writes atomically into `<out>/builds/` and bundles the user's ROM when it
can find one (the package's `GameRom.<ext>`, the queued ROM path, then
`<out>/launcher-roms` or `<out>/../launcher-roms`); without a ROM the export
still succeeds with a warning that deploying it needs the original ROM. Import
validates the ZIP structure, manifest schema/version, title ID, pack SHA-256 +
Mach-O magic, `GameInfo.json` hash/shape and every optional payload hash before
installing into `<out>/packages/<TITLEID>/`; an existing package is only
replaced with `--replace`, and unrelated files in it are never deleted.

**A .32a can contain the user's game data.** It is user data like `out/`: keep it
in the gitignored launcher workspace, never commit or upload it.

## Where the compile really runs

The shipped product is launcher-first: the Windows launcher
([launcher/windows/](../launcher/windows/)) imports the ROM with
`3ds2apple-pack`, compiles the GamePack locally on the PC (3dsrecomp + the
official LLVM 23.1.6 clang/ld64.lld toolchain plus the hand-written Darwin
stubs in [tools/winbuild/](../tools/winbuild/)), composes the ROM-free IPA and
pushes only `GameRom.cci` + optional `cover.png` + `GameInfo.json` to the phone. The macOS launcher
compiles with Apple's toolchain on the Mac. `3ds2apple-pack` stays a pure
desktop library/CLI: it never signs, installs or contacts a project server.

## Related documentation

- [../README.md](../README.md) — product usage and the launcher workflow.
- [../launcher/windows/README.md](../launcher/windows/README.md) — Windows launcher
  developer guide.
- [../launcher/macos/README.md](../launcher/macos/README.md) — macOS launcher
  developer guide.
- [../tools/devpush/README.md](../tools/devpush/README.md) — device bridge
  (devpush/1) quickstart and contract.
- [../tools/winbuild/README.md](../tools/winbuild/README.md) — Apple-SDK-free
  LLVM/LLD GamePack build.
- [../scripts/README.md](../scripts/README.md) — build scripts, AOT flags and
  self-checks.
