//! SSH binding: argv construction for the system OpenSSH client plus the few
//! `ssh-keyscan`/`ssh-keygen` calls the host wizard needs.
//!
//! The remote side runs the Agent's forced command (`builder-agent
//! ssh-dispatch`); the requested subcommand is the single remote-command
//! argument and is parsed strictly by the dispatch entry point. Everything the
//! Builder puts in front of sshd is built from validated tokens, and no shell is
//! involved on either side (PROTOCOL.md §3.1, §10.1).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::transport::TransportError;

fn default_port() -> u16 {
    22
}

fn default_connect_timeout() -> u32 {
    10
}

/// Connection parameters for a macOS host running the Build Agent behind
/// OpenSSH with a forced command.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshSpec {
    /// Host name or IP address (no spaces, no leading `-`).
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    pub user: String,
    /// Dedicated private key generated for this host profile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<PathBuf>,
    /// Profile-private `known_hosts`, written after the user confirms the host
    /// key fingerprint. Never the user's global file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub known_hosts: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub control_path: Option<PathBuf>,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout_secs: u32,
}

impl SshSpec {
    /// Check the values that end up on the ssh command line.
    pub fn validate(&self) -> Result<(), String> {
        validate_host(&self.host)?;
        validate_user(&self.user)?;
        if self.port == 0 {
            return Err("ssh port must be 1-65535".to_string());
        }
        Ok(())
    }

    pub fn destination(&self) -> String {
        format!("{}@{}", self.user, self.host)
    }

    pub fn describe(&self) -> String {
        format!("ssh {}@{}:{}", self.user, self.host, self.port)
    }

    /// Build the ssh command for one remote subcommand.
    pub fn ssh_command(&self, remote_subcommand: &str) -> Result<Command, TransportError> {
        self.validate().map_err(TransportError::InvalidConfig)?;
        validate_remote_command(remote_subcommand).map_err(TransportError::InvalidConfig)?;

        let mut command = Command::new("ssh");
        command.arg("-p").arg(self.port.to_string());
        command.args(["-o", "BatchMode=yes"]);
        command.args(["-o", "IdentitiesOnly=yes"]);
        command.args(["-o", "StrictHostKeyChecking=yes"]);
        command.args([
            "-o",
            &format!("ConnectTimeout={}", self.connect_timeout_secs),
        ]);
        command.args(["-o", "ServerAliveInterval=15"]);
        command.args(["-o", "ServerAliveCountMax=3"]);
        command.args(["-o", "LogLevel=ERROR"]);
        if let Some(known_hosts) = &self.known_hosts {
            command.args([
                "-o",
                &format!("UserKnownHostsFile={}", known_hosts.to_string_lossy()),
            ]);
            command.args(["-o", "GlobalKnownHostsFile=/dev/null"]);
        }
        if let Some(identity) = &self.identity {
            command.arg("-i").arg(identity);
        }
        if let Some(control_path) = &self.control_path {
            // Unix-domain socket paths are short; skip multiplexing rather than
            // fail when the profile directory is deep.
            let rendered = control_path.to_string_lossy().to_string();
            if rendered.len() < 90 {
                command.args(["-o", "ControlMaster=auto"]);
                command.args(["-o", &format!("ControlPath={rendered}")]);
                command.args(["-o", "ControlPersist=60"]);
            }
        }
        command.arg(self.destination());
        // One argument: ssh sends it verbatim as the remote command, which the
        // forced command reads from SSH_ORIGINAL_COMMAND.
        command.arg(remote_subcommand);
        Ok(command)
    }

    /// Spawn one remote subcommand with the caller-chosen stdio.
    pub fn spawn_with_stdio(
        &self,
        remote_subcommand: &str,
        stdin: Stdio,
        stdout: Stdio,
        stderr: Stdio,
    ) -> Result<Child, TransportError> {
        let mut command = self.ssh_command(remote_subcommand)?;
        command.stdin(stdin).stdout(stdout).stderr(stderr);
        command.spawn().map_err(|error| TransportError::Spawn {
            program: "ssh".to_string(),
            message: error.to_string(),
        })
    }
}

