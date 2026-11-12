//! Builder client: the session logic over one control channel.
//!
//! The CLI (and, later, the GUI backends) use this type; it contains no
//! presentation logic. All calls are synchronous and sequential: a build
//! session is create → upload → subscribe → (artifact → download → ack), which
//! mirrors how the protocol is used and keeps the reference client easy to
//! audit.

use std::collections::VecDeque;
use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use serde::de::DeserializeOwned;

use crate::hash::{sha256_file, verify_file, HashingWriter, VerifyOutcome};
use crate::protocol::codes::ErrorCode;
use crate::protocol::frames::{
    ArtifactAckRequest, ArtifactManifestRequest, ArtifactManifestResult, FrameMessage,
    HelloRequest, HelloResult, JobCancelRequest, JobCancelResult, JobCreateRequestFrame,
    JobCreated, JobDeleteRequest, JobDeleteResult, JobEventFrame, JobInputReadyRequest,
    JobInputReadyResult, JobListRequest, JobListResult, JobStatusRequest, JobStatusResult,
    JobSubscribeRequest, JobSubscribeResult, RawFrame, UploadComplete,
};
use crate::protocol::model::{
    ArtifactRecord, ClientInfo, ErrorInfo, InputRole, JobCreateRequest, JobEvent, JobView,
    UploadProgress, UploadRole, UploadStatusReply,
};
use crate::protocol::{normalize_sha256, valid_job_id, PROTOCOL};
use crate::transport::{ControlChannel, TransportError, TransportSpec};
use crate::{CLIENT_NAME, MIN_AGENT_VERSION, VERSION};

/// Capabilities this client can use when the Agent advertises them.
pub const CLIENT_FEATURES: [&str; 2] = ["events.stream", "upload.resume"];

/// Size of the chunks the client writes into an upload channel.
const UPLOAD_CHUNK: usize = 1024 * 1024;
/// Size of the chunks read from a download channel.
const DOWNLOAD_CHUNK: usize = 256 * 1024;
/// Lines of Agent stderr kept for diagnostics.
const STDERR_TAIL_LINES: usize = 40;

/// Client-side error.
#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    #[error("transport error: {0}")]
    Transport(#[from] TransportError),
    #[error("protocol error: {0}")]
    Protocol(#[from] crate::protocol::ProtocolError),
    #[error("agent error [{code}]: {message}", code = .error.code, message = .error.message)]
    Remote { error: ErrorInfo },
    #[error("unexpected frame {got:?} while waiting for {expected:?}")]
    UnexpectedFrame {
        expected: &'static str,
        got: Option<String>,
    },
    #[error("the agent channel closed while waiting for {0}")]
    Closed(&'static str),
    #[error("local i/o error during {context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },
    #[error("{0}")]
    Local(String),
    #[error("agent subcommand {operation} failed with exit code {code}{suffix}", suffix = format_stderr(stderr))]
    AgentExit {
        operation: String,
        code: i32,
        stderr: String,
    },
    #[error("invalid agent reply: {0}")]
    InvalidReply(String),
    #[error("artifact checksum mismatch: expected {expected}, computed {actual} ({bytes} bytes)")]
    ArtifactCorrupt {
        expected: String,
        actual: String,
        bytes: u64,
    },
}

fn format_stderr(stderr: &str) -> String {
    if stderr.trim().is_empty() {
        String::new()
    } else {
        format!("; stderr: {stderr}")
    }
}

impl ClientError {
    /// Protocol error code, when the failure came from the Agent.
    pub fn code(&self) -> Option<ErrorCode> {
        match self {
            ClientError::Remote { error } => Some(error.code),
            _ => None,
        }
    }

    /// Whether retrying the same request may succeed without user action.
    pub fn is_retryable(&self) -> bool {
        match self {
            ClientError::Remote { error } => error.retryable || error.code.retryable(),
            ClientError::Transport(_) => true,
            _ => false,
        }
    }

    /// Actionable hint for the user, when the protocol supplied one.
    pub fn hint(&self) -> Option<&str> {
        match self {
            ClientError::Remote { error } => error.hint.as_deref(),
            _ => None,
        }
    }
}

/// Result of uploading one input role.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadOutcome {
    pub received_bytes: u64,
    pub bytes: u64,
    pub sha256_ok: bool,
    /// Bytes already present on the Agent before this call.
    pub resumed_from: u64,
    pub already_complete: bool,
}

/// Which artifact file to download.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactWhat {
    Ipa,
    ManifestTxt,
}

