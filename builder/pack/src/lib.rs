//! Desktop AOT-first pipeline for 3ds2apple.
//!
//! The desktop side of the AOT-first model ([docs/desktop-aot.md]): import the
//! user's own decrypted ROMs, detect their title IDs from the container
//! headers, queue AOT builds, keep one deterministic per-game package directory
//! per title, and allocate the selected packages into a single shell IPA with a
//! generated `GameCatalog.json`.
//!
//! Design rules:
//!
//! - No game data is copied, hashed or written anywhere: importing reads a
//!   couple of header blocks and records metadata (title ID, product code,
//!   sizes, local path). The ROM stays where the user put it.
//! - The real compile/link is delegated to `scripts/` on macOS (the Build
//!   Agent / user's Mac); this crate owns the pure, testable desktop logic:
//!   detection, the import queue, package manifests, catalogue allocation and
//!   the command plan handed to the scripts.
//! - Generated manifests and catalogues are deterministic: no timestamps,
//!   sorted entries and fixed serialisation, so re-running import/allocate
//!   produces byte-identical `GameInfo.json`/`GameCatalog.json` files. The IPA
//!   itself is NOT claimed reproducible: packaging uses the system `zip` and
//!   embeds archive timestamps (only its contents/catalogue are verified).
//!
//! See `docs/desktop-aot.md` for the flow, the package layout and the
//! catalogue schema.
#![forbid(unsafe_code)]
#![warn(missing_debug_implementations)]

pub mod catalog;
pub mod error;
pub mod gameinfo;
pub mod ops;
pub mod plan;
pub mod queue;
pub mod rom;

pub use error::{PackError, Result};

/// Version of this desktop pipeline, reported by `3ds2apple-pack --version`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Binary name used in help text and the generated command plans.
pub const BRAND: &str = "3ds2apple-pack";

/// Default output root relative to the working directory (`out/`, gitignored).
pub const DEFAULT_OUT_DIR: &str = "out";

/// Catalog schema version this pipeline writes (schema 2, as read by
/// `ios/app/Sources/GameCatalog.swift` + `AOTPackageLoader.swift` after the
/// AOT-shell task). Version 1 catalogs (statically linked single-game builds)
/// are still accepted by the reader and the script validator.
pub const CATALOG_SCHEMA_VERSION: u32 = 2;

/// GamePack dylib contract version ("host ABI") the desktop pipeline writes into
/// `packABIVersion`. Must match `AOTPackageLoader.hostABIVersion` (1) and the
/// runtime's GamePack C ABI. See docs/desktop-aot.md and docs/aot-first.md §7.4.
pub const GAMEPACK_ABI_VERSION: u32 = 1;

/// Registration hook the shell looks up by default on a GamePack dylib.
pub const GAMEPACK_REGISTRATION_SYMBOL: &str = "zk_gamepack_register";
