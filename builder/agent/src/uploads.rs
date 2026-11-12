//! Data-channel handlers for the SSH binding: `upload` and `upload-status`.
//!
//! The bytes arrive on stdin; JSON status lines go to stdout. The staging file
//! lives under `<job>/input/.staging/<role>.part` and only becomes the job's
//! input after the declared total size and SHA256 match. A dropped transfer
//! leaves the staging file in place for a resumable retry.

use std::io::{self, Read, Write};

use builder_core::hash::sha256_file;
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::frames::{error_frame, ErrorFrame, FrameMessage, UploadComplete};
use builder_core::protocol::model::{ErrorInfo, InputRole, UploadProgress, UploadStatusReply};
use builder_core::protocol::{normalize_sha256, UPLOAD_PROGRESS_EVERY};

use crate::store::{self, DataRoot};
use crate::util;

/// Upload request parameters, already parsed from the SSH subcommand line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadArgs {
    pub job_id: String,
    pub role: InputRole,
    pub bytes: u64,
    pub sha256: String,
    pub offset: u64,
}

/// Exit codes used by the data-channel subcommands.
pub const EXIT_OK: i32 = 0;
pub const EXIT_RETRYABLE: i32 = 1;
pub const EXIT_USAGE: i32 = 2;
pub const EXIT_STATE: i32 = 3;
pub const EXIT_INTERNAL: i32 = 64;

fn write_json_line<T: serde::Serialize>(value: &T) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

fn print_error(error: ErrorInfo) {
    if let Ok(frame) = error_frame("", error) {
        if let Ok(line) = frame.to_line() {
            let mut stdout = io::stdout().lock();
            let _ = stdout.write_all(line.as_bytes());
            let _ = stdout.write_all(b"\n");
            let _ = stdout.flush();
        }
    }
    let _ = ErrorFrame::TYPE;
}

fn load_job(data: &DataRoot, job_id: &str) -> Result<store::JobPersist, ErrorInfo> {
    if !builder_core::protocol::valid_job_id(job_id) {
        return Err(ErrorInfo::new(
            ErrorCode::BadRequest,
            format!("invalid job id {job_id:?}"),
        ));
    }
    store::load_job_json(&data.job_dir(job_id)).map_err(|error| {
        ErrorInfo::new(
            ErrorCode::NotFound,
            format!("unknown job {job_id}: {error}"),
        )
    })
}

fn declared_input(
    job: &store::JobPersist,
    role: InputRole,
) -> Result<&builder_core::protocol::model::InputSpec, ErrorInfo> {
    job.declared_input(role).ok_or_else(|| {
        ErrorInfo::new(
            ErrorCode::BadRequest,
            format!("job {} does not declare input role {role}", job.job_id),
        )
    })
}

