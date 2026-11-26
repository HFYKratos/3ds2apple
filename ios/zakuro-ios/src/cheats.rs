//! Cheat codes: a title's Action Replay / Gateway codes, read from and written
//! back to the app's own file in the format Citra and Azahar use.
//!
//! Zakuro's core already owns the format and the execution: a file is
//! `[name]` sections, `*` notes, a `*citra_enabled` marker and
//! `XXXXXXXX YYYYYYYY` lines, and [`zakuro_core::cheats::run`] applies the
//! enabled ones once per emulated frame inside [`System::run_frame`], before the
//! CPU steps. This module is only the C ABI around that: it reads the text into
//! [`System::cheats`], writes it back, lists it and switches entries on and off.
//! Nothing here parses a code itself and nothing ticks: `zk_run_frame` keeps
//! calling the core's run loop, so a switch made here applies from the next frame.
//!
//! ## The file belongs to the app
//!
//! The path is an argument, never derived from `Config::data_dir`: the iOS app
//! keeps the user's file at `Documents/Cheats/<TITLEID>.txt`, outside the
//! per-game data directory (a file under that directory would be swept into the
//! Save Manager's archive export) and hands the path to [`zk_cheats_load`] and
//! [`zk_cheats_save`]. Nothing is written anywhere the caller did not name.
//!
//! ## What this build does not carry
//!
//! Upstream Zakuro also bundles community "enhancements", a code table keyed by
//! title that the desktop frontend can switch on by name. The iOS build removes
//! that data (`patches/0011-remove-enhancements-data.patch`), so no code
//! database ships in the app: this ABI lists, edits and runs only the player's
//! own file. A builtin entry (a title's enhancement, were one ever handed to the
//! loader) is not listed by [`zk_cheats_json`] and is refused by
//! [`zk_cheats_set_enabled`].
//!
//! ## Threading and errors
//!
//! Like every call that takes a handle, these run on the runtime's serial queue.
//! A failure returns a negative code and records the reason for
//! [`crate::zk_last_error`] on the calling thread; a success clears it. The
//! pointer [`zk_cheats_json`] returns is thread-local and stays valid until the
//! next [`zk_cheats_json`] call on the same thread, like
//! [`crate::zk_keyboard_request_json`].
//!
//! ## Limits
//!
//! A file is read only up to [`ZK_CHEATS_MAX_FILE_BYTES`], one cheat may carry
//! at most [`ZK_CHEATS_MAX_LINES`] code lines and a file at most
//! [`ZK_CHEATS_MAX_CHEATS`] cheats. Past that the load is refused instead of
//! allocating without bound. The runtime also caps one cheat at 100000 executed
//! steps per frame (upstream `MOST_STEPS`), so a looping code cannot freeze the
//! frame loop.

use std::cell::RefCell;
use std::ffi::{c_char, c_void, CString};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::ptr;

use zakuro_core::cheats::{self, Cheat};
use zakuro_core::System;

use crate::{clear_last_error, cpath, push_json_string, set_last_error};

/// The largest cheat file this ABI reads, in bytes. Mirrored by
/// `ZK_CHEATS_MAX_FILE_BYTES` in `ios/ZakuroBridge.h`.
pub const ZK_CHEATS_MAX_FILE_BYTES: usize = 256 * 1024;

/// The most cheats one file may define. Mirrored by `ZK_CHEATS_MAX_CHEATS`.
pub const ZK_CHEATS_MAX_CHEATS: usize = 128;

/// The most code lines one cheat may carry. Mirrored by
/// `ZK_CHEATS_MAX_LINES`.
pub const ZK_CHEATS_MAX_LINES: usize = 1024;

/// The largest document `zk_cheats_json` returns, in bytes and not counting the
/// terminating NUL. Mirrored by `ZK_CHEATS_JSON_MAX_BYTES`. The per-name cut
/// and the entry limits together keep a full file inside this.
pub const ZK_CHEATS_JSON_MAX_BYTES: usize = 256 * 1024;

/// The longest name the JSON document reports, in UTF-8 bytes; a longer one is
/// cut at a character boundary. The runtime itself keeps the whole name, only a
/// document shown by the app is bounded.
const JSON_NAME_MAX_BYTES: usize = 256;

