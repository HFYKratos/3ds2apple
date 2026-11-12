//! Saved states: writing the whole console out and putting it back.
//!
//! Zakuro serializes a running console between frames with [`System::save_state`]
//! and restores it with [`System::load_state`]: CPU, kernel objects, services,
//! GPU registers and programs, and the four physical memories, one compressed
//! blob. The app uses that for instant save slots; this module is the C ABI
//! around the pair and a size/copy protocol that goes with it.
//!
//! ## The size -> copy -> load protocol
//!
//! A saved state is tens of MiB and its compressed size is only known once it
//! has been written, so the app cannot guess a buffer:
//!
//! 1. [`zk_save_state_size`] serializes the console once and returns the byte
//!    count. The blob is kept in this module, so the following copy does not
//!    serialize a second time.
//! 2. [`zk_save_state_copy`] copies exactly the snapshot whose size was
//!    measured, and returns its length. A buffer that is too small copies what
//!    fits, is logged, and returns the full length so the app can retry; the
//!    kept blob makes the retry cheap. A complete copy releases it.
//! 3. [`zk_load_state`] validates the container and hands the blob to Zakuro.
//!
//! The kept blob is a snapshot of the console as it was when
//! [`zk_save_state_size`] ran; running frames or loading another state
//! afterwards does not change the bytes it holds. It is released by a complete
//! copy, [`zk_save_state_discard`], a load, `zk_destroy`, and by the next
//! measurement of any handle, so an abandoned save cannot hold tens of MiB
//! forever.
//!
//! ## Threading and errors
//!
//! Every function here that takes a handle follows the rest of the C ABI: the
//! caller runs it on the runtime's serial queue, between frames (the app pauses
//! its frame loop for a save or a load). A failure returns 0 or a negative code
//! with a readable message in [`zk_last_error`] on the calling thread; a
//! success clears that thread's last error.

use std::ffi::c_void;
use std::ptr;
use std::sync::{Mutex, MutexGuard};
use std::time::Instant;

use zakuro_core::System;

use crate::{clear_last_error, set_last_error};

/// The largest saved state, in bytes, this ABI carries in either direction.
///
/// The raw console memories are at most a New3DS's 256 MiB FCRAM plus 6 MiB of
/// VRAM and 1 MiB of DSP RAM/AXI WRAM, so a state that claims more is a damaged
/// length field or a caller bug, not something to hand to the allocator.
///
/// Mirrored by `ZK_SAVE_STATE_MAX_BYTES` in `ios/ZakuroBridge.h`.
pub const ZK_SAVE_STATE_MAX_BYTES: usize = 512 * 1024 * 1024;

/// The most the state's metadata section may unpack to, in bytes: the CPU,
/// kernel, services and GPU state, everything that is not one of the four
/// memories. A real state's metadata is far smaller (hundreds of KiB for an
/// empty console); a bigger claim is a damaged length field and would otherwise
/// ask the decompressor for a buffer that size before it can fail.
const MAX_METADATA_BYTES: usize = 256 * 1024 * 1024;

/// A state measured and kept, so the copy after [`zk_save_state_size`] does not
/// serialize the console a second time.
struct KeptState {
    /// The `zk_system_t` address the blob was serialized from. A handle is only
    /// compared with this; the blob is an owned `Vec` and never points into the
    /// `System`.
    system: usize,
    bytes: Vec<u8>,
}

static KEPT_STATE: Mutex<Option<KeptState>> = Mutex::new(None);

/// The kept-state slot, even if an earlier call panicked while holding it.
///
/// No panic may cross the C ABI; a poisoned lock only means some unrelated
/// caller panicked, and the `Vec` behind it is still whole. Taking the inner
/// value keeps a poisoned slot from turning every later save into a panic.
fn kept() -> MutexGuard<'static, Option<KeptState>> {
    KEPT_STATE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Keeps `bytes` as the state measured for `system`, releasing any previous one.
