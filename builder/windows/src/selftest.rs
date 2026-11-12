//! `self-test`: a no-Mac, no-ROM check that the frontend works on this PC.
//!
//! This is the command to run first on a new Windows machine. It exercises the
//! parts that are easy to get wrong on Windows - long paths, CJK and space
//! handling, reserved names, hashing and atomic writes - plus the shared config
//! round trip. It creates and deletes only temporary files under the system temp
//! directory and the Builder's own directories.

use std::path::{Path, PathBuf};

use builder_core::config::BuilderConfig;
use serde::Serialize;

use crate::artifacts;
use crate::errors::EXIT_SUCCESS;
use crate::install_guide::{self, ArtifactGuide};
use crate::paths;
use crate::probe;
use crate::{errors::FrontendError, events::EventRenderer, preflight, FRONTEND_NAME, VERSION};

/// One self-test result.
#[derive(Debug, Clone, Serialize)]
pub struct TestResult {
    pub name: String,
    pub ok: bool,
    pub detail: String,
}

/// Aggregated self-test report.
#[derive(Debug, Clone, Serialize)]
pub struct SelfTestReport {
    pub frontend: String,
    pub version: String,
    pub os: String,
    pub arch: String,
    pub windows_build: bool,
    pub ok: bool,
    pub results: Vec<TestResult>,
}

fn check(results: &mut Vec<TestResult>, name: &str, outcome: Result<String, String>) {
    match outcome {
        Ok(detail) => results.push(TestResult {
            name: name.to_string(),
            ok: true,
            detail,
        }),
        Err(detail) => results.push(TestResult {
            name: name.to_string(),
            ok: false,
            detail,
        }),
    }
}

fn scratch_dir() -> PathBuf {
    std::env::temp_dir().join(format!("3ds2apple-builder-selftest-{}", std::process::id()))
}

fn cjk_and_space_round_trip(scratch: &Path) -> Result<String, String> {
    let directory = scratch.join("目录 with spaces");
    paths::ensure_dir(&directory).map_err(|error| format!("create directory: {error}"))?;
    let file = directory.join("宝可梦 Y (美版) 测试.txt");
    let content = "3ds2apple 自检 · CJK 路径 · spaces";
    artifacts::write_atomic(&file, content.as_bytes())
        .map_err(|error| format!("atomic write: {error}"))?;
    let read = std::fs::read_to_string(&file).map_err(|error| format!("read back: {error}"))?;
    let _ = std::fs::remove_dir_all(&directory);
    if read != content {
        return Err("content changed on the round trip".to_string());
    }
    Ok(format!(
        "wrote and read back {}",
        paths::display_path(&file)
    ))
}

#[cfg(windows)]
fn long_path_round_trip(scratch: &Path) -> Result<String, String> {
    // Build a path well past the classic 260-character limit.
    let mut directory = scratch.join("long");
    for index in 0..6 {
        directory = directory.join(format!("{index}-{}", "a".repeat(45)));
    }
    paths::ensure_dir(&directory).map_err(|error| format!("create long directory: {error}"))?;
    let file = directory.join("long path file.bin");
    let encoded = paths::extended_length_path(&file);
    std::fs::write(&encoded, b"long path ok").map_err(|error| format!("write: {error}"))?;
    let read = std::fs::read(&encoded).map_err(|error| format!("read: {error}"))?;
    let _ = std::fs::remove_dir_all(paths::extended_length_path(scratch));
    let length = paths::display_path(&file).chars().count();
    if read != b"long path ok" {
        return Err("content changed on the long-path round trip".to_string());
    }
    if length <= paths::MAX_PATH {
        return Err(format!(
            "test path was only {length} characters, expected more than {}",
            paths::MAX_PATH
        ));
    }
    Ok(format!("wrote and read back a {length}-character path"))
}

#[cfg(not(windows))]
fn long_path_round_trip(_scratch: &Path) -> Result<String, String> {
    Ok("not applicable on this platform (Windows-only check)".to_string())
}