/// Host names: DNS labels, IPv4 or dotted names. No whitespace, no shell
/// metacharacters, and never a string that ssh could read as an option.
pub fn validate_host(host: &str) -> Result<(), String> {
    if host.is_empty() || host.len() > 253 {
        return Err("ssh host must be 1-253 characters".to_string());
    }
    if host.starts_with('-') {
        return Err("ssh host must not start with '-'".to_string());
    }
    if !host
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
    {
        return Err(format!(
            "ssh host {host:?} may contain only letters, digits, '.', '-' and '_'"
        ));
    }
    Ok(())
}

/// Login user: safe account-name characters only.
pub fn validate_user(user: &str) -> Result<(), String> {
    if user.is_empty() || user.len() > 64 {
        return Err("ssh user must be 1-64 characters".to_string());
    }
    if user.starts_with('-') {
        return Err("ssh user must not start with '-'".to_string());
    }
    if !user
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    {
        return Err(format!("ssh user {user:?} contains unsupported characters"));
    }
    Ok(())
}

/// Allowed characters for a remote subcommand line.
///
/// The line is one ssh argument, so whitespace matters (argument separator) but
/// quotes, semicolons, backslashes, `$`, backticks and newlines are rejected:
/// they are never needed for the Agent's fixed subcommands and would be shell
/// injection if the host were not using a forced command.
pub fn validate_remote_command(command: &str) -> Result<(), String> {
    if command.is_empty() || command.len() > 512 {
        return Err("remote command must be 1-512 characters".to_string());
    }
    if !command.bytes().all(|b| {
        b.is_ascii_alphanumeric() || matches!(b, b' ' | b'.' | b'_' | b'-' | b'=' | b':' | b'/')
    }) {
        return Err(format!(
            "remote command contains characters outside the allowlist: {command:?}"
        ));
    }
    if command.starts_with('-') {
        return Err("remote command must not start with '-'".to_string());
    }
    Ok(())
}

/// Suggested `authorized_keys` line for pairing (printed by `zkb host add`).
/// The user pastes it on the Mac; the Builder never edits the file remotely.
pub fn suggested_authorized_keys_line(
    agent_path: &str,
    profile_id: &str,
    public_key: &str,
) -> Result<String, String> {
    if !agent_path.starts_with('/') {
        return Err("agent path must be absolute (starts with '/')".to_string());
    }
    if agent_path.contains('"') || agent_path.contains('\n') {
        return Err("agent path contains unsupported characters".to_string());
    }
    if !profile_id
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
    {
        return Err("profile id contains unsupported characters".to_string());
    }
    if public_key.contains('\n') || public_key.trim().is_empty() {
        return Err("public key is empty or contains newlines".to_string());
    }
    Ok(format!(
        "command=\"{agent_path} ssh-dispatch\",restrict {public_key} 3ds2apple-builder {profile_id}"
    ))
}

/// Whether the system OpenSSH client is runnable.
pub fn ssh_available() -> Result<(), String> {
    match Command::new("ssh").arg("-V").output() {
        Ok(_) => Ok(()),
        Err(error) => Err(format!(
            "the OpenSSH client (`ssh`) is not available: {error}. On Windows enable the \
             'OpenSSH Client' optional feature; on Linux install openssh-client."
        )),
    }
}

/// Whether `ssh-keyscan` and `ssh-keygen` are available for the pairing step.
pub fn pairing_tools_available() -> Result<(), String> {
    for program in ["ssh-keyscan", "ssh-keygen"] {
        Command::new(program)
            .arg("-h")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .map_err(|error| format!("{program} is not available: {error}"))?;
    }
    Ok(())
}

