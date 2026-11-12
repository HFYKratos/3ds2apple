//! Control sessions: NDJSON frames over stdio (SSH forced command) or over a
//! Unix socket (daemon mode).
//!
//! One session handles one client connection. Commands are read on a helper
//! thread while asynchronous `job.event` frames from an active subscription are
//! written from the main loop.

use std::io::{self, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::mpsc::{self, TryRecvError};
use std::sync::Arc;
use std::time::Duration;

use builder_core::framing::{FrameReader, FrameWriter};
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::frames::{
    error_frame, ArtifactAckRequest, ArtifactManifestRequest, ArtifactManifestResult, FrameMessage,
    HelloRequest, JobCancelRequest, JobCreateRequestFrame, JobDeleteRequest, JobEventFrame,
    JobInputReadyRequest, JobListRequest, JobStatusRequest, JobStatusResult, JobSubscribeRequest,
    Pong, RawFrame,
};
use builder_core::protocol::model::ErrorInfo;
use builder_core::protocol::{protocol_compatible, PROTOCOL};

use crate::service::{Service, Subscription};
use crate::util;

/// How often the session loop wakes up to check for commands/events.
const POLL: Duration = Duration::from_millis(5);

/// Decode a frame or answer with a `bad_request` error; the caller returns.
macro_rules! decode_or_error {
    ($session:expr, $frame:expr, $tag:expr) => {
        match $frame.decode() {
            Ok(message) => message,
            Err(error) => {
                $session.send_error(
                    &$tag,
                    ErrorInfo::new(ErrorCode::BadRequest, error.to_string()),
                )?;
                return Ok(true);
            }
        }
    };
}

/// Run one control session over the given stdio pair.
pub fn run_session(
    service: &Arc<Service>,
    input: Box<dyn Read + Send>,
    output: Box<dyn Write + Send>,
) -> io::Result<()> {
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("builder-agent-session-reader".to_string())
        .spawn(move || {
            let mut reader = FrameReader::new(BufReader::new(input));
            loop {
                match reader.read_frame() {
                    Ok(Some(frame)) => {
                        if tx.send(Ok(Some(frame))).is_err() {
                            return;
                        }
                    }
                    Ok(None) => {
                        let _ = tx.send(Ok(None));
                        return;
                    }
                    Err(error) => {
                        let _ = tx.send(Err(error.to_string()));
                        return;
                    }
                }
            }
        })
        .expect("could not start the session reader thread");

    let mut session = Session {
        service: Arc::clone(service),
        writer: FrameWriter::new(output),
        handshaken: false,
        subscription: None,
    };

    loop {
        session.drain_events()?;
        match rx.recv_timeout(POLL) {
            Ok(Ok(Some(frame))) => {
                if !session.handle(frame)? {
                    break;
                }
            }
            Ok(Ok(None)) => break,
            Ok(Err(message)) => {
                session.send_error("", ErrorInfo::new(ErrorCode::BadRequest, message))?;
                break;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    Ok(())
}

/// Run the daemon: listen on a Unix socket and serve sessions until killed.
pub fn run_daemon(service: Arc<Service>, socket_path: &Path) -> io::Result<()> {
    if let Some(parent) = socket_path.parent() {
        util::ensure_private_dir(parent)?;
    }
    if socket_path.exists() {
        match UnixStream::connect(socket_path) {
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    format!(
                        "another Agent is already listening on {}",
                        socket_path.display()
                    ),
                ))
            }
            Err(_) => {
                // Stale socket from a crashed daemon.
                let _ = std::fs::remove_file(socket_path);
            }
        }
    }
    let listener = UnixListener::bind(socket_path)?;
    util::set_private_file(socket_path)?;
    eprintln!(
        "builder-agent {} listening on {}",
        builder_core::VERSION,
        socket_path.display()
    );
    for connection in listener.incoming() {
        let stream = match connection {
            Ok(stream) => stream,
            Err(error) => {
                eprintln!("builder-agent: accept failed: {error}");
                continue;
            }
        };
        let service = Arc::clone(&service);
        std::thread::Builder::new()
            .name("builder-agent-session".to_string())
            .spawn(move || {
                let reader = match stream.try_clone() {
                    Ok(reader) => reader,
                    Err(error) => {
                        eprintln!("builder-agent: session clone failed: {error}");
                        return;
                    }
                };
                if let Err(error) = run_session(&service, Box::new(reader), Box::new(stream)) {
                    eprintln!("builder-agent: session ended: {error}");
                }
            })
            .ok();
    }
    Ok(())
}

struct ActiveSubscription {
    subscription: Subscription,
    last_seq: u64,
}

struct Session {
    service: Arc<Service>,
    writer: FrameWriter<Box<dyn Write + Send>>,
    handshaken: bool,
    subscription: Option<ActiveSubscription>,
}

impl Session {
    fn write_frame<T: FrameMessage>(&mut self, message: &T) -> io::Result<()> {
        let frame = RawFrame::of(message).map_err(protocol_io)?;
        self.writer.write_frame(&frame).map_err(protocol_io)
    }

    fn write_raw(&mut self, frame: &RawFrame) -> io::Result<()> {
        self.writer.write_frame(frame).map_err(protocol_io)
    }

    fn send_error(&mut self, tag: &str, error: ErrorInfo) -> io::Result<()> {
        let frame = error_frame(tag.to_string(), error).map_err(protocol_io)?;
        self.write_raw(&frame)
    }

    fn drain_events(&mut self) -> io::Result<()> {
        let Some(mut active) = self.subscription.take() else {
            return Ok(());
        };
        let mut closed = false;
        loop {
            match active.subscription.events.try_recv() {
                Ok(event) => {
                    if event.seq <= active.last_seq {
                        continue;
                    }
                    active.last_seq = event.seq;
                    self.write_frame(&JobEventFrame::from(event))?;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    closed = true;
                    break;
                }
            }
        }
        if !closed {
            self.subscription = Some(active);
        }
        Ok(())
    }

    /// Handle one frame. Returns `false` when the channel must close.
    fn handle(&mut self, frame: RawFrame) -> io::Result<bool> {
        let tag = frame.tag().unwrap_or_default().to_string();
        let Some(frame_type) = frame.frame_type().map(str::to_string) else {
            self.send_error(
                &tag,
                ErrorInfo::new(ErrorCode::BadRequest, "frame without a type"),
            )?;
            return Ok(false);
        };

        if !self.handshaken && frame_type != "hello" {
            self.send_error(
                &tag,
                ErrorInfo::new(ErrorCode::BadRequest, "the first frame must be \"hello\""),
            )?;
            return Ok(false);
        }

        match frame_type.as_str() {
            "hello" => {
                let request: HelloRequest = match frame.decode() {
                    Ok(request) => request,
                    Err(error) => {
                        self.send_error(
                            &tag,
                            ErrorInfo::new(ErrorCode::BadRequest, error.to_string()),
                        )?;
                        return Ok(false);
                    }
                };
                if !protocol_compatible(&request.protocol) {
                    self.send_error(
                        &tag,
                        ErrorInfo::new(
                            ErrorCode::UnsupportedProtocol,
                            format!(
                                "this Agent speaks {PROTOCOL}, the client speaks {}",
                                request.protocol
                            ),
                        ),
                    )?;
                    return Ok(false);
                }
                let mut reply = self.service.hello_result();
                reply.tag = tag;
                self.write_frame(&reply)?;
                self.handshaken = true;
                Ok(true)
            }
            "ping" => {
                self.write_frame(&Pong { tag })?;
                Ok(true)
            }
            "job.create" => {
                let request = match frame.decode::<JobCreateRequestFrame>() {
                    Ok(request) => request,
                    Err(error) => {
                        self.send_error(
                            &tag,
                            ErrorInfo::new(ErrorCode::BadRequest, error.to_string()),
                        )?;
                        return Ok(true);
                    }
                };
                match self.service.create_job(request.into()) {
                    Ok(mut reply) => {
                        reply.tag = tag;
                        self.write_frame(&reply)
                    }
                    Err(error) => self.send_error(&tag, error),
                }?;
                Ok(true)
            }
            "job.input_ready" => {
                let request: JobInputReadyRequest = decode_or_error!(self, frame, tag);
                match self.service.input_ready(&request.job_id) {
                    Ok(mut reply) => {
                        reply.tag = tag;
                        self.write_frame(&reply)
                    }
                    Err(error) => self.send_error(&tag, error),
                }?;
                Ok(true)
            }
            "job.status" => {
                let request: JobStatusRequest = decode_or_error!(self, frame, tag);
                match self.service.job_view(&request.job_id) {
                    Ok(job) => {
                        let reply = JobStatusResult { tag, job };
                        self.write_frame(&reply)
                    }
                    Err(error) => self.send_error(&tag, error),
                }?;
                Ok(true)
            }
            "job.subscribe" => {
                let request: JobSubscribeRequest = decode_or_error!(self, frame, tag);
                match self.service.subscribe(&request.job_id, request.since_seq) {
                    Ok((subscription, mut reply)) => {
                        reply.tag = tag.clone();
                        let replay = subscription.replay.clone();
                        let last_seq = replay.last().map(|event| event.seq).unwrap_or(0);
                        self.write_frame(&reply)?;
                        for event in replay {
                            self.write_frame(&JobEventFrame::from(event))?;
                        }
                        self.subscription = Some(ActiveSubscription {
                            subscription,
                            last_seq,
                        });
                        Ok(true)
                    }
                    Err(error) => {
                        self.send_error(&tag, error)?;
                        Ok(true)
                    }
                }
            }
            "job.cancel" => {
                let request: JobCancelRequest = decode_or_error!(self, frame, tag);
                match self
                    .service
                    .cancel_job(&request.job_id, request.reason.as_deref())
                {
                    Ok(mut reply) => {
                        reply.tag = tag;
                        self.write_frame(&reply)
                    }
                    Err(error) => self.send_error(&tag, error),
                }?;
                Ok(true)
            }
            "job.list" => {
                let request: JobListRequest = decode_or_error!(self, frame, tag);
                match self
                    .service
                    .list_jobs(request.limit, request.cursor.as_deref())
                {
                    Ok(mut reply) => {
                        reply.tag = tag;
                        self.write_frame(&reply)
                    }
                    Err(error) => self.send_error(&tag, error),
                }?;
                Ok(true)
            }
            "job.delete" => {
                let request: JobDeleteRequest = decode_or_error!(self, frame, tag);
                match self.service.delete_job(&request.job_id) {
                    Ok(mut reply) => {
                        reply.tag = tag;
                        self.write_frame(&reply)
                    }
                    Err(error) => self.send_error(&tag, error),
                }?;
                Ok(true)
            }
            "artifact.manifest" => {
                let request: ArtifactManifestRequest = decode_or_error!(self, frame, tag);
                match self.service.artifact_manifest(&request.job_id) {
                    Ok(artifact) => {
                        let reply = ArtifactManifestResult { tag, artifact };
                        self.write_frame(&reply)
                    }
                    Err(error) => self.send_error(&tag, error),
                }?;
                Ok(true)
            }
            "artifact.ack" => {
                if let Ok(request) = frame.decode::<ArtifactAckRequest>() {
                    let _ = self
                        .service
                        .ack_artifact(&request.job_id, &request.artifact_sha256);
                }
                // Fire-and-forget: no reply.
                Ok(true)
            }
            _unknown => {
                // Unknown frame types are ignored for forward compatibility; a
                // newer client may use frames this Agent does not implement.
                Ok(true)
            }
        }
    }
}

fn protocol_io(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}
