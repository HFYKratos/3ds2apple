# zakuro-ios

Rust static library that embeds the [Zakuro](https://github.com/fearkov/zakuro)
3DS runtime in the iOS app. It exposes a small C ABI to Swift and can link
3dsrecomp-generated game code statically.

The 3D is drawn by Zakuro's software PICA200 by default. An optional hardware
path draws it on the host GPU through Vulkan, which on iOS is MoltenVK over
Metal, and can present the screens on the app's own `CAMetalLayer` instead of
copying them back to the CPU; the architecture, the upstream patch it needs and
the A0/A1 split are in [METAL.md](METAL.md).

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

### Hardware-rendering build (MoltenVK)

The Vulkan renderer is already compiled into `libzakuro_ios.a`; on iOS it only
needs a loadable MoltenVK and one small patch to where Zakuro looks for it. In
order:

```bash
# 1) create the local Zakuro checkout (and the plain static library); the
#    script applies ios/zakuro-ios/patches/*.patch idempotently
scripts/build-zakuro-ios.sh

# Existing checkout only: apply the patches by hand (see METAL.md §8.2).
git -C third_party/zakuro apply "$PWD/ios/zakuro-ios/patches/0001-vulkan-on-ios.patch"
git -C third_party/zakuro apply "$PWD/ios/zakuro-ios/patches/0002-pipeline-cache-save-every.patch"

# 2) build the per-game runtime: this recompiles the runtime from the patched
#    checkout (applying any missing patch again), with hardware rendering on
#    by default
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

### Presentation on a CAMetalLayer (A1)

The same library build serves the presented path; the presenter itself is made
at run time from the app's `UIView` (`zk_presenter_create`). A build that embeds
MoltenVK is enough: the app creates the presenter and loads through
`zk_create_presented` automatically, and falls back to `zk_create` (A0/software,
CPU readback) when the presenter cannot be made.

`ZAKURO_IOS_HARDWARE` is **not** needed for A1: `zk_create_presented` asks for
the GPU renderer itself, because the screens the renderer draws have to be the
ones the presenter shows. Setting it only affects a plain `zk_create` load, i.e.
the A0 fallback build.

The presented layer is not fixed to the console's stacked portrait layout:
`zk_presenter_set_layout` and `zk_presenter_set_orientation` arrange and turn
the screens (stacked, side by side, a single screen, or the console arrangement
rotated a quarter turn), `zk_present_layout_size` reports the drawable pixels
that shows an arrangement without letterboxing, and `zk_present_touch_map`
applies the same layout/rotation when the app maps a touch. The app's display
settings use these live while a game runs.

The app still has to embed MoltenVK; [METAL.md](METAL.md) §8.3 has the download
and packaging steps.

## Pipeline cache and first-run warm-up (app warm-up removed in 0.1.1)

The Vulkan renderer compiles a draw pipeline the first time a draw needs it.
On a first run (empty cache) those driver compiles can take hundreds of
milliseconds and land inside `zk_run_frame`; later runs read the same
pipelines from disk and are smooth. The repository has a small upstream patch
plus app-side behaviour that keeps the first-run cost on a loading screen:

- **Cache location.** `XDG_CACHE_HOME` is pointed at the app's Caches
  directory, so Zakuro keeps one file per title in
  `Library/Caches/zakuro/pipelines/<title-id>.bin`. The cache is regenerable
  data (iOS may purge it) and never contains game content that is not already
  part of the build.
- **Durability.** `patches/0002-pipeline-cache-save-every.patch` lowers
  Zakuro's `SAVE_EVERY` from 60 s to 5 s, so an early exit keeps most of the
  compiled pipelines; `zk_destroy` (Unload, Change ROM, background) also saves
  the cache on the way out. The app logs the directory contents after
  `zk_destroy` so this is visible in device logs and diagnostics.
- **Warm-up (removed in 0.1.1).** The app-level "Preparing graphics" warm-up
  overlay was removed together with its Settings option; a game is revealed as
  soon as it loads. The runtime pipeline cache above still absorbs the first
  compiles of later sessions, and a pipeline first used during play compiles on
  a worker thread (async creation below) instead of a loading screen.
- **Async creation.** Zakuro already compiles new draw combinations on its
  own `shader compiler` threads and draws through a generic fallback pipeline
  meanwhile; dropping draws until a pipeline is ready is analysed in
  [METAL.md](METAL.md) §10 but is not enabled, because a skipped draw can be
  observed by a title's own framebuffer/depth readbacks and change game state.

The app-side thresholds, log lines and diagnostics fields are documented in
[METAL.md](METAL.md) §10 and [ios/app/README.md](../app/README.md).

## C ABI

`ios/ZakuroBridge.h` declares the functions used by Swift.

| Function | Purpose |
|---|---|
| `zk_create(rom, data_dir)` | Load a decrypted ROM; returns an opaque handle or NULL |
| `zk_last_error()` | Last failure on the calling thread (`zk_create`, save-state and hardware/presenter calls) |
| `zk_run_frame(system)` | Run one 3DS frame (0 completed, 1 exited, negative fault) |
| `zk_screen_width(which)` / `zk_screen_height(which)` | 400×240 upper, 320×240 lower |
| `zk_read_screen(system, which, out, cap)` | Copy RGBA8 pixels; returns full byte count |
| `zk_take_audio(system, out, cap)` | Drain interleaved stereo `i16` PCM |
| `zk_set_input(system, buttons, cx, cy, touch, tx, ty)` | Push buttons, Circle Pad and touch |
| `zk_set_cstick(system, cx, cy)` | Push the New 3DS C-stick vector that the next `zk_set_input` on the same thread carries (additive; (0, 0) releases it) |
| `zk_keyboard_pending(system)` | 1 while a title waits on the 3DS software keyboard (library applet), 0 when none is open or NULL; poll after every frame |
| `zk_keyboard_request_json(system)` | The pending request as JSON (schema 1: `hint`, `text`, `maxLength` in UTF-16 units, `buttons` left to right, `valid` rule); NULL when none. Library-owned thread-local pointer like `zk_recompiled_status`; the document is within `ZK_KEYBOARD_JSON_MAX_BYTES` |
| `zk_answer_keyboard(system, text, button)` | Answer with UTF-8 text and the button index (0 = leftmost, last confirms): `0` answered, `-1` bad handle, `-2` bad text, `-3` no request. The title continues from the frame it waited in |
| `zk_destroy(system)` | Release the runtime (and a measured saved state it did not copy) |
| `zk_save_state_size(system)` | Serialize the console once and return the saved state's byte count; the blob is kept for the copy. `0` on error |
| `zk_save_state_copy(system, out, cap)` | Copy the measured saved state, or only report its length with `out == NULL`; returns the full byte count (a short buffer is logged), `0` on error |
| `zk_save_state_discard(system)` | Release a measured saved state that will not be copied (tens of MiB) |
| `zk_load_state(system, data, length)` | Restore a saved state: `0` loaded, `-1` bad handle, `-2` bad argument, `-3` refused |
| `zk_presenter_create(ui_view, width, height)` | Make a Vulkan presenter for a `UIView` whose layer is a `CAMetalLayer`; returns an opaque presenter or NULL |
| `zk_presenter_resize(presenter, width, height)` | New drawable size in pixels (layout/rotation/render scale); the swapchain rebuilds on the next present |
| `zk_presenter_destroy(presenter)` | Release the presenter; destroy its systems first |
| `zk_presenter_shared_device(presenter)` | 1 when the renderer can draw on the presenter's device (no readback), 0 for upload presentation, -1 for NULL |
| `zk_presenter_set_layout(presenter, layout)` | Arrange the screens (`ZK_LAYOUT_*`: stacked, side by side, upper only, lower only, large upper); 0, or -1 for NULL/unknown |
| `zk_presenter_set_orientation(presenter, orientation)` | Turn the screens clockwise (`ZK_ORIENTATION_*`: north/east/south/west); 0, or -1 for NULL/unknown |
| `zk_present_layout_size(layout, orientation, out_w, out_h)` | Drawable pixels that show a layout without letterboxing (stacked 400×480 north / 480×400 east-west, side by side 720×240, …); 1, or 0 for unknown/NULL |
| `zk_create_presented(rom, data_dir, presenter)` | `zk_create` on the presenter's device: GPU renderer requested, screens presented through the layer |
| `zk_present(system, presenter)` | Present the frame `zk_run_frame` just drew; 0 ok, 1 swapchain out of date (continue), -1 bad handle, -2 failed |
| `zk_present_mode(system, presenter)` | Presentation path of a loaded system: 0 readback, 1 GPU direct, 2 uploaded |
| `zk_present_touch_map(width, height, layout, orientation, x, y, out_x, out_y)` | Normalised touch on the presented layer → lower-screen pixels (1) or not on it (0), for the presenter's layout and rotation |
| `zk_linked_code()` | 1 if this build contains linked AOT code |
| `zk_linked_program_id()` | Title ID the linked code was built for |
| `zk_recompiled(system)` | 1 if the running title is executing linked code |
| `zk_hardware_probe()` | Build a Vulkan device and drop it again: `0` = the host GPU can be used, `-1` = not (reason in `zk_last_error`/stderr). Needs no ROM |
| `zk_set_hardware_renderer(enabled)` | Draw the 3D on the host GPU for the next `zk_create` (`0` = software). Process-wide; systems already loaded keep their renderer. Returns `0` |
| `zk_set_vulkan_library(path)` | Name the MoltenVK framework/dylib to load (`@executable_path/…`, `@rpath/…` or absolute); `0`, or `-1` for NULL/non-UTF-8. Call before `zk_create` |
| `zk_set_hardware_option(name, value)` | Renderer switches (`gpu_shaders`, `cpu_shaders`, `static_blend`, `float_depth`, …); NULL/empty unsets. `0`, or `-1` for an unknown name/NULL/non-UTF-8. Call before `zk_create` |
| `zk_set_render_scale(scale)` | Internal 3D render scale of the host-GPU renderer: `1`–`4` (`1` = 400×240, `4` = 1600×960) for the next `zk_create`/`zk_create_presented`; a loaded system keeps its scale (no run-time renderer rebuild), and the software renderer always draws at `1`×. `0`, or `-1` when the scale is outside `1..4` (setting unchanged, reason in `zk_last_error`). Call before the load |
| `zk_hardware_status(system)` | One-line renderer + present status: host GPU with scale and whether the screens go straight to the Metal layer or are read back; requested-but-fell-back, or software. A NULL handle reports the last probe. Pointer is library-owned like `zk_recompiled_status` |

Additional diagnostics used by the app's HUD/logs include
`zk_last_frame_micros`, `zk_last_frame_gpu_busy_micros`,
`zk_last_screen_read_micros`, `zk_last_audio_take_micros`,
`zk_recompiled_status`, `zk_profiler_start` and `zk_profiler_hot_spots` (see
`src/lib.rs`).

`zk_last_frame_gpu_busy_micros()` is the software GPU's command-list walk inside
the last `zk_run_frame()` (the `gpu` half of the `zk_perf` split); the rest of
`zk_last_frame_micros()` is emulated CPU/HLE work. The shell reads it after
every frame to split `run` in its diagnostics report, so a CPU-bound scene and a
first-use pipeline compile are told apart on a device. It is declared in
`ios/ZakuroBridge.h` because the app calls it.

The hardware functions keep the same error contract as `zk_create`:
`zk_hardware_probe` (no Vulkan device), `zk_set_vulkan_library` and
`zk_set_hardware_option` (invalid arguments), and the presenter calls
(`zk_presenter_create` on a bad view/size, `zk_create_presented` on a load or
device failure, `zk_present` on a presentation failure) write `zk_last_error` on
the calling thread; `zk_set_hardware_renderer` cannot fail. `zk_hardware_status`,
`zk_set_render_scale` and the presentation functions are declared in
`ios/ZakuroBridge.h` (the Swift bridging header); the probe and renderer-option
switches are declared in `src/lib.rs` only and are documented here, so the app
does not call them today. The build-time `ZAKURO_IOS_HARDWARE` switch needs no
header change.

## Software keyboard (3DS text input)

A 3DS title that needs text (a player name, a message, a password) starts the
console's software-keyboard library applet and waits on it. Zakuro already carries
the applet (`zakuro-core/src/services/keyboard.rs`: `System::keyboard_request()`
and `System::answer_keyboard()`); this crate exposes it to the app, so a title no
longer waits forever:

1. Poll `zk_keyboard_pending(system)` after every `zk_run_frame`. It is a flag
   check, cheap enough per frame.
2. When it reports 1, copy `zk_keyboard_request_json(system)` (NULL when no
   request is open). The document is schema 1 and always within
   `ZK_KEYBOARD_JSON_MAX_BYTES` (16 KiB):

   ```json
   {"schema":1,"hint":"Your name","text":"Link","maxLength":8,
    "buttons":["Cancel","OK"],"valid":"notEmptyNotBlank"}
   ```

   `hint` and `text` are the applet's prompt and initial text,
   `maxLength` is the title's limit in UTF-16 units, `buttons` are the labels
   left to right (the last one confirms) and `valid` is the confirming button's
   rule: `anything`, `notEmpty`, `notEmptyNotBlank`, `notBlank` or
   `fixedLength` (exactly `maxLength` units). The app mirrors those checks for
   the overlay; the non-confirming buttons never apply the rule. A very long
   initial text is cut (never mid-character) to keep the document bounded; the
   answer path truncates what goes back to `maxLength` and to the shared block
   regardless.
3. Stop the frame loop while the request is open: the title is waiting on the
   applet, so further frames would only burn CPU (the desktop frontend stops
   emulating while it types for the same reason). The app clears input and stops
   its audio engine for the same duration.
4. Call `zk_answer_keyboard(system, text, button)` on the runtime serial queue:
   0 answered, -1 bad/null handle, -2 NULL or non-UTF-8 text, -3 no request open.
   Button 0 is the leftmost and the last one confirms; a larger index counts as
   the last button. The title wakes on its next frame, which the app resumes.

The pointer `zk_keyboard_request_json()` returns is library-owned and valid until
the next keyboard call on the same thread (like `zk_recompiled_status`), so copy
it. Polling, reading and answering all belong on the runtime's serial queue. The
three functions are additive: an app that never calls them keeps the old
behaviour (the title simply keeps waiting), and no existing signature changed.

## Saved states

The library can write the whole console — CPU, kernel objects, services, GPU
state and the four memories — to one compressed blob between frames and put it
back later, which is what instant save slots need. A blob is tens of MiB: the
raw memories are 128 MiB of FCRAM plus 6 MiB of VRAM and 1 MiB of DSP RAM/AXI
WRAM on an Old3DS build (256 MiB FCRAM on a New3DS build), LZ4-compressed into
one file. The exact size is what `zk_save_state_size` returns; the hard limit in
either direction is `ZK_SAVE_STATE_MAX_BYTES` (512 MiB).

The C ABI is a size → copy protocol, because the compressed size is only known
after the state has been written:

1. `zk_save_state_size(system)` serializes the console once and returns the
   byte count, keeping the blob inside the library.
2. The app allocates that many bytes and calls
   `zk_save_state_copy(system, out, capacity)`, which copies the kept snapshot
   and returns its length. A short buffer copies what fits, logs it, and
   returns the full length so the app can retry with a bigger buffer; the kept
   blob makes the retry cheap. A complete copy releases it.
3. `zk_load_state(system, data, length)` restores a blob: `0` on success, `-1`
   for a NULL handle, `-2` for NULL data or a length past the limit, `-3` when
   refused. Before Zakuro reads the state its container is checked (the magic,
   truncation, the section lengths and that the four memories unpack to the
   sizes this console has), so a truncated or damaged file is refused without a
   many-gigabyte allocation and without touching the running console. Zakuro
   then checks the state's format version and title ID and applies nothing
   unless the whole state was read and accepted. The reason for a failure is in
   `zk_last_error` on the calling thread; a success clears it.

A measured state is a snapshot of the console at the `zk_save_state_size` call:
running frames afterwards does not change the bytes the copy gets. It is
released by a complete copy, `zk_save_state_discard`, a load, `zk_destroy`, and
the next measurement of any handle. An app that measures a state and then
abandons it must call `zk_save_state_discard`, because the kept blob is the
size of the state (tens of MiB).

Saves are not files at this level: the app decides where the bytes go (writing
a temporary file and renaming it into place is the safe order) and reads them
back before `zk_load_state`. Save and load are not thread-safe either: pause
the frame loop and call them on the runtime's serial queue like every other
handle call. After a successful load, drop the audio buffered before it (the
DSP state went back too) and refresh the HUD; the state also carries the GPU's
guest-side state, and the hardware paths rebuild the host GPU state from the
restored memory on the next frame.

## Threading

- `zk_system_t` is not thread-safe.
- Every call that takes a handle must run on one serial queue.
- `zk_last_error` returns a thread-local pointer valid only until the next call
  that records or clears an error on the same thread; copy the text before
  hopping queues.
- The software-keyboard calls take the handle too: poll
  `zk_keyboard_pending`/`zk_keyboard_request_json` after a frame and answer with
  `zk_answer_keyboard` on the same serial queue. The JSON pointer is thread-local
  and valid only until the next keyboard call on that thread.
- `zk_destroy` must not run concurrently with any other call on the handle.
- Save and load follow the same rule and run between frames: a save or load
  copies the whole console (tens of MiB) and can take from tens of milliseconds
  to about a second, so the frame loop should be paused for it.
- The hardware switches (`zk_set_hardware_renderer`, `zk_set_vulkan_library`,
  `zk_set_hardware_option`) are process-wide and are read by the next
  `zk_create`; call them on the runtime's serial queue before loading a ROM.
- A presenter (`zk_presenter_t`) is not thread-safe either. Create, resize and
  destroy it on the main queue (it wraps a `UIView`); call `zk_present` on the
  same serial queue as `zk_run_frame`, after the frame completed, and change its
  layout/orientation on that serial queue too while a system is presenting (or
  on the main queue before a load starts). Destroy the systems loaded with
  `zk_create_presented` before the presenter.

## Linked AOT code

3dsrecomp writes generated C plus the `recomp_abi`, `recomp_entries` and
`recomp_modules` tables. Compile that C for `arm64-apple-ios` into `libgame.a`
and link it into the app. `zk_create` builds Zakuro's `Linked` value from those
tables; the loader checks the title ID and interface version and falls back to
the interpreter when they do not match.

A port can have a **single code unit**: 3dsrecomp writes the module count as
`units.len() - 1`, so a program with no CRO modules has
`recomp_module_count == 0` and an empty `recomp_modules` table. That is a
complete program - all of its code is in `recomp_entries` - and the loader,
`recomp-abi`'s `Library::linked` and the run path all accept it; nothing reads
the empty module table. A GamePack may therefore pass `modules == NULL` when
`module_count == 0` (registration replaces it with a non-NULL placeholder so
the empty slice is well-formed); the entries and origins tables and a non-zero
entry count are still required. `src/gamepack.rs` has regression tests for this
shape.

## Hardware rendering (Metal via MoltenVK)

There are two levels, and the app picks the better one it can run:

- **A1, presented** — the app owns a `UIView` whose backing layer is a
  `CAMetalLayer`, creates a presenter for it (`zk_presenter_create`) and loads the
  ROM with `zk_create_presented`. The renderer draws on the presenter's Vulkan
  device (`direct` presentation), and `zk_present` shows the frames straight from
  the GPU: no `zk_read_screen`, no `CGImage`. If the GPU renderer cannot start,
  the loader falls back to software and the presenter uploads the pixels through
  the same layer (`zk_present_mode` = 2), so the app still has no readback code
  and a real Metal layer. The system Metal Performance HUD can attach to that
  layer.
- **A0 / readback** — plain `zk_create` (+ `ZAKURO_IOS_HARDWARE=1` for the GPU
  renderer): screens are read back with `zk_read_screen` and shown as `CGImage`.
  This is the fallback when no presenter can be made (for example no MoltenVK in
  the app) and the path used by non-presented builds.

The loader always falls back to software with a `zk[WARN]` log line when a
device cannot start, and `zk_hardware_status` reports what a loaded system ended
up drawing on (including whether the screens go straight to the layer or are
read back).

The `zk_perf` line's `gpu` field means CPU-side command-list/submit time when
the hardware renderer is on, not software rasterisation time; compare software
and hardware builds on the same scene. The system Metal Performance HUD
(`MetalHudEnabled` in the test IPA's Info.plist) shows FPS/GPU/memory alongside
the in-app HUD.

## GPU execution timing and renderer A/B switches (0.1.3)

`zk_perf`'s `gpu` column times the host's command-list walk, which is what the
CPU records; it is not how long the GPU executes the frame. The renderer can
measure that itself with Vulkan timestamp queries: with `ZAKURO_GPU_TIMES=1`
set before a load (the app's diagnostic GPU profiles do) every change of work
kind stamps the GPU's clock, and the per-kind totals, pipeline statistics and
the host's waits for the GPU are kept. It costs timestamp writes and fence
reads, so a normal build leaves it off.

The app reads it through:

| C ABI | What it reports |
|---|---|
| `zk_gpu_timing_status()` | 1 when the times are being measured |
| `zk_gpu_exec_micros_per_frame()` | real GPU execution time per frame, the average of the last 60-frame window (the same number the system Metal HUD shows) |
| `zk_gpu_times_line(out, capacity)` | the window's breakdown: time per kind (`draw`, `upload`, `clear`, `transfer`, `capture`, `copy`, `download`, `barrier`, `upright`, `readback`, `other`), render passes, barriers, draws, the host's waits, the shaded vertices/primitives/fragments per frame, the render targets by GPU time (`target 0xADDR WxH[+d] X.XXms/f (N passes, M draws)`, the one that cost most first), the per-pass report (`zk_passes:`: the dominant target's passes in recording order, each one's GPU milliseconds, draws, depth and twin, and what ended the pass before it, with the window's pass breaks), the kinds of work the batches started (`ops ...`), the draw-state classes by GPU time (`draw_classes`: `blend/alpha/tex/write/coverage X.XXms/f N/f Y.YYMpx/f`, the class that cost most first, see below), the `safe_skips N/f D.DDMpx/f` counter, and, when the opaque sort is on, `sorted N/f of M/f draws in R/f runs` with the reason each draw was held or not |

The periodic log line gains `gpu_exec X.XXms/f passes N/f barriers M/f` (plus
`shaded V/P/F` when the device keeps pipeline statistics), and a second
`zk_gpu:` line has the full breakdown. Every render target a timestamped batch
draws into is timed as well, and a `GPU render targets over N batches: ...`
line (log target `zakuro_gpu::passes`) names the targets that cost most, so the
largest render pass of a title can be identified without guessing. Each
timestamped pass is also kept as an instance with its own milliseconds, draws,
depth, twin and the reason the pass before it ended, and a `zk_passes:` line
(log target `zakuro_gpu::passes`, carried in `gpu_times_line`) reports the
dominant target's passes in recording order: that is what says whether a title's
run of passes into one buffer is a depth switch, a texture upload, a transfer or
a capture, and what a pass merge would join. The numbers
come from
`zakuro_gpu::GpuTimes`, the same type the desktop renderer can log with
`ZAKURO_GPU_TIMES=1` (`GPU over N batches: ...` lines).

A frame that is fill bound needs its draw time split by draw state, not only by
render target. `ZAKURO_GPU_TIMES=1` also buckets the draw time five ways: the
blend kind (off, the usual source-alpha over, anything else), whether the alpha
test is on, how many texture units are enabled, what the draw may write (color
and depth, color only, a partial color mask, nothing) and how much of the target
its triangles estimate to cover (under a sixteenth, under a quarter, more; a
draw the GPU shades has no placed vertices so its coverage is unknown). That is
`3 x 2 x 4 x 4 x 4` classes. The timestamp is written when the class changes,
not on every draw, so the buckets cost a handful of extra query writes per
batch instead of one per draw; the time between two stamps goes to the class of
the draw before it, and the draws and the pixels their triangle areas add up to
are counted per class the same way. A `GPU draw classes over N batches: ...`
line (log target `zakuro_gpu::draws`) lists the ten most expensive classes with
their milliseconds, draws and estimated megapixels, and `gpu_times_line` carries
the same as `draw_classes ...` plus `safe_skips ...`. Time and pixels per class
together say what a class's milliseconds buy: a class whose ms/f is high and
whose Mpx/f is higher than the frame's pixels is overdraw, and the fragment
cost per megapixel is what a texture/ALU change would have to lower.

Renderer switches the diagnostic profiles use (all default off, read once when
the renderer is built, so set them before a load):

| Variable | Effect |
|---|---|
| `ZAKURO_FAST_CLEARS=1` | a clear of every row goes through `vkCmdClear*Image` instead of a render pass with LOAD+STORE: it writes the rows and nothing else |
| `ZAKURO_FAST_BARRIERS=1` | the barrier a render pass waits for after a target switch is scoped to the attachment and transfer stages instead of `ALL_COMMANDS` |
| `ZAKURO_SORT_OPAQUE=1` | opaque draws of a render pass whose state may be reordered (depth test and write on, no blending or logic op, no stencil writes, vertices placed on the CPU so their depth is known) are held back and recorded front to back, the nearest first, so the early depth test drops the fragments hidden behind them. Alpha test and partial colour masks no longer keep a draw out: they cannot change what any order draws. Draws at the same depth keep their order (stable sort), everything else keeps the title's order, and the picture must not change. Every draw's reason is counted (`off`, `twins`, `no-pass`, `no-depth`, `compare`, `write-off`, `blend`, `logic`, `stencil`, `gpu-vertices`, `no-vertices`, `sorted`) and a `zk_sort:` line says whether it engaged at all |
| `ZAKURO_MERGE_PASSES=1` | a draw the guest gives no depth buffer, into the color buffer a pass with depth is already drawing into, keeps that pass and draws with the depth attachment it has and no depth test or write: the picture is the same and the pass does not end and begin again. The line gains `merged N draws/f` |
| `ZAKURO_DEDUPE_CAPTURE=1` | a capture of a surface asked for again in the same batch, with nothing drawn since the last capture, is skipped; the line gains `captures_skipped N/f` when it happens |
| `ZAKURO_GPU_TIMES=1` | the GPU's own timestamped execution times above (diagnostic only) |
| `ZAKURO_MEASURE_NOBLEND=1` | measurement only, the picture is wrong: every blending draw is written as if the blend were off, so the time blending and its read of the destination cost can be measured apart from the rest of the draw |
| `ZAKURO_MEASURE_FLAT=1` | measurement only, the picture is wrong: every fragment is drawn as one color, with the combiners, the texture fetches, lighting, the procedural texture and the fog neutralized in a copy of the draw's registers. What the draw time loses against the normal build is what the fragment work adds beyond fill and blending |
| `ZAKURO_SAFE_SKIPS=1` | math-equivalent: a draw that can change neither buffer is left out as a whole (no color writes, no depth write and no stencil write, or a blend that leaves the destination as it is), and the time and pixels it would have cost are counted in `safe_skips N/f` instead. The picture must not change |
| `ZAKURO_MEASURE_TEXONLY=1` | measurement only, the picture is wrong: the fragment shader samples the texture units the draw has and outputs their sum and the vertex color, with the combiners, fragment lighting, procedural texture, fog and alpha test left out. `baseline5 - texonly` is what that fragment ALU costs and `texonly - flat` what the texture fetches cost |
| `ZAKURO_FRAG_SPECIALIZE=1` | math-equivalent: a second build of `raster.frag` takes the draw's fragment lighting (the lights on, its switches, the bump and shadow words), the fog's switch and each unit's wrapping as specialization constants, so the driver compiles away the light loop's shape, the fog's test and the border comparisons of units that do not border. The picture must not change; the GPU line counts the draws in `frag_build specialized N/f` |
| `ZAKURO_FRAG_FAST_MATH=1` | math-equivalent apart from rounding: a second build of `raster.frag` without `precise`, so the driver may contract multiply and add into fused operations and approximate. The picture must stay visually the same; the GPU line counts the draws in `frag_build fastmath N/f` |
| `ZAKURO_FRAG_FAST_MATH=1` + `ZAKURO_FRAG_SPECIALIZE=1` | both fragment switches at once: a third build of `raster.frag` with the specialization constants *and* without `precise` runs, so the two savings apply to the same draw. Math-equivalent apart from rounding; the GPU line counts the draws in `frag_build specfast N/f`. Setting only one switch keeps that switch's own build |

**Release default from 0.1.3:** a normal build enables only
`ZAKURO_FRAG_FAST_MATH=1` (`MoltenVKTuning.releaseRendererDefaults`, applied
when no diagnostic GPU profile is selected; an explicit
`THREEDS2APPLE_RENDERER_OPTIONS=ZAKURO_FRAG_FAST_MATH=0` disables it). The
combined build stays diagnostic: it measured within noise of fast-math alone
and the specialized build costs one more pipeline shape per state.

The other hidden renderer switches (`ZAKURO_GPU_SHADERS` / `ZAKURO_CPU_SHADERS`,
`ZAKURO_FLOAT_DEPTH`, `ZAKURO_DEPTH_BLITS`, `ZAKURO_STATIC_BLEND`,
`ZAKURO_GENERIC_SHADERS`, `ZAKURO_INTERPRET_SHADERS`, `ZAKURO_WAIT_FOR_SHADERS`)
predate 0.1.3 and keep their defaults. The 0.1.3 switches change GPU state and
scheduling, never the rendered picture; `ZAKURO_GPU_SHADERS` is the one that
moves vertex shading between CPU and GPU and is a measurement switch of its own.

The GPU timing and the switches are in
`ios/zakuro-ios/patches/0003-gpu-timing-and-render-options.patch`,
`0004-gpu-pass-times-and-opaque-sort.patch`,
`0005-gpu-sort-reasons-and-pass-merge.patch`,
`0006-gpu-draw-classes-and-safe-skips.patch` and
`0007-gpu-fragment-builds.patch` (the fifth round's fast-math, texonly and
specialized builds of the fragment shader, and the sixth round's combined
fast-math + specialized build), applied to
the gitignored Zakuro checkout by `scripts/build-zakuro-ios.sh`, so a static
library built from this repository carries all of them. `scripts/README.md` has
the A/B build and measurement procedure.

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

The GamePack registration rules have host tests in `src/gamepack.rs`
(`register_accepts_a_single_code_unit`, `register_rejects_invalid_tables`,
`register_refuses_an_unaccepted_interface_version`). They use synthetic tables,
so they need no ROM and no generated archive:

```bash
cd third_party/zakuro
cargo test -p zakuro-ios --lib gamepack
```

The presenter FFI has its own host tests (argument validation and the
normalised-touch → lower-screen mapping) in `src/presenter.rs`; unlike
`hardware_probe_makes_a_device` they need no Vulkan. The device verification
steps for hardware rendering and presentation are in [METAL.md](METAL.md) §8.

The saved-state ABI has host tests in `src/savestate.rs`: NULL and argument
validation, the kept-state life cycle, the container preflight against
truncated, damaged and foreign states, and a real save → load round trip on a
console with no ROM loaded. They need no game either, only a few hundred MiB of
host RAM.

The software-keyboard JSON and ABI have host tests in `src/lib.rs`
(`keyboard_json_carries_every_field`,
`keyboard_json_escapes_quotes_and_control_characters`,
`keyboard_json_caps_a_huge_initial_text`, `keyboard_ffi_round_trips_a_request`, ...).
They build a `System` with no ROM, open the applet with a synthetic configuration
and answer it through the C functions:

```bash
cd third_party/zakuro
cargo test -p zakuro-ios --lib keyboard
```

## Layout

```text
src/lib.rs       C ABI, handle/error handling, linked table wiring, hardware FFI,
                 software-keyboard JSON/FFI
src/presenter.rs A1 CAMetalLayer presentation: presenter/swapchain FFI, touch mapping
src/savestate.rs  saved states: size/copy/discard/load FFI, container preflight
src/perf.rs      frame-time logging and profiler helpers
build.rs         linked-build title ID validation
Cargo.toml       staticlib crate; `linked` and `profiling` features
METAL.md         Metal/MoltenVK evaluation, A0/A1 plan, build and device steps
patches/         upstream Zakuro patches: iOS MoltenVK lookup and the
                5 s pipeline-cache save interval
```

## Limitations

- Only the base ROM is passed to the runtime; update, DLC and mods are not yet
  exposed through the C ABI.
- The GPU is software-rendered by default. The MoltenVK hardware path and its
  CAMetalLayer presentation are experimental and still being evaluated on device.
- A presented session reuses one presenter (and one Metal view) for its lifetime;
  the swapchain is rebuilt on rotation/layout changes. 3D stereo, frame
  interpolation and texture packs are not exposed by the app yet.
- Generated game code is game-derived and must never be committed.
