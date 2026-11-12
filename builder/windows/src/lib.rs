//! 3ds2apple Builder for Windows.
//!
//! The Windows frontend is a thin desktop client over the shared
//! [`builder_core`] library: it validates the user's ROM on this PC, connects to
//! a macOS Build Agent the user controls (SSH, or a local Agent process for
//! testing), streams build progress and logs, then downloads and verifies the
//! unsigned IPA and shows the sideloading steps.
//!
//! It shares its configuration file and host profiles with the cross-platform
//! `zkb` CLI, so the two can be used interchangeably on the same machine. No
//! protocol or build logic lives in this crate: the network protocol, transfers,
//! hashing and host configuration all come from `builder_core`.
//!
//! The optional graphical shell (Tauri 2 over this same library) is not part of
//! this build; see `builder/windows/README.md` for its status and prerequisites.
//!
//! Windows-specific handling lives in [`paths`] (extended-length paths, reserved
//! names, CJK file names), [`probe`] (OpenSSH, WebView2, console encoding, free
//! disk space) and [`doctor`] (the environment report).
#![forbid(unsafe_code)]
#![warn(missing_debug_implementations)]

pub mod app;
pub mod artifacts;
pub mod doctor;
pub mod errors;
pub mod events;
pub mod hosts;
pub mod install_guide;
pub mod paths;
pub mod preflight;
pub mod probe;
pub mod selftest;
pub mod wizard;

/// Product name shown in banners and reports.
pub const FRONTEND_NAME: &str = "3ds2apple Builder for Windows";

/// Version of this frontend, also sent to the Agent in `hello`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Minimum free space recommended on the volume that receives the IPA.
pub const RECOMMENDED_FREE_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// Free space below which the frontend refuses to start a download.
pub const MINIMUM_FREE_BYTES: u64 = 256 * 1024 * 1024;
