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
//! Zakuro's own `log` records (the loader's linked-code warnings, GPU warnings)
//! are forwarded to stderr by [`zk_create`], because an iOS app installs no
//! logger and they would otherwise be dropped.

use std::cell::RefCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::ptr;
use std::sync::Mutex;
use std::time::Instant;

use zakuro_common::Screen;
use zakuro_core::loader;
use zakuro_core::services::hid::{InputState, PadState};
use zakuro_core::{Config, FrameOutcome, System};

mod perf;

thread_local! {
    /// Last `zk_create` failure on the current thread; empty when there is none.
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

/// Records why the linked tables cannot be run.
///
/// Only a `linked` build can discover such a reason, so the interpreter-only
/// build does not carry the function (the status path still reads the note).
#[cfg(feature = "linked")]
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
        _ if !cfg!(feature = "linked") => "this is the interpreter-only build".to_owned(),
        (None, _) => "this linked build handed no code to the loader".to_owned(),
        (Some(linked), Some(rom)) if linked != rom => {
            format!("the code linked in is for title {linked:016X}, but the ROM is {rom:016X}")
        }
        (Some(_), _) => linked_refusal().unwrap_or_else(|| {
            "the loader did not accept the linked code; check the zk[WARN] lines above".to_owned()
        }),
    };
    eprintln!("zk_create: AOT inactive: interpreting everything: {reason}");
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

/// 1 when this static library was built with one game's recompiled code linked
/// in (`--features linked`, see `scripts/AOT_BUILD.md`), 0 for the interpreter-only shell.
#[no_mangle]
pub extern "C" fn zk_linked_code() -> i32 {
    if cfg!(feature = "linked") {
        1
    } else {
        0
    }
}

/// The 3DS title ID (`0004xxxxxxxxxxxx`) the linked recompiled code was built
/// from, or 0 when this library has no linked code.
///
/// The loader compares it with the title in the ROM: a mismatch logs a warning
/// and interprets everything rather than running code meant for another game.
#[no_mangle]
pub extern "C" fn zk_linked_program_id() -> u64 {
    #[cfg(feature = "linked")]
    let id = linked::program_id().unwrap_or(0);
    #[cfg(not(feature = "linked"))]
    let id = 0;
    id
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
    config.hardware_renderer = false;
    config.texture_packs = false;
    // iOS forbids executable memory: no JIT, no recompiled-code discovery here.
    config.find_recompiled = false;

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
    use std::ffi::{c_char, c_void, CStr};
    use std::ptr;

    #[cfg(feature = "linked")]
    use zakuro_core::{Config, System};

    use super::{
        clear_last_error, set_last_error, zk_create, zk_last_audio_take_micros, zk_last_error,
        zk_last_frame_micros, zk_last_screen_read_micros, zk_linked_code, zk_linked_program_id,
        zk_profiler_hot_spots, zk_profiler_start, zk_recompiled, zk_recompiled_status,
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
}