impl ArtifactWhat {
    pub fn as_str(self) -> &'static str {
        match self {
            ArtifactWhat::Ipa => "ipa",
            ArtifactWhat::ManifestTxt => "manifest-txt",
        }
    }
}

/// Result of downloading one artifact file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadOutcome {
    pub path: PathBuf,
    pub bytes: u64,
    pub sha256: String,
    pub resumed_from: u64,
}

/// An authenticated, hand-shaken control session with one Build Agent.
pub struct BuilderClient {
    transport: TransportSpec,
    channel: Box<dyn ControlChannel>,
    hello: HelloResult,
    next_tag: u64,
    pending_events: VecDeque<JobEvent>,
}

impl std::fmt::Debug for BuilderClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BuilderClient")
            .field("transport", &self.transport)
            .field("agent", &self.hello.agent)
            .field("ready", &self.hello.ready)
            .finish_non_exhaustive()
    }
}

impl BuilderClient {
    /// Open the control channel and perform the `hello` handshake.
    pub fn connect(transport: TransportSpec) -> Result<Self, ClientError> {
        let mut channel = transport.open_control()?;
        let hello_request = HelloRequest {
            tag: "t-1".to_string(),
            protocol: PROTOCOL.to_string(),
            client: client_info(),
            features: CLIENT_FEATURES
                .iter()
                .map(|value| value.to_string())
                .collect(),
        };
        channel.send_frame(&RawFrame::of(&hello_request)?)?;
        let reply = loop {
            let Some(raw) = channel.recv_frame()? else {
                return Err(ClientError::Closed("hello.result"));
            };
            if raw.is_error() {
                return Err(ClientError::Remote {
                    error: raw.decode_error()?,
                });
            }
            match raw.frame_type() {
                Some("hello.result") => break raw.decode::<HelloResult>()?,
                Some(_) => continue,
                None => return Err(ClientError::InvalidReply("frame without type".to_string())),
            }
        };
        if !crate::protocol::protocol_compatible(&reply.protocol) {
            return Err(ClientError::Remote {
                error: ErrorInfo::new(
                    ErrorCode::UnsupportedProtocol,
                    format!(
                        "agent speaks {}, this client speaks {PROTOCOL}",
                        reply.protocol
                    ),
                ),
            });
        }
        if version_less_than(VERSION, &reply.min_client) {
            return Err(ClientError::Remote {
                error: ErrorInfo::new(
                    ErrorCode::UnsupportedAgent,
                    format!(
                        "this Agent requires Builder {}+, this is {VERSION}",
                        reply.min_client
                    ),
                ),
            });
        }
        Ok(Self {
            transport,
            channel,
            hello: reply,
            next_tag: 1,
            pending_events: VecDeque::new(),
        })
    }

    /// Handshake reply, including capabilities, toolchain and limits.
    pub fn hello(&self) -> &HelloResult {
        &self.hello
    }

    pub fn transport(&self) -> &TransportSpec {
        &self.transport
    }

    /// Close the control channel cleanly.
    pub fn close(mut self) -> Result<(), ClientError> {
        self.channel.close()?;
        Ok(())
    }

    fn next_tag(&mut self) -> String {
        self.next_tag += 1;
        format!("t-{}", self.next_tag)
    }