/// Fetch the host key lines of a Mac. Returns the raw `known_hosts` lines.
pub fn scan_host_key(port: u16, host: &str, timeout_secs: u32) -> Result<Vec<String>, String> {
    validate_host(host)?;
    let output = Command::new("ssh-keyscan")
        .arg("-T")
        .arg(timeout_secs.to_string())
        .args(["-p", &port.to_string()])
        .arg(host)
        .output()
        .map_err(|error| format!("could not run ssh-keyscan: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "ssh-keyscan failed for {host}:{}: {}",
            port,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let lines: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim_end)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_string)
        .collect();
    if lines.is_empty() {
        return Err(format!("no host key received from {host}:{port}"));
    }
    Ok(lines)
}

/// SHA256 fingerprints of the given host key lines (`SHA256:...`).
pub fn host_key_fingerprints(host_key_lines: &[String]) -> Result<Vec<String>, String> {
    if host_key_lines.is_empty() {
        return Err("no host key lines to fingerprint".to_string());
    }
    let mut child = Command::new("ssh-keygen")
        .args(["-lf", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("could not run ssh-keygen: {error}"))?;
    {
        let stdin = child.stdin.as_mut().ok_or("ssh-keygen stdin unavailable")?;
        for line in host_key_lines {
            writeln!(stdin, "{line}").map_err(|error| error.to_string())?;
        }
    }
    let output = child
        .wait_with_output()
        .map_err(|error| error.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "ssh-keygen could not read the host key: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let mut fingerprints = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if let Some(fingerprint) = line.split_whitespace().nth(1) {
            if fingerprint.starts_with("SHA256:") {
                fingerprints.push(fingerprint.to_string());
            }
        }
    }
    if fingerprints.is_empty() {
        return Err("ssh-keygen produced no SHA256 fingerprint".to_string());
    }
    Ok(fingerprints)
}

/// Write a profile-private `known_hosts` file with owner-only permissions.
pub fn write_known_hosts(path: &Path, host_key_lines: &[String]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let text = format!("{}\n", host_key_lines.join("\n"));
    std::fs::write(path, text)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = std::fs::metadata(path)?.permissions();
        permissions.set_mode(0o600);
        std::fs::set_permissions(path, permissions)?;
    }
    Ok(())
}

