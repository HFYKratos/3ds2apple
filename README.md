# 3ds2apple

**English** | [简体中文](README.zh-CN.md)

> **Run the Nintendo 3DS games you own as native ARM64 code on iPhone / iPad.**

Game code is translated from ARM to C at build time by [3dsrecomp](https://github.com/fearkov/3dsrecomp) and compiled into ARM64; at runtime [Zakuro](https://github.com/fearkov/zakuro) provides the 3DS system services, GPU and a small interpreter fallback. **No CPU JIT.**

Platform: iPhone / iPad (iOS 16+) · Build: macOS + Xcode · Install: Sideloadly / SideStore / AltStore sideload · License: Apache-2.0 · **Bring your own game**

> **Latest shell build: v0.1.5-beta1 (2026-11-14)** — [GitHub Release](https://github.com/HFYKratos/3ds2apple/releases/tag/v0.1.5-beta1)
>
> UI polish: Saves / Diagnostics / About moved into Settings, the disclaimer is centered, every Settings hint sits inline under its control, and the game screen is redesigned with a rounded stage, a title/pause bar and glass touch controls.
> 界面打磨：存档/诊断/关于移入设置，免责声明居中；设置项提示统一放在控件下方；游戏画面重设计为圆角画面舞台、标题/暂停栏和玻璃质感触摸按键。

**Status: early development.** The shell imports your own ROMs, keeps a multi-game library and runs them through the interpreter; a per-game AOT build (compiled locally from your own ROM) is what reaches near-60 fps. Compatibility, stability and the number of supported games are still being verified.

## Try the shell build

`3ds2apple-shell-0.1.5-beta1.ipa` in the v0.1.5-beta1 GitHub Release is a **universal shell without game data**:

- import one or more of your own decrypted `.3ds` / `.cci` / `.cia` files; they are copied into the app and kept in a persistent game library;
- it contains **no** per-game AOT code, so games run through the Zakuro interpreter and are noticeably slower than an AOT build;
- the IPA is unsigned; install it with Sideloadly / SideStore / AltStore and your own Apple ID.

The near-60 fps measured on Pokémon Y requires a per-game AOT IPA built on your own Mac with your own ROM, following [docs/build.md](docs/build.md). That IPA contains code derived from the game and is **not** distributed with the Release.

## Native port, not a CPU emulator

Traditional 3DS emulators translate CPU instructions one by one at runtime. 3ds2apple moves that step to build time:

- for each game, 3dsrecomp translates ARM / Thumb / VFP code into C;
- the C code is compiled into ARM64 with the iOS clang and linked into the app;
- the runtime keeps only what the game still needs: HLE system services, the PICA200 GPU, audio and input;
- the small set of instructions not covered by recompilation falls back to Zakuro's interpreter.

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

The iOS side calls Zakuro through a small C ABI (`ios/zakuro-ios/`): load a ROM, run frames, read the upper and lower screens, take audio and send input. The shell also reads a build-time `GameCatalog.json` to know which title IDs have AOT code linked in; anything else falls back to the interpreter. Game code and runtime are statically linked into the app.

## Current status

- Multi-game library: grid home, multi-ROM import through Files, persistent `library.json`, delete, last-played dates and an AOT/interpreter badge;
- unified Settings, in-game menu and Save Manager in one simple grouped style; the game screen shows only the two screens, touch controls and the pause/menu button;
- touch controls, GameController, lower-screen touch, audio output, save states and battery-save import/export;
- fast-forward 1× / 2× / 4× (audio stays audible), render resolution 1×–4×, and display layout / rotation / aspect settings;
- Metal presentation through a CAMetalLayer (MoltenVK), with a software fallback; the Metal Performance HUD can be requested from Settings (restart required) for AOT/Metal builds;
- pipeline cache persisted in the app's Caches directory, so later runs do not recompile the same pipelines; an optional “Preparing graphics” warm-up is off by default;
- diagnostics export from the app (device / build / AOT / display / frame timings / logs);
- Pokémon Y (US) with AOT code linked reaches close to 60 fps on an A16 device once the pipeline cache is warm; the shell build (no AOT code) does not.

UI screenshots of the current shell (headless Mac Catalyst renders, no game content): [docs/qa/ui](docs/qa/ui).

> Game screens and test data are used only for local verification and never enter the repository; this repository contains no ROM, key, system file or game asset.

## Roadmap

The next version moves to AOT only: you import your own ROMs and precompile them on a desktop (Linux, Windows or macOS), the phone only installs per-game AOT packages, and the interpreter fallback is removed. The plan, package layout and milestones are in [docs/aot-first.md](docs/aot-first.md).

## Platforms and limitations

| Item | Details |
|---|---|
| Device | iPhone / iPad, iOS 16 or later (development device: iPhone 14 Pro Max) |
| Build | macOS + Xcode (iOS SDK); Rust for the Zakuro static library |
| Install | unsigned IPA, signed with your own Apple ID through Sideloadly / SideStore / AltStore |
| CPU | AOT recompilation, no JIT; a small interpreter fallback |
| GPU | Metal via MoltenVK / CAMetalLayer, with a software fallback |
| Out of scope for now | App Store, camera, microphone, online play, full game-library compatibility |

## Building

See [docs/build.md](docs/build.md) for the full steps. In short:

```bash
# 1. Build the Zakuro iOS static library (macOS + Xcode + Rust + aarch64-apple-ios)
scripts/build-zakuro-ios.sh

# 2. Build the shell app and package an unsigned IPA
scripts/build-ios-app.sh
scripts/package-ipa.sh ios/app/build/Release-iphoneos/3ds2apple.app 3ds2apple-shell-0.1.5-beta1

# 3. Per game: 3dsrecomp → libgame.a → linked static library → IPA
scripts/build-recomp-ios.sh "path/to/game.cci" pokemon-y --auto-serial
scripts/build-linked-ios-lib.sh pokemon-y
scripts/build-game-ipa.sh pokemon-y --title-id 0004000000055E00 \
  --display-name "Pokemon Y" --product-code CTR-P-EK2A
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
ios/app/                 SwiftUI iOS shell (library, screens, input, audio, settings)
ios/zakuro-ios/          Zakuro iOS C ABI / presenter / save state
ios/preview/             Mac Catalyst headless UI preview (development tool)
ios/ZakuroBridge.h       Swift ↔ C ABI bridging header
builder/                 Desktop Builder (Windows/Linux) + macOS Build Agent
scripts/                 Static library / AOT / IPA build scripts
docs/architecture.md     Architecture and design notes
docs/build.md            Build guide
docs/aot-first.md       AOT-only desktop import plan for the next version
docs/related-projects.md Survey of similar projects and their licenses
docs/qa/ui/              Current UI screenshots and how to regenerate them
THIRD_PARTY.md           Third-party components and licenses
CONTRIBUTING.md          Contributing guide
NOTICE                   Copyright, trademark and no-ROM notice
```

## Credits

- **[Zakuro](https://github.com/fearkov/zakuro)** (MIT): 3DS HLE runtime that runs AOT code rather than a JIT.
- **[3dsrecomp](https://github.com/fearkov/3dsrecomp)**: ARM / Thumb / VFP → C static recompiler (build-time tool).
- **[Pocket Native](https://github.com/whovian64/pocket-native)** (MIT): AOT fork of Zakuro + 3dsrecomp; an important reference for AOT linking, the renderer and game profiles.
- **Azahar / Citra** (GPL, behaviour reference only): 3DS HLE, GPU and PICA200 semantics; no GPL code is linked into this project.
- **nxnative / NX2Apple** (MIT) and **S2Arm** (Apache-2.0): references for same-ISA game ports to iOS and their platform layers.
- **MoltenVK** (Apache-2.0): Vulkan → Metal compatibility layer, used for direct presentation.

Full license details are in [THIRD_PARTY.md](THIRD_PARTY.md) and [NOTICE](NOTICE).

## License and legal

This project is open source under the [Apache License 2.0](LICENSE).

This project is not affiliated with Nintendo and is not endorsed or sponsored by Nintendo. Nintendo 3DS is a trademark of Nintendo Co., Ltd.; game names and trademarks belong to their respective owners.

This project contains no Nintendo ROM, decryption key, system file, font or game asset. Use only games you legally own and have exported yourself.