//! `zkb` — cross-platform command line client for the 3ds2apple Builder.
//!
//! The CLI drives one user-owned macOS Build Agent over the SSH transport
//! (system OpenSSH) or a local Agent process. It never signs or installs
//! anything and never contacts a project-operated server.

use std::path::PathBuf;

use builder_core::client::ClientError;
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::model::ErrorInfo;
use clap::{Parser, Subcommand};

mod build;
mod doctor;
mod host;
mod jobs;
mod output;

pub use output::Printer;

/// Exit codes follow the documented CLI conventions.
pub const EXIT_SUCCESS: i32 = 0;
pub const EXIT_BUILD_FAILED: i32 = 1;
pub const EXIT_USAGE: i32 = 2;
pub const EXIT_HOST: i32 = 3;
pub const EXIT_CANCELED: i32 = 4;
pub const EXIT_IO: i32 = 5;
pub const EXIT_INTERNAL: i32 = 64;

#[derive(Debug, Parser)]
#[command(
    name = "zkb",
    version,
    about = "Build your own 3ds2apple IPA on a macOS host you control",
    long_about = "zkb builds one game at a time: it hashes and uploads a ROM you own to the \
                  Build Agent on your Mac, streams the build log, then downloads and verifies \
                  the unsigned IPA. It never signs, installs or distributes the result."
)]
struct Cli {
    /// Builder config file (default: platform config directory).
    #[arg(long, global = true)]
    config: Option<PathBuf>,
    /// Emit NDJSON protocol objects on stdout.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Manage build hosts.
    Host {
        #[command(subcommand)]
        command: host::HostCommand,
    },
    /// Build one game and download the unsigned IPA.
    Build(build::BuildArgs),
    /// Show a job's status.
    Status {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
        /// Keep streaming until the job finishes.
        #[arg(long)]
        follow: bool,
    },
    /// Print a job's log.
    Logs {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
        /// Resume from this event sequence number.
        #[arg(long, default_value_t = 0)]
        since: u64,
        /// Print the retained log and exit instead of following.
        #[arg(long)]
        no_follow: bool,
    },
    /// Cancel a running or queued job.
    Cancel {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
        #[arg(long)]
        reason: Option<String>,
    },
    /// Download and verify a finished build's IPA.
    Download {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
        /// Destination directory (default: ./out).
        #[arg(long)]
        out: Option<PathBuf>,
        /// Recompute the SHA256 after download (always on; kept for scripting).
        #[arg(long)]
        verify: bool,
    },
    /// List jobs the Agent still holds.
    Jobs {
        /// Host name or id.
        #[arg(long)]
        host: String,
        #[arg(long)]
        limit: Option<u32>,
    },
    /// Delete a finished job's data on the Agent.
    Delete {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
    },
    /// Check this machine's Builder setup, or a host's toolchain.
    Doctor {
        /// Also run the remote doctor checks against this host.
        #[arg(long)]
        host: Option<String>,
    },
    /// Show the Builder configuration (secrets redacted).
    Config,
}

