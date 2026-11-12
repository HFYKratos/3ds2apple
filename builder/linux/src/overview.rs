//! `status` / no subcommand: the first screen.
//!
//! A short, honest overview: is the shared client present, which hosts are
//! paired, is a local VM forwarding an SSH port, and what the next command is.
//! It is informational and always exits 0 (`doctor` is the pass/fail check).

use std::path::Path;

use builder_core::config::BuilderConfig;
use serde::Serialize;

use crate::error::Error;
use crate::output::Printer;
use crate::vm::{self, DiscoverOptions};
use crate::zkb::{self, Zkb};

/// One configured host, in display form.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HostSummary {
    pub id: String,
    pub name: String,
    pub transport: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_test_at: Option<String>,
}

/// A located shared client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ZkbStatus {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

/// Machine-readable overview.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StatusReport {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zkb: Option<ZkbStatus>,
    pub config_path: String,
    pub hosts: Vec<HostSummary>,
    pub vm_candidates: Vec<String>,
    pub notes: Vec<String>,
    pub next_steps: Vec<String>,
}

/// Build and print the status screen.
pub fn run<F>(
    config_path: &Path,
    explicit_zkb: Option<&Path>,
    current_exe: &Path,
    env_get: F,
    printer: Printer,
) -> Result<i32, Error>
where
    F: Fn(&str) -> Option<String>,
{
    let located_zkb = Zkb::locate(
        explicit_zkb,
        std::env::var_os(zkb::ENV_ZKB_BIN),
        current_exe,
    );
    let zkb = match located_zkb {
        Ok(ref zkb) => Some(ZkbStatus {
            path: zkb.path().display().to_string(),
            version: zkb.version(),
        }),
        Err(_) => None,
    };

    let mut notes = Vec::new();
    let hosts = match BuilderConfig::load(config_path) {
        Ok(config) => config
            .hosts
            .iter()
            .map(|host| HostSummary {
                id: host.id.clone(),
                name: host.name.clone(),
                transport: host.transport.describe(),
                agent_version: host.agent_version.clone(),
                last_test_at: host.last_test_at.clone(),
            })
            .collect::<Vec<_>>(),
        Err(message) => {
            notes.push(format!("the Builder config cannot be read: {message}"));
            Vec::new()
        }
    };

    let discovery = vm::discover(
        &DiscoverOptions {
            scan_ports: false,
            probe: false,
            ports: Vec::new(),
            timeout: std::time::Duration::from_millis(0),
        },
        &env_get,
        Path::new("/proc"),
    );
    notes.extend(discovery.notes.iter().cloned());
    let vm_candidates = discovery
        .endpoints
        .iter()
        .map(|endpoint| format!("{} ({})", endpoint.label(), endpoint.source.label()))
        .collect::<Vec<_>>();

    let next_steps = next_steps(&hosts, zkb.is_some());
    let report = StatusReport {
        zkb,
        config_path: config_path.display().to_string(),
        hosts,
        vm_candidates,
        notes,
        next_steps,
    };
    if printer.json {
        printer.json(&report);
    } else {
        print_human(&report, printer);
    }
    Ok(crate::error::EXIT_SUCCESS)
}

fn next_steps(hosts: &[HostSummary], zkb_present: bool) -> Vec<String> {
    let mut steps = Vec::new();
    if !zkb_present {
        steps.push(
            "Install the shared client: cargo build --release -p builder-cli, then put `zkb` \
             on PATH (or pass --zkb <path>)."
                .to_string(),
        );
    }
    match hosts.first() {
        None => {
            steps.push(
                "Pair your macOS VM or Mac: 3ds2apple-builder vm setup --name cachyos-vm"
                    .to_string(),
            );
            steps.push("Check the setup: 3ds2apple-builder doctor".to_string());
            steps.push(
                "Build: 3ds2apple-builder build --host cachyos-vm --rom 'ROM/<game>.cci'"
                    .to_string(),
            );
        }
        Some(host) => {
            steps.push(format!(
                "Check the host: 3ds2apple-builder doctor --host {}",
                host.id
            ));
            steps.push(format!(
                "Build: 3ds2apple-builder build --host {} --rom 'ROM/<game>.cci'",
                host.id
            ));
            steps.push(
                "Sign/install guide: 3ds2apple-builder install-guide --ipa <downloaded.ipa>"
                    .to_string(),
            );
        }
    }
    steps.push("Advanced/passthrough commands: 3ds2apple-builder zkb --help".to_string());
    steps
}

