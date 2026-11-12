//! Build-host profiles: add (SSH pairing or local Agent), list, test, remove.
//!
//! The profiles live in the same `config.toml` that the `zkb` CLI uses, so a
//! host paired by one tool is immediately available in the other. Pairing
//! follows the same rules as the rest of the project: a dedicated Ed25519 key
//! per profile, a profile-private `known_hosts`, an explicit host-key fingerprint
//! confirmation, no passwords and no edits to the Mac's files.
//!
//! Windows-specific detail: connection multiplexing (`ControlMaster`) is
//! disabled there, because the Win32 OpenSSH client does not support Unix-domain
//! control sockets. Short-lived connections cost one extra handshake per data
//! channel and keep the client working on a stock Windows install.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use builder_core::client::BuilderClient;
use builder_core::config::{self, BuilderConfig, HostProfile};
use builder_core::transport::ssh::{self, SshSpec};
use builder_core::transport::{LocalSpec, TransportSpec};
use builder_core::util::rfc3339_now;
use serde::Serialize;

use crate::errors::FrontendError;
use crate::paths;

/// Options for `host add`.
#[derive(Debug, Clone)]
pub struct AddHostOptions {
    /// Human name, also the basis for the profile id.
    pub name: String,
    /// `user@host` for an SSH host.
    pub ssh: Option<String>,
    pub port: u16,
    /// Existing private key instead of creating a dedicated one.
    pub identity: Option<PathBuf>,
    /// Run `builder-agent` on this machine (testing and same-machine use).
    pub local_agent: Option<PathBuf>,
    pub local_args: Vec<String>,
    pub local_env: Vec<(String, String)>,
    /// Trust the displayed host-key fingerprints (non-interactive).
    pub yes: bool,
    /// Pin one SHA256 fingerprint explicitly.
    pub fingerprint: Option<String>,
    /// Path of `builder-agent` on the Mac, used in the authorized_keys line.
    pub agent_path: String,
}

/// Result of adding a host.
#[derive(Debug, Clone)]
pub struct AddedHost {
    pub profile: HostProfile,
    /// Line to paste into the Mac's `~/.ssh/authorized_keys` (SSH hosts only).
    pub authorized_keys_line: Option<String>,
    pub fingerprints: Vec<String>,
}

/// A host as shown by `host list`.
#[derive(Debug, Clone, Serialize)]
pub struct HostSummary {
    pub id: String,
    pub name: String,
    pub endpoint: String,
    pub status: String,
}

/// Facts returned by a successful `host test` (the Agent's `hello` reply).
#[derive(Debug, Clone, Serialize)]
pub struct HostTestReport {
    pub host_name: String,
    pub endpoint: String,
    pub protocol: String,
    pub agent_version: String,
    pub agent_id: String,
    pub agent_os: String,
    pub agent_arch: String,
    pub toolchain: String,
    pub source_revision: Option<String>,
    pub source_dirty: bool,
    pub scripts_present: bool,
    pub max_input_bytes: u64,
    pub max_queued_jobs: u32,
    pub max_concurrent_builds: u32,
    pub ready: bool,
    pub refusals: Vec<String>,
}

/// Host key scan result shown before the user confirms pairing.
#[derive(Debug, Clone)]
pub struct HostKeyScan {
    pub host: String,
    pub port: u16,
    pub fingerprints: Vec<String>,
    /// Raw `known_hosts` lines, kept until the user confirms.
    pub lines: Vec<String>,
}