fn config_round_trip() -> Result<String, String> {
    let directory = std::env::temp_dir().join(format!(
        "3ds2apple-builder-config-test-{}",
        std::process::id()
    ));
    paths::ensure_dir(&directory).map_err(|error| format!("create directory: {error}"))?;
    let config_path = directory.join("config.toml");
    let mut config = BuilderConfig::default();
    config.hosts.push(builder_core::config::HostProfile {
        id: "selftest".to_string(),
        name: "Self test".to_string(),
        transport: builder_core::transport::TransportSpec::Local(
            builder_core::transport::LocalSpec {
                program: PathBuf::from("builder-agent"),
                args: Vec::new(),
                env: std::collections::BTreeMap::new(),
            },
        ),
        created_at: builder_core::util::rfc3339_now(),
        last_test_at: None,
        agent_version: None,
        agent_id: None,
    });
    config
        .save(&config_path)
        .map_err(|error| format!("save config: {error}"))?;
    let loaded =
        BuilderConfig::load(&config_path).map_err(|error| format!("load config: {error}"))?;
    let _ = std::fs::remove_dir_all(&directory);
    if loaded.hosts.len() != 1 || loaded.hosts[0].id != "selftest" {
        return Err("config did not round-trip".to_string());
    }
    Ok("saved and reloaded a host profile".to_string())
}

fn hash_round_trip() -> Result<String, String> {
    let directory = std::env::temp_dir().join(format!(
        "3ds2apple-builder-hash-test-{}",
        std::process::id()
    ));
    paths::ensure_dir(&directory).map_err(|error| format!("create directory: {error}"))?;
    let file = directory.join("hash.bin");
    std::fs::write(&file, b"hello").map_err(|error| format!("write: {error}"))?;
    let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    let actual = artifacts::verify_sha256(&file, expected)
        .map_err(|error| format!("verify known hash: {error}"))?;
    let rejected = artifacts::verify_sha256(&file, "00").is_err();
    let _ = std::fs::remove_dir_all(&directory);
    if !rejected {
        return Err("a wrong checksum was accepted".to_string());
    }
    if actual != expected {
        return Err("hashing returned a different value".to_string());
    }
    Ok("known SHA256 verified; wrong hash rejected".to_string())
}

fn path_rules() -> Result<String, String> {
    let extended = paths::extended_windows_path(r"C:\Users\me\ROM\Pokemon Y.cci");
    if extended != r"\\?\C:\Users\me\ROM\Pokemon Y.cci" {
        return Err(format!("unexpected extended path: {extended}"));
    }
    let reserved = paths::check_windows_path(r"C:\tmp\CON");
    if reserved.is_empty() {
        return Err("reserved device name CON was accepted".to_string());
    }
    let cjk = paths::check_windows_path(r"C:\Users\玩家\宝可梦 Y (美版).cci");
    if !cjk.is_empty() {
        return Err(format!("CJK path was rejected: {cjk:?}"));
    }
    Ok("extended conversion, reserved names and CJK paths behave".to_string())
}

fn event_reassembly() -> Result<String, String> {
    use builder_core::protocol::model::{EventKind, JobEvent};
    let mut renderer = EventRenderer::new();
    let mut first = JobEvent {
        seq: 1,
        job_id: "job_01J8Z3K4T9ABCDEFGHJKMNPQRS".to_string(),
        ts: "2026-11-12T19:00:00Z".to_string(),
        kind: EventKind::Log,
        stage: None,
        source: None,
        level: None,
        line: Some("part one ".to_string()),
        line_part: Some(1),
        line_parts: Some(2),
        state: None,
        error: None,
        artifact: None,
        message: None,
    };
    let ignored = renderer.render(&first).is_none();
    first.seq = 2;
    first.line = Some("part two".to_string());
    first.line_part = Some(2);
    let joined = renderer.render(&first);
    match joined {
        Some(crate::events::Rendered::Log(line)) if line == "part one part two" && ignored => {
            Ok("split log lines are reassembled".to_string())
        }
        _ => Err("split log lines were not reassembled".to_string()),
    }
}

fn install_guide_check() -> Result<String, String> {
    let ipa = PathBuf::from(r"C:\out\pokemon-y-AOT.ipa");
    let sha256 = "aa".repeat(32);
    let text = install_guide::render_windows(&ArtifactGuide {
        display_name: "Pokemon Y",
        ipa_path: &ipa,
        bytes: 101_000_000,
        sha256: &sha256,
        title_id: Some("0004000000055E00"),
        source_revision: Some("4cc6186"),
        xcode: Some("16.4"),
        host_name: Some("self-test"),
    });
    for needle in ["certutil -hashfile", "sideloadly.io", "7 days"] {
        if !text.contains(needle) {
            return Err(format!("install guide is missing {needle:?}"));
        }
    }
    Ok("install guide renders the checksum and the signing steps".to_string())
}