fn print_human(report: &StatusReport, printer: Printer) {
    printer.line("3ds2apple Builder (Linux)");
    printer.line("Build your own ROM into an unsigned IPA on a macOS VM or Mac you control.");
    printer.blank();
    match &report.zkb {
        Some(zkb) => printer.line(format!(
            "shared client: {} ({})",
            zkb.version.as_deref().unwrap_or("zkb, version unknown"),
            zkb.path
        )),
        None => printer.line("shared client: NOT FOUND (see the next steps below)"),
    }
    printer.line(format!("config:        {}", report.config_path));
    if report.hosts.is_empty() {
        printer.line("hosts:         none configured");
    } else {
        printer.line("hosts:");
        for host in &report.hosts {
            let status = match (&host.agent_version, &host.last_test_at) {
                (Some(version), Some(at)) => format!("builder-agent {version} (tested {at})"),
                (Some(version), None) => format!("builder-agent {version}"),
                _ => "not tested yet".to_string(),
            };
            printer.line(format!("  {:<16} {:<34} {status}", host.id, host.transport));
        }
    }
    if report.vm_candidates.is_empty() {
        printer.line("macOS VM:      no forwarded SSH port detected (optional)");
    } else {
        printer.line(format!(
            "macOS VM:      {}",
            report.vm_candidates.join(", ")
        ));
    }
    if !report.notes.is_empty() {
        printer.blank();
        for note in &report.notes {
            printer.progress(format!("note: {note}"));
        }
    }
    printer.blank();
    printer.line("Next steps:");
    for (index, step) in report.next_steps.iter().enumerate() {
        printer.line(format!("  {}. {step}", index + 1));
    }
    printer.blank();
    printer.line("Only use decrypted ROMs you own. The ROM goes only to your macOS host and is");
    printer.line("deleted there when the build ends. This tool never asks for an Apple ID and");
    printer.line("never signs anything: the IPA is unsigned and must not be redistributed.");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(id: &str) -> HostSummary {
        HostSummary {
            id: id.to_string(),
            name: format!("{id} name"),
            transport: "ssh builder@127.0.0.1:2222".to_string(),
            agent_version: None,
            last_test_at: None,
        }
    }

    #[test]
    fn next_steps_change_when_a_host_exists() {
        let without = next_steps(&[], true);
        assert!(without.iter().any(|step| step.contains("vm setup")));
        assert!(without.iter().any(|step| step.contains("doctor")));
        assert!(!without.iter().any(|step| step.contains("doctor --host")));

        let with = next_steps(&[host("cachyos-vm")], true);
        assert!(with
            .iter()
            .any(|step| step.contains("doctor --host cachyos-vm")));
        assert!(with
            .iter()
            .any(|step| step.contains("build --host cachyos-vm")));
        assert!(with.iter().any(|step| step.contains("install-guide")));
    }

    #[test]
    fn missing_zkb_is_reported_first() {
        let steps = next_steps(&[], false);
        assert!(steps[0].contains("Install the shared client"));
        let json = serde_json::to_value(StatusReport {
            zkb: None,
            config_path: "/tmp/config.toml".to_string(),
            hosts: vec![host("vm")],
            vm_candidates: vec!["builder@127.0.0.1:2222 (qemu hostfwd)".to_string()],
            notes: vec![],
            next_steps: steps,
        })
        .unwrap();
        assert_eq!(json["hosts"][0]["id"], "vm");
    }
}
