//! `doctor`: check this Windows PC and, optionally, the configured Mac.
//!
//! The local report covers what actually differs on Windows: the OpenSSH client
//! (an optional Windows feature), the console code page (CJK output), long-path
//! settings, free space, and whether the config/artifact directories are
//! writable. WebView2 is reported for completeness but is only needed by a
//! graphical build, not by this CLI-first frontend.

use std::path::{Path, PathBuf};

use builder_core::config::BuilderConfig;
use serde::Serialize;

use crate::errors::{FrontendError, EXIT_HOST, EXIT_SUCCESS};
use crate::hosts::{self, HostTestReport};
use crate::paths;
use crate::preflight::format_bytes;
use crate::probe;
use crate::{FRONTEND_NAME, RECOMMENDED_FREE_BYTES, VERSION};

/// Result of one environment check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckStatus {
    Ok,
    Warning,
    Fail,
    Info,
}

impl CheckStatus {
    pub fn label(self) -> &'static str {
        match self {
            CheckStatus::Ok => "ok",
            CheckStatus::Warning => "warning",
            CheckStatus::Fail => "fail",
            CheckStatus::Info => "info",
        }
    }
}

/// One named check with its outcome and an optional fix.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Check {
    pub name: String,
    pub status: CheckStatus,
    pub detail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

/// Local environment facts, gathered once and evaluated separately so the
/// evaluation rules are testable without a Windows machine.
#[derive(Debug, Clone)]
pub struct Facts {
    pub windows_build: bool,
    pub os: String,
    pub arch: String,
    pub windows_version: Option<String>,
    pub ssh_program: Option<PathBuf>,
    pub ssh_version: Option<String>,
    pub ssh_keygen: Option<PathBuf>,
    pub ssh_keyscan: Option<PathBuf>,
    pub webview2: Option<String>,
    pub console_code_page: Option<u32>,
    pub long_paths_enabled: Option<bool>,
    pub config_path: PathBuf,
    pub config_writable: bool,
    pub artifacts_dir: PathBuf,
    pub artifacts_writable: bool,
    pub free_bytes: Option<u64>,
}

/// Gather the local facts used by the report.
pub fn gather(config_path: &Path) -> Facts {
    let ssh = probe::ssh_probe();
    let artifacts_dir = paths::artifacts_dir();
    Facts {
        windows_build: paths::is_windows_build(),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        windows_version: probe::windows_version(),
        ssh_program: ssh.program,
        ssh_version: ssh.version,
        ssh_keygen: probe::pairing_tool("ssh-keygen"),
        ssh_keyscan: probe::pairing_tool("ssh-keyscan"),
        webview2: probe::webview2_runtime(),
        console_code_page: probe::console_code_page(),
        long_paths_enabled: probe::long_paths_enabled(),
        config_path: config_path.to_path_buf(),
        config_writable: directory_writable(config_path.parent().unwrap_or(Path::new("."))),
        artifacts_dir: artifacts_dir.clone(),
        artifacts_writable: directory_writable(&artifacts_dir),
        free_bytes: probe::free_space(&artifacts_dir),
    }
}

fn directory_writable(directory: &Path) -> bool {
    if paths::ensure_dir(directory).is_err() {
        return false;
    }
    let probe_path = directory.join(".builder-permission-test");
    let ok = std::fs::write(paths::extended_length_path(&probe_path), b"ok").is_ok();
    let _ = std::fs::remove_file(paths::extended_length_path(&probe_path));
    ok
}