    /// Send a request and wait for its typed reply, ignoring keepalives and
    /// queueing asynchronous events that arrive in between.
    fn transact<Req, Res>(&mut self, mut request: Req) -> Result<Res, ClientError>
    where
        Req: FrameMessage,
        Res: FrameMessage,
    {
        let tag = self.next_tag();
        *request.tag_mut() = tag;
        self.channel.send_frame(&RawFrame::of(&request)?)?;
        loop {
            let Some(raw) = self.channel.recv_frame()? else {
                return Err(ClientError::Closed(Res::TYPE));
            };
            if raw.is_error() {
                return Err(ClientError::Remote {
                    error: raw.decode_error()?,
                });
            }
            match raw.frame_type() {
                Some(frame_type) if frame_type == Res::TYPE => {
                    return Ok(raw.decode::<Res>()?);
                }
                Some("job.event") => {
                    self.pending_events
                        .push_back(JobEvent::from(raw.decode::<JobEventFrame>()?));
                }
                Some("ping") | Some("pong") => {}
                Some(other) => {
                    return Err(ClientError::UnexpectedFrame {
                        expected: Res::TYPE,
                        got: Some(other.to_string()),
                    });
                }
                None => return Err(ClientError::InvalidReply("frame without type".to_string())),
            }
        }
    }

    // -----------------------------------------------------------------
    // Job operations
    // -----------------------------------------------------------------

    pub fn create_job(&mut self, request: JobCreateRequest) -> Result<JobCreated, ClientError> {
        if version_less_than(VERSION, &self.hello.min_client) {
            return Err(ClientError::Remote {
                error: ErrorInfo::new(
                    ErrorCode::UnsupportedClient,
                    format!(
                        "this Agent requires Builder {}+, this is {VERSION}",
                        self.hello.min_client
                    ),
                ),
            });
        }
        let created: JobCreated = self.transact(JobCreateRequestFrame::from(request))?;
        if !valid_job_id(&created.job_id) {
            return Err(ClientError::InvalidReply(format!(
                "agent returned an invalid job id {:?}",
                created.job_id
            )));
        }
        Ok(created)
    }

    pub fn input_ready(&mut self, job_id: &str) -> Result<JobInputReadyResult, ClientError> {
        self.transact(JobInputReadyRequest {
            tag: String::new(),
            job_id: job_id.to_string(),
        })
    }

    pub fn status(&mut self, job_id: &str) -> Result<JobView, ClientError> {
        let reply: JobStatusResult = self.transact(JobStatusRequest {
            tag: String::new(),
            job_id: job_id.to_string(),
        })?;
        Ok(reply.job)
    }

    pub fn subscribe(
        &mut self,
        job_id: &str,
        since_seq: u64,
    ) -> Result<JobSubscribeResult, ClientError> {
        self.transact(JobSubscribeRequest {
            tag: String::new(),
            job_id: job_id.to_string(),
            since_seq,
        })
    }

    /// Next event on the current subscription. `Ok(None)` means the channel
    /// closed (the job itself keeps running on the Agent).
    pub fn next_event(&mut self) -> Result<Option<JobEvent>, ClientError> {
        if let Some(event) = self.pending_events.pop_front() {
            return Ok(Some(event));
        }
        loop {
            let Some(raw) = self.channel.recv_frame()? else {
                return Ok(None);
            };
            if raw.is_error() {
                return Err(ClientError::Remote {
                    error: raw.decode_error()?,
                });
            }
            match raw.frame_type() {
                Some("job.event") => {
                    return Ok(Some(JobEvent::from(raw.decode::<JobEventFrame>()?)));
                }
                Some("ping") | Some("pong") => continue,
                Some(_) => continue,
                None => return Err(ClientError::InvalidReply("frame without type".to_string())),
            }
        }
    }

