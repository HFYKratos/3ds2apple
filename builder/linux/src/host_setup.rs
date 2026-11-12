//! First-run pairing of a macOS VM or Mac as a build host.
//!
//! This is the Linux-specific part of the host wizard: it finds the VM's
//! forwarded SSH port ([`crate::vm`]), shows the host-key fingerprints, and
//! delegates to the shared `zkb host add`, which creates a dedicated SSH key
//! and writes a profile-private `known_hosts`. Passwords are never used,
//! requested or stored; pairing is SSH-key only.

use std::io::BufRead;
use std::path::{Path, PathBuf};

use builder_core::config::BuilderConfig;
use builder_core::transport::ssh;

use crate::error::Error;
use crate::output::Printer;
use crate::vm::{self, DiscoverOptions, VmEndpoint};
use crate::zkb::Zkb;

/// Default path of the Agent binary printed in the `authorized_keys` line.
pub const DEFAULT_AGENT_PATH: &str = "~/.local/bin/builder-agent";
/// SSH port of a Mac (or of a VM whose host port is forwarded to `:22`).
pub const DEFAULT_SSH_PORT: u16 = 22;

/// Options for `vm setup`.
#[derive(Debug, Clone)]
pub struct SetupOptions {
    pub name: String,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub user: Option<String>,
    pub key: Option<PathBuf>,
    pub agent_path: String,
    pub yes: bool,
    pub fingerprint: Option<String>,
    pub test: bool,
    pub ports: Vec<u16>,
    pub timeout_ms: u64,
}

impl Default for SetupOptions {
    fn default() -> Self {
        Self {
            name: String::new(),
            host: None,
            port: None,
            user: None,
            key: None,
            agent_path: DEFAULT_AGENT_PATH.to_string(),
            yes: false,
            fingerprint: None,
            test: false,
            ports: vm::default_local_ports(),
            timeout_ms: 700,
        }
    }
}

/// Run the pairing flow and return the intended process exit code.
pub fn setup<F>(
    options: &SetupOptions,
    config_path: &Path,
    env_get: F,
    zkb: &Zkb,
    printer: Printer,
    interactive: bool,
) -> Result<i32, Error>
where
    F: Fn(&str) -> Option<String>,
{
    let name = options.name.trim();
    if name.is_empty() {
        return Err(Error::usage("--name must not be empty"));
    }
    let config = BuilderConfig::load(config_path)
        .map_err(|message| Error::usage(format!("cannot use {config_path:?}: {message}")))?;
    let id = builder_core::config::slugify_host_id(name);
    if config.find(&id).is_some() {
        return Err(Error::usage(format!(
            "a build host {id:?} already exists; choose another --name or remove it with \
             `zkb host remove {id}`"
        )));
    }

    let endpoint = resolve_endpoint(options, &env_get)?;
    printer.progress(format!(
        "using macOS host endpoint {} ({})",
        endpoint.label(),
        endpoint.detail
    ));

    // Confirm the endpoint really is an SSH server before scanning keys.
    let reach = if endpoint.reach.is_ssh() {
        endpoint.reach.clone()
    } else {
        vm::probe_ssh(
            &endpoint.host,
            endpoint.port,
            std::time::Duration::from_millis(options.timeout_ms),
        )
    };
    if !reach.is_ssh() {
        return Err(Error::host(format!(
            "{} is not answering as an SSH server ({})",
            endpoint.label(),
            reach.label()
        )));
    }

    ssh::ssh_available().map_err(Error::local)?;
    ssh::pairing_tools_available().map_err(Error::local)?;
    let host_keys = ssh::scan_host_key(endpoint.port, &endpoint.host, 10).map_err(|message| {
        Error::host(format!(
            "could not read the host key of {}: {message}",
            endpoint.label()
        ))
    })?;
    let fingerprints = ssh::host_key_fingerprints(&host_keys).map_err(|message| {
        Error::host(format!(
            "could not compute the host-key fingerprint of {}: {message}",
            endpoint.label()
        ))
    })?;

    printer.line(format!("Pairing macOS host \"{name}\""));
    printer.line(format!(
        "  endpoint: ssh {}:{}",
        endpoint.destination(),
        endpoint.port
    ));
    printer.line(format!("  source:   {}", endpoint.detail));
    printer.line("  host key fingerprints:");
    for fingerprint in &fingerprints {
        printer.line(format!("    {fingerprint}"));
    }
    printer.line("");
    printer.line("Verify one of them on the Mac:");
    printer.line("  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub");
    printer.blank();

    let confirmation = match &options.fingerprint {
        Some(expected) => {
            if !fingerprints
                .iter()
                .any(|fingerprint| fingerprint.eq_ignore_ascii_case(expected.trim()))
            {
                return Err(Error::usage(format!(
                    "fingerprint {expected:?} does not match any host key of {}",
                    endpoint.label()
                )));
            }
            FingerprintChoice::Pin(expected.trim().to_string())
        }
        None if options.yes => FingerprintChoice::Accept,
        None if interactive => {
            confirm_fingerprint(&fingerprints, &mut std::io::stdin().lock(), interactive)?
        }
        None => {
            return Err(Error::usage(
                "verify the fingerprint above, then re-run with --yes (trust the listed keys) \
                 or --fingerprint SHA256:... (pin one)",
            ))
        }
    };

    let identity = options
        .key
        .clone()
        .or_else(|| vm::identity_from_env(&env_get));
    if let Some(identity) = &identity {
        if !identity.is_file() {
            return Err(Error::usage(format!(
                "SSH identity {} does not exist",
                identity.display()
            )));
        }
    }

    let args = build_host_add_args(options, &endpoint, identity.as_deref(), &confirmation);
    printer.progress("pairing with the shared Builder client (zkb host add)");
    let output = zkb.run_streaming(&args, true)?;
    if !output.succeeded() {
        return Err(Error::Forwarded(output.code));
    }

    printer.blank();
    printer.line("Next steps:");
    printer.line(
        "  1. Install builder-agent on the Mac if it is not there yet, and add the \
         authorized_keys line above.",
    );
    printer.line(format!(
        "  2. Check the host: 3ds2apple-builder doctor --host {name}"
    ));
    printer.line(format!(
        "  3. Build:          3ds2apple-builder build --host {name} --rom <your.cci>"
    ));
    printer.blank();
    printer.line("This profile uses a key pair, never a password.");
    if !options.test {
        return Ok(crate::error::EXIT_SUCCESS);
    }

    // Optional immediate check against the Mac.
    let test_args = crate::zkb::with_globals(
        Some(config_path),
        printer.json,
        vec!["host".to_string(), "test".to_string(), name.to_string()],
    );
    let output = zkb.run_streaming(&test_args, true)?;
    Ok(output.code)
}