/// Evaluate the rules over the gathered facts.
pub fn evaluate(facts: &Facts) -> Vec<Check> {
    let mut checks = Vec::new();

    let platform_detail = if let Some(version) = &facts.windows_version {
        format!("Windows ({}), {}", version, facts.arch)
    } else {
        format!("{} ({})", facts.os, facts.arch)
    };
    checks.push(if facts.windows_build {
        Check {
            name: "platform".into(),
            status: CheckStatus::Ok,
            detail: platform_detail,
            fix: None,
        }
    } else {
        Check {
            name: "platform".into(),
            status: CheckStatus::Warning,
            detail: format!("{platform_detail}; this is a development build, release builds target Windows 10/11"),
            fix: Some("run the Windows build of the Builder for the supported setup".into()),
        }
    });

    match (&facts.ssh_program, &facts.ssh_version) {
        (Some(program), Some(version)) => checks.push(Check {
            name: "openssh".into(),
            status: CheckStatus::Ok,
            detail: format!("OpenSSH {version} ({})", paths::display_path(program)),
            fix: None,
        }),
        (Some(program), None) => checks.push(Check {
            name: "openssh".into(),
            status: CheckStatus::Warning,
            detail: format!(
                "found {} but could not read its version",
                paths::display_path(program)
            ),
            fix: Some("run `ssh -V` in a terminal to check the OpenSSH installation".into()),
        }),
        _ => checks.push(Check {
            name: "openssh".into(),
            status: CheckStatus::Fail,
            detail: "the OpenSSH client (`ssh`) is not installed".into(),
            fix: Some(
                "install it as an administrator: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` (Settings > Apps > Optional features > OpenSSH Client)".into(),
            ),
        }),
    }

    let missing: Vec<&str> = [
        ("ssh-keygen", &facts.ssh_keygen),
        ("ssh-keyscan", &facts.ssh_keyscan),
    ]
    .iter()
    .filter(|(_, program)| program.is_none())
    .map(|(name, _)| *name)
    .collect();
    checks.push(if missing.is_empty() {
        Check {
            name: "ssh_pairing_tools".into(),
            status: CheckStatus::Ok,
            detail: "ssh-keygen and ssh-keyscan are available".into(),
            fix: None,
        }
    } else {
        Check {
            name: "ssh_pairing_tools".into(),
            status: CheckStatus::Fail,
            detail: format!("missing: {}", missing.join(", ")),
            fix: Some(
                "the OpenSSH Client optional feature includes ssh-keygen and ssh-keyscan; install it as an administrator".into(),
            ),
        }
    });

    checks.push(if facts.config_writable {
        Check {
            name: "config_write".into(),
            status: CheckStatus::Ok,
            detail: format!("writable: {}", paths::display_path(&facts.config_path)),
            fix: None,
        }
    } else {
        Check {
            name: "config_write".into(),
            status: CheckStatus::Fail,
            detail: format!(
                "cannot write the configuration file {}",
                paths::display_path(&facts.config_path)
            ),
            fix: Some(
                "check the folder permissions or pass --config to a writable location".into(),
            ),
        }
    });

    checks.push(if facts.artifacts_writable {
        Check {
            name: "artifacts_write".into(),
            status: CheckStatus::Ok,
            detail: format!(
                "writable: {}",
                paths::display_path(&facts.artifacts_dir)
            ),
            fix: None,
        }
    } else {
        Check {
            name: "artifacts_write".into(),
            status: CheckStatus::Fail,
            detail: format!(
                "cannot write downloaded IPAs to {}",
                paths::display_path(&facts.artifacts_dir)
            ),
            fix: Some("free space or permissions on the artifacts directory; --out can be used to write elsewhere".into()),
        }
    });

    let disk = crate::preflight::disk_status(facts.free_bytes);
    let (status, detail, fix) = match disk {
        crate::preflight::DiskStatus::Ok => (
            CheckStatus::Ok,
            format!(
                "{} free for downloaded IPAs",
                format_bytes(facts.free_bytes.unwrap_or(0))
            ),
            None,
        ),
        crate::preflight::DiskStatus::Limited => (
            CheckStatus::Warning,
            format!(
                "{} free; {} recommended",
                format_bytes(facts.free_bytes.unwrap_or(0)),
                format_bytes(RECOMMENDED_FREE_BYTES)
            ),
            Some("free some space before downloading a large IPA".to_string()),
        ),
        crate::preflight::DiskStatus::Insufficient => (
            CheckStatus::Fail,
            format!("only {} free", format_bytes(facts.free_bytes.unwrap_or(0))),
            Some("free at least a few hundred MiB before downloading an IPA".to_string()),
        ),
        crate::preflight::DiskStatus::Unknown => (
            CheckStatus::Info,
            "the platform could not report free space".to_string(),
            None,
        ),
    };
    checks.push(Check {
        name: "disk_space".into(),
        status,
        detail,
        fix,
    });

    if facts.windows_build {
        let (status, detail, fix) = match facts.long_paths_enabled {
            Some(true) => (
                CheckStatus::Ok,
                "system-wide long path support is enabled".to_string(),
                None,
            ),
            Some(false) => (
                CheckStatus::Warning,
                "system-wide long path support is disabled (the Builder itself uses extended-length paths)"
                    .to_string(),
                Some(
                    "optional: as an administrator set HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem\\LongPathsEnabled=1"
                        .to_string(),
                ),
            ),
            None => (
                CheckStatus::Info,
                "could not read the long-path registry setting; the Builder uses extended-length paths regardless"
                    .to_string(),
                None,
            ),
        };
        checks.push(Check {
            name: "long_paths".into(),
            status,
            detail,
            fix,
        });
    }

    if facts.windows_build {
        let (status, detail, fix) = match facts.console_code_page {
            Some(65001) => (
                CheckStatus::Ok,
                "the console code page is UTF-8 (65001)".to_string(),
                None,
            ),
            Some(code_page) => (
                CheckStatus::Warning,
                format!(
                    "the console code page is {code_page}; CJK names and log lines may look garbled"
                ),
                Some(
                    "run `chcp 65001` before starting the Builder, or use Windows Terminal"
                        .to_string(),
                ),
            ),
            None => (
                CheckStatus::Info,
                "could not detect the console code page".to_string(),
                None,
            ),
        };
        checks.push(Check {
            name: "console_encoding".into(),
            status,
            detail,
            fix,
        });
    }

    let (status, detail) = match &facts.webview2 {
        Some(version) => (
            CheckStatus::Ok,
            format!("WebView2 runtime {version} detected (only a graphical build needs it)"),
        ),
        None => (
            CheckStatus::Info,
            "WebView2 runtime not detected; the CLI frontend does not need it".to_string(),
        ),
    };
    checks.push(Check {
        name: "webview2".into(),
        status,
        detail,
        fix: None,
    });

    checks.push(Check {
        name: "protocol".into(),
        status: CheckStatus::Info,
        detail: format!(
            "{} {} · protocol {} · core {}",
            FRONTEND_NAME,
            VERSION,
            builder_core::PROTOCOL,
            builder_core::VERSION
        ),
        fix: None,
    });

    checks
}