    pub fn cancel(
        &mut self,
        job_id: &str,
        reason: Option<&str>,
    ) -> Result<JobCancelResult, ClientError> {
        self.transact(JobCancelRequest {
            tag: String::new(),
            job_id: job_id.to_string(),
            reason: reason.map(str::to_string),
        })
    }

    pub fn list_jobs(
        &mut self,
        limit: Option<u32>,
        cursor: Option<&str>,
    ) -> Result<JobListResult, ClientError> {
        self.transact(JobListRequest {
            tag: String::new(),
            limit,
            cursor: cursor.map(str::to_string),
        })
    }

    pub fn delete_job(&mut self, job_id: &str) -> Result<JobDeleteResult, ClientError> {
        self.transact(JobDeleteRequest {
            tag: String::new(),
            job_id: job_id.to_string(),
        })
    }

    pub fn artifact_manifest(&mut self, job_id: &str) -> Result<ArtifactRecord, ClientError> {
        let reply: ArtifactManifestResult = self.transact(ArtifactManifestRequest {
            tag: String::new(),
            job_id: job_id.to_string(),
        })?;
        Ok(reply.artifact)
    }

    /// Fire-and-forget acknowledgement after a verified download.
    pub fn ack_artifact(&mut self, job_id: &str, sha256: &str) -> Result<(), ClientError> {
        let frame = RawFrame::of(&ArtifactAckRequest {
            tag: self.next_tag(),
            job_id: job_id.to_string(),
            artifact_sha256: sha256.to_string(),
        })?;
        self.channel.send_frame(&frame)?;
        Ok(())
    }

    // -----------------------------------------------------------------
    // Data channels
    // -----------------------------------------------------------------

    fn spawn_data_channel(&self, subcommand: &str) -> Result<Child, ClientError> {
        self.transport
            .spawn_agent(subcommand, Stdio::piped(), Stdio::piped(), Stdio::piped())
            .map_err(ClientError::Transport)
    }

    pub fn upload_status(
        &self,
        job_id: &str,
        role: InputRole,
    ) -> Result<UploadStatusReply, ClientError> {
        ensure_job_id(job_id)?;
        let subcommand = format!("upload-status --job {job_id} --role {}", role.as_str());
        let mut child = self.spawn_data_channel(&subcommand)?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ClientError::Local("upload-status stdout missing".into()))?;
        let stderr = child.stderr.take();
        let (stderr_tail, stderr_thread) = spawn_stderr_collector(stderr);