/// How the user confirmed the host key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FingerprintChoice {
    /// `--yes`: trust the listed keys for this profile.
    Accept,
    /// `--fingerprint SHA256:...` (or the interactive equivalent): pin one.
    Pin(String),
}

impl FingerprintChoice {
    fn as_args(&self) -> Vec<String> {
        match self {
            Self::Accept => vec!["--yes".to_string()],
            Self::Pin(fingerprint) => {
                vec!["--fingerprint".to_string(), fingerprint.clone()]
            }
        }
    }
}

/// Interactive fingerprint confirmation.
///
/// Accepts `yes` (trust the listed keys) or one of the printed fingerprints.
/// Three invalid answers abort instead of looping forever.
pub fn confirm_fingerprint<R: BufRead>(
    fingerprints: &[String],
    reader: &mut R,
    interactive: bool,
) -> Result<FingerprintChoice, Error> {
    if !interactive {
        return Err(Error::usage(
            "verify the fingerprint above, then re-run with --yes or --fingerprint SHA256:...",
        ));
    }
    for _ in 0..3 {
        eprint!("Type 'yes' to trust the listed keys, or paste one SHA256:... to pin it: ");
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return Err(Error::usage(
                "no answer on stdin; re-run with --yes or --fingerprint SHA256:...",
            ));
        }
        let answer = line.trim();
        if answer.eq_ignore_ascii_case("yes") || answer.eq_ignore_ascii_case("y") {
            return Ok(FingerprintChoice::Accept);
        }
        if fingerprints
            .iter()
            .any(|fingerprint| fingerprint.eq_ignore_ascii_case(answer))
        {
            return Ok(FingerprintChoice::Pin(answer.to_string()));
        }
        eprintln!("that does not match a listed fingerprint; try again");
    }
    Err(Error::usage(
        "the fingerprint was not confirmed; nothing was changed",
    ))
}