/// Scan a Mac's host key and compute its fingerprints.
///
/// `ssh-keyscan` from the Windows OpenSSH client can fail against a newer sshd
/// that offers a post-quantum key exchange first, even though the regular `ssh`
/// client negotiates it fine. When the scan fails, the key is learned through a
/// throwaway `ssh` connection and its temporary `known_hosts` file instead; the
/// user still confirms the fingerprint before anything is trusted.
pub fn scan_host_key(port: u16, host: &str) -> Result<HostKeyScan, FrontendError> {
    let lines = match ssh::scan_host_key(port, host, 10) {
        Ok(lines) => lines,
        Err(scan_error) => match scan_host_key_via_ssh(port, host) {
            Ok(lines) => {
                println!("note: ssh-keyscan could not read the host key ({scan_error});");
                println!("      used a direct ssh probe instead. The fingerprint below still needs your confirmation.");
                lines
            }
            Err(probe_error) => {
                return Err(FrontendError::Environment(format!(
                    "cannot reach {host}:{port} to read its host key: {scan_error}; \
                     a direct ssh probe also failed: {probe_error}"
                )))
            }
        },
    };
    let fingerprints = ssh::host_key_fingerprints(&lines).map_err(|message| {
        FrontendError::Environment(format!("cannot fingerprint the host key: {message}"))
    })?;
    Ok(HostKeyScan {
        host: host.to_string(),
        port,
        fingerprints,
        lines,
    })
}

/// Learn host key lines through the system `ssh` client.
///
/// The host key is exchanged before authentication, so a throwaway connection
/// with `StrictHostKeyChecking=accept-new` writes it to a temporary
/// `known_hosts` file. The connection itself is expected to fail authentication.
fn scan_host_key_via_ssh(port: u16, host: &str) -> Result<Vec<String>, String> {
    let directory = std::env::temp_dir().join(format!(
        "3ds2apple-hostkey-{}-{}",
        std::process::id(),
        builder_core::util::unix_now()
    ));
    paths::ensure_dir(&directory)
        .map_err(|error| format!("create temporary directory: {error}"))?;
    let known_hosts = directory.join("known_hosts");
    let known_hosts_option = format!("UserKnownHostsFile={}", known_hosts.to_string_lossy());
    let mut command = std::process::Command::new("ssh");
    command.args(["-p", &port.to_string()]);
    command.args(["-o", "BatchMode=yes"]);
    command.args(["-o", "StrictHostKeyChecking=accept-new"]);
    command.args(["-o", &known_hosts_option]);
    command.args(["-o", "GlobalKnownHostsFile=/dev/null"]);
    command.args(["-o", "ConnectTimeout=10"]);
    command.args(["-o", "LogLevel=ERROR"]);
    command.arg(format!("3ds2apple-hostkey-probe@{host}"));
    command.arg("true");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let output = command
        .output()
        .map_err(|error| format!("could not run ssh: {error}"))?;
    let lines: Vec<String> = std::fs::read_to_string(&known_hosts)
        .map(|text| {
            text.lines()
                .map(str::trim_end)
                .filter(|line| !line.is_empty() && !line.starts_with('#'))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let _ = std::fs::remove_dir_all(paths::extended_length_path(&directory));
    if lines.is_empty() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            "the ssh probe learned no host key".to_string()
        } else {
            stderr
        });
    }
    Ok(lines)
}

fn find_duplicate(config: &BuilderConfig, id: &str) -> Result<(), FrontendError> {
    if config.find(id).is_some() {
        return Err(FrontendError::usage(format!(
            "a host named {id:?} already exists; remove it first or choose another --name"
        )));
    }
    Ok(())
}

fn profile_dir(config_path: &Path, id: &str) -> PathBuf {
    let config_dir = config_path.parent().unwrap_or_else(|| Path::new("."));
    config::profile_dir(config_dir, id)
}

fn read_public_key(identity: &Path) -> String {
    let public = identity.with_extension("pub");
    std::fs::read_to_string(paths::extended_length_path(&public))
        .map(|text| text.trim().to_string())
        .unwrap_or_else(|_| "<paste your public key here>".to_string())
}

fn insert_profile(
    config: &mut BuilderConfig,
    config_path: &Path,
    profile: HostProfile,
) -> Result<(), FrontendError> {
    config.hosts.push(profile);
    config.save(config_path).map_err(FrontendError::Config)
}