/// CLI error with an exit-code mapping.
#[derive(Debug, thiserror::Error)]
pub enum CliError {
    #[error("{0}")]
    Usage(String),
    #[error("{0}")]
    Local(String),
    #[error("{0}")]
    Config(String),
    #[error(transparent)]
    Client(#[from] ClientError),
    /// A build reached a terminal failed state: actionable build failure.
    #[error("build failed: {}", .error.message)]
    BuildFailed { error: ErrorInfo },
    #[error("the build was canceled")]
    Canceled,
    #[error("the Agent was interrupted: {0}")]
    Interrupted(String),
}

impl CliError {
    pub fn usage(message: impl Into<String>) -> Self {
        CliError::Usage(message.into())
    }
}

/// Exit code for an error.
pub fn exit_code(error: &CliError) -> i32 {
    match error {
        CliError::Usage(_) | CliError::Config(_) => EXIT_USAGE,
        CliError::BuildFailed { .. } => EXIT_BUILD_FAILED,
        CliError::Canceled => EXIT_CANCELED,
        CliError::Interrupted(_) => EXIT_HOST,
        CliError::Local(_) => EXIT_IO,
        CliError::Client(error) => match error {
            ClientError::Remote { error } => match error.code {
                ErrorCode::BuildFailed => EXIT_BUILD_FAILED,
                ErrorCode::Internal => EXIT_INTERNAL,
                _ => EXIT_HOST,
            },
            ClientError::Io { .. }
            | ClientError::Local(_)
            | ClientError::ArtifactCorrupt { .. } => EXIT_IO,
            ClientError::Protocol(_)
            | ClientError::Transport(_)
            | ClientError::UnexpectedFrame { .. }
            | ClientError::Closed(_)
            | ClientError::AgentExit { .. }
            | ClientError::InvalidReply(_) => EXIT_HOST,
        },
    }
}

fn report_error(printer: Printer, error: &CliError) {
    if printer.json {
        let info: Option<ErrorInfo> = match error {
            CliError::BuildFailed { error } => Some(error.clone()),
            CliError::Client(ClientError::Remote { error }) => Some(error.clone()),
            _ => None,
        };
        if let Some(info) = info {
            if let Ok(frame) = builder_core::protocol::frames::error_frame("", info) {
                if let Ok(line) = frame.to_line() {
                    println!("{line}");
                }
            }
        }
    }
    eprintln!("zkb: {error}");
    if let Some(hint) = match error {
        CliError::BuildFailed { error } => error.hint.as_deref(),
        CliError::Client(ClientError::Remote { error }) => error.hint.as_deref(),
        _ => None,
    } {
        eprintln!("hint: {hint}");
    }
    if let CliError::BuildFailed { error } = error {
        if let Some(tail) = &error.log_tail {
            eprintln!("last log lines:");
            for line in tail {
                eprintln!("  {line}");
            }
        }
    }
}

fn load_config(path: &std::path::Path) -> Result<builder_core::config::BuilderConfig, CliError> {
    builder_core::config::BuilderConfig::load(path).map_err(CliError::Config)
}

fn connect(
    config: &builder_core::config::BuilderConfig,
    host: &str,
) -> Result<
    (
        builder_core::client::BuilderClient,
        builder_core::config::HostProfile,
    ),
    CliError,
> {
    let profile = config.find(host).cloned().ok_or_else(|| {
        CliError::Usage(format!("unknown host {host:?}; add it with `zkb host add`"))
    })?;
    let client = builder_core::client::BuilderClient::connect(profile.transport.clone())?;
    Ok((client, profile))
}

fn main() {
    let cli = Cli::parse();
    let printer = Printer::new(cli.json);
    let config_path = cli
        .config
        .clone()
        .unwrap_or_else(builder_core::config::default_config_file);
    let result: Result<i32, CliError> = (|| match cli.command {
        Command::Host { command } => host::run(command, &config_path, printer),
        Command::Build(args) => {
            let config = load_config(&config_path)?;
            build::run(&args, &config, printer)
        }
        Command::Status {
            host,
            job_id,
            follow,
        } => {
            if follow {
                let config = load_config(&config_path)?;
                return jobs::follow(&config, &host, &job_id, 0, printer);
            }
            let config = load_config(&config_path)?;
            jobs::status(&config, &host, &job_id, printer)
        }
        Command::Logs {
            host,
            job_id,
            since,
            no_follow,
        } => {
            let config = load_config(&config_path)?;
            if no_follow {
                jobs::logs_only(&config, &host, &job_id, since, printer)
            } else {
                jobs::follow(&config, &host, &job_id, since, printer)
            }
        }
        Command::Cancel {
            host,
            job_id,
            reason,
        } => {
            let config = load_config(&config_path)?;
            jobs::cancel(&config, &host, &job_id, reason.as_deref(), printer)
        }
        Command::Download {
            host,
            job_id,
            out,
            verify,
        } => {
            let config = load_config(&config_path)?;
            let out = out.unwrap_or_else(|| PathBuf::from("out"));
            jobs::download(&config, &host, &job_id, &out, verify, printer)
        }
        Command::Jobs { host, limit } => {
            let config = load_config(&config_path)?;
            jobs::list(&config, &host, limit, printer)
        }
        Command::Delete { host, job_id } => {
            let config = load_config(&config_path)?;
            jobs::delete(&config, &host, &job_id, printer)
        }
        Command::Doctor { host } => {
            let config = load_config(&config_path).unwrap_or_default();
            doctor::run(&config, host.as_deref(), &config_path, printer)
        }
        Command::Config => {
            let config = load_config(&config_path)?;
            doctor::show_config(&config, &config_path)
        }
    })();
    match result {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            report_error(printer, &error);
            std::process::exit(exit_code(&error));
        }
    }
}
