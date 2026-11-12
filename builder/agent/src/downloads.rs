//! Artifact download for the SSH binding: stream the IPA (or the build
//! manifest copy) to stdout, resumable by byte offset.
//!
//! Errors are written to stderr as JSON error frames so stdout stays pure
//! artifact bytes; the client already captures the stderr tail for diagnostics.

use std::io::{self, Read, Seek, SeekFrom, Write};

use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::frames::{error_frame, ErrorFrame, FrameMessage};
use builder_core::protocol::model::ErrorInfo;

use crate::store::{self, DataRoot};
use crate::uploads::{EXIT_INTERNAL, EXIT_OK, EXIT_STATE, EXIT_USAGE};

/// Which artifact file to stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactWhat {
    Ipa,
    ManifestTxt,
}

impl ArtifactWhat {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "ipa" => Some(ArtifactWhat::Ipa),
            "manifest-txt" => Some(ArtifactWhat::ManifestTxt),
            _ => None,
        }
    }
}

fn print_error_to_stderr(error: ErrorInfo) {
    if let Ok(frame) = error_frame("", error) {
        if let Ok(line) = frame.to_line() {
            let mut stderr = io::stderr().lock();
            let _ = stderr.write_all(line.as_bytes());
            let _ = stderr.write_all(b"\n");
            let _ = stderr.flush();
        }
    }
    let _ = ErrorFrame::TYPE;
}

/// Handle `download-artifact --job ... --what ipa|manifest-txt [--offset N]`.
pub fn run_download(data: &DataRoot, job_id: &str, what: ArtifactWhat, offset: u64) -> i32 {
    if !builder_core::protocol::valid_job_id(job_id) {
        print_error_to_stderr(ErrorInfo::new(ErrorCode::BadRequest, "invalid job id"));
        return EXIT_USAGE;
    }
    let job_dir = data.job_dir(job_id);
    let artifact_path = store::out_dir(&job_dir).join("artifact.json");
    let artifact: builder_core::protocol::model::ArtifactRecord =
        match crate::util::read_json(&artifact_path) {
            Ok(artifact) => artifact,
            Err(error) => {
                print_error_to_stderr(ErrorInfo::new(
                    ErrorCode::ArtifactNotReady,
                    format!("no artifact for job {job_id}: {error}"),
                ));
                return EXIT_STATE;
            }
        };
    let file = match what {
        ArtifactWhat::Ipa => &artifact.ipa,
        ArtifactWhat::ManifestTxt => &artifact.manifest_txt,
    };
    if !builder_core::protocol::valid_file_name(&file.name) {
        print_error_to_stderr(ErrorInfo::new(
            ErrorCode::Internal,
            "artifact record contains an unsafe file name",
        ));
        return EXIT_INTERNAL;
    }
    let out_dir = store::out_dir(&job_dir);
    let path = out_dir.join(&file.name);
    let canonical_out = match out_dir.canonicalize() {
        Ok(path) => path,
        Err(error) => {
            print_error_to_stderr(ErrorInfo::new(
                ErrorCode::ArtifactNotReady,
                format!("job output directory is missing: {error}"),
            ));
            return EXIT_STATE;
        }
    };
    let canonical = match path.canonicalize() {
        Ok(path) => path,
        Err(error) => {
            print_error_to_stderr(ErrorInfo::new(
                ErrorCode::ArtifactNotReady,
                format!("artifact {} is missing: {error}", path.display()),
            ));
            return EXIT_STATE;
        }
    };
    if !canonical.starts_with(&canonical_out) {
        print_error_to_stderr(ErrorInfo::new(
            ErrorCode::Internal,
            "artifact path escapes the job output directory",
        ));
        return EXIT_INTERNAL;
    }
    let mut file_handle = match std::fs::File::open(&canonical) {
        Ok(file) => file,
        Err(error) => {
            print_error_to_stderr(ErrorInfo::new(
                ErrorCode::ArtifactNotReady,
                format!("could not open the artifact: {error}"),
            ));
            return EXIT_STATE;
        }
    };
    let length = match file_handle.metadata() {
        Ok(metadata) => metadata.len(),
        Err(error) => {
            print_error_to_stderr(ErrorInfo::new(
                ErrorCode::Internal,
                format!("could not stat the artifact: {error}"),
            ));
            return EXIT_INTERNAL;
        }
    };
    if offset > length {
        print_error_to_stderr(ErrorInfo::new(
            ErrorCode::BadRequest,
            format!("offset {offset} is past the end of the {length}-byte artifact"),
        ));
        return EXIT_USAGE;
    }
    if offset > 0 {
        if let Err(error) = file_handle.seek(SeekFrom::Start(offset)) {
            print_error_to_stderr(ErrorInfo::new(
                ErrorCode::Internal,
                format!("could not seek the artifact: {error}"),
            ));
            return EXIT_INTERNAL;
        }
    }
    let mut stdout = io::stdout().lock();
    if let Err(error) = io::copy(&mut file_handle, &mut stdout) {
        let _ = stdout.flush();
        print_error_to_stderr(ErrorInfo::new(
            ErrorCode::Internal,
            format!("streaming the artifact failed: {error}"),
        ));
        return EXIT_INTERNAL;
    }
    let _ = stdout.flush();
    EXIT_OK
}

// Keep the `Read` trait import meaningful for builds where `io::copy` is
// inlined differently.
#[allow(dead_code)]
fn _read_trait<T: Read>(_: T) {}
