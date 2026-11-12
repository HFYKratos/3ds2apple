//! Presentation of the 3DS screens on the host's Metal layer (A1).
//!
//! The app owns a `UIView` whose backing layer is a `CAMetalLayer` and hands
//! its pointer to [`zk_presenter_create`]. Zakuro's Vulkan presenter wraps that
//! layer in a surface and a swapchain (through `ash-window`'s UIKit support,
//! which calls `vkCreateMetalSurfaceEXT`), and [`zk_create_presented`] loads a
//! ROM on the Vulkan device that the presenter and the renderer share. Every
//! frame the app calls [`zk_present`] with the handle returned by
//! [`zk_create_presented`]; the screens the renderer drew are then shown
//! straight from the GPU instead of being copied to the CPU.
//!
//! This is optional and one of several presentation paths:
//!
//! | path | what the app does |
//! |---|---|
//! | A1, shared device | `zk_create_presented` + `zk_present`: the renderer's images go to the swapchain, no readback |
//! | A1, renderer on the CPU | same calls, but `zk_present` uploads `zk_read_screen`-equivalent pixels through the swapchain |
//! | A0 / software | plain `zk_create` + `zk_read_screen` + `CGImage` (no presenter at all) |
//!
//! On iOS the Vulkan implementation is MoltenVK over Metal. Without a loadable
//! MoltenVK the presenter cannot be made: [`zk_presenter_create`] returns
//! `NULL` with the reason in [`zk_last_error`], and the app keeps the readback
//! path. A presented system whose renderer fell back to software still
//! presents (the "renderer on the CPU" row): that removes the CGImage step and
//! keeps a real Metal layer for the system Metal HUD, though the pixels still
//! travel through the CPU.
//!
//! Threading follows the rest of the C ABI: a presenter is not thread-safe.
//! Create, resize and destroy it on the app's main queue (the `UIView` is a
//! UIKit object), and call [`zk_present`] on the same serial queue as
//! `zk_run_frame`. The presenter must outlive every presented system that uses
//! its device; release the systems first.

use std::ffi::c_void;
use std::ptr::{self, NonNull};
use std::sync::Arc;

use raw_window_handle::{
    DisplayHandle, HandleError, HasDisplayHandle, HasWindowHandle, RawWindowHandle,
    UiKitWindowHandle, WindowHandle,
};
use zakuro_common::Screen;
use zakuro_core::System;
use zakuro_gpu::backend::vulkan::VulkanPresenter;
use zakuro_gpu::backend::TOP_WIDTH;
use zakuro_gpu::{
    layout, Overlay, PresentError, Presenter, ScreenImage, ScreenLayout, ScreenOrientation,
};

use crate::{perf, set_last_error};

/// A `UIView*` the app handed over, as the raw-window-handle pair
/// `ash-window` needs to make a `VkSurface` from its `CAMetalLayer`.
struct UiKitView {
    view: NonNull<c_void>,
}

impl HasDisplayHandle for UiKitView {
    fn display_handle(&self) -> Result<DisplayHandle<'_>, HandleError> {
        // iOS has no display connection object: the display handle is empty and
        // the view's layer carries everything the surface needs.
        Ok(DisplayHandle::uikit())
    }
}

impl HasWindowHandle for UiKitView {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        // SAFETY: the app keeps the `UIView` alive for as long as the
        // presenter exists and hands over a live pointer; the raw handle is
        // only borrowed for the duration of the `VulkanPresenter::new` call.
        let raw = RawWindowHandle::UiKit(UiKitWindowHandle::new(self.view));
        unsafe { Ok(WindowHandle::borrow_raw(raw)) }
    }
}

/// What a presentation backend does with a frame.
#[derive(Clone, Copy, PartialEq, Eq)]
enum BackendMode {
    /// no presenter: the app reads the screens back (A0/software path)
    Readback,
    /// the renderer's GPU images go straight to the swapchain
    Direct,
    /// the renderer draws in software; its pixels are uploaded through the
    /// swapchain instead of being turned into a `CGImage`
    Uploaded,
}

impl BackendMode {
    fn label(self) -> &'static str {
        match self {
            BackendMode::Readback => "readback",
            BackendMode::Direct => "direct",
            BackendMode::Uploaded => "uploaded",
        }
    }
}

