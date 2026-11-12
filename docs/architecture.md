# Architecture

3ds2apple runs a Nintendo 3DS game as a native ARM64 program on iPhone and
iPad. The CPU code is translated ahead of time; the runtime supplies the 3DS
services, GPU and audio that the game still calls.

## Design constraints

- **No CPU JIT.** iOS does not allow executable memory for ordinary apps, and
  the project targets sideloaded builds without a debugger.
- **Bring your own game.** No ROM, keys or game data are stored in this
  repository or in any build artifact it distributes.
- **One game, one IPA.** Recompiled code and the runtime are statically linked
  into a per-game app; there is no runtime code loading.
- **Stock iOS frameworks.** SwiftUI/UIKit, AVFoundation, GameController and
  Metal; no private APIs.

## Components

```text
┌──────────────────────────────────────────────┐
│  SwiftUI shell (ios/app)                     │
│  ROM import · upper/lower screens · input    │
│  audio · performance HUD                     │
└──────────────────────┬───────────────────────┘
                       │  C ABI (ios/ZakuroBridge.h)
┌──────────────────────▼───────────────────────┐
│  libzakuro_ios.a (ios/zakuro-ios)            │
│  ┌────────────────────────────────────────┐  │
│  │ Zakuro core                            │  │
│  │  HLE kernel / services                 │  │
│  │  CPU interpreter fallback              │  │
│  │  PICA200 GPU (software renderer)       │  │
│  │  DSP / audio, input, saves             │  │
│  └────────────────────────────────────────┘  │
│  libgame.a: 3dsrecomp-generated ARM64 code   │
└──────────────────────────────────────────────┘
```

### 1. Recompiled game code

For each supported title, 3dsrecomp reads the game's executable code and
writes C. The C is compiled for `arm64-apple-ios` into `libgame.a`. At runtime
Zakuro receives the generated entry/module tables through its `Linked` API.

Most instructions execute from this native code. Instructions that cannot be
recompiled (for example code created at runtime) fall back to Zakuro's
interpreter; the measured share on the tested titles is about 0.2%.

### 2. Zakuro runtime

Zakuro is an MIT-licensed 3DS HLE runtime. It implements the kernel objects,
services, filesystem, audio, input and PICA200 GPU behaviour that a game calls.
Its CPU interpreter is used for the small uncovered remainder and for games or
title versions that have not been recompiled.

The iOS build disables Zakuro's optional Cranelift shader JIT: it would need
executable memory. Shaders therefore run through the interpreter/software
paths.

### 3. iOS C ABI

`ios/zakuro-ios` exposes a small, stable C ABI used by Swift:

| Function | Purpose |
|---|---|
| `zk_create` / `zk_destroy` | Load/release a ROM and its runtime |
| `zk_run_frame` | Execute one 3DS frame |
| `zk_read_screen` | Read upper (400×240) or lower (320×240) RGBA8 pixels |
| `zk_take_audio` | Drain interleaved stereo PCM |
| `zk_set_input` | Push buttons, Circle Pad and touch coordinates |
| `zk_last_error` | Human-readable load error for the current thread |
| `zk_linked_code` / `zk_recompiled` | Report whether AOT code is linked and active |

All handle-taking calls must run on one serial queue.

### 4. SwiftUI shell

The shell owns the UI and the frame loop:

- imports a `.3ds` / `.cci` through the Files picker and copies it into the
  app's Documents directory;
- drives the runtime in a free-running loop (capped at 60 Hz), decoupled from
  the display refresh so slow frames do not quantise the game clock;
- converts the two RGBA screens to `CGImage` for display;
- feeds on-screen buttons, GameController input and lower-screen touches into
  `zk_set_input`;
- plays `zk_take_audio` through AVAudioEngine;
- shows frame time by phase (run / screen reads / image conversion / audio) for
  performance work.

## Build pipeline

```text
ROM (local only)
  └─ 3dsrecomp ──► generated C
                    └─ clang (iOS SDK) ──► libgame.a
Zakuro source ──► cargo (aarch64-apple-ios) ──► libzakuro_ios.a
libgame.a + libzakuro_ios.a + SwiftUI shell ──► xcodebuild ──► .app ──► .ipa
```

The IPA is unsigned; signing and installation happen on the user's machine
with Sideloadly or AltStore and the user's own Apple ID.

## Performance model

- The CPU side is native AOT code, with an interpreter fallback.
- On iOS the GPU path is Zakuro's Vulkan renderer running on MoltenVK, which
  translates to Metal. The A1 presenter draws the two screens directly into a
  `CAMetalLayer`; the software PICA200 renderer remains as a fallback.
- The tested Pokémon Y build keeps steady-state run time around 6 ms and
  reaches ~60 fps on an A16 device once the pipeline cache is warm. First-run
  pipeline compilation is still visible as short hitches; the cache is saved
  under the app's Caches directory and reused on later launches.
- The UI exposes frame-time phases, so renderer/presenter changes can be
  measured on device rather than guessed.
- Longer term, a direct PICA200 → Metal renderer (Metal render pipelines plus
  compute for TEV/shader work) can remove the Vulkan/MoltenVK layer.

## Non-goals for the first release

- App Store distribution.
- Camera, microphone and online play.
- A single app that runs an arbitrary 3DS library.
- JIT or debugger-assisted execution.
