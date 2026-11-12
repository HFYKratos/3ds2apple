//! Discovery of a macOS VM's forwarded SSH port on a Linux workstation.
//!
//! A CachyOS/Arch workstation usually runs the macOS VM with QEMU/KVM and
//! user-mode networking, which forwards a host port to the guest's SSH port:
//!
//! ```text
//! qemu-system-x86_64 ... -netdev user,id=net0,hostfwd=tcp::2222-:22 ...
//! ```
//!
//! Remembering that rule, the login user and the host key fingerprint is the
//! tedious part of the first run. This module finds the rule in `/proc`, probes
//! the candidate ports for an SSH banner and ranks the results, so pairing can
//! start from a verified endpoint instead of a guess.
//!
//! The module only reads process metadata and opens TCP connections to
//! addresses the user already controls (loopback by default). It never sends
//! credentials and never modifies the VM.

use std::io::Read;
use std::net::{TcpStream, ToSocketAddrs};
use std::path::Path;
use std::time::Duration;

use builder_core::transport::ssh;
use serde::Serialize;

use crate::output::Printer;

/// SSH endpoint override (`[user@]host[:port]`), highest priority.
pub const ENV_SSH: &str = "ZKB_VM_SSH";
/// VM host override used with [`ENV_PORT`].
pub const ENV_HOST: &str = "ZKB_VM_HOST";
/// VM SSH port override.
pub const ENV_PORT: &str = "ZKB_VM_PORT";
/// Login user override for the VM.
pub const ENV_USER: &str = "ZKB_VM_USER";
/// Existing private key override (the shared CLI otherwise creates a dedicated
/// key during pairing).
pub const ENV_KEY: &str = "ZKB_VM_KEY";

/// Localhost ports tried when scanning for a forwarded SSH port.
const DEFAULT_LOCAL_PORTS: &[u16] = &[2222, 2223, 2224, 2200, 2201, 2022, 10022, 8022, 22222];

/// Default timeout for a single TCP connect/banner read.
const DEFAULT_PROBE_TIMEOUT: Duration = Duration::from_millis(700);

/// Where an endpoint came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EndpointSource {
    /// `ZKB_VM_*` environment variables.
    Env,
    /// A QEMU/KVM `hostfwd` rule found in `/proc/<pid>/cmdline`.
    QemuHostfwd,
    /// A localhost port that answered with an SSH banner.
    LocalPort,
}

impl EndpointSource {
    pub fn label(self) -> &'static str {
        match self {
            Self::Env => "environment",
            Self::QemuHostfwd => "qemu hostfwd",
            Self::LocalPort => "localhost port",
        }
    }
}

/// Result of probing an endpoint for an SSH server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Reach {
    /// The endpoint answered with an `SSH-...` banner.
    Ssh { banner: String },
    /// The TCP connection worked but the peer did not speak SSH.
    NotSsh { first_line: String },
    /// Nothing is listening.
    Closed,
    /// TCP connected or the banner read timed out.
    TimedOut,
    /// The host name could not be resolved.
    Unresolved { message: String },
    /// Probing was disabled.
    NotProbed,
}

impl Reach {
    pub fn is_ssh(&self) -> bool {
        matches!(self, Self::Ssh { .. })
    }

    pub fn label(&self) -> String {
        match self {
            Self::Ssh { banner } => format!("SSH ({banner})"),
            Self::NotSsh { first_line } if first_line.is_empty() => "not SSH (empty reply)".into(),
            Self::NotSsh { first_line } => format!("not SSH ({first_line})"),
            Self::Closed => "closed".into(),
            Self::TimedOut => "timed out".into(),
            Self::Unresolved { message } => format!("unresolved ({message})"),
            Self::NotProbed => "not probed".into(),
        }
    }
}

/// A candidate SSH endpoint for the macOS host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VmEndpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub source: EndpointSource,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guest_port: Option<u16>,
    pub detail: String,
    pub reach: Reach,
}

impl VmEndpoint {
    pub fn destination(&self) -> String {
        format!("{}@{}", self.user, self.host)
    }

    pub fn label(&self) -> String {
        format!("{}@{}:{}", self.user, self.host, self.port)
    }

