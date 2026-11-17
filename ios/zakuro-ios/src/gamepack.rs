//! Run-time registration of a per-game AOT GamePack.
//!
//! The AOT-first shell (`ios/app/Sources/AOTPackageLoader.swift`) dlopen()s one
//! `Frameworks/GamePack-<TITLE_ID>.dylib` per catalog entry. The pack's C shim
//! (`ios/zakuro-ios/gamepack/zk_gamepack_shim.c`, built by
//! `scripts/build-game-pack.sh`) implements the pack's side of GamePack C ABI
//! v1 and calls [`zk_register_gamepack`] with the addresses of the 3dsrecomp
//! tables the pack carries. [`super::zk_create`] then hands those tables to
//! Zakuro through the same `Config.linked` path a statically linked single-game
//! build uses, so the game runs as AOT C instead of in the interpreter.
//!
//! This does not change the 0.1.x single-game builds: a build with
//! `--features linked` keeps its build-time tables and they win over a
//! registered pack. The interpreter-only shell - the AOT-first runtime - has no
//! build-time tables and uses the most recently registered pack.
//!
//! # A port can have one code unit
//!
//! 3dsrecomp writes `recomp_module_count = units.len() - 1`, so a port whose
//! program is the executable alone (no CRO modules) carries
//! `recomp_module_count == 0` and an empty `recomp_modules` table. That is a
//! complete program - all of its code is in `recomp_entries` - and Zakuro's
//! loader, `recomp-abi`'s `Library::linked` and the `Linked` value it builds
//! from these tables all accept it: nothing on the run path dereferences the
//! empty module table. Registration therefore treats an empty module table as
//! valid and insists only on the entries table (with a non-zero entry count)
//! and the origins table.
//!
//! # Why a process-wide singleton
//!
//! The pack is a dylib whose code stays loaded for the whole app run; its
//! tables are static constants of that image, so the registry only needs to
//! keep their addresses and sizes. The shell resolves exactly one catalog game
//! before launching it, so "the most recently registered pack" is the game
//! being started. The loader additionally checks the title ID inside the tables
//! against the ROM; a pack for another game is refused there (the interpreter
//! would run instead, and the AOT-only shell then reports "No AOT build for
//! this game").
//!
//! See `ios/zakuro-ios/include/zakuro_gamepack.h` for the C contract and
//! `builder/README.md` section 6 for the desktop pipeline's side.

use std::ffi::c_void;
use std::sync::Mutex;

use zakuro_core::recompiled::{Library, Linked};

/// One registered GamePack: the generated tables' addresses (stored as
/// `usize`, so the registry is `Send` + `Sync` without unsafe), their sizes,
/// and the interface version and generation the pack was built for.
#[derive(Clone, Copy)]
struct RegisteredProgram {
    program_id: u64,
    abi: u32,
    generation: u32,
    entries: usize,
    entry_count: u32,
    modules: usize,
    module_count: u32,
    origins: usize,
}

/// The pack registered by the most recent successful [`zk_register_gamepack`].
static REGISTERED: Mutex<Option<RegisteredProgram>> = Mutex::new(None);

/// Locks the registry, ignoring a poisoned mutex: a panic while it was held
/// must not turn every later FFI call into a panic across the C boundary.
fn registry() -> std::sync::MutexGuard<'static, Option<RegisteredProgram>> {
    REGISTERED
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A non-NULL, `Module`-aligned placeholder for a table that has no modules.
///
/// A port whose program is a single code unit has `recomp_module_count == 0`
/// and no modules to describe. `recomp-abi` keeps the module table as a slice,
/// and Rust wants a non-NULL, aligned pointer for one even when it is empty, so
/// a pack that passes NULL for the empty table gets this address instead.
static EMPTY_MODULES: u64 = 0;

