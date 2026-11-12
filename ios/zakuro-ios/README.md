# zakuro-ios

Rust static library that embeds the [Zakuro](https://github.com/fearkov/zakuro)
3DS runtime in the iOS app. It exposes a small C ABI to Swift and can link
3dsrecomp-generated game code statically.

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

Additional diagnostics used by the app's HUD/logs include
`zk_last_frame_micros`, `zk_last_screen_read_micros`,
`zk_last_audio_take_micros`, `zk_recompiled_status`, `zk_profiler_start` and
`zk_profiler_hot_spots` (see `src/lib.rs`).

## Threading

- `zk_system_t` is not thread-safe.
- Every call that takes a handle must run on one serial queue.
- `zk_last_error` returns a thread-local pointer valid only until the next
  `zk_create`/`zk_last_error` call on the same thread; copy the text before
  hopping queues.
- `zk_destroy` must not run concurrently with any other call on the handle.

## Linked AOT code

3dsrecomp writes generated C plus the `recomp_abi`, `recomp_entries` and
`recomp_modules` tables. Compile that C for `arm64-apple-ios` into `libgame.a`
and link it into the app. `zk_create` builds Zakuro's `Linked` value from those
tables; the loader checks the title ID and interface version and falls back to
the interpreter when they do not match.

## Layout

```text
src/lib.rs       C ABI, handle/error handling, linked table wiring
src/perf.rs      frame-time logging and profiler helpers
build.rs         linked-build title ID validation
Cargo.toml       staticlib crate; `linked` and `profiling` features
```

## Limitations

- Only the base ROM is passed to the runtime; update, DLC and mods are not yet
  exposed through the C ABI.
- The GPU is currently software-rendered.
- Generated game code is game-derived and must never be committed.