    /// Command that pairs this endpoint (fingerprint confirmation still needed).
    pub fn setup_hint(&self) -> String {
        format!(
            "3ds2apple-builder vm setup --name cachyos-vm --host {} --port {} --user {}",
            self.host, self.port, self.user
        )
    }
}

/// Everything discovery found, plus human notes for the report.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Discovery {
    pub endpoints: Vec<VmEndpoint>,
    pub notes: Vec<String>,
}

impl Discovery {
    /// First endpoint that positively answered as SSH.
    pub fn best_ssh_candidate(&self) -> Option<&VmEndpoint> {
        self.endpoints
            .iter()
            .find(|endpoint| endpoint.reach.is_ssh())
    }

    /// All endpoints that answered as SSH, best first.
    pub fn ssh_candidates(&self) -> Vec<&VmEndpoint> {
        self.endpoints
            .iter()
            .filter(|endpoint| endpoint.reach.is_ssh())
            .collect()
    }
}

/// Options for [`discover`].
#[derive(Debug, Clone)]
pub struct DiscoverOptions {
    /// Also probe the default localhost port range.
    pub scan_ports: bool,
    /// Probe candidates for an SSH banner.
    pub probe: bool,
    /// Ports probed when `scan_ports` is set.
    pub ports: Vec<u16>,
    /// Per-connection connect/banner timeout.
    pub timeout: Duration,
}

impl Default for DiscoverOptions {
    fn default() -> Self {
        Self {
            scan_ports: false,
            probe: true,
            ports: default_local_ports(),
            timeout: DEFAULT_PROBE_TIMEOUT,
        }
    }
}

/// The default localhost ports checked when scanning is enabled.
pub fn default_local_ports() -> Vec<u16> {
    DEFAULT_LOCAL_PORTS.to_vec()
}

/// Look for a VM endpoint configured through environment variables.
///
/// `ZKB_VM_SSH` wins; otherwise `ZKB_VM_HOST` (+ optional `ZKB_VM_PORT`) is
/// used. The login user comes from the endpoint, then `ZKB_VM_USER`, then
/// `$USER`/`$LOGNAME`, then `builder`. No password is ever read or stored.
pub fn endpoint_from_env<F>(env_get: &F) -> Result<Option<VmEndpoint>, String>
where
    F: Fn(&str) -> Option<String>,
{
    let user = default_user(env_get);
    if let Some(spec) = env_get(ENV_SSH) {
        let spec = spec.trim().to_string();
        if spec.is_empty() {
            return Err(format!("{ENV_SSH} is empty"));
        }
        let (endpoint_user, host, port) = parse_ssh_spec(&spec)?;
        let user = endpoint_user.unwrap_or(user);
        return Ok(Some(make_endpoint(
            host,
            port,
            &user,
            EndpointSource::Env,
            None,
            format!("{ENV_SSH}={spec}"),
            Reach::NotProbed,
        )?));
    }
    if let Some(host) = env_get(ENV_HOST) {
        let host = host.trim().to_string();
        let port = match env_get(ENV_PORT) {
            Some(port) => parse_port(port.trim())?,
            None => 22,
        };
        let detail = format!("{ENV_HOST}={host} {ENV_PORT}={port}");
        return Ok(Some(make_endpoint(
            host,
            port,
            &user,
            EndpointSource::Env,
            None,
            detail,
            Reach::NotProbed,
        )?));
    }
    Ok(None)
}

/// Login user for the VM: `ZKB_VM_USER`, `$USER`, `$LOGNAME`, then `builder`.
pub fn default_user<F>(env_get: &F) -> String
where
    F: Fn(&str) -> Option<String>,
{
    for key in [ENV_USER, "USER", "LOGNAME"] {
        if let Some(value) = env_get(key) {
            let value = value.trim();
            if !value.is_empty() {
                return value.to_string();
            }
        }
    }
    "builder".to_string()
}

/// Existing private key override from `ZKB_VM_KEY`, if set.
pub fn identity_from_env<F>(env_get: &F) -> Option<std::path::PathBuf>
where
    F: Fn(&str) -> Option<String>,
{
    env_get(ENV_KEY)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(std::path::PathBuf::from)
}