impl RegisteredProgram {
    /// The tables as Zakuro's `Linked`, or `None` when the addresses/counts
    /// cannot describe a program (registration validates them already).
    ///
    /// An empty module table is a usable program: a single-code-unit port has
    /// all of its code in the entries table and no CRO modules. Only the
    /// entries and origins tables have to be there and the entry count be
    /// non-zero; `modules` may be NULL when `module_count` is 0, and is then
    /// replaced with a non-NULL placeholder so that the empty slice
    /// `recomp-abi` keeps is well-formed.
    fn code(self) -> Option<Linked> {
        if self.entries == 0 || self.origins == 0 || self.entry_count == 0 {
            return None;
        }
        if self.module_count != 0 && self.modules == 0 {
            return None;
        }
        let modules = if self.module_count == 0 {
            std::ptr::addr_of!(EMPTY_MODULES).cast::<c_void>()
        } else {
            self.modules as *const c_void
        };
        // SAFETY: the addresses are the constant tables inside the loaded pack,
        // which the shell keeps loaded for the rest of the process; `recomp.h`
        // declares their layout and `recomp-abi` keeps `Linked` in step with
        // it. This is the same contract `linked::code` relies on.
        Some(unsafe {
            Linked::new(
                self.program_id,
                self.abi,
                self.entries as *const c_void,
                self.entry_count,
                modules,
                self.module_count,
            )
            .with_origins(self.generation, self.origins as *const c_void)
        })
    }
}

/// The title ID of the most recently registered GamePack, if any.
pub(crate) fn registered_title_id() -> Option<u64> {
    registry().as_ref().map(|program| program.program_id)
}

/// The most recently registered GamePack's tables as Zakuro's `Linked`.
pub(crate) fn registered_code() -> Option<Linked> {
    registry().as_ref().and_then(|program| program.code())
}

/// Registers a per-game AOT GamePack with the runtime.
///
/// This is the host side of the GamePack C ABI (`zakuro_gamepack.h`); the
/// pack's `zk_gamepack_register` export calls it once, on the main thread,
/// right after the shell loaded the pack. The arguments are the seven tables
/// 3dsrecomp's generated C exports (`recomp.h`, "Exported symbols"), their
/// counts, the recomp interface version (`recomp_abi`) and generation, plus
/// the title ID the pack was built for (the generated tables carry no title).
///
/// The interface version is checked here, so a pack built against another
/// recomp ABI is reported at registration instead of a mysterious
/// "interpreting" later. A successful registration replaces any previous one;
/// the shell resolves one game per launch.
///
/// The tables may describe a single code unit: a port whose program is the
/// executable alone has `module_count == 0` and no modules, which is a valid
/// program (see the module documentation). A NULL `modules` pointer is
/// therefore accepted when `module_count` is 0; when it is non-zero the
/// pointer must be there. The entries and origins pointers and a non-zero
/// `entry_count` are always required.
///
/// Returns 0 on success, -1 for invalid arguments or unusable tables (a missing
/// title, entries, origins or module table, or a zero entry count), -2 when
/// this Zakuro refuses the tables' interface version. A non-zero result makes
/// the shell unload the pack and report the game as unavailable.
#[no_mangle]
pub extern "C" fn zk_register_gamepack(
    title_id: u64,
    recomp_abi: u32,
    generation: u32,
    entries: *const c_void,
    entry_count: u32,
    modules: *const c_void,
    module_count: u32,
    origins: *const c_void,
) -> i32 {
    if title_id == 0
        || entries.is_null()
        || origins.is_null()
        || entry_count == 0
        || (module_count != 0 && modules.is_null())
    {
        eprintln!(
            "zk_register_gamepack: refused: invalid tables (title {title_id:016X}, \
             {entry_count} entry points, {module_count} modules)"
        );
        super::set_linked_refusal("the game package tables were empty or invalid".to_owned());
        return -1;
    }

    let program = RegisteredProgram {
        program_id: title_id,
        abi: recomp_abi,
        generation,
        entries: entries as usize,
        entry_count,
        modules: modules as usize,
        module_count,
        origins: origins as usize,
    };
    let Some(code) = program.code() else {
        eprintln!("zk_register_gamepack: refused: unusable tables for title {title_id:016X}");
        super::set_linked_refusal("the game package tables were unusable".to_owned());
        return -1;
    };

    // Check the interface version now: `Library::linked` is the same check
    // the loader performs, so a mismatch is explained at registration.
    match Library::linked(&code) {
        Ok(library) => {
            eprintln!(
                "zk_register_gamepack: accepted title {title_id:016X}: {}",
                library.describe()
            );
        }
        Err(error) => {
            let reason = format!(
                "the game package tables for title {title_id:016X} were built for an interface \
                 version this Zakuro refuses: {error}"
            );
            eprintln!("zk_register_gamepack: refused title {title_id:016X}: {error}");
            super::set_linked_refusal(reason);
            return -2;
        }
    }

    *registry() = Some(program);
    super::clear_linked_refusal();
    let modules_note = if module_count == 0 {
        " (single code unit)"
    } else {
        ""
    };
    eprintln!(
        "zk_register_gamepack: registered title {title_id:016X}: recomp interface ABI \
         {recomp_abi}, generation {generation}, {entry_count} entry points, {module_count} modules{modules_note}"
    );
    0
}

