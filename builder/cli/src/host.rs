//! `zkb host`: add, list, test and remove build hosts.
//!
//! SSH pairing uses a dedicated Ed25519 key, verifies the host key fingerprint
//! with the user and writes a profile-private `known_hosts`; the Builder never
//! edits `authorized_keys` remotely and never stores a password.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use builder_core::client::BuilderClient;
use builder_core::config::{self, BuilderConfig, HostProfile};
use builder_core::transport::ssh;
use builder_core::transport::{LocalSpec, TransportSpec};
use builder_core::util::rfc3339_now;
use clap::Subcommand;

use crate::{CliError, Printer, EXIT_HOST, EXIT_SUCCESS};

#[derive(Debug, Subcommand)]
pub enum HostCommand {
    /// Add a build host (SSH, or a local Agent binary).
    Add(Box<HostAddArgs>),
    /// List configured hosts.
    List,
    /// Connect to a host and run its doctor checks.
    #[command(alias = "doctor")]
    Test {
        /// Host name or id.
        name: String,
    },
    /// Remove a host from this machine's configuration.
    Remove {
        /// Host name or id.
        name: String,
    },
}

#[derive(Debug, clap::Args)]
pub struct HostAddArgs {
    /// Name for this host (also used as its id).
    #[arg(long)]
    pub name: String,
    /// SSH destination `user@host` (system OpenSSH, key authentication only).
    #[arg(long)]
    pub ssh: Option<String>,
    /// SSH port.
    #[arg(long, default_value_t = 22)]
    pub port: u16,
    /// Existing private key to use instead of creating a dedicated one.
    #[arg(long)]
    pub identity: Option<PathBuf>,
    /// Run a `builder-agent` binary on this machine instead of connecting over SSH.
    #[arg(long)]
    pub local_agent: Option<PathBuf>,
    /// Extra argument for the local Agent binary (repeatable).
    #[arg(long = "local-arg")]
    pub local_args: Vec<String>,
    /// Extra environment variable `K=V` for the local Agent (repeatable).
    #[arg(long = "local-env")]
    pub local_env: Vec<String>,
    /// Trust the shown host key without an interactive confirmation.
    #[arg(long)]
    pub yes: bool,
    /// Pin the host key by its SHA256 fingerprint instead of using --yes.
    #[arg(long)]
    pub fingerprint: Option<String>,
    /// Path of `builder-agent` on the Mac (shown in the authorized_keys line).
    #[arg(long, default_value = "~/.local/bin/builder-agent")]
    pub agent_path: String,
}

pub fn run(command: HostCommand, config_path: &Path, printer: Printer) -> Result<i32, CliError> {
    let mut config = BuilderConfig::load(config_path).map_err(CliError::Config)?;
    match command {
        HostCommand::Add(args) => add(*args, &mut config, config_path, printer),
        HostCommand::List => list(&config, printer),
        HostCommand::Test { name } => test(&name, &mut config, config_path, printer),
        HostCommand::Remove { name } => remove(&name, &mut config, config_path, printer),
    }
}