/// Add a build host.
///
/// `report` receives progress lines the caller can print (fingerprints, key
/// creation). Configuration is only saved after every interactive step
/// succeeded, so a failed pairing leaves no half-written profile behind.
pub fn add_host(
    config: &mut BuilderConfig,
    config_path: &Path,
    options: &AddHostOptions,
    report: &mut dyn FnMut(&str),
) -> Result<AddedHost, FrontendError> {
    match (&options.ssh, &options.local_agent) {
        (Some(_), Some(_)) => {
            return Err(FrontendError::usage(
                "use either --ssh or --local-agent, not both",
            ))
        }
        (None, None) => {
            return Err(FrontendError::usage(
                "choose a connection: --ssh user@host (recommended) or --local-agent <path>",
            ))
        }
        _ => {}
    }
    let name = options.name.trim();
    if name.is_empty() {
        return Err(FrontendError::usage("--name must not be empty"));
    }
    let id = config::slugify_host_id(name);
    find_duplicate(config, &id)?;

    if let Some(local_agent) = &options.local_agent {
        let mut env = BTreeMap::new();
        for (key, value) in &options.local_env {
            env.insert(key.clone(), value.clone());
        }
        let transport = TransportSpec::Local(LocalSpec {
            program: local_agent.clone(),
            args: options.local_args.clone(),
            env,
        });
        transport.validate().map_err(FrontendError::usage)?;
        let profile = HostProfile {
            id: id.clone(),
            name: name.to_string(),
            transport,
            created_at: rfc3339_now(),
            last_test_at: None,
            agent_version: None,
            agent_id: None,
        };
        insert_profile(config, config_path, profile.clone())?;
        report(&format!(
            "host {id} added (local agent {})",
            paths::display_path(local_agent)
        ));
        return Ok(AddedHost {
            profile,
            authorized_keys_line: None,
            fingerprints: Vec::new(),
        });
    }

    let destination = options.ssh.clone().unwrap_or_default();
    let (user, host) = destination.split_once('@').ok_or_else(|| {
        FrontendError::usage(format!("--ssh expects user@host, got {destination:?}"))
    })?;
    let (user, host) = (user.to_string(), host.to_string());
    ssh::validate_user(&user).map_err(FrontendError::usage)?;
    ssh::validate_host(&host).map_err(FrontendError::usage)?;
    if options.port == 0 {
        return Err(FrontendError::usage("--port must be 1-65535"));
    }
    ssh::ssh_available().map_err(FrontendError::Environment)?;
    ssh::pairing_tools_available().map_err(FrontendError::Environment)?;

    let profile_dir = profile_dir(config_path, &id);
    paths::ensure_dir(&profile_dir).map_err(|error| {
        FrontendError::local(format!(
            "cannot create the profile directory {}: {error}",
            paths::display_path(&profile_dir)
        ))
    })?;

    let identity = match &options.identity {
        Some(path) => {
            if !path.exists() {
                return Err(FrontendError::usage(format!(
                    "SSH identity {} does not exist",
                    paths::display_path(path)
                )));
            }
            path.clone()
        }
        None => {
            let path = profile_dir.join("id_ed25519");
            report(&format!(
                "creating a dedicated SSH key at {}",
                paths::display_path(&path)
            ));
            ssh::generate_identity(&path, &format!("3ds2apple-builder {id}"))
                .map_err(FrontendError::local)?;
            path
        }
    };
    let public_key = read_public_key(&identity);

    let scan = scan_host_key(options.port, &host)?;
    report(&format!(
        "host key fingerprints for {host}:{}",
        options.port
    ));
    for fingerprint in &scan.fingerprints {
        report(&format!("  {fingerprint}"));
    }
    match &options.fingerprint {
        Some(expected) => {
            if !scan
                .fingerprints
                .iter()
                .any(|fingerprint| fingerprint.eq_ignore_ascii_case(expected))
            {
                return Err(FrontendError::usage(format!(
                    "host key fingerprint {expected:?} does not match the scanned host key"
                )));
            }
        }
        None if options.yes => {}
        None => {
            return Err(FrontendError::usage(
                "verify the fingerprint above on the Mac (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub), then re-run with --yes or --fingerprint SHA256:...",
            ))
        }
    }
    let known_hosts = profile_dir.join("known_hosts");
    ssh::write_known_hosts(&known_hosts, &scan.lines).map_err(|error| {
        FrontendError::local(format!(
            "cannot write {}: {error}",
            paths::display_path(&known_hosts)
        ))
    })?;

    // Win32 OpenSSH does not support Unix-domain control sockets, so profiles
    // created on Windows skip connection multiplexing.
    let control_path = if cfg!(windows) {
        None
    } else {
        Some(profile_dir.join("ssh-%r@%h-%p"))
    };
    let transport = TransportSpec::Ssh(SshSpec {
        host: host.clone(),
        port: options.port,
        user: user.clone(),
        identity: Some(identity),
        known_hosts: Some(known_hosts),
        control_path,
        connect_timeout_secs: 10,
    });
    transport.validate().map_err(FrontendError::usage)?;
    let authorized_keys_line =
        ssh::suggested_authorized_keys_line(&options.agent_path, &id, &public_key)
            .map_err(FrontendError::usage)?;
    let profile = HostProfile {
        id: id.clone(),
        name: name.to_string(),
        transport,
        created_at: rfc3339_now(),
        last_test_at: None,
        agent_version: None,
        agent_id: None,
    };
    insert_profile(config, config_path, profile.clone())?;
    report(&format!(
        "host {id} added (ssh {user}@{host}:{})",
        options.port
    ));
    Ok(AddedHost {
        profile,
        authorized_keys_line: Some(authorized_keys_line),
        fingerprints: scan.fingerprints,
    })
}

