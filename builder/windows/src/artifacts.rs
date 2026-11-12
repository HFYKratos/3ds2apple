//! Artifact bookkeeping: checksum verification, the local artifact record, the
//! installation guide file, and opening the result in Explorer.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use builder_core::client::ClientError;
use builder_core::hash::sha256_file;
use builder_core::protocol::model::{ArtifactFile, ArtifactRecord};

use crate::errors::FrontendError;
use crate::paths;

/// Recompute a file's SHA256 (using extended-length paths on Windows).
pub fn compute_sha256(path: &Path) -> Result<String, FrontendError> {
    let target = paths::extended_length_path(path);
    sha256_file(&target)
        .map(|result| result.sha256)
        .map_err(|error| {
            FrontendError::local(format!(
                "cannot hash {}: {error}",
                paths::display_path(path)
            ))
        })
}

/// Verify a downloaded file against the SHA256 the Agent reported.
///
/// This is a second, independent check on top of the streaming verification the
/// client does while writing: if it fails, the local file is not what the Agent
/// built.
pub fn verify_sha256(path: &Path, expected: &str) -> Result<String, FrontendError> {
    let actual = compute_sha256(path)?;
    if !actual.eq_ignore_ascii_case(expected) {
        let bytes = std::fs::metadata(paths::extended_length_path(path))
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        return Err(FrontendError::Client(ClientError::ArtifactCorrupt {
            expected: expected.to_string(),
            actual,
            bytes,
        }));
    }
    Ok(actual)
}

/// Reject artifact names that could escape the output directory.
pub fn safe_artifact_name(name: &str) -> Result<&str, FrontendError> {
    let invalid = name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\\')
        || name.chars().any(char::is_control);
    if invalid {
        return Err(FrontendError::Client(ClientError::InvalidReply(format!(
            "the Agent reported an unsafe artifact name {name:?}"
        ))));
    }
    Ok(name)
}

/// Local JSON record written next to the IPA.
pub fn record_path(out_dir: &Path, build_name: &str) -> PathBuf {
    out_dir.join(format!("{build_name}-artifact.json"))
}

/// Installation guide written next to the IPA.
pub fn install_guide_path(out_dir: &Path, build_name: &str) -> PathBuf {
    out_dir.join(format!("{build_name}-INSTALL.txt"))
}

/// Write a file through a temporary name and a rename, so an interrupted write
/// never leaves a half-written record behind.
pub fn write_atomic(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    let target = paths::extended_length_path(path);
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    paths::ensure_dir(parent)?;
    let mut temporary = target.clone();
    let extension = target
        .extension()
        .map(|extension| extension.to_string_lossy().to_string())
        .unwrap_or_default();
    let name = if extension.is_empty() {
        "tmp".to_string()
    } else {
        format!("tmp.{extension}")
    };
    temporary.set_file_name(format!(".{name}.builder"));
    {
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(contents)?;
        file.flush()?;
    }
    match std::fs::rename(&temporary, &target) {
        Ok(()) => Ok(()),
        Err(error) => {
            let _ = std::fs::remove_file(&temporary);
            Err(error)
        }
    }
}

/// Serialise and write the artifact record.
pub fn write_record(
    out_dir: &Path,
    build_name: &str,
    record: &ArtifactRecord,
) -> Result<PathBuf, FrontendError> {
    let path = record_path(out_dir, build_name);
    let text = serde_json::to_string_pretty(record).map_err(|error| {
        FrontendError::local(format!("cannot serialise the artifact record: {error}"))
    })?;
    write_atomic(&path, text.as_bytes()).map_err(|error| {
        FrontendError::local(format!(
            "cannot write {}: {error}",
            paths::display_path(&path)
        ))
    })?;
    Ok(path)
}