fn keep(system: *mut c_void, bytes: Vec<u8>) {
    *kept() = Some(KeptState {
        system: system as usize,
        bytes,
    });
}

/// Releases the kept state when it belongs to `system`.
pub(crate) fn forget(system: *mut c_void) {
    let mut slot = kept();
    if slot
        .as_ref()
        .is_some_and(|kept| kept.system == system as usize)
    {
        *slot = None;
    }
}

/// How many bytes are kept for `system`, or `None` when nothing is.
fn kept_length(system: *mut c_void) -> Option<usize> {
    kept()
        .as_ref()
        .filter(|kept| kept.system == system as usize)
        .map(|kept| kept.bytes.len())
}

/// One decimal place of MiB, for the log lines.
fn mib(bytes: usize) -> f64 {
    bytes as f64 / (1024.0 * 1024.0)
}

/// Serializes the whole console and checks that the blob is a size the ABI can
/// carry.
///
/// Serialization can take from tens of milliseconds to about a second, mostly
/// LZ4-compressing the memories; that is why the blob is kept for the copy.
///
/// # Safety
///
/// `system` must be a live handle from `zk_create`, and the caller must be on
/// the runtime's serial queue so this is the only access to the `System`.
unsafe fn serialize(system: *mut System) -> Result<Vec<u8>, String> {
    // SAFETY: the C ABI's serial-queue rule means no other `&mut System` exists
    // while this call runs; `save_state` takes `&mut self` and the reference
    // does not outlive the call.
    let bytes = unsafe { &mut *system }
        .save_state()
        .map_err(|error| format!("the runtime could not write a state: {error}"))?;
    if bytes.len() > ZK_SAVE_STATE_MAX_BYTES {
        return Err(format!(
            "the state is {} bytes, more than the C ABI accepts \
             ({ZK_SAVE_STATE_MAX_BYTES})",
            bytes.len()
        ));
    }
    Ok(bytes)
}

/// Serializes the console, logs it and keeps the blob as the measurement for
/// `system`.
fn measure(system: *mut c_void, operation: &str) -> Result<usize, String> {
    let started = Instant::now();
    // SAFETY: the entry point checked the handle and the serial-queue rule.
    let bytes = unsafe { serialize(system as *mut System) }?;
    let length = bytes.len();
    eprintln!(
        "{operation}: a state of {length} bytes ({:.1} MiB) in {} ms",
        mib(length),
        started.elapsed().as_millis()
    );
    keep(system, bytes);
    Ok(length)
}

/// Reports a failure with the same text in the log and in `zk_last_error`, and
/// returns `value`.
fn fail(value: usize, operation: &str, error: &str) -> usize {
    let message = format!("{operation}: {error}");
    eprintln!("{message}");
    set_last_error(message);
    value
}

/// Bytes a saved state of `system` takes, 0 on failure.
///
/// Serializes the console once and keeps the blob for [`zk_save_state_copy`].
/// Call it between frames, on the runtime's serial queue, with the frame loop
/// paused: the blob is the console as it was at this call.
///
/// Returns 0 with the reason in [`zk_last_error`] for a NULL handle, a state the
/// runtime could not write, or a state larger than [`ZK_SAVE_STATE_MAX_BYTES`].
/// A success clears the calling thread's last error.
#[no_mangle]
pub extern "C" fn zk_save_state_size(system: *mut c_void) -> usize {
    if system.is_null() {
        return fail(0, "zk_save_state_size", "the system handle is NULL");
    }
    match measure(system, "zk_save_state_size") {
        Ok(length) => {
            clear_last_error();
            length
        }
        Err(error) => {
            // A failed measurement must not leave an older blob behind: the app
            // sizes its buffer from this call, and a copy of the older state
            // would be a different console.
            forget(system);
            fail(0, "zk_save_state_size", &error)
        }
    }
}