        let mut reply: Option<UploadStatusReply> = None;
        let mut remote_error: Option<ErrorInfo> = None;
        for line in BufReader::new(stdout).lines() {
            let line = line.map_err(|error| ClientError::Io {
                context: "reading upload status".into(),
                source: error,
            })?;
            if line.trim().is_empty() {
                continue;
            }
            let raw = RawFrame::from_line(&line)?;
            if raw.is_error() {
                remote_error = Some(raw.decode_error()?);
                continue;
            }
            if raw.frame_type() == Some("upload.status") {
                reply = Some(serde_json::from_str(&line).map_err(|error| {
                    ClientError::InvalidReply(format!("bad upload.status line: {error}"))
                })?);
            }
        }
        let status = child.wait().map_err(|error| ClientError::Io {
            context: "waiting for upload-status".into(),
            source: error,
        })?;
        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }
        if let Some(error) = remote_error {
            return Err(ClientError::Remote { error });
        }
        if !status.success() {
            return Err(ClientError::AgentExit {
                operation: "upload-status".to_string(),
                code: status.code().unwrap_or(-1),
                stderr: take_stderr(&stderr_tail),
            });
        }
        reply
            .ok_or_else(|| ClientError::InvalidReply("upload-status printed no status".to_string()))
    }

    /// Upload one declared input role, resuming from the Agent's offset.
    pub fn upload<F>(
        &self,
        job_id: &str,
        role: InputRole,
        path: &Path,
        declared: &UploadRole,
        mut on_progress: F,
    ) -> Result<UploadOutcome, ClientError>
    where
        F: FnMut(u64, u64),
    {
        ensure_job_id(job_id)?;
        if declared.role != role {
            return Err(ClientError::Local(format!(
                "declared role {} does not match upload role {}",
                declared.role, role
            )));
        }
        let local = sha256_file(path).map_err(|error| ClientError::Io {
            context: format!("hashing {}", path.display()),
            source: error,
        })?;
        if local.bytes != declared.bytes {
            return Err(ClientError::Local(format!(
                "{} is {} bytes but the job declared {} bytes",
                path.display(),
                local.bytes,
                declared.bytes
            )));
        }
        if !local.sha256.eq_ignore_ascii_case(&declared.sha256) {
            return Err(ClientError::Local(format!(
                "{} has SHA256 {} but the job declared {}",
                path.display(),
                local.sha256,
                declared.sha256
            )));
        }

        let status = self.upload_status(job_id, role)?;
        if status.complete {
            return Ok(UploadOutcome {
                received_bytes: status.received_bytes,
                bytes: status.bytes,
                sha256_ok: status.sha256_ok,
                resumed_from: 0,
                already_complete: true,
            });
        }
        let offset = status.received_bytes.min(declared.bytes);

        let subcommand = format!(
            "upload --job {job_id} --role {} --bytes {} --sha256 {} --offset {}",
            role.as_str(),
            declared.bytes,
            declared.sha256,
            offset
        );
        let mut child = self.spawn_data_channel(&subcommand)?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| ClientError::Local("upload stdin missing".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ClientError::Local("upload stdout missing".into()))?;
        let stderr = child.stderr.take();
        let (stderr_tail, stderr_thread) = spawn_stderr_collector(stderr);

        let file_path = path.to_path_buf();
        let writer: JoinHandle<std::io::Result<u64>> = std::thread::spawn(move || {
            let mut file = File::open(&file_path)?;
            file.seek(SeekFrom::Start(offset))?;
            let mut buffer = vec![0_u8; UPLOAD_CHUNK];
            let mut written = 0_u64;
            loop {
                let read = file.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                stdin.write_all(&buffer[..read])?;
                written += read as u64;
                if written % (UPLOAD_CHUNK as u64 * 8) == 0 {
                    stdin.flush()?;
                }
            }
            stdin.flush()?;
            Ok(written)
        });

        let mut complete: Option<UploadComplete> = None;
        let mut remote_error: Option<ErrorInfo> = None;
        for line in BufReader::new(stdout).lines() {
            let line = line.map_err(|error| ClientError::Io {
                context: "reading upload progress".into(),
                source: error,
            })?;
            if line.trim().is_empty() {
                continue;
            }
            let raw = RawFrame::from_line(&line)?;
            if raw.is_error() {
                remote_error = Some(raw.decode_error()?);
                continue;
            }
            match raw.frame_type() {
                Some("upload.progress") => {
                    let progress: UploadProgress =
                        serde_json::from_str(&line).map_err(|error| {
                            ClientError::InvalidReply(format!("bad upload.progress: {error}"))
                        })?;
                    on_progress(progress.received_bytes, progress.bytes);
                }
                Some("upload.complete") => {
                    complete = Some(serde_json::from_str(&line).map_err(|error| {
                        ClientError::InvalidReply(format!("bad upload.complete: {error}"))
                    })?);
                }
                _ => {}
            }
        }

        let written = writer
            .join()
            .map_err(|_| ClientError::Local("upload writer thread panicked".to_string()))?
            .map_err(|error| ClientError::Io {
                context: "streaming upload".into(),
                source: error,
            })?;
        let status = child.wait().map_err(|error| ClientError::Io {
            context: "waiting for upload".into(),
            source: error,
        })?;
        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }
        let _ = written;
        if let Some(error) = remote_error {
            return Err(ClientError::Remote { error });
        }
        let Some(complete) = complete else {
            return Err(ClientError::AgentExit {
                operation: "upload".to_string(),
                code: status.code().unwrap_or(-1),
                stderr: take_stderr(&stderr_tail),
            });
        };
        if !status.success() || !complete.sha256_ok {
            return Err(ClientError::Remote {
                error: ErrorInfo::new(
                    ErrorCode::InputInvalid,
                    "the Agent rejected the uploaded file (size/SHA256 mismatch)".to_string(),
                ),
            });
        }
        Ok(UploadOutcome {
            received_bytes: complete.received_bytes,
            bytes: complete.bytes,
            sha256_ok: complete.sha256_ok,
            resumed_from: offset,
            already_complete: false,
        })
    }

    /// Download one artifact file, resuming from `resume_from` bytes, and verify
    /// the declared size and SHA256 (rehash the whole file after a resume).
    #[allow(clippy::too_many_arguments)]
    pub fn download_artifact<F>(
        &self,
        job_id: &str,
        what: ArtifactWhat,
        destination: &Path,
        expected_bytes: u64,
        expected_sha256: &str,
        resume_from: u64,
        mut on_progress: F,
    ) -> Result<DownloadOutcome, ClientError>
    where
        F: FnMut(u64, u64),
    {
        ensure_job_id(job_id)?;
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent).map_err(|error| ClientError::Io {
                context: format!("creating {}", parent.display()),
                source: error,
            })?;
        }
        let subcommand = format!(
            "download-artifact --job {job_id} --what {} --offset {}",
            what.as_str(),
            resume_from
        );
        let mut child = self.spawn_data_channel(&subcommand)?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ClientError::Local("download stdout missing".into()))?;
        let stderr = child.stderr.take();
        let (stderr_tail, stderr_thread) = spawn_stderr_collector(stderr);

        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true);
        if resume_from > 0 {
            options.append(true);
        } else {
            options.truncate(true);
        }
        let file = options.open(destination).map_err(|error| ClientError::Io {
            context: format!("opening {}", destination.display()),
            source: error,
        })?;
        let mut writer = HashingWriter::new(file);
        let mut reader = BufReader::with_capacity(DOWNLOAD_CHUNK, stdout);
        let mut buffer = vec![0_u8; DOWNLOAD_CHUNK];
        loop {
            let read = reader.read(&mut buffer).map_err(|error| ClientError::Io {
                context: "reading artifact".into(),
                source: error,
            })?;
            if read == 0 {
                break;
            }
            writer
                .write_all(&buffer[..read])
                .map_err(|error| ClientError::Io {
                    context: format!("writing {}", destination.display()),
                    source: error,
                })?;
            on_progress(
                writer.bytes_written(),
                expected_bytes.saturating_sub(resume_from),
            );
        }
        writer.flush().map_err(|error| ClientError::Io {
            context: format!("flushing {}", destination.display()),
            source: error,
        })?;
        let streamed_hash = writer.finish();
        let status = child.wait().map_err(|error| ClientError::Io {
            context: "waiting for download".into(),
            source: error,
        })?;
        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }
        if !status.success() {
            let stderr = take_stderr(&stderr_tail);
            if let Some(error) = parse_error_from_stderr(&stderr) {
                return Err(ClientError::Remote { error });
            }
            let _ = std::fs::remove_file(destination);
            return Err(ClientError::AgentExit {
                operation: "download-artifact".to_string(),
                code: status.code().unwrap_or(-1),
                stderr,
            });
        }

        let outcome = if resume_from > 0 {
            match verify_file(destination, expected_sha256, expected_bytes) {
                Ok(VerifyOutcome::Match { sha256, bytes }) => DownloadOutcome {
                    path: destination.to_path_buf(),
                    bytes,
                    sha256,
                    resumed_from: resume_from,
                },
                Ok(other) => {
                    let _ = std::fs::remove_file(destination);
                    return Err(verify_error(other));
                }
                Err(error) => {
                    return Err(ClientError::Io {
                        context: format!("verifying {}", destination.display()),
                        source: error,
                    })
                }
            }
        } else {
            if !streamed_hash.eq_ignore_ascii_case(expected_sha256) {
                let _ = std::fs::remove_file(destination);
                let bytes = std::fs::metadata(destination)
                    .map(|meta| meta.len())
                    .unwrap_or(0);
                return Err(ClientError::ArtifactCorrupt {
                    expected: expected_sha256.to_ascii_lowercase(),
                    actual: streamed_hash,
                    bytes,
                });
            }
            DownloadOutcome {
                path: destination.to_path_buf(),
                bytes: std::fs::metadata(destination)
                    .map(|meta| meta.len())
                    .unwrap_or(0),
                sha256: streamed_hash,
                resumed_from: 0,
            }
        };
        Ok(outcome)
    }
}

