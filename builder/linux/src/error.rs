//! Errors and the exit-code contract.
//!
//! The codes match the shared CLI conventions documented in `builder/UX.md`
//! §8, so scripts can treat this frontend and `zkb` the same way:
//!
//! | code | meaning |
//! |---|---|
//! | 0 | success |
//! | 1 | the build failed |
//! | 2 | usage or configuration error |
//! | 3 | host, authentication or transport problem |
//! | 4 | the build was canceled |
//! | 5 | local I/O problem on this machine |
//! | 64 | internal error |

/// Everything worked.
pub const EXIT_SUCCESS: i32 = 0;
/// A build reached a terminal failed state.
pub const EXIT_BUILD_FAILED: i32 = 1;
/// Bad arguments or local configuration.
pub const EXIT_USAGE: i32 = 2;
/// The macOS host, the SSH connection or the Agent failed.
pub const EXIT_HOST: i32 = 3;
/// The user canceled the build.
pub const EXIT_CANCELED: i32 = 4;
/// A local file/IO operation on this Linux machine failed.
pub const EXIT_IO: i32 = 5;
/// A bug or an unexpected internal state.
pub const EXIT_INTERNAL: i32 = 64;

/// An error with a stable exit code and a hint printed after the message.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    /// The command line is wrong or the local configuration cannot be used.
    #[error("{0}")]
    Usage(String),
    /// This machine is fine, but the macOS host side failed.
    #[error("{0}")]
    Host(String),
    /// Local file or process work failed on this machine.
    #[error("{0}")]
    Local(String),
    /// The shared client exited with a non-zero code and already explained why.
    #[error("zkb exited with code {0}")]
    Forwarded(i32),
    /// Unexpected state; a bug.
    #[error("{0}")]
    Internal(String),
}

impl Error {
    pub fn usage(message: impl Into<String>) -> Self {
        Self::Usage(message.into())
    }

    pub fn host(message: impl Into<String>) -> Self {
        Self::Host(message.into())
    }

    pub fn local(message: impl Into<String>) -> Self {
        Self::Local(message.into())
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::Internal(message.into())
    }

    /// Process exit code for this error.
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Usage(_) => EXIT_USAGE,
            Self::Host(_) => EXIT_HOST,
            Self::Local(_) => EXIT_IO,
            Self::Forwarded(code) => *code,
            Self::Internal(_) => EXIT_INTERNAL,
        }
    }

    /// Extra line printed after the error, when the next action is not obvious.
    pub fn hint(&self) -> Option<String> {
        match self {
            Self::Usage(_) => None,
            Self::Host(_) => Some(
                "Run `3ds2apple-builder doctor --host <name>` and check `zkb host test <name>`."
                    .to_string(),
            ),
            Self::Local(_) => None,
            Self::Forwarded(EXIT_HOST) => Some(
                "The Mac side is not reachable or not ready: run \
                 `3ds2apple-builder doctor --host <name>` and `zkb host test <name>`."
                    .to_string(),
            ),
            Self::Forwarded(EXIT_USAGE) => {
                Some("Fix the arguments and try again (`--help` shows them).".to_string())
            }
            Self::Forwarded(_) => None,
            Self::Internal(_) => Some(
                "This is an unexpected state; re-run with the same arguments and report it."
                    .to_string(),
            ),
        }
    }
}

/// Convenience for `Option<T>` values that are required by a command.
pub fn required<T>(value: Option<T>, message: impl Into<String>) -> Result<T, Error> {
    value.ok_or_else(|| Error::usage(message))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_codes_match_the_documented_contract() {
        assert_eq!(Error::Usage(String::new()).exit_code(), 2);
        assert_eq!(Error::Host(String::new()).exit_code(), 3);
        assert_eq!(Error::Local(String::new()).exit_code(), 5);
        assert_eq!(Error::Forwarded(1).exit_code(), 1);
        assert_eq!(Error::Forwarded(4).exit_code(), 4);
        assert_eq!(Error::Internal(String::new()).exit_code(), 64);
    }

    #[test]
    fn forwarded_host_failure_gets_a_next_action() {
        assert!(Error::Forwarded(EXIT_HOST).hint().is_some());
        assert!(Error::Forwarded(1).hint().is_none());
    }
}