/// Summaries for `host list`.
pub fn list_hosts(config: &BuilderConfig) -> Vec<HostSummary> {
    config
        .hosts
        .iter()
        .map(|host| HostSummary {
            id: host.id.clone(),
            name: host.name.clone(),
            endpoint: host.transport.describe(),
            status: match (&host.agent_version, &host.last_test_at) {
                (Some(version), Some(at)) => format!("builder-agent {version} (tested {at})"),
                (Some(version), None) => format!("builder-agent {version}"),
                _ => "not tested yet".to_string(),
            },
        })
        .collect()
}

/// Remove a host and its profile directory (dedicated key, known_hosts).
pub fn remove_host(
    config: &mut BuilderConfig,
    config_path: &Path,
    name: &str,
) -> Result<HostProfile, FrontendError> {
    let removed = config
        .remove(name)
        .ok_or_else(|| FrontendError::usage(format!("unknown host {name:?}")))?;
    config.save(config_path).map_err(FrontendError::Config)?;
    let config_dir = config_path.parent().unwrap_or_else(|| Path::new("."));
    let profile_dir = config::profile_dir(config_dir, &removed.id);
    if profile_dir.exists() {
        // Only ever delete inside this configuration's own directory.
        let allowed = config_dir
            .canonicalize()
            .map(|directory| profile_dir.starts_with(directory))
            .unwrap_or(false);
        if allowed {
            let _ = std::fs::remove_dir_all(paths::extended_length_path(&profile_dir));
        }
    }
    Ok(removed)
}

