//! Script execution with process-group cancellation and timeout.
//!
//! The Agent always runs `bash <script> <args...>` with a fixed working
//! directory; there is no shell interpolation. Each stage is its own process
//! group so cancellation reaches `cargo`, `clang` and `xcodebuild` children.

use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use builder_core::protocol::model::{LogLevel, LogSource, Stage};

use crate::nix_util;
use crate::service::Service;
use crate::stages::ScriptCall;
use crate::store::JobEntry;

/// Grace period between SIGTERM and SIGKILL for a canceled stage.
pub const CANCEL_GRACE: Duration = Duration::from_secs(30);
/// Poll interval while waiting for a child to exit.
const POLL_INTERVAL: Duration = Duration::from_millis(50);
/// Lines of stdout/stderr kept for marker parsing and error tails.
const CAPTURE_LIMIT: usize = 8_000;

/// Captured result of one script stage.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScriptOutcome {
    pub exit_code: i32,
    pub stdout: Vec<String>,
    pub stderr: Vec<String>,
}

impl ScriptOutcome {
    /// Combined capture used for marker parsing and log tails.
    pub fn combined(&self) -> Vec<String> {
        let mut lines = self.stdout.clone();
        lines.extend(self.stderr.iter().cloned());
        lines
    }

    /// Last `count` lines, for the error `log_tail`.
    pub fn tail(&self, count: usize) -> Vec<String> {
        let combined = self.combined();
        let start = combined.len().saturating_sub(count);
        combined[start..].to_vec()
    }
}

/// Why a stage did not complete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunFailure {
    Canceled,
    TimedOut { stage: Stage, seconds: u64 },
    Spawn(String),
    Io(String),
}

/// Run one script stage, streaming stdout/stderr into the job log.
#[allow(clippy::too_many_arguments)]
pub fn run_script(
    service: &Arc<Service>,
    entry: &Arc<JobEntry>,
    stage: Stage,
    call: &ScriptCall,
    envs: &[(String, String)],
    timeout: Duration,
) -> Result<ScriptOutcome, RunFailure> {
    let Some(checkout) = service.cfg.checkout.clone() else {
        return Err(RunFailure::Spawn(
            "no source checkout configured".to_string(),
        ));
    };
    let mut command = call.command(&checkout);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in envs {
        command.env(key, value);
    }
    // Own process group so cancellation also stops cargo/clang/xcodebuild.
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    service.log(
        entry,
        Some(stage),
        LogSource::Agent,
        LogLevel::Info,
        &format!("$ bash {}", call.display()),
    );
    let mut child = command.spawn().map_err(|error| {
        RunFailure::Spawn(format!(
            "could not start {}: {error}",
            call.script.display()
        ))
    })?;
    let pgid = child.id() as i32;
    entry.with(|record| record.job.process_group = Some(pgid));

    let stdout = Arc::new(Mutex::new(Vec::new()));
    let stderr = Arc::new(Mutex::new(Vec::new()));
    let stdout_thread = child.stdout.take().map(|stream| {
        spawn_reader(
            stream,
            Arc::clone(service),
            Arc::clone(entry),
            stage,
            LogSource::Script,
            LogLevel::Info,
            Arc::clone(&stdout),
        )
    });
    let stderr_thread = child.stderr.take().map(|stream| {
        spawn_reader(
            stream,
            Arc::clone(service),
            Arc::clone(entry),
            stage,
            LogSource::Script,
            LogLevel::Warn,
            Arc::clone(&stderr),
        )
    });

    let started = Instant::now();
    let exit_status = loop {
        if entry.with(|record| record.job.cancel_requested) {
            terminate(&mut child, pgid);
            finish_children(&mut child, stdout_thread, stderr_thread);
            entry.with(|record| record.job.process_group = None);
            return Err(RunFailure::Canceled);
        }
        if started.elapsed() > timeout {
            terminate(&mut child, pgid);
            finish_children(&mut child, stdout_thread, stderr_thread);
            entry.with(|record| record.job.process_group = None);
            return Err(RunFailure::TimedOut {
                stage,
                seconds: timeout.as_secs(),
            });
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => std::thread::sleep(POLL_INTERVAL),
            Err(error) => {
                terminate(&mut child, pgid);
                finish_children(&mut child, stdout_thread, stderr_thread);
                entry.with(|record| record.job.process_group = None);
                return Err(RunFailure::Io(format!(
                    "waiting for the build script: {error}"
                )));
            }
        }
    };
    finish_children(&mut child, stdout_thread, stderr_thread);
    entry.with(|record| {
        record.job.process_group = None;
        // Cancellation can land just as the process exits; report it as such.
    });

    Ok(ScriptOutcome {
        exit_code: exit_status.code().unwrap_or(-1),
        stdout: take_lines(&stdout),
        stderr: take_lines(&stderr),
    })
}