/// Forgets the registered GamePack, so the next `zk_create` runs without AOT
/// code. The shell does not need this (a pack stays loaded); it keeps the API
/// symmetric with registration and makes the FFI tests independent.
///
/// Returns 0 (there is no failure mode).
#[no_mangle]
pub extern "C" fn zk_unregister_gamepack() -> i32 {
    *registry() = None;
    crate::clear_linked_refusal();
    0
}

/// 1 when a GamePack is registered and would be handed to the next `zk_create`,
/// 0 otherwise.
#[no_mangle]
pub extern "C" fn zk_gamepack_registered() -> i32 {
    if registered_title_id().is_some() {
        1
    } else {
        0
    }
}

/// The title ID of the registered GamePack (the AOT code's title), or 0.
///
/// Named apart from the pack's own `zk_gamepack_title_id` export to keep the
/// two sides of the C ABI obviously distinct.
#[no_mangle]
pub extern "C" fn zk_registered_gamepack_title_id() -> u64 {
    registered_title_id().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    /// The registration slot and the recorded refusal are process-wide, and
    /// the test harness runs tests in parallel threads: hold this for a test.
    static SERIAL: Mutex<()> = Mutex::new(());

    fn serial() -> MutexGuard<'static, ()> {
        SERIAL
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Stands in for the generated `recomp_entries`/`recomp_origins` tables.
    /// Registration only keeps the addresses and reads the counts, so nothing
    /// has to be behind it, and no generated archive is needed for these tests.
    static TABLE: u64 = 0;

    fn table() -> *const c_void {
        std::ptr::addr_of!(TABLE).cast()
    }

    const TITLE: u64 = 0x0004_0000_0008_9F00;
    const ABI: u32 = 5;
    /// Below `recomp-abi`'s OLDEST_ABI (4): too old to run.
    const OLD_ABI: u32 = 3;

    /// A single-code-unit port has `recomp_module_count == 0` and an empty
    /// `recomp_modules` table (3dsrecomp writes `units.len() - 1`). 0.1.1
    /// refused exactly that shape as "invalid tables", which kept both games
    /// from starting; it is a complete program and must register.
    #[test]
    fn register_accepts_a_single_code_unit() {
        let _serial = serial();
        zk_unregister_gamepack();
        assert_eq!(
            zk_register_gamepack(
                TITLE,
                ABI,
                ABI,
                table(),
                110732,
                std::ptr::null(),
                0,
                table()
            ),
            0,
            "0 modules (one code unit) is a valid program, not an invalid pack"
        );
        assert_eq!(zk_gamepack_registered(), 1);
        assert_eq!(zk_registered_gamepack_title_id(), TITLE);

        // The registered tables are handed to Zakuro as a `Linked`: the empty
        // module table must not make that impossible, and Zakuro's own
        // interface-version check must accept it.
        let program = RegisteredProgram {
            program_id: TITLE,
            abi: ABI,
            generation: ABI,
            entries: table() as usize,
            entry_count: 110732,
            modules: 0,
            module_count: 0,
            origins: table() as usize,
        };
        let linked = program
            .code()
            .expect("a single code unit is a usable program");
        assert_eq!(linked.program_id(), TITLE);
        let library = zakuro_core::recompiled::Library::linked(&linked)
            .expect("recomp-abi accepts a Linked with an empty module table");
        assert!(
            library.describe().ends_with("0 modules"),
            "the empty table is described, not rejected: {}",
            library.describe()
        );
        let mut count_without_table = program;
        count_without_table.module_count = 1;
        assert!(
            count_without_table.code().is_none(),
            "a module count without a module table is still unusable"
        );

        // 3dsrecomp's generated C does define the (empty) table's symbol, so a
        // pack may pass its address instead of NULL; that shape is accepted too.
        assert_eq!(
            zk_register_gamepack(TITLE, ABI, ABI, table(), 110732, table(), 0, table()),
            0,
            "an empty but non-NULL module table is accepted"
        );
        assert_eq!(zk_registered_gamepack_title_id(), TITLE);
        zk_unregister_gamepack();
    }

    /// The other malformed-table cases are still refused with -1, and a refused
    /// pack leaves the registration slot alone.
    #[test]
    fn register_rejects_invalid_tables() {
        let _serial = serial();
        zk_unregister_gamepack();
        assert_eq!(
            zk_register_gamepack(TITLE, ABI, ABI, table(), 1, table(), 1, table()),
            0,
            "a table with modules registers first"
        );

        assert_eq!(
            zk_register_gamepack(0, ABI, ABI, table(), 1, table(), 1, table()),
            -1,
            "title 0 must be refused"
        );
        assert_eq!(
            zk_register_gamepack(TITLE, ABI, ABI, std::ptr::null(), 1, table(), 1, table()),
            -1,
            "a NULL entries table must be refused"
        );
        assert_eq!(
            zk_register_gamepack(TITLE, ABI, ABI, table(), 1, table(), 1, std::ptr::null()),
            -1,
            "a NULL origins table must be refused"
        );
        assert_eq!(
            zk_register_gamepack(TITLE, ABI, ABI, table(), 0, table(), 1, table()),
            -1,
            "0 entry points must be refused"
        );
        assert_eq!(
            zk_register_gamepack(TITLE, ABI, ABI, table(), 1, std::ptr::null(), 1, table()),
            -1,
            "a NULL module table with a non-zero count must be refused"
        );
        assert_eq!(
            zk_register_gamepack(TITLE, ABI, ABI, table(), 0, std::ptr::null(), 0, table()),
            -1,
            "an empty single-code-unit table is still refused without entry points"
        );

        assert_eq!(
            zk_gamepack_registered(),
            1,
            "a refused pack must not clear the registered one"
        );
        assert_eq!(zk_registered_gamepack_title_id(), TITLE);
        zk_unregister_gamepack();
        assert_eq!(zk_gamepack_registered(), 0);
        assert_eq!(zk_registered_gamepack_title_id(), 0);
    }

    /// The table shape is checked before the interface version, and a
    /// well-formed single-code-unit table gets the ABI refusal (-2) rather than
    /// the invalid-arguments one (-1).
    #[test]
    fn register_refuses_an_unaccepted_interface_version() {
        let _serial = serial();
        zk_unregister_gamepack();
        assert_eq!(
            zk_register_gamepack(
                TITLE,
                OLD_ABI,
                ABI,
                table(),
                1,
                std::ptr::null(),
                0,
                table()
            ),
            -2,
            "a single-code-unit table with an old interface version is refused as ABI"
        );
        assert_eq!(zk_gamepack_registered(), 0);
        zk_unregister_gamepack();
    }
}
