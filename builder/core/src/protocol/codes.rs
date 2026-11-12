//! Stable, machine-readable error codes (PROTOCOL.md §8.2).
//!
//! Codes are part of the protocol: they are never renamed inside a protocol
//! major version, and clients are expected to branch on them rather than on
//! message text.

use serde::{Deserialize, Serialize};

/// Error code carried by an `error` frame or a failed job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    BadRequest,
    UnsupportedProtocol,
    UnsupportedClient,
    UnsupportedAgent,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    QueueFull,
    RateLimited,
    PayloadTooLarge,
    InsufficientStorage,
    ToolchainMissing,
    RepoMissing,
    RepoDirty,
    SourceMismatch,
    InputInvalid,
    InputTimeout,
    UploadStalled,
    BuildFailed,
    VerifyFailed,
    ArtifactNotReady,
    DaemonUnavailable,
    Timeout,
    Interrupted,
    Internal,
}

impl ErrorCode {
    /// Every code, in documentation order. Used by tests and by `zkb doctor`.
    pub const ALL: [ErrorCode; 26] = [
        ErrorCode::BadRequest,
        ErrorCode::UnsupportedProtocol,
        ErrorCode::UnsupportedClient,
        ErrorCode::UnsupportedAgent,
        ErrorCode::Unauthorized,
        ErrorCode::Forbidden,
        ErrorCode::NotFound,
        ErrorCode::Conflict,
        ErrorCode::QueueFull,
        ErrorCode::RateLimited,
        ErrorCode::PayloadTooLarge,
        ErrorCode::InsufficientStorage,
        ErrorCode::ToolchainMissing,
        ErrorCode::RepoMissing,
        ErrorCode::RepoDirty,
        ErrorCode::SourceMismatch,
        ErrorCode::InputInvalid,
        ErrorCode::InputTimeout,
        ErrorCode::UploadStalled,
        ErrorCode::BuildFailed,
        ErrorCode::VerifyFailed,
        ErrorCode::ArtifactNotReady,
        ErrorCode::DaemonUnavailable,
        ErrorCode::Timeout,
        ErrorCode::Interrupted,
        ErrorCode::Internal,
    ];