/// The opaque handle Swift holds: one Vulkan presenter and the layer size its
/// swapchain is for.
pub struct PresenterHandle {
    presenter: VulkanPresenter,
    /// Drawable size in pixels, as the app last reported it.
    size: (u32, u32),
    /// Whether the first presented frame already logged which path it took.
    logged_mode: bool,
}

/// What presenting a frame of `system` through a presenter will do: the
/// renderer's images straight to the swapchain, or CPU pixels uploaded through
/// it. `presented` is false for a `zk_create` system, which has no presenter and
/// is read back for `CGImage` display.
fn presentation_mode(system: &System, presented: bool) -> BackendMode {
    if !presented {
        return BackendMode::Readback;
    }
    if system.gpu.shows_directly() {
        BackendMode::Direct
    } else {
        BackendMode::Uploaded
    }
}

/// One screen's pixels for the presenter: either the renderer's GPU image or a
/// CPU buffer that the presenter uploads. Keeps whichever buffer alive for the
/// duration of the present call.
enum PresentScreen {
    Gpu {
        image: zakuro_gpu::GpuScreen,
        width: u32,
        height: u32,
    },
    Cpu {
        /// `(pixels, width, height)` as `read_screen_scaled` returns it.
        screen: zakuro_core::Screen,
    },
}

impl PresentScreen {
    fn image(&self) -> ScreenImage<'_> {
        match self {
            PresentScreen::Gpu {
                image,
                width,
                height,
            } => ScreenImage {
                width: *width,
                height: *height,
                pixels: &[],
                gpu: Some(*image),
            },
            PresentScreen::Cpu { screen } => ScreenImage {
                width: screen.1,
                height: screen.2,
                pixels: &screen.0,
                gpu: None,
            },
        }
    }
}

/// Reads a screen for the presenter. With a shared device and the hardware
/// renderer on, that is the image on the GPU; otherwise it is the console's
/// pixels (read back by Zakuro's own helpers, exactly as `zk_read_screen`
/// would) that the presenter uploads. Must run on the serial queue.
fn present_screen(system: &mut System, screen: Screen) -> PresentScreen {
    if let Some(image) = system.gpu_screen(screen) {
        let scale = system.gpu.scale();
        return PresentScreen::Gpu {
            image,
            width: screen.width() * scale,
            height: screen.height() * scale,
        };
    }
    PresentScreen::Cpu {
        screen: system.read_screen_scaled(screen),
    }
}

/// Creates a presenter for the app's `UIView` and the `CAMetalLayer` it backs.
///
/// `ui_view` is an `Unmanaged.passUnretained(view).toOpaque()` pointer to a
/// `UIView` whose `layerClass` is `CAMetalLayer` (or whose layer already is
/// one); `width` and `height` are the drawable size in pixels. Call on the
/// main queue, before [`zk_create_presented`].
///
/// Returns an opaque handle, or `NULL` when a Vulkan device/surface/swapchain
/// cannot be made (no MoltenVK in the app, an unsupported GPU, a zero size,
/// ...). The reason is in [`crate::zk_last_error`] on the calling thread and in
/// the log. The app is expected to fall back to `zk_create` + `zk_read_screen`
/// when this returns `NULL`.
///
/// The view must stay alive until [`zk_presenter_destroy`].
///
/// # Safety
///
/// `ui_view` must be `NULL` or a pointer to a live `UIView` that stays alive
/// until the presenter is destroyed. The returned pointer must be freed with
/// [`zk_presenter_destroy`] and not used afterwards; never free it with
/// `free()`.
#[no_mangle]
pub extern "C" fn zk_presenter_create(
    ui_view: *mut c_void,
    width: u32,
    height: u32,
) -> *mut c_void {
    let Some(view) = NonNull::new(ui_view) else {
        set_last_error("zk_presenter_create: ui_view is NULL");
        return ptr::null_mut();
    };
    // A zero-sized layer cannot back a swapchain. The app reports the size it
    // laid the view out at and resizes when that changes; a zero here is a
    // caller bug worth an error rather than a silently broken presenter.
    if width == 0 || height == 0 {
        set_last_error(format!(
            "zk_presenter_create: drawable size is {width}x{height}; the layer needs a size"
        ));
        return ptr::null_mut();
    }

    perf::install_logger();
    match VulkanPresenter::new(&UiKitView { view }, (width, height)) {
        Ok(presenter) => {
            let shared = presenter.shared_device();
            eprintln!(
                "zk_presenter_create: CAMetalLayer presentation {}x{}, {}{}",
                width,
                height,
                if shared.is_some() {
                    "sharing the renderer's Vulkan device (no screen readback)"
                } else {
                    "presenter owns its Vulkan device (screens will be uploaded)"
                },
                if presenter.waits_for_display() {
                    ", presents wait for the display (FIFO)"
                } else {
                    ""
                }
            );
            Box::into_raw(Box::new(PresenterHandle {
                presenter,
                size: (width, height),
                logged_mode: false,
            })) as *mut c_void
        }
        Err(error) => {
            let message = format!(
                "zk_presenter_create: could not present on the CAMetalLayer (is MoltenVK in \
                 the app?): {error}"
            );
            eprintln!("{message}");
            set_last_error(message);
            ptr::null_mut()
        }
    }
}

