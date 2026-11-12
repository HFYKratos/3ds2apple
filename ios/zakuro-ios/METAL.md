# Metal / MoltenVK rendering path

3ds2apple currently draws the 3D with Zakuro's software PICA200 renderer. This
document evaluates moving that work to the host GPU on iPhone/iPad, and records
the two implemented steps: **A0** (the renderer on the GPU through MoltenVK,
presentation kept as the existing CPU readback, behind the `ZAKURO_IOS_HARDWARE`
build switch) and **A1** (the screens presented on a `CAMetalLayer` the app
owns, with no readback). It also records the small upstream Zakuro patch both
need and the steps to build and verify a hardware-rendering build on a device.

Two routes were evaluated:

- **Plan A: reuse Zakuro's Vulkan renderer through MoltenVK.** The renderer is
  already compiled into `libzakuro_ios.a`; MoltenVK is the only missing piece on
  iOS. Split into **A0** (renderer on the GPU, presentation kept as the existing
  CPU readback) and **A1** (presentation moved to a `CAMetalLayer` swapchain).
  Both are implemented; A0 remains the fallback and the measurement build.
- **Plan B: a native Metal PICA200 backend.** Not part of the first release;
  evaluated as a longer-term option.

**Recommendation:** Plan A. A0 needs no Swift change and almost no Rust change;
A1 adds the `CAMetalLayer` presentation that removes the readback and makes the
system Metal HUD work. Plan B should only follow if Plan A's measurements show
the renderer is the bottleneck and a third-party Vulkan translation layer is
unacceptable.

## 1. Summary

Facts checked against upstream [`fearkov/zakuro`](https://github.com/fearkov/zakuro)
`main` on 2026-11-12 (version 0.2.32):

1. **The Vulkan renderer is already inside `libzakuro_ios.a`.** `zakuro-core`
   enables `zakuro-gpu`'s `vulkan` feature for every build, so `ash`,
   `ash-window`, `naga` and the Vulkan device/renderer code are part of the
   static library. No new Cargo feature is needed; the iOS build only disables
   the Cranelift shader JIT.
2. **The only hard iOS gap is MoltenVK library lookup.**
   `zakuro-gpu`'s `instance::entry()` has macOS MoltenVK paths but no iOS ones;
   on iOS `ash::Entry::load()` falls back to `dlopen("libvulkan.dylib")`, which
   fails. The renderer then makes no Vulkan device and the loader silently falls
   back to software. The fix is a ~20-line patch to
   `crates/zakuro-gpu/src/instance.rs` (`patches/0001-vulkan-on-ios.patch`).
3. **A0 needs no Vulkan presentation/swapchain.** With
   `Config.hardware_renderer = true` the loader calls
   `Gpu::enable_hardware_renderer(...)`; without a presenter sharing the device
   it builds the renderer with `direct = false`, and screens are read back from
   guest memory through `sync_gpu`. `zk_read_screen` keeps its exact semantics,
   so the existing `CGImage`/SwiftUI presentation path is unchanged.
4. **A1 (GPU-to-GPU presentation) is implemented.** `ash-window` 0.13 supports
   iOS (`RawWindowHandle::UiKit` → `raw-window-metal` →
   `vkCreateMetalSurfaceEXT`), and `VulkanPresenter::new` accepts any
   `HasDisplayHandle + HasWindowHandle`, so the iOS crate wraps a `UIView*`
   without modifying `VulkanPresenter`. `ios/zakuro-ios/src/presenter.rs` has
   the presenter FFI and the app owns the `CAMetalLayer`; no existing `zk_*`
   signature changed. The system Metal Performance HUD can attach to that layer,
   which the `CGImage` readback path never had.
5. **Measure before investing further.** A0's ceiling is whatever share of the
   frame the software renderer costs; A1's increment is the readback and
   `CGImage` step it removes. The app's HUD shows the phases (run, screen
   reads/CGImage or present, audio) and `zk_perf` splits the same frame, so a
   renderer or presentation change is measured on device rather than guessed.

Decision summary:

| Option | When | Effort (estimate, ±50%) |
|---|---|---|
| **A0** (MoltenVK renderer + existing readback) | implemented: the readback build, and the fallback when a presenter cannot be made | upstream patch (done) + hardware FFI (done) + build/device verification |
| **A1** (CAMetalLayer + swapchain presentation) | implemented: presented path with automatic fallback to A0/software | presenter FFI + Metal view (done) + device verification |
| **A2** (renderer tuning: resolution, vertex shading, pipeline cache) | after A1, driven by HUD data | 1–3 days |
| **Plan B** (direct Metal PICA backend) | not in v1; revisit only if MoltenVK problems block the target frame rate | 3–6 weeks+ |

Main risks: MoltenVK is deprecated by Khronos (though still the recommended
Vulkan-on-iOS implementation), there is no system Vulkan loader on iOS so the
framework must be embedded, Metal driver/extension differences need a device
check, readback has a cost, the first pipeline compile can stutter, and the
patch is local until it lands upstream.

## 2. Upstream Zakuro Vulkan path

> Basis: `fearkov/zakuro` `main` @ `f54cbdb` (version 0.2.32, 2026-11-12).
> Line numbers refer to that revision.

### 2.1 The renderer is in the dependency tree

`crates/zakuro-gpu/Cargo.toml`:

```toml
[features]
default = ["jit"]                      # Cranelift shader JIT; disabled for iOS
opengl  = ["dep:glow"]
vulkan  = ["dep:ash", "dep:ash-window", "dep:naga"]
jit     = [ ... cranelift ... ]
```

`crates/zakuro-core/Cargo.toml:14`:

```toml
zakuro-gpu = { workspace = true, features = ["vulkan"] }
```

So linking `zakuro-core` already links the Vulkan backend;
`scripts/build-zakuro-ios.sh` sets the workspace's `zakuro-gpu` to
`default-features = false`, which only turns off `jit`.

- The Vulkan renderer's SPIR-V is precompiled into the repository
  (`crates/zakuro-gpu/shaders/*.spv`, `include_bytes!`), so building the iOS
  library needs no glslang or MoltenVK toolchain.
- PICA vertex shaders are translated to SPIR-V at run time by **`naga`** (pure
  Rust, on the CPU; `raster/hardware.rs:35`). That is ordinary code, not a JIT.
- Whether vertex shading runs on the GPU (`shades`) defaults to
  `device_type != INTEGRATED_GPU` (`raster/hardware.rs:1711`): **an iPhone is
  integrated, so by default vertices are shaded on the CPU** through the same
  PICA vertex path as the software renderer. On a device, set
  `ZAKURO_GPU_SHADERS=1` (or call `zk_set_hardware_option("gpu_shaders", "1")`)
  to compare, otherwise CPU vertex work can look like "Metal did not help".

### 2.2 `Config`: hardware rendering is three fields

`crates/zakuro-core/src/lib.rs:38`:

| Field | Default | Effect |
|---|---|---|
| `hardware_renderer: bool` | `false` | when `true`, the loader tries the Vulkan renderer; on failure it falls back to software and logs a warning |
| `device: Option<Arc<SharedDevice>>` | `None` | Vulkan device shared with a presenter; `None` lets the renderer make its own, so no presenter is needed |
| `resolution: u32` | `1` | internal render scale (`1` = 400×240) |
| `interpolate: bool` | `false` | frame interpolation; needs a presenter with a shared device (not used in v1) |
| `texture_packs: bool` | `true` | texture packs; need the hardware renderer (the iOS FFI keeps this off) |

