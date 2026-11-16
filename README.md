# 3ds2apple

**Play your own Nintendo 3DS games natively on iPhone and iPad.** 3ds2apple is a
desktop-first toolkit: it imports a decrypted ROM you own, compiles the game ahead
of time into a native ARM64 library, builds a ROM-free iOS app for you, signs it
with your own Apple ID, and installs it. The game then runs as native code on the
phone — no CPU JIT and no emulator core.

> 3ds2apple does not include, download or link to Nintendo ROMs, decryption keys,
> BIOS or system files, and is not affiliated with, endorsed by or sponsored by
> Nintendo. You must own and dump the games you import.

![Windows launcher — Library](launcher/windows/docs/ui/v4-library-en.png)

*Windows launcher, Library page (synthetic demo entries; no game data).*

![macOS launcher — empty library](launcher/macos/screenshots/launcher-library-empty-dark-en.png)

*macOS launcher, empty library.*

## One product, three parts

| Part | What it does |
|---|---|
| **Windows launcher** — `launcher/windows`, C#/Avalonia | Imports `.3ds`/`.cci` ROMs, compiles one GamePack per game on the PC with a bundled open-source LLVM/LLD toolchain, composes the ROM-free shell IPA (app + packs + MoltenVK + catalog), signs and installs it with the bundled official Impactor/plumesign and your own Apple ID, then pushes only the game data to the phone. |
| **macOS launcher** — `launcher/macos`, SwiftUI | The same one-click flow on a Mac: Apple clang builds the GamePack, Xcode automatic signing + devicectl installs the IPA, then the launcher pushes the game data. |
| **iOS app** — `ios/app`, SwiftUI | The phone shell: game library, in-game menu, touch controls and save states. It loads the AOT GamePacks from inside the signed app bundle and runs them with the Zakuro HLE runtime and Metal via MoltenVK. |

Supporting tools in the same repository: `builder/` (`3ds2apple-pack`:
ROM import, SMDH metadata, packages, GameCatalog), `tools/devpush` (device
bridge: usbmuxd/AFC push and install verification) and `tools/winbuild`
(Apple-SDK-free LLVM/LLD GamePack build for Windows/Linux).

## How it works

```text
your decrypted ROM (.3ds/.cci)
  → launcher imports it (reads only the ROM header + SMDH icon)
  → 3dsrecomp: ARM/Thumb → C
  → local clang: C → arm64 GamePack-<TITLEID>.dylib
  → launcher composes a ROM-free shell IPA (app + packs + MoltenVK + GameCatalog.json)
  → your Apple ID signs it (Impactor/plumesign on Windows, Xcode on macOS) and installs it
  → devpush copies only Documents/Games/<TITLEID>/{GameRom.cci, GameInfo.json}
  → the app runs the AOT code: Zakuro HLE + Metal through MoltenVK
```

Per-game executable code **must** live inside the signed IPA: iOS refuses to load
unsigned code from Documents. That is why the launcher always composes and signs
a fresh IPA for the games you selected. Only game data (the ROM + its metadata)
is pushed afterwards, and it survives reinstalls and app updates.

## Features

- **Native AOT execution** — every game is recompiled to ARM64 ahead of time and
  runs directly on the phone. No CPU JIT and no recompilation on device.
- **One app, the whole library** — the shell carries a catalog plus one GamePack
  per selected game; add or remove a game by deploying again.
- **Desktop-first workflow** — import, compile, compose, sign and install from a
  single launcher window (Library → Deploy), with a portable data folder beside
  the launcher.
- **Metal rendering** — the PICA200 GPU path runs through MoltenVK on Metal, with
  a performance HUD and diagnostics.
- **Official signing tools, unmodified** — the Windows launcher bundles the
  official Impactor v2.7.2 + plumesign release (MIT / MPL-2.0, SHA-256 pinned);
  Apple ID credentials never touch 3ds2apple code.
- **Tested on the host** — every component has self-checks or test suites that
  run without a game console or a phone.

## Download