/// Resizes the presenter's swapchain to a new drawable size in pixels.
///
/// Call it from the main queue when the app's view is laid out again (rotation,
/// split view, a new screen). The swapchain is rebuilt on the next
/// [`zk_present`]; that call reports `1` (out of date) once, and the frame
/// after it presents normally. Returns 0, or -1 for a `NULL` presenter or a
/// zero size.
#[no_mangle]
pub extern "C" fn zk_presenter_resize(presenter: *mut c_void, width: u32, height: u32) -> i32 {
    let Some(presenter) = (unsafe { (presenter as *mut PresenterHandle).as_mut() }) else {
        return -1;
    };
    if width == 0 || height == 0 {
        return -1;
    }
    if presenter.size == (width, height) {
        return 0;
    }
    presenter.size = (width, height);
    presenter.presenter.resize(width, height);
    eprintln!("zk_presenter_resize: CAMetalLayer drawable now {width}x{height}");
    0
}

/// Releases a presenter returned by [`zk_presenter_create`].
///
/// Release the systems loaded with [`zk_create_presented`] first (or at least
/// stop using them): their renderer holds the device the presenter shares and
/// their screens live in its images. `NULL` is a no-op.
///
/// # Safety
///
/// `presenter` must be `NULL` or a pointer returned by [`zk_presenter_create`]
/// that has not been destroyed yet.
#[no_mangle]
pub extern "C" fn zk_presenter_destroy(presenter: *mut c_void) {
    if presenter.is_null() {
        return;
    }
    // SAFETY: the pointer came from `Box::into_raw` in `zk_presenter_create`
    // and is freed exactly once here; the ABI requires the caller to stop using
    // it afterwards.
    drop(unsafe { Box::from_raw(presenter as *mut PresenterHandle) });
    eprintln!("zk_presenter_destroy: CAMetalLayer presentation released");
}

/// 1 when the presenter made a Vulkan device it can share with the renderer
/// (so the screens can be shown straight from the GPU), 0 when it owns a plain
/// device and screens will be uploaded, -1 for a `NULL` presenter.
#[no_mangle]
pub extern "C" fn zk_presenter_shared_device(presenter: *mut c_void) -> i32 {
    // SAFETY: `presenter` is NULL or a live handle on the caller's serial queue;
    // only read here.
    let Some(presenter) = (unsafe { (presenter as *mut PresenterHandle).as_ref() }) else {
        return -1;
    };
    if presenter.presenter.shared_device().is_some() {
        1
    } else {
        0
    }
}