/// Handle `upload --job ... --role ... --bytes ... --sha256 ... [--offset ...]`.
pub fn run_upload(data: &DataRoot, args: &UploadArgs) -> i32 {
    let job = match load_job(data, &args.job_id) {
        Ok(job) => job,
        Err(error) => {
            print_error(error);
            return EXIT_STATE;
        }
    };
    if job.state != builder_core::protocol::model::JobState::Created {
        print_error(ErrorInfo::new(
            ErrorCode::Conflict,
            format!("job {} is {}; uploads are closed", job.job_id, job.state),
        ));
        return EXIT_STATE;
    }
    let declared = match declared_input(&job, args.role) {
        Ok(declared) => declared.clone(),
        Err(error) => {
            print_error(error);
            return EXIT_USAGE;
        }
    };
    if args.bytes != declared.bytes {
        print_error(ErrorInfo::new(
            ErrorCode::BadRequest,
            format!(
                "job declared {} bytes for {}, upload says {}",
                declared.bytes, args.role, args.bytes
            ),
        ));
        return EXIT_USAGE;
    }
    let expected_sha = match normalize_sha256(&args.sha256) {
        Some(sha) => sha,
        None => {
            print_error(ErrorInfo::new(
                ErrorCode::BadRequest,
                "invalid SHA256 in upload command",
            ));
            return EXIT_USAGE;
        }
    };
    if !expected_sha.eq_ignore_ascii_case(&declared.sha256) {
        print_error(ErrorInfo::new(
            ErrorCode::BadRequest,
            "the SHA256 in the upload command does not match the one declared in job.create",
        ));
        return EXIT_USAGE;
    }

    let job_dir = data.job_dir(&job.job_id);
    let staging = store::staging_path(&job_dir, args.role);
    let input = store::input_path(&job_dir, args.role);
    if input.is_file() {
        print_error(ErrorInfo::new(
            ErrorCode::Conflict,
            format!("input {} was already uploaded", args.role),
        ));
        return EXIT_STATE;
    }
    let existing = std::fs::metadata(&staging)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    if args.offset != existing {
        print_error(ErrorInfo::new(
            ErrorCode::BadRequest,
            format!(
                "resume offset {} does not match the {} bytes already staged; query upload-status and resume",
                args.offset, existing
            ),
        ));
        return EXIT_USAGE;
    }
    std::fs::create_dir_all(staging.parent().unwrap_or(&job_dir)).ok();
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = match options.open(&staging) {
        Ok(file) => file,
        Err(error) => {
            print_error(ErrorInfo::new(
                ErrorCode::Internal,
                format!("could not open the staging file: {error}"),
            ));
            return EXIT_INTERNAL;
        }
    };
    let _ = util::set_private_file(&staging);

    let mut stdin = io::stdin().lock();
    let mut received = existing;
    let mut last_report = received;
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        match stdin.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                if let Err(error) = file.write_all(&buffer[..read]) {
                    print_error(ErrorInfo::new(
                        ErrorCode::Internal,
                        format!("could not write the staging file: {error}"),
                    ));
                    return EXIT_INTERNAL;
                }
                received += read as u64;
                if received >= args.bytes && received > args.bytes {
                    break;
                }
                if received - last_report >= UPLOAD_PROGRESS_EVERY {
                    last_report = received;
                    let _ = file.flush();
                    let _ = write_json_line(&UploadProgress {
                        frame_type: "upload.progress".to_string(),
                        received_bytes: received,
                        bytes: args.bytes,
                    });
                }
            }
            Err(error) => {
                print_error(ErrorInfo::new(
                    ErrorCode::UploadStalled,
                    format!("reading the upload stream failed: {error}"),
                ));
                return EXIT_RETRYABLE;
            }
        }
    }
    if let Err(error) = file.flush() {
        print_error(ErrorInfo::new(
            ErrorCode::Internal,
            format!("could not flush the staging file: {error}"),
        ));
        return EXIT_INTERNAL;
    }
    drop(file);

    if received < args.bytes {
        print_error(
            ErrorInfo::new(
                ErrorCode::UploadStalled,
                format!(
                    "received {received} of {} bytes; resume from that offset",
                    args.bytes
                ),
            )
            .with_details(serde_json::json!({ "received_bytes": received, "bytes": args.bytes })),
        );
        return EXIT_RETRYABLE;
    }
    if received > args.bytes {
        let _ = std::fs::remove_file(&staging);
        print_error(ErrorInfo::new(
            ErrorCode::PayloadTooLarge,
            format!(
                "received {received} bytes but the job declared {}",
                args.bytes
            ),
        ));
        return EXIT_USAGE;
    }

    let hash = match sha256_file(&staging) {
        Ok(hash) => hash,
        Err(error) => {
            print_error(ErrorInfo::new(
                ErrorCode::Internal,
                format!("could not hash the staging file: {error}"),
            ));
            return EXIT_INTERNAL;
        }
    };
    if !hash.sha256.eq_ignore_ascii_case(&declared.sha256) {
        let _ = std::fs::remove_file(&staging);
        print_error(
            ErrorInfo::new(
                ErrorCode::InputInvalid,
                format!(
                    "uploaded file SHA256 {} does not match the declared {}",
                    hash.sha256, declared.sha256
                ),
            )
            .with_details(serde_json::json!({
                "expected": declared.sha256,
                "actual": hash.sha256,
            })),
        );
        return EXIT_RETRYABLE;
    }
    if let Err(error) = std::fs::rename(&staging, &input) {
        print_error(ErrorInfo::new(
            ErrorCode::Internal,
            format!("could not move the uploaded file into place: {error}"),
        ));
        return EXIT_INTERNAL;
    }
    let _ = util::set_private_file(&input);
    let _ = write_json_line(&UploadComplete {
        frame_type: "upload.complete".to_string(),
        received_bytes: received,
        bytes: args.bytes,
        sha256_ok: true,
    });
    EXIT_OK
}

/// Handle `upload-status --job ... --role ...`.
pub fn run_status(data: &DataRoot, job_id: &str, role: InputRole) -> i32 {
    let job = match load_job(data, job_id) {
        Ok(job) => job,
        Err(error) => {
            print_error(error);
            return EXIT_STATE;
        }
    };
    let declared = match declared_input(&job, role) {
        Ok(declared) => declared,
        Err(error) => {
            print_error(error);
            return EXIT_USAGE;
        }
    };
    let job_dir = data.job_dir(&job.job_id);
    let input = store::input_path(&job_dir, role);
    let complete = input.is_file()
        && std::fs::metadata(&input)
            .map(|metadata| metadata.len() == declared.bytes)
            .unwrap_or(false);
    let received_bytes = if complete {
        declared.bytes
    } else {
        store::staging_size(&job_dir, role)
    };
    let reply = UploadStatusReply {
        frame_type: "upload.status".to_string(),
        received_bytes,
        bytes: declared.bytes,
        sha256_ok: complete,
        complete,
    };
    match write_json_line(&reply) {
        Ok(()) => EXIT_OK,
        Err(_) => EXIT_INTERNAL,
    }
}
