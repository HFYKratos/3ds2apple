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
//! `docs/desktop-aot.md` section 6 for the desktop pipeline's side.

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

impl RegisteredProgram {
    /// The tables as Zakuro's `Linked`, or `None` when the addresses/counts
    /// cannot describe a program (registration validates them already).
    fn code(self) -> Option<Linked> {
        if self.entries == 0 || self.modules == 0 || self.origins == 0 || self.entry_count == 0 {
            return None;
        }
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
                self.modules as *const c_void,
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
/// Returns 0 on success, -1 for invalid arguments, -2 when this Zakuro refuses
/// the tables' interface version. A non-zero result makes the shell unload the
/// pack and report the game as unavailable.
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
        || modules.is_null()
        || origins.is_null()
        || entry_count == 0
        || module_count == 0
    {
        eprintln!(
            "zk_register_gamepack: refused: invalid tables (title {title_id:016X}, \
             {entry_count} entry points, {module_count} modules)"
        );
        super::set_linked_refusal(
            "the game package tables were empty or invalid".to_owned(),
        );
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
    eprintln!(
        "zk_register_gamepack: registered title {title_id:016X}: recomp interface ABI \
         {recomp_abi}, generation {generation}, {entry_count} entry points, {module_count} modules"
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

    /// Registration rejects unusable tables without touching the registry; no
    /// ROM or generated archive is needed for this path.
    #[test]
    fn register_rejects_empty_tables() {
        clear_registered();
        let marker = 1u32;
        let pointer = (&marker as *const u32).cast::<c_void>();
        assert_eq!(
            zk_register_gamepack(0, 5, 5, pointer, 1, pointer, 1, pointer),
            -1,
            "title 0 must be refused"
        );
        assert_eq!(
            zk_register_gamepack(0x0004_0000_0005_5E00, 5, 5, std::ptr::null(), 1, pointer, 1, pointer),
            -1,
            "NULL tables must be refused"
        );
        assert_eq!(zk_gamepack_registered(), 0);
        assert_eq!(zk_registered_gamepack_title_id(), 0);
        clear_registered();
    }
}
