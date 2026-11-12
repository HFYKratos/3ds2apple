//! C ABI for embedding Zakuro's 3DS runtime in an iOS app.
//!
//! This crate is copied into a Zakuro checkout as `crates/zakuro-ios` and
//! built with `cargo build -p zakuro-ios --target aarch64-apple-ios`.
//!
//! The Rust side owns `System`; Swift only sees opaque pointers. All calls
//! must happen on the same serial queue.

use std::ffi::{c_char, c_void, CStr};
use std::path::PathBuf;
use std::ptr;

use zakuro_common::Screen;
use zakuro_core::loader;
use zakuro_core::services::hid::{InputState, PadState};
use zakuro_core::{Config, FrameOutcome, System};

fn cpath(p: *const c_char) -> Option<PathBuf> {
    if p.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(p) }
            .to_str()
            .ok()
            .map(PathBuf::from)
    }
}

/// Loads a decrypted `.3ds` / `.cci` and returns an opaque `System*`.
/// Returns null on failure.
#[no_mangle]
pub extern "C" fn zk_create(rom: *const c_char, data_dir: *const c_char) -> *mut c_void {
    let Some(rom) = cpath(rom) else {
        return ptr::null_mut();
    };
    let mut config = Config::default();
    config.data_dir = cpath(data_dir);
    config.hardware_renderer = false;
    config.texture_packs = false;
    config.find_recompiled = false;
    match loader::load(&rom, config) {
        Ok(system) => Box::into_raw(Box::new(system)) as *mut c_void,
        Err(error) => {
            eprintln!("zk_create: {error}");
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
    let system = unsafe { &mut *(system as *mut System) };
    let screen = if which == 0 { Screen::Top } else { Screen::Bottom };
    let pixels = system.read_screen(screen);
    let n = pixels.len().min(capacity);
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
    let system = unsafe { &mut *(system as *mut System) };
    let samples = system.take_audio();
    let frames = samples.len().min(capacity / 2);
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
        unsafe { drop(Box::from_raw(system as *mut System)) };
    }
}