/// Loads a decrypted ROM with presentation on the Swift app's `CAMetalLayer`.
///
/// Same as [`crate::zk_create`], but the 3D is drawn on the Vulkan device that
/// belongs to `presenter` (the GPU renderer is requested even when the
/// build-time `ZAKURO_IOS_HARDWARE` switch is off), so the screens the
/// renderer draws are shown straight from the GPU by [`zk_present`]. When the
/// renderer cannot start on that device the loader falls back to software and
/// [`zk_present`] uploads the pixels through the same layer instead; the app
/// then never needs `zk_read_screen`.
///
/// Returns `NULL` on failure with the reason in [`crate::zk_last_error`]. The
/// app should then fall back to `zk_create` (the readback path). The system must
/// be destroyed with `zk_destroy` and the presenter with
/// [`zk_presenter_destroy`] before the view goes away; see the module notes for
/// the order.
///
/// # Safety
///
/// `rom_path` and `data_dir` follow [`crate::zk_create`]'s contract;
/// `presenter` must be `NULL` or a live handle from [`zk_presenter_create`].
#[no_mangle]
pub extern "C" fn zk_create_presented(
    rom_path: *const std::ffi::c_char,
    data_dir: *const std::ffi::c_char,
    presenter: *mut c_void,
) -> *mut c_void {
    let Some(presenter) = (unsafe { (presenter as *mut PresenterHandle).as_ref() }) else {
        set_last_error(
            "zk_create_presented: presenter is NULL; use zk_create for the readback path",
        );
        return ptr::null_mut();
    };
    // The renderer draws on the presenter's device when it can share it with
    // the swapchain. `None` (the presenter could not make a shareable device)
    // still presents: the renderer makes its own device, the screens are read
    // back and uploaded, and the app's display path is unchanged.
    let device: Option<Arc<zakuro_gpu::SharedDevice>> = presenter.presenter.shared_device();
    crate::create_system(rom_path, data_dir, device, true)
}

/// Presents the frame that [`crate::zk_run_frame`] just drew on the presenter's
/// `CAMetalLayer`.
///
/// With a system from [`zk_create_presented`] this is the app's whole display
/// path: the upper (3D) and lower (2D) screens are shown stacked the way the
/// console is, with no `zk_read_screen` and no `CGImage`. Call it on the same
/// serial queue as `zk_run_frame`, once per completed frame.
///
/// Returns 0 when the frame was handed to the display, 1 when the swapchain is
/// out of date and was rebuilt (just continue; the next frame presents
/// normally), -1 for a `NULL`/unusable system or presenter, and -2 when
/// presenting failed (the reason goes to the log and [`crate::zk_last_error`];
/// the app can keep trying or fall back to the readback path).
///
/// # Safety
///
/// `system` must be `NULL` or a live handle from `zk_create`/
/// [`zk_create_presented`]; `presenter` must be `NULL` or a live handle from
/// [`zk_presenter_create`]. No other call may use either handle at the same
/// time.
#[no_mangle]
pub extern "C" fn zk_present(system: *mut c_void, presenter: *mut c_void) -> i32 {
    let Some(system) = (unsafe { (system as *mut System).as_mut() }) else {
        return -1;
    };
    let Some(presenter) = (unsafe { (presenter as *mut PresenterHandle).as_mut() }) else {
        return -1;
    };

    let top = present_screen(system, Screen::Top);
    let bottom = present_screen(system, Screen::Bottom);
    // The app shows no 3D yet; an empty right eye is what the presenter expects
    // from a title that draws in 2D.
    let right = ScreenImage {
        width: 0,
        height: 0,
        pixels: &[],
        gpu: None,
    };
    let overlay = Overlay::default();

    if !presenter.logged_mode {
        presenter.logged_mode = true;
        eprintln!(
            "zk_present: presenting the screens on the CAMetalLayer, {}",
            presentation_mode(system, true).label()
        );
    }

    match presenter
        .presenter
        .present(top.image(), bottom.image(), right, &overlay)
    {
        Ok(()) => 0,
        Err(PresentError::OutOfDate) => 1,
        Err(error) => {
            let message = format!("zk_present: presenting failed: {error}");
            eprintln!("{message}");
            set_last_error(message);
            -2
        }
    }
}

/// How a loaded system puts its screens on the display, for the app's status
/// line and logs:
///
/// - `0`: no presenter (`zk_create`): the app reads the screens back and shows
///   them as `CGImage`;
/// - `1`: the presenter shows the renderer's GPU images directly (no readback);
/// - `2`: the presenter uploads CPU pixels (the renderer is software, or the
///   device is not shared); the display path is still the Metal layer, not
///   `CGImage`.
///
/// Pass the presenter the system was loaded with (the one given to
/// [`zk_create_presented`]), or `NULL` when it was loaded with `zk_create`.
/// Returns 0 for a `NULL` system or `NULL` presenter.
#[no_mangle]
pub extern "C" fn zk_present_mode(system: *mut c_void, presenter: *mut c_void) -> i32 {
    // SAFETY: `system` is NULL or a live handle on the caller's serial queue;
    // only read here.
    let Some(system) = (unsafe { (system as *mut System).as_ref() }) else {
        return 0;
    };
    match presentation_mode(system, !presenter.is_null()) {
        BackendMode::Readback => 0,
        BackendMode::Direct => 1,
        BackendMode::Uploaded => 2,
    }
}