/// Run `ssh-keygen -t ed25519` to create the dedicated per-profile key.
pub fn generate_identity(path: &Path, comment: &str) -> Result<String, String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let output = Command::new("ssh-keygen")
        .args(["-t", "ed25519", "-N", "", "-C", comment, "-f"])
        .arg(path)
        .output()
        .map_err(|error| format!("could not run ssh-keygen: {error}"))?;
    if !output.status.success() {
        return Err(format!(
            "ssh-keygen failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let public = path.with_extension("pub");
    let public_key = std::fs::read_to_string(&public)
        .map_err(|error| format!("could not read {}: {error}", public.display()))?;
    Ok(public_key.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> SshSpec {
        SshSpec {
            host: "mac-mini.local".into(),
            port: 22,
            user: "builder".into(),
            identity: Some(PathBuf::from("/home/u/.config/3ds2apple/key")),
            known_hosts: Some(PathBuf::from("/home/u/.config/3ds2apple/known_hosts")),
            control_path: Some(PathBuf::from("/tmp/3ds2apple-ssh-%r@%h:%p")),
            connect_timeout_secs: 10,
        }
    }

    fn argv(spec: &SshSpec, remote: &str) -> Vec<String> {
        let command = spec.ssh_command(remote).unwrap();
        command
            .get_args()
            .map(|arg| arg.to_string_lossy().to_string())
            .collect()
    }

    #[test]
    fn ssh_argv_is_batch_and_strict() {
        let args = argv(&spec(), "stdio");
        let joined = args.join(" ");
        assert!(joined.contains("-p 22"));
        assert!(joined.contains("-o BatchMode=yes"));
        assert!(joined.contains("-o IdentitiesOnly=yes"));
        assert!(joined.contains("-o StrictHostKeyChecking=yes"));
        assert!(joined.contains("-o ConnectTimeout=10"));
        assert!(joined.contains("UserKnownHostsFile=/home/u/.config/3ds2apple/known_hosts"));
        assert!(joined.contains("-i /home/u/.config/3ds2apple/key"));
        assert!(joined.contains("ControlMaster=auto"));
        // Destination and remote command are the last two arguments.
        let destination = args.len() - 2;
        assert_eq!(args[destination], "builder@mac-mini.local");
        assert_eq!(args[destination + 1], "stdio");
    }

    #[test]
    fn standard_port_is_always_explicit() {
        let mut custom = spec();
        custom.port = 2222;
        let args = argv(&custom, "doctor --json");
        assert!(args.join(" ").contains("-p 2222"));
        assert_eq!(args.last().unwrap(), "doctor --json");
    }

    #[test]
    fn missing_optional_settings_are_omitted() {
        let mut minimal = spec();
        minimal.identity = None;
        minimal.known_hosts = None;
        minimal.control_path = None;
        let joined = argv(&minimal, "stdio").join(" ");
        assert!(!joined.contains("-i "));
        assert!(!joined.contains("UserKnownHostsFile"));
        assert!(!joined.contains("ControlMaster"));
        assert!(joined.contains("StrictHostKeyChecking=yes"));
    }

    #[test]
    fn injection_through_host_or_user_is_rejected() {
        let mut evil = spec();
        evil.host = "mac.local; rm -rf /".into();
        assert!(evil.validate().is_err());
        assert!(evil.ssh_command("stdio").is_err());

        let mut evil = spec();
        evil.user = "-oProxyCommand=evil".into();
        assert!(evil.validate().is_err());

        let mut evil = spec();
        evil.host = "-oProxyCommand=evil".into();
        assert!(evil.validate().is_err());
    }

    #[test]
    fn remote_command_allowlist() {
        for ok in [
            "stdio",
            "doctor --json",
            "upload --job job_01J8Z3K4T9ABCDEFGHJKMNPQRS --role rom --bytes 10 --sha256 abcdef",
            "upload --job job_01J8Z3K4T9ABCDEFGHJKMNPQRS --role rom --bytes 10 --sha256 abcdef --offset 5",
            "download-artifact --job job_01J8Z3K4T9ABCDEFGHJKMNPQRS --what ipa --offset 0",
        ] {
            assert!(validate_remote_command(ok).is_ok(), "{ok}");
        }
        for bad in [
            "stdio; rm -rf /",
            "stdio && evil",
            "$(whoami)",
            "`id`",
            "stdio\nrm",
            "upload --job 'x'",
            "",
            "-oProxyCommand=evil",
        ] {
            assert!(validate_remote_command(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn authorized_keys_line_is_restricted() {
        let line = suggested_authorized_keys_line(
            "/Users/builder/.local/bin/builder-agent",
            "office",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA 3ds2apple-builder office",
        )
        .unwrap();
        assert!(line.starts_with(
            "command=\"/Users/builder/.local/bin/builder-agent ssh-dispatch\",restrict "
        ));
        assert!(line.ends_with("3ds2apple-builder office"));
        assert!(
            suggested_authorized_keys_line("relative/path", "office", "ssh-ed25519 AAAA").is_err()
        );
        assert!(
            suggested_authorized_keys_line("/bin/agent", "bad id", "ssh-ed25519 AAAA").is_err()
        );
        assert!(suggested_authorized_keys_line("/bin/agent", "office", "").is_err());
    }

    #[test]
    fn known_hosts_is_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("profile/known_hosts");
        write_known_hosts(&path, &["mac.local ssh-ed25519 AAAA".to_string()]).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(text, "mac.local ssh-ed25519 AAAA\n");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
    }

    #[test]
    fn host_and_user_rules() {
        assert!(validate_host("mac-mini.local").is_ok());
        assert!(validate_host("192.168.1.20").is_ok());
        assert!(validate_host("mac mini").is_err());
        assert!(validate_host("").is_err());
        assert!(validate_user("builder").is_ok());
        assert!(validate_user("builder-2").is_ok());
        assert!(validate_user("root user").is_err());
    }
}