/// Full local report.
#[derive(Debug, Clone, Serialize)]
pub struct DoctorReport {
    pub frontend: String,
    pub version: String,
    pub os: String,
    pub arch: String,
    pub windows_build: bool,
    pub ready: bool,
    pub checks: Vec<Check>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote: Option<RemoteReport>,
}

/// Remote Agent facts included when `doctor --host` is used.
#[derive(Debug, Clone, Serialize)]
pub struct RemoteReport {
    pub host: String,
    pub endpoint: String,
    pub agent_version: String,
    pub agent_os: String,
    pub agent_arch: String,
    pub protocol: String,
    pub toolchain: String,
    pub source_revision: Option<String>,
    pub source_dirty: bool,
    pub ready: bool,
    pub refusals: Vec<String>,
}

impl From<&HostTestReport> for RemoteReport {
    fn from(report: &HostTestReport) -> Self {
        Self {
            host: report.host_name.clone(),
            endpoint: report.endpoint.clone(),
            agent_version: report.agent_version.clone(),
            agent_os: report.agent_os.clone(),
            agent_arch: report.agent_arch.clone(),
            protocol: report.protocol.clone(),
            toolchain: report.toolchain.clone(),
            source_revision: report.source_revision.clone(),
            source_dirty: report.source_dirty,
            ready: report.ready,
            refusals: report.refusals.clone(),
        }
    }
}

