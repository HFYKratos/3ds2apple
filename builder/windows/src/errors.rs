//! Error type and the documented CLI exit codes.
//!
//! The exit codes match `builder/UX.md` §8 and the `zkb` CLI, so scripts and
//! shortcuts can treat both tools the same way.

use builder_core::client::ClientError;
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::model::ErrorInfo;

/// Exit code for success.
pub const EXIT_SUCCESS: i32 = 0;
/// A build reached a terminal failed state.
pub const EXIT_BUILD_FAILED: i32 = 1;
/// Usage or configuration error.
pub const EXIT_USAGE: i32 = 2;
/// Host, authentication or transport error.
pub const EXIT_HOST: i32 = 3;
/// The user canceled the job.
pub const EXIT_CANCELED: i32 = 4;
/// Local input/output error (disk, write, permissions).
pub const EXIT_IO: i32 = 5;
/// An internal error (protocol violation, unexpected state).
pub const EXIT_INTERNAL: i32 = 64;

/// Everything that can go wrong while the frontend drives a build.
#[derive(Debug, thiserror::Error)]
pub enum FrontendError {
    #[error("{0}")]
    Usage(String),
    #[error("{0}")]
    Config(String),
    #[error("{0}")]
    Local(String),
    #[error(transparent)]
    Client(#[from] ClientError),
    /// The user is not allowed to continue until the local environment is fixed.
    #[error("{0}")]
    Environment(String),
    /// A build reached a terminal failed state: actionable failure.
    #[error("build failed: {}", .error.message)]
    BuildFailed { error: ErrorInfo },
    #[error("the build was canceled")]
    Canceled,
    #[error("the Agent was interrupted: {0}")]
    Interrupted(String),
}

impl FrontendError {
    pub fn usage(message: impl Into<String>) -> Self {
        FrontendError::Usage(message.into())
    }

    pub fn local(message: impl Into<String>) -> Self {
        FrontendError::Local(message.into())
    }

    /// The machine-readable protocol code, when one exists.
    pub fn protocol_code(&self) -> Option<ErrorCode> {
        match self {
            FrontendError::BuildFailed { error } => Some(error.code),
            FrontendError::Client(ClientError::Remote { error }) => Some(error.code),
            FrontendError::Client(ClientError::ArtifactCorrupt { .. }) => {
                Some(ErrorCode::VerifyFailed)
            }
            _ => None,
        }
    }

    /// A hint that tells the user what to change, when one exists.
    pub fn hint(&self) -> Option<&str> {
        match self {
            FrontendError::BuildFailed { error } => error.hint.as_deref(),
            FrontendError::Client(ClientError::Remote { error }) => error.hint.as_deref(),
            FrontendError::Client(ClientError::ArtifactCorrupt { .. }) => {
                Some("run the download again; if it repeats, the Agent-side artifact is damaged")
            }
            _ => None,
        }
    }

    /// Last log lines reported by the Agent, if any.
    pub fn log_tail(&self) -> Option<&[String]> {
        match self {
            FrontendError::BuildFailed { error } => error.log_tail.as_deref(),
            _ => None,
        }
    }

    /// The build stage the failure belongs to, if the Agent reported one.
    pub fn stage(&self) -> Option<&str> {
        match self {
            FrontendError::BuildFailed { error } => error.stage.map(|stage| stage.as_str()),
            _ => None,
        }
    }
}

/// Exit code for an error, following the documented conventions.
pub fn exit_code(error: &FrontendError) -> i32 {
    match error {
        FrontendError::Usage(_) | FrontendError::Config(_) => EXIT_USAGE,
        FrontendError::Environment(_) => EXIT_HOST,
        FrontendError::BuildFailed { .. } => EXIT_BUILD_FAILED,
        FrontendError::Canceled => EXIT_CANCELED,
        FrontendError::Interrupted(_) => EXIT_HOST,
        FrontendError::Local(_) => EXIT_IO,
        FrontendError::Client(error) => match error {
            ClientError::Remote { error } => match error.code {
                ErrorCode::BuildFailed => EXIT_BUILD_FAILED,
                ErrorCode::Internal => EXIT_INTERNAL,
                _ => EXIT_HOST,
            },
            ClientError::Io { .. }
            | ClientError::Local(_)
            | ClientError::ArtifactCorrupt { .. } => EXIT_IO,
            ClientError::Protocol(_)
            | ClientError::Transport(_)
            | ClientError::UnexpectedFrame { .. }
            | ClientError::Closed(_)
            | ClientError::AgentExit { .. }
            | ClientError::InvalidReply(_) => EXIT_HOST,
        },
    }
}

/// Human hint for an Agent refusal code reported in `hello`.
pub fn refusal_hint(code: &str) -> &'static str {
    match code {
        "toolchain_missing" => {
            "on the Mac: install Xcode with the iOS SDK, Rust with the aarch64-apple-ios target, xcodegen and Python 3"
        }
        "repo_missing" => {
            "on the Mac: start the Agent with --checkout pointing at a 3ds2apple checkout"
        }
        "repo_dirty" => "on the Mac: commit or stash the changes in the 3ds2apple checkout",
        "insufficient_storage" => "on the Mac: free disk space (about 20 GB per build)",
        "forbidden" => "on the Mac: run the Agent as your login user, not as root",
        _ => "run `builder-agent doctor` on the Mac",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exit_codes_follow_the_documented_table() {
        assert_eq!(exit_code(&FrontendError::Usage("x".into())), 2);
        assert_eq!(exit_code(&FrontendError::Config("x".into())), 2);
        assert_eq!(exit_code(&FrontendError::Local("x".into())), 5);
        assert_eq!(exit_code(&FrontendError::Canceled), 4);
        assert_eq!(exit_code(&FrontendError::Interrupted("x".into())), 3);
        assert_eq!(exit_code(&FrontendError::Environment("x".into())), 3);
        let failed = FrontendError::BuildFailed {
            error: ErrorInfo::new(ErrorCode::BuildFailed, "boom"),
        };
        assert_eq!(exit_code(&failed), 1);
        let remote = FrontendError::Client(ClientError::Remote {
            error: ErrorInfo::new(ErrorCode::Internal, "boom"),
        });
        assert_eq!(exit_code(&remote), 64);
        let remote_host = FrontendError::Client(ClientError::Remote {
            error: ErrorInfo::new(ErrorCode::DaemonUnavailable, "boom"),
        });
        assert_eq!(exit_code(&remote_host), 3);
    }

    #[test]
    fn clues_are_exposed() {
        let failed = FrontendError::BuildFailed {
            error: ErrorInfo::new(ErrorCode::BuildFailed, "boom")
                .with_hint("check the Mac")
                .with_log_tail(vec!["line".into()])
                .with_stage(builder_core::protocol::model::Stage::Linking),
        };
        assert_eq!(failed.hint(), Some("check the Mac"));
        assert_eq!(failed.log_tail().map(<[String]>::len), Some(1));
        assert_eq!(failed.stage(), Some("linking"));
        assert_eq!(failed.protocol_code(), Some(ErrorCode::BuildFailed));
        assert_eq!(exit_code(&failed), 1);
    }

    #[test]
    fn every_refusal_code_has_a_hint() {
        for code in [
            "toolchain_missing",
            "repo_missing",
            "repo_dirty",
            "insufficient_storage",
            "forbidden",
            "something_new",
        ] {
            assert!(!refusal_hint(code).is_empty(), "{code}");
        }
    }
}
