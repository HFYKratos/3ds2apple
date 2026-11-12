//! `doctor`: check this Linux machine, the Builder configuration and, when
//! asked, the macOS host itself.
//!
//! The report separates blocking failures (exit code 3) from warnings. It
//! never asks for secrets and never prints a private key: only paths and file
//! permission problems.

use std::path::Path;

use builder_core::config::BuilderConfig;
use builder_core::transport::{ssh, TransportSpec};
use serde::Serialize;

use crate::error::Error;
use crate::output::Printer;
use crate::paths;
use crate::vm;
use crate::zkb::{self, Zkb};

/// One line of the doctor report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckStatus {
    Ok,
    Warn,
    Fail,
}

/// A single check and its explanation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Check {
    pub name: String,
    pub status: CheckStatus,
    pub detail: String,
}

/// Options for `doctor`.
#[derive(Debug, Clone)]
pub struct DoctorOptions {
    /// Also run the remote `zkb host test` for this host.
    pub host: Option<String>,
    /// Probe QEMU forwards and scan localhost ports.
    pub probe: bool,
    /// Ports used by the optional scan.
    pub ports: Vec<u16>,
    /// Per-connection timeout.
    pub timeout_ms: u64,
}

impl Default for DoctorOptions {
    fn default() -> Self {
        Self {
            host: None,
            probe: false,
            ports: vm::default_local_ports(),
            timeout_ms: 700,
        }
    }
}

/// The whole report; `ready` is false when any check failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DoctorReport {
    pub checks: Vec<Check>,
    pub ready: bool,
}

fn check(name: &str, status: CheckStatus, detail: impl Into<String>) -> Check {
    Check {
        name: name.to_string(),
        status,
        detail: detail.into(),
    }
}

fn ok(name: &str, detail: impl Into<String>) -> Check {
    check(name, CheckStatus::Ok, detail)
}

fn warn(name: &str, detail: impl Into<String>) -> Check {
    check(name, CheckStatus::Warn, detail)
}

fn fail(name: &str, detail: impl Into<String>) -> Check {
    check(name, CheckStatus::Fail, detail)
}