fn add(
    args: HostAddArgs,
    config: &mut BuilderConfig,
    config_path: &Path,
    printer: Printer,
) -> Result<i32, CliError> {
    match (&args.ssh, &args.local_agent) {
        (Some(_), Some(_)) => {
            return Err(CliError::usage(
                "use either --ssh or --local-agent, not both",
            ))
        }
        (None, None) => {
            return Err(CliError::usage(
                "choose a connection: --ssh user@host (recommended) or --local-agent <path>",
            ))
        }
        _ => {}
    }
    let id = config::slugify_host_id(&args.name);
    if config.find(&id).is_some() {
        return Err(CliError::usage(format!(
            "a host named {id:?} already exists; remove it first or choose another --name"
        )));
    }
    let config_dir = config_path.parent().unwrap_or(Path::new("."));
    let profile_dir = config::profile_dir(config_dir, &id);

    if let Some(local_agent) = &args.local_agent {
        let mut env = BTreeMap::new();
        for pair in &args.local_env {
            let Some((key, value)) = pair.split_once('=') else {
                return Err(CliError::usage(format!(
                    "--local-env expects K=V, got {pair:?}"
                )));
            };
            env.insert(key.to_string(), value.to_string());
        }
        let transport = TransportSpec::Local(LocalSpec {
            program: local_agent.clone(),
            args: args.local_args.clone(),
            env,
        });
        transport.validate().map_err(CliError::usage)?;
        let profile = HostProfile {
            id: id.clone(),
            name: args.name.clone(),
            transport,
            created_at: rfc3339_now(),
            last_test_at: None,
            agent_version: None,
            agent_id: None,
        };
        config.hosts.push(profile);
        config.save(config_path).map_err(CliError::Config)?;
        printer.line(format!("host {id} added ({})", local_agent.display()));
        printer.line(format!("test it with: zkb host test {id}"));
        return Ok(EXIT_SUCCESS);
    }

    let destination = args.ssh.clone().unwrap_or_default();
    let (user, host) = destination
        .split_once('@')
        .ok_or_else(|| CliError::usage(format!("--ssh expects user@host, got {destination:?}")))?;
    let (user, host) = (user.to_string(), host.to_string());
    ssh::validate_user(&user).map_err(CliError::usage)?;
    ssh::validate_host(&host).map_err(CliError::usage)?;
    ssh::ssh_available().map_err(CliError::usage)?;
    ssh::pairing_tools_available().map_err(CliError::usage)?;

    // Dedicated key per profile.
    let identity = match &args.identity {
        Some(path) => {
            if !path.exists() {
                return Err(CliError::usage(format!(
                    "SSH identity {} does not exist",
                    path.display()
                )));
            }
            path.clone()
        }
        None => {
            let path = profile_dir.join("id_ed25519");
            printer.progress(format!(
                "creating a dedicated SSH key at {}",
                path.display()
            ));
            ssh::generate_identity(&path, &format!("3ds2apple-builder {id}"))
                .map_err(CliError::Local)?;
            path
        }
    };
    let public_key = read_public_key(&identity);

    // Host key verification.
    let host_keys = ssh::scan_host_key(args.port, &host, 10).map_err(CliError::host_key)?;
    let fingerprints = ssh::host_key_fingerprints(&host_keys).map_err(CliError::host_key)?;
    printer.line(format!("host key fingerprints for {host}:{}", args.port));
    for fingerprint in &fingerprints {
        printer.line(format!("  {fingerprint}"));
    }
    match &args.fingerprint {
        Some(expected) => {
            if !fingerprints
                .iter()
                .any(|fingerprint| fingerprint.eq_ignore_ascii_case(expected))
            {
                return Err(CliError::usage(format!(
                    "host key fingerprint {expected:?} does not match the scanned host key"
                )));
            }
        }
        None if args.yes => {}
        None => {
            return Err(CliError::usage(
                "verify the fingerprint above, then re-run with --yes (or pass --fingerprint SHA256:...)",
            ));
        }
    }
    let known_hosts = profile_dir.join("known_hosts");
    ssh::write_known_hosts(&known_hosts, &host_keys).map_err(|error| {
        CliError::Local(format!("could not write the known_hosts file: {error}"))
    })?;

    let transport = TransportSpec::Ssh(ssh::SshSpec {
        host: host.clone(),
        port: args.port,
        user: user.clone(),
        identity: Some(identity),
        known_hosts: Some(known_hosts),
        control_path: Some(profile_dir.join("ssh-%r@%h-%p")),
        connect_timeout_secs: 10,
    });
    transport.validate().map_err(CliError::usage)?;
    let profile = HostProfile {
        id: id.clone(),
        name: args.name.clone(),
        transport,
        created_at: rfc3339_now(),
        last_test_at: None,
        agent_version: None,
        agent_id: None,
    };
    config.hosts.push(profile);
    config.save(config_path).map_err(CliError::Config)?;

    printer.line(format!("host {id} added (ssh {user}@{host}:{})", args.port));
    printer.line("");
    printer.line("Add this line to ~/.ssh/authorized_keys on the Mac:");
    let line = ssh::suggested_authorized_keys_line(&args.agent_path, &id, &public_key)
        .map_err(CliError::usage)?;
    printer.line(format!("  {line}"));
    printer.line("");
    printer.line("The forced command means this key can only run the Build Agent.");
    printer.line(format!("Then check the Mac: zkb host test {id}"));
    Ok(EXIT_SUCCESS)
}

fn read_public_key(identity: &Path) -> String {
    let public = identity.with_extension("pub");
    std::fs::read_to_string(&public)
        .map(|text| text.trim().to_string())
        .unwrap_or_else(|_| "<paste your public key here>".to_string())
}