/// Parse `[user@]host[:port]`.
pub fn parse_ssh_spec(spec: &str) -> Result<(Option<String>, String, u16), String> {
    let spec = spec.trim();
    if spec.is_empty() {
        return Err("the SSH endpoint is empty".to_string());
    }
    let (user, rest) = match spec.split_once('@') {
        Some((user, rest)) => {
            if user.is_empty() {
                return Err(format!("missing user in {spec:?}"));
            }
            (Some(user.to_string()), rest)
        }
        None => (None, spec),
    };
    if rest.starts_with('[') {
        return Err(
            "IPv6 endpoints are not supported here; use the IPv4 address or host name".to_string(),
        );
    }
    let (host, port) = match rest.rsplit_once(':') {
        Some((host, port)) => {
            if host.is_empty() {
                return Err(format!("missing host in {spec:?}"));
            }
            (host.to_string(), parse_port(port)?)
        }
        None => (rest.to_string(), 22),
    };
    if host.is_empty() {
        return Err(format!("missing host in {spec:?}"));
    }
    Ok((user, host, port))
}

fn parse_port(value: &str) -> Result<u16, String> {
    let port: u16 = value
        .trim()
        .parse()
        .map_err(|_| format!("invalid port {value:?}; expected 1-65535"))?;
    if port == 0 {
        return Err("port 0 is not a valid SSH port".to_string());
    }
    Ok(port)
}

fn make_endpoint(
    host: String,
    port: u16,
    user: &str,
    source: EndpointSource,
    guest_port: Option<u16>,
    detail: String,
    reach: Reach,
) -> Result<VmEndpoint, String> {
    ssh::validate_host(&host)?;
    ssh::validate_user(user)?;
    Ok(VmEndpoint {
        host,
        port,
        user: user.to_string(),
        source,
        guest_port,
        detail,
        reach,
    })
}

/// Parse a QEMU `hostfwd` rule into `(bind host, bind port, guest port)`.
///
/// Accepted forms: `tcp:127.0.0.1:2222-:22`, `tcp::2222-:22`,
/// `tcp:0.0.0.0:2222-:22`, `tcp:[::]:2222-:22`, `tcp:localhost:2222-:22`.
/// Only TCP rules are relevant for SSH; UDP rules return `None`.
pub fn parse_hostfwd_rule(rule: &str) -> Option<(String, u16, u16)> {
    let rule = rule.trim();
    let rule = rule.strip_prefix("tcp:")?;
    let (bind, guest) = rule.split_once('-')?;
    let (bind_host, bind_port) = split_host_port(bind)?;
    if bind_port == 0 {
        return None;
    }
    let guest_port: u16 = guest
        .trim_start_matches(':')
        .rsplit(':')
        .next()?
        .parse()
        .ok()?;
    if guest_port == 0 {
        return None;
    }
    Some((normalize_bind_host(&bind_host), bind_port, guest_port))
}

fn split_host_port(bind: &str) -> Option<(String, u16)> {
    let bind = bind.trim();
    if let Some(inner) = bind.strip_prefix('[') {
        // [::]:2222
        let (host, rest) = inner.split_once(']')?;
        let port = rest.strip_prefix(':')?.parse().ok()?;
        return Some((host.to_string(), port));
    }
    let (host, port) = bind.rsplit_once(':')?;
    Some((host.to_string(), port.parse().ok()?))
}

fn normalize_bind_host(bind: &str) -> String {
    let bind = bind.trim();
    if bind.is_empty()
        || bind == "0.0.0.0"
        || bind == "::"
        || bind == "[::]"
        || bind == "::1"
        || bind == "localhost"
    {
        "127.0.0.1".to_string()
    } else {
        bind.to_string()
    }
}

/// A `hostfwd` rule found in a running QEMU process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostFwd {
    pub host: String,
    pub port: u16,
    pub guest_port: u16,
    pub pid: u32,
    /// VM name from `-name guest=...` when present.
    pub guest_name: Option<String>,
}

impl HostFwd {
    pub fn detail(&self) -> String {
        match &self.guest_name {
            Some(guest) => format!(
                "qemu pid {} (guest {guest}), guest port {}",
                self.pid, self.guest_port
            ),
            None => format!("qemu pid {}, guest port {}", self.pid, self.guest_port),
        }
    }
}