    /// The wire name (`snake_case`).
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::BadRequest => "bad_request",
            ErrorCode::UnsupportedProtocol => "unsupported_protocol",
            ErrorCode::UnsupportedClient => "unsupported_client",
            ErrorCode::UnsupportedAgent => "unsupported_agent",
            ErrorCode::Unauthorized => "unauthorized",
            ErrorCode::Forbidden => "forbidden",
            ErrorCode::NotFound => "not_found",
            ErrorCode::Conflict => "conflict",
            ErrorCode::QueueFull => "queue_full",
            ErrorCode::RateLimited => "rate_limited",
            ErrorCode::PayloadTooLarge => "payload_too_large",
            ErrorCode::InsufficientStorage => "insufficient_storage",
            ErrorCode::ToolchainMissing => "toolchain_missing",
            ErrorCode::RepoMissing => "repo_missing",
            ErrorCode::RepoDirty => "repo_dirty",
            ErrorCode::SourceMismatch => "source_mismatch",
            ErrorCode::InputInvalid => "input_invalid",
            ErrorCode::InputTimeout => "input_timeout",
            ErrorCode::UploadStalled => "upload_stalled",
            ErrorCode::BuildFailed => "build_failed",
            ErrorCode::VerifyFailed => "verify_failed",
            ErrorCode::ArtifactNotReady => "artifact_not_ready",
            ErrorCode::DaemonUnavailable => "daemon_unavailable",
            ErrorCode::Timeout => "timeout",
            ErrorCode::Interrupted => "interrupted",
            ErrorCode::Internal => "internal",
        }
    }

    /// HTTP status used by the (optional) HTTP binding.
    pub fn http_status(self) -> u16 {
        match self {
            ErrorCode::BadRequest => 400,
            ErrorCode::UnsupportedProtocol
            | ErrorCode::UnsupportedClient
            | ErrorCode::UnsupportedAgent => 426,
            ErrorCode::Unauthorized => 401,
            ErrorCode::Forbidden => 403,
            ErrorCode::NotFound => 404,
            ErrorCode::Conflict | ErrorCode::ArtifactNotReady => 409,
            ErrorCode::QueueFull | ErrorCode::RateLimited => 429,
            ErrorCode::PayloadTooLarge => 413,
            ErrorCode::InsufficientStorage => 507,
            ErrorCode::ToolchainMissing
            | ErrorCode::RepoMissing
            | ErrorCode::RepoDirty
            | ErrorCode::SourceMismatch => 412,
            ErrorCode::InputInvalid | ErrorCode::BuildFailed => 422,
            ErrorCode::VerifyFailed | ErrorCode::Internal => 500,
            ErrorCode::DaemonUnavailable => 503,
            ErrorCode::InputTimeout | ErrorCode::UploadStalled | ErrorCode::Timeout => 408,
            ErrorCode::Interrupted => 503,
        }
    }

    /// Whether retrying the same request may succeed without a user change.
    pub fn retryable(self) -> bool {
        matches!(
            self,
            ErrorCode::QueueFull
                | ErrorCode::RateLimited
                | ErrorCode::UploadStalled
                | ErrorCode::DaemonUnavailable
                | ErrorCode::Internal
        )
    }

    /// Short actionable hint shown next to the error, when one is known.
    pub fn hint(self) -> Option<&'static str> {
        match self {
            ErrorCode::UnsupportedProtocol => {
                Some("The Builder and the Build Agent speak different protocol versions; update the older side.")
            }
            ErrorCode::UnsupportedClient => Some("Update the Builder to the version the Agent requires."),
            ErrorCode::UnsupportedAgent => Some("Update the Build Agent on the Mac."),
            ErrorCode::Unauthorized => Some("Re-pair the host (the token or SSH key is no longer accepted)."),
            ErrorCode::QueueFull => Some("The Mac is busy; wait for the running build or retry shortly."),
            ErrorCode::RateLimited => Some("The Agent is rate limiting requests; wait a moment and retry."),
            ErrorCode::PayloadTooLarge => Some("The game file exceeds the Agent's configured input limit."),
            ErrorCode::InsufficientStorage => Some("Free disk space on the Mac host and retry."),
            ErrorCode::ToolchainMissing => {
                Some("Run `builder-agent doctor` on the Mac and install what it reports missing.")
            }
            ErrorCode::RepoMissing => Some("Configure the Agent's source checkout (`--checkout`) and retry."),
            ErrorCode::RepoDirty => Some("Commit or stash changes in the Mac checkout, or allow it explicitly."),
            ErrorCode::SourceMismatch => Some("Update the Mac checkout to the expected source revision."),
            ErrorCode::InputInvalid => Some("The uploaded file did not match its declared size or SHA256; upload again."),
            ErrorCode::UploadStalled => Some("The upload stalled; resume it from the reported offset."),
            ErrorCode::BuildFailed => {
                Some("Open the log: the failing stage, the hint and the log tail are in the job status.")
            }
            ErrorCode::VerifyFailed => Some("The Agent could not verify the produced IPA; re-run the build once."),
            ErrorCode::ArtifactNotReady => Some("The artifact is only available after a successful build."),
            ErrorCode::DaemonUnavailable => Some("Start the Build Agent on the Mac (`builder-agent serve`)."),
            ErrorCode::Timeout => Some("The step exceeded its time limit; check the Mac's load and retry."),
            ErrorCode::Interrupted => Some("The Mac restarted or the Agent stopped; start a new build."),
            ErrorCode::Internal => Some("Unexpected Agent error; retry once and report the log if it repeats."),
            ErrorCode::BadRequest | ErrorCode::Forbidden | ErrorCode::NotFound | ErrorCode::Conflict => None,
            ErrorCode::InputTimeout => Some("The upload never completed; create a new job."),
        }
    }
}

impl std::fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::str::FromStr for ErrorCode {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        ErrorCode::ALL
            .iter()
            .copied()
            .find(|code| code.as_str() == value)
            .ok_or(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_names_are_stable_and_unique() {
        let mut seen = std::collections::HashSet::new();
        for code in ErrorCode::ALL {
            assert!(seen.insert(code.as_str()), "duplicate code {}", code);
            assert!(
                code.as_str()
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b == b'_'),
                "code is not snake_case: {}",
                code
            );
        }
        assert_eq!(
            serde_json::to_string(&ErrorCode::QueueFull).unwrap(),
            "\"queue_full\""
        );
        assert_eq!(
            serde_json::from_str::<ErrorCode>("\"artifact_not_ready\"").unwrap(),
            ErrorCode::ArtifactNotReady
        );
        assert!("not_a_code".parse::<ErrorCode>().is_err());
    }

    #[test]
    fn http_status_and_retryability() {
        assert_eq!(ErrorCode::Unauthorized.http_status(), 401);
        assert_eq!(ErrorCode::QueueFull.http_status(), 429);
        assert_eq!(ErrorCode::ArtifactNotReady.http_status(), 409);
        assert_eq!(ErrorCode::InsufficientStorage.http_status(), 507);
        assert!(ErrorCode::QueueFull.retryable());
        assert!(!ErrorCode::BuildFailed.retryable());
        assert!(ErrorCode::BuildFailed.hint().is_some());
    }
}