/// Build the `zkb host add` argument vector (no shell, one flag per value).
pub fn build_host_add_args(
    options: &SetupOptions,
    endpoint: &VmEndpoint,
    identity: Option<&Path>,
    confirmation: &FingerprintChoice,
) -> Vec<String> {
    let mut args = vec![
        "host".to_string(),
        "add".to_string(),
        "--name".to_string(),
        options.name.trim().to_string(),
        "--ssh".to_string(),
        endpoint.destination(),
        "--port".to_string(),
        endpoint.port.to_string(),
        "--agent-path".to_string(),
        options.agent_path.clone(),
    ];
    if let Some(identity) = identity {
        args.push("--identity".to_string());
        args.push(identity.display().to_string());
    }
    args.extend(confirmation.as_args());
    args
}

/// Resolve the endpoint to pair: explicit flags, then `ZKB_VM_*`, then
/// discovery (QEMU forwarding rules and a localhost port scan).
fn resolve_endpoint<F>(options: &SetupOptions, env_get: &F) -> Result<VmEndpoint, Error>
where
    F: Fn(&str) -> Option<String>,
{
    let user = options
        .user
        .clone()
        .unwrap_or_else(|| vm::default_user(env_get));
    match (&options.host, options.port) {
        (Some(host), Some(port)) => return explicit_endpoint(host, port, &user),
        // A host without a port means the standard SSH port; a port without a
        // host means a local VM forwarding on 127.0.0.1.
        (Some(host), None) => return explicit_endpoint(host, DEFAULT_SSH_PORT, &user),
        (None, Some(port)) => return explicit_endpoint("127.0.0.1", port, &user),
        (None, None) => {}
    }
    if let Some(endpoint) = vm::endpoint_from_env(env_get).map_err(Error::usage)? {
        return Ok(endpoint);
    }

    let discovery = vm::discover(
        &DiscoverOptions {
            scan_ports: true,
            probe: true,
            ports: options.ports.clone(),
            timeout: std::time::Duration::from_millis(options.timeout_ms),
        },
        env_get,
        Path::new("/proc"),
    );
    let candidates = discovery.ssh_candidates();
    if candidates.is_empty() {
        let mut message = String::from(
            "no macOS VM SSH endpoint found. Start the VM, enable Remote Login inside it, then \
             pass --host/--port (for example --host 127.0.0.1 --port 2222) or set ZKB_VM_SSH.",
        );
        for note in &discovery.notes {
            message.push_str("\n  note: ");
            message.push_str(note);
        }
        return Err(Error::host(message));
    }
    let chosen = choose_candidate(&candidates, None, None)?;
    Ok(chosen.clone())
}

fn explicit_endpoint(host: &str, port: u16, user: &str) -> Result<VmEndpoint, Error> {
    ssh::validate_host(host).map_err(Error::usage)?;
    ssh::validate_user(user).map_err(Error::usage)?;
    if port == 0 {
        return Err(Error::usage("--port must be 1-65535"));
    }
    Ok(VmEndpoint {
        host: host.to_string(),
        port,
        user: user.to_string(),
        source: vm::EndpointSource::Env,
        guest_port: None,
        detail: "explicit --host/--port".to_string(),
        reach: vm::Reach::NotProbed,
    })
}