/// Search `/proc` for QEMU/KVM user-mode networking forwards.
///
/// Returns the forwards (SSH-eligible guest port first) and human notes about
/// processes/rules that could not be used.
pub fn scan_qemu_hostfwd(proc_root: &Path) -> (Vec<HostFwd>, Vec<String>) {
    let mut forwards = Vec::new();
    let mut notes: Vec<String> = Vec::new();
    let entries = match std::fs::read_dir(proc_root) {
        Ok(entries) => entries,
        Err(error) => {
            push_note(
                &mut notes,
                format!("cannot read {}: {error}", proc_root.display()),
            );
            return (forwards, notes);
        }
    };
    let mut qemu_processes = 0_usize;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Ok(pid) = name.parse::<u32>() else {
            continue;
        };
        let bytes = match std::fs::read(entry.path().join("cmdline")) {
            Ok(bytes) => bytes,
            Err(_) => continue,
        };
        let argv: Vec<String> = bytes
            .split(|byte| *byte == 0)
            .filter(|part| !part.is_empty())
            .map(|part| String::from_utf8_lossy(part).to_string())
            .collect();
        let Some(program) = argv.first() else {
            continue;
        };
        let basename = Path::new(program)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(program);
        if !basename.contains("qemu") {
            continue;
        }
        qemu_processes += 1;
        let guest_name = qemu_guest_name(&argv);
        for arg in &argv {
            for chunk in arg.split(',') {
                let Some(rule) = chunk.strip_prefix("hostfwd=") else {
                    continue;
                };
                if rule.starts_with("udp:") {
                    push_note(
                        &mut notes,
                        format!("ignoring UDP forward {rule:?} of qemu pid {pid} (SSH is TCP)"),
                    );
                    continue;
                }
                match parse_hostfwd_rule(rule) {
                    Some((host, port, guest_port)) => {
                        if forwards
                            .iter()
                            .any(|forward: &HostFwd| forward.host == host && forward.port == port)
                        {
                            continue;
                        }
                        forwards.push(HostFwd {
                            host,
                            port,
                            guest_port,
                            pid,
                            guest_name: guest_name.clone(),
                        });
                    }
                    None => push_note(
                        &mut notes,
                        format!("ignoring unsupported qemu forward {rule:?} (pid {pid})"),
                    ),
                }
            }
        }
    }
    if qemu_processes == 0 {
        push_note(
            &mut notes,
            format!(
                "no running QEMU process was found under {}; start the macOS VM first",
                proc_root.display()
            ),
        );
    }
    // Prefer port forwards whose guest port is SSH.
    forwards.sort_by_key(|forward| {
        let ssh_bonus = if forward.guest_port == 22 { 0 } else { 1 };
        (ssh_bonus, forward.port)
    });
    (forwards, notes)
}

fn qemu_guest_name(argv: &[String]) -> Option<String> {
    let mut index = 0;
    while index < argv.len() {
        let arg = &argv[index];
        let value: Option<&str> = if arg == "-name" {
            argv.get(index + 1).map(String::as_str)
        } else {
            arg.strip_prefix("-name=")
        };
        if let Some(value) = value {
            let first = value.split(',').next().unwrap_or(value);
            let first = first.strip_prefix("guest=").unwrap_or(first);
            if !first.is_empty() {
                return Some(first.to_string());
            }
        }
        index += 1;
    }
    None
}

fn push_note(notes: &mut Vec<String>, note: String) {
    if !notes.contains(&note) {
        notes.push(note);
    }
}

/// Probe one endpoint for an SSH server (connect + read the banner).
pub fn probe_ssh(host: &str, port: u16, timeout: Duration) -> Reach {
    let addresses: Vec<std::net::SocketAddr> = match (host, port).to_socket_addrs() {
        Ok(addresses) => addresses.collect(),
        Err(error) => {
            return Reach::Unresolved {
                message: error.to_string(),
            }
        }
    };
    let Some(address) = addresses.first().copied() else {
        return Reach::Unresolved {
            message: "the host name did not resolve to an address".to_string(),
        };
    };
    let mut stream = match TcpStream::connect_timeout(&address, timeout) {
        Ok(stream) => stream,
        Err(error) => {
            return match error.kind() {
                std::io::ErrorKind::ConnectionRefused => Reach::Closed,
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => Reach::TimedOut,
                _ => Reach::Unresolved {
                    message: error.to_string(),
                },
            };
        }
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let mut buffer = [0_u8; 256];
    match stream.read(&mut buffer) {
        Ok(0) => Reach::NotSsh {
            first_line: String::new(),
        },
        Ok(read) => {
            let text = String::from_utf8_lossy(&buffer[..read]).to_string();
            let first_line = text
                .lines()
                .next()
                .unwrap_or("")
                .trim_end_matches('\r')
                .to_string();
            if first_line.starts_with("SSH-") {
                Reach::Ssh { banner: first_line }
            } else {
                Reach::NotSsh { first_line }
            }
        }
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            Reach::TimedOut
        }
        Err(error) => Reach::NotSsh {
            first_line: format!("read error: {error}"),
        },
    }
}