/// Connect to a host, run its doctor (`hello`) checks and remember the result.
pub fn test_host(
    config: &mut BuilderConfig,
    config_path: &Path,
    name: &str,
) -> Result<HostTestReport, FrontendError> {
    let profile = config
        .find(name)
        .cloned()
        .ok_or_else(|| FrontendError::usage(format!("unknown host {name:?}")))?;
    let client = BuilderClient::connect(profile.transport.clone())?;
    let hello = client.hello().clone();
    let report = HostTestReport {
        host_name: profile.name.clone(),
        endpoint: profile.transport.describe(),
        protocol: hello.protocol.clone(),
        agent_version: hello.agent.version.clone(),
        agent_id: hello.agent.id.clone(),
        agent_os: hello.agent.os.clone(),
        agent_arch: hello.agent.arch.clone(),
        toolchain: hello.toolchain.summary(),
        source_revision: hello.source.revision.clone(),
        source_dirty: hello.source.dirty,
        scripts_present: hello.source.scripts_present,
        max_input_bytes: hello.limits.max_input_bytes,
        max_queued_jobs: hello.limits.max_queued_jobs,
        max_concurrent_builds: hello.limits.max_concurrent_builds,
        ready: hello.ready,
        refusals: hello.refusals.clone(),
    };
    if let Some(stored) = config.find_mut(&profile.id) {
        stored.last_test_at = Some(rfc3339_now());
        stored.agent_version = Some(hello.agent.version.clone());
        stored.agent_id = Some(hello.agent.id.clone());
    }
    let _ = config.save(config_path);
    let _ = client.close();
    Ok(report)
}

