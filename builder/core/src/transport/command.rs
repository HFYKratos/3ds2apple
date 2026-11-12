//! Process-based control channel: the shared primitive behind both bindings.
//!
//! The Agent subprocess is started with piped stdio. Control frames are NDJSON
//! on stdin/stdout; stderr is captured into a bounded tail and only surfaces in
//! diagnostics (so a failed `ssh` connection is explainable without leaking
//! anything into the frame stream).

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use crate::framing::FrameReader;
use crate::protocol::frames::RawFrame;
use crate::protocol::MAX_FRAME_BYTES;
use crate::transport::{ControlChannel, TransportError};

/// Number of stderr lines kept for error messages.
const STDERR_TAIL_LINES: usize = 40;

/// A control channel over a child process's stdio.
#[derive(Debug)]
pub struct CommandChannel {
    child: Child,
    stdin: Option<BufWriter<ChildStdin>>,
    stdout: FrameReader<BufReader<ChildStdout>>,
    stderr_tail: Arc<Mutex<VecDeque<String>>>,
    stderr_thread: Option<JoinHandle<()>>,
    label: String,
    closed: bool,
}

impl CommandChannel {
    /// Spawn a configured command and start the stderr collector.
    pub fn spawn(command: &mut Command, label: &str) -> Result<Self, TransportError> {
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command.spawn().map_err(|error| TransportError::Spawn {
            program: label.to_string(),
            message: error.to_string(),
        })?;

        let stdin = child.stdin.take().ok_or_else(|| TransportError::Spawn {
            program: label.to_string(),
            message: "child stdin was not piped".to_string(),
        })?;
        let stdout = child.stdout.take().ok_or_else(|| TransportError::Spawn {
            program: label.to_string(),
            message: "child stdout was not piped".to_string(),
        })?;
        let stderr = child.stderr.take();

        let stderr_tail = Arc::new(Mutex::new(VecDeque::new()));
        let stderr_thread =
            stderr.map(|stderr| spawn_stderr_collector(stderr, Arc::clone(&stderr_tail)));

        Ok(Self {
            child,
            stdin: Some(BufWriter::new(stdin)),
            stdout: FrameReader::new(BufReader::new(stdout)),
            stderr_tail,
            stderr_thread,
            label: label.to_string(),
            closed: false,
        })
    }

    fn stderr_text(&self) -> String {
        let tail = self.stderr_tail.lock().expect("stderr tail poisoned");
        tail.iter().cloned().collect::<Vec<_>>().join("\n")
    }

    /// Wait for the child to exit, returning its status and stderr tail.
    fn reap(&mut self) -> Result<(i32, String), TransportError> {
        // Close our end of stdin first so a well-behaved child sees EOF.
        self.stdin.take();
        let status = self.child.wait()?;
        if let Some(handle) = self.stderr_thread.take() {
            let _ = handle.join();
        }
        let stderr = self.stderr_text();
        Ok((status.code().unwrap_or(-1), stderr))
    }
}

fn spawn_stderr_collector(
    stderr: ChildStderr,
    tail: Arc<Mutex<VecDeque<String>>>,
) -> JoinHandle<()> {
    std::thread::spawn(move || {
        let reader = BufReader::new(stderr);
        for line in reader.lines() {
            let Ok(line) = line else { break };
            let trimmed = line.trim_end().to_string();
            if trimmed.is_empty() {
                continue;
            }
            let mut tail = tail.lock().expect("stderr tail poisoned");
            if tail.len() == STDERR_TAIL_LINES {
                tail.pop_front();
            }
            tail.push_back(trimmed);
        }
    })
}

impl ControlChannel for CommandChannel {
    fn send_frame(&mut self, frame: &RawFrame) -> Result<(), TransportError> {
        let line = frame.to_line()?;
        let Some(stdin) = self.stdin.as_mut() else {
            return Err(TransportError::Closed(format!(
                "{}: channel already closed",
                self.label
            )));
        };
        stdin.write_all(line.as_bytes())?;
        stdin.write_all(b"\n")?;
        stdin.flush()?;
        Ok(())
    }

    fn recv_frame(&mut self) -> Result<Option<RawFrame>, TransportError> {
        match self.stdout.read_frame() {
            Ok(Some(frame)) => Ok(Some(frame)),
            Ok(None) => {
                let (code, stderr) = self.reap()?;
                self.closed = true;
                if code == 0 {
                    Ok(None)
                } else {
                    Err(TransportError::Exited {
                        program: self.label.clone(),
                        code,
                        stderr,
                    })
                }
            }
            Err(error) => {
                self.closed = true;
                let _ = self.child.kill();
                let _ = self.reap();
                Err(TransportError::Protocol(error))
            }
        }
    }

    fn close(&mut self) -> Result<(), TransportError> {
        if self.closed {
            return Ok(());
        }
        self.stdin.take();
        let (code, stderr) = self.reap()?;
        self.closed = true;
        if code == 0 {
            Ok(())
        } else {
            Err(TransportError::Exited {
                program: self.label.clone(),
                code,
                stderr,
            })
        }
    }

    fn describe(&self) -> String {
        self.label.clone()
    }
}

impl Drop for CommandChannel {
    fn drop(&mut self) {
        if !self.closed {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        if let Some(handle) = self.stderr_thread.take() {
            let _ = handle.join();
        }
    }
}

/// Maximum frame size used when reading (kept explicit for tests).
pub const FRAME_LIMIT: usize = MAX_FRAME_BYTES;

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::protocol::frames::{Ping, Pong};
    use std::process::Command;

    fn echo_agent(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script);
        command
    }

    #[test]
    fn request_reply_and_eof() {
        // A tiny agent: read one line, answer with a fixed pong, then exit.
        let mut command = echo_agent(
            "IFS= read -r line; printf '%s\\n' '{\"type\":\"pong\",\"tag\":\"t-1\"}'; exit 0",
        );
        let mut channel = CommandChannel::spawn(&mut command, "fake").unwrap();
        let frame = RawFrame::of(&Ping { tag: "t-1".into() }).unwrap();
        channel.send_frame(&frame).unwrap();
        let reply = channel.recv_frame().unwrap().unwrap();
        assert_eq!(reply.decode::<Pong>().unwrap().tag, "t-1");
        assert!(channel.recv_frame().unwrap().is_none());
    }

    #[test]
    fn nonzero_exit_reports_stderr_tail() {
        let mut command = echo_agent("echo 'permission denied' >&2; exit 255");
        let mut channel = CommandChannel::spawn(&mut command, "ssh").unwrap();
        let error = channel.recv_frame().unwrap_err();
        let message = error.to_string();
        assert!(message.contains("255"), "{message}");
        assert!(message.contains("permission denied"), "{message}");
    }

    #[test]
    fn malformed_frame_is_a_protocol_error() {
        let mut command = echo_agent("printf 'not json\\n'; exit 0");
        let mut channel = CommandChannel::spawn(&mut command, "fake").unwrap();
        assert!(matches!(
            channel.recv_frame(),
            Err(TransportError::Protocol(_))
        ));
    }
}