/// Maps a touch in the presented Metal view to lower-screen pixels.
///
/// `width` and `height` are the drawable size in pixels that the presenter was
/// created/last resized for; `x` and `y` are the touch position normalised to
/// `0.0 ... 1.0` from the view's top-left, so the caller does not have to care
/// about points versus pixels. The same layout the presenter uses (upper screen
/// above lower screen, in the console's 400x480 shape) decides whether the point
/// is on the lower screen.
///
/// Returns 1 and writes the lower-screen pixel coordinates (`0...320`,
/// `0...240`) to `out_x`/`out_y` when the point is on the lower screen, 0 when
/// it is not (the touch releases) or an argument is missing.
///
/// # Safety
///
/// `out_x` and `out_y` must be `NULL` or point to writable `uint16_t`s; they
/// are only written when the function returns 1.
#[no_mangle]
pub extern "C" fn zk_present_touch_map(
    width: u32,
    height: u32,
    x: f32,
    y: f32,
    out_x: *mut u16,
    out_y: *mut u16,
) -> i32 {
    if width == 0 || height == 0 || out_x.is_null() || out_y.is_null() {
        return 0;
    }
    let (_, bottom) = layout(
        width,
        height,
        ScreenLayout::Stacked,
        ScreenOrientation::North,
        TOP_WIDTH,
        false,
    );
    let Some(viewport) = bottom else {
        return 0;
    };
    if viewport.width <= 0.0 || viewport.height <= 0.0 {
        return 0;
    }
    let pixel_x = x * width as f32;
    let pixel_y = y * height as f32;
    let u = (pixel_x - viewport.x) / viewport.width;
    let v = (pixel_y - viewport.y) / viewport.height;
    if !(0.0..=1.0).contains(&u) || !(0.0..=1.0).contains(&v) {
        return 0;
    }
    // The 3DS touch panel reports pixels within 320x240; round like a finger
    // landing between pixels and keep the last row/column addressable.
    let touch_x = (u * 320.0).round().clamp(0.0, 320.0) as u16;
    let touch_y = (v * 240.0).round().clamp(0.0, 240.0) as u16;
    // SAFETY: the pointers were checked non-NULL and the caller guarantees they
    // are writable.
    unsafe {
        *out_x = touch_x;
        *out_y = touch_y;
    }
    1
}

#[cfg(test)]
mod tests {
    use std::ffi::c_void;
    use std::ptr;

    use super::{
        zk_create_presented, zk_present, zk_present_mode, zk_present_touch_map,
        zk_presenter_create, zk_presenter_destroy, zk_presenter_resize, zk_presenter_shared_device,
    };

    /// Copies the calling thread's last error, if any.
    fn last_error_text() -> Option<String> {
        let pointer = crate::zk_last_error();
        if pointer.is_null() {
            return None;
        }
        // SAFETY: the pointer comes from `zk_last_error` and stays valid until
        // the next `zk_create`/`zk_last_error` call on this thread; read now.
        Some(
            unsafe { std::ffi::CStr::from_ptr(pointer) }
                .to_string_lossy()
                .into_owned(),
        )
    }

    /// A non-NULL pointer that is never dereferenced: the presenter creation
    /// checks the arguments before it touches the view.
    fn dangling_view() -> *mut c_void {
        ptr::NonNull::<c_void>::dangling().as_ptr()
    }

    #[test]
    fn null_view_is_reported() {
        crate::clear_last_error();
        assert!(zk_presenter_create(ptr::null_mut(), 400, 480).is_null());
        let message = last_error_text().expect("a NULL view must set an error");
        assert!(message.contains("ui_view is NULL"), "unexpected: {message}");
    }

    #[test]
    fn zero_size_is_reported() {
        crate::clear_last_error();
        assert!(zk_presenter_create(dangling_view(), 0, 480).is_null());
        let message = last_error_text().expect("a zero size must set an error");
        assert!(
            message.contains("drawable size is 0x480"),
            "unexpected: {message}"
        );
    }