/// Choose one candidate when discovery found several.
///
/// A unique SSH candidate is used directly; ambiguity is a usage error that
/// lists the options (pairing must never guess which host gets the ROM).
pub fn choose_candidate<'a>(
    candidates: &[&'a VmEndpoint],
    host: Option<&str>,
    port: Option<u16>,
) -> Result<&'a VmEndpoint, Error> {
    let filtered: Vec<&'a VmEndpoint> = candidates
        .iter()
        .copied()
        .filter(|endpoint| host.map_or(true, |host| endpoint.host == host))
        .filter(|endpoint| port.map_or(true, |port| endpoint.port == port))
        .collect();
    match filtered.len() {
        1 => Ok(filtered[0]),
        0 => Err(Error::usage(
            "no discovered SSH endpoint matches --host/--port",
        )),
        _ => {
            let mut message = String::from(
                "several macOS SSH endpoints were found; choose one with --host/--port:",
            );
            for endpoint in filtered {
                message.push_str(&format!(
                    "\n  {} ({}, {})",
                    endpoint.label(),
                    endpoint.source.label(),
                    endpoint.detail
                ));
            }
            Err(Error::usage(message))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vm::{EndpointSource, Reach};
    use std::io::Cursor;

    fn endpoint(host: &str, port: u16, user: &str) -> VmEndpoint {
        VmEndpoint {
            host: host.to_string(),
            port,
            user: user.to_string(),
            source: EndpointSource::QemuHostfwd,
            guest_port: Some(22),
            detail: "test".to_string(),
            reach: Reach::Ssh {
                banner: "SSH-2.0-OpenSSH_9.6".to_string(),
            },
        }
    }

    #[test]
    fn explicit_endpoint_validates_its_parts() {
        let endpoint = explicit_endpoint("127.0.0.1", 2222, "builder").unwrap();
        assert_eq!(endpoint.label(), "builder@127.0.0.1:2222");
        assert!(explicit_endpoint("bad host", 2222, "builder").is_err());
        assert!(explicit_endpoint("127.0.0.1", 0, "builder").is_err());
        assert!(explicit_endpoint("127.0.0.1", 2222, "-user").is_err());
    }

    #[test]
    fn explicit_endpoint_defaults_the_missing_side() {
        let default_port = SetupOptions {
            host: Some("127.0.0.1".to_string()),
            ..SetupOptions::default()
        };
        let endpoint = resolve_endpoint(&default_port, &|_key: &str| None).unwrap();
        assert_eq!(endpoint.port, DEFAULT_SSH_PORT);

        let local_forward = SetupOptions {
            port: Some(2222),
            ..SetupOptions::default()
        };
        let endpoint = resolve_endpoint(&local_forward, &|_key: &str| None).unwrap();
        assert_eq!(endpoint.host, "127.0.0.1");
        assert_eq!(endpoint.port, 2222);
    }

    #[test]
    fn unique_candidate_is_chosen() {
        let first = endpoint("127.0.0.1", 2222, "builder");
        let candidates = vec![&first];
        let chosen = choose_candidate(&candidates, None, None).unwrap();
        assert_eq!(chosen, &first);
    }

    #[test]
    fn ambiguous_candidates_are_a_usage_error_with_options() {
        let first = endpoint("127.0.0.1", 2222, "builder");
        let second = endpoint("127.0.0.1", 2223, "builder");
        let candidates = vec![&first, &second];
        let error = choose_candidate(&candidates, None, None).unwrap_err();
        assert_eq!(error.exit_code(), crate::error::EXIT_USAGE);
        let message = error.to_string();
        assert!(message.contains("--host/--port"));
        assert!(message.contains("2222"));
        assert!(message.contains("2223"));

        let chosen = choose_candidate(&candidates, None, Some(2223)).unwrap();
        assert_eq!(chosen, &second);
        assert!(choose_candidate(&candidates, None, Some(9999)).is_err());
    }

    #[test]
    fn host_add_arguments_are_shell_free_argument_pairs() {
        let options = SetupOptions {
            name: "cachyos-vm".to_string(),
            key: Some(PathBuf::from("/home/u/.ssh/vm-key")),
            ..SetupOptions::default()
        };
        let endpoint = endpoint("127.0.0.1", 2222, "builder");
        let args = build_host_add_args(
            &options,
            &endpoint,
            Some(Path::new("/home/u/.ssh/vm-key")),
            &FingerprintChoice::Pin("SHA256:abc".to_string()),
        );
        assert_eq!(
            args,
            vec![
                "host",
                "add",
                "--name",
                "cachyos-vm",
                "--ssh",
                "builder@127.0.0.1",
                "--port",
                "2222",
                "--agent-path",
                DEFAULT_AGENT_PATH,
                "--identity",
                "/home/u/.ssh/vm-key",
                "--fingerprint",
                "SHA256:abc",
            ]
        );
    }

    #[test]
    fn accept_confirmation_passes_yes() {
        let args = FingerprintChoice::Accept.as_args();
        assert_eq!(args, vec!["--yes"]);
    }

    #[test]
    fn interactive_fingerprint_accepts_yes_or_a_listed_fingerprint() {
        let fingerprints = vec!["SHA256:first".to_string(), "SHA256:second".to_string()];

        let mut input = Cursor::new("yes\n");
        assert_eq!(
            confirm_fingerprint(&fingerprints, &mut input, true).unwrap(),
            FingerprintChoice::Accept
        );

        let mut input = Cursor::new("sha256:SECOND\n");
        assert_eq!(
            confirm_fingerprint(&fingerprints, &mut input, true).unwrap(),
            FingerprintChoice::Pin("sha256:SECOND".to_string())
        );

        let mut input = Cursor::new("nope\nnope\nnope\n");
        assert!(confirm_fingerprint(&fingerprints, &mut input, true).is_err());

        let mut input = Cursor::new("yes\n");
        let error = confirm_fingerprint(&fingerprints, &mut input, false).unwrap_err();
        assert_eq!(error.exit_code(), crate::error::EXIT_USAGE);
    }
}
