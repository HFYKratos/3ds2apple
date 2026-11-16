<img src="assets/icon.png" width="112" alt="3ds2apple icon">

# 3ds2apple

[English](README.md) | [简体中文](README.zh-CN.md)

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
**[GitHub Releases](https://github.com/HFYKratos/3ds2apple/releases)**. Each
release carries exactly the two platform packages:

- `3ds2apple-<version>-windows-x64.zip` — the Windows 10/11 launcher
  (one self-contained executable),
- `3ds2apple-<version>-macos-universal.zip` — the macOS 13+ launcher
  (`.app`, Intel + Apple silicon).

Notes:

- The ROM-free **shell template is embedded in both launchers**; it is not a
  separate download.
- Releases do **not** attach `LICENSE`, `NOTICE`, `THIRD_PARTY.md` or a
  `SHA256SUMS.txt`: the license texts live in this repository and are bundled in
  the launcher payloads, and GitHub shows the SHA-256 digest for every release
  asset on the Release page (you can also compute it locally).
- Releases never contain game ROMs, decryption keys, BIOS, generated C or
  per-game code: the launcher compiles the per-game code locally from your own
  ROM.
- Release notes list the product version and the bilingual update highlights;
  release rules are in [CONTRIBUTING.md](CONTRIBUTING.md#release-policy).

## Usage

**This README is the single, complete usage guide.** Component READMEs are
developer notes only.

### Requirements

- **Windows 10/11 x64** — no Mac required; the launcher brings its own toolchain
  and signing tools.
- **or macOS 13+** (Intel or Apple silicon) with **Xcode 15+** for signing and
  installation.
- An iPhone/iPad on **iOS 16+**, a USB cable and **Developer Mode** enabled.
- A free or paid **Apple ID** for signing (entered only in Impactor or Xcode).
- Your own legally obtained, **decrypted** 3DS ROM (`.3ds` / `.cci`).

### Windows launcher

1. Download and extract `3ds2apple-<version>-windows-x64.zip` into a writable
   folder (not `Program Files`).
2. Install **Apple Devices** (or iTunes) from the Microsoft Store so the phone is
   reachable over USB.
3. Run `3ds2apple-launcher.exe`. The executable is not code-signed: after
   checking the digest, choose *More info → Run anyway* on the SmartScreen prompt.
   Run Settings → self-test once; it should be green (all bundled tools verified).
4. **Library → Import**: pick your own decrypted `.3ds`/`.cci`. Only the ROM
   header and the SMDH icon/metadata are read.
5. **Deploy (导入手机)**: select one or more games and press the one deploy
   button. The launcher compiles one GamePack per game, composes one ROM-free IPA,
   signs and installs it with the bundled official Impactor/plumesign (sign in
   with your own Apple ID inside Impactor, which opens on first deploy), and then
   pushes only `GameRom.cci` + `GameInfo.json` per game into
   `Documents/Games/<TITLEID>/`.
6. Wait for the *Done / 可以打开手机 App 游玩* state, then open the app on the
   phone and play. Adding or removing a game means deploying again; the pushed
   game data stays. A clean app uninstall clears the app data.

### macOS launcher

1. Download and extract `3ds2apple-<version>-macos-universal.zip`; you get
   `3ds2apple-launcher.app`.
2. The app is not notarised: after checking the digest, first launch it with
   right-click → *Open* (Gatekeeper).
3. Prerequisites — the macOS package is **not self-contained yet**; it needs
   macOS 13+, Xcode 15+ with your Apple ID added under Xcode → Settings →
   Accounts, `xcodegen`, a repository checkout and the built tools
   (`scripts/build-zakuro-ios.sh` for `build/ios/libzakuro_ios.a`, the
   `builder` pack CLI and `tools/devpush`). The launcher finds them in its
   bundle, the checkout or `PATH`.
4. Run the app → **Library → Import** → **Deploy**. Apple clang compiles each
   GamePack, Xcode automatic signing + `devicectl` installs the composed IPA,
   and the launcher pushes the game data. The selection/update rules are the same
   as on Windows.

### Phone data, saves and limits

- The app keeps game data under `Documents/Games/<TITLEID>/` (the Files app can
  show it); save data and save states live in the app container.
- Free Apple IDs: 3 apps per device, ~7-day signing validity — re-deploy to
  refresh. A paid developer account removes those limits.
- Uninstalling the app removes its data; game ROMs on your computer are never
  touched.

### FAQ

**Why do I need my own ROM?** 3ds2apple ships no ROMs, keys or BIOS and provides
no downloads. Only user-dumped, decrypted ROMs are supported.

**Why does the launcher compile on my PC?** The per-game GamePack is derived from
your ROM, so it cannot be pre-built into a public release. The launcher does the
AOT compile locally and signs the result into the IPA.

**Is there a JIT or a fallback emulator?** No CPU JIT on the phone: the shipping
path runs the game as native AOT code through Zakuro's HLE runtime and Metal.

**Which games work?** Compatibility is per title; if a game fails to boot or
renders badly, report it with the title ID (see
[CONTRIBUTING.md](CONTRIBUTING.md)).

**Why does the macOS app ask for a checkout?** The macOS package is a
developer-preview build that is not self-contained yet; the Windows package is a
single executable.

## Build from source

| Component | Build / test |
|---|---|
| Windows launcher | `cd launcher/windows && dotnet build Launcher.slnx -c Release` / `dotnet test Launcher.slnx -c Debug` — see [launcher/windows/README.md](launcher/windows/README.md) |
| macOS launcher | XcodeGen + `xcodebuild` on macOS — see [launcher/macos/README.md](launcher/macos/README.md) |
| iOS app / shell | `scripts/build-zakuro-ios.sh` → `scripts/build-ios-app.sh` → `scripts/package-ipa.sh` — see [scripts/README.md](scripts/README.md) and [ios/app/README.md](ios/app/README.md) |
| Pack CLI (`3ds2apple-pack`) | `cd builder && cargo build --workspace` / `cargo test --workspace` — see [builder/README.md](builder/README.md) |
| Device bridge (`devpush`) | `cargo build --release --manifest-path tools/devpush/Cargo.toml` — see [tools/devpush/README.md](tools/devpush/README.md) |

Host-side self-checks (no Xcode, ROM or phone needed):

```bash
cd builder && cargo test --workspace
cd launcher/windows && dotnet test Launcher.slnx -c Debug
bash scripts/tests/perf-selfcheck.sh
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/game-catalog-selfcheck.sh
bash scripts/tests/desktop-aot-selfcheck.sh
```

AOT build flags, packaging details and troubleshooting are in
[scripts/README.md](scripts/README.md).

## Repository layout

```text
assets/            app icon used by this README
ios/app/           iOS app: library, in-game menu, touch controls, save states
ios/zakuro-ios/    Zakuro iOS C ABI: GamePack loader, Metal presenter, perf counters
launcher/windows/  Windows launcher (C#/Avalonia), single-file packaging
launcher/macos/    macOS launcher (SwiftUI), Xcode signing and install
builder/           3ds2apple-pack: ROM import, SMDH metadata, packages, GameCatalog
tools/devpush/     device bridge: usbmuxd/house_arrest/AFC push, install verification
tools/winbuild/    Apple-SDK-free LLVM/LLD GamePack cross-build documentation
scripts/           build, package, release and self-check scripts
licenses/          third-party license texts (Impactor MIT, apple-codesign MPL-2.0)
```

## Contributing and release

- [CONTRIBUTING.md](CONTRIBUTING.md) — contribution rules, issue reports and the
  **release policy** (two platform assets, bilingual update notes, immutable tags).
- [LICENSE](LICENSE) — Apache-2.0.
- [THIRD_PARTY.md](THIRD_PARTY.md) and [NOTICE](NOTICE) — third-party components
  and legal notices.

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