fn list(config: &BuilderConfig, printer: Printer) -> Result<i32, CliError> {
    if config.hosts.is_empty() {
        printer.line("no build hosts configured; add one with `zkb host add`");
        return Ok(EXIT_SUCCESS);
    }
    for host in &config.hosts {
        let endpoint = host.transport.describe();
        let status = match (&host.agent_version, &host.last_test_at) {
            (Some(version), Some(at)) => format!("builder-agent {version} (tested {at})"),
            _ => "not tested yet".to_string(),
        };
        printer.line(format!(
            "{:<20} {:<24} {:<40} {}",
            host.name, host.id, endpoint, status
        ));
    }
    Ok(EXIT_SUCCESS)
}

fn test(
    name: &str,
    config: &mut BuilderConfig,
    config_path: &Path,
    printer: Printer,
) -> Result<i32, CliError> {
    let profile = config
        .find(name)
        .cloned()
        .ok_or_else(|| CliError::usage(format!("unknown host {name:?}")))?;
    let client = BuilderClient::connect(profile.transport.clone())?;
    let hello = client.hello().clone();
    printer.line(format!(
        "host: {} ({})",
        profile.name,
        profile.transport.describe()
    ));
    printer.line(format!(
        "agent: builder-agent {} (id {}, {} {}, protocol {})",
        hello.agent.version, hello.agent.id, hello.agent.os, hello.agent.arch, hello.protocol
    ));
    printer.line(format!("toolchain: {}", hello.toolchain.summary()));
    printer.line(format!(
        "source: revision {} ({}), scripts {}",
        hello.source.revision.as_deref().unwrap_or("unknown"),
        if hello.source.dirty { "dirty" } else { "clean" },
        if hello.source.scripts_present {
            "present"
        } else {
            "missing"
        }
    ));
    printer.line(format!(
        "limits: max input {}, queue {}, builds {}",
        crate::output::format_bytes(hello.limits.max_input_bytes),
        hello.limits.max_queued_jobs,
        hello.limits.max_concurrent_builds
    ));
    if hello.ready {
        printer.line("ready: yes");
    } else {
        printer.line(format!("ready: no ({})", hello.refusals.join(", ")));
        for refusal in &hello.refusals {
            printer.line(format!("  fix: {}", refusal_hint(refusal)));
        }
    }

    // Remember the result for `zkb host list`.
    if let Some(profile) = config.find_mut(&profile.id) {
        profile.last_test_at = Some(rfc3339_now());
        profile.agent_version = Some(hello.agent.version.clone());
        profile.agent_id = Some(hello.agent.id.clone());
    }
    let _ = config.save(config_path);
    let _ = client.close();
    if hello.ready {
        Ok(EXIT_SUCCESS)
    } else {
        Ok(EXIT_HOST)
    }
}

fn refusal_hint(code: &str) -> &'static str {
    match code {
        "toolchain_missing" => {
            "install Xcode + the iOS SDK, Rust with aarch64-apple-ios, xcodegen and Python 3"
        }
        "repo_missing" => "start the Agent with --checkout pointing at the 3ds2apple checkout",
        "repo_dirty" => "commit or stash changes in the Mac checkout",
        "insufficient_storage" => "free disk space on the Mac (about 20 GiB per build)",
        "forbidden" => "run the Agent as your login user, not as root",
        _ => "run `builder-agent doctor` on the Mac",
    }
}

fn remove(
    name: &str,
    config: &mut BuilderConfig,
    config_path: &Path,
    printer: Printer,
) -> Result<i32, CliError> {
    let removed = config
        .remove(name)
        .ok_or_else(|| CliError::usage(format!("unknown host {name:?}")))?;
    config.save(config_path).map_err(CliError::Config)?;
    let config_dir = config_path.parent().unwrap_or(Path::new("."));
    let profile_dir = config::profile_dir(config_dir, &removed.id);
    if profile_dir.exists() {
        let allowed = config_dir
            .canonicalize()
            .map(|dir| profile_dir.starts_with(dir))
            .unwrap_or(false);
        if allowed {
            let _ = std::fs::remove_dir_all(&profile_dir);
        }
    }
    printer.line(format!("removed host {name}"));
    Ok(EXIT_SUCCESS)
}

impl CliError {
    pub fn host_key(message: String) -> Self {
        CliError::Client(builder_core::client::ClientError::Transport(
            builder_core::transport::TransportError::InvalidConfig(message),
        ))
    }
}
