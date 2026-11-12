# 3ds2apple

**English** | [简体中文](README.zh-CN.md)

> **Run the Nintendo 3DS games you own as native ARM64 code on iPhone / iPad.**

Game code is translated from ARM to C at build time by [3dsrecomp](https://github.com/fearkov/3dsrecomp) and compiled into ARM64; at runtime [Zakuro](https://github.com/fearkov/zakuro) provides the 3DS system services, GPU and a small interpreter fallback. **No CPU JIT.**

Platform: iPhone / iPad (iOS 16+) · Build: macOS + Xcode · Install: Sideloadly / AltStore sideload · License: Apache-2.0 · **Bring your own game**

> **First experimental release:** [v0.1.0-alpha](https://github.com/HFYKratos/3ds2apple/releases/tag/v0.1.0-alpha) (source + game-data-free shell IPA); release notes are available in [English](docs/releases/v0.1.0-alpha.md) and [简体中文](docs/releases/v0.1.0-alpha.zh-CN.md).
>
> **Status: early development.** On Pokémon Y (US) the AOT code has been verified active, Metal presents directly and frame rates are close to 60 fps; the pipeline cache persists, so the second launch does not recompile the same pipelines. The first launch may still hit a pipeline-compilation spike, which is being optimized. Compatibility and features will change between versions.

## Try v0.1.0-alpha (shell)

`3ds2apple-shell-v0.1.0-alpha.ipa` in the GitHub Release is a **universal shell without game data**:

- After installing, import your own `.3ds` / `.cci` from Files and it runs directly through the Zakuro interpreter;
- it contains **no** per-game AOT code, so it can only be used to verify installation, the UI, compatibility and basic execution;
- frame rates are noticeably lower than a per-game AOT build, and some games may be very slow;
- the IPA is unsigned; install it with Sideloadly / AltStore and your own Apple ID.

The near-60 fps measured on Pokémon Y requires a per-game AOT IPA built on your own Mac with your own ROM, following [docs/build.md](docs/build.md). That IPA contains code derived from the game and is **not** distributed with the Release.

## Native port, not a CPU emulator

Traditional 3DS emulators translate CPU instructions one by one at runtime. 3ds2apple moves that step to build time:

- for each game, 3dsrecomp translates ARM / Thumb / VFP code into C;
- the C code is compiled into ARM64 with the iOS clang and linked into the app;
- the runtime keeps only what the game still needs: HLE system services, the PICA200 GPU, audio and input;
- the small set of instructions not covered by recompilation falls back to Zakuro's interpreter (about 0.2% on the tested games).

As a result, the device runs **ordinary ARM64 code** — no JIT and no debugger injection.

## How it works

```text
your own .3ds / .cci (never uploaded or bundled)
        │
        ▼
   3dsrecomp (build machine)
        │  generated C
        ▼
   clang -target arm64-apple-ios
        │  libgame.a
        ▼
   SwiftUI shell + libzakuro_ios.a (Zakuro runtime)
        │
        ▼
   unsigned IPA → sideload signing → iPhone / iPad
```

The iOS side calls Zakuro through a small C ABI (`ios/zakuro-ios/`): load a ROM, run frames, read the upper and lower screens, take audio and send input. Game code and runtime are statically linked into the app: one IPA per game.

## Current status

- The SwiftUI shell starts on a real iPhone / iPad, imports your own ROM and displays both screens;
- touch controls, GameController, lower-screen touch and audio output work;
- the 3dsrecomp AOT code for Pokémon Y (US) is statically linked, and the runtime confirms that AOT is active;
- a performance HUD and a free-run frame loop are wired up, so frame times per stage can be inspected on device;
- the GPU presents directly to a CAMetalLayer through MoltenVK / Vulkan, and keeps a software fallback;
- Pokémon Y AOT is close to 60 fps on an A16 device; the pipeline cache is persisted;
- on first launch, GPU pipeline compilation happens on the loading screen: after the ROM is loaded, a few frames run behind a "Preparing graphics" overlay (at least 2 s, 90 consecutive frames without a >50 ms spike, at most 5 s) before the game is revealed; the cache for the same ROM is stored in the app's Caches directory and read directly on the second run, so warm-up is clearly shorter; warm-up is skipped when the renderer falls back to software;
- diagnostics can be exported from the app (device / build / AOT / frame times);
- compatibility, stability and support for more games are still being verified.

> Game screens and test data are used only for local verification and never enter the repository; this repository contains no ROM, key, system file or game asset.

## Platforms and limitations

| Item | Details |
|---|---|
| Device | iPhone / iPad, iOS 16 or later (development device: iPhone 14 Pro Max, iOS 26.7.2) |
| Build | macOS + Xcode (iOS SDK); Rust for the Zakuro static library |
| Install | unsigned IPA, signed with your own Apple ID through Sideloadly / AltStore |
| CPU | AOT recompilation, no JIT; a small interpreter fallback |
| GPU | Metal via MoltenVK / CAMetalLayer, with a software fallback |
| Out of scope for the first release | App Store, camera, microphone, online play, full game-library compatibility |

## Building

See [docs/build.md](docs/build.md) for the full steps. In short:

```bash
# 1. Build the Zakuro iOS static library (macOS + Xcode + Rust + aarch64-apple-ios)
scripts/build-zakuro-ios.sh

# 2. Build the universal shell / game-free app and package an unsigned IPA
scripts/build-ios-app.sh
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple

# 3. Per game: 3dsrecomp → libgame.a → linked static library → IPA
scripts/build-recomp-ios.sh "path/to/game.cci" pokemon-y --auto-serial
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-game-ipa.sh pokemon-y --display-name "Pokemon Y"
```

The desktop Builder in [builder/](builder/README.md) can drive the macOS build from a Windows or Linux machine over SSH using the same scripts. Script details are in [scripts/README.md](scripts/README.md) and [scripts/AOT_BUILD.md](scripts/AOT_BUILD.md).

## Bring your own game

This project **does not provide** ROMs, decryption keys, BIOS files, system files or game assets, nor does it provide ways to obtain them.

- Use only games that you have exported and decrypted yourself from your own console;
- builds and runs happen on your own machine;
- the repository and CI never receive, upload or cache ROMs or data generated from games;
- compatibility reports describe games and problems only, without game files.

## Repository layout

```text
ios/app/                 SwiftUI iOS shell (two screens, input, audio, HUD)
ios/zakuro-ios/          Zakuro iOS C ABI and staticlib crate
ios/ZakuroBridge.h       Swift ↔ C ABI bridging header
builder/                 Desktop Builder (Windows/Linux) + macOS Build Agent
scripts/                 Static library / AOT / IPA build scripts
docs/architecture.md     Architecture and design notes
docs/build.md            Build guide
docs/releases/           Release notes (English + Simplified Chinese)
THIRD_PARTY.md           Third-party components and licenses
CONTRIBUTING.md          Contributing guide
NOTICE                   Copyright, trademark and no-ROM notice
```

## Credits

- **[Zakuro](https://github.com/fearkov/zakuro)** (MIT): 3DS HLE runtime that runs AOT code rather than a JIT.
- **[3dsrecomp](https://github.com/fearkov/3dsrecomp)** (MIT): ARM / Thumb / VFP → C static recompiler.
- **[Pocket Native](https://github.com/whovian64/pocket-native)** (MIT): AOT fork of Zakuro + 3dsrecomp; an important reference for AOT linking, the renderer and game profiles.
- **Azahar / Citra** (GPL, behaviour reference only): compatibility reference for 3DS HLE, GPU and PICA200 semantics; no GPL code is linked into this project.
- **nxnative / S2Arm** (MIT / Apache-2.0): references for same-ISA game ports to iOS, engineering and platform layers.
- **MoltenVK** (Apache-2.0): Vulkan → Metal compatibility layer, used for direct presentation.

Full license details are in [THIRD_PARTY.md](THIRD_PARTY.md) and [NOTICE](NOTICE).

## License and legal

This project is open source under the [Apache License 2.0](LICENSE).

This project is not affiliated with Nintendo and is not endorsed or sponsored by Nintendo. Nintendo 3DS is a trademark of Nintendo Co., Ltd.; game names and trademarks belong to their respective owners.

This project contains no Nintendo ROM, decryption key, system file, font or game asset. Use only games you legally own and have exported yourself.