/// Run the local checks, optionally checking a host as well.
pub fn run(
    config: &mut BuilderConfig,
    config_path: &Path,
    host: Option<&str>,
    json: bool,
) -> Result<i32, FrontendError> {
    let facts = gather(config_path);
    let checks = evaluate(&facts);
    let local_ready = !checks.iter().any(|check| check.status == CheckStatus::Fail);
    let remote = match host {
        Some(host) => Some(RemoteReport::from(&hosts::test_host(
            config,
            config_path,
            host,
        )?)),
        None => None,
    };
    let remote_ready = remote.as_ref().map(|report| report.ready).unwrap_or(true);
    let report = DoctorReport {
        frontend: FRONTEND_NAME.to_string(),
        version: VERSION.to_string(),
        os: facts.os.clone(),
        arch: facts.arch.clone(),
        windows_build: facts.windows_build,
        ready: local_ready && remote_ready,
        checks,
        remote,
    };
    if json {
        let text = serde_json::to_string_pretty(&report).map_err(|error| {
            FrontendError::local(format!("cannot serialise the report: {error}"))
        })?;
        println!("{text}");
    } else {
        for line in render(&report) {
            println!("{line}");
        }
    }
    if report.ready {
        Ok(EXIT_SUCCESS)
    } else {
        Ok(EXIT_HOST)
    }
}