fn disk_probe() -> Result<String, String> {
    match probe::free_space(&std::env::temp_dir()) {
        Some(bytes) => Ok(format!(
            "{} free on the temp volume",
            preflight::format_bytes(bytes)
        )),
        None => Err("the free-space probe returned no value".to_string()),
    }
}

fn directory_check() -> Result<String, String> {
    let scratch = scratch_dir();
    paths::ensure_dir(&scratch).map_err(|error| format!("create scratch: {error}"))?;
    Ok(format!("created {}", paths::display_path(&scratch)))
}

/// Run all self-tests and return the report.
pub fn collect() -> SelfTestReport {
    let mut results = Vec::new();
    check(&mut results, "directory", directory_check());
    let scratch = scratch_dir();
    check(&mut results, "long_paths", long_path_round_trip(&scratch));
    check(
        &mut results,
        "cjk_paths",
        cjk_and_space_round_trip(&scratch),
    );
    check(&mut results, "path_rules", path_rules());
    check(&mut results, "config", config_round_trip());
    check(&mut results, "sha256", hash_round_trip());
    check(&mut results, "events", event_reassembly());
    check(&mut results, "install_guide", install_guide_check());
    check(&mut results, "disk_probe", disk_probe());
    let _ = std::fs::remove_dir_all(paths::extended_length_path(&scratch));
    let ok = results.iter().all(|result| result.ok);
    SelfTestReport {
        frontend: FRONTEND_NAME.to_string(),
        version: VERSION.to_string(),
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        windows_build: paths::is_windows_build(),
        ok,
        results,
    }
}

/// Run the self-test and return the process exit code.
pub fn run(json: bool) -> i32 {
    let report = collect();
    if json {
        match serde_json::to_string_pretty(&report) {
            Ok(text) => println!("{text}"),
            Err(error) => eprintln!("builder-windows: cannot serialise the report: {error}"),
        }
    } else {
        println!("{} {}", report.frontend, report.version);
        println!(
            "platform: {} ({}) · windows build: {}",
            report.os, report.arch, report.windows_build
        );
        println!();
        for result in &report.results {
            println!(
                "[{}] {}: {}",
                if result.ok { "PASS" } else { "FAIL" },
                result.name,
                result.detail
            );
        }
        println!();
        println!("self-test: {}", if report.ok { "PASS" } else { "FAIL" });
    }
    if report.ok {
        EXIT_SUCCESS
    } else {
        1
    }
}

/// A failure carried by the self-test's own report rather than the CLI error type.
pub fn failed(results: &[TestResult]) -> Option<FrontendError> {
    results.iter().find(|result| !result.ok).map(|result| {
        FrontendError::Environment(format!(
            "self-test {} failed: {}",
            result.name, result.detail
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_self_test_passes_on_the_development_host() {
        // The self-test is designed to pass on any supported development host
        // (Linux included); it only exercises portable pieces plus the
        // platform-appropriate long-path check.
        let report = collect();
        let failures: Vec<_> = report
            .results
            .iter()
            .filter(|result| !result.ok)
            .map(|result| format!("{}: {}", result.name, result.detail))
            .collect();
        assert!(report.ok, "{failures:#?}");
        assert!(report.results.len() >= 8);
        assert!(report
            .results
            .iter()
            .any(|result| result.name == "cjk_paths"));
        assert!(report
            .results
            .iter()
            .any(|result| result.name == "long_paths"));
    }

    #[test]
    fn failures_are_reported_with_their_name() {
        let results = vec![
            TestResult {
                name: "one".into(),
                ok: true,
                detail: "fine".into(),
            },
            TestResult {
                name: "two".into(),
                ok: false,
                detail: "broken".into(),
            },
        ];
        let error = failed(&results).expect("a failure is reported");
        assert!(error.to_string().contains("two"), "{error}");
        assert!(failed(&results[..1]).is_none());
    }
}
