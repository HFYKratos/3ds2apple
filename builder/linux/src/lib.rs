//! Linux desktop frontend for the 3ds2apple Builder.
//!
//! The AOT pipeline (3dsrecomp, the iOS SDK's clang, `xcodebuild`) needs
//! macOS, so this frontend drives a macOS Build Agent that the user controls:
//! a local macOS VM, a Mac on the LAN or a rented cloud Mac. The protocol work
//! is done by the shared `zkb` client and the shared [`builder_core`] library;
//! this crate adds what is specific to a Linux workstation:
//!
//! * discovery of a local QEMU/KVM macOS VM's forwarded SSH port
//!   ([`vm`]), so pairing does not start with guesswork;
//! * a first-run [`host_setup`] flow that verifies the host key and pairs the
//!   host through `zkb` (SSH key only, never a password);
//! * a [`build`] wrapper that selects the ROM, streams the build, verifies the
//!   downloaded IPA's SHA256 and prints the signing/installation steps;
//! * a [`doctor`] report and an [`overview`] for the first screen.
//!
//! The crate never signs, installs or distributes anything, never talks to a
//! project-operated server and stores no credentials. Signing and installation
//! are a manual step on a Windows or macOS machine (Sideloadly/AltStore).
#![forbid(unsafe_code)]

pub mod build;
pub mod cli;
pub mod doctor;
pub mod error;
pub mod host_setup;
pub mod install;
pub mod output;
pub mod overview;
pub mod paths;
pub mod vm;
pub mod zkb;

pub use error::{
    Error, EXIT_BUILD_FAILED, EXIT_CANCELED, EXIT_HOST, EXIT_INTERNAL, EXIT_IO, EXIT_SUCCESS,
    EXIT_USAGE,
};
pub use output::Printer;