fn ensure_job_id(job_id: &str) -> Result<(), ClientError> {
    if valid_job_id(job_id) {
        Ok(())
    } else {
        Err(ClientError::Local(format!("invalid job id {job_id:?}")))
    }
}

fn take_stderr(tail: &Arc<Mutex<VecDeque<String>>>) -> String {
    tail.lock()
        .map(|tail| tail.iter().cloned().collect::<Vec<_>>().join("\n"))
        .unwrap_or_default()
}

fn spawn_stderr_collector(
    stderr: Option<ChildStderr>,
) -> (Arc<Mutex<VecDeque<String>>>, Option<JoinHandle<()>>) {
    let tail = Arc::new(Mutex::new(VecDeque::new()));
    let Some(stderr) = stderr else {
        return (tail, None);
    };
    let sink = Arc::clone(&tail);
    let handle = std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines() {
            let Ok(line) = line else { break };
            let line = line.trim_end().to_string();
            if line.is_empty() {
                continue;
            }
            let mut tail = sink.lock().expect("stderr tail poisoned");
            if tail.len() == STDERR_TAIL_LINES {
                tail.pop_front();
            }
            tail.push_back(line);
        }
    });
    (tail, Some(handle))
}

fn parse_error_from_stderr(stderr: &str) -> Option<ErrorInfo> {
    stderr
        .lines()
        .rev()
        .find_map(|line| RawFrame::from_line(line.trim()).ok())
        .filter(RawFrame::is_error)
        .and_then(|frame| frame.decode_error().ok())
}

