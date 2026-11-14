//! Error type shared by the desktop AOT pipeline.

use std::path::PathBuf;

/// Anything the desktop pipeline can fail on. Messages are user-facing: they
/// name the file or value and the next action, and never contain ROM bytes.
#[derive(Debug, thiserror::Error)]
pub enum PackError {
    /// Invalid user input, a malformed ROM/package, or an inconsistent state.
    #[error("{0}")]
    Invalid(String),
    /// Filesystem failure with the path that failed.
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    /// JSON failure for a package manifest or catalogue.
    #[error("{path}: invalid JSON: {source}")]
    Json {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },
}

impl PackError {
    /// Build an invalid-input error from anything displayable.
    pub fn invalid(message: impl Into<String>) -> Self {
        PackError::Invalid(message.into())
    }

    /// Wrap an I/O error with the path it happened on.
    pub fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        PackError::Io {
            path: path.into(),
            source,
        }
    }

    /// Wrap a JSON error with the file it came from.
    pub fn json(path: impl Into<PathBuf>, source: serde_json::Error) -> Self {
        PackError::Json {
            path: path.into(),
            source,
        }
    }
}

/// In-memory JSON (de)serialisation errors have no file to name; file reads and
/// writes use the explicit constructors above so the path is preserved.
impl From<serde_json::Error> for PackError {
    fn from(source: serde_json::Error) -> Self {
        PackError::Invalid(format!("JSON error: {source}"))
    }
}

/// Convenience result alias.
pub type Result<T> = std::result::Result<T, PackError>;
