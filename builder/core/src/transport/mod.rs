//! Transport bindings.
//!
//! Both bindings carry the same frames; only how the bytes travel differs:
//!
//! * [`ssh`] — the default for remote hosts: the system OpenSSH client runs the
//!   Agent's forced-command `ssh-dispatch` entry point. There is no listening
//!   port on the Mac and no token.
//! * [`command`] — the low-level primitive both bindings use: spawn a process
//!   with piped stdio and speak NDJSON on stdin/stdout. `Local` transport runs
//!   the Agent binary on this machine (useful for testing and for building on
//!   the same Mac).
//!
//! The optional HTTP+SSE binding from `builder/PROTOCOL.md` §3.2 is not part of
//! this slice; see `builder/README.md`.

pub mod command;
pub mod ssh;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::{Child, Stdio};

use serde::{Deserialize, Serialize};

use crate::protocol::frames::RawFrame;
use crate::protocol::ProtocolError;

pub use command::CommandChannel;
pub use ssh::SshSpec;

/// Errors from establishing or using a transport.
#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("could not start {program}: {message}")]
    Spawn { program: String, message: String },
    #[error("i/o error: {0}")]
    Io(#[from] std::io::Error),
    #[error("protocol error: {0}")]
    Protocol(#[from] ProtocolError),
    #[error("{program} exited with code {code}{stderr_suffix}", stderr_suffix = format_stderr(stderr))]
    Exited {
        program: String,
        code: i32,
        stderr: String,
    },
    #[error("the agent channel closed unexpectedly: {0}")]
    Closed(String),
    #[error("the system OpenSSH client is not available ({0})")]
    SshUnavailable(String),
    #[error("invalid transport configuration: {0}")]
    InvalidConfig(String),
}

fn format_stderr(stderr: &str) -> String {
    if stderr.trim().is_empty() {
        String::new()
    } else {
        format!("; stderr: {stderr}")
    }
}

/// A bidirectional stream of control frames.
pub trait ControlChannel: Send {
    fn send_frame(&mut self, frame: &RawFrame) -> Result<(), TransportError>;
    fn recv_frame(&mut self) -> Result<Option<RawFrame>, TransportError>;
    fn close(&mut self) -> Result<(), TransportError>;
    /// Short description for diagnostics ("ssh builder@mac.local", "local ...").
    fn describe(&self) -> String;
}

/// A local Agent binary invoked as `program <args> ssh-dispatch`, mirroring what
/// sshd runs through the forced-command entry point. The requested Agent
/// subcommand travels in `SSH_ORIGINAL_COMMAND`, exactly as over SSH.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalSpec {
    pub program: PathBuf,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
}

/// How the Builder reaches an Agent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TransportSpec {
    Ssh(SshSpec),
    Local(LocalSpec),
}

impl TransportSpec {
    /// Validate config values before storing a host profile.
    pub fn validate(&self) -> Result<(), String> {
        match self {
            TransportSpec::Ssh(spec) => spec.validate(),
            TransportSpec::Local(spec) => {
                if spec.program.as_os_str().is_empty() {
                    return Err("local agent program must not be empty".to_string());
                }
                for arg in &spec.args {
                    if arg.contains('\0') {
                        return Err("local agent arguments must not contain NUL".to_string());
                    }
                }
                for (key, value) in &spec.env {
                    if key.is_empty() || key.contains('=') || key.contains('\0') {
                        return Err(format!("invalid environment variable name {key:?}"));
                    }
                    if value.contains('\0') {
                        return Err(format!("environment variable {key} contains NUL"));
                    }
                }
                Ok(())
            }
        }
    }

    /// Open the control channel and return it un-handshaken.
    pub fn open_control(&self) -> Result<Box<dyn ControlChannel>, TransportError> {
        match self {
            TransportSpec::Ssh(spec) => {
                let mut command = spec.ssh_command("stdio")?;
                let channel = CommandChannel::spawn(&mut command, &spec.describe())?;
                Ok(Box::new(channel))
            }
            TransportSpec::Local(spec) => {
                let label = format!("local {}", spec.program.display());
                let mut command = local_command(spec, "stdio");
                let channel = CommandChannel::spawn(&mut command, &label)?;
                Ok(Box::new(channel))
            }
        }
    }

    /// Spawn one Agent subcommand, used for data channels (`upload`,
    /// `download-artifact`, `upload-status`) and by the control channel.
    pub fn spawn_agent(
        &self,
        subcommand: &str,
        stdin: Stdio,
        stdout: Stdio,
        stderr: Stdio,
    ) -> Result<Child, TransportError> {
        match self {
            TransportSpec::Ssh(spec) => {
                ssh::validate_remote_command(subcommand).map_err(TransportError::InvalidConfig)?;
                spec.spawn_with_stdio(subcommand, stdin, stdout, stderr)
            }
            TransportSpec::Local(spec) => {
                ssh::validate_remote_command(subcommand).map_err(TransportError::InvalidConfig)?;
                spawn_local_with_stdio(spec, subcommand, stdin, stdout, stderr)
            }
        }
    }

    /// Human description of the Agent endpoint.
    pub fn describe(&self) -> String {
        match self {
            TransportSpec::Ssh(spec) => format!("ssh {}@{}:{}", spec.user, spec.host, spec.port),
            TransportSpec::Local(spec) => format!("local {}", spec.program.display()),
        }
    }
}

/// Base command for a locally-run Agent binary. It is invoked exactly as the
/// forced-command entry point would be; the requested subcommand travels in
/// `SSH_ORIGINAL_COMMAND` rather than on the command line.
fn local_command(spec: &LocalSpec, subcommand: &str) -> std::process::Command {
    let mut command = std::process::Command::new(&spec.program);
    command
        .args(&spec.args)
        .arg("ssh-dispatch")
        .env("SSH_ORIGINAL_COMMAND", subcommand);
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    command
}

fn spawn_local_with_stdio(
    spec: &LocalSpec,
    subcommand: &str,
    stdin: Stdio,
    stdout: Stdio,
    stderr: Stdio,
) -> Result<Child, TransportError> {
    let mut command = local_command(spec, subcommand);
    command.stdin(stdin).stdout(stdout).stderr(stderr);
    command.spawn().map_err(|error| TransportError::Spawn {
        program: spec.program.display().to_string(),
        message: error.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn local() -> TransportSpec {
        TransportSpec::Local(LocalSpec {
            program: PathBuf::from("/usr/bin/builder-agent"),
            args: vec![],
            env: BTreeMap::new(),
        })
    }

    #[test]
    fn validate_local_spec() {
        assert!(local().validate().is_ok());
        let bad = TransportSpec::Local(LocalSpec {
            program: PathBuf::new(),
            args: vec![],
            env: BTreeMap::new(),
        });
        assert!(bad.validate().is_err());
        let bad_env = TransportSpec::Local(LocalSpec {
            program: PathBuf::from("/bin/agent"),
            args: vec![],
            env: BTreeMap::from([("A=B".to_string(), "x".to_string())]),
        });
        assert!(bad_env.validate().is_err());
    }

    #[test]
    fn xml_rejects_shell_metacharacters_in_subcommand() {
        let spec = local();
        let result = spec.spawn_agent(
            "stdio; rm -rf /",
            Stdio::null(),
            Stdio::null(),
            Stdio::null(),
        );
        assert!(matches!(result, Err(TransportError::InvalidConfig(_))));
    }

    #[test]
    fn describe_mentions_endpoint() {
        assert!(local().describe().contains("/usr/bin/builder-agent"));
    }
}