fn verify_error(outcome: VerifyOutcome) -> ClientError {
    match outcome {
        VerifyOutcome::Match { .. } => {
            ClientError::Local("verification unexpectedly matched".into())
        }
        VerifyOutcome::HashMismatch {
            expected,
            actual,
            bytes,
        } => ClientError::ArtifactCorrupt {
            expected,
            actual,
            bytes,
        },
        VerifyOutcome::SizeMismatch { expected, actual } => ClientError::Local(format!(
            "downloaded artifact has {actual} bytes, expected {expected}"
        )),
    }
}

/// Client identity sent in `hello`.
pub fn client_info() -> ClientInfo {
    ClientInfo {
        name: CLIENT_NAME.to_string(),
        version: VERSION.to_string(),
        os: std::env::consts::OS.to_string(),
        os_version: None,
    }
}

/// Compare dotted versions numerically (`0.9.0` < `0.10.0`).
pub fn version_less_than(left: &str, right: &str) -> bool {
    fn parse(value: &str) -> Vec<u64> {
        value
            .trim_start_matches('v')
            .split(['.', '-', '+'])
            .map(|part| part.parse::<u64>().unwrap_or(0))
            .collect()
    }
    let mut left = parse(left);
    let mut right = parse(right);
    let length = left.len().max(right.len());
    left.resize(length, 0);
    right.resize(length, 0);
    left < right
}