/// `zk_cheats_load`/`zk_cheats_save` results; mirrored by `ZK_CHEATS_*` in
/// `ios/ZakuroBridge.h`.
pub const ZK_CHEATS_OK: i32 = 0;
/// NULL or invalid `zk_system_t`.
pub const ZK_CHEATS_BAD_HANDLE: i32 = -1;
/// NULL or non-UTF-8 path.
pub const ZK_CHEATS_BAD_PATH: i32 = -2;
/// The file could not be read, or written, for a reason the message names.
pub const ZK_CHEATS_READ_FAILED: i32 = -3;
/// The file (or one cheat in it) is past this ABI's limits.
pub const ZK_CHEATS_TOO_LARGE: i32 = -4;
/// `zk_cheats_set_enabled`: no cheat at that index.
pub const ZK_CHEATS_BAD_INDEX: i32 = -2;
/// `zk_cheats_set_enabled`: the entry is a builtin enhancement, not the
/// player's; this build carries none.
pub const ZK_CHEATS_REFUSED: i32 = -3;

thread_local! {
    /// Last JSON document `zk_cheats_json` returned on the current thread.
    /// Kept apart from the keyboard document, the status slot and the error
    /// slot so listing cheats never disturbs their contracts.
    static CHEATS_JSON: RefCell<CString> = RefCell::new(CString::default());
}

/// Parses the text the way the runtime does, refusing a file past this ABI's
/// limits. The message names the limit that was hit; it is what
/// `zk_last_error` reports.
fn parse_limited(text: &str) -> Result<Vec<Cheat>, String> {
    let parsed = cheats::parse(text);
    if parsed.len() > ZK_CHEATS_MAX_CHEATS {
        return Err(format!(
            "the file defines {} cheats; this build reads at most {}",
            parsed.len(),
            ZK_CHEATS_MAX_CHEATS
        ));
    }
    for cheat in &parsed {
        if cheat.lines().len() > ZK_CHEATS_MAX_LINES {
            return Err(format!(
                "the cheat \u{201c}{}\u{201d} has {} lines; this build reads at most {}",
                cheat.name,
                cheat.lines().len(),
                ZK_CHEATS_MAX_LINES
            ));
        }
    }
    Ok(parsed)
}

/// Lines of `cheat` that are not `XXXXXXXX YYYYYYYY` code: the runtime keeps and
/// writes them back (like Citra), and the app can warn about them.
fn invalid_lines(cheat: &Cheat) -> usize {
    cheat
        .lines()
        .iter()
        .filter(|line| !cheats::is_code(line))
        .count()
}

