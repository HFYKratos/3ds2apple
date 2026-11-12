//! End-to-end tests for the Windows frontend binary.
//!
//! These run on any Unix development host (Linux, macOS, WSL) exactly like the
//! `zkb` CLI tests: the real macOS Build Agent binary runs in its `--fake-build`
//! mode behind the production `ssh-dispatch` local transport, and the real
//! `builder-windows` binary drives it through the shared core. That covers the
//! protocol path, upload, event streaming, artifact download and checksum
//! verification, cancellation and cleanup without a Mac or a ROM.
//!
//! The Windows-only branches (extended-length paths, console code page, WebView2,
//! Explorer integration) cannot run here; they are covered by `self-test` and by
//! running the Windows binary on Windows (see `builder/windows/README.md`).
//!
//! Run with `cargo test --workspace` so the Agent binary is built as well.
#![cfg(unix)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

use builder_core::protocol::model::ArtifactRecord;
use tempfile::TempDir;

/// Locate the sibling `builder-agent` binary that cargo built for the workspace.
fn agent_binary() -> Option<PathBuf> {
    let frontend = PathBuf::from(env!("CARGO_BIN_EXE_builder-windows"));
    let directory = frontend.parent()?.to_path_buf();
    let agent = directory.join("builder-agent");
    agent.is_file().then_some(agent)
}

struct Harness {
    _dir: TempDir,
    config: PathBuf,
    agent_data: PathBuf,
    agent: Child,
    frontend: PathBuf,
}