/// Copies the measured saved state into `out` and returns its full length.
///
/// With `out == NULL` (or `capacity == 0`) it only reports the length and keeps
/// the blob. With a buffer it copies `min(capacity, length)` bytes: a short
/// buffer is logged and the kept blob stays for a retry with the full length, a
/// complete copy releases it (see [`zk_save_state_discard`] for abandoning a
/// measured state). `out` must point to `capacity` writable bytes, the same
/// contract as [`zk_read_screen`].
///
/// When no blob is kept for `system` (no [`zk_save_state_size`] call, or the
/// kept one belongs to another handle) the console is serialized here first, so
/// a copy into an already large enough buffer works on its own.
///
/// Returns 0 with the reason in [`zk_last_error`] on failure; a real state is
/// never 0 bytes long.
#[no_mangle]
pub extern "C" fn zk_save_state_copy(system: *mut c_void, out: *mut u8, capacity: usize) -> usize {
    if system.is_null() {
        return fail(0, "zk_save_state_copy", "the system handle is NULL");
    }
    let measured = kept_length(system).is_some();
    if !measured {
        if let Err(error) = measure(system, "zk_save_state_copy") {
            return fail(0, "zk_save_state_copy", &error);
        }
    }
    let mut slot = kept();
    let Some(state) = slot
        .as_mut()
        .filter(|state| state.system == system as usize)
    else {
        // Cannot happen: the measurement above either failed (and returned) or
        // stored the blob. Report it instead of panicking across the FFI.
        return fail(
            0,
            "zk_save_state_copy",
            "internal error: the measured state went missing",
        );
    };
    let length = state.bytes.len();
    if out.is_null() || capacity == 0 {
        clear_last_error();
        return length;
    }
    let copied = length.min(capacity);
    // SAFETY: `out` is non-NULL and the C ABI contract has the caller provide
    // `capacity` writable bytes there (the same contract as `zk_read_screen`);
    // `copied <= capacity`. The source is this module's own `Vec`, so it cannot
    // overlap the caller's buffer.
    unsafe { ptr::copy_nonoverlapping(state.bytes.as_ptr(), out, copied) };
    if copied == length {
        *slot = None;
        clear_last_error();
    } else {
        // A short read is not a failure: the length is what the app needs to
        // retry, and the kept blob makes that retry cheap. Say both numbers so
        // the device log shows what buffer would have been needed.
        eprintln!(
            "zk_save_state_copy: the buffer holds {capacity} bytes and the state is {length}; \
             {copied} bytes copied, the state was kept: retry with a {length}-byte buffer or \
             call zk_save_state_discard"
        );
        clear_last_error();
    }
    length
}

/// Releases the state [`zk_save_state_size`]/[`zk_save_state_copy`] kept for
/// `system`, without copying it.
///
/// The kept blob is the size of the state (tens of MiB), so call this when a
/// measured state is abandoned instead of copied. A complete copy, a load, a
/// destroy and the next measurement release it too. Safe to call with a NULL
/// handle, which does nothing.
#[no_mangle]
pub extern "C" fn zk_save_state_discard(system: *mut c_void) {
    if system.is_null() {
        return;
    }
    forget(system);
    clear_last_error();
}

/// How [`zk_load_state`] reports its result; mirrored by the `ZK_LOAD_STATE_*`
/// constants in `ios/ZakuroBridge.h`.
///
/// Any other negative value would also mean failure; these are the ones the ABI
/// documents and returns.
pub const ZK_LOAD_STATE_LOADED: i32 = 0;
/// The `system` handle was NULL (or not a live handle this ABI made).
pub const ZK_LOAD_STATE_BAD_HANDLE: i32 = -1;
/// The data pointer or length was impossible: NULL data with a length, or a
/// length past [`ZK_SAVE_STATE_MAX_BYTES`].
pub const ZK_LOAD_STATE_BAD_ARGUMENT: i32 = -2;
/// The blob was read but is not a state this console can take: another game,
/// another Zakuro version, a different console model, or damaged/truncated
/// bytes. Nothing was applied.
pub const ZK_LOAD_STATE_REFUSED: i32 = -3;

