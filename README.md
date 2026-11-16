# 3ds2apple

Run your own Nintendo 3DS games natively on iPhone and iPad, compiled ahead of time to
native ARM64 code — no CPU JIT, no on-device emulation.

## How it works

1. Open the **Windows or macOS launcher** and import decrypted `.3ds` / `.cci` ROMs you own.
2. The launcher compiles a per-game AOT `GamePack.dylib` and composes a ROM-free base shell IPA.
3. Sign in with your own Apple ID in Impactor (Windows) or Xcode (macOS); the launcher signs and
   installs the shell, then copies only `GameRom.cci` + `GameInfo.json` into the app's Documents.
4. The phone app lists the library and runs the games with the Zakuro runtime and PICA200 GPU path.

One phone app holds the whole library. The IPA never contains game ROMs; game data is pushed
into `Documents/Games/<TITLEID>/` by the launcher.

## Ready-to-test launchers

Build outputs are kept in `out/launchers/` (git-ignored, not in the repository):

- `3ds2apple-windows-single-0.2.4.zip` — one Windows executable; ROM-free shell, Impactor,
  local 3dsrecomp + LLVM toolchain and the CLI tools are embedded.
- `3ds2apple-launcher-0.2.3-macos-app.zip` — macOS universal app (Xcode-based signing).

These packages contain no ROM, keys, BIOS or Apple credentials. Use only decrypted ROMs you own.

## Requirements

- Windows 10/11 x64 or macOS 13+ (Intel / Apple silicon).
- An iPhone/iPad on iOS 16 or later, USB cable, Developer Mode enabled.
- A free or paid Apple ID for signing (entered only in Impactor/Xcode).
- Your own decrypted 3DS ROM files.

## Repository layout

```text
ios/app/           iPhone/iPad shell (SwiftUI, AOT game library, Documents game data)
ios/zakuro-ios/     Zakuro iOS C ABI, presenter and save-state bridge
ios/sim/            x86_64 simulator harness used for AOT development
launcher/windows/   Windows launcher (C#/Avalonia), single-file packaging
launcher/macos/     macOS launcher (SwiftUI), Xcode signing and install
tools/devpush/      usbmuxd/AFC device bridge (Rust)
tools/winbuild/     open-source LLVM/LLD GamePack cross-build (Windows/Linux)
builder/pack/       ROM/package/catalog CLI (3ds2apple-pack)
builder/device/     signing/install and push wrapper
scripts/            build, package and self-check scripts
docs/               launcher architecture, device bridge, build and validation docs
```

## Build

- Windows launcher: `launcher/windows/README.md` (`.NET 10`; no Mac required).
- macOS launcher: `launcher/macos/README.md` (Xcode 26.6; Xcodegen).
- iPhone shell: `scripts/build-ios-app.sh` on macOS (Xcode 26.6 / iOS 26.5 SDK).
- Device bridge: `cargo build --release --manifest-path tools/devpush/Cargo.toml`.

See [docs/launcher-architecture.md](docs/launcher-architecture.md),
[docs/launcher-flow-v2.md](docs/launcher-flow-v2.md),
[docs/device-bridge.md](docs/device-bridge.md),
[docs/windows-launcher.md](docs/windows-launcher.md) and
[docs/macos-launcher.md](docs/macos-launcher.md).

## License and legal

Apache-2.0. The project ships no ROMs, decryption keys, BIOS or system files and provides no
ROM download or piracy support. You must own the games you import. Third-party licenses and
source links are documented in [THIRD_PARTY.md](THIRD_PARTY.md) and [NOTICE](NOTICE).