impl Harness {
    fn new(fake_plan: &str) -> Option<Self> {
        let Some(agent_bin) = agent_binary() else {
            eprintln!(
                "skipping: builder-agent is not built next to the test binary; run `cargo test --workspace`"
            );
            return None;
        };
        let frontend = PathBuf::from(env!("CARGO_BIN_EXE_builder-windows"));
        let dir = tempfile::tempdir().expect("temp dir");
        let config = dir.path().join("config").join("config.toml");
        let agent_data = dir.path().join("agent");
        let socket = agent_data.join("agent.sock");
        let checkout = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("repository root resolves");

        let init = Command::new(&agent_bin)
            .args([
                "init",
                "--data-root",
                agent_data.to_str().unwrap(),
                "--checkout",
                checkout.to_str().unwrap(),
                "--fake-build",
                "--fake-plan",
                fake_plan,
                "--agent-id",
                "e2e-agent",
            ])
            .output()
            .expect("builder-agent init runs");
        assert!(
            init.status.success(),
            "builder-agent init failed: {}",
            String::from_utf8_lossy(&init.stderr)
        );
        let agent = Command::new(&agent_bin)
            .args([
                "serve",
                "--socket",
                socket.to_str().unwrap(),
                "--data-root",
                agent_data.to_str().unwrap(),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("builder-agent serve starts");
        let harness = Self {
            _dir: dir,
            config,
            agent_data,
            agent,
            frontend,
        };
        harness.wait_for_socket(&socket);
        let output = harness.run(&[
            "host",
            "add",
            "--name",
            "local",
            "--local-agent",
            agent_bin.to_str().unwrap(),
            "--local-env",
            &format!("BUILDER_AGENT_DATA_ROOT={}", harness.agent_data.display()),
        ]);
        assert!(
            output.status.success(),
            "host add failed: {}{}",
            harness.stdout(&output),
            harness.stderr(&output)
        );
        Some(harness)
    }

    fn wait_for_socket(&self, socket: &Path) {
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if socket.exists() {
                return;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        panic!("Agent socket {} did not appear", socket.display());
    }

    fn base_command(&self) -> Command {
        let mut command = Command::new(&self.frontend);
        command.arg("--config").arg(&self.config);
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.base_command()
            .args(args)
            .output()
            .expect("frontend runs")
    }

    fn run_json(&self, args: &[&str]) -> Output {
        let mut full: Vec<&str> = vec!["--json"];
        full.extend_from_slice(args);
        self.run(&full)
    }

    fn stdout(&self, output: &Output) -> String {
        String::from_utf8_lossy(&output.stdout).to_string()
    }

    fn stderr(&self, output: &Output) -> String {
        String::from_utf8_lossy(&output.stderr).to_string()
    }

    fn write_rom(&self, name: &str, bytes: usize) -> PathBuf {
        let path = self._dir.path().join(name);
        let mut file = std::fs::File::create(&path).expect("create rom");
        let payload: Vec<u8> = (0..bytes).map(|index| (index % 251) as u8).collect();
        file.write_all(&payload).expect("write rom");
        path
    }

    fn build(&self, rom: &Path, out: &Path, extra: &[&str]) -> Output {
        let mut args = vec![
            "build".to_string(),
            "--host".to_string(),
            "local".to_string(),
            "--rom".to_string(),
            rom.to_str().unwrap().to_string(),
            "--name".to_string(),
            "pokemon-y".to_string(),
            "--display-name".to_string(),
            "Pokemon Y".to_string(),
            "--out".to_string(),
            out.to_str().unwrap().to_string(),
        ];
        args.extend(extra.iter().map(|value| value.to_string()));
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        self.run(&refs)
    }

    fn job_id(&self) -> String {
        let output = self.run_json(&["jobs", "--host", "local"]);
        assert!(
            output.status.success(),
            "jobs failed: {}",
            self.stderr(&output)
        );
        let jobs: serde_json::Value = serde_json::from_slice(&output.stdout).expect("jobs JSON");
        jobs[0]["job_id"]
            .as_str()
            .expect("a job id is present")
            .to_string()
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = self.agent.kill();
        let _ = self.agent.wait();
    }
}

#[test]
fn self_test_passes_without_a_mac_or_rom() {
    let Some(harness) = Harness::new("success") else {
        return;
    };
    let output = harness.run(&["self-test"]);
    let text = harness.stdout(&output);
    assert!(
        output.status.success(),
        "self-test failed: {text}{}",
        harness.stderr(&output)
    );
    assert!(text.contains("self-test: PASS"), "{text}");
    assert!(text.contains("[PASS] cjk_paths"), "{text}");
    assert!(text.contains("[PASS] long_paths"), "{text}");
}

#[test]
fn doctor_reports_this_pc() {
    let Some(harness) = Harness::new("success") else {
        return;
    };
    let output = harness.run(&["doctor"]);
    let text = harness.stdout(&output);
    assert!(
        text.contains("protocol: 3ds2apple-builder/1"),
        "{}",
        harness.stderr(&output)
    );
    assert!(text.contains("platform:"), "{text}");
    assert!(
        text.contains("openssh") || text.contains("OpenSSH"),
        "{text}"
    );
}

#[test]
fn build_succeeds_and_download_is_verified() {
    let Some(harness) = Harness::new("success") else {
        return;
    };
    let rom = harness.write_rom("Pokemon Y.cci", 256 * 1024);
    let out = harness._dir.path().join("out");
    let output = harness.build(&rom, &out, &[]);
    assert!(
        output.status.success(),
        "build failed: {}{}",
        harness.stdout(&output),
        harness.stderr(&output)
    );
    let text = harness.stdout(&output);
    assert!(text.contains("sha256:"), "{text}");
    assert!(text.contains("install guide:"), "{text}");
    assert!(text.contains("ROM on the Mac: deleted"), "{text}");

    // The IPA, manifest, artifact record and install guide exist and agree.
    let ipa = out.join("pokemon-y-AOT.ipa");
    assert!(ipa.is_file(), "IPA missing at {}", ipa.display());
    assert!(out.join("manifest.txt").is_file());
    assert!(out.join("pokemon-y-artifact.json").is_file());
    let guide = out.join("pokemon-y-INSTALL.txt");
    assert!(guide.is_file());
    let guide_text = std::fs::read_to_string(&guide).unwrap();
    assert!(guide_text.contains("certutil -hashfile"), "{guide_text}");
    assert!(
        guide_text.contains("https://sideloadly.io/"),
        "{guide_text}"
    );

    let manifest = std::fs::read_to_string(out.join("manifest.txt")).unwrap();
    let expected = manifest
        .lines()
        .find_map(|line| line.strip_prefix("ipa_sha256="))
        .expect("manifest sha256");
    let actual = builder_core::hash::sha256_file(&ipa).unwrap().sha256;
    assert_eq!(actual, expected);
    assert!(
        text.contains(expected),
        "printed result should contain the SHA256"
    );

    // The local record parses as the protocol artifact record.
    let record_text = std::fs::read_to_string(out.join("pokemon-y-artifact.json")).unwrap();
    let record: ArtifactRecord = serde_json::from_str(&record_text).expect("artifact record JSON");
    assert_eq!(record.ipa.sha256, expected);
    assert_eq!(record.game.name, "pokemon-y");
    assert_eq!(record.game.display_name, "Pokemon Y");

    // The ROM is deleted from the Agent after the job.
    let jobs_dir = harness.agent_data.join("jobs");
    if let Ok(entries) = std::fs::read_dir(&jobs_dir) {
        for entry in entries.flatten() {
            let input = entry.path().join("input");
            let leftovers: Vec<_> = std::fs::read_dir(&input)
                .map(|entries| entries.flatten().collect())
                .unwrap_or_default();
            assert!(
                leftovers.is_empty(),
                "job input was not cleaned: {leftovers:?}"
            );
        }
    }

    // Status, jobs, download and the install-guide viewer work on the result.
    let job_id = harness.job_id();
    let status = harness.run_json(&["status", "--host", "local", &job_id]);
    assert!(status.status.success(), "{}", harness.stderr(&status));
    let view: serde_json::Value = serde_json::from_slice(&status.stdout).expect("status JSON");
    assert_eq!(view["state"], "succeeded");

    let out_again = harness._dir.path().join("out2");
    let download = harness.run(&[
        "download",
        "--host",
        "local",
        &job_id,
        "--out",
        out_again.to_str().unwrap(),
    ]);
    assert!(
        download.status.success(),
        "download failed: {}",
        harness.stderr(&download)
    );
    assert!(out_again.join("pokemon-y-AOT.ipa").is_file());
    assert_eq!(
        builder_core::hash::sha256_file(&out_again.join("pokemon-y-AOT.ipa"))
            .unwrap()
            .sha256,
        expected
    );

    let guide_output = harness.run(&[
        "install-guide",
        "--ipa",
        ipa.to_str().unwrap(),
        "--sha256",
        expected,
        "--display-name",
        "Pokemon Y",
    ]);
    assert!(
        guide_output.status.success(),
        "{}",
        harness.stderr(&guide_output)
    );
    assert!(harness.stdout(&guide_output).contains(expected));
}

#[test]
fn build_failure_reports_stage_hint_and_exit_code() {
    let Some(harness) = Harness::new("fail-packaging") else {
        return;
    };
    let rom = harness.write_rom("fail.cci", 4096);
    let out = harness._dir.path().join("out");
    let output = harness.build(&rom, &out, &[]);
    assert_eq!(
        output.status.code(),
        Some(1),
        "expected exit 1: {}",
        harness.stderr(&output)
    );
    let errors = harness.stderr(&output);
    assert!(errors.contains("build failed"), "{errors}");
    assert!(errors.contains("hint:"), "{errors}");
    assert!(!out.join("pokemon-y-AOT.ipa").exists());
    let view = harness.run_json(&["status", "--host", "local", &harness.job_id()]);
    let view: serde_json::Value = serde_json::from_slice(&view.stdout).unwrap_or_default();
    assert_eq!(view["state"], "failed");
}

#[test]
fn cancel_stops_a_running_build_with_exit_code_4() {
    let Some(harness) = Harness::new("slow") else {
        return;
    };
    let rom = harness.write_rom("slow.cci", 4096);
    let out = harness._dir.path().join("out");
    let mut child = harness
        .base_command()
        .args([
            "build",
            "--host",
            "local",
            "--rom",
            rom.to_str().unwrap(),
            "--name",
            "slow-game",
            "--out",
            out.to_str().unwrap(),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("build spawns");

    // Wait until the job is running on the Agent, then cancel it from another
    // process exactly like a second window would.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut job_id = None;
    while Instant::now() < deadline {
        let output = harness.run_json(&["jobs", "--host", "local"]);
        if output.status.success() {
            if let Ok(jobs) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                if let Some(first) = jobs.get(0) {
                    let state = first["state"].as_str().unwrap_or("");
                    if state == "running" || state == "queued" {
                        job_id = first["job_id"].as_str().map(str::to_string);
                        break;
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let job_id = job_id.expect("the slow build should reach running/queued");
    let cancel = harness.run(&["cancel", "--host", "local", &job_id]);
    assert!(
        cancel.status.success(),
        "cancel failed: {}",
        harness.stderr(&cancel)
    );
    let status = child.wait().expect("build process exits");
    assert_eq!(status.code(), Some(4), "expected canceled exit code 4");
    let view = harness.run_json(&["status", "--host", "local", &job_id]);
    let view: serde_json::Value = serde_json::from_slice(&view.stdout).unwrap_or_default();
    assert_eq!(view["state"], "canceled");
}

#[test]
fn unknown_host_is_a_usage_error() {
    let Some(harness) = Harness::new("success") else {
        return;
    };
    let output = harness.run(&["status", "--host", "nope", "job_01J8Z3K4T9ABCDEFGHJKMNPQRS"]);
    assert_eq!(output.status.code(), Some(2));
    assert!(harness.stderr(&output).contains("unknown host"));
}

#[test]
fn a_missing_rom_is_a_usage_error() {
    let Some(harness) = Harness::new("success") else {
        return;
    };
    let out = harness._dir.path().join("out");
    let output = harness.build(&harness._dir.path().join("missing.cci"), &out, &[]);
    assert_eq!(output.status.code(), Some(2));
    assert!(harness.stderr(&output).contains("does not exist"));
}

#[test]
fn the_host_list_shares_the_config_file() {
    let Some(harness) = Harness::new("success") else {
        return;
    };
    let output = harness.run_json(&["host", "list"]);
    assert!(output.status.success(), "{}", harness.stderr(&output));
    let hosts: serde_json::Value = serde_json::from_slice(&output.stdout).expect("host list JSON");
    assert_eq!(hosts[0]["id"], "local");
    assert_eq!(hosts[0]["name"], "local");
    // The configuration is the documented shared one, in TOML.
    let text = std::fs::read_to_string(&harness.config).unwrap();
    assert!(text.contains("kind = \"local\""), "{text}");
}