Public builds are published only on
**[GitHub Releases](https://github.com/HFYKratos/3ds2apple/releases)**. The
current release line is **0.1.0** (Windows launcher, macOS launcher and the
shell template share the same version). A release typically contains:

- `3ds2apple-0.1.0-windows-x64.zip` — the Windows launcher (single executable),
- `3ds2apple-0.1.0-macos-universal.zip` — the macOS launcher (`.app`),
- `3ds2apple-0.1.0-shell.ipa` — the ROM-free iOS shell template used by the
  launchers (not playable on its own),
- `SHA256SUMS.txt`, `LICENSE`, `NOTICE` and `THIRD_PARTY.md`.

Always verify a download against `SHA256SUMS.txt` before running it. Releases
contain no game ROMs, decryption keys, BIOS, generated C or per-game code: the
launcher compiles the per-game code locally from your own ROM. The full release
policy, asset list and verification rules are in
[docs/release.md](docs/release.md).

## Requirements

- **Windows 10/11 x64** — no Mac required; the launcher brings its own toolchain
  and signing tools.
- **or macOS 13+** (Intel or Apple silicon) with **Xcode 15+** for signing and
  installation.
- An iPhone/iPad on **iOS 16+**, a USB cable and **Developer Mode** enabled.
- A free or paid **Apple ID** for signing (entered only in Impactor or Xcode).
- Your own legally obtained, **decrypted** 3DS ROM (`.3ds` / `.cci`).

## Build from source

| Component | Build / test |
|---|---|
| Windows launcher | `cd launcher/windows && dotnet build Launcher.slnx -c Release` and `dotnet test Launcher.slnx -c Debug` — see [launcher/windows/README.md](launcher/windows/README.md) |
| macOS launcher | XcodeGen + `xcodebuild` on macOS — see [launcher/macos/README.md](launcher/macos/README.md) |
| iOS app | `scripts/build-ios-app.sh` then `scripts/package-ipa.sh` on macOS — see [ios/app/README.md](ios/app/README.md) |
| Pack CLI (`3ds2apple-pack`) | `cd builder && cargo build --workspace` / `cargo test --workspace` — see [builder/README.md](builder/README.md) |
| Device bridge (`devpush`) | `cargo build --release --manifest-path tools/devpush/Cargo.toml` — see [tools/devpush/README.md](tools/devpush/README.md) |

Host-side self-checks (no Xcode, ROM or phone needed):

```bash
cd builder && cargo test --workspace
cd launcher/windows && dotnet test Launcher.slnx -c Debug
bash scripts/tests/perf-selfcheck.sh
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/game-catalog-selfcheck.sh
```

Per-game AOT build options are documented in
[scripts/AOT_BUILD.md](scripts/AOT_BUILD.md).

## Repository layout

```text
ios/app/           iOS app: library, in-game menu, touch controls, save states
ios/zakuro-ios/    Zakuro iOS C ABI: GamePack loader, Metal presenter, perf counters
launcher/windows/  Windows launcher (C#/Avalonia), single-file packaging
launcher/macos/    macOS launcher (SwiftUI), Xcode signing and install
builder/           3ds2apple-pack: ROM import, SMDH metadata, packages, GameCatalog
tools/devpush/     device bridge: usbmuxd/house_arrest/AFC push, install verification
tools/winbuild/    Apple-SDK-free LLVM/LLD GamePack cross-build (Windows/Linux)
scripts/           build, package, release and self-check scripts
docs/              launcher, device-bridge, performance and release docs
licenses/          third-party license texts (Impactor MIT, apple-codesign MPL-2.0)
```

## Documentation

- [docs/README.md](docs/README.md) — documentation index.
- [docs/windows-launcher.md](docs/windows-launcher.md) and
  [docs/macos-launcher.md](docs/macos-launcher.md) — launcher flows, contracts and
  test plans.
- [docs/device-bridge.md](docs/device-bridge.md) — devpush contract and the
  Documents data layout.
- [docs/performance.md](docs/performance.md) — performance telemetry, measurement
  plan and tuning.
- [docs/release.md](docs/release.md) — public release policy and asset
  verification.
- [builder/README.md](builder/README.md) — pack CLI, `GameInfo.json` and
  `GameCatalog.json` schemas.

## License and legal

3ds2apple is licensed under **Apache-2.0** (see [LICENSE](LICENSE)). It ships no
Nintendo ROMs, decryption keys, BIOS, system files, game assets or gameplay
screenshots, and it provides no ROM download or piracy support. Only use games
that you legally own and dump yourself.

Third-party components and licenses are listed in
[THIRD_PARTY.md](THIRD_PARTY.md) and [NOTICE](NOTICE). The launchers bundle the
official Impactor v2.7.2 + plumesign release files unmodified (MIT; the embedded
apple-codesign 0.29.0 is MPL-2.0) and keep the license texts in
[licenses/impactor](licenses/impactor). GPL projects are read as architecture
references only — no GPL code or text is copied into this repository.