/// Write the human-readable install guide file.
pub fn write_install_guide(
    out_dir: &Path,
    build_name: &str,
    text: &str,
) -> Result<PathBuf, FrontendError> {
    let path = install_guide_path(out_dir, build_name);
    write_atomic(&path, text.as_bytes()).map_err(|error| {
        FrontendError::local(format!(
            "cannot write {}: {error}",
            paths::display_path(&path)
        ))
    })?;
    Ok(path)
}

/// The IPA file of an artifact record.
pub fn ipa_file(record: &ArtifactRecord) -> &ArtifactFile {
    &record.ipa
}

/// Find `ipa_sha256=` in a manifest and return its value.
pub fn manifest_sha256(text: &str) -> Option<String> {
    text.lines().find_map(|line| {
        line.trim()
            .strip_prefix("ipa_sha256=")
            .map(|value| value.trim().to_string())
    })
}

/// Open a folder (or select a file's folder) in the OS file manager.
///
/// Failure to launch a file manager is not a build failure; the caller reports
/// the path and continues.
pub fn open_in_file_manager(path: &Path) -> Result<(), FrontendError> {
    #[cfg(windows)]
    let mut command = {
        let target = paths::extended_length_path(path);
        let mut command = Command::new("explorer.exe");
        if path.is_file() {
            command.arg(format!("/select,{}", target.to_string_lossy()));
        } else {
            command.arg(&target);
        }
        command
    };
    #[cfg(target_os = "macos")]
    let mut command = {
        let target = paths::extended_length_path(path);
        let mut command = Command::new("open");
        command.arg("-R").arg(&target);
        command
    };
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut command = {
        let mut command = Command::new("xdg-open");
        let directory = if path.is_file() {
            path.parent().unwrap_or(path).to_path_buf()
        } else {
            path.to_path_buf()
        };
        command.arg(directory);
        command
    };
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command.spawn().map(|_| ()).map_err(|error| {
        FrontendError::local(format!(
            "could not open the file manager for {}: {error}",
            paths::display_path(path)
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, bytes: &[u8]) {
        std::fs::write(path, bytes).unwrap();
    }

    #[test]
    fn checksums_are_verified() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file.bin");
        write(&path, b"hello");
        let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
        assert_eq!(verify_sha256(&path, expected).unwrap(), expected);
        assert_eq!(
            verify_sha256(&path, &expected.to_ascii_uppercase()).unwrap(),
            expected
        );
        let error = verify_sha256(&path, "00").unwrap_err();
        assert!(matches!(
            error,
            FrontendError::Client(ClientError::ArtifactCorrupt { .. })
        ));
        assert_eq!(crate::errors::exit_code(&error), 5);
    }

    #[test]
    fn artifact_names_cannot_escape_the_output_directory() {
        assert_eq!(
            safe_artifact_name("pokemon-y-AOT.ipa").unwrap(),
            "pokemon-y-AOT.ipa"
        );
        for bad in [
            "",
            ".",
            "..",
            "../x.ipa",
            r"..\x.ipa",
            "dir/x.ipa",
            "a\u{0}.ipa",
        ] {
            assert!(safe_artifact_name(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn record_and_guide_paths_are_derived_from_the_build_name() {
        let out = Path::new("out");
        assert_eq!(
            record_path(out, "pokemon-y"),
            out.join("pokemon-y-artifact.json")
        );
        assert_eq!(
            install_guide_path(out, "pokemon-y"),
            out.join("pokemon-y-INSTALL.txt")
        );
        assert_eq!(
            record_path(out, "pokemon-y").file_name().unwrap(),
            "pokemon-y-artifact.json"
        );
    }

    #[test]
    fn atomic_write_replaces_and_creates_parents() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("file.txt");
        write_atomic(&path, b"one").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "one");
        write_atomic(&path, b"two").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "two");
        let leftovers: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name.contains(".builder"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    #[test]
    fn manifest_checksums_are_parsed() {
        let text = "name=pokemon-y\nipa_sha256=abc123\nipa_bytes=100\n";
        assert_eq!(manifest_sha256(text), Some("abc123".to_string()));
        assert_eq!(manifest_sha256("nothing here"), None);
    }
}