/// Run the checks and return the process exit code (0 ready, 3 not ready).
pub fn run<F>(
    options: &DoctorOptions,
    config_path: &Path,
    explicit_zkb: Option<&Path>,
    current_exe: &Path,
    env_get: F,
    printer: Printer,
) -> Result<i32, Error>
where
    F: Fn(&str) -> Option<String>,
{
    let mut checks = Vec::new();

    // 1. The shared client.
    let zkb = Zkb::locate(
        explicit_zkb,
        std::env::var_os(zkb::ENV_ZKB_BIN),
        current_exe,
    );
    match &zkb {
        Ok(zkb) => {
            let version = zkb
                .version()
                .unwrap_or_else(|| "version unknown".to_string());
            checks.push(ok("zkb", format!("{} ({version})", zkb.path().display())));
        }
        Err(error) => checks.push(fail(
            "zkb",
            format!(
                "{error}. Build it with `cargo build --release -p builder-cli` and put it on \
                 PATH, or pass --zkb."
            ),
        )),
    }

    // 2. OpenSSH tooling for pairing and the transport.
    let ssh_status = ssh::ssh_available()
        .and_then(|()| ssh::pairing_tools_available())
        .map(|()| "ssh, ssh-keygen and ssh-keyscan are available".to_string());
    match ssh_status {
        Ok(detail) => checks.push(ok("openssh", detail)),
        Err(message) => checks.push(fail(
            "openssh",
            format!("{message} (CachyOS/Arch: `sudo pacman -S openssh`)"),
        )),
    }

    // 3. Configuration file and host profiles.
    let config = match BuilderConfig::load(config_path) {
        Ok(config) => {
            let hosts = if config.hosts.is_empty() {
                "no hosts configured yet".to_string()
            } else {
                config
                    .hosts
                    .iter()
                    .map(|host| host.id.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            };
            let detail = format!("{} ({hosts})", config_path.display());
            if let Some(mode) = overly_permissive(config_path) {
                checks.push(warn(
                    "config",
                    format!(
                        "{detail}; the file mode is {mode:o} and readable by other users \
                         (chmod 600 {})",
                        config_path.display()
                    ),
                ));
            } else {
                checks.push(ok("config", detail.clone()));
            }
            Some(config)
        }
        Err(message) => {
            checks.push(fail("config", message));
            None
        }
    };

    // 4. Per-profile SSH keys and known_hosts files.
    if let Some(config) = &config {
        let mut checked = 0_usize;
        let mut problems: Vec<String> = Vec::new();
        for host in &config.hosts {
            let TransportSpec::Ssh(spec) = &host.transport else {
                continue;
            };
            checked += 1;
            if let Some(identity) = &spec.identity {
                match file_mode(identity) {
                    None => problems.push(format!(
                        "host {}: private key {} is missing; re-pair with `3ds2apple-builder vm setup`",
                        host.id,
                        identity.display()
                    )),
                    Some(mode) if mode & 0o077 != 0 => problems.push(format!(
                        "host {}: private key {} is readable by other users (mode {mode:o}); chmod 600",
                        host.id,
                        identity.display()
                    )),
                    Some(_) => {}
                }
            }
            if let Some(known_hosts) = &spec.known_hosts {
                if !known_hosts.is_file() {
                    problems.push(format!(
                        "host {}: {} is missing; re-pair the host",
                        host.id,
                        known_hosts.display()
                    ));
                }
            }
        }
        if checked == 0 {
            checks.push(ok("ssh keys", "no SSH host profiles to check yet"));
        } else if problems.is_empty() {
            checks.push(ok(
                "ssh keys",
                format!("{checked} SSH profile(s), key permissions 0600"),
            ));
        } else {
            for problem in &problems {
                checks.push(fail("ssh keys", problem.clone()));
            }
        }
    }

    // 5. Local macOS VM candidates.
    let discovery = vm::discover(
        &vm::DiscoverOptions {
            scan_ports: options.probe,
            probe: true,
            ports: options.ports.clone(),
            timeout: std::time::Duration::from_millis(options.timeout_ms),
        },
        &env_get,
        Path::new("/proc"),
    );
    let ssh_candidates = discovery.ssh_candidates();
    let hosts_configured = config
        .as_ref()
        .map(|config| !config.hosts.is_empty())
        .unwrap_or(false);
    if let Some(best) = ssh_candidates.first() {
        checks.push(ok(
            "macos vm",
            format!(
                "{} ({}){}",
                best.label(),
                best.source.label(),
                if ssh_candidates.len() > 1 {
                    format!(", {} candidates", ssh_candidates.len())
                } else {
                    String::new()
                }
            ),
        ));
    } else if hosts_configured {
        checks.push(ok(
            "macos vm",
            "no local VM endpoint found (optional when the host is a LAN Mac)",
        ));
    } else {
        checks.push(warn(
            "macos vm",
            "no local VM SSH endpoint found; start the VM and set ZKB_VM_SSH, or pass \
             --host/--port to `vm setup`",
        ));
    }

    // 6. Data directory writability.
    let artifacts = paths::artifacts_dir();
    match std::fs::create_dir_all(&artifacts) {
        Ok(()) => checks.push(ok("data directory", format!("{}", artifacts.display()))),
        Err(error) => checks.push(fail(
            "data directory",
            format!("cannot create {}: {error}", artifacts.display()),
        )),
    }

    // 7. Optional source checkout (for --expected-revision pinning).
    let cwd = std::env::current_dir().unwrap_or_else(|_| Path::new(".").to_path_buf());
    match paths::project_root(&cwd) {
        Some(root) => match paths::git_revision(&root) {
            Some((revision, dirty)) => checks.push(if dirty {
                warn(
                    "checkout",
                    format!("{root:?} @ {revision}, uncommitted changes (fine for local work)"),
                )
            } else {
                ok("checkout", format!("{root:?} @ {revision}"))
            }),
            None => checks.push(ok(
                "checkout",
                format!("{root:?} (git revision unavailable)"),
            )),
        },
        None => checks.push(ok("checkout", "not inside a 3ds2apple checkout (optional)")),
    }

    // 8. Optional remote host self-test.
    if let Some(host) = &options.host {
        match &zkb {
            Ok(zkb) => {
                let args = zkb::with_globals(
                    Some(config_path),
                    false,
                    vec!["host".to_string(), "test".to_string(), host.clone()],
                );
                printer.progress(format!("running `zkb host test {host}`..."));
                let output = zkb.run_streaming(&args, !printer.json)?;
                if output.succeeded() {
                    checks.push(ok("host test", format!("host {host} is ready")));
                } else {
                    let tail = output
                        .stderr
                        .iter()
                        .chain(output.stdout.iter())
                        .rev()
                        .take(5)
                        .cloned()
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect::<Vec<_>>()
                        .join(" | ");
                    checks.push(fail(
                        "host test",
                        format!(
                            "host {host} is not ready (zkb exit {}){}{}",
                            output.code,
                            if tail.is_empty() { "" } else { ": " },
                            tail
                        ),
                    ));
                }
            }
            Err(_) => checks.push(fail(
                "host test",
                "cannot test the host without the shared `zkb` client",
            )),
        }
    }

    let ready = checks.iter().all(|check| check.status != CheckStatus::Fail);
    let report = DoctorReport { checks, ready };
    if printer.json {
        printer.json(&report);
    } else {
        printer.line("3ds2apple Builder doctor");
        for check in &report.checks {
            let marker = match check.status {
                CheckStatus::Ok => "ok  ",
                CheckStatus::Warn => "warn",
                CheckStatus::Fail => "FAIL",
            };
            printer.line(format!("  [{marker}] {:<14} {}", check.name, check.detail));
        }
        printer.blank();
        if report.ready {
            printer.line("ready: yes");
        } else {
            printer.line("ready: no (fix the FAIL items above)");
        }
    }
    if report.ready {
        Ok(crate::error::EXIT_SUCCESS)
    } else {
        Ok(crate::error::EXIT_HOST)
    }
}

/// `Some(mode)` when the file exists and is readable by group/other users.
fn overly_permissive(path: &Path) -> Option<u32> {
    let mode = file_mode(path)?;
    (mode & 0o077 != 0).then_some(mode)
}

fn file_mode(path: &Path) -> Option<u32> {
    let metadata = std::fs::metadata(path).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        Some(metadata.permissions().mode() & 0o777)
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_serialises_as_snake_case() {
        let value = serde_json::to_value(CheckStatus::Fail).unwrap();
        assert_eq!(value, serde_json::json!("fail"));
    }

    #[test]
    fn report_readiness_requires_no_failures() {
        let report = DoctorReport {
            checks: vec![ok("a", "fine"), warn("b", "optional")],
            ready: true,
        };
        assert!(report.ready);
        assert!(report
            .checks
            .iter()
            .all(|check| check.status != CheckStatus::Fail));
    }

    #[test]
    fn permissive_permissions_are_detected() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(&path, "x").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = std::fs::metadata(&path).unwrap().permissions();
            permissions.set_mode(0o644);
            std::fs::set_permissions(&path, permissions.clone()).unwrap();
            assert_eq!(overly_permissive(&path), Some(0o644));
            permissions.set_mode(0o600);
            std::fs::set_permissions(&path, permissions).unwrap();
            assert_eq!(overly_permissive(&path), None);
        }
        assert_eq!(overly_permissive(&dir.path().join("missing")), None);
    }
}