/// Loads a saved state back into `system`.
///
/// Returns [`ZK_LOAD_STATE_LOADED`] (0) on success or a negative code:
/// [`ZK_LOAD_STATE_BAD_HANDLE`], [`ZK_LOAD_STATE_BAD_ARGUMENT`] or
/// [`ZK_LOAD_STATE_REFUSED`]. The reason is in [`zk_last_error`] on the calling
/// thread; a success clears it.
///
/// The container is checked before Zakuro reads it (magic, truncation, section
/// lengths, the four memory sizes): a truncated or damaged file is refused
/// without a many-gigabyte allocation request and without touching the running
/// console. Zakuro itself then checks the state's format version and title ID,
/// and applies nothing unless the whole state was read and accepted.
///
/// Call it between frames on the runtime's serial queue. The app should drop
/// the audio it buffered before the load (the DSP went back too) and let the
/// next frame redraw; the state includes the GPU's guest-side state, and on the
/// hardware paths the host GPU state is rebuilt from the restored memory.
#[no_mangle]
pub extern "C" fn zk_load_state(system: *mut c_void, data: *const u8, length: usize) -> i32 {
    if system.is_null() {
        set_last_error("zk_load_state: the system handle is NULL");
        return ZK_LOAD_STATE_BAD_HANDLE;
    }
    if length == 0 {
        set_last_error("zk_load_state: the state is empty");
        return ZK_LOAD_STATE_REFUSED;
    }
    if data.is_null() {
        set_last_error("zk_load_state: data is NULL but the length is not 0");
        return ZK_LOAD_STATE_BAD_ARGUMENT;
    }
    if length > ZK_SAVE_STATE_MAX_BYTES {
        set_last_error(format!(
            "zk_load_state: {length} bytes is more than the C ABI accepts \
             ({ZK_SAVE_STATE_MAX_BYTES}); the length is probably wrong"
        ));
        return ZK_LOAD_STATE_BAD_ARGUMENT;
    }
    // A state kept for this handle is the console before the load; the app must
    // not copy it afterwards as if it were the console's current state.
    forget(system);
    // SAFETY: `data` is non-NULL and the C ABI contract has the caller keep
    // `length` readable bytes there for the duration of the call; the slice is
    // only borrowed here and never retained.
    let state = unsafe { std::slice::from_raw_parts(data, length) };
    // What this console's memories are, to check the state's sections before
    // Zakuro trusts their length fields.
    let memories = {
        // SAFETY: a live handle on the runtime's serial queue; read-only, and
        // the reference ends before the mutable borrow `load_state` takes.
        let system = unsafe { &*(system as *const System) };
        memory_sizes(system)
    };
    if let Err(error) = preflight(state, memories) {
        set_last_error(format!("zk_load_state: the state was refused: {error}"));
        return ZK_LOAD_STATE_REFUSED;
    }
    let started = Instant::now();
    // SAFETY: the entry point checked the handle; the read-only reference above
    // ended; the serial-queue rule means no other call is running; the caller
    // buffer is only read.
    match unsafe { &mut *(system as *mut System) }.load_state(state) {
        Ok(()) => {
            eprintln!(
                "zk_load_state: loaded {length} bytes ({:.1} MiB) in {} ms",
                mib(length),
                started.elapsed().as_millis()
            );
            clear_last_error();
            ZK_LOAD_STATE_LOADED
        }
        Err(error) => {
            let message = format!("zk_load_state: the runtime refused the state: {error}");
            eprintln!("{message}");
            set_last_error(message);
            ZK_LOAD_STATE_REFUSED
        }
    }
}

/// The sizes the four memory sections of a state must unpack to for `system`.
///
/// Taken from the live console, so the check follows the console model the
/// system was made with instead of assuming one.
fn memory_sizes(system: &System) -> [usize; 4] {
    let physical = &system.memory.phys;
    [
        physical.fcram.len(),
        physical.vram.len(),
        physical.dsp_ram.len(),
        physical.axi_wram.len(),
    ]
}

/// The magic a saved state starts with (`crates/zakuro-core/src/state/mod.rs`).
const MAGIC: &[u8; 8] = b"ZAKUROST";

