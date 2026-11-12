//! Toolchain, source-checkout and disk checks.
//!
//! `doctor` runs the same checks the Agent performs before starting a job, and
//! the result is also what `hello.result` advertises. Every check is
//! best-effort: a missing tool is reported as `None` and becomes a refusal code
//! rather than an Agent crash.

use std::path::Path;
use std::process::Command;

use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::model::{DoctorReport, SourceInfo, Toolchain};

use crate::config::AgentConfig;
use crate::store::DataRoot;
use crate::util;

/// Disk space the Agent wants free before it starts a real build.
pub const MIN_DISK_BYTES: u64 = 20 * 1024 * 1024 * 1024;

/// The scripts a usable checkout must contain.
pub const REQUIRED_SCRIPTS: [&str; 4] = [
    crate::stages::SCRIPT_RUNTIME,
    crate::stages::SCRIPT_RECOMP,
    crate::stages::SCRIPT_LINKED,
    crate::stages::SCRIPT_PACKAGE,
];

/// Run a program and return trimmed stdout, or `None` when it is missing/fails.
fn command_output(program: &str, args: &[&str], cwd: Option<&Path>) -> Option<String> {
    let mut command = Command::new(program);
    command.args(args);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().trim().to_string()
}

/// Detect the macOS build toolchain. Missing tools stay `None`.
pub fn detect_toolchain() -> Toolchain {
    let xcode = command_output("xcodebuild", &["-version"], None)
        .map(|text| first_line(&text))
        .map(|line| line.trim_start_matches("Xcode ").to_string())
        .filter(|value| !value.is_empty());
    let ios_sdk = command_output("xcrun", &["--sdk", "iphoneos", "--show-sdk-version"], None)
        .map(|text| first_line(&text))
        .filter(|value| !value.is_empty());
    let rust = command_output("rustc", &["--version"], None)
        .map(|text| first_line(&text))
        .and_then(|line| line.split_whitespace().nth(1).map(str::to_string));
    let rust_target_installed = command_output("rustup", &["target", "list", "--installed"], None)
        .map(|text| text.lines().any(|line| line.trim() == "aarch64-apple-ios"))
        .unwrap_or(false);
    let xcodegen = command_output("xcodegen", &["--version"], None).map(|text| {
        let line = first_line(&text);
        line.split_whitespace()
            .last()
            .unwrap_or(line.as_str())
            .trim_start_matches('v')
            .to_string()
    });
    let python = command_output("python3", &["--version"], None)
        .map(|text| first_line(&text))
        .map(|line| line.trim_start_matches("Python ").to_string());
    let git = command_output("git", &["--version"], None)
        .map(|text| first_line(&text))
        .map(|line| line.trim_start_matches("git version ").to_string());
    Toolchain {
        xcode,
        ios_sdk,
        rust,
        rust_target_installed,
        xcodegen,
        python,
        git,
    }
}

/// Whether a checkout contains the build scripts.
pub fn scripts_present(checkout: &Path) -> bool {
    REQUIRED_SCRIPTS
        .iter()
        .all(|script| checkout.join(script).is_file())
}

/// Source revision/dirty state of the checkout.
pub fn detect_source(checkout: Option<&Path>) -> SourceInfo {
    let Some(checkout) = checkout else {
        return SourceInfo::default();
    };
    let repo = Some(checkout.display().to_string());
    let revision = command_output("git", &["rev-parse", "HEAD"], Some(checkout));
    let dirty = command_output("git", &["status", "--porcelain"], Some(checkout))
        .map(|text| !text.trim().is_empty())
        .unwrap_or(false);
    SourceInfo {
        repo,
        revision,
        dirty,
        scripts_present: scripts_present(checkout),
    }
}

/// Free disk space at the Agent data root.
pub fn free_disk_bytes(data: &DataRoot) -> Option<u64> {
    crate::nix_util::free_disk_bytes(&data.root)
}

/// Compute readiness and refusal codes from the collected facts.
pub fn readiness(
    cfg: &AgentConfig,
    toolchain: &Toolchain,
    source: &SourceInfo,
    disk_free: Option<u64>,
) -> (bool, Vec<String>) {
    let mut refusals = Vec::new();
    if util::is_root() {
        refusals.push(ErrorCode::Forbidden.as_str().to_string());
    }
    if cfg.fake_build {
        // The scripted fake build only exercises the protocol; no Mac toolchain
        // or checkout is needed.
        return (refusals.is_empty(), refusals);
    }
    let toolchain_ok = toolchain.xcode.is_some()
        && toolchain.ios_sdk.is_some()
        && toolchain.rust.is_some()
        && toolchain.rust_target_installed
        && toolchain.xcodegen.is_some()
        && toolchain.python.is_some()
        && toolchain.git.is_some();
    if !toolchain_ok {
        refusals.push(ErrorCode::ToolchainMissing.as_str().to_string());
    }
    if source.revision.is_none() || !source.scripts_present || cfg.checkout.is_none() {
        refusals.push(ErrorCode::RepoMissing.as_str().to_string());
    }
    if source.dirty && !cfg.allow_dirty {
        refusals.push(ErrorCode::RepoDirty.as_str().to_string());
    }
    if let Some(free) = disk_free {
        if free < MIN_DISK_BYTES {
            refusals.push(ErrorCode::InsufficientStorage.as_str().to_string());
        }
    }
    (refusals.is_empty(), refusals)
}

