//! Shared library for the 3ds2apple Builder (Windows/Linux/macOS CLI) and the
//! macOS Build Agent.
//!
//! The crate owns the wire protocol ([`protocol`]), the two transport bindings
//! ([`transport`]), streaming hashing ([`hash`]) and the client-side state and
//! configuration ([`client`], [`config`]). It contains no UI and never spawns a
//! build: the Agent is the only component that runs processes, and it does so
//! with fixed argument arrays.
//!
//! The protocol is specified in `builder/PROTOCOL.md`; the public docs describe
//! the product, not this internal layout.
#![forbid(unsafe_code)]
#![warn(missing_debug_implementations)]

pub mod client;
pub mod config;
pub mod framing;
pub mod hash;
pub mod protocol;
pub mod redact;
pub mod transport;
pub mod util;

pub use protocol::PROTOCOL;

/// Version of this Builder/Agent implementation. Reported in `hello`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Product name used in `hello` and in user-facing output.
pub const CLIENT_NAME: &str = "3ds2apple-builder";

/// Oldest Agent build this client is willing to drive. Kept in lock-step with
/// the script contract in `scripts/`; bump when a stage argument or output
/// marker changes.
pub const MIN_AGENT_VERSION: &str = "0.1.0";

/// Default HTTP listener port (same-machine or SSH tunnel); SSH is the default
/// transport and does not use a port on the Mac.
pub const DEFAULT_AGENT_HTTP_PORT: u16 = 7676;
