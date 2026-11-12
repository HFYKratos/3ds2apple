# zakuro-ios

Rust static library that embeds the [Zakuro](https://github.com/fearkov/zakuro)
3DS runtime in the iOS app. It exposes a small C ABI to Swift and can link
3dsrecomp-generated game code statically.

The 3D is drawn by Zakuro's software PICA200 by default. An optional hardware
path draws it on the host GPU through Vulkan, which on iOS is MoltenVK over
Metal; the architecture, the upstream patch it needs and the A0/A1 plan are in
[METAL.md](METAL.md).

## Build

This crate is built from inside a Zakuro checkout. The repository script does
the copy and patch steps:

```bash
scripts/build-zakuro-ios.sh
```

Output: `build/ios/libzakuro_ios.a` for `aarch64-apple-ios`.

For a per-game AOT build:

```bash
ZAKURO_LINKED_PROGRAM_ID=<16-hex-title-id> \
  cargo build -p zakuro-ios --release --features linked \
  --target aarch64-apple-ios
```

The linked build leaves the seven `_recomp_*` symbols undefined; they are
resolved by `libgame.a` when the app is linked. The app must link
`-lzakuro_ios` before `-lgame`.

The build disables Zakuro's optional Cranelift shader JIT: iOS does not allow
executable memory for ordinary apps.

### Hardware-rendering build (MoltenVK A0)

The Vulkan renderer is already compiled into `libzakuro_ios.a`; on iOS it only
needs a loadable MoltenVK and one small patch to where Zakuro looks for it. A
hardware-rendering build takes two extra steps:

```bash
# 1) after scripts/build-zakuro-ios.sh created the local checkout: fix the
#    iOS MoltenVK lookup (see METAL.md §8.2)
git -C third_party/zakuro apply "$PWD/ios/zakuro-ios/patches/0001-vulkan-on-ios.patch"

# 2) build the per-game runtime with hardware rendering on by default
ZAKURO_IOS_HARDWARE=1 scripts/build-linked-ios-lib.sh <name> --title-id <16-hex-title-id>
```

`ZAKURO_IOS_HARDWARE` accepts `1`, `on`, `true` or `yes` at compile time. It is
the A0 test-building switch: the app does not have to change code, and if no
Vulkan device can be made the loader falls back to software and logs why. Leave
it unset for release builds; the app can call `zk_set_hardware_renderer` from a
setting instead.

The built app must also contain MoltenVK (embed `MoltenVK.framework`, or link
the static library). The binary is never committed; download it into `build/`
as described in [METAL.md](METAL.md) §8.3.

## C ABI

`ios/ZakuroBridge.h` declares the functions used by Swift.

| Function | Purpose |
|---|---|
| `zk_create(rom, data_dir)` | Load a decrypted ROM; returns an opaque handle or NULL |
| `zk_last_error()` | Last `zk_create` error on the calling thread |
| `zk_run_frame(system)` | Run one 3DS frame (0 completed, 1 exited, negative fault) |
| `zk_screen_width(which)` / `zk_screen_height(which)` | 400×240 upper, 320×240 lower |
| `zk_read_screen(system, which, out, cap)` | Copy RGBA8 pixels; returns full byte count |
| `zk_take_audio(system, out, cap)` | Drain interleaved stereo `i16` PCM |
| `zk_set_input(system, buttons, cx, cy, touch, tx, ty)` | Push buttons, Circle Pad and touch |
| `zk_destroy(system)` | Release the runtime |
| `zk_linked_code()` | 1 if this build contains linked AOT code |
| `zk_linked_program_id()` | Title ID the linked code was built for |
| `zk_recompiled(system)` | 1 if the running title is executing linked code |
| `zk_hardware_probe()` | Build a Vulkan device and drop it again: `0` = the host GPU can be used, `-1` = not (reason in `zk_last_error`/stderr). Needs no ROM |
| `zk_set_hardware_renderer(enabled)` | Draw the 3D on the host GPU for the next `zk_create` (`0` = software). Process-wide; systems already loaded keep their renderer. Returns `0` |
| `zk_set_vulkan_library(path)` | Name the MoltenVK framework/dylib to load (`@executable_path/…`, `@rpath/…` or absolute); `0`, or `-1` for NULL/non-UTF-8. Call before `zk_create` |
| `zk_set_hardware_option(name, value)` | Renderer switches (`gpu_shaders`, `cpu_shaders`, `static_blend`, `float_depth`, …); NULL/empty unsets. `0`, or `-1` for an unknown name/NULL/non-UTF-8. Call before `zk_create` |
| `zk_hardware_status(system)` | One-line renderer status: host GPU with scale, requested-but-fell-back, or software. A NULL handle reports the last probe. Pointer is library-owned like `zk_recompiled_status` |

Additional diagnostics used by the app's HUD/logs include
`zk_last_frame_micros`, `zk_last_screen_read_micros`,
`zk_last_audio_take_micros`, `zk_recompiled_status`, `zk_profiler_start` and
`zk_profiler_hot_spots` (see `src/lib.rs`).

The hardware functions keep the same error contract as `zk_create`:
`zk_hardware_probe` (no Vulkan device), `zk_set_vulkan_library` and
`zk_set_hardware_option` (invalid arguments) write `zk_last_error` on the
calling thread; `zk_set_hardware_renderer` cannot fail. Their prototypes are not
in `ios/ZakuroBridge.h` yet, so Swift cannot call them until they are added
there; the build-time `ZAKURO_IOS_HARDWARE` switch needs no header change.

## Threading

- `zk_system_t` is not thread-safe.
- Every call that takes a handle must run on one serial queue.
- `zk_last_error` returns a thread-local pointer valid only until the next
  `zk_create`/`zk_last_error` call on the same thread; copy the text before
  hopping queues.
- `zk_destroy` must not run concurrently with any other call on the handle.
- The hardware switches (`zk_set_hardware_renderer`, `zk_set_vulkan_library`,
  `zk_set_hardware_option`) are process-wide and are read by the next
  `zk_create`; call them on the runtime's serial queue before loading a ROM.

## Linked AOT code

3dsrecomp writes generated C plus the `recomp_abi`, `recomp_entries` and
`recomp_modules` tables. Compile that C for `arm64-apple-ios` into `libgame.a`
and link it into the app. `zk_create` builds Zakuro's `Linked` value from those
tables; the loader checks the title ID and interface version and falls back to
the interpreter when they do not match.

## Hardware rendering (Metal via MoltenVK)

`zk_create` reads the hardware-rendering switch and asks Zakuro's loader for the
GPU path. The loader builds the Vulkan device itself, falls back to software
with a `zk[WARN]` log line when it cannot, and the app is unchanged: screens are
still read back with `zk_read_screen` (the GPU→CPU readback makes the HUD's
`read top/bottom` phases more expensive), and `zk_hardware_status` reports what
a loaded system ended up drawing on.

- **A0** (this build): renderer on the GPU, presentation stays CPU readback.
  Needs only the patch, MoltenVK in the app, and `ZAKURO_IOS_HARDWARE=1`.
- **A1** (not implemented): presentation on a `CAMetalLayer` swapchain, removing
  the readback; designed in [METAL.md](METAL.md) §3.2.

The `zk_perf` line's `gpu` field means CPU-side command-list/submit time when
the hardware renderer is on, not software rasterisation time; compare software
and hardware builds on the same scene. The system Metal Performance HUD
(`MetalHudEnabled` in the test IPA's Info.plist) shows FPS/GPU/memory alongside
the in-app HUD.

## Tests

The unit tests run inside the Zakuro checkout (the build script creates it and
copies this crate in):

```bash
cd third_party/zakuro
cargo test -p zakuro-ios --lib
ZAKURO_LINKED_PROGRAM_ID=<16-hex-title-id> cargo test -p zakuro-ios --lib --features linked

# Host Vulkan/MoltenVK probe: builds and drops a device. Ignored by default;
# a machine without Vulkan (or MoltenVK) fails it by design.
cargo test -p zakuro-ios --lib -- --ignored hardware_probe_makes_a_device
```

The tests do not need a ROM or an iOS device. The A0 device verification steps
are in [METAL.md](METAL.md) §8.

## Layout

```text
src/lib.rs       C ABI, handle/error handling, linked table wiring, hardware FFI
src/perf.rs      frame-time logging and profiler helpers
build.rs         linked-build title ID validation
Cargo.toml       staticlib crate; `linked` and `profiling` features
METAL.md         Metal/MoltenVK evaluation, A0/A1 plan, build and device steps
patches/         upstream Zakuro patch for the iOS MoltenVK lookup
```

## Limitations

- Only the base ROM is passed to the runtime; update, DLC and mods are not yet
  exposed through the C ABI.
- The GPU is software-rendered by default. The MoltenVK hardware path is
  experimental and still being evaluated on device.
- Generated game code is game-derived and must never be committed.
