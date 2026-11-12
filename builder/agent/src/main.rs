//! `builder-agent` — the macOS Build Agent for the 3ds2apple Builder.
//!
//! The Agent is a headless build executor for one user-owned Mac:
//!
//! * `serve` runs the job daemon (one build slot) or a single stdio session;
//! * `ssh-dispatch` is the forced-command entry point used over SSH;
//! * `doctor`, `init`, `pair` and `gc` are setup/maintenance commands.
//!
//! It never signs, provisions or installs anything, never handles an Apple ID,
//! and runs only the fixed `scripts/` pipeline with argument arrays.
#![forbid(unsafe_code)]

#[cfg(unix)]
mod cleanup;
#[cfg(unix)]
mod cli;
#[cfg(unix)]
mod config;
#[cfg(unix)]
mod doctor;
#[cfg(unix)]
mod downloads;
#[cfg(unix)]
mod exec;
#[cfg(unix)]
mod fake;
#[cfg(unix)]
mod nix_util;
#[cfg(unix)]
mod server;
#[cfg(unix)]
mod service;
#[cfg(unix)]
mod ssh_dispatch;
#[cfg(unix)]
mod stages;
#[cfg(unix)]
mod store;
#[cfg(unix)]
mod uploads;
#[cfg(unix)]
mod util;
#[cfg(unix)]
mod worker;

#[cfg(unix)]
fn main() {
    std::process::exit(cli::run());
}

#[cfg(not(unix))]
fn main() {
    eprintln!(
        "builder-agent runs on macOS and Linux only; this build is not supported on this platform"
    );
    std::process::exit(2);
}