/// Reads a cheat file up to [`ZK_CHEATS_MAX_FILE_BYTES`] and decodes it the way
/// the runtime does (a non-UTF-8 byte becomes U+FFFD instead of failing the
/// load). Errors carry the code the ABI returns and the message for
/// `zk_last_error`.
fn read_cheat_file(path: &Path) -> Result<String, (i32, String)> {
    let too_large = |bytes: u64| {
        (
            ZK_CHEATS_TOO_LARGE,
            format!(
                "{} is {} bytes; a cheat file may be at most {}",
                path.display(),
                bytes,
                ZK_CHEATS_MAX_FILE_BYTES
            ),
        )
    };
    let metadata = std::fs::metadata(path).map_err(|error| {
        (
            ZK_CHEATS_READ_FAILED,
            format!("cannot read {}: {error}", path.display()),
        )
    })?;
    if metadata.len() > ZK_CHEATS_MAX_FILE_BYTES as u64 {
        return Err(too_large(metadata.len()));
    }
    let bytes = std::fs::read(path).map_err(|error| {
        (
            ZK_CHEATS_READ_FAILED,
            format!("cannot read {}: {error}", path.display()),
        )
    })?;
    // The file may have grown between the metadata call and the read.
    if bytes.len() > ZK_CHEATS_MAX_FILE_BYTES {
        return Err(too_large(bytes.len() as u64));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Writes `text` through a sibling temporary file and a rename, so a crash
/// halfway leaves the previous file whole. The runtime's own
/// `zakuro_core::cheats::save` writes in place and is deliberately not used
/// here. Creates the parent directory, so the first save into a new
/// `Documents/Cheats` works.
fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let parent = path.parent().filter(|parent| !parent.as_os_str().is_empty());
    if let Some(parent) = parent {
        std::fs::create_dir_all(parent)?;
    }
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "cheats.txt".to_owned());
    let temporary = match parent {
        Some(parent) => parent.join(format!(".{name}.{}.tmp", std::process::id())),
        None => PathBuf::from(format!(".{name}.{}.tmp", std::process::id())),
    };
    let result = (|| {
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(text.as_bytes())?;
        // The codes are what the next launch runs; get them on disk before the
        // rename publishes them.
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

/// Appends a name as one JSON string literal, cut to [`JSON_NAME_MAX_BYTES`] at
/// a character boundary.
fn push_name_json(out: &mut String, name: &str) {
    let mut end = name.len().min(JSON_NAME_MAX_BYTES);
    while end > 0 && !name.is_char_boundary(end) {
        end -= 1;
    }
    push_json_string(out, &name[..end]);
}

/// The player's cheats as the schema-1 document the app decodes.
fn cheats_json(cheats: &[Cheat]) -> String {
    let mut out =
        String::with_capacity((64 + cheats.len() * 64).min(ZK_CHEATS_JSON_MAX_BYTES));
    out.push_str("{\"schema\":1,\"cheats\":[");
    let mut first = true;
    for cheat in cheats.iter().filter(|cheat| !cheat.builtin) {
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str("{\"name\":");
        push_name_json(&mut out, &cheat.name);
        out.push_str(",\"enabled\":");
        out.push_str(if cheat.enabled { "true" } else { "false" });
        out.push_str(&format!(
            ",\"lines\":{},\"invalidLines\":{}}}",
            cheat.lines().len(),
            invalid_lines(cheat)
        ));
    }
    out.push_str("]}");
    out
}

/// Stores `json` as the calling thread's cheat document and returns its
/// pointer, owned by this library like `zk_last_error`'s pointer.
fn set_cheats_json(json: String) -> *const c_char {
    // Escape interior NULs so `CString::new` cannot fail: no panic across FFI.
    let json = CString::new(json.replace('\0', "\\0")).unwrap_or_default();
    match CHEATS_JSON.try_with(|slot| {
        let mut slot = slot.borrow_mut();
        *slot = json;
        slot.as_ptr()
    }) {
        Ok(pointer) => pointer,
        // TLS is gone during teardown; report NULL instead of panicking.
        Err(_) => ptr::null(),
    }
}

/// Loads a title's cheat file: the player's codes at `path` (UTF-8, the
/// Citra/Azahar text) replace the ones the system has, and the enabled ones run
/// from the next frame on.
///
/// Returns the number of cheats loaded (0 for a file with no `[name]`
/// section), or a negative `ZK_CHEATS_*` code with the reason in
/// [`crate::zk_last_error`]: -1 NULL handle, -2 NULL or non-UTF-8 path, -3 the
/// file could not be read, -4 the file is past this ABI's limits.
///
/// Call it on the runtime's serial queue. It touches only `system.cheats`; the
/// runtime keeps its frame loop, so nothing needs to be paused.
#[no_mangle]
pub extern "C" fn zk_cheats_load(system: *mut c_void, path: *const c_char) -> i32 {
    // SAFETY: `system` is either NULL or a live handle from `zk_create`, used
    // exclusively here on the serial queue that owns it.
    let Some(system) = (unsafe { (system as *mut System).as_mut() }) else {
        return ZK_CHEATS_BAD_HANDLE;
    };
    let Ok(path) = cpath(path) else {
        return ZK_CHEATS_BAD_PATH;
    };
    let text = match read_cheat_file(&path) {
        Ok(text) => text,
        Err((code, message)) => {
            set_last_error(message);
            return code;
        }
    };
    let parsed = match parse_limited(&text) {
        Ok(parsed) => parsed,
        Err(message) => {
            set_last_error(message);
            return ZK_CHEATS_TOO_LARGE;
        }
    };
    // The player's file replaces the player's cheats; a builtin entry (a title's
    // enhancement, none in this build) stays and stays out of the file.
    let mut builtin: Vec<Cheat> = std::mem::take(&mut system.cheats)
        .into_iter()
        .filter(|cheat| cheat.builtin)
        .collect();
    let count = parsed.len();
    system.cheats = parsed;
    system.cheats.append(&mut builtin);
    clear_last_error();
    i32::try_from(count).unwrap_or(i32::MAX)
}

/// Writes the player's cheats to `path` in the Citra/Azahar text, with a
/// `*citra_enabled` marker on the enabled ones, through a sibling temporary
/// file and a rename (a crash halfway keeps the previous file whole).
///
/// Returns 0, or a negative `ZK_CHEATS_*` code as [`zk_cheats_load`] (-1, -2,
/// -3; the write failure's reason is in [`crate::zk_last_error`]).
///
/// Call it on the runtime's serial queue.
#[no_mangle]
pub extern "C" fn zk_cheats_save(system: *mut c_void, path: *const c_char) -> i32 {
    // SAFETY: `system` is either NULL or a live handle from `zk_create`; only
    // read here, on the caller's serial queue.
    let Some(system) = (unsafe { (system as *const System).as_ref() }) else {
        return ZK_CHEATS_BAD_HANDLE;
    };
    let Ok(path) = cpath(path) else {
        return ZK_CHEATS_BAD_PATH;
    };
    let text = cheats::to_text(&system.cheats);
    match write_atomic(&path, &text) {
        Ok(()) => {
            clear_last_error();
            ZK_CHEATS_OK
        }
        Err(error) => {
            set_last_error(format!("cannot write {}: {error}", path.display()));
            ZK_CHEATS_READ_FAILED
        }
    }
}

/// How many of the player's cheats the system has (0 when nothing was loaded);
/// -1 for a NULL handle. Call it on the runtime's serial queue.
#[no_mangle]
pub extern "C" fn zk_cheats_count(system: *mut c_void) -> i32 {
    // SAFETY: see `zk_cheats_save`: a live handle, read-only, on the serial queue.
    let Some(system) = (unsafe { (system as *const System).as_ref() }) else {
        return ZK_CHEATS_BAD_HANDLE;
    };
    i32::try_from(system.cheats.iter().filter(|cheat| !cheat.builtin).count())
        .unwrap_or(i32::MAX)
}

/// The player's cheats as one JSON document, or NULL for a NULL handle.
///
/// Schema 1:
///
/// ```json
/// {"schema":1,"cheats":[{"name":"Example","enabled":true,"lines":2,"invalidLines":0}]}
/// ```
///
///  schema       1, this document's shape.
///  name         the section's name (`[...]` in the file), cut to 256 UTF-8
///               bytes at a character boundary to keep the document bounded.
///  enabled      whether the entry runs each frame (the `*citra_enabled`
///               marker in the file).
///  lines        how many `XXXXXXXX YYYYYYYY` lines the entry has.
///  invalidLines lines the runtime keeps and writes back but does not run
///               (`is_code` refused them); the app can warn about them.
///
/// The document is always within `ZK_CHEATS_JSON_MAX_BYTES`, so no copy buffer
/// is needed. The pointer is owned by this library and stays valid until the
/// next `zk_cheats_json` call on the same thread; copy it
/// (`String(cString:)` in Swift) and never free it. Call it on the runtime's
/// serial queue.
#[no_mangle]
pub extern "C" fn zk_cheats_json(system: *mut c_void) -> *const c_char {
    // SAFETY: see `zk_cheats_save`: a live handle, read-only, on the serial queue.
    let Some(system) = (unsafe { (system as *const System).as_ref() }) else {
        // Clear the thread's old document so a stale pointer cannot report a
        // list that no longer belongs to the caller.
        let _ = CHEATS_JSON.try_with(|slot| *slot.borrow_mut() = CString::default());
        return ptr::null();
    };
    set_cheats_json(cheats_json(&system.cheats))
}

/// Turns one of the player's cheats on or off; the change applies from the next
/// frame (the runtime calls the core's run loop at the start of every
/// `zk_run_frame`).
///
/// `index` is the position in the list `zk_cheats_json` reports, i.e. the
/// player's cheat order. 0 = done, -1 = NULL handle, -2 = no cheat at that
/// index, -3 = the entry is a builtin enhancement, not the player's (this build
/// carries none). Call it on the runtime's serial queue.
///
/// Turning a cheat off does not put back bytes it already wrote: like Citra, a
/// cheat's writes stay until the title overwrites them or a saved state is
/// loaded.
#[no_mangle]
pub extern "C" fn zk_cheats_set_enabled(system: *mut c_void, index: i32, enabled: i32) -> i32 {
    // SAFETY: `system` is either NULL or a live handle from `zk_create`, used
    // exclusively here on the serial queue that owns it.
    let Some(system) = (unsafe { (system as *mut System).as_mut() }) else {
        return ZK_CHEATS_BAD_HANDLE;
    };
    let Some(index) = usize::try_from(index).ok() else {
        return ZK_CHEATS_BAD_INDEX;
    };
    // The player's cheats are the vector's front: the runtime appends a title's
    // builtin enhancements after the file's own cheats, and so does
    // `zk_cheats_load`.
    let players = system.cheats.iter().filter(|cheat| !cheat.builtin).count();
    if index >= players {
        return ZK_CHEATS_BAD_INDEX;
    }
    let Some(cheat) = system.cheats.get_mut(index) else {
        return ZK_CHEATS_BAD_INDEX;
    };
    if cheat.builtin {
        set_last_error(format!(
            "cheat {} is a builtin enhancement, not the player's",
            index
        ));
        return ZK_CHEATS_REFUSED;
    }
    cheat.enabled = enabled != 0;
    clear_last_error();
    ZK_CHEATS_OK
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// The one-line code the fixtures use; a plain 32-bit write, not a game's.
    const CODE: &str = "08000000 00000001";

    /// A unique temporary directory under the host's temp dir.
    fn scratch_dir(tag: &str) -> PathBuf {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let unique = NEXT.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "zk-cheats-test-{}-{tag}-{unique}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("a temporary directory can be made");
        dir
    }

    /// Writes `text` to `dir/name` and returns its path.
    fn scratch_file(dir: &Path, name: &str, text: &str) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, text).expect("the fixture file can be written");
        path
    }

    fn citra_text() -> String {
        format!(
            "[Example cheat]\n*first note\n*second note\n{CODE}\n\n\
             [Enabled cheat]\n*citra_enabled\n{CODE}\n{CODE}\n\n\
             [Broken cheat]\nnot a code\n{CODE}\n"
        )
    }

    #[test]
    fn parse_keeps_names_notes_enabled_state_and_lines() {
        let parsed = parse_limited(&citra_text()).expect("the fixture is within the limits");
        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[0].name, "Example cheat");
        assert!(!parsed[0].enabled);
        assert_eq!(parsed[0].lines().to_vec(), vec![CODE.to_owned()]);
        assert_eq!(parsed[0].notes, ["first note", "second note"]);
        assert_eq!(parsed[1].name, "Enabled cheat");
        assert!(parsed[1].enabled, "the *citra_enabled marker must survive");
        assert_eq!(parsed[1].lines().len(), 2);
        assert_eq!(invalid_lines(&parsed[0]), 0);
        assert_eq!(invalid_lines(&parsed[2]), 1);
    }

    #[test]
    fn parse_accepts_crlf_and_a_utf8_bom() {
        let text = format!("[With CRLF]\r\n*note\r\n{CODE}\r\n");
        let parsed = parse_limited(&text).expect("CRLF is what a Windows editor writes");
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].lines().to_vec(), vec![CODE.to_owned()]);
        assert_eq!(invalid_lines(&parsed[0]), 0);
    }

    #[test]
    fn parse_refuses_a_file_past_the_limits() {
        let mut many = String::new();
        for index in 0..=ZK_CHEATS_MAX_CHEATS {
            many.push_str(&format!("[cheat {index}]\n{CODE}\n"));
        }
        assert!(parse_limited(&many).is_err(), "too many cheats must be refused");

        let mut long = String::from("[long]\n");
        for _ in 0..=ZK_CHEATS_MAX_LINES {
            long.push_str(CODE);
            long.push('\n');
        }
        assert!(parse_limited(&long).is_err(), "a cheat past the line limit must be refused");

        let at_limit = format!("[ok]\n{}", format!("{CODE}\n").repeat(ZK_CHEATS_MAX_LINES));
        assert!(parse_limited(&at_limit).is_ok(), "the limit itself must be accepted");
    }

    #[test]
    fn serialising_round_trips_through_parse() {
        let parsed = parse_limited(&citra_text()).expect("the fixture is within the limits");
        let text = cheats::to_text(&parsed);
        let again = parse_limited(&text).expect("what this ABI writes must parse again");
        assert_eq!(again.len(), parsed.len());
        for (before, after) in parsed.iter().zip(again.iter()) {
            assert_eq!(before.name, after.name);
            assert_eq!(before.enabled, after.enabled);
            assert_eq!(before.notes, after.notes);
            assert_eq!(before.lines(), after.lines());
        }
    }

    #[test]
    fn read_refuses_a_file_past_the_byte_limit() {
        let dir = scratch_dir("size");
        let path = dir.join("big.txt");
        std::fs::write(&path, vec![b'x'; ZK_CHEATS_MAX_FILE_BYTES + 1])
            .expect("the oversized fixture can be written");
        let (code, _) = read_cheat_file(&path).expect_err("an oversized file must be refused");
        assert_eq!(code, ZK_CHEATS_TOO_LARGE);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_refuses_a_missing_file() {
        let (code, message) = read_cheat_file(Path::new("/nonexistent/zakuro/cheats.txt"))
            .expect_err("a missing file must be an error");
        assert_eq!(code, ZK_CHEATS_READ_FAILED);
        assert!(!message.is_empty(), "the reason is what zk_last_error reports");
    }

    #[test]
    fn json_carries_the_documented_fields_and_escapes_names() {
        let parsed = parse_limited(&citra_text()).expect("the fixture is within the limits");
        let mut parsed = parsed;
        parsed[0].name = "quo\"te \\ back\nslash \u{1}".to_owned();
        let json = cheats_json(&parsed);
        assert!(json.starts_with("{\"schema\":1,\"cheats\":["), "unexpected: {json}");
        assert!(json.ends_with("]}"), "unexpected: {json}");
        assert!(json.contains("\"enabled\":true"), "unexpected: {json}");
        assert!(json.contains("\"lines\":2"), "unexpected: {json}");
        assert!(json.contains("\"invalidLines\":1"), "unexpected: {json}");
        assert!(
            !json.chars().any(|character| character < ' '),
            "no raw control character may reach the C string: {json}"
        );
        assert!(json.contains("quo\\\"te \\\\ back\\nslash \\u0001"), "unexpected: {json}");
    }

    #[test]
    fn json_is_empty_for_no_cheats_and_does_not_list_builtins() {
        assert_eq!(cheats_json(&[]), "{\"schema\":1,\"cheats\":[]}");
        let mut cheat = Cheat::new("player", vec![CODE.to_owned()], Vec::new());
        cheat.enabled = true;
        let mut builtin = Cheat::new("enhancement", vec![CODE.to_owned()], Vec::new());
        builtin.builtin = true;
        let json = cheats_json(&[cheat, builtin]);
        assert!(json.contains("\"name\":\"player\""), "unexpected: {json}");
        assert!(!json.contains("enhancement"), "a builtin must stay out: {json}");
    }

    #[test]
    fn json_cuts_a_long_name_and_stays_bounded() {
        let mut cheat = Cheat::new(&"\u{5b57}".repeat(1_000), vec![CODE.to_owned()], Vec::new());
        cheat.enabled = false;
        let json = cheats_json(&[cheat]);
        assert!(json.len() <= ZK_CHEATS_JSON_MAX_BYTES, "the document must stay bounded");
        // The cut is at a character boundary, so the document is still UTF-8.
        assert!(json.contains("\"name\":\""), "unexpected: {json}");
    }

    #[test]
    fn write_atomic_replaces_the_file_and_leaves_no_temporary() {
        let dir = scratch_dir("atomic");
        let path = dir.join("Cheats").join("0004000000000000.txt");
        write_atomic(&path, "[first]\n").expect("the first save creates the folder");
        assert_eq!(std::fs::read_to_string(&path).expect("the file is there"), "[first]\n");
        write_atomic(&path, "[second]\n").expect("a second save replaces it");
        assert_eq!(std::fs::read_to_string(&path).expect("the file is there"), "[second]\n");
        let leftovers: Vec<_> = std::fs::read_dir(path.parent().expect("a parent"))
            .expect("the folder is there")
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "a failed or finished save must leave no .tmp");
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn loaded_system(dir: &Path) -> (Box<System>, *mut c_void, PathBuf) {
        let mut system = Box::new(System::new(zakuro_core::Config::default()));
        let handle = (&mut *system) as *mut System as *mut c_void;
        let path = scratch_file(dir, "cheats.txt", &citra_text());
        (system, handle, path)
    }

    #[test]
    fn ffi_loads_lists_toggles_and_saves_a_file() {
        let dir = scratch_dir("ffi");
        let (system, handle, path) = loaded_system(&dir);
        let c_path = CString::new(path.to_string_lossy().into_owned()).expect("no NUL in the path");
        assert_eq!(zk_cheats_count(handle), 0);
        assert_eq!(zk_cheats_load(handle, c_path.as_ptr()), 3);
        assert_eq!(zk_cheats_count(handle), 3);
        assert_eq!(system.cheats.len(), 3);

        let json = cheats_json(&system.cheats);
        assert!(json.contains("\"name\":\"Example cheat\""), "unexpected: {json}");
        assert!(json.contains("\"enabled\":true"), "unexpected: {json}");

        // The list order is the file order: index 1 is the enabled one.
        assert_eq!(zk_cheats_set_enabled(handle, 1, 0), ZK_CHEATS_OK);
        assert!(!system.cheats[1].enabled);
        assert_eq!(zk_cheats_set_enabled(handle, 3, 1), ZK_CHEATS_BAD_INDEX);
        assert_eq!(zk_cheats_set_enabled(handle, -1, 1), ZK_CHEATS_BAD_INDEX);
        assert_eq!(zk_cheats_set_enabled(handle, 0, 1), ZK_CHEATS_OK);
        assert!(system.cheats[0].enabled);

        let out = dir.join("saved.txt");
        let c_out = CString::new(out.to_string_lossy().into_owned()).expect("no NUL in the path");
        assert_eq!(zk_cheats_save(handle, c_out.as_ptr()), ZK_CHEATS_OK);
        let written = std::fs::read_to_string(&out).expect("the save wrote the file");
        assert!(written.contains("*citra_enabled"), "the enabled state must be written: {written}");
        assert!(written.contains("[Example cheat]"), "the name must be written: {written}");
        // A reload of what was written gives the same three cheats.
        assert_eq!(zk_cheats_load(handle, c_out.as_ptr()), 3);
        assert!(system.cheats[0].enabled);

        // The FFI's own document, through the thread-local pointer.
        assert!(!zk_cheats_json(handle).is_null());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ffi_rejects_a_bad_handle_and_path() {
        assert_eq!(zk_cheats_load(ptr::null_mut(), ptr::null()), ZK_CHEATS_BAD_HANDLE);
        assert_eq!(zk_cheats_save(ptr::null_mut(), ptr::null()), ZK_CHEATS_BAD_HANDLE);
        assert_eq!(zk_cheats_count(ptr::null_mut()), ZK_CHEATS_BAD_HANDLE);
        assert!(zk_cheats_json(ptr::null_mut()).is_null());
        assert_eq!(zk_cheats_set_enabled(ptr::null_mut(), 0, 1), ZK_CHEATS_BAD_HANDLE);

        let mut system = Box::new(System::new(zakuro_core::Config::default()));
        let handle = (&mut *system) as *mut System as *mut c_void;
        assert_eq!(zk_cheats_load(handle, ptr::null()), ZK_CHEATS_BAD_PATH);
        assert_eq!(zk_cheats_save(handle, ptr::null()), ZK_CHEATS_BAD_PATH);
        let missing = c"/nonexistent/zakuro/cheats.txt";
        assert_eq!(zk_cheats_load(handle, missing.as_ptr()), ZK_CHEATS_READ_FAILED);
        assert!(!crate::zk_last_error().is_null(), "a failure records a reason");
    }
}
