//! C ABI for embedding Zakuro's 3DS runtime in an iOS app.
//!
//! This crate is copied into a Zakuro checkout as `crates/zakuro-ios` and
//! built with `cargo build -p zakuro-ios --target aarch64-apple-ios`.
//!
//! The Rust side owns `System`; Swift only sees opaque pointers. All calls
//! must happen on the same serial queue.
//!
//! ## Error reporting
//!
//! `zk_create` records a human-readable, thread-local message on failure;
//! [`zk_last_error`] returns it. A successful `zk_create` clears the message.
//! Other `zk_*` functions never touch it.

use std::cell::RefCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::ptr;

use zakuro_common::Screen;
use zakuro_core::loader;
use zakuro_core::services::hid::{InputState, PadState};
use zakuro_core::{Config, FrameOutcome, System};

thread_local! {
    /// Last `zk_create` failure on the current thread; empty when there is none.
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

/// Why a C string argument could not be converted to a path.
enum CPathError {
    /// The pointer was `NULL`.
    Null,
    /// The bytes were not valid UTF-8, so they cannot be turned into a `PathBuf`
    /// that round-trips on every platform.
    NotUtf8,
}

/// Converts a NUL-terminated C path into a `PathBuf`.
fn cpath(p: *const c_char) -> Result<PathBuf, CPathError> {
    if p.is_null() {
        return Err(CPathError::Null);
    }
    // SAFETY: the FFI contract requires a non-NULL `rom` / `data_dir` argument to
    // be a NUL-terminated string that stays valid for the duration of this call.
    // `CStr::from_ptr` reads only up to the first NUL and does not retain `p`.
    let bytes = unsafe { CStr::from_ptr(p) };
    bytes
        .to_str()
        .map(PathBuf::from)
        .map_err(|_| CPathError::NotUtf8)
}

/// Records `message` as the calling thread's last error.
fn set_last_error(message: impl Into<String>) {
    // Escape interior NULs first so `CString::new` cannot fail: the FFI path must
    // not panic. `unwrap_or_default` is then only a belt-and-braces fallback.
    let message: String = message.into();
    let message = message.replace('\0', "\\0");
    let message = CString::new(message).unwrap_or_default();
    // `try_with`: the TLS slot may already be destroyed during thread teardown.
    let _ = LAST_ERROR.try_with(|slot| *slot.borrow_mut() = message);
}

/// Marks the calling thread as having no pending error.
fn clear_last_error() {
    let _ = LAST_ERROR.try_with(|slot| *slot.borrow_mut() = CString::default());
}

/// Returns the last `zk_create` failure on the calling thread, or `NULL` when
/// there is no pending error.
///
/// The returned pointer is owned by this library and remains valid until the
/// next `zk_create` or `zk_last_error` call **on the same thread**. Copy the text
/// (for example `String(cString:)` in Swift) if it must outlive that; never free
/// it. A failure recorded on a background queue can only be read back on that
/// same thread.
#[no_mangle]
pub extern "C" fn zk_last_error() -> *const c_char {
    match LAST_ERROR.try_with(|slot| {
        let slot = slot.borrow();
        if slot.as_bytes().is_empty() {
            ptr::null()
        } else {
            slot.as_ptr()
        }
    }) {
        Ok(pointer) => pointer,
        // TLS is gone during teardown; report "no error" instead of panicking.
        Err(_) => ptr::null(),
    }
}

/// Loads a decrypted `.3ds` / `.cci` and returns an opaque `System*`.
///
/// Returns `NULL` on failure; read [`zk_last_error`] on the same thread for the
/// reason. On success the thread's last error is cleared.
#[no_mangle]
pub extern "C" fn zk_create(rom: *const c_char, data_dir: *const c_char) -> *mut c_void {
    let rom = match cpath(rom) {
        Ok(rom) => rom,
        Err(CPathError::Null) => {
            set_last_error("zk_create: rom path is NULL");
            return ptr::null_mut();
        }
        Err(CPathError::NotUtf8) => {
            set_last_error("zk_create: rom path is not valid UTF-8");
            return ptr::null_mut();
        }
    };

    // `data_dir` is optional: `NULL` means "use Zakuro's default data directory".
    let data_dir = match cpath(data_dir) {
        Ok(path) => Some(path),
        Err(CPathError::Null) => None,
        Err(CPathError::NotUtf8) => {
            set_last_error("zk_create: data_dir path is not valid UTF-8");
            return ptr::null_mut();
        }
    };

    let mut config = Config::default();
    config.data_dir = data_dir;
    config.hardware_renderer = false;
    config.texture_packs = false;
    // iOS forbids executable memory: no JIT, no recompiled-code discovery here.
    config.find_recompiled = false;

    match loader::load(&rom, config) {
        Ok(system) => {
            clear_last_error();
            Box::into_raw(Box::new(system)) as *mut c_void
        }
        Err(error) => {
            let message = format!("zk_create: failed to load {}: {error}", rom.display());
            eprintln!("{message}");
            set_last_error(message);
            ptr::null_mut()
        }
    }
}

/// Runs one frame. 0 = completed, 1 = exited, -1 = faulted, -2 = bad handle.
#[no_mangle]
pub extern "C" fn zk_run_frame(system: *mut c_void) -> i32 {
    if system.is_null() {
        return -2;
    }
    // SAFETY: `system` is a live pointer returned by `zk_create` (a leaked
    // `Box<System>`). The C ABI requires serial calls, so no other `&mut` to the
    // same `System` exists; only `zk_destroy` frees it.
    let system = unsafe { &mut *(system as *mut System) };
    match system.run_frame() {
        FrameOutcome::Completed => 0,
        FrameOutcome::Exited => 1,
        FrameOutcome::Faulted => -1,
    }
}

#[no_mangle]
pub extern "C" fn zk_screen_width(which: u32) -> u32 {
    if which == 0 {
        400
    } else {
        320
    }
}

#[no_mangle]
pub extern "C" fn zk_screen_height(_which: u32) -> u32 {
    240
}

/// Copies RGBA8 pixels into `out`. Returns the full byte length (which may
/// exceed `capacity`; then the copy was truncated).
#[no_mangle]
pub extern "C" fn zk_read_screen(
    system: *mut c_void,
    which: u32,
    out: *mut u8,
    capacity: usize,
) -> usize {
    if system.is_null() || out.is_null() {
        return 0;
    }
    // SAFETY: see `zk_run_frame`: serial calls guarantee exclusive access to the
    // `System` behind `system`.
    let system = unsafe { &mut *(system as *mut System) };
    let screen = if which == 0 { Screen::Top } else { Screen::Bottom };
    let pixels = system.read_screen(screen);
    let n = pixels.len().min(capacity);
    // SAFETY: `out` is non-NULL and the caller guarantees `capacity` writable
    // bytes; `n <= capacity`. The source buffer is owned by the `System`, so it
    // cannot overlap the caller's `out` buffer.
    unsafe { ptr::copy_nonoverlapping(pixels.as_ptr(), out, n) };
    pixels.len()
}

/// Copies interleaved stereo i16 samples into `out`. Returns frames written.
#[no_mangle]
pub extern "C" fn zk_take_audio(
    system: *mut c_void,
    out: *mut i16,
    capacity: usize,
) -> usize {
    if system.is_null() || out.is_null() {
        return 0;
    }
    // SAFETY: see `zk_run_frame`: serial calls guarantee exclusive access to the
    // `System` behind `system`.
    let system = unsafe { &mut *(system as *mut System) };
    let samples = system.take_audio();
    let frames = samples.len().min(capacity / 2);
    // SAFETY: `out` is non-NULL and the caller guarantees space for `capacity`
    // `i16` values. `frames <= capacity / 2`, so the largest index written,
    // `2 * frames - 1`, is smaller than `capacity`.
    for (i, [l, r]) in samples.iter().take(frames).enumerate() {
        unsafe {
            *out.add(i * 2) = *l;
            *out.add(i * 2 + 1) = *r;
        }
    }
    frames
}

/// Buttons use the 3DS HID bit layout (PadState). `touch` is 0/1; coordinates
/// are in bottom-screen pixels.
#[no_mangle]
pub extern "C" fn zk_set_input(
    system: *mut c_void,
    buttons: u32,
    circle_x: f32,
    circle_y: f32,
    touch: i32,
    touch_x: u16,
    touch_y: u16,
) {
    if system.is_null() {
        return;
    }
    // SAFETY: see `zk_run_frame`: serial calls guarantee exclusive access to the
    // `System` behind `system`.
    let system = unsafe { &mut *(system as *mut System) };
    system.set_input(InputState {
        buttons: PadState::from_bits_truncate(buttons),
        circle_x,
        circle_y,
        c_stick_x: 0.0,
        c_stick_y: 0.0,
        touch: if touch != 0 {
            Some((touch_x, touch_y))
        } else {
            None
        },
        tilt: [0.0, 0.0],
    });
}

#[no_mangle]
pub extern "C" fn zk_destroy(system: *mut c_void) {
    if !system.is_null() {
        // SAFETY: `system` is a pointer produced by `zk_create` (a `Box<System>`
        // leaked through `Box::into_raw`) and is freed exactly once here. The C
        // ABI requires the caller to stop using the handle afterwards.
        unsafe { drop(Box::from_raw(system as *mut System)) };
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::{c_char, CStr};
    use std::ptr;

    use super::{clear_last_error, set_last_error, zk_create, zk_last_error};

    /// Copies the current thread's last error, if any.
    fn last_error_text() -> Option<String> {
        let pointer = zk_last_error();
        if pointer.is_null() {
            return None;
        }
        // SAFETY: the pointer comes from `zk_last_error` and stays valid until
        // the next `zk_create` / `zk_last_error` call on this thread; it is read
        // immediately here.
        Some(unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned())
    }

    #[test]
    fn no_error_by_default() {
        clear_last_error();
        assert!(zk_last_error().is_null());
        assert_eq!(last_error_text(), None);
    }

    #[test]
    fn error_round_trips() {
        set_last_error("boom");
        assert_eq!(last_error_text().as_deref(), Some("boom"));
        clear_last_error();
        assert!(zk_last_error().is_null());
    }

    #[test]
    fn interior_nul_is_escaped() {
        set_last_error("bad\0message");
        assert_eq!(last_error_text().as_deref(), Some("bad\\0message"));
    }

    #[test]
    fn null_rom_is_reported() {
        clear_last_error();
        let system = zk_create(ptr::null(), ptr::null());
        assert!(system.is_null());
        let message = last_error_text().expect("null rom must set an error");
        assert!(message.contains("rom path is NULL"), "unexpected: {message}");
    }

    #[test]
    fn non_utf8_rom_path_is_reported() {
        clear_last_error();
        let rom = b"bad\xFFpath\0";
        // SAFETY: `rom` is a NUL-terminated buffer that outlives this call.
        let system = zk_create(rom.as_ptr() as *const c_char, ptr::null());
        assert!(system.is_null());
        let message = last_error_text().expect("invalid UTF-8 must set an error");
        assert!(message.contains("not valid UTF-8"), "unexpected: {message}");
    }

    #[test]
    fn error_state_is_per_thread() {
        set_last_error("main thread");
        let worker = std::thread::spawn(|| {
            // A fresh thread starts without an error, then keeps its own message.
            assert!(zk_last_error().is_null());
            set_last_error("worker thread");
            last_error_text()
        })
        .join()
        .expect("worker thread must not panic");
        assert_eq!(worker.as_deref(), Some("worker thread"));
        // The worker's write did not clobber this thread's message.
        assert_eq!(last_error_text().as_deref(), Some("main thread"));
    }
}