/// Checks a saved state's container before Zakuro reads it.
///
/// Zakuro's own reader rejects a damaged state, but it trusts length fields
/// first: a corrupt size inside a section can ask LZ4 for a buffer of gigabytes
/// before it discovers the bytes are damaged, and on iOS that allocation can
/// kill the app. This walks the same container as Zakuro's
/// `crates/zakuro-core/src/state/mod.rs`: the magic, the version string, the
/// title ID, then five sections (the `postcard` metadata, then FCRAM, VRAM, DSP
/// RAM and AXI WRAM), each a little-endian `u64` of compressed bytes followed
/// by them, together exactly the blob. The metadata may not claim more than
/// [`MAX_METADATA_BYTES`], and the memories must unpack to the sizes this
/// console has.
///
/// This is a preflight, not the load: a state that passes is still fully
/// validated by Zakuro, which also checks the format version and the title ID.
/// A state failing here is refused with a readable reason and without touching
/// the running console.
fn preflight(state: &[u8], memories: [usize; 4]) -> Result<(), String> {
    let mut reader = Reader { bytes: state };
    if reader.take(MAGIC.len())? != MAGIC {
        return Err("it is not a saved state (the magic is wrong)".to_owned());
    }
    // Format version: a byte length and that many bytes. A state from another
    // Zakuro version reads fine here and is refused by Zakuro's own version
    // check, which has the version string to compare.
    let version_length = reader.u32()? as usize;
    reader.take(version_length)?;
    // The title ID: Zakuro refuses a state from another game itself.
    reader.u64()?;

    let metadata = decompressed_size(reader.section()?)?;
    if metadata > MAX_METADATA_BYTES {
        return Err(format!(
            "its metadata claims {metadata} bytes, more than a saved state's can be \
             ({MAX_METADATA_BYTES})"
        ));
    }
    for (index, expected) in memories.iter().enumerate() {
        let size = decompressed_size(reader.section()?)?;
        if size != *expected {
            return Err(format!(
                "its memory {} unpacks to {size} bytes, and this console's is {expected}",
                index + 1
            ));
        }
    }
    if !reader.bytes.is_empty() {
        return Err(format!(
            "it has {} bytes after its last section",
            reader.bytes.len()
        ));
    }
    Ok(())
}

/// How many bytes a compressed section unpacks to.
///
/// `lz4_flex::compress_prepend_size`, which Zakuro writes every section with,
/// stores the original length first, little endian.
fn decompressed_size(section: &[u8]) -> Result<usize, String> {
    let Some(size) = section.get(..4) else {
        return Err("a section is too short to hold its size".to_owned());
    };
    Ok(u32::from_le_bytes([size[0], size[1], size[2], size[3]]) as usize)
}

/// Reads a saved state's container from the start on.
struct Reader<'a> {
    bytes: &'a [u8],
}

