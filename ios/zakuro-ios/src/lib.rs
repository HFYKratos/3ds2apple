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
//! `zk_create`, the saved-state calls in [`savestate`] and the hardware and
//! presenter calls record a human-readable, thread-local message on failure;
//! [`zk_last_error`] returns it. A successful `zk_create`, state measurement,
//! state copy or state load clears the message. Calls that only read
//! diagnostics never touch it.
//!
//! ## Linked game code
//!
//! A build with `--features linked` carries one title's 3dsrecomp-generated
//! tables, which the app links in as a static archive beside this library, and
//! [`zk_create`] hands them to Zakuro so the game runs as AOT C instead of in
//! the interpreter. The default build is the interpreter-only shell and links
//! nothing extra. `scripts/AOT_BUILD.md` in this directory has the build and
//! version-matching rules; [`zk_linked_code`], [`zk_linked_program_id`] and
//! [`zk_recompiled`] report what a build and a loaded system ended up using,
//! and [`zk_recompiled_status`] explains a fallback.
//!
//! The interpreter-only shell can also take one game's AOT code at run time:
//! the AOT-first build ships a per-game GamePack dylib in the app bundle, the
//! shell dlopen()s it and the pack registers its tables with
//! [`gamepack::zk_register_gamepack`], which [`zk_create`] then runs through
//! the same `Config.linked` path. GamePack C ABI v1 is declared in
//! `ios/zakuro-ios/include/zakuro_gamepack.h`; the statically linked
//! single-game flow above is unchanged and keeps precedence when present.
//!
//! ## Performance diagnostics
//!
//! [`zk_last_frame_micros`], [`zk_last_screen_read_micros`] and
//! [`zk_last_audio_take_micros`] time the frame loop's FFI calls, and every
//! [`perf::DEFAULT_LOG_INTERVAL`] frames the library prints a `zk_perf` line to
//! stderr (visible in `idevicesyslog` without any Swift change) that splits
//! frame time into emulated CPU, software GPU, screen read and audio. The
//! optional `profiling` feature adds guest-PC hot spots to that line, and
//! [`zk_profiler_start`] / [`zk_profiler_hot_spots`] let the app ask directly.
//! `ios/zakuro-ios/README.md` has the measurement method and how to read the numbers.
//!
//! ## Hardware rendering
//!
//! The 3D is drawn by Zakuro's software PICA200 unless the app asks for the
//! host GPU, which on iOS is Metal through MoltenVK: [`zk_set_hardware_renderer`]
//! turns it on for the systems [`zk_create`] makes afterwards, and a library
//! built with `ZAKURO_IOS_HARDWARE=1` has it on by default (the spike switch,
//! so a device test needs no Swift change). A system whose Vulkan device fails
//! to start falls back to software by itself and logs why.
//!
//! [`zk_hardware_probe`] says whether a Vulkan device can be made at all,
//! [`zk_hardware_status`] says what a loaded system ended up drawing on,
//! [`zk_set_vulkan_library`] names the MoltenVK library when the app keeps it
//! somewhere the lookup does not expect, and [`zk_set_hardware_option`] sets the
//! renderer's tuning switches (GPU versus CPU vertex shading) before a load.
//! `METAL.md` has the architecture, the MoltenVK findings and the spike plan.
//!
//! The internal resolution the host-GPU renderer draws the 3D at is a separate,
//! process-wide switch: [`zk_set_render_scale`] picks 1x (the console's own
//! 400×240, the default) to 4x, and the value is read when a system loads, like
//! the renderer switch. The software PICA200 always draws at 1x.
//!
//! ## Presentation on a CAMetalLayer
//!
//! The A0 path above still copies every screen out of the GPU memory and shows
//! it as a `CGImage`. The optional A1 path in [`presenter`] instead presents the
//! screens on a `CAMetalLayer` the app owns: [`presenter::zk_presenter_create`]
//! makes a Vulkan surface and swapchain from the app's `UIView`,
//! [`presenter::zk_create_presented`] loads a system on the device the renderer
//! shares with it, and [`presenter::zk_present`] shows each frame without a
//! readback. A device without MoltenVK, or one where the renderer cannot start,
//! keeps working: the app falls back to `zk_create` + `zk_read_screen`, and a
//! presented system whose renderer stayed on the CPU presents its pixels through
//! the same Metal layer. The existing `zk_*` signatures are unchanged.
//!
//! ## Saved states
//!
//! [`savestate`] exposes Zakuro's instant save/load pair to the app: the whole
//! console (CPU, kernel, services, GPU state and the four memories) is written
//! to one compressed blob between frames and put back later, with
//! [`savestate::zk_save_state_size`] / [`savestate::zk_save_state_copy`] /
//! [`savestate::zk_load_state`]. The container is checked before Zakuro reads
//! it, so a truncated or damaged file cannot ask the allocator for gigabytes or
//! touch the running console. Measured states are kept until copied/discarded
//! and released with the handle.
//!
//! Zakuro's own `log` records (the loader's linked-code warnings, GPU warnings)
//! are forwarded to stderr by [`zk_create`], because an iOS app installs no
//! logger and they would otherwise be dropped.