/// Human lines for the report.
pub fn render(report: &DoctorReport) -> Vec<String> {
    let mut lines = vec![
        format!("{} {}", report.frontend, report.version),
        format!("platform: {} ({})", report.os, report.arch),
        format!("protocol: {}", builder_core::PROTOCOL),
        String::new(),
    ];
    for check in &report.checks {
        lines.push(format!(
            "[{:<7}] {}: {}",
            check.status.label(),
            check.name,
            check.detail
        ));
        if let Some(fix) = &check.fix {
            lines.push(format!("          fix: {fix}"));
        }
    }
    lines.push(String::new());
    if let Some(remote) = &report.remote {
        lines.push(format!(
            "remote host: {} ({})",
            remote.host, remote.endpoint
        ));
        lines.push(format!(
            "  agent: builder-agent {} ({} {})",
            remote.agent_version, remote.agent_os, remote.agent_arch
        ));
        lines.push(format!("  toolchain: {}", remote.toolchain));
        lines.push(format!(
            "  source: revision {} ({})",
            remote.source_revision.as_deref().unwrap_or("unknown"),
            if remote.source_dirty {
                "dirty"
            } else {
                "clean"
            }
        ));
        if remote.ready {
            lines.push("  ready: yes".to_string());
        } else {
            lines.push(format!("  ready: no ({})", remote.refusals.join(", ")));
            for refusal in &remote.refusals {
                lines.push(format!("  fix: {}", crate::errors::refusal_hint(refusal)));
            }
        }
        lines.push(String::new());
    }
    lines.push(if report.ready {
        "ready: yes".to_string()
    } else {
        "ready: no".to_string()
    });
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts() -> Facts {
        Facts {
            windows_build: true,
            os: "windows".into(),
            arch: "x86_64".into(),
            windows_version: Some("Microsoft Windows [Version 10.0.26200.9711]".into()),
            ssh_program: Some(PathBuf::from(r"C:\Windows\System32\OpenSSH\ssh.exe")),
            ssh_version: Some("9.5p1".into()),
            ssh_keygen: Some(PathBuf::from(r"C:\Windows\System32\OpenSSH\ssh-keygen.exe")),
            ssh_keyscan: Some(PathBuf::from(
                r"C:\Windows\System32\OpenSSH\ssh-keyscan.exe",
            )),
            webview2: Some("157.0.4341.46".into()),
            console_code_page: Some(65001),
            long_paths_enabled: Some(false),
            config_path: PathBuf::from(
                r"C:\Users\me\AppData\Roaming\3ds2apple\builder\config.toml",
            ),
            config_writable: true,
            artifacts_dir: PathBuf::from(r"C:\Users\me\AppData\Local\3ds2apple\builder\artifacts"),
            artifacts_writable: true,
            free_bytes: Some(50 * 1024 * 1024 * 1024),
        }
    }

    fn status_of<'a>(checks: &'a [Check], name: &str) -> &'a Check {
        checks
            .iter()
            .find(|check| check.name == name)
            .unwrap_or_else(|| panic!("no check named {name}"))
    }

    #[test]
    fn a_healthy_windows_pc_is_ready() {
        let checks = evaluate(&facts());
        assert!(checks.iter().all(|check| check.status != CheckStatus::Fail));
        assert_eq!(status_of(&checks, "platform").status, CheckStatus::Ok);
        assert_eq!(status_of(&checks, "openssh").status, CheckStatus::Ok);
        assert_eq!(
            status_of(&checks, "console_encoding").status,
            CheckStatus::Ok
        );
        assert_eq!(
            status_of(&checks, "long_paths").status,
            CheckStatus::Warning
        );
        assert_eq!(status_of(&checks, "webview2").status, CheckStatus::Ok);
    }

    #[test]
    fn missing_openssh_is_a_failure_with_an_install_command() {
        let mut facts = facts();
        facts.ssh_program = None;
        facts.ssh_version = None;
        facts.ssh_keygen = None;
        facts.ssh_keyscan = None;
        let checks = evaluate(&facts);
        let ssh = status_of(&checks, "openssh");
        assert_eq!(ssh.status, CheckStatus::Fail);
        assert!(ssh
            .fix
            .as_deref()
            .unwrap_or("")
            .contains("Add-WindowsCapability"));
        assert_eq!(
            status_of(&checks, "ssh_pairing_tools").status,
            CheckStatus::Fail
        );
    }

    #[test]
    fn a_cjk_code_page_gets_a_warning_with_the_chcp_fix() {
        let mut facts = facts();
        facts.console_code_page = Some(936);
        let checks = evaluate(&facts);
        let encoding = status_of(&checks, "console_encoding");
        assert_eq!(encoding.status, CheckStatus::Warning);
        assert!(encoding.fix.as_deref().unwrap_or("").contains("chcp 65001"));
    }

    #[test]
    fn low_disk_space_is_a_failure() {
        let mut facts = facts();
        facts.free_bytes = Some(1024);
        let checks = evaluate(&facts);
        assert_eq!(status_of(&checks, "disk_space").status, CheckStatus::Fail);
        facts.free_bytes = None;
        let checks = evaluate(&facts);
        assert_eq!(status_of(&checks, "disk_space").status, CheckStatus::Info);
    }

    #[test]
    fn an_unwritable_config_directory_is_a_failure() {
        let mut facts = facts();
        facts.config_writable = false;
        facts.artifacts_writable = false;
        let checks = evaluate(&facts);
        assert_eq!(status_of(&checks, "config_write").status, CheckStatus::Fail);
        assert_eq!(
            status_of(&checks, "artifacts_write").status,
            CheckStatus::Fail
        );
    }

    #[test]
    fn the_report_renders_checks_fixes_and_remote_facts() {
        let report = DoctorReport {
            frontend: FRONTEND_NAME.to_string(),
            version: VERSION.to_string(),
            os: "windows".into(),
            arch: "x86_64".into(),
            windows_build: true,
            ready: false,
            checks: evaluate(&facts()),
            remote: Some(RemoteReport {
                host: "office".into(),
                endpoint: "ssh builder@mac:22".into(),
                agent_version: "0.1.0".into(),
                agent_os: "macos".into(),
                agent_arch: "aarch64".into(),
                protocol: builder_core::PROTOCOL.into(),
                toolchain: "Xcode 16.4".into(),
                source_revision: Some("4cc6186".into()),
                source_dirty: false,
                ready: false,
                refusals: vec!["repo_dirty".into()],
            }),
        };
        let text = render(&report).join("\n");
        assert!(text.contains("[ok     ] openssh: OpenSSH 9.5p1"), "{text}");
        assert!(text.contains("remote host: office"), "{text}");
        assert!(text.contains("ready: no (repo_dirty)"), "{text}");
        assert!(text.contains("fix: on the Mac: commit or stash"), "{text}");
        assert!(text.contains("ready: no"), "{text}");
    }

    #[test]
    fn a_linux_development_build_is_a_warning_not_a_failure() {
        let mut facts = facts();
        facts.windows_build = false;
        facts.windows_version = None;
        facts.os = "linux".into();
        let checks = evaluate(&facts);
        assert_eq!(status_of(&checks, "platform").status, CheckStatus::Warning);
        // Windows-only checks are not emitted on other platforms.
        assert!(!checks.iter().any(|check| check.name == "long_paths"));
        assert!(!checks.iter().any(|check| check.name == "console_encoding"));
        assert!(checks.iter().all(|check| check.status != CheckStatus::Fail));
        assert!(checks.iter().any(|check| check.name == "protocol"));
    }
}