/// Human text for a `host test` report.
pub fn render_test_report(report: &HostTestReport) -> Vec<String> {
    let mut lines = vec![
        format!("host: {} ({})", report.host_name, report.endpoint),
        format!(
            "agent: builder-agent {} (id {}, {} {}, protocol {})",
            report.agent_version,
            report.agent_id,
            report.agent_os,
            report.agent_arch,
            report.protocol
        ),
        format!("toolchain: {}", report.toolchain),
        format!(
            "source: revision {} ({}), scripts {}",
            report.source_revision.as_deref().unwrap_or("unknown"),
            if report.source_dirty {
                "dirty"
            } else {
                "clean"
            },
            if report.scripts_present {
                "present"
            } else {
                "missing"
            }
        ),
        format!(
            "limits: max input {}, queue {}, builds {}",
            crate::preflight::format_bytes(report.max_input_bytes),
            report.max_queued_jobs,
            report.max_concurrent_builds
        ),
    ];
    if report.ready {
        lines.push("ready: yes".to_string());
    } else {
        lines.push(format!("ready: no ({})", report.refusals.join(", ")));
        for refusal in &report.refusals {
            lines.push(format!("  fix: {}", crate::errors::refusal_hint(refusal)));
        }
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options_ssh() -> AddHostOptions {
        AddHostOptions {
            name: "Mac mini in the office".into(),
            ssh: Some("builder@mac-mini.local".into()),
            port: 22,
            identity: None,
            local_agent: None,
            local_args: Vec::new(),
            local_env: Vec::new(),
            yes: false,
            fingerprint: None,
            agent_path: "~/.local/bin/builder-agent".into(),
        }
    }

    #[test]
    fn ssh_and_local_are_mutually_exclusive() {
        let mut config = BuilderConfig::default();
        let path = Path::new("/tmp/config/config.toml");
        let mut options = options_ssh();
        options.local_agent = Some(PathBuf::from("/usr/local/bin/builder-agent"));
        let mut report = |_message: &str| {};
        let error = add_host(&mut config, path, &options, &mut report).unwrap_err();
        assert!(error.to_string().contains("either --ssh or --local-agent"));
        let error = add_host(
            &mut config,
            path,
            &AddHostOptions {
                ssh: None,
                ..options_ssh()
            },
            &mut report,
        )
        .unwrap_err();
        assert!(error.to_string().contains("choose a connection"));
    }

    #[test]
    fn malformed_destinations_are_rejected_without_touching_the_config() {
        let mut config = BuilderConfig::default();
        let path = tempfile::tempdir().unwrap();
        let config_path = path.path().join("config.toml");
        let mut report = |_message: &str| {};
        for ssh in ["no-at-sign", "@host", "user@", "user@@host"] {
            let mut options = options_ssh();
            options.ssh = Some(ssh.to_string());
            let error = add_host(&mut config, &config_path, &options, &mut report).unwrap_err();
            assert!(
                matches!(
                    error,
                    FrontendError::Usage(_) | FrontendError::Environment(_)
                ),
                "{ssh}: {error:?}"
            );
            assert!(config.hosts.is_empty(), "{ssh}");
        }
        assert!(!config_path.exists());
    }

    #[test]
    fn a_local_agent_host_round_trips_through_the_config() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        let mut config = BuilderConfig::load(&config_path).unwrap();
        let mut options = options_ssh();
        options.ssh = None;
        options.local_agent = Some(PathBuf::from("/usr/local/bin/builder-agent"));
        options.name = "This Mac".into();
        options.local_args = vec!["--fake-build".into()];
        options.local_env = vec![("BUILDER_AGENT_DATA_ROOT".into(), "/tmp/agent".into())];
        let mut report = |_message: &str| {};
        let added = add_host(&mut config, &config_path, &options, &mut report).unwrap();
        assert_eq!(added.profile.id, "this-mac");
        assert!(added.authorized_keys_line.is_none());
        assert!(added.fingerprints.is_empty());
        let reloaded = BuilderConfig::load(&config_path).unwrap();
        assert_eq!(reloaded.hosts.len(), 1);
        assert_eq!(reloaded.hosts[0].id, "this-mac");
        assert_eq!(
            reloaded.hosts[0].transport.describe(),
            "local /usr/local/bin/builder-agent"
        );

        let summaries = list_hosts(&reloaded);
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].status, "not tested yet");

        let mut mutable = reloaded;
        let removed = remove_host(&mut mutable, &config_path, "This Mac").unwrap();
        assert_eq!(removed.id, "this-mac");
        assert!(BuilderConfig::load(&config_path).unwrap().hosts.is_empty());
    }

    #[test]
    fn duplicate_names_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        let mut config = BuilderConfig::load(&config_path).unwrap();
        let mut options = options_ssh();
        options.ssh = None;
        options.local_agent = Some(PathBuf::from("/usr/local/bin/builder-agent"));
        options.name = "Office Mac".into();
        let mut report = |_message: &str| {};
        add_host(&mut config, &config_path, &options, &mut report).unwrap();
        let error = add_host(&mut config, &config_path, &options, &mut report).unwrap_err();
        assert!(error.to_string().contains("already exists"), "{error}");
    }

    #[test]
    fn empty_names_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        let mut config = BuilderConfig::load(&config_path).unwrap();
        let mut options = options_ssh();
        options.ssh = None;
        options.local_agent = Some(PathBuf::from("/usr/local/bin/builder-agent"));
        options.name = "   ".into();
        let mut report = |_message: &str| {};
        assert!(add_host(&mut config, &config_path, &options, &mut report).is_err());
    }

    #[test]
    fn unknown_hosts_are_usage_errors() {
        let dir = tempfile::tempdir().unwrap();
        let config_path = dir.path().join("config.toml");
        let mut config = BuilderConfig::load(&config_path).unwrap();
        assert!(test_host(&mut config, &config_path, "nope").is_err());
        assert!(remove_host(&mut config, &config_path, "nope").is_err());
    }

    #[test]
    fn test_report_rendering_prints_fixes() {
        let report = HostTestReport {
            host_name: "office".into(),
            endpoint: "ssh builder@mac:22".into(),
            protocol: builder_core::PROTOCOL.into(),
            agent_version: "0.1.0".into(),
            agent_id: "agent".into(),
            agent_os: "macos".into(),
            agent_arch: "aarch64".into(),
            toolchain: "Xcode 16.4, ...".into(),
            source_revision: Some("4cc6186".into()),
            source_dirty: false,
            scripts_present: true,
            max_input_bytes: 8 * 1024 * 1024 * 1024,
            max_queued_jobs: 4,
            max_concurrent_builds: 1,
            ready: false,
            refusals: vec!["toolchain_missing".into()],
        };
        let lines = render_test_report(&report).join("\n");
        assert!(lines.contains("ready: no (toolchain_missing)"), "{lines}");
        assert!(lines.contains("Xcode with the iOS SDK"), "{lines}");
        assert!(lines.contains("max input 8.0 GiB"), "{lines}");
    }
}