fn spawn_reader<R: Read + Send + 'static>(
    stream: R,
    service: Arc<Service>,
    entry: Arc<JobEntry>,
    stage: Stage,
    source: LogSource,
    level: LogLevel,
    sink: Arc<Mutex<Vec<String>>>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let reader = BufReader::new(stream);
        for line in reader.lines() {
            let Ok(line) = line else { break };
            service.log(&entry, Some(stage), source, level, &line);
            if let Ok(mut captured) = sink.lock() {
                if captured.len() < CAPTURE_LIMIT {
                    captured.push(line);
                }
            }
        }
    })
}

fn take_lines(sink: &Arc<Mutex<Vec<String>>>) -> Vec<String> {
    sink.lock().map(|lines| lines.clone()).unwrap_or_default()
}

fn join_reader(handle: Option<std::thread::JoinHandle<()>>) {
    if let Some(handle) = handle {
        let _ = handle.join();
    }
}

fn finish_children(
    child: &mut Child,
    stdout: Option<std::thread::JoinHandle<()>>,
    stderr: Option<std::thread::JoinHandle<()>>,
) {
    let _ = child.wait();
    join_reader(stdout);
    join_reader(stderr);
}

/// SIGTERM the group, wait up to [`CANCEL_GRACE`], then SIGKILL.
fn terminate(child: &mut Child, pgid: i32) {
    let _ = nix_util::signal_process_group(pgid, nix_util::Signal::SIGTERM);
    let deadline = Instant::now() + CANCEL_GRACE;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(POLL_INTERVAL),
            _ => break,
        }
    }
    let _ = nix_util::signal_process_group(pgid, nix_util::Signal::SIGKILL);
}

/// The stage timeouts from PROTOCOL.md §8.4.
pub fn stage_timeout(stage: Stage) -> Duration {
    match stage {
        Stage::Preparing => Duration::from_secs(45 * 60),
        Stage::Recompiling => Duration::from_secs(4 * 3600),
        Stage::Linking => Duration::from_secs(2 * 3600),
        Stage::Packaging => Duration::from_secs(3600),
        Stage::Verifying => Duration::from_secs(10 * 60),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stage_timeouts_match_documentation() {
        assert_eq!(
            stage_timeout(Stage::Recompiling),
            Duration::from_secs(14_400)
        );
        assert_eq!(stage_timeout(Stage::Packaging), Duration::from_secs(3_600));
        assert_eq!(stage_timeout(Stage::Verifying), Duration::from_secs(600));
    }

    #[test]
    fn outcome_tail_is_bounded() {
        let outcome = ScriptOutcome {
            exit_code: 1,
            stdout: (0..100).map(|index| format!("line {index}")).collect(),
            stderr: vec!["error".to_string()],
        };
        let tail = outcome.tail(3);
        assert_eq!(tail.len(), 3);
        assert_eq!(tail.last().unwrap(), "error");
        assert_eq!(outcome.combined().len(), 101);
    }
}