/// Parse a `--ports` value: comma-separated ports and inclusive ranges
/// (`2222,2200-2205`).
pub fn parse_ports(value: &str) -> Result<Vec<u16>, String> {
    let mut ports: Vec<u16> = Vec::new();
    for part in value.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        match part.split_once('-') {
            Some((start, end)) => {
                let start = parse_port(start)?;
                let end = parse_port(end)?;
                if start > end {
                    return Err(format!("port range {part:?} is descending"));
                }
                if u32::from(end) - u32::from(start) > 1000 {
                    return Err(format!("port range {part:?} covers more than 1000 ports"));
                }
                for port in start..=end {
                    if !ports.contains(&port) {
                        ports.push(port);
                    }
                }
            }
            None => {
                let port = parse_port(part)?;
                if !ports.contains(&port) {
                    ports.push(port);
                }
            }
        }
    }
    if ports.is_empty() {
        return Err("no ports given".to_string());
    }
    Ok(ports)
}

/// Run discovery and return ranked endpoints plus notes.
///
/// `env_get` is injected so the discovery logic is testable without mutating
/// the process environment; the real command passes `std::env::var`.
pub fn discover<F>(options: &DiscoverOptions, env_get: F, proc_root: &Path) -> Discovery
where
    F: Fn(&str) -> Option<String>,
{
    let mut discovery = Discovery::default();
    let user = default_user(&env_get);

    // 1. Explicit environment override.
    match endpoint_from_env(&env_get) {
        Ok(Some(mut endpoint)) => {
            if options.probe {
                endpoint.reach = probe_ssh(&endpoint.host, endpoint.port, options.timeout);
            }
            if !endpoint.reach.is_ssh() && !matches!(endpoint.reach, Reach::NotProbed) {
                push_note(
                    &mut discovery.notes,
                    format!(
                        "the endpoint from {ENV_SSH}/{ENV_HOST} did not answer as SSH: {}",
                        endpoint.reach.label()
                    ),
                );
            }
            discovery.endpoints.push(endpoint);
        }
        Ok(None) => {}
        Err(message) => push_note(
            &mut discovery.notes,
            format!("ignoring the VM environment override: {message}"),
        ),
    }

    // 2. QEMU/KVM host forwarding rules.
    let (forwards, mut qemu_notes) = scan_qemu_hostfwd(proc_root);
    discovery.notes.append(&mut qemu_notes);
    for forward in forwards {
        if discovery
            .endpoints
            .iter()
            .any(|endpoint| endpoint.host == forward.host && endpoint.port == forward.port)
        {
            continue;
        }
        let mut reach = Reach::NotProbed;
        if options.probe {
            reach = probe_ssh(&forward.host, forward.port, options.timeout);
            if !reach.is_ssh() {
                push_note(
                    &mut discovery.notes,
                    format!(
                        "qemu forward {}:{} is not answering as SSH ({}); is the VM booted \
                         and Remote Login enabled?",
                        forward.host,
                        forward.port,
                        reach.label()
                    ),
                );
            }
        }
        match make_endpoint(
            forward.host.clone(),
            forward.port,
            &user,
            EndpointSource::QemuHostfwd,
            Some(forward.guest_port),
            forward.detail(),
            reach,
        ) {
            Ok(endpoint) => discovery.endpoints.push(endpoint),
            Err(message) => push_note(
                &mut discovery.notes,
                format!(
                    "ignoring qemu forward {}:{}: {message}",
                    forward.host, forward.port
                ),
            ),
        }
    }

    // 3. Optional localhost port scan.
    if options.scan_ports {
        for port in &options.ports {
            if discovery
                .endpoints
                .iter()
                .any(|endpoint| endpoint.host == "127.0.0.1" && endpoint.port == *port)
            {
                continue;
            }
            let reach = if options.probe {
                probe_ssh("127.0.0.1", *port, options.timeout)
            } else {
                Reach::NotProbed
            };
            if !options.probe {
                continue;
            }
            if reach.is_ssh() {
                match make_endpoint(
                    "127.0.0.1".to_string(),
                    *port,
                    &user,
                    EndpointSource::LocalPort,
                    Some(22),
                    format!("SSH listener on 127.0.0.1:{port}"),
                    reach,
                ) {
                    Ok(endpoint) => discovery.endpoints.push(endpoint),
                    Err(message) => push_note(
                        &mut discovery.notes,
                        format!("ignoring local port {port}: {message}"),
                    ),
                }
            }
        }
    }

    if discovery.endpoints.is_empty() {
        push_note(
            &mut discovery.notes,
            format!(
                "no candidate found. Start the macOS VM, enable Remote Login in it, then set \
                 {ENV_SSH}=user@127.0.0.1:2222 (or pass --host/--port) if the QEMU forwarding \
                 rule is not visible from this account."
            ),
        );
    }
    discovery
}

