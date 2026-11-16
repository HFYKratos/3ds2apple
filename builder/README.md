# 3ds2apple desktop pack pipeline (`builder/`)

> **Status 2026-11-16: only the pack pipeline remains.** The Rust Build Agent
> front ends that used to live in this directory (macOS agent daemon, `zkb`
> client, CLI-first Windows/Linux front ends and their wire protocol) were
> deleted after the v2 Windows launcher started compiling GamePacks locally with
> 3dsrecomp + open-source LLVM/LLD: no Mac is required any more, so the remote
> build-agent path had no remaining customer. Their sources, protocol and UX
> docs are preserved in git history (last full revision: commit 6421e58).

## Remaining components

| Path | What it is | Verified by |
|---|---|---|
| `builder/pack` (`3ds2apple-pack`) | Desktop AOT-first pipeline: ROM header detection (NCSD/NCCH), SMDH title/publisher/icon metadata (localized `displayNames`, `publisher`, 48x48 `cover.png`), import queue, per-game package manifests, self-contained packages with a bundled user ROM (`--include-rom`), deterministic schema-v2 catalogue allocation, macOS script plan, fake/preview packs + preview multi-game IPA | `cargo test -p builder-pack` (unit + CLI integration on Linux); `scripts/tests/desktop-aot-selfcheck.sh` |
| `builder/core` (`builder-core`) | Tiny shared library: streaming SHA-256 helpers (`sha256_file` / `sha256_hex`) used by the pack pipeline. | `cargo test -p builder-core` |
| `builder/device` | Optional Python device-bridge wrapper (devpush/Impactor helpers) used by scripts; not part of the Cargo workspace. | `python3 builder/device/tests/test_device.py -v` |

## Build and test

```bash
cd builder
cargo build --workspace          # binary: target/debug/3ds2apple-pack
cargo test --workspace
target/debug/3ds2apple-pack --help
```

## Desktop AOT-first pipeline (`builder/pack`, preview)

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

Self-contained packages copy the user's ROM into the package as
`GameRom.<ext>`, hashed and recorded as `romFile`/`romSha256`/`romBytes`, so the
phone never imports game data. Pass `--include-rom` to `packages add`,
`packages record` or `build --roms`; `packages verify` re-hashes the copy and
the catalogue names it as `Roms/<TITLE_ID>.<ext>`:

```bash
target/debug/3ds2apple-pack packages add --roms "../ROM/Game.cci" --include-rom
target/debug/3ds2apple-pack packages verify
```

Import also reads the game metadata from the NCCH ExeFS: the SMDH title table
gives localized names (BCP-47 keys `ja`/`en`/`fr`/`de`/`it`/`es`/`zh-Hans`/
`ko`/`nl`/`pt`/`ru`/`zh-Hant`), the publisher and the 48x48 icon, which is
written to the package as `cover.png`. `GameInfo.json` gains additive optional
`displayNames`, `publisher` and `coverPath` fields (schema version stays 1;
`displayName` remains the English/default title), and the same fields plus the
absolute `coverPath` are exposed by `packages add --json` / `packages list
--json` for launchers. Only ~14 KiB of the ROM is read and the extracted cover
stays in the gitignored output tree.

## Where the compile really runs

The shipped product is launcher-first: the Windows launcher
([launcher/windows/](../launcher/windows/)) imports the ROM with
`3ds2apple-pack`, compiles the GamePack locally on the PC (3dsrecomp + the
official LLVM 21.1.8 clang/ld64.lld toolchain plus the hand-written Darwin
stubs in [tools/winbuild/](../tools/winbuild/)), composes the ROM-free IPA and
pushes only `GameRom.cci` + `GameInfo.json` to the phone. The macOS launcher
compiles with Apple's toolchain on the Mac. `3ds2apple-pack` stays a pure
desktop library/CLI: it never signs, installs or contacts a project server.

## Related documentation

- [../docs/desktop-aot.md](../docs/desktop-aot.md) — package layout, catalogue schema v2, GamePack ABI hand-off.
- [../docs/windows-build.md](../docs/windows-build.md) — Windows local compile/link design and toolchain.
- [../docs/windows-launcher.md](../docs/windows-launcher.md) — end-to-end Windows launcher flow.
- [../launcher/windows/README.md](../launcher/windows/README.md) — Windows launcher developer guide.
- [STACK.md](STACK.md) — current workspace stack; the retired Build Agent design is in git history.