    #[test]
    fn presenter_calls_need_a_presenter() {
        assert_eq!(zk_presenter_resize(ptr::null_mut(), 400, 480), -1);
        assert_eq!(zk_presenter_shared_device(ptr::null_mut()), -1);
        // Destroying NULL is a no-op, not a fault.
        zk_presenter_destroy(ptr::null_mut());
    }

    #[test]
    fn presented_create_needs_a_presenter() {
        crate::clear_last_error();
        let system = zk_create_presented(ptr::null(), ptr::null(), ptr::null_mut());
        assert!(system.is_null());
        let message = last_error_text().expect("a NULL presenter must set an error");
        assert!(
            message.contains("presenter is NULL"),
            "unexpected: {message}"
        );
    }

    #[test]
    fn present_needs_both_handles() {
        assert_eq!(zk_present(ptr::null_mut(), ptr::null_mut()), -1);
        // A NULL system is rejected before the presenter is touched.
        assert_eq!(zk_present(ptr::null_mut(), dangling_view()), -1);
    }

    #[test]
    fn null_system_presents_as_readback() {
        assert_eq!(zk_present_mode(ptr::null_mut(), ptr::null_mut()), 0);
        assert_eq!(zk_present_mode(ptr::null_mut(), dangling_view()), 0);
    }

    #[test]
    fn present_mode_follows_the_presenter() {
        // A System with no ROM and no hardware renderer is enough to exercise
        // the readback/uploaded distinction: it never presents.
        let mut system = Box::new(zakuro_core::System::new(zakuro_core::Config::default()));
        let handle = &mut *system as *mut zakuro_core::System as *mut c_void;
        // No presenter: the pre-A1 readback path.
        assert_eq!(zk_present_mode(handle, ptr::null_mut()), 0);
        // A presenter is attached, but this system has no GPU renderer, so its
        // pixels would be uploaded through the Metal layer.
        assert_eq!(zk_present_mode(handle, dangling_view()), 2);
    }

    #[test]
    fn touch_map_lands_on_the_lower_screen() {
        let mut x = 0u16;
        let mut y = 0u16;

        // 400x480 is the console's own layout: the lower screen is 320x240,
        // centred under the upper one (a 40 pixel margin each side).
        assert_eq!(zk_present_touch_map(400, 480, 0.5, 0.75, &mut x, &mut y), 1);
        assert_eq!((x, y), (160, 120), "the centre of the lower screen");

        // The upper screen is not a touch surface.
        assert_eq!(zk_present_touch_map(400, 480, 0.5, 0.25, &mut x, &mut y), 0);
        // Nor is the console's side margin beside the lower screen.
        assert_eq!(
            zk_present_touch_map(400, 480, 0.05, 0.75, &mut x, &mut y),
            0
        );

        // Its top-left corner is the lower screen's (0, 0); the bottom-right
        // edge rounds to the last addressable pixel.
        assert_eq!(zk_present_touch_map(400, 480, 0.1, 0.5, &mut x, &mut y), 1);
        assert_eq!((x, y), (0, 0));
        assert_eq!(zk_present_touch_map(400, 480, 0.9, 1.0, &mut x, &mut y), 1);
        assert_eq!((x, y), (320, 240));

        // Missing outputs just fail instead of writing.
        assert_eq!(
            zk_present_touch_map(400, 480, 0.5, 0.75, ptr::null_mut(), &mut y),
            0
        );
        assert_eq!(
            zk_present_touch_map(400, 480, 0.5, 0.75, &mut x, ptr::null_mut()),
            0
        );
        // A zero drawable size has no layout to map.
        assert_eq!(zk_present_touch_map(0, 0, 0.5, 0.75, &mut x, &mut y), 0);
    }

    #[test]
    fn touch_map_keeps_the_normalised_position_across_sizes() {
        let mut x = 0u16;
        let mut y = 0u16;
        // Twice the pixels, same shape: the same normalised point maps to the
        // same console pixel.
        assert_eq!(zk_present_touch_map(800, 960, 0.5, 0.75, &mut x, &mut y), 1);
        assert_eq!((x, y), (160, 120));
        // A wider window letterboxes; the lower screen keeps its place in the
        // middle, so the same normalised x no longer hits its centre.
        assert_eq!(zk_present_touch_map(800, 480, 0.5, 0.75, &mut x, &mut y), 1);
        assert_eq!((x, y), (160, 120));
    }
}