impl<'a> Reader<'a> {
    /// The next `length` bytes, or an error that says the state is truncated.
    fn take(&mut self, length: usize) -> Result<&'a [u8], String> {
        if self.bytes.len() < length {
            return Err("the state ends early".to_owned());
        }
        let (taken, rest) = self.bytes.split_at(length);
        self.bytes = rest;
        Ok(taken)
    }

    fn u32(&mut self) -> Result<u32, String> {
        let bytes = self.take(4)?;
        Ok(u32::from_le_bytes(
            bytes.try_into().map_err(|_| "the state ends early")?,
        ))
    }

    fn u64(&mut self) -> Result<u64, String> {
        let bytes = self.take(8)?;
        Ok(u64::from_le_bytes(
            bytes.try_into().map_err(|_| "the state ends early")?,
        ))
    }

    /// A section: a little-endian `u64` of compressed bytes, then those bytes.
    fn section(&mut self) -> Result<&'a [u8], String> {
        let length = self.u64()?;
        let length = usize::try_from(length).map_err(|_| "a section is too long")?;
        self.take(length)
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::{c_void, CStr};
    use std::ptr;
    use std::sync::Mutex;

    use zakuro_core::{Config, System};

    use super::{
        kept_length, zk_load_state, zk_save_state_copy, zk_save_state_discard, zk_save_state_size,
        ZK_LOAD_STATE_BAD_ARGUMENT, ZK_LOAD_STATE_BAD_HANDLE, ZK_LOAD_STATE_LOADED,
        ZK_LOAD_STATE_REFUSED, ZK_SAVE_STATE_MAX_BYTES,
    };

    /// A `System` is a 128 MiB FCRAM plus the rest, and a save/load copies it,
    /// so the tests that make one take the lock and run one at a time: the
    /// suite then works on a machine with several GiB free and a few hundred
    /// MiB peak, not on one system per test thread.
    static BIG_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn big_test_lock() -> std::sync::MutexGuard<'static, ()> {
        BIG_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Copies the calling thread's last error, if any.
    fn last_error() -> Option<String> {
        let pointer = crate::zk_last_error();
        if pointer.is_null() {
            return None;
        }
        // SAFETY: the pointer comes from `zk_last_error` and stays valid until
        // the next call that records an error on this thread; read immediately.
        Some(
            unsafe { CStr::from_ptr(pointer) }
                .to_string_lossy()
                .into_owned(),
        )
    }

    /// The handle value of a test `System` that stays owned by the box.
    fn handle_of(system: &mut System) -> *mut c_void {
        system as *mut System as *mut c_void
    }

    /// An empty console: `save_state` and `load_state` work on it, and it needs
    /// no ROM, so the host tests can exercise the real serialization.
    fn empty_system() -> Box<System> {
        Box::new(System::new(Config::default()))
    }

    /// Saves `system` through the ABI and returns the state bytes.
    fn save(handle: *mut c_void) -> Vec<u8> {
        let length = zk_save_state_size(handle);
        assert!(length > 0, "{}", last_error().unwrap_or_default());
        let mut bytes = vec![0u8; length];
        assert_eq!(
            zk_save_state_copy(handle, bytes.as_mut_ptr(), bytes.len()),
            length
        );
        bytes
    }

    /// `(offset of the length field, compressed length)` of each of the five
    /// sections of a state this library wrote, out of the container alone.
    fn sections(state: &[u8]) -> Vec<(usize, usize)> {
        let mut at = 8;
        let version_length =
            u32::from_le_bytes(state[at..at + 4].try_into().expect("4 bytes")) as usize;
        at += 4 + version_length + 8;
        let mut sections = Vec::with_capacity(5);
        for _ in 0..5 {
            let length =
                u64::from_le_bytes(state[at..at + 8].try_into().expect("8 bytes")) as usize;
            sections.push((at, length));
            at += 8 + length;
        }
        assert_eq!(at, state.len(), "a state is its sections and nothing else");
        sections
    }

    /// Overwrites the uncompressed size stored at the front of a section.
    fn patch_section_size(state: &mut [u8], section: usize, size: u32) {
        let (offset, length) = sections(state)[section];
        assert!(length >= 4, "a section holds at least its size");
        state[offset + 8..offset + 12].copy_from_slice(&size.to_le_bytes());
    }

    /// The title ID's offset in a state's header.
    fn title_id_offset(state: &[u8]) -> usize {
        let version_length = u32::from_le_bytes(state[8..12].try_into().expect("4 bytes")) as usize;
        8 + 4 + version_length
    }

    #[test]
    fn null_handles_are_reported() {
        crate::clear_last_error();
        assert_eq!(zk_save_state_size(ptr::null_mut()), 0);
        assert!(last_error().unwrap_or_default().contains("NULL"));

        assert_eq!(zk_save_state_copy(ptr::null_mut(), ptr::null_mut(), 0), 0);
        assert!(last_error().unwrap_or_default().contains("NULL"));

        assert_eq!(
            zk_load_state(ptr::null_mut(), ptr::null(), 16),
            ZK_LOAD_STATE_BAD_HANDLE
        );
        assert!(last_error().unwrap_or_default().contains("NULL"));

        // Discard is a cleanup call: a NULL handle is a no-op, not an error.
        crate::clear_last_error();
        zk_save_state_discard(ptr::null_mut());
        assert_eq!(last_error(), None);
    }

    #[test]
    fn state_is_measured_kept_and_copied() {
        let _guard = big_test_lock();
        let mut system = empty_system();
        let handle = handle_of(&mut system);

        crate::clear_last_error();
        let length = zk_save_state_size(handle);
        assert!(
            length > 0,
            "an empty console still saves a state: {}",
            last_error().unwrap_or_default()
        );
        assert!(length <= ZK_SAVE_STATE_MAX_BYTES);
        assert_eq!(last_error(), None, "a success clears the last error");
        assert_eq!(
            kept_length(handle),
            Some(length),
            "the measured state is kept for the copy"
        );

        // A NULL buffer only reports the length and keeps the state.
        assert_eq!(zk_save_state_copy(handle, ptr::null_mut(), 0), length);
        assert_eq!(kept_length(handle), Some(length));

        // A short buffer copies what fits, returns the full length, keeps the
        // state for the retry, and writes nothing past the capacity.
        let capacity = length / 2;
        assert!(capacity > 0, "a state has a header");
        let mut short = vec![0xAAu8; capacity + 32];
        assert_eq!(
            zk_save_state_copy(handle, short.as_mut_ptr(), capacity),
            length
        );
        assert!(
            short[capacity..].iter().all(|&byte| byte == 0xAA),
            "the copy stopped at the capacity"
        );
        assert_eq!(kept_length(handle), Some(length));

        // The retry copies that same kept snapshot and releases it.
        let mut full = vec![0u8; length];
        assert_eq!(
            zk_save_state_copy(handle, full.as_mut_ptr(), full.len()),
            length
        );
        assert_eq!(kept_length(handle), None, "a complete copy releases it");
        assert_eq!(last_error(), None);
        assert_eq!(
            &full[..capacity],
            &short[..capacity],
            "the retry copies the snapshot the size measured"
        );

        // A copy with nothing kept serializes the console itself.
        let mut again = vec![0u8; length];
        assert_eq!(
            zk_save_state_copy(handle, again.as_mut_ptr(), again.len()),
            length
        );
        assert_eq!(kept_length(handle), None);
        assert_eq!(again, full, "saving an unchanged console is repeatable");

        // And discard releases a measured state that will not be copied.
        assert_eq!(zk_save_state_size(handle), length);
        assert_eq!(kept_length(handle), Some(length));
        zk_save_state_discard(handle);
        assert_eq!(kept_length(handle), None);
        assert_eq!(last_error(), None);
    }

    #[test]
    fn load_round_trips_and_refuses_damaged_states() {
        let _guard = big_test_lock();
        let mut source = empty_system();
        let state = save(handle_of(&mut source));

        let mut target = empty_system();
        target.frames = 42;
        let handle = handle_of(&mut target);

        // The whole round trip: the loaded console is the state's.
        crate::clear_last_error();
        assert_eq!(
            zk_load_state(handle, state.as_ptr(), state.len()),
            ZK_LOAD_STATE_LOADED
        );
        assert_eq!(target.frames, 0);
        assert_eq!(last_error(), None, "a success clears the last error");

        // A truncated state is refused and changes nothing.
        target.frames = 7;
        assert_eq!(
            zk_load_state(handle, state.as_ptr(), state.len() / 2),
            ZK_LOAD_STATE_REFUSED
        );
        assert!(
            last_error().unwrap_or_default().contains("ends early"),
            "the refusal says the state is short"
        );
        assert_eq!(target.frames, 7, "a refused state changes nothing");

        // A damaged magic is refused before Zakuro sees the state.
        let mut damaged = state.clone();
        damaged[0] ^= 0xFF;
        assert_eq!(
            zk_load_state(handle, damaged.as_ptr(), damaged.len()),
            ZK_LOAD_STATE_REFUSED
        );
        assert!(last_error()
            .unwrap_or_default()
            .contains("not a saved state"));

        // A damaged section size would ask the decompressor for gigabytes; the
        // preflight refuses it instead.
        let mut huge_memory = state.clone();
        patch_section_size(&mut huge_memory, 1, u32::MAX);
        assert_eq!(
            zk_load_state(handle, huge_memory.as_ptr(), huge_memory.len()),
            ZK_LOAD_STATE_REFUSED
        );
        let message = last_error().unwrap_or_default();
        assert!(message.contains("memory 1"), "unexpected: {message}");
        assert!(
            message.contains(&u32::MAX.to_string()),
            "unexpected: {message}"
        );

        let mut huge_metadata = state.clone();
        patch_section_size(&mut huge_metadata, 0, u32::MAX);
        assert_eq!(
            zk_load_state(handle, huge_metadata.as_ptr(), huge_metadata.len()),
            ZK_LOAD_STATE_REFUSED
        );
        assert!(
            last_error().unwrap_or_default().contains("metadata claims"),
            "unexpected: {:?}",
            last_error()
        );

        // Trailing bytes mean the file is not a whole state.
        let mut trailing = state.clone();
        trailing.push(0);
        assert_eq!(
            zk_load_state(handle, trailing.as_ptr(), trailing.len()),
            ZK_LOAD_STATE_REFUSED
        );
        assert!(last_error()
            .unwrap_or_default()
            .contains("after its last section"));

        // A state from another game is refused by Zakuro itself.
        let mut other_game = state.clone();
        other_game[title_id_offset(&state)] ^= 0xFF;
        assert_eq!(
            zk_load_state(handle, other_game.as_ptr(), other_game.len()),
            ZK_LOAD_STATE_REFUSED
        );
        assert!(
            last_error().unwrap_or_default().contains("another game"),
            "unexpected: {:?}",
            last_error()
        );

        // Arguments that cannot be a state are refused before any read.
        assert_eq!(
            zk_load_state(handle, ptr::null(), 16),
            ZK_LOAD_STATE_BAD_ARGUMENT
        );
        assert_eq!(
            zk_load_state(handle, state.as_ptr(), 0),
            ZK_LOAD_STATE_REFUSED
        );
        assert_eq!(
            zk_load_state(handle, state.as_ptr(), ZK_SAVE_STATE_MAX_BYTES + 1),
            ZK_LOAD_STATE_BAD_ARGUMENT
        );

        // A load releases a state measured before it, even when Zakuro refuses
        // the state after the arguments were accepted.
        let mut discarded = empty_system();
        let discard_handle = handle_of(&mut discarded);
        assert!(zk_save_state_size(discard_handle) > 0);
        assert!(kept_length(discard_handle).is_some());
        assert_eq!(
            zk_load_state(discard_handle, other_game.as_ptr(), other_game.len()),
            ZK_LOAD_STATE_REFUSED
        );
        assert_eq!(kept_length(discard_handle), None);
    }

    #[test]
    fn destroy_releases_the_measured_state() {
        let _guard = big_test_lock();
        let system = empty_system();
        let handle = Box::into_raw(system) as *mut c_void;
        assert!(zk_save_state_size(handle) > 0);
        assert!(kept_length(handle).is_some(), "the measured state is kept");
        // A destroyed handle must not keep its state (tens of MiB) in the
        // library, and must not confuse a later handle that reuses the address.
        crate::zk_destroy(handle);
        assert_eq!(kept_length(handle), None);
    }

    #[test]
    fn abi_limits_are_the_documented_ones() {
        // `ios/ZakuroBridge.h` mirrors these values; changing one means
        // changing the header and this test together.
        assert_eq!(ZK_SAVE_STATE_MAX_BYTES, 512 * 1024 * 1024);
        assert_eq!(super::MAX_METADATA_BYTES, 256 * 1024 * 1024);
    }
}