use std::cell::RefCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::ptr;
use std::sync::atomic::{AtomicU32, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use zakuro_common::Screen;
use zakuro_core::loader;
use zakuro_core::services::hid::{InputState, PadState};
use zakuro_core::{Config, FrameOutcome, System};
use zakuro_gpu::SharedDevice;

mod gamepack;
mod perf;
mod presenter;
mod savestate;

thread_local! {
    /// Last failure recorded on the current thread; empty when there is none.
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
    /// Last text [`zk_recompiled_status`] or [`zk_profiler_hot_spots`] returned
    /// on the current thread. Kept apart from `LAST_ERROR` so those calls never
    /// disturb the error contract.
    static LAST_STATUS: RefCell<CString> = RefCell::new(CString::default());
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

/// Reads a NUL-terminated C string as UTF-8, or `None` for a NULL pointer or
/// bytes that are not valid UTF-8.
fn read_c_string(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    // SAFETY: the FFI contract requires a non-NULL argument to be a
    // NUL-terminated string that stays valid for the duration of this call; it
    // is copied out and not retained.
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

/// Records `message` as the calling thread's last error.
pub(crate) fn set_last_error(message: impl Into<String>) {
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

/// One title's code, recompiled by 3dsrecomp at build time and linked into the
/// app instead of loaded from a library at run time. See `scripts/AOT_BUILD.md`.
#[cfg(feature = "linked")]
mod linked {
    use std::ffi::c_void;
    use std::ptr;

    use zakuro_core::recompiled::Linked;

    // The tables 3dsrecomp's generated C exports: the executable's entry
    // points, its CRO modules, and what the code was made from (`recomp.h`,
    // "Exported symbols"; there is no title ID among them).
    //
    // The generated archive the app links defines these; a `linked` build
    // without it fails at the app's final link with undefined `recomp_*`
    // symbols, which is intended.
    #[cfg(not(test))]
    extern "C" {
        static recomp_abi: u32;
        static recomp_generation: u32;
        static recomp_entry_count: u32;
        static recomp_entries: u8;
        static recomp_module_count: u32;
        static recomp_modules: u8;
        static recomp_origins: u8;
    }

    /// The 3DS title ID of the game the linked tables came from, baked at build
    /// time by `build.rs` from `ZAKURO_LINKED_PROGRAM_ID`.
    ///
    /// `Linked::new` needs it so the loader can check that the code matches the
    /// title in the ROM; a `3dsrecomp port` program bakes it into its `main.rs`
    /// the same way, because the symbols carry the tables but not the title.
    pub fn program_id() -> Option<u64> {
        let value = option_env!("ZAKURO_LINKED_PROGRAM_ID")?;
        let digits = value.trim();
        let digits = digits
            .strip_prefix("0x")
            .or_else(|| digits.strip_prefix("0X"))
            .unwrap_or(digits);
        u64::from_str_radix(digits, 16).ok()
    }

    /// The linked tables as Zakuro's `Linked`, or `None` when the build has no
    /// title ID to go with them.
    pub fn code() -> Option<Linked> {
        let program_id = program_id()?;
        // SAFETY: `tables` reads the constant tables of the code 3dsrecomp
        // generated, which the app links in and which live for the whole
        // process; `recomp.h` declares their layout and `recomp-abi` keeps the
        // Rust `Linked` in step with it.
        let (abi, entries, entry_count, modules, module_count, generation, origins) =
            unsafe { tables() };
        // SAFETY: the arguments are exactly those tables: the interface
        // version, the arrays and their counts, and the generation and origins
        // of the same generated code, as `Linked::new` and `with_origins` ask.
        Some(unsafe {
            Linked::new(program_id, abi, entries, entry_count, modules, module_count)
                .with_origins(generation, origins)
        })
    }

    /// A one-line description of the linked tables for the `zk_create` log: the
    /// build-time title, interface version, generation and table sizes.
    ///
    /// Reading the tables is safe here for the same reason as in [`code`], and
    /// `None` means the build has no title ID to go with them.
    pub fn describe_tables() -> Option<String> {
        let program_id = program_id()?;
        // SAFETY: as in `code`; `tables` lives for the whole process.
        let (abi, _, entry_count, _, module_count, generation, _) = unsafe { tables() };
        Some(format!(
            "tables for title {program_id:016X}: interface ABI {abi}, generation {generation}, \
             {entry_count} entry points, {module_count} modules"
        ))
    }

    /// The tables' addresses and counts, as `recomp.h` declares them.
    ///
    /// # Safety
    ///
    /// reads the `recomp_*` tables, which only the generated archive the app
    /// links defines.
    #[cfg(not(test))]
    unsafe fn tables() -> (
        u32,
        *const c_void,
        u32,
        *const c_void,
        u32,
        u32,
        *const c_void,
    ) {
        (
            recomp_abi,
            ptr::addr_of!(recomp_entries) as *const c_void,
            recomp_entry_count,
            ptr::addr_of!(recomp_modules) as *const c_void,
            recomp_module_count,
            recomp_generation,
            ptr::addr_of!(recomp_origins) as *const c_void,
        )
    }

    /// Stand-ins shaped like the tables `recomp.h` declares but holding no code,
    /// so host unit tests can build a `Linked` without a ROM or a generated
    /// archive.
    ///
    /// The interface version is `recomp.h`'s `RECOMP_ABI`, which upstream raises
    /// when the layout or meaning of the tables changes.
    ///
    /// # Safety
    ///
    /// always safe; `unsafe` to match the real `tables`.
    #[cfg(test)]
    unsafe fn tables() -> (
        u32,
        *const c_void,
        u32,
        *const c_void,
        u32,
        u32,
        *const c_void,
    ) {
        // aligned for `Entry`/`Module`/`Origins`, only ever used as addresses
        static EMPTY: u64 = 0;
        let empty = ptr::addr_of!(EMPTY) as *const c_void;
        (5, empty, 0, empty, 0, 5, empty)
    }
}

/// Why the code linked into this build could not be run, recorded by
/// [`zk_create`] for [`zk_recompiled_status`].
///
/// The loader reports the same thing through `log::warn!` (forwarded to stderr
/// by [`perf::install_logger`]), but the app's status line should not have to
/// grep the log. The interface-version check is repeated in [`zk_create`] before
/// loading so the reason is known even when the loader's log is not kept.
static LINKED_REFUSAL: Mutex<Option<String>> = Mutex::new(None);

/// Records why the AOT code handed to the loader cannot be run.
///
/// A statically `linked` build discovers such a reason from its build-time
/// tables and the interpreter-only shell from a GamePack registered at run time
/// ([gamepack::zk_register_gamepack]); the status path reads it back through
/// [`linked_refusal`].
fn set_linked_refusal(reason: impl Into<String>) {
    *LINKED_REFUSAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(reason.into());
}

/// The reasons most recently recorded by [`zk_create`], if any.
fn linked_refusal() -> Option<String> {
    LINKED_REFUSAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// Forgets a refusal so a new `zk_create` does not report the old one.
fn clear_linked_refusal() {
    *LINKED_REFUSAL
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
}

/// Hardware rendering: whether the systems [`zk_create`] makes draw the 3D on
/// the host GPU (Vulkan; MoltenVK over Metal on iOS) instead of in software.
///
/// The switch is process-wide and applies to the next [`zk_create`] call, not
/// to systems already loaded. `ZAKURO_IOS_HARDWARE` at build time makes it the
/// default, so the device spike can be a plain `cargo build` (see `METAL.md`).
const HARDWARE_AUTO: u8 = 0;
const HARDWARE_ON: u8 = 1;
const HARDWARE_OFF: u8 = 2;

/// What [`zk_set_hardware_renderer`] last asked for.
static HARDWARE_SETTING: AtomicU8 = AtomicU8::new(HARDWARE_AUTO);

/// What the last [`zk_hardware_probe`] found, for [`zk_hardware_status`] with a
/// `NULL` handle (there is no `System` to ask then).
static HARDWARE_PROBE: Mutex<Option<String>> = Mutex::new(None);

/// Whether [`zk_create`] should pass `Config.hardware_renderer = true`: the
/// run-time setting when one was made, else whether the library was built with
/// `ZAKURO_IOS_HARDWARE` set.
fn hardware_requested() -> bool {
    match HARDWARE_SETTING.load(Ordering::Relaxed) {
        HARDWARE_ON => true,
        HARDWARE_OFF => false,
        _ => matches!(
            option_env!("ZAKURO_IOS_HARDWARE").map(str::trim),
            Some("1" | "on" | "true" | "yes")
        ),
    }
}

/// Internal render resolution: the scale [`zk_create`] and
/// [`presenter::zk_create_presented`] hand the loader as `Config.resolution`,
/// where `1` is the 3DS's own 400×240 and `4` is 1600×960.
///
/// The loader builds the renderer once, while it loads a system, so a new scale
/// applies to the next load and never rebuilds a loaded system's renderer.
const DEFAULT_RENDER_SCALE: u32 = 1;
/// Smallest accepted internal scale: the console's own pixels.
const MIN_RENDER_SCALE: u32 = 1;
/// Largest accepted internal scale: 4x (1600×960), 16 times the pixels of 1x.
const MAX_RENDER_SCALE: u32 = 4;

/// The process-wide internal render scale; see [`zk_set_render_scale`].
static RENDER_SCALE: AtomicU32 = AtomicU32::new(DEFAULT_RENDER_SCALE);

/// The render scale a load should use, clamped into the accepted range in case
/// the atomic ever holds anything else.
fn render_scale() -> u32 {
    RENDER_SCALE
        .load(Ordering::Relaxed)
        .clamp(MIN_RENDER_SCALE, MAX_RENDER_SCALE)
}

/// Stores a new render scale, or leaves the old one and returns `false` for a
/// value outside `1..=4`.
fn store_render_scale(scale: u32) -> bool {
    if !(MIN_RENDER_SCALE..=MAX_RENDER_SCALE).contains(&scale) {
        return false;
    }
    RENDER_SCALE.store(scale, Ordering::Relaxed);
    true
}

/// Stores `text` as the last [`zk_hardware_probe`] result.
fn set_hardware_probe(text: impl Into<String>) {
    *HARDWARE_PROBE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(text.into());
}

/// The last [`zk_hardware_probe`] result, if it ran.
fn hardware_probe_result() -> Option<String> {
    HARDWARE_PROBE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// Logs what a freshly loaded system ended up drawing the 3D on.
///
/// [`zk_create`] prints this once per load, next to the linked-code lines, so
/// `idevicesyslog` answers "did the spike take the GPU path?" without an app
/// change. `METAL.md` explains the build and device steps.
fn log_hardware_outcome(system: &System) {
    let requested = system.config.hardware_renderer;
    if system.gpu.draws_on_gpu() {
        let presentation = if system.gpu.shows_directly() {
            "the screens go straight to the CAMetalLayer (no readback)"
        } else {
            "screens are read back for presentation"
        };
        eprintln!(
            "zk_create: the 3D draws on the host GPU through Vulkan (MoltenVK over Metal on \
             iOS) at {}x; {presentation}",
            system.gpu.scale()
        );
    } else if requested {
        let presentation = if system.config.device.is_some() {
            "; the screens are uploaded through the CAMetalLayer"
        } else {
            ""
        };
        eprintln!(
            "zk_create: hardware rendering was requested but no Vulkan device started; the 3D \
             draws in software (the zk[WARN] line above has the reason){presentation}"
        );
    } else {
        eprintln!(
            "zk_create: the 3D draws in software (PICA200 on the CPU); hardware rendering is off \
             (see zk_set_hardware_renderer, METAL.md)"
        );
    }
}

/// Logs how a presented system will reach the app's `CAMetalLayer`: straight
/// from the renderer's GPU images, or uploaded from the CPU when the renderer
/// stayed in software. A plain `zk_create` says nothing here; its display path
/// is unchanged (readback + `CGImage`).
fn log_presentation_outcome(system: &System, presented: bool) {
    if !presented {
        return;
    }
    let presentation = if system.gpu.shows_directly() {
        "the screens go straight to the CAMetalLayer (no readback)"
    } else if system.gpu.draws_on_gpu() {
        "the renderer draws on the GPU but the screens are read back and uploaded through the \
         CAMetalLayer"
    } else {
        "the renderer is software; its pixels are uploaded through the CAMetalLayer"
    };
    eprintln!("zk_create_presented: {presentation}");
}

/// The text [`zk_hardware_status`] returns: what this system, or the last
/// probe, says about drawing on the host GPU.
fn hardware_status_text(system: *mut c_void) -> String {
    // SAFETY: `system` is either NULL or a live handle from `zk_create`; only
    // read here, on the caller's serial queue.
    let Some(system) = (unsafe { (system as *mut System).as_ref() }) else {
        return match hardware_probe_result() {
            Some(result) => format!("no system: the last zk_hardware_probe reported {result}"),
            None => "no system: zk_hardware_status needs a handle returned by zk_create, or a \
                 zk_hardware_probe first"
                .to_owned(),
        };
    };
    let scale = system.gpu.scale();
    if system.gpu.draws_on_gpu() {
        let presentation = if system.gpu.shows_directly() {
            "the screens go straight to the CAMetalLayer (no readback)"
        } else {
            "screens are read back for presentation"
        };
        format!(
            "the 3D draws on the host GPU through Vulkan (MoltenVK over Metal on iOS) at {scale}x; \
             {presentation}"
        )
    } else if system.config.hardware_renderer {
        if system.config.device.is_some() {
            "the 3D draws in software; the screens are uploaded through the CAMetalLayer (the \
             zk[WARN] line in the log has the reason)"
                .to_owned()
        } else {
            "hardware rendering was requested but no Vulkan device started; the 3D draws in \
             software (the zk[WARN] line in the log has the reason)"
                .to_owned()
        }
    } else {
        "the 3D draws in software (PICA200 on the CPU); hardware rendering is off".to_owned()
    }
}

/// Stores `text` as the calling thread's last status text and returns a pointer
/// to it, owned by this library exactly like [`zk_last_error`]'s pointer.
fn set_status_text(text: impl Into<String>) -> *const c_char {
    let text: String = text.into();
    // Escape interior NULs so `CString::new` cannot fail: no panic across FFI.
    let text = text.replace('\0', "\\0");
    let text = CString::new(text).unwrap_or_default();
    match LAST_STATUS.try_with(|slot| {
        let mut slot = slot.borrow_mut();
        *slot = text;
        slot.as_ptr()
    }) {
        Ok(pointer) => pointer,
        // TLS is gone during teardown; report an empty string instead of panicking.
        Err(_) => ptr::null(),
    }
}

/// The text [`zk_recompiled_status`] returns: whether the loaded system runs the
/// code linked into this build, and why not when it does not.
///
/// Split out from the FFI entry point so host unit tests can build a `System`
/// with placeholder linked tables and check the wording without a ROM.
fn recompiled_status_text(system: *mut c_void) -> String {
    // SAFETY: `system` is either NULL or a live handle from `zk_create`; only
    // read here, on the caller's serial queue.
    let Some(system) = (unsafe { (system as *mut System).as_ref() }) else {
        return "no system: zk_recompiled_status needs a handle returned by zk_create".to_owned();
    };
    let linked = system
        .config
        .linked
        .as_ref()
        .map(|linked| linked.program_id());
    let rom = system.title.as_ref().map(|title| title.program_id());

    if let Some(library) = &system.recompiled {
        let fallbacks = library.fallbacks();
        let interpreted = system.interpreted_instructions.saturating_add(fallbacks);
        let total = interpreted.saturating_add(system.recompiled_instructions);
        let percent = if total == 0 {
            0.0
        } else {
            interpreted as f64 * 100.0 / total as f64
        };
        let title = linked.map_or_else(|| "unknown".to_owned(), |id| format!("{id:016X}"));
        return format!(
            "AOT active: linked code for title {title}, {}, {fallbacks} instruction fallbacks, \
             interpreted {percent:.2}% of {total} instructions",
            library.describe(),
        );
    }

    if !cfg!(feature = "linked") {
        // A GamePack can register at run time in this interpreter-only build;
        // when the loader still did not run its code, name the pack's title and
        // the recorded reason instead of claiming there is no AOT code.
        if let Some(title) = gamepack::registered_title_id() {
            let detail = linked_refusal().unwrap_or_else(|| {
                "the loader did not accept the game package; look for the zk[WARN] lines in \
                 the log for the reason (title/ABI mismatch, or a pack for another game)"
                    .to_owned()
            });
            return format!(
                "interpreting: the game package for title {title:016X} was registered but not \
                 accepted: {detail}"
            );
        }
        return "interpreting: interpreter-only build, no linked code is compiled in".to_owned();
    }
    let Some(linked) = linked else {
        return "interpreting: this linked build handed no code to the loader".to_owned();
    };
    match rom {
        Some(rom) if rom != linked => format!(
            "interpreting: the code linked in is for title {linked:016X}, but the ROM is \
             {rom:016X}, so the loader fell back to the interpreter"
        ),
        _ => {
            let detail = linked_refusal().unwrap_or_else(|| {
                "look for the zk[WARN] lines in the log for the loader's reason (title/ABI \
                 mismatch, or an update/mod changed the code)"
                    .to_owned()
            });
            format!(
                "interpreting: the loader did not run the code linked in for title \
                 {linked:016X}: {detail}"
            )
        }
    }
}

/// Logs whether the loaded system will run the code linked into this build, so a
/// device run shows the answer even when the app does not display
/// [`zk_recompiled_status`].
fn log_linked_outcome(system: &System) {
    if let Some(library) = &system.recompiled {
        let fallbacks = library.fallbacks();
        let total = system
            .interpreted_instructions
            .saturating_add(fallbacks)
            .saturating_add(system.recompiled_instructions);
        eprintln!(
            "zk_create: AOT active: linked code, {}, {fallbacks} instruction fallbacks, {} \
             instructions ran so far",
            library.describe(),
            total,
        );
        return;
    }

    let linked = system
        .config
        .linked
        .as_ref()
        .map(|linked| linked.program_id());
    let rom = system.title.as_ref().map(|title| title.program_id());
    let reason = match (linked, rom) {
        (Some(linked), Some(rom)) if linked != rom => {
            format!(
                "the AOT code handed to the loader is for title {linked:016X}, but the ROM is \
                 {rom:016X}"
            )
        }
        (Some(_), _) => linked_refusal().unwrap_or_else(|| {
            "the loader did not accept the AOT code; check the zk[WARN] lines above".to_owned()
        }),
        (None, _) if !cfg!(feature = "linked") => match gamepack::registered_title_id() {
            Some(title) => linked_refusal().unwrap_or_else(|| {
                format!(
                    "the game package for title {title:016X} was registered but handed no usable \
                     code"
                )
            }),
            None => "this is the interpreter-only build and no game package is registered"
                .to_owned(),
        },
        (None, _) => "this linked build handed no code to the loader".to_owned(),
    };
    eprintln!("zk_create: AOT inactive: interpreting everything: {reason}");
}

/// Returns the last failure on the calling thread, or `NULL` when there is no
/// pending error.
///
/// `zk_create`, the saved-state calls (`zk_save_state_size`,
/// `zk_save_state_copy`, `zk_load_state`), the hardware switches and the
/// presenter calls record their failures here; a successful `zk_create`,
/// state measurement/copy/load clears the message.
///
/// The returned pointer is owned by this library and remains valid until the
/// next call that records or clears an error on **the same thread**. Copy the
/// text (for example `String(cString:)` in Swift) if it must outlive that; never
/// free it. A failure recorded on a background queue can only be read back on
/// that same thread.
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

/// 1 when AOT code is available for the next [`zk_create`]: either one game's
/// recompiled tables linked in at build time (`--features linked`, see
/// `scripts/AOT_BUILD.md`) or a GamePack dylib registered at run time
/// ([gamepack]), 0 for a shell with neither.
#[no_mangle]
pub extern "C" fn zk_linked_code() -> i32 {
    if cfg!(feature = "linked") || gamepack::registered_title_id().is_some() {
        1
    } else {
        0
    }
}

/// The 3DS title ID (`0004xxxxxxxxxxxx`) of the AOT code this build will hand
/// the next [`zk_create`]: the statically linked title, or the GamePack
/// registered at run time, or 0 when there is no AOT code.
///
/// The loader compares it with the title in the ROM: a mismatch logs a warning
/// and interprets everything rather than running code meant for another game.
#[no_mangle]
pub extern "C" fn zk_linked_program_id() -> u64 {
    #[cfg(feature = "linked")]
    if let Some(id) = linked::program_id() {
        return id;
    }
    gamepack::registered_title_id().unwrap_or(0)
}

/// Loads a decrypted `.3ds` / `.cci` and returns an opaque `System*`.
///
/// Returns `NULL` on failure; read [`zk_last_error`] on the same thread for the
/// reason. On success the thread's last error is cleared.
///
/// This is also where the diagnostics start: it installs the stderr logger that
/// forwards Zakuro's own records, logs whether the code linked into this build
/// (if any) is running, and resets the frame-time window reported by
/// [`zk_last_frame_micros`] and the periodic `zk_perf` line.
#[no_mangle]
pub extern "C" fn zk_create(rom: *const c_char, data_dir: *const c_char) -> *mut c_void {
    create_system(rom, data_dir, None, false)
}

/// Shared body of [`zk_create`] and [`presenter::zk_create_presented`].
///
/// `device` is the Vulkan device a presenter offers for the renderer to share
/// (`None` = no presenter: the loader makes its own and screens are read back);
/// `presented` also forces the hardware renderer on, because a presented system
/// must draw on the device it will show from. Everything else, including the
/// error contract, is `zk_create`'s.
pub(crate) fn create_system(
    rom: *const c_char,
    data_dir: *const c_char,
    device: Option<Arc<SharedDevice>>,
    presented: bool,
) -> *mut c_void {
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

    // The loader explains a linked-code fallback through `log`, and an iOS app
    // installs no logger: without this those records are dropped and the only
    // device-side clue is `zk_recompiled` returning 0. Forward them to stderr,
    // where `idevicesyslog` sees them.
    perf::install_logger();
    // A new system gets a fresh frame-time window; the old system's counters
    // mean nothing for it.
    perf::reset();
    clear_linked_refusal();

    let mut config = Config::default();
    config.data_dir = data_dir;
    // A presented load draws on the presenter's device and always asks for the
    // GPU renderer (the app shows the screens through its Metal layer). A plain
    // load follows the build/runtime switch above: the loader makes the Vulkan
    // device itself and falls back to software, logging why, when it can't. On
    // iOS that usually means MoltenVK is not where Zakuro's `instance::entry`
    // looks: METAL.md has the small upstream patch for it.
    config.hardware_renderer = presented || hardware_requested();
    config.device = device;
    config.texture_packs = false;
    // iOS forbids executable memory: no JIT, no recompiled-code discovery here.
    config.find_recompiled = false;
    // The internal render resolution of the host-GPU renderer (1x = the
    // console's own 400×240). The loader builds the renderer while it loads, so
    // this is where a new scale takes effect: there is no run-time rebuild of a
    // loaded system's renderer, and the software renderer stays at 1x.
    config.resolution = render_scale();

    // One game's AOT code can be linked into the app instead (`scripts/AOT_BUILD.md`). The
    // loader checks its title ID and interface version, and interprets instead
    // when they do not match.
    #[cfg(feature = "linked")]
    {
        match linked::describe_tables() {
            Some(tables) => eprintln!("zk_create: linked build, {tables}"),
            None => eprintln!(
                "zk_create: linked build without a title ID (ZAKURO_LINKED_PROGRAM_ID), \
                 interpreting everything"
            ),
        }
        match linked::code() {
            Some(code) => {
                // Check the tables here as well as in the loader: this records
                // the reason `zk_recompiled_status` reports, and the loader's
                // own warning is forwarded to stderr by the logger above.
                match zakuro_core::recompiled::Library::linked(&code) {
                    Ok(library) => eprintln!(
                        "zk_create: recomp-abi accepted the linked tables: {}",
                        library.describe()
                    ),
                    Err(error) => {
                        let reason = format!(
                            "the linked tables were built for an interface version this Zakuro \
                             refuses: {error}"
                        );
                        eprintln!("zk_create: {reason}; the loader will interpret everything");
                        set_linked_refusal(reason);
                    }
                }
                config.linked = Some(code);
            }
            None => eprintln!(
                "zk_create: no linked tables to hand the loader (missing title ID), \
                 interpreting everything"
            ),
        }
    }
    #[cfg(not(feature = "linked"))]
    eprintln!("zk_create: interpreter-only build, no linked code is compiled in");

    // A per-game AOT GamePack dylib may have registered its tables at run time
    // (AOT-first shell, docs/desktop-aot.md section 6). This is the AOT source
    // of the interpreter-only shell; a statically linked build keeps precedence
    // because its compile-time title check is stricter.
    if config.linked.is_none() {
        if let Some(title_id) = gamepack::registered_title_id() {
            match gamepack::registered_code() {
                Some(code) => {
                    eprintln!(
                        "zk_create: game package registered for title {title_id:016X}, handing \
                         its AOT code to the loader"
                    );
                    match zakuro_core::recompiled::Library::linked(&code) {
                        Ok(library) => eprintln!(
                            "zk_create: recomp-abi accepted the game package tables: {}",
                            library.describe()
                        ),
                        Err(error) => {
                            let reason = format!(
                                "the game package tables were built for an interface version \
                                 this Zakuro refuses: {error}"
                            );
                            eprintln!("zk_create: {reason}; the loader will interpret everything");
                            set_linked_refusal(reason);
                        }
                    }
                    config.linked = Some(code);
                }
                None => eprintln!(
                    "zk_create: a game package is registered for title {title_id:016X} but its \
                     tables are unusable"
                ),
            }
        }
    }

    // The pack's host entry point must stay resolvable from a dlopen()ed pack
    // even though the app never calls it directly: taking its address in code
    // this app does call keeps the linker from dropping the symbol.
    let _ = std::hint::black_box(gamepack::zk_register_gamepack as *const () as usize);

    match loader::load(&rom, config) {
        Ok(system) => {
            clear_last_error();
            // Sampling guest PCs costs a branch per guest step, so only the
            // diagnostic `profiling` build starts it on its own; the app can
            // start it at run time with `zk_profiler_start`.
            #[cfg(feature = "profiling")]
            let system = {
                let mut system = system;
                system.enable_profiler();
                eprintln!("zk_create: profiling build, sampling guest PCs from the first frame");
                system
            };
            log_linked_outcome(&system);
            log_hardware_outcome(&system);
            log_presentation_outcome(&system, presented);
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
///
/// The call's duration is what [`zk_last_frame_micros`] reports, and every
/// [`perf::DEFAULT_LOG_INTERVAL`] frames the library logs a `zk_perf` line
/// splitting that time into emulated CPU, software GPU, screen read and audio.
#[no_mangle]
pub extern "C" fn zk_run_frame(system: *mut c_void) -> i32 {
    if system.is_null() {
        return -2;
    }
    // SAFETY: `system` is a live pointer returned by `zk_create` (a leaked
    // `Box<System>`). The C ABI requires serial calls, so no other `&mut` to the
    // same `System` exists; only `zk_destroy` frees it.
    let system = unsafe { &mut *(system as *mut System) };
    let started = Instant::now();
    let result = match system.run_frame() {
        FrameOutcome::Completed => 0,
        FrameOutcome::Exited => 1,
        FrameOutcome::Faulted => -1,
    };
    perf::record_frame(system, started.elapsed(), result);
    result
}

/// Microseconds the last [`zk_run_frame`] call took, 0 before the first frame.
///
/// The app can read this every frame for a HUD; the periodic `zk_perf` line
/// gives the same number as an average. A frame that returns early because the
/// handle is `NULL` is not timed.
#[no_mangle]
pub extern "C" fn zk_last_frame_micros() -> u64 {
    perf::last_frame_micros()
}

/// 1 when this `System` is running 3dsrecomp code, 0 when the interpreter runs
/// everything (no recompiled code for the title, or the loader refused it).
///
/// For QA logs and performance triage: an AOT build that reports 0 here is
/// interpreting, which is slow, not broken. This reports the loader's decision
/// for the handle, not the build: [`zk_linked_code`] says what was compiled in,
/// and [`zk_recompiled_status`] explains a 0 and reports how much of the work
/// actually went through the linked code.
#[no_mangle]
pub extern "C" fn zk_recompiled(system: *mut c_void) -> i32 {
    if system.is_null() {
        return 0;
    }
    // SAFETY: see `zk_run_frame`: a live handle, read-only, on the serial queue.
    let system = unsafe { &*(system as *const System) };
    if system.recompiled.is_some() {
        1
    } else {
        0
    }
}

/// Explains, in one line, whether this `System` runs the code linked into this
/// build and why not when it does not: no linked code, a title or interface
/// mismatch, or an update/mod that changed the game's code.
///
/// The pointer is owned by this library and remains valid until the next
/// [`zk_recompiled_status`] or [`zk_profiler_hot_spots`] call **on the same
/// thread**; copy the text (for example `String(cString:)` in Swift). It is
/// never `NULL` in practice, but treat `NULL` as "no text".
///
/// Unlike [`zk_last_error`], this is a status, not a failure: a `NULL` handle
/// gets a readable line instead of an error. Call it on the runtime's serial
/// queue, like every other call taking a handle.
#[no_mangle]
pub extern "C" fn zk_recompiled_status(system: *mut c_void) -> *const c_char {
    set_status_text(recompiled_status_text(system))
}

/// Starts the guest-PC sampling profiler for this `System`.
///
/// Returns 0 on success, -1 for a `NULL` handle. Sampling costs a little per
/// guest step; call it only while diagnosing, not for a release run. Once on,
/// it stays on and the sampled addresses accumulate (they are cumulative, not
/// per window): read them with [`zk_profiler_hot_spots`], and the `profiling`
/// build also puts the hottest few in every `zk_perf` line.
#[no_mangle]
pub extern "C" fn zk_profiler_start(system: *mut c_void) -> i32 {
    if system.is_null() {
        return -1;
    }
    // SAFETY: see `zk_run_frame`: a live handle on the serial queue, exclusive.
    let system = unsafe { &mut *(system as *mut System) };
    system.enable_profiler();
    eprintln!("zk_profiler_start: sampling guest PCs, read them with zk_profiler_hot_spots");
    0
}

/// The hottest `count` sampled guest locations as text, one `thread 0xPC hits`
/// line each, most frequent first.
///
/// Empty when the profiler has not run ([`zk_profiler_start`] or the
/// `profiling` build) or has no samples yet. Function names are not available
/// for guest addresses, so the PC is what a symbol map of `libgame.a` matches.
/// `count` is capped at 100; the pointer contract is [`zk_recompiled_status`]'s.
#[no_mangle]
pub extern "C" fn zk_profiler_hot_spots(system: *mut c_void, count: u32) -> *const c_char {
    // SAFETY: see `zk_recompiled`: a live handle, read-only, on the serial queue.
    let text = (unsafe { (system as *mut System).as_ref() }).map_or_else(String::new, |system| {
        perf::format_hot_spots(system, (count as usize).min(100))
    });
    set_status_text(text)
}

/// Makes a Vulkan device the way [`zk_create`] will with hardware rendering on,
/// and drops it again: the preflight for the MoltenVK spike.
///
/// Returns 0 when a device was made, -1 when it wasn't. The reason goes to
/// [`zk_last_error`] and the log; on iOS it is usually that MoltenVK is not
/// linked, not where Zakuro's `instance::entry` looks, or that the app's
/// `ZAKURO_VULKAN_LIBRARY` names a library that does not load. No game and no
/// `System` are needed. Call it before [`zk_create`], on the same serial queue
/// as every other handle call, and treat the device it makes as a diagnostic:
/// each system makes its own when it loads.
#[no_mangle]
pub extern "C" fn zk_hardware_probe() -> i32 {
    match zakuro_gpu::SharedDevice::new() {
        Ok(device) => {
            drop(device);
            clear_last_error();
            set_hardware_probe("a Vulkan device was made");
            eprintln!(
                "zk_hardware_probe: a Vulkan device was made, the 3D can draw on the host GPU"
            );
            0
        }
        Err(error) => {
            let message = format!("zk_hardware_probe: no Vulkan device: {error}");
            eprintln!("{message}");
            set_last_error(message);
            set_hardware_probe("no Vulkan device (METAL.md has the spike steps)");
            -1
        }
    }
}

/// Draws the 3D on the host GPU (Vulkan; MoltenVK over Metal on iOS) for the
/// systems [`zk_create`] makes from now on, or in software again with
/// `enabled = 0`.
///
/// The switch is process-wide and does not touch a system already loaded: pass
/// it before the load. Even when on, a device that cannot start (no MoltenVK,
/// a GPU without what the renderer needs) falls back to software by itself,
/// logging why. Returns 0. [`zk_hardware_status`] says what a loaded system
/// actually ended up using; `METAL.md` covers the paths and the spike.
#[no_mangle]
pub extern "C" fn zk_set_hardware_renderer(enabled: i32) -> i32 {
    HARDWARE_SETTING.store(
        if enabled != 0 {
            HARDWARE_ON
        } else {
            HARDWARE_OFF
        },
        Ordering::Relaxed,
    );
    eprintln!(
        "zk_set_hardware_renderer: hardware rendering {} for the next zk_create",
        if enabled != 0 { "on" } else { "off" }
    );
    0
}

/// Sets the internal resolution the 3D renderer draws at for the systems
/// [`zk_create`] and [`presenter::zk_create_presented`] load from now on: `1`
/// (the default) is the 3DS's own 400×240, `4` is 1600×960.
///
/// The value goes into `Config.resolution` on the next load. Zakuro builds the
/// renderer while it loads a system, so a change never rebuilds the renderer of
/// a system already loaded (there is no run-time renderer rebuild): destroy the
/// system and call `zk_create`/`zk_create_presented` again for the new scale to
/// take effect. The setting is process-wide and independent of the
/// hardware/software renderer switch, but only the host-GPU renderer uses it:
/// the software PICA200 always draws at 1x. A higher scale costs GPU time and
/// memory, and the presenter scales the larger screens down to its layer.
///
/// Returns 0, or -1 when `scale` is outside 1..=4; the setting is then
/// unchanged and the reason goes to [`zk_last_error`] on the calling thread.
#[no_mangle]
pub extern "C" fn zk_set_render_scale(scale: u32) -> i32 {
    if !store_render_scale(scale) {
        let message = format!(
            "zk_set_render_scale: scale {scale} is outside {MIN_RENDER_SCALE}..={MAX_RENDER_SCALE}"
        );
        eprintln!("{message}");
        set_last_error(message);
        return -1;
    }
    eprintln!(
        "zk_set_render_scale: the next load draws the 3D at {scale}x ({}x{} internally); a \
         loaded system keeps its scale",
        400 * scale,
        240 * scale
    );
    0
}

/// Names the Vulkan library (on iOS: MoltenVK) to load, for when the app keeps
/// it where Zakuro's bundled lookup does not try.
///
/// Sets `ZAKURO_VULKAN_LIBRARY`, which the iOS build of Zakuro's
/// `instance::entry` reads before its own candidates (a small upstream patch;
/// `METAL.md` has the diff). Pass a `@rpath/`, `@executable_path/` or absolute
/// path, for example `@executable_path/Frameworks/MoltenVK.framework/MoltenVK`.
/// Call before [`zk_create`]. Returns 0, or -1 for a NULL or non-UTF-8 path.
#[no_mangle]
pub extern "C" fn zk_set_vulkan_library(path: *const c_char) -> i32 {
    let Some(path) = read_c_string(path) else {
        set_last_error("zk_set_vulkan_library: path is NULL or not valid UTF-8");
        return -1;
    };
    // SAFETY: `set_var` has no memory-safety preconditions on this target; the
    // environment is read by Zakuro's renderer on the next `zk_create`, which
    // the caller must not have started yet (the ABI is serial anyway).
    std::env::set_var("ZAKURO_VULKAN_LIBRARY", &path);
    eprintln!("zk_set_vulkan_library: Vulkan/MoltenVK will be loaded from {path}");
    0
}

/// The renderer's own switches this ABI lets the app set before a load, so a
/// device can A/B them without rebuilding the IPA.
///
/// `name` is one of the keys here; `value` is the string the renderer reads
/// (NULL or empty unsets it again). They map to the environment variables
/// Zakuro's Vulkan renderer checks while it makes its device and draws. The
/// ones worth a spike run: `gpu_shaders` (`ZAKURO_GPU_SHADERS=1`) shades
/// vertices on the GPU instead of on the CPU, which is the default on a GPU it
/// takes for integrated, as an iPhone's is; `cpu_shaders` forces the CPU side
/// back; `static_blend` and `float_depth` compare the fallbacks. Returns 0, or
/// -1 for a NULL name, a name not in this table, or a non-UTF-8 string.
///
/// Call before [`zk_create`]: the renderer reads these once per load.
#[no_mangle]
pub extern "C" fn zk_set_hardware_option(name: *const c_char, value: *const c_char) -> i32 {
    /// The switches a device spike wants, by the name the app passes and the
    /// environment variable Zakuro's Vulkan renderer reads.
    const OPTIONS: [(&str, &str); 10] = [
        ("gpu_shaders", "ZAKURO_GPU_SHADERS"),
        ("cpu_shaders", "ZAKURO_CPU_SHADERS"),
        ("interpret_shaders", "ZAKURO_INTERPRET_SHADERS"),
        ("copy_screens", "ZAKURO_COPY_SCREENS"),
        ("present_mode", "ZAKURO_PRESENT_MODE"),
        ("gpu_times", "ZAKURO_GPU_TIMES"),
        ("wait_for_shaders", "ZAKURO_WAIT_FOR_SHADERS"),
        ("static_blend", "ZAKURO_STATIC_BLEND"),
        ("float_depth", "ZAKURO_FLOAT_DEPTH"),
        ("depth_blits", "ZAKURO_DEPTH_BLITS"),
    ];
    let Some(name) = read_c_string(name) else {
        set_last_error("zk_set_hardware_option: name is NULL or not valid UTF-8");
        return -1;
    };
    // A NULL or empty value means "unset, use the renderer's default".
    let value = read_c_string(value).filter(|value| !value.is_empty());
    let Some((_, variable)) = OPTIONS.iter().find(|(key, _)| *key == name) else {
        set_last_error(format!(
            "zk_set_hardware_option: unknown option {name:?} (known: gpu_shaders, cpu_shaders, \
             interpret_shaders, copy_screens, present_mode, gpu_times, wait_for_shaders, \
             static_blend, float_depth, depth_blits)"
        ));
        return -1;
    };
    // SAFETY: as in `zk_set_vulkan_library`, only before the renderer reads the
    // environment.
    match value {
        Some(value) => {
            std::env::set_var(variable, &value);
            eprintln!("zk_set_hardware_option: {variable} = {value}");
        }
        None => {
            std::env::remove_var(variable);
            eprintln!("zk_set_hardware_option: {variable} unset");
        }
    }
    0
}

/// Describes what this system draws the 3D on, in one line, for the HUD or the
/// log: the host GPU (Vulkan; MoltenVK over Metal on iOS) with the resolution
/// scale, a request that fell back to software, or software by choice.
///
/// With a `NULL` handle it reports the last [`zk_hardware_probe`] instead,
/// which is what the spike checks before a ROM is loaded. The pointer is owned
/// by this library like [`zk_recompiled_status`]'s: copy it (`String(cString:)`
/// in Swift), do not free it, and do not keep it across the next status call on
/// the same thread.
#[no_mangle]
pub extern "C" fn zk_hardware_status(system: *mut c_void) -> *const c_char {
    set_status_text(hardware_status_text(system))
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
///
/// The call's duration is what [`zk_last_screen_read_micros`] reports. It is
/// separate from [`zk_last_frame_micros`] because reading a screen (and turning
/// it into an image on the Swift side) is presentation cost, not emulation.
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
    let screen = if which == 0 {
        Screen::Top
    } else {
        Screen::Bottom
    };
    let started = Instant::now();
    let pixels = system.read_screen(screen);
    let n = pixels.len().min(capacity);
    // SAFETY: `out` is non-NULL and the caller guarantees `capacity` writable
    // bytes; `n <= capacity`. The source buffer is owned by the `System`, so it
    // cannot overlap the caller's `out` buffer.
    unsafe { ptr::copy_nonoverlapping(pixels.as_ptr(), out, n) };
    perf::record_screen_read(which, started.elapsed());
    pixels.len()
}

/// Microseconds the last [`zk_read_screen`] call took for `which` (0 = top,
/// other = bottom), 0 before the first read.
#[no_mangle]
pub extern "C" fn zk_last_screen_read_micros(which: u32) -> u64 {
    perf::last_screen_read_micros(which)
}

/// Copies interleaved stereo i16 samples into `out`. Returns frames written.
///
/// The call's duration is what [`zk_last_audio_take_micros`] reports.
#[no_mangle]
pub extern "C" fn zk_take_audio(system: *mut c_void, out: *mut i16, capacity: usize) -> usize {
    if system.is_null() || out.is_null() {
        return 0;
    }
    // SAFETY: see `zk_run_frame`: serial calls guarantee exclusive access to the
    // `System` behind `system`.
    let system = unsafe { &mut *(system as *mut System) };
    let started = Instant::now();
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
    perf::record_audio_take(started.elapsed());
    frames
}

/// Microseconds the last [`zk_take_audio`] call took, 0 before the first call.
#[no_mangle]
pub extern "C" fn zk_last_audio_take_micros() -> u64 {
    perf::last_audio_take_micros()
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

/// Releases a handle returned by `zk_create()`. Safe to call with NULL.
///
/// Also releases a saved state the handle had measured and not copied yet (see
/// [`savestate::zk_save_state_discard`]), so an abandoned save does not outlive
/// the runtime.
#[no_mangle]
pub extern "C" fn zk_destroy(system: *mut c_void) {
    if !system.is_null() {
        // The handle's measured saved state is owned by this library, not by the
        // `System`; release it before the pointer can be handed to a new system.
        savestate::forget(system);
        // SAFETY: `system` is a pointer produced by `zk_create` (a `Box<System>`
        // leaked through `Box::into_raw`) and is freed exactly once here. The C
        // ABI requires the caller to stop using the handle afterwards.
        unsafe { drop(Box::from_raw(system as *mut System)) };
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::{c_char, c_void, CStr};
    use std::ptr;
    use std::sync::atomic::Ordering;
    use std::sync::{Mutex, MutexGuard};

    #[cfg(feature = "linked")]
    use zakuro_core::{Config, System};

    use super::{
        clear_last_error, render_scale, set_last_error, store_render_scale, zk_create,
        zk_hardware_status, zk_last_audio_take_micros, zk_last_error, zk_last_frame_micros,
        zk_last_screen_read_micros, zk_linked_code, zk_linked_program_id, zk_profiler_hot_spots,
        zk_profiler_start, zk_recompiled, zk_recompiled_status, zk_set_hardware_option,
        zk_set_hardware_renderer, zk_set_render_scale, zk_set_vulkan_library, DEFAULT_RENDER_SCALE,
        MAX_RENDER_SCALE, MIN_RENDER_SCALE, RENDER_SCALE,
    };
    #[cfg(feature = "linked")]
    use super::{clear_linked_refusal, set_linked_refusal};

    /// Copies the current thread's last error, if any.
    fn last_error_text() -> Option<String> {
        let pointer = zk_last_error();
        if pointer.is_null() {
            return None;
        }
        // SAFETY: the pointer comes from `zk_last_error` and stays valid until
        // the next `zk_create` / `zk_last_error` call on this thread; it is read
        // immediately here.
        Some(
            unsafe { CStr::from_ptr(pointer) }
                .to_string_lossy()
                .into_owned(),
        )
    }

    /// Copies the text `zk_recompiled_status` just wrote for `system`.
    fn status_text(system: *mut c_void) -> String {
        let pointer = zk_recompiled_status(system);
        assert!(!pointer.is_null(), "status text is never NULL");
        // SAFETY: pointer owned by the library and valid until the next status
        // call on this thread; read immediately.
        unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned()
    }

    /// Copies the text `zk_profiler_hot_spots` just wrote for `system`.
    fn hot_spots_text(system: *mut c_void, count: u32) -> String {
        let pointer = zk_profiler_hot_spots(system, count);
        assert!(!pointer.is_null(), "hot spots text is never NULL");
        // SAFETY: as in `status_text`.
        unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned()
    }

    /// Copies the text `zk_hardware_status` just wrote for `system`.
    fn hardware_status(system: *mut c_void) -> String {
        let pointer = zk_hardware_status(system);
        assert!(!pointer.is_null(), "hardware status text is never NULL");
        // SAFETY: as in `status_text`.
        unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .into_owned()
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
        assert!(
            message.contains("rom path is NULL"),
            "unexpected: {message}"
        );
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

    #[test]
    fn null_handle_reports_no_recompiled_code() {
        assert_eq!(zk_recompiled(ptr::null_mut()), 0);
    }

    #[test]
    fn missing_rom_is_reported() {
        // A syntactically valid path exercises the full create path up to the
        // loader (logger install, frame-time reset) and its failure report.
        clear_last_error();
        let path = std::ffi::CString::new("this-rom-does-not-exist.3ds").expect("no NUL");
        let system = zk_create(path.as_ptr(), ptr::null());
        assert!(system.is_null());
        let message = last_error_text().expect("a failed load must set an error");
        assert!(message.contains("failed to load"), "unexpected: {message}");
    }

    #[test]
    fn linked_build_reports_its_knobs() {
        #[cfg(feature = "linked")]
        {
            assert_eq!(zk_linked_code(), 1);
            let id = zk_linked_program_id();
            assert_ne!(id, 0, "the linked feature needs ZAKURO_LINKED_PROGRAM_ID");
            assert_eq!(super::linked::program_id(), Some(id));
            let tables = super::linked::describe_tables().expect("placeholder tables");
            assert!(
                tables.contains(&format!("{id:016X}")),
                "unexpected: {tables}"
            );
            assert!(tables.contains("interface ABI 5"), "unexpected: {tables}");
            let code = super::linked::code().expect("tables for the build-time title ID");
            // The stand-in tables carry a layout-compatible interface version, so
            // Zakuro turns them into a Library; they hold no code.
            let library = zakuro_core::recompiled::Library::linked(&code)
                .expect("accepted interface version");
            assert_eq!(library.describe(), "0 entry points, 0 modules");
        }
        #[cfg(not(feature = "linked"))]
        {
            assert_eq!(zk_linked_code(), 0);
            assert_eq!(zk_linked_program_id(), 0);
        }
    }

    #[cfg(feature = "linked")]
    #[test]
    fn linked_abi_mismatch_is_refused() {
        use zakuro_core::recompiled::{Library, Linked};

        // Interface version 3 is older than the oldest one Zakuro accepts, so a
        // `Linked` built for it is refused and the loader interprets instead.
        // SAFETY: the pointers are never read; the version is checked first.
        let old = unsafe { Linked::new(0, 3, ptr::null(), 0, ptr::null(), 0) };
        let error = match Library::linked(&old) {
            Ok(_) => panic!("interface version 3 must be refused"),
            Err(error) => error,
        };
        assert!(error.contains("version"), "unexpected: {error}");
    }

    #[test]
    fn timers_start_at_zero() {
        // No frame has run on this test's account, so nothing to report yet.
        // Other tests never call the frame entry points (there is no ROM).
        assert_eq!(zk_last_frame_micros(), 0);
        assert_eq!(zk_last_screen_read_micros(0), 0);
        assert_eq!(zk_last_screen_read_micros(1), 0);
        assert_eq!(zk_last_audio_take_micros(), 0);
    }

    #[test]
    fn null_handle_status_is_readable() {
        let text = status_text(ptr::null_mut());
        assert!(text.contains("no system"), "unexpected: {text}");
    }

    #[test]
    fn hardware_switch_round_trips() {
        // The build default (AUTO) is whatever `ZAKURO_IOS_HARDWARE` said at
        // compile time; a run-time call pins it either way for the next load.
        assert_eq!(zk_set_hardware_renderer(1), 0);
        assert!(super::hardware_requested());
        assert_eq!(zk_set_hardware_renderer(0), 0);
        assert!(!super::hardware_requested());
        // Leave the build default for the other tests, which need no device.
        super::HARDWARE_SETTING.store(super::HARDWARE_AUTO, std::sync::atomic::Ordering::Relaxed);
    }

    #[test]
    fn hardware_status_without_a_system_is_readable() {
        let text = hardware_status(ptr::null_mut());
        assert!(text.contains("no system"), "unexpected: {text}");
    }

    /// The cheapest proof that `ash` can make a Vulkan device at all on the
    /// build that ships to the device: run it on a machine with Vulkan or
    /// MoltenVK installed, before an IPA, with
    /// `cargo test -p zakuro-ios --lib -- --ignored hardware_probe_makes_a_device`.
    /// A machine without Vulkan fails it by design, which is why it is ignored.
    #[test]
    #[ignore = "needs Vulkan/MoltenVK on the host"]
    fn hardware_probe_makes_a_device() {
        assert_eq!(
            super::zk_hardware_probe(),
            0,
            "{}",
            last_error_text().unwrap_or_default()
        );
    }

    #[test]
    fn hardware_options_are_a_whitelist() {
        // A known switch takes a value, then unsets it again with NULL.
        assert_eq!(
            zk_set_hardware_option(c"gpu_shaders".as_ptr(), c"1".as_ptr()),
            0
        );
        assert_eq!(std::env::var("ZAKURO_GPU_SHADERS").as_deref(), Ok("1"));
        assert_eq!(
            zk_set_hardware_option(c"gpu_shaders".as_ptr(), ptr::null()),
            0
        );
        assert!(std::env::var_os("ZAKURO_GPU_SHADERS").is_none());

        // Unknown or missing names are errors, not silent no-ops.
        clear_last_error();
        assert_eq!(
            zk_set_hardware_option(c"no_such_option".as_ptr(), ptr::null()),
            -1
        );
        let message = last_error_text().expect("an unknown option must set an error");
        assert!(message.contains("unknown option"), "unexpected: {message}");
        assert_eq!(zk_set_hardware_option(ptr::null(), ptr::null()), -1);
    }

    #[test]
    fn vulkan_library_requires_a_path() {
        clear_last_error();
        assert_eq!(zk_set_vulkan_library(ptr::null()), -1);
        let message = last_error_text().expect("a NULL path must set an error");
        assert!(message.contains("path is NULL"), "unexpected: {message}");
    }

    #[test]
    fn profiler_ffi_needs_a_handle() {
        assert_eq!(zk_profiler_start(ptr::null_mut()), -1);
        // A NULL handle has no samples, and the formatter must not invent any.
        assert_eq!(hot_spots_text(ptr::null_mut(), 3), "");
    }

    /// A `System` with no ROM, enough to exercise the status/diagnostic handle
    /// paths without emulation. The placeholder linked tables stand in for the
    /// generated archive, which only a real build links.
    #[cfg(feature = "linked")]
    fn placeholder_system() -> Box<System> {
        let mut system = Box::new(System::new(Config::default()));
        system.config.linked =
            Some(super::linked::code().expect("placeholder tables and build-time title ID"));
        system
    }

    #[cfg(feature = "linked")]
    fn handle_of(system: &mut System) -> *mut c_void {
        system as *mut System as *mut c_void
    }

    #[cfg(feature = "linked")]
    #[test]
    fn linked_status_distinguishes_interpreter_and_aot() {
        use zakuro_core::recompiled::Library;

        let mut system = placeholder_system();
        let handle = handle_of(&mut system);
        // `Config.linked` set but no library accepted yet: the loader would
        // interpret everything, and the status names the linked title.
        assert_eq!(zk_recompiled(handle), 0);
        let text = status_text(handle);
        assert!(text.contains("interpreting"), "unexpected: {text}");
        assert!(
            text.contains(&format!("{:016X}", zk_linked_program_id())),
            "unexpected: {text}"
        );

        // What the loader does on acceptance: the same handle reports AOT, and
        // the placeholder tables are described as empty, not invented.
        let code = system.config.linked.expect("placeholder tables");
        system.recompiled = Some(
            Library::linked(&code).expect("placeholder tables carry a usable interface version"),
        );
        assert_eq!(zk_recompiled(handle), 1);
        let text = status_text(handle);
        assert!(text.contains("AOT active"), "unexpected: {text}");
        assert!(
            text.contains("0 entry points, 0 modules"),
            "unexpected: {text}"
        );
    }

    #[cfg(feature = "linked")]
    #[test]
    fn linked_refusal_reason_reaches_status() {
        let mut system = placeholder_system();
        let handle = handle_of(&mut system);
        set_linked_refusal("it was built for version 3 of the interface, this is 5");
        let text = status_text(handle);
        clear_linked_refusal();
        assert!(text.contains("version 3"), "unexpected: {text}");
    }

    /// Serializes the tests that change the process-wide render scale: the test
    /// harness runs them in parallel, and the scale is one atomic for the whole
    /// process.
    static RENDER_SCALE_TEST_LOCK: Mutex<()> = Mutex::new(());

    /// Puts the render scale back to its default when a test ends, including
    /// while a failing test unwinds, so every section starts from 1x.
    struct RenderScaleReset;

    impl Drop for RenderScaleReset {
        fn drop(&mut self) {
            RENDER_SCALE.store(DEFAULT_RENDER_SCALE, Ordering::Relaxed);
        }
    }

    /// The render-scale tests' serial section, with the default restored on exit.
    fn render_scale_test_section() -> (MutexGuard<'static, ()>, RenderScaleReset) {
        let guard = RENDER_SCALE_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        (guard, RenderScaleReset)
    }

    #[test]
    fn render_scale_defaults_to_one() {
        let (_section, _reset) = render_scale_test_section();
        assert_eq!(DEFAULT_RENDER_SCALE, 1);
        assert_eq!(RENDER_SCALE.load(Ordering::Relaxed), 1);
        assert_eq!(render_scale(), 1);
    }

    #[test]
    fn render_scale_accepts_one_to_four() {
        let (_section, _reset) = render_scale_test_section();
        for scale in MIN_RENDER_SCALE..=MAX_RENDER_SCALE {
            assert_eq!(
                zk_set_render_scale(scale),
                0,
                "scale {scale} must be accepted"
            );
            assert_eq!(render_scale(), scale);
            assert!(store_render_scale(scale));
        }
    }

    #[test]
    fn render_scale_rejects_values_outside_one_to_four() {
        let (_section, _reset) = render_scale_test_section();
        assert_eq!(zk_set_render_scale(2), 0);
        for scale in [0u32, MAX_RENDER_SCALE + 1, 5, 100, u32::MAX] {
            clear_last_error();
            assert_eq!(
                zk_set_render_scale(scale),
                -1,
                "scale {scale} must be refused"
            );
            let message = last_error_text().expect("a refused scale must set an error");
            assert!(message.contains("outside 1..=4"), "unexpected: {message}");
            assert_eq!(
                render_scale(),
                2,
                "a refused scale must not replace the stored one"
            );
        }
    }

    #[test]
    fn render_scale_reading_clamps_a_corrupt_setting() {
        let (_section, _reset) = render_scale_test_section();
        RENDER_SCALE.store(0, Ordering::Relaxed);
        assert_eq!(render_scale(), MIN_RENDER_SCALE);
        RENDER_SCALE.store(MAX_RENDER_SCALE + 1, Ordering::Relaxed);
        assert_eq!(render_scale(), MAX_RENDER_SCALE);
    }
}
