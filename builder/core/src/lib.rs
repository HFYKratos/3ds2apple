//! Shared helpers for the 3ds2apple desktop pack pipeline (`3ds2apple-pack`).
//!
//! The crate is intentionally tiny: only the streaming SHA-256 utilities in
//! [`hash`] survive the removal of the legacy macOS Build Agent stack. That
//! agent, its CLI/client front ends and their wire protocol were deleted on
//! 2026-11-16: the v2 launcher builds GamePacks locally on Windows with
//! 3dsrecomp + LLVM/LLD and no longer needs a remote macOS host, so the
//! protocol/transport/client code had no remaining customer. The full history
//! stays in git.
#![forbid(unsafe_code)]
#![warn(missing_debug_implementations)]

pub mod hash;