/// Print a discovery report and the suggested setup command.
pub fn print_discovery(discovery: &Discovery, printer: Printer) {
    if discovery.endpoints.is_empty() {
        printer.line("No macOS VM SSH endpoint found.");
        printer.line("Start the VM and enable Remote Login in it, then either rely on the");
        printer.line("QEMU forwarding rule below or pass --host/--port to `vm setup`.");
    } else {
        printer.line("Candidate macOS SSH endpoints:");
        for (index, endpoint) in discovery.endpoints.iter().enumerate() {
            printer.line(format!(
                "  {}. {:<30} {:<15} {:<28} {}",
                index + 1,
                endpoint.label(),
                endpoint.source.label(),
                endpoint.reach.label(),
                endpoint.detail
            ));
        }
    }
    if !discovery.notes.is_empty() {
        printer.blank();
        for note in &discovery.notes {
            printer.line(format!("note: {note}"));
        }
    }
    if let Some(best) = discovery.best_ssh_candidate() {
        printer.blank();
        printer.line("Pair it with:");
        printer.line(format!("  {}", best.setup_hint()));
        printer.line("  (verify the printed host-key fingerprint on the VM before confirming)");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env_map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }

    fn env_reader(map: &HashMap<String, String>) -> impl Fn(&str) -> Option<String> + '_ {
        move |key: &str| map.get(key).cloned()
    }

    #[test]
    fn parses_ssh_specs() {
        assert_eq!(
            parse_ssh_spec("builder@127.0.0.1:2222").unwrap(),
            (Some("builder".into()), "127.0.0.1".into(), 2222)
        );
        assert_eq!(
            parse_ssh_spec("mac-vm").unwrap(),
            (None, "mac-vm".into(), 22)
        );
        assert_eq!(
            parse_ssh_spec("user@10.0.2.2:2200").unwrap(),
            (Some("user".into()), "10.0.2.2".into(), 2200)
        );
        assert!(parse_ssh_spec("").is_err());
        assert!(parse_ssh_spec("user@:2222").is_err());
        assert!(parse_ssh_spec("[::1]:2222").is_err());
        assert!(parse_ssh_spec("host:notaport").is_err());
        assert!(parse_ssh_spec("host:0").is_err());
    }

    #[test]
    fn endpoint_from_env_prefers_ssh_override() {
        let map = env_map(&[
            (ENV_SSH, "builder@127.0.0.1:2222"),
            (ENV_HOST, "10.0.0.5"),
            (ENV_PORT, "22"),
            (ENV_USER, "someoneelse"),
        ]);
        let endpoint = endpoint_from_env(&env_reader(&map)).unwrap().unwrap();
        assert_eq!(endpoint.label(), "builder@127.0.0.1:2222");
        assert_eq!(endpoint.source, EndpointSource::Env);
        assert!(endpoint.detail.contains(ENV_SSH));
    }

    #[test]
    fn endpoint_from_env_uses_host_and_user_fallbacks() {
        let map = env_map(&[(ENV_HOST, "10.0.0.5"), (ENV_USER, "vmuser")]);
        let endpoint = endpoint_from_env(&env_reader(&map)).unwrap().unwrap();
        assert_eq!(endpoint.label(), "vmuser@10.0.0.5:22");
    }

    #[test]
    fn endpoint_from_env_is_optional_and_validated() {
        let map = env_map(&[]);
        assert!(endpoint_from_env(&env_reader(&map)).unwrap().is_none());
        let bad = env_map(&[(ENV_SSH, "user@bad host:22")]);
        assert!(endpoint_from_env(&env_reader(&bad)).is_err());
    }

    #[test]
    fn parses_qemu_hostfwd_rules() {
        assert_eq!(
            parse_hostfwd_rule("tcp:127.0.0.1:2222-:22"),
            Some(("127.0.0.1".to_string(), 2222, 22))
        );
        assert_eq!(
            parse_hostfwd_rule("tcp::2222-:22"),
            Some(("127.0.0.1".to_string(), 2222, 22))
        );
        assert_eq!(
            parse_hostfwd_rule("tcp:0.0.0.0:2200-:22"),
            Some(("127.0.0.1".to_string(), 2200, 22))
        );
        assert_eq!(
            parse_hostfwd_rule("tcp:[::]:2210-:22"),
            Some(("127.0.0.1".to_string(), 2210, 22))
        );
        assert_eq!(
            parse_hostfwd_rule("tcp:localhost:2222-:2222"),
            Some(("127.0.0.1".to_string(), 2222, 2222))
        );
        assert_eq!(parse_hostfwd_rule("udp:127.0.0.1:1234-:1234"), None);
        assert_eq!(parse_hostfwd_rule("tcp:not-a-rule"), None);
        assert_eq!(parse_hostfwd_rule("tcp:127.0.0.1:0-:22"), None);
    }

    fn write_cmdline(path: &Path, argv: &[&str]) {
        let bytes: Vec<u8> = argv
            .iter()
            .flat_map(|arg| arg.bytes().chain(std::iter::once(0)))
            .collect();
        std::fs::write(path, bytes).unwrap();
    }

    #[test]
    fn scans_qemu_processes_for_forwarded_ports() {
        let dir = tempfile::tempdir().unwrap();
        let proc_root = dir.path();
        std::fs::create_dir_all(proc_root.join("4242")).unwrap();
        write_cmdline(
            &proc_root.join("4242").join("cmdline"),
            &[
                "/usr/bin/qemu-system-x86_64",
                "-name",
                "guest=macOS-VM,debug-threads=on",
                "-netdev",
                "user,id=net0,hostfwd=tcp::2222-:22",
                "-m",
                "8192",
            ],
        );
        // Not a QEMU process.
        std::fs::create_dir_all(proc_root.join("1234")).unwrap();
        write_cmdline(
            &proc_root.join("1234").join("cmdline"),
            &["/usr/bin/bash", "-c", "hostfwd=tcp::9999-:22"],
        );
        // Non-numeric directory.
        std::fs::create_dir_all(proc_root.join("self")).unwrap();

        let (forwards, notes) = scan_qemu_hostfwd(proc_root);
        assert_eq!(forwards.len(), 1, "{forwards:?} {notes:?}");
        let forward = &forwards[0];
        assert_eq!(forward.host, "127.0.0.1");
        assert_eq!(forward.port, 2222);
        assert_eq!(forward.guest_port, 22);
        assert_eq!(forward.pid, 4242);
        assert_eq!(forward.guest_name.as_deref(), Some("macOS-VM"));
    }

    #[test]
    fn scan_notes_missing_qemu_and_udp_rules() {
        let dir = tempfile::tempdir().unwrap();
        let (forwards, notes) = scan_qemu_hostfwd(dir.path());
        assert!(forwards.is_empty());
        assert!(notes.iter().any(|note| note.contains("no running QEMU")));

        std::fs::create_dir_all(dir.path().join("77")).unwrap();
        write_cmdline(
            &dir.path().join("77").join("cmdline"),
            &[
                "qemu-system-aarch64",
                "-netdev",
                "user,hostfwd=udp:127.0.0.1:5000-:5000,hostfwd=tcp:127.0.0.1:2222-:22",
            ],
        );
        let (forwards, notes) = scan_qemu_hostfwd(dir.path());
        assert_eq!(forwards.len(), 1);
        assert!(notes.iter().any(|note| note.contains("UDP")));
    }

    #[test]
    fn probes_an_ssh_banner_and_a_non_ssh_service() {
        use std::io::Write;
        use std::net::TcpListener;

        let ssh_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let ssh_port = ssh_listener.local_addr().unwrap().port();
        let ssh_thread = std::thread::spawn(move || {
            let (mut stream, _) = ssh_listener.accept().unwrap();
            stream.write_all(b"SSH-2.0-OpenSSH_9.6\r\n").unwrap();
        });
        let reach = probe_ssh("127.0.0.1", ssh_port, Duration::from_millis(700));
        ssh_thread.join().unwrap();
        assert!(reach.is_ssh(), "{reach:?}");
        match reach {
            Reach::Ssh { banner } => assert!(banner.contains("OpenSSH_9.6")),
            other => panic!("expected SSH, got {other:?}"),
        }

        let http_listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let http_port = http_listener.local_addr().unwrap().port();
        let http_thread = std::thread::spawn(move || {
            let (mut stream, _) = http_listener.accept().unwrap();
            stream
                .write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n")
                .unwrap();
        });
        let reach = probe_ssh("127.0.0.1", http_port, Duration::from_millis(700));
        http_thread.join().unwrap();
        assert!(matches!(reach, Reach::NotSsh { .. }), "{reach:?}");
    }

    #[test]
    fn probes_a_closed_port() {
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let reach = probe_ssh("127.0.0.1", port, Duration::from_millis(200));
        assert!(
            matches!(reach, Reach::Closed | Reach::TimedOut),
            "{reach:?}"
        );
    }

    #[test]
    fn parses_port_lists_and_ranges() {
        assert_eq!(
            parse_ports("2222,2200-2202").unwrap(),
            vec![2222, 2200, 2201, 2202]
        );
        assert_eq!(parse_ports("2222,2222").unwrap(), vec![2222]);
        assert!(parse_ports("").is_err());
        assert!(parse_ports("0").is_err());
        assert!(parse_ports("70000").is_err());
        assert!(parse_ports("2202-2200").is_err());
        assert!(parse_ports("1-5000").is_err());
    }

    #[test]
    fn discovery_uses_environment_override_without_probing() {
        let map = env_map(&[(ENV_SSH, "builder@127.0.0.1:2222")]);
        let options = DiscoverOptions {
            scan_ports: false,
            probe: false,
            ..DiscoverOptions::default()
        };
        let dir = tempfile::tempdir().unwrap();
        let discovery = discover(&options, env_reader(&map), dir.path());
        assert_eq!(discovery.endpoints.len(), 1);
        assert_eq!(discovery.best_ssh_candidate(), None);
        assert!(matches!(discovery.endpoints[0].reach, Reach::NotProbed));
    }

    #[test]
    fn discovery_probes_qemu_forward() {
        use std::io::Write;
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let thread = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.write_all(b"SSH-2.0-OpenSSH_9.6\r\n").unwrap();
        });
        let dir = tempfile::tempdir().unwrap();
        let proc_root = dir.path();
        std::fs::create_dir_all(proc_root.join("99")).unwrap();
        write_cmdline(
            &proc_root.join("99").join("cmdline"),
            &[
                "qemu-system-x86_64",
                "-netdev",
                &format!("user,hostfwd=tcp:127.0.0.1:{port}-:22"),
            ],
        );
        let empty = env_map(&[]);
        let discovery = discover(
            &DiscoverOptions {
                scan_ports: false,
                probe: true,
                ports: vec![],
                timeout: Duration::from_millis(700),
            },
            env_reader(&empty),
            proc_root,
        );
        thread.join().unwrap();
        let candidate = discovery.best_ssh_candidate().expect("SSH candidate");
        assert_eq!(candidate.port, port);
        assert_eq!(candidate.source, EndpointSource::QemuHostfwd);
        assert_eq!(candidate.guest_port, Some(22));
    }
}