`crates/zakuro-core/src/loader.rs:202` (the loader wires it automatically):

```rust
if system.config.hardware_renderer {
    match system.gpu.enable_hardware_renderer(
        system.config.resolution, system.config.device.clone(), Some(title.program_id()),
    ) {
        Ok(name) => log::info!("drawing on {name} through Vulkan"),
        Err(error) => log::warn!("{error}, drawing in software"),
    }
}
```

`zk_create` only has to set `config.hardware_renderer`; the loader creates the
device, falls back on failure and logs. With `config.device = None` it calls
`Hardware::with_device(Arc::new(own_device()?), false, kept)`
(`crates/zakuro-gpu/src/lib.rs:667`): own device, `direct = false`.

### 2.3 Renderer and presentation are separate paths

`crates/zakuro-gpu/src/lib.rs`:

| API | Line | Purpose |
|---|---|---|
| `Gpu::enable_hardware_renderer(scale, device, title)` | 667 | build the `Hardware` renderer; returns the GPU name |
| `Gpu::draws_on_gpu()` | 692 | whether the 3D is really drawn on the GPU |
| `Gpu::shows_directly()` | 711 | whether a presenter can display the GPU image directly (`direct`) |
| `Gpu::scale()` | 799 | current internal render scale |
| `Gpu::screen_image(screen)` / `Gpu::scaled_picture(screen)` | — | GPU image for a presenter / read back into `Vec<u8>` |

`crates/zakuro-core/src/lib.rs`:

| API | Line | Purpose |
|---|---|---|
| `System::read_screen_scaled(screen)` | 1050 | presentation helper: GPU readback (`scaled_picture`) when available, CPU framebuffer otherwise |
| `System::read_screen(screen)` | 1183 | pure CPU path; **what `zk_read_screen` uses** |
| `System::read_screen_at` | 1188 | `sync_gpu(base, len)` first: copies what the GPU drew back into guest memory, then reads |
| `System::gpu_screen(screen)` | 1094 | `GpuScreen` for a presenter that shares the device |

The key point for A0: `zk_read_screen` → `read_screen` → `read_screen_at` →
`sync_gpu` → `Hardware::prepare_read` (GPU→CPU readback). **With the hardware
renderer on, the `zk_read_screen` contract does not change**; only the readback
becomes more expensive (see 5.1).

### 2.4 Presenter (A1 only)

`crates/zakuro-gpu/src/backend/mod.rs:356` defines the `Presenter` trait:
`present(top, bottom, right, overlay)`, `resize`, `set_layout`,
`set_orientation`, `set_top_width`, `set_scaling`, `set_stereo`.
`ScreenImage { width, height, pixels, gpu: Option<GpuScreen> }`
(`backend/mod.rs:12`): when `gpu` is `Some`, the presenter draws from the GPU
image and `pixels` is empty.

`crates/zakuro-gpu/src/backend/vulkan.rs:140`:

```rust
pub fn new(window: &(impl HasDisplayHandle + HasWindowHandle), size: (u32, u32))
    -> Result<VulkanPresenter, PresentError>
```

It enumerates the required extensions, creates a `VkSurface`, picks a device,
and — when `can_render` holds — creates the render device with
`VK_KHR_swapchain`; renderer and presenter share one `SharedDevice`
(`shared_device()`, `backend/vulkan.rs:607`). The desktop frontend wires this up
in `crates/zakuro/src/present.rs:235` (`create_vulkan`) and
`crates/zakuro/src/lib.rs:1740` (`present()`): first `shown(&mut system,
Screen::Top)` (`gpu_screen` if available, else `read_screen_scaled`), then
`backend.present(ScreenImage { ... }, ...)`.

On iOS, surface creation is not a problem: `ash-window` 0.13 has an iOS branch
(`RawWindowHandle::UiKit` → `raw_window_metal::uikit::metal_layer_from_handle` →
`vkCreateMetalSurfaceEXT`). See 4.5. The old `VK_MVK_ios_surface` /
`vkCreateIOSSurfaceMVK` API (`VkIOSSurfaceCreateInfoMVK.pView = UIView*`) is
obsolete in MoltenVK; do not use it.

### 2.5 The complete iOS gap list

| # | Gap | State upstream | Fix |
|---|---|---|---|
| 1 | `instance::entry()` does not know iOS MoltenVK | macOS has `.app/Frameworks` + Homebrew paths; iOS only tries `dlopen("libvulkan.dylib")` | `patches/0001-vulkan-on-ios.patch` (reads `ZAKURO_VULKAN_LIBRARY`, then `@executable_path/Frameworks/MoltenVK.framework/MoltenVK`, `@rpath/libMoltenVK.dylib`) |
| 2 | No MoltenVK binary in the app | — | the app embeds/links MoltenVK (4.3); **the binary is never committed** |
| 3 | `config.hardware_renderer` was hard-coded `false` | `zk_create` | this change makes it switchable at build time (`ZAKURO_IOS_HARDWARE`) and at run time (`zk_set_hardware_renderer`) |
| 4 | No iOS presenter / `UIView` entry point (A1 only) | presenter only accepts winit raw handles | implemented in `ios/zakuro-ios/src/presenter.rs` (3.2): `RawWindowHandle::UiKit` + `VulkanPresenter`; the app adds a `MetalScreenView` (`UIView` + `CAMetalLayer`) |

The Vulkan device/instance requirements behind gap 1 are listed in 4.6.

## 3. What the iOS host must provide

There are two levels: **A0 = renderer only**, **A1 = renderer and presentation**.

### 3.1 A0: renderer only (minimum device verification)

| Need | Provided by | Notes |
|---|---|---|
| A loadable MoltenVK | the app embeds a dynamic framework or links the static library; the downloaded build artifact lives under `build/` (gitignored) | see 4.3; never committed |
| Tell Zakuro where MoltenVK is | the upstream patch; the default `@executable_path/Frameworks/MoltenVK.framework/MoltenVK` path is enough for an embedded framework; `ZAKURO_VULKAN_LIBRARY` overrides it | `zk_set_vulkan_library` wraps the override |
| Turn hardware rendering on | build-time `ZAKURO_IOS_HARDWARE=1` (**no Swift change**), or run-time `zk_set_hardware_renderer(1)` | §7 |
| Presentation | nothing new: existing `zk_read_screen` + `CGImage` + SwiftUI | readback gets more expensive; the HUD's `read top/bottom` rises |
| `CAMetalLayer` / `VkSurface` / swapchain | not needed | A1 only |

A0 data flow:

```text
guest command list ── CPU parse/vertex (interpret PICA shader) ── upload ── Metal (MoltenVK)
                                                          │
     guest-memory framebuffer ←── GPU→CPU readback (direct=false) ┘
                │
     zk_read_screen ── CGImage ── SwiftUI (unchanged)
```

### 3.2 A1: presenter (GPU→GPU presentation) — implemented

A1 replaces the last step of A0 ("readback → `CGImage`") with a Metal swapchain.
The app provides:

1. **A `UIView`** whose `layerClass` is `CAMetalLayer` (`MetalScreenView` in
   `ios/app/Sources/MetalScreenView.swift`). It is laid out at the console's
   400:480 shape, so the presenter's stacked upper/lower screens fit the layer.
   Swift passes it to the FFI with
   `Unmanaged.passUnretained(view).toOpaque()`.
2. **Drawable size in pixels** (the view's `bounds × contentScaleFactor`),
   passed when the presenter is made and again whenever the view is laid out
   (rotation, split view). The view keeps `CAMetalLayer.drawableSize` in step
   because MoltenVK takes the surface extent from it.
3. **A present cadence**: the app's existing free-run frame loop; `zk_present`
   follows each completed `zk_run_frame` on the runtime serial queue. The
   preferred present mode is mailbox (no vblank wait); FIFO is the fallback.
4. **Lifecycle**: the view and the presenter are made on the main queue; the
   system is loaded on the presenter's device and destroyed before the presenter.
   Stopping the frame loop (Unload, background, exit/fault) stops presenting; the
   presenter, its device and the layer are kept for the next load, and are
   released with the app. A size change marks the swapchain stale and it is
   rebuilt on the next present.
5. **C API** (implemented in `ios/zakuro-ios/src/presenter.rs`, declared in
   `ios/ZakuroBridge.h`):

```c
/* UIView* + drawable pixels -> presenter, or NULL (reason in zk_last_error) */
zk_presenter_t zk_presenter_create(void *ui_view, uint32_t width, uint32_t height);
int32_t        zk_presenter_resize(zk_presenter_t presenter, uint32_t width, uint32_t height);
void           zk_presenter_destroy(zk_presenter_t presenter);
/* 1 = the renderer can share the presenter's device (no readback) */
int32_t        zk_presenter_shared_device(zk_presenter_t presenter);
/* load on the presenter's device; zk_create's contract otherwise */
zk_system_t    zk_create_presented(const char *rom_path, const char *data_dir,
                                   zk_presenter_t presenter);
/* present the frame zk_run_frame just drew: 0 ok, 1 out of date, -1 bad, -2 failed */
int32_t        zk_present(zk_system_t system, zk_presenter_t presenter);
/* 0 = readback, 1 = GPU direct, 2 = CPU pixels uploaded through the layer */
int32_t        zk_present_mode(zk_system_t system, zk_presenter_t presenter);
/* normalised touch on the presented layer -> lower-screen pixels */
int32_t        zk_present_touch_map(uint32_t width, uint32_t height, float x, float y,
                                    uint16_t *out_x, uint16_t *out_y);
```

Implementation notes (all verified against the upstream code):

- A small local type implements `HasDisplayHandle`/`HasWindowHandle`
  (`DisplayHandle::uikit()`,
  `RawWindowHandle::UiKit(UiKitWindowHandle::new(view))`) and is passed to
  `VulkanPresenter::new(&handle, (w, h))`; `ash-window` gets the
  `CAMetalLayer` through `raw-window-metal` and calls `vkCreateMetalSurfaceEXT`.
  The view's layer must already be a `CAMetalLayer`, otherwise
  `raw-window-metal` creates a sublayer whose size nothing would track.
- `presenter.shared_device()` becomes `Config.device`; the loader's
  `enable_hardware_renderer(.., Some(device), ..)` then builds the renderer with
  `direct = true`, so `System::gpu_screen()` returns a `GpuScreen` and
  `zk_present` submits
  `ScreenImage { pixels: &[], gpu: Some(..) }` with no readback. Presentation
  cost drops from "0.66 MiB/frame GPU→CPU plus `CGImage`" to one swapchain
  submit.
- A presented system whose renderer stayed in software (or whose presenter has
  no shareable device) still presents: `zk_present` falls back to
  `read_screen_scaled` CPU pixels and uploads them through the same swapchain.
  The app's display path is still the Metal layer, so it never needs the
  `CGImage` code; that path is only used when the presenter itself cannot be
  made.
- The presenter draws the upper screen over the lower one in the console's
  400×480 shape. `zk_present_touch_map` applies the presenter's layout to a
  normalised touch, so the app's on-screen buttons and lower-screen touch work
  without duplicating the layout maths.

## 4. MoltenVK

### 4.1 Version, licence, lifecycle

| Item | Value | Source |
|---|---|---|
| Latest release | **v1.4.2** (released 2026-07-20; GitHub release published 2026-07-24) | GitHub releases / `Docs/Whats_New.md` |
| Vulkan version | 1.4 core (since 1.4.0); Zakuro needs 1.3 | `Whats_New.md` |
| Minimum OS | **iOS 15** (raised to 15 in 1.4.2); this project targets iOS 16 | `Docs/MoltenVK_Runtime_UserGuide.md`; framework `Info.plist` `MinimumOSVersion 15.0` |
| Device slice | `MoltenVK-ios.tar` contains **ios-arm64 (device) only**; the simulator needs `MoltenVK-all.tar` | `Info.plist` in the package |
| Licence | **Apache-2.0** (Brenwill Workshop Ltd.) | package `LICENSE` |
| Maintenance | **Khronos has deprecated MoltenVK** (README caution), but still recommends it for iOS; community best-effort | MoltenVK README |
| Build SDK | v1.4.2 framework `Info.plist`: `DTXcode 26.5` / `iphoneos 26.5`; Xcode 16 / iOS 18 SDK supported since 1.2.10 | framework `Info.plist` / `Whats_New.md` |

**What the deprecation means:** it does not block the plan — MoltenVK is the
only ready-made Vulkan-on-Metal implementation for iOS (KosmicKrisp targets
Apple-silicon macOS only). Record the version and source in `THIRD_PARTY.md` /
`NOTICE`, and pin the version + SHA256. Plan B is the long-term answer only if a
"no third-party render stack" requirement appears.

**Xcode compatibility risk:** the project's build machine uses Xcode 16.4 / iOS
18.5 SDK, while v1.4.2 was built with Xcode 26.5. Linking a framework built with
a newer SDK usually works (deployment target 15.0 ≤ 16.0) but is not guaranteed.
Options, in order: try v1.4.2; if link/runtime problems appear, fall back to
**v1.4.0 or v1.3.x** (Xcode 16 era; do not go below 1.3.0 — Vulkan 1.3 core is
required); upgrading Xcode is a build-machine decision.

### 4.2 Package contents and size (v1.4.2, `MoltenVK-ios.tar`)

Download: <https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar>
(34,535,424 bytes; SHA256
`b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1`)

| Content | Path after extraction | Size | Use |
|---|---|---|---|
| Static library | `MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a` | 7,132,224 B ≈ 6.80 MiB | static link (long term) |
| Dynamic framework | `MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK` | 4,822,128 B ≈ 4.60 MiB | embed + load at run time (A0) |
| Headers | `MoltenVK/MoltenVK/include/` (Vulkan + MoltenVK) | ~22 MiB | build time only; a pure-Rust link does not need them |
| Docs/licence | `MoltenVK/Docs/`, `MoltenVK/LICENSE` | small | archive/attribution |
| Dynamic install name | `@rpath/MoltenVK.framework/MoltenVK` (Mach-O `LC_ID_DYLIB`) | — | decides the rpath |

- The static library exports `vkGetInstanceProcAddr` (and the other `vk*`
  entry points, though `MVK_HIDE_VULKAN_SYMBOLS` hides most by default). That
  is what makes "static link + `ash::Entry::from_static_fn`" possible.
- IPA size impact: **+4.6 MiB** with the dynamic framework (plus its
  `Info.plist`), **+6.8 MiB** statically (a little less after `-dead_strip`).
- **The binary is never committed.** Download it to
  `build/third_party/moltenvk/` (`build/` is gitignored) or a CI temp directory;
  `THIRD_PARTY.md` / `NOTICE` record version, URL, SHA256 and licence only.

### 4.3 Static vs dynamic (A0 uses dynamic)

| | Dynamic framework (**A0**) | Static library (long-term candidate) |
|---|---|---|
| Integration | app embeds `MoltenVK.framework`; Xcode adds `LD_RUNPATH_SEARCH_PATHS = @executable_path/Frameworks` | `OTHER_LDFLAGS` adds `-lMoltenVK -lc++` plus `-framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework IOSurface -framework UIKit` |
| Loading | `Entry::load_from("@executable_path/Frameworks/MoltenVK.framework/MoltenVK")` (in the patch) | the patch would need a second part: `Entry::from_static_fn(StaticFn { vkGetInstanceProcAddr })`, behind an extra feature so non-MoltenVK iOS builds still link |
| Sideload signing | Sideloadly/AltStore re-sign embedded frameworks (common practice; verify once on device) | no extra signing object, most robust |
| Size | +4.6 MiB | +6.8 MiB |
| Upgrading MoltenVK | replace the framework, no relink of the Rust library | relink the app |
| Risk | framework embedding/signing, wrong rpath | more complex patch, more linker flags |

Conclusion: A0 uses the dynamic framework (patch already verified, smallest
change). If signing/rpath turns out to be a problem on device, switch to static
(about 15 more patch lines + a feature).

### 4.4 How Rust `ash` loads MoltenVK

`ash 0.38.0+1.3.281` (used by Zakuro, features `["loaded", "std"]`):

| Method | API | Works on iOS? |
|---|---|---|
| default | `Entry::load()` | **no** — iOS `LIB_PATH = "libvulkan.dylib"`; a bare `dlopen` name does not see the app's `Frameworks` directory (same conclusion as iOS ports of DXVK) |
| explicit path | `Entry::load_from("@executable_path/Frameworks/MoltenVK.framework/MoltenVK")` | **yes** — `@executable_path` / `@rpath` / absolute paths work inside the app |
| static link | `Entry::from_static_fn(StaticFn { get_instance_proc_addr: vkGetInstanceProcAddr })` | **yes** — the MoltenVK static library always exports `vkGetInstanceProcAddr` |
| link-time | `Entry::linked()` (ash `linked` feature) | possible but forces the link dependency on every build; not recommended |

So the minimal patch adds two iOS candidate paths plus a
`ZAKURO_VULKAN_LIBRARY` override to `instance::entry()` (the patch is
`patches/0001-vulkan-on-ios.patch`), with no changes to `ash` and **no Vulkan
loader**: on iOS MoltenVK is
used directly as the Vulkan implementation. Instance creation already handles
`VK_KHR_portability_enumeration` and the device's `VK_KHR_portability_subset`
(upstream PR #26 added that for macOS).

### 4.5 Building a VkSurface from a CAMetalLayer (A1)

Use `VK_EXT_metal_surface` (`vkCreateMetalSurfaceEXT`); the old
`VK_MVK_ios_surface` / `vkCreateIOSSurfaceMVK` is obsolete.

1. **Swift/UIKit**: provide a `UIView` (`UIViewRepresentable` or a view
   controller's view) with `isOpaque = true`; pass the pointer and pixel size to
   Rust.
2. **Rust (handled by `ash-window`)**:
   ```rust
   // raw-window-handle's UiKit handle is the UIView pointer:
   let handle = RawWindowHandle::UiKit(UiKitWindowHandle::new(
       NonNull::new(ui_view).expect("non-null UIView")));
   // ash-window: raw-window-metal gets/creates the CAMetalLayer (delegate,
   // content scale), then VkMetalSurfaceCreateInfoEXT { p_layer } ->
   // vkCreateMetalSurfaceEXT.
   let display = RawDisplayHandle::UiKit(UiKitDisplayHandle::new());
   let extensions = ash_window::enumerate_required_extensions(display)?;
   let surface = unsafe { ash_window::create_surface(&entry, &instance, display, handle, None)? };
   ```
   Required instance extensions: `VK_KHR_surface` + `VK_EXT_metal_surface`
   (`enumerate_required_extensions` returns them); optional
   `VK_KHR_portability_enumeration` + `ENUMERATE_PORTABILITY_KHR` (already
   handled upstream).
3. **CAMetalLayer requirements**: `frame`/`bounds` follow the view;
   `contentsScale = UIScreen.nativeScale`; `drawableSize = bounds * scale`;
   MoltenVK recommends `CAMetalLayer.delegate = UIView` for correct
   swapchain/refresh timing (`raw-window-metal` sets only some properties when
   it creates the layer; the delegate is the caller's job). To use your own
   layer, set `view.layerClass = CAMetalLayer.self` (or assign a new
   `CAMetalLayer`).
4. **Device extensions**: presenter and renderer share the device and need
   `VK_KHR_swapchain`; the renderer adds `VK_KHR_push_descriptor` and, where
   advertised, `portability_subset` plus extended dynamic state. Upstream
   `render_device` already requests these; nothing to write.
5. **Swapchain**: extent = drawable size; present mode FIFO (default, waits for
   vblank) or mailbox; rebuild on `VK_ERROR_OUT_OF_DATE_KHR` or size change
   (`VulkanPresenter` implements `stale`/`resize`; A1 forwards the `UIView`
   size).

### 4.6 MoltenVK vs the renderer's feature requirements

`render_device` (`crates/zakuro-gpu/src/raster/hardware.rs:5619`) requires:

| Requirement | Level | MoltenVK | Notes |
|---|---|---|---|
| Vulkan 1.3 core features: dynamic rendering, synchronization2, pipeline creation cache control | device features13 | yes (1.4.x = Vulkan 1.4; 1.3 core since 1.3.0) | hard requirement; MoltenVK below 1.3.0 will not work |
| `VK_KHR_push_descriptor` | required | yes | required |
| `VK_KHR_swapchain` | presenter | yes | A1 |
| `VK_EXT_metal_surface` + `VK_KHR_surface` | presenter | yes | A1 (or obsolete `VK_MVK_ios_surface`) |
| `VK_KHR_portability_enumeration/subset` | when advertised | yes | handled upstream |
| graphics + compute queue family (`can_render`) | required | yes (Metal has a single family) | required |
| depth format `D24S8` or `D32_SFLOAT_S8` blit | required | yes | Apple GPUs support the D32S8 fallback (upstream implements it) |
| `depthClamp` device feature | required (`render_device` sets `depth_clamp(true)`) | yes (release notes contain depthClamp fixes; tvOS used to lack it) | **device verification point**: if `vkCreateDevice` returns `FEATURE_NOT_PRESENT`, the loader falls back to software; upstream could make depthClamp conditional (~5 lines) |
| `logicOp` | optional | no: not enabled in official releases (needs a `MVK_USE_METAL_PRIVATE_API` build) | a few games using logic ops may render incorrectly; acceptable for v1 |
| `extended_dynamic_state3` (dynamic blend) | optional (static blend otherwise) | yes | performance path |
| `extended_dynamic_state2` (logic op) | optional | yes (but logicOp itself is missing) | — |
| pipeline statistics query | optional (`ZAKURO_GPU_TIMES` diagnostics) | no | diagnostics only, no rendering effect |
| geometry shaders | not needed | — | upstream falls back to the CPU path for geometry draw |

Conclusion: MoltenVK covers everything the renderer needs. The main device
unknowns are `depthClamp` and driver bugs. Any device-creation failure is caught
by the loader, which falls back to software without crashing.

### 4.7 Licence and attribution

| Component | Licence | Handling |
|---|---|---|
| MoltenVK | **Apache-2.0** | compatible with this project; record version/URL/SHA256/LICENSE in `THIRD_PARTY.md` / `NOTICE`; never commit the binary |
| SPIRV-Cross, Vulkan headers (bundled in MoltenVK) | Apache-2.0 (in package) | keep the package's `LICENSE` / `Docs` for attribution |
| `ash` / `ash-window` | MIT OR Apache-2.0 | already in the dependency tree; normal Cargo attribution |
| `raw-window-metal` / `raw-window-handle` / `cocoa` / `objc` | MIT OR Apache-2.0 (Zlib for raw-window-handle) | same; only linked for the A1 path |
| Zakuro patch | MIT (upstream) | prefer sending it upstream as a PR; keep the local patch file until it lands |

Do not copy GPL code from Azahar/Citra; GLSL/TEV semantics may be used as
reference only.

## 5. Plan A

### 5.1 A0: renderer offload, keep CPU-readback presentation

**Change list:**

| # | Change | File |
|---|---|---|
| 1 | upstream `instance::entry()` iOS branch | `crates/zakuro-gpu/src/instance.rs` (`patches/0001-vulkan-on-ios.patch`) |
| 2 | `Config.hardware_renderer` switch + diagnostic FFI | `ios/zakuro-ios/src/lib.rs` (this change) |
| 3 | app embeds/links MoltenVK and builds the IPA | `ios/app/project.yml` on the build machine (or the post-packaging copy in 8.3) |
| 4 | device A/B data (software vs hardware) | local test logs |

Data flow: see 3.1.

**Expected benefit** (measure the `zk_perf` split first):

- The software PICA200 host time (`zk_perf`'s `gpu` field) covers command-list
  parsing, vertex shading (PICA shader interpretation), rasterisation, texture
  decode, TEV combining and display transfer. The hardware path hands
  pixel/texture/combine/transfer work to Metal; the CPU keeps command parsing,
  vertex shading (still on the CPU by default, see 2.1) and uploads.
- The software renderer dominates frame time on the tested title. If `gpu` is
  **50–70%** of the `run` phase, A0 has a realistic chance to cut `run` frame
  time substantially; the new cost is a **0.66 MiB/frame** GPU→CPU readback
  (400×240×4 + 320×240×4 = 691,200 B; ≈ 41 MB/s at 60 fps) plus the
  synchronisation wait, and first-use pipeline compilation.
- If `gpu` is **< 40%** of `run`, A0's upside is limited (the bottleneck is CPU
  interpretation/HLE); optimise the non-GPU part before investing further.
- The hardware path does **not** reduce vertex shading cost by default (an
  iPhone is treated as integrated GPU); `zk_set_hardware_option("gpu_shaders",
  "1")` flips it for a comparison.

**First-frame/stutter risk:** the pipeline cache is written to
`$HOME/.cache/zakuro/pipelines/<title>.bin` on the host
(`raster/hardware.rs:550`); inside the iOS app sandbox `HOME` is writable, but
the cache is empty on a first run/reinstall, so the first new draw combination
may compile SPIR-V→MSL online and stutter for a few seconds. Mitigations:
warm-up frames, move the cache path to `Library/Caches` (upstream follow-up),
or treat A0 as an experiment build.

**A0 acceptance:**

1. `zk_create` logs `zk[INFO] drawing on … through Vulkan` (MoltenVK/Metal
   device name) and no `drawing in software`.
2. `zk_perf`'s `AOT active` / `interpreted %` are unchanged (the renderer
   switch must not affect AOT).
3. `run` frame time in the same scene is ≥20% lower than the software build
   (otherwise record the data and stop).
4. The picture is correct (compare with the software build; minor driver
   differences allowed, black/garbled output is not).
5. A 20-minute soak does not crash, thermal-throttle to a crash, or grow memory.
6. Switch off: the software build behaves exactly as before (regression).

### 5.2 A1: GPU→GPU presentation (CAMetalLayer + swapchain) — implemented

**Value:** removes the 0.66 MiB/frame readback and its synchronisation, lowers
presentation latency, and gives the app a real `CAMetalLayer` for the system
Metal Performance HUD to attach to. The presenter also carries 3D stereo /
interpolation / texture-pack / overlay support, which the app does not expose
yet.

**What was implemented:**

| # | Change | Where |
|---|---|---|
| 1 | Presenter FFI: `zk_presenter_create/resize/destroy/shared_device`, `zk_create_presented`, `zk_present`, `zk_present_mode`, `zk_present_touch_map` | `ios/zakuro-ios/src/presenter.rs` |
| 2 | UIKit raw-window handle + reuse of `VulkanPresenter` and its shared device | same |
| 3 | `zk_create` body shared with `zk_create_presented` (`Config.device`, GPU renderer forced on) | `ios/zakuro-ios/src/lib.rs` |
| 4 | `MetalScreenView` (`UIView` + `CAMetalLayer`), presenter lifecycle, `zk_present` after each frame, `present` HUD phase, touch mapping | `ios/app/Sources/` |
| 5 | Header prototypes and docs | `ios/ZakuroBridge.h`, this file, `README.md` |

**Behaviour and fallbacks:**

- The presenter is made once per app run on the main queue and reused across
  loads; a size change resizes the swapchain (one out-of-date present, then
  normal).
- A presented load keeps the A0 readback path one call away: if
  `zk_presenter_create` returns `NULL` (no MoltenVK in the app, no Vulkan
  device), or `zk_create_presented` fails, the app loads with `zk_create` and
  shows `CGImage`s exactly as before. The HUD then shows the readback phases
  instead of `present`.
- With a presented system the app never calls `zk_read_screen`. If `zk_present`
  keeps failing (e.g. a broken surface), the app falls back to the readback path
  after about a second of failures instead of leaving a black picture.

**Acceptance:** no tearing/flicker; rotation and background recovery work; the
HUD's `read top`/`read bottom`/`CGImage` rows are replaced by `present` while
the layer is in use; the system Metal Performance HUD appears in the presented
build; fps not lower than A0; soak passes.

### 5.3 A2: renderer tuning (after A1)

- `Config.resolution = 2` (800×480 internally): sharper picture, more GPU load;
  decide from the HUD.
- GPU vertex shading (`zk_set_hardware_option("gpu_shaders", "1")`) versus CPU.
- Pipeline cache warm-up/sizing (`MOST_PIPELINE_BYTES = 64 MiB`).
- Texture packs / 3D stereo / interpolation (presenter features behind app UI).

## 6. Plan B: direct Metal PICA compatibility layer (not in v1)

**What it is:** a new Metal render backend inside `zakuro-gpu` (replacing or
sitting beside `raster/hardware.rs`) and a Metal presenter, without MoltenVK.
PICA200 semantics (TEV combiners, texture formats/sampling, lighting tables,
fog, proctex, depth/blend/logic ops) would be modelled on **Pocket Native's
GLES 3.1 renderer** (MIT) and Citra/Azahar's GLSL **semantics** (reference only,
no code copying).

**Two sub-routes:**

- **B1: Metal render backend** (mirror `hardware.rs`: pipeline cache, per-draw
  uniforms/push constants, vertex formats, texture format mapping, display
  transfer compute, TEV→MSL fragment). 3–6 weeks; risk of TEV/lighting/format
  regressions and maintaining two backends.
- **B2: AOT shaders** (translate PICA vertex/fragment shaders to MSL/metallib
  at build time with a 3dsrecomp-style tool; run time only binds parameters).
  Combinable with B1; 2–4 more weeks; removes run-time `naga` translation and
  first-use compilation.

**Expected benefit:** versus MoltenVK, mainly removes the Vulkan→Metal
translation overhead (draw submission CPU cost, roughly 5–20% by experience)
and the "MoltenVK is deprecated" maintenance risk; it does **not** make GPU
rendering itself much faster (both end up on Metal). Plan A already shows the
GPU path's upside; Plan B's increment is usually smaller.

**Risks:** weeks of work, TEV/texture/lighting precision regressions, two
backends, re-running the per-game compatibility matrix, and no existing iOS
Metal PICA renderer to copy (Pocket Native is GLES; nxnative/S2Arm's Metal
presentation is a reference, not a PICA renderer).

**Conclusion:** not in v1. If a later release wants "no MoltenVK + maximum
performance", do B1 then B2 and keep Plan A as the fallback. Do not write a
Metal PICA renderer from scratch now.

**Why not the GLES 3.1 route (Pocket Native engine):** OpenGL ES is deprecated
on iOS and may be removed; the Pocket Native engine is a whole ABI-7 fork, and
switching to it costs more than the MoltenVK patch. Its renderer semantics are
useful as a Plan B reference.

## 7. C ABI added by these changes

The hardware-rendering FFI (A0) and the presentation FFI (A1) are new; **no
existing `zk_*` signature changed**. `zk_create` is now a thin wrapper over the
body `zk_create_presented` also uses: the presented variant sets
`Config.device` to the presenter's Vulkan device and forces the GPU renderer on
(the screens it draws must be the ones presented). The full table is in
[README.md](README.md#c-abi); prototypes are in `ios/ZakuroBridge.h`:

```c
/* hardware rendering (A0) */
int32_t     zk_hardware_probe(void);
int32_t     zk_set_hardware_renderer(int32_t enabled);
int32_t     zk_set_vulkan_library(const char *path);
int32_t     zk_set_hardware_option(const char *name, const char *value);
const char *zk_hardware_status(zk_system_t system);

/* presentation on the app's CAMetalLayer (A1) */
zk_presenter_t zk_presenter_create(void *ui_view, uint32_t width, uint32_t height);
int32_t        zk_presenter_resize(zk_presenter_t presenter, uint32_t width, uint32_t height);
void           zk_presenter_destroy(zk_presenter_t presenter);
int32_t        zk_presenter_shared_device(zk_presenter_t presenter);
zk_system_t    zk_create_presented(const char *rom_path, const char *data_dir,
                                   zk_presenter_t presenter);
int32_t        zk_present(zk_system_t system, zk_presenter_t presenter);
int32_t        zk_present_mode(zk_system_t system, zk_presenter_t presenter);
int32_t        zk_present_touch_map(uint32_t width, uint32_t height, float x, float y,
                                    uint16_t *out_x, uint16_t *out_y);
```

**Build-time switch:** `ZAKURO_IOS_HARDWARE=1` (or `on`/`true`/`yes`) makes
`zk_create` turn hardware rendering on by default, so an A0 build needs no Swift
change. It is not needed for A1: `zk_create_presented` asks for the GPU renderer
itself, because a presented session has to draw on the device it presents from.
Do not set it for release builds; the app can call `zk_set_hardware_renderer`
from a setting instead.

The app only sees these functions once they are declared in
`ios/ZakuroBridge.h` (the Swift bridging header); the A1 functions and
`zk_hardware_status` are declared there.

## 8. Building a hardware-rendering test build (A0/A1)

### 8.1 What is verified where

Verified on the Linux development host (2026-11-12) — see appendix B:

- `cargo fmt -p zakuro-ios -- --check`;
- `cargo check -p zakuro-ios --target aarch64-apple-ios`, default and
  `--features linked`, against upstream `f54cbdb` with the patch applied;
- `cargo test -p zakuro-ios --lib` for the same two variants (1 ignored test
  needs Vulkan on the host), including the A1 presenter tests (argument
  validation, touch mapping) which need no Vulkan;
- `git apply --check` of `patches/0001-vulkan-on-ios.patch` against a pristine
  upstream checkout.

Not verified on the development host (needs the macOS build machine + a device):
`xcodebuild`, linking/embedding the MoltenVK framework, IPA signing by
Sideloadly/AltStore, and actual on-device rendering/presentation. Section 8.3
onward is the verification plan.

### 8.2 Prepare the Zakuro checkout and apply the patch

Run from the repository root, on the macOS build machine:

```bash
# 1) Clone the upstream checkout and copy this crate into it.
scripts/build-zakuro-ios.sh

# The patch was generated against upstream f54cbdb (2026-11-12); pin that
# revision if the checkout moved on since.
git -C third_party/zakuro rev-parse --short HEAD    # expect f54cbdb
# git -C third_party/zakuro fetch --depth 1 origin f54cbdb302195193688eff8dc52844b3316c4487
# git -C third_party/zakuro checkout f54cbdb302195193688eff8dc52844b3316c4487

# 2) Apply the iOS MoltenVK lookup patch (the checkout is local, gitignored).
git -C third_party/zakuro apply --check "$PWD/ios/zakuro-ios/patches/0001-vulkan-on-ios.patch"
git -C third_party/zakuro apply "$PWD/ios/zakuro-ios/patches/0001-vulkan-on-ios.patch"

# 3) Sanity: exactly one upstream file changed.
git -C third_party/zakuro diff --stat
#  crates/zakuro-gpu/src/instance.rs | 28 ++++++++++++++++++++++--
```

If the patch was already applied, step 2 fails with "patch does not apply";
`git -C third_party/zakuro diff --stat` shows it and you can skip to 8.3.

### 8.3 Build the hardware-rendering IPA (A0 and A1)

```bash
# 1) MoltenVK, downloaded (never committed; build/ is gitignored).
mkdir -p build/third_party/moltenvk
cd build/third_party/moltenvk
curl -LO https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar
shasum -a 256 MoltenVK-ios.tar
#  expected: b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1
tar xf MoltenVK-ios.tar
cd -

# 2) Linked runtime. ZAKURO_IOS_HARDWARE=1 makes the plain (non-presented) load
#    use the GPU renderer too, i.e. it is what an A0 build checks; the A1
#    presented path asks for the GPU renderer itself. build-linked-ios-lib.sh
#    refreshes third_party/zakuro/crates/zakuro-ios from this repository, then
#    builds with the title ID and the switch.
ZAKURO_IOS_HARDWARE=1 scripts/build-linked-ios-lib.sh <name> --title-id <16-hex-title-id>

# 3) Embed MoltenVK in the app and package the IPA.
scripts/build-game-ipa.sh <name> --display-name "Game name"
```

For step 3 the app must contain
`3ds2apple.app/Frameworks/MoltenVK.framework`; the app loads it by
`@executable_path` path, so there is no link-time dependency on MoltenVK and no
rpath to manage. Two ways to get it there:

**Option A (recommended): embed it with XcodeGen.** Make this build-machine-only
edit to `ios/app/project.yml` (not committed), then run step 3:

```yaml
targets:
  "3ds2apple":
    ...
    dependencies:
      - framework: ../../build/third_party/moltenvk/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework
        embed: true
```

`scripts/build-game-ipa.sh` runs `xcodegen generate` and `xcodebuild` itself, so
no other change is needed. Revert the edit afterwards (or keep it on the build
machine only).

**Option B (no project edit): inject the framework into the packaged IPA.** This
works because MoltenVK is loaded at run time by path, not linked at build time:

```bash
rm -rf /tmp/a0ipa && mkdir -p /tmp/a0ipa/Payload
unzip -q "IPA/<name>-AOT.ipa" -d /tmp/a0ipa
mkdir -p /tmp/a0ipa/Payload/3ds2apple.app/Frameworks
cp -R build/third_party/moltenvk/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework \
      /tmp/a0ipa/Payload/3ds2apple.app/Frameworks/
(cd /tmp/a0ipa && zip -qry "$OLDPWD/IPA/<name>-A0.ipa" Payload)
```

The sideload signer must re-sign the embedded framework along with the app
(Sideloadly/AltStore normally do). If the app fails to launch with a code
signature error, use Option A so Xcode builds the bundle with the framework
already embedded.

Before installing, check the build:

```bash
APP=$(ls -d ios/app/build/Release-iphoneos/*.app | head -n 1)   # or the path build-game-ipa.sh printed
nm -g "$APP/3ds2apple" | grep zk_hardware          # the new symbols are present
ls "$APP/Frameworks/MoltenVK.framework"            # dynamic Option A only
```

### 8.4 Install and read the device log

`scripts/package-ipa.sh` enables the system Metal Performance HUD
(`MetalHudEnabled`) for self-built test IPAs; it shows FPS, GPU time and memory,
which is the most direct way to see whether Metal is doing the work.

```bash
# install the unsigned IPA with Sideloadly/AltStore, then:
idevicesyslog | grep -E 'zk_create|zk_hardware|zk\[|zk_perf|drawing on|MoltenVK' | tee a0-device.log
```

Expected lines for a presented (A1) build, order not strict:

- `zk_presenter_create: CAMetalLayer presentation 1290x1548, sharing the
  renderer's Vulkan device (no screen readback)` (size depends on the device);
- `zk[INFO] presenting in mailbox mode, of …` (or `fifo`);
- `zk[INFO] drawing on Apple … through Vulkan` — the loader's line with the
  MoltenVK/Metal device name, and `, shown straight from the GPU,` when the
  renderer shares the presenter's device;
- `zk_create_presented: the screens go straight to the CAMetalLayer (no
  readback)`;
- `zk_present: presenting the screens on the CAMetalLayer, direct`;
- `zk_create: the 3D draws on the host GPU … ; the screens go straight to the
  CAMetalLayer (no readback)`;
- **no** `zk[WARN] …, drawing in software`.

A build that falls back to A0/readback logs `zk_presenter_create: could not
present on the CAMetalLayer …` (or `zk_create_presented failed`) and then the
A0 lines, ending with `screens are read back for presentation`.

Expected lines for an A0 (non-presented) build:

- `zk_hardware_probe: a Vulkan device was made` — if the app calls the probe;
- `zk[INFO] drawing on Apple … through Vulkan` — the loader's line, with the
  MoltenVK/Metal device name;
- `zk_create: the 3D draws on the host GPU through Vulkan (MoltenVK over Metal
  on iOS) at 1x; screens are read back for presentation`
- **no** `zk[WARN] …, drawing in software`.

Then record a steady-state `zk_perf` line from the second or third window:
`run`/`frame avg`, `gpu`, `non-gpu`, `read top`/`read bottom`, `cpu %`,
`interpreted %`, `draws/xfr/fills`. Repeat with the software build
(`ZAKURO_IOS_HARDWARE` unset) on the same ROM/scene and compare.

### 8.5 Failure triage

- **`zk_hardware_probe == -1`** → read `no Vulkan device: …` in
  `zk_last_error`/stderr: usually the framework is not inside the IPA
  (`ls Frameworks`, `otool -L`), the path/rpath is wrong, or re-signing broke
  the framework.
- **Probe 0 but `drawing in software`** → `vkCreateDevice` or pipeline creation
  failed; check the `zk[WARN]` line (often a `depthClamp`/extension issue).
  Fall back to software (automatic) and record the log.
- **Black or garbled picture** → record game/scene, switch back to the software
  build, keep the log. First decide whether it is an emulation difference of the
  hardware renderer or a MoltenVK driver issue before investing more.
- **`zk_presenter_create` returns NULL / the app logs `using the CGImage readback
  path`** → MoltenVK is not inside the IPA at the path the patch looks for, or no
  Vulkan device could be made. The app is still usable (A0/software); check
  `ls "$APP/Frameworks"`, `otool -L` and the `zk[WARN]` line.
- **Picture frozen while `fps` keeps counting** → `zk_present` is returning
  `1` every frame (swapchain keeps rebuilding). Check the resize log lines and
  that the view's drawable size follows the window (rotation/split view).

### 8.6 Acceptance checklist (A0/A1)

- [ ] host unit tests pass and the ignored `hardware_probe_makes_a_device`
      passes on the build machine;
- [ ] `cargo build --features linked` succeeds and the IPA contains MoltenVK;
- [ ] device log shows `drawing on … through Vulkan`, no `drawing in software`;
- [ ] device log shows `zk_presenter_create: CAMetalLayer presentation …` and
      `zk_present: presenting the screens on the CAMetalLayer, direct` for the
      presented path;
- [ ] the system Metal Performance HUD is visible over the 3D (it needs a real
      Metal layer; on the readback path it does not appear);
- [ ] HUD comparison (software vs hardware, readback vs presented):
      `run`/`gpu`/`non-gpu`/`read`/`present` recorded;
- [ ] `read top`/`read bottom`/`CGImage` rows are absent or 0 while the `present`
      row is measured, and fps is not lower than A0;
- [ ] picture correct, 20-minute soak passes, memory/thermals normal;
- [ ] background/Unload/Load-last and rotation keep working (swapchain rebuilt
      after a size change);
- [ ] fallback: build without MoltenVK still runs on the readback path;
- [ ] software build regression: with the switch off (and no presenter),
      behaviour is unchanged;
- [ ] `git status` clean (MoltenVK tar/framework/IPA are gitignored).

## 9. Risks and mitigations

| # | Risk | Likelihood/Impact | Mitigation |
|---|---|---|---|
| R1 | upstream `main` drifts; patch or APIs stop matching | medium/medium | patch touches only `instance.rs`; check out the tested revision (8.2) before patching; `git apply --check` reports a mismatch |
| R2 | the build machine's Xcode 16.4 cannot link MoltenVK 1.4.2 (built with Xcode 26.5) | medium/medium | try 1.4.2 first; fall back to 1.4.0/1.3.x (≥1.3.0) or upgrade Xcode as a build-machine decision |
| R3 | iOS rejects `depthClamp` or another device feature | low/low | loader falls back to software and logs; upstream can make depthClamp conditional (~5 lines) |
| R4 | embedded dynamic framework breaks under re-signing / wrong rpath | medium/medium | check `otool -L`; `ZAKURO_VULKAN_LIBRARY` absolute path fallback; else switch to static |
| R5 | first-run pipeline compilation stutters (empty cache) | high/low | record in QA; warm-up frames; move the cache path to `Library/Caches` (upstream follow-up) |
| R6 | hardware-render emulation differences cause wrong pictures | medium/medium | keep the software build; `zk_set_hardware_renderer(0)` at run time; record per game |
| R7 | readback cancels the win (`sync_gpu` waits on the GPU) | low/medium | measure HUD read first; A1 removes it; or lower internal resolution/fps cap |
| R8 | MoltenVK deprecation / no more updates | high (long term)/low | pin the version; Plan B in a later release; does not block v1 |
| R9 | IPA size | low/none | sideloading is not reviewed; +4.6/6.8 MiB is acceptable |
| R10 | interaction with AOT/frame loop (first-frame/long frames) | low/medium | A0 only swaps the renderer; frame-loop semantics unchanged; the free-run loop is kept |
| R11 | swapchain rebuild (rotation/resize, layer property updates) runs on the renderer's serial queue, not the main queue | medium/low | the app sets `CAMetalLayer.drawableSize` on the main queue first, then resizes the presenter on the render queue; a size change costs one out-of-date present. Device verification point: rotation and split view |
| R12 | first present before the `UIView` is in the window hierarchy (very fast load) | low/low | the load takes much longer than SwiftUI's layout pass, and the layer holds a provisional drawable size before layout; verify on device that the first frame appears |
| R13 | presenter/swapchain failure leaves a black layer | low/medium | the app counts `zk_present` failures and falls back to the CGImage readback path after about a second; the Metal view stays alive for the presenter |
| R14 | the Vulkan device/Metal layer is suspended with the app and the GPU takes it away | low/low | the frame loop and presenting stop in the background; on return the same device is used again. If the first frames after resume fail, `zk_present` errors fall back to the readback path (R13). Device verification point |

## Appendix A: upstream file index

Upstream `main` @ `f54cbdb` (2026-11-12):

| File | Content |
|---|---|
| `crates/zakuro-core/src/lib.rs:38` | `Config` (`hardware_renderer`/`device`/`resolution`/`interpolate`) |
| `crates/zakuro-core/src/lib.rs:1050`/`1094`/`1183` | `read_screen_scaled` / `gpu_screen` / `read_screen` (used by `zk_read_screen`) |
| `crates/zakuro-core/src/loader.rs:202` | loader's automatic `enable_hardware_renderer` + software fallback |
| `crates/zakuro-gpu/src/lib.rs:667`/`692`/`711`/`799` | `enable_hardware_renderer` / `draws_on_gpu` / `shows_directly` / `scale` |
| `crates/zakuro-gpu/src/device.rs:10`/`27` | `SharedDevice` / `SharedDevice::new()` |
| `crates/zakuro-gpu/src/instance.rs` | Vulkan library lookup (**the iOS gap**, patched in 8.2) |
| `crates/zakuro-gpu/src/raster/hardware.rs:550`/`1577`/`1711`/`5609`/`5619`/`5714` | pipeline cache path / `with_device` / `shades` default / `can_render` / `render_device` / `own_device` |
| `crates/zakuro-gpu/src/backend/mod.rs:12`/`356` | `ScreenImage` / `Presenter` trait |
| `crates/zakuro-gpu/src/backend/vulkan.rs:140`/`425`/`607` | `VulkanPresenter::new` / swapchain / `shared_device` |
| `crates/zakuro/src/present.rs:235` | desktop `create_vulkan` (A1 wiring reference) |
| `crates/zakuro-gpu/shaders/*.spv` | precompiled SPIR-V (`include_bytes!` at build time) |

## Appendix B: verification log

Linux development host, upstream `f54cbdb`, patch applied, 2026-11-12:

| Check | Command | Result |
|---|---|---|
| formatting | `cargo fmt -p zakuro-ios -- --check` | pass |
| iOS target, default build | `cargo check -p zakuro-ios --target aarch64-apple-ios` | pass |
| iOS target, linked | same with `--features linked` (and `ZAKURO_LINKED_PROGRAM_ID`) | pass |
| host unit tests | `cargo test -p zakuro-ios --lib` | pass, 29 passed + 1 ignored (needs Vulkan on the host) |
| host unit tests, linked | `ZAKURO_LINKED_PROGRAM_ID=<id> cargo test -p zakuro-ios --lib --features linked` | pass, 32 passed + 1 ignored |
| A1 presenter tests | part of the above (`src/presenter.rs`: NULL/zero-size argument checks, touch mapping) | pass, no Vulkan needed |
| dependency resolution | `raw-window-handle = "0.6"` resolves with the `ash-window` copy | one version in the lock file |
| header | `gcc -std=c11/c17 -Wall -Wextra -pedantic -Werror -fsyntax-only` with `ios/ZakuroBridge.h` | pass; C++17 include also compiles |
| patch applies | `git apply --check patches/0001-vulkan-on-ios.patch` on pristine upstream | pass |
| MoltenVK binary | not downloaded, not committed | repository contains text only |

Not run here: macOS links, `xcodebuild`, device tests (including the presented
path, the system Metal HUD, resize/rotation and the fallback runs).

## Appendix C: references

- MoltenVK v1.4.2 release:
  <https://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2>
- MoltenVK runtime guide (install, static/dynamic, system frameworks, minimum
  OS): `Docs/MoltenVK_Runtime_UserGuide.md` in the package
- MoltenVK supported extensions: same guide, "Supported Extensions"
- Zakuro PR #26 (MoltenVK on macOS, merged 2026-11-05):
  <https://github.com/fearkov/zakuro/pull/26>
- `ash` (`Entry::load`/`load_from`/`from_static_fn`):
  <https://docs.rs/ash/0.38.0>
- `ash-window` (iOS / `RawWindowHandle::UiKit` → `vkCreateMetalSurfaceEXT`):
  <https://github.com/ash-rs/ash>
- Similar iOS experience (not project code; reference for "a bare `dlopen`
  name does not see the app's Frameworks directory"):
  <https://github.com/ammaarreshi/Generals-Mac-iOS-iPad/blob/master/Patches/dxvk-ios.patch>
- Pocket Native (PICA→GLES semantics reference for Plan B, MIT):
  <https://github.com/whovian64/pocket-native>
- Project docs: [README.md](README.md), [docs/architecture.md](../../docs/architecture.md),
  [docs/build.md](../../docs/build.md), [scripts/AOT_BUILD.md](../../scripts/AOT_BUILD.md),
  [ios/app/README.md](../app/README.md), [THIRD_PARTY.md](../../THIRD_PARTY.md)