/// Full doctor report (also printed by `builder-agent doctor --json`).
pub fn gather(cfg: &AgentConfig, data: &DataRoot) -> DoctorReport {
    let toolchain = detect_toolchain();
    let source = detect_source(cfg.checkout.as_deref());
    let disk_free = free_disk_bytes(data);
    let (ready, refusals) = readiness(cfg, &toolchain, &source, disk_free);
    let mut notes = Vec::new();
    if cfg.fake_build {
        notes.push(format!(
            "fake build mode is enabled (plan: {}); no Mac toolchain is required",
            cfg.fake_plan
        ));
    }
    if cfg.moltenvk_framework.is_none() {
        notes.push(
            "MoltenVK framework is not configured; packaging may skip embedding it".to_string(),
        );
    }
    DoctorReport {
        agent_version: builder_core::VERSION.to_string(),
        protocol: builder_core::PROTOCOL.to_string(),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        user: util::username(),
        is_root: util::is_root(),
        hostname: Some(util::hostname()),
        data_root: data.root.display().to_string(),
        checkout: cfg.checkout.as_ref().map(|path| path.display().to_string()),
        source,
        toolchain,
        disk_free_bytes: disk_free,
        disk_required_bytes: MIN_DISK_BYTES,
        limits: cfg.limits(),
        ready,
        refusals,
        notes,
        generated_at: util::now(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fake_config() -> AgentConfig {
        AgentConfig {
            fake_build: true,
            checkout: None,
            ..AgentConfig::default()
        }
    }

    #[test]
    fn fake_mode_is_ready_without_macos() {
        let toolchain = detect_toolchain();
        let source = SourceInfo::default();
        let (ready, refusals) = readiness(&fake_config(), &toolchain, &source, Some(u64::MAX));
        assert!(ready, "fake build mode should be ready: {refusals:?}");
        assert!(refusals.is_empty());
    }

    #[test]
    fn real_mode_refuses_without_toolchain_and_repo() {
        let cfg = AgentConfig {
            fake_build: false,
            checkout: None,
            ..AgentConfig::default()
        };
        let toolchain = Toolchain::default();
        let source = SourceInfo::default();
        let (ready, refusals) = readiness(&cfg, &toolchain, &source, Some(MIN_DISK_BYTES));
        assert!(!ready);
        assert!(refusals.contains(&"toolchain_missing".to_string()));
        assert!(refusals.contains(&"repo_missing".to_string()));
    }

    #[test]
    fn dirty_repo_is_refused_unless_allowed() {
        let cfg = AgentConfig {
            fake_build: false,
            checkout: Some(PathBuf::from("/repo")),
            ..AgentConfig::default()
        };
        let toolchain = Toolchain {
            xcode: Some("16.4".into()),
            ios_sdk: Some("18.5".into()),
            rust: Some("1.99.1".into()),
            rust_target_installed: true,
            xcodegen: Some("2.44.1".into()),
            python: Some("3.11.9".into()),
            git: Some("2.46.0".into()),
        };
        let source = SourceInfo {
            repo: Some("/repo".into()),
            revision: Some("abc".into()),
            dirty: true,
            scripts_present: true,
        };
        let (ready, refusals) = readiness(&cfg, &toolchain, &source, Some(MIN_DISK_BYTES));
        assert!(!ready);
        assert!(refusals.contains(&"repo_dirty".to_string()));
        let mut allowed = cfg.clone();
        allowed.allow_dirty = true;
        let (ready, _) = readiness(&allowed, &toolchain, &source, Some(MIN_DISK_BYTES));
        assert!(ready);
    }

    #[test]
    fn low_disk_is_refused() {
        let cfg = fake_config();
        let toolchain = Toolchain::default();
        let source = SourceInfo::default();
        let (_, refusals) = readiness(&cfg, &toolchain, &source, Some(1024));
        // Fake mode short-circuits before the disk check by design; real mode
        // checks disk. Cover the real-mode path here.
        assert!(refusals.is_empty());
        let real = AgentConfig {
            fake_build: false,
            checkout: None,
            ..AgentConfig::default()
        };
        let (_, refusals) = readiness(&real, &toolchain, &source, Some(1024));
        assert!(refusals.contains(&"insufficient_storage".to_string()));
    }

    #[test]
    fn scripts_presence_check() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!scripts_present(dir.path()));
        for script in REQUIRED_SCRIPTS {
            let path = dir.path().join(script);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, b"#!/bin/sh\n").unwrap();
        }
        assert!(scripts_present(dir.path()));
    }

    #[test]
    fn doctor_report_is_serialisable() {
        let dir = tempfile::tempdir().unwrap();
        let data = DataRoot::new(dir.path().to_path_buf());
        data.ensure_layout().unwrap();
        let report = gather(&fake_config(), &data);
        assert!(!report.agent_version.is_empty());
        assert_eq!(report.protocol, builder_core::PROTOCOL);
        assert!(report
            .notes
            .iter()
            .any(|note| note.contains("fake build mode")));
        let json = serde_json::to_string(&report).unwrap();
        let back: DoctorReport = serde_json::from_str(&json).unwrap();
        assert_eq!(back.data_root, report.data_root);
    }
}