/// Client features advertised in `hello`.
pub fn client_features() -> Vec<String> {
    CLIENT_FEATURES
        .iter()
        .map(|value| value.to_string())
        .collect()
}

/// Normalise a user-supplied SHA256, returning a helpful error.
pub fn parse_sha256(value: &str) -> Result<String, String> {
    normalize_sha256(value).ok_or_else(|| format!("{value:?} is not a 64-character hex SHA256"))
}

/// Check that a checksum the Agent reported is well formed.
pub fn check_reported_sha256(value: &str) -> Result<(), String> {
    normalize_sha256(value)
        .map(|_| ())
        .ok_or_else(|| format!("agent reported an invalid SHA256: {value:?}"))
}

/// A `hex`-free re-export used by the CLI for display of hashes.
pub fn format_sha256(value: &str) -> String {
    value.to_ascii_lowercase()
}

/// Deserialize a JSON object from a line, used for data-channel status lines.
pub fn from_json_line<T: DeserializeOwned>(line: &str) -> Result<T, ClientError> {
    serde_json::from_str(line).map_err(|error| ClientError::InvalidReply(error.to_string()))
}

/// The protocol this client speaks.
pub fn protocol_version() -> &'static str {
    PROTOCOL
}

/// Minimum Agent version accepted by this client.
pub fn minimum_agent_version() -> &'static str {
    MIN_AGENT_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_comparison_is_numeric() {
        assert!(version_less_than("0.1.0", "0.2.0"));
        assert!(version_less_than("0.9.0", "0.10.0"));
        assert!(version_less_than("0.1.0", "0.1.1"));
        assert!(!version_less_than("0.1.0", "0.1.0"));
        assert!(!version_less_than("1.0.0", "0.9.9"));
        assert!(!version_less_than("0.2.0", "0.2"));
        assert!(version_less_than("0.2", "0.2.1"));
    }

    #[test]
    fn sha256_helpers() {
        assert!(parse_sha256(&"a".repeat(64)).is_ok());
        assert!(parse_sha256("abc").is_err());
        assert!(check_reported_sha256(&"A".repeat(64)).is_ok());
        assert!(check_reported_sha256("zz").is_err());
    }

    #[test]
    fn event_frame_converts_to_model() {
        let frame = JobEventFrame {
            tag: String::new(),
            seq: 3,
            job_id: "job_01J8Z3K4T9ABCDEFGHJKMNPQRS".into(),
            ts: "2026-11-12T19:44:01Z".into(),
            kind: crate::protocol::model::EventKind::Log,
            stage: Some(crate::protocol::model::Stage::Recompiling),
            source: Some(crate::protocol::model::LogSource::Script),
            level: Some(crate::protocol::model::LogLevel::Info),
            line: Some("[build-recomp] compiling".into()),
            line_part: None,
            line_parts: None,
            state: None,
            error: None,
            artifact: None,
            message: None,
        };
        let event = JobEvent::from(frame);
        assert_eq!(event.seq, 3);
        assert_eq!(event.line.as_deref(), Some("[build-recomp] compiling"));
        assert_eq!(
            event.stage,
            Some(crate::protocol::model::Stage::Recompiling)
        );
    }

    #[test]
    fn invalid_job_ids_are_rejected_before_spawning() {
        assert!(ensure_job_id("job_01J8Z3K4T9ABCDEFGHJKMNPQRS").is_ok());
        assert!(ensure_job_id("../../etc/passwd").is_err());
    }

    #[test]
    fn error_from_stderr_line() {
        let stderr = "ssh: connect to host failed\n{\"type\":\"error\",\"tag\":\"\",\"error\":{\"code\":\"not_found\",\"message\":\"no such job\",\"retryable\":false}}\n";
        let error = parse_error_from_stderr(stderr).unwrap();
        assert_eq!(error.code, ErrorCode::NotFound);
        assert!(parse_error_from_stderr("plain text").is_none());
    }
}
