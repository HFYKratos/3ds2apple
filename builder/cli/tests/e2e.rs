//! End-to-end tests for the CLI against the real Build Agent in fake-build mode.
//!
//! The Agent is started as a separate process (Unix-socket daemon), the CLI
//! talks to it through the production `ssh-dispatch` local transport, and the
//! whole protocol path runs: handshake, job creation, resumable upload, queue,
//! NDJSON event stream, artifact download/verification and cleanup.
#![cfg(unix)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

use builder_core::protocol::frames::JobListResult;
use builder_core::protocol::model::JobState;
use tempfile::TempDir;

const AGENT_BIN_NAME: &str = "builder-agent";

struct E2e {
    _dir: TempDir,
    config_dir: PathBuf,
    agent_data: PathBuf,
    agent: Child,
    zkb: PathBuf,
}

impl E2e {
    fn new(fake_plan: &str) -> Self {
        let zkb = PathBuf::from(env!("CARGO_BIN_EXE_zkb"));
        let debug_dir = zkb
            .parent()
            .expect("zkb has a parent directory")
            .to_path_buf();
        let agent_bin = debug_dir.join(AGENT_BIN_NAME);
        assert!(
            agent_bin.is_file(),
            "{} is missing; run the workspace tests (`cargo test --workspace`) so all binaries are built",
            agent_bin.display()
        );
        let dir = tempfile::tempdir().expect("temp dir");
        let config_dir = dir.path().join("config");
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
        let e2e = Self {
            _dir: dir,
            config_dir,
            agent_data,
            agent,
            zkb,
        };
        e2e.wait_for_socket(&socket);
        let add = e2e.run(&[
            "host",
            "add",
            "--name",
            "local",
            "--local-agent",
            agent_bin.to_str().unwrap(),
            "--local-env",
            &format!("BUILDER_AGENT_DATA_ROOT={}", e2e.agent_data.display()),
        ]);
        assert!(
            add.status.success(),
            "host add failed: {}{}",
            String::from_utf8_lossy(&add.stdout),
            String::from_utf8_lossy(&add.stderr)
        );
        e2e
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
        let mut command = Command::new(&self.zkb);
        command.env("ZKB_CONFIG_DIR", &self.config_dir);
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.base_command().args(args).output().expect("zkb runs")
    }

    fn run_json(&self, args: &[&str]) -> Output {
        let mut full: Vec<&str> = vec!["--json"];
        full.extend_from_slice(args);
        self.run(&full)
    }

    fn write_rom(&self, name: &str, bytes: usize) -> PathBuf {
        let path = self._dir.path().join(name);
        let mut file = std::fs::File::create(&path).expect("create rom");
        // Deterministic content: these are not real ROMs, only test payloads.
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

    fn job_id_from_jobs(&self) -> (String, JobState) {
        let output = self.run_json(&["jobs", "--host", "local"]);
        assert!(
            output.status.success(),
            "zkb jobs failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let reply: JobListResult =
            serde_json::from_slice(&output.stdout).expect("jobs output is a JobListResult");
        let job = reply.jobs.first().expect("at least one job");
        (job.job_id.clone(), job.state)
    }
}

impl Drop for E2e {
    fn drop(&mut self) {
        let _ = self.agent.kill();
        let _ = self.agent.wait();
    }
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).to_string()
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).to_string()
}

#[test]
fn host_test_reports_a_ready_agent() {
    let e2e = E2e::new("success");
    let output = e2e.run(&["host", "test", "local"]);
    let text = stdout(&output);
    assert!(
        output.status.success(),
        "host test failed: {text}{}",
        stderr(&output)
    );
    assert!(text.contains("ready: yes"), "{text}");
    assert!(text.contains("protocol 3ds2apple-builder/1"), "{text}");
}

#[test]
fn build_succeeds_and_download_verifies_the_artifact() {
    let e2e = E2e::new("success");
    let rom = e2e.write_rom("Pokemon Y.cci", 256 * 1024);
    let out = e2e._dir.path().join("out");
    let output = e2e.build(&rom, &out, &[]);
    assert!(
        output.status.success(),
        "build failed: {}{}",
        stdout(&output),
        stderr(&output)
    );
    let text = stdout(&output);
    assert!(text.contains("sha256:"), "{text}");
    let ipa = out.join("pokemon-y-AOT.ipa");
    assert!(ipa.is_file(), "IPA missing at {}", ipa.display());
    assert!(out.join("manifest.txt").is_file());
    assert!(out.join("pokemon-y-artifact.json").is_file());
    // The printed SHA256 must match the manifest and the file.
    let manifest = std::fs::read_to_string(out.join("manifest.txt")).unwrap();
    let expected = manifest
        .lines()
        .find_map(|line| line.strip_prefix("ipa_sha256="))
        .expect("manifest sha256");
    let actual = builder_core::hash::sha256_file(&ipa).unwrap();
    assert_eq!(actual.sha256, expected);
    assert!(
        text.contains(expected),
        "printed result should contain the SHA256"
    );

    // The ROM must be gone from the Agent after the job (default cleanup).
    let jobs = std::fs::read_dir(e2e.agent_data.join("jobs")).unwrap();
    for job in jobs.flatten() {
        let input = job.path().join("input");
        let leftovers: Vec<_> = std::fs::read_dir(&input)
            .map(|entries| entries.flatten().collect())
            .unwrap_or_default();
        assert!(
            leftovers.is_empty(),
            "job input was not cleaned: {leftovers:?}"
        );
    }

    // Jobs/logs/status work on the finished job.
    let (job_id, state) = e2e.job_id_from_jobs();
    assert_eq!(state, JobState::Succeeded);
    let logs = e2e.run(&["logs", "--host", "local", &job_id, "--no-follow"]);
    assert!(logs.status.success(), "logs failed: {}", stderr(&logs));
    assert!(
        stdout(&logs).contains("build succeeded"),
        "{}",
        stdout(&logs)
    );
    let status = e2e.run_json(&["status", "--host", "local", &job_id]);
    assert!(status.status.success());
    let view: builder_core::protocol::model::JobView =
        serde_json::from_slice(&status.stdout).expect("status JSON");
    assert_eq!(view.state, JobState::Succeeded);
    assert!(view.artifact.is_some());

    // Downloading again is resumable/verified and gives the same file.
    let out2 = e2e._dir.path().join("out2");
    let download = e2e.run(&[
        "download",
        "--host",
        "local",
        &job_id,
        "--out",
        out2.to_str().unwrap(),
    ]);
    assert!(
        download.status.success(),
        "download failed: {}",
        stderr(&download)
    );
    assert!(out2.join("pokemon-y-AOT.ipa").is_file());
}

#[test]
fn build_failure_reports_stage_hint_and_exit_code() {
    let e2e = E2e::new("fail-packaging");
    let rom = e2e.write_rom("fail.cci", 4096);
    let out = e2e._dir.path().join("out");
    let output = e2e.build(&rom, &out, &[]);
    assert_eq!(
        output.status.code(),
        Some(1),
        "expected exit 1: {}",
        stderr(&output)
    );
    let errors = stderr(&output);
    assert!(errors.contains("build failed"), "{errors}");
    assert!(errors.contains("hint:"), "{errors}");
    assert!(errors.contains("_recomp_"), "{errors}");
    assert!(!out.join("pokemon-y-AOT.ipa").exists());
    let (_, state) = e2e.job_id_from_jobs();
    assert_eq!(state, JobState::Failed);
}

#[test]
fn corrupt_artifact_is_rejected_during_verification() {
    let e2e = E2e::new("corrupt-artifact");
    let rom = e2e.write_rom("corrupt.cci", 4096);
    let out = e2e._dir.path().join("out");
    let output = e2e.build(&rom, &out, &[]);
    assert_eq!(
        output.status.code(),
        Some(1),
        "expected exit 1: {}",
        stderr(&output)
    );
    let errors = stderr(&output);
    assert!(
        errors.contains("verify_failed") || errors.contains("SHA256 mismatch"),
        "{errors}"
    );
    assert!(!out.exists() || std::fs::read_dir(&out).unwrap().next().is_none());
}

#[test]
fn cancel_stops_a_running_build_with_exit_code_4() {
    let e2e = E2e::new("slow");
    let rom = e2e.write_rom("slow.cci", 4096);
    let out = e2e._dir.path().join("out");
    let mut build = e2e
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
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("build spawns");

    // Wait until the job is running on the Agent, then cancel it.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut job_id = None;
    while Instant::now() < deadline {
        let output = e2e.run_json(&["jobs", "--host", "local"]);
        if output.status.success() {
            if let Ok(reply) = serde_json::from_slice::<JobListResult>(&output.stdout) {
                if let Some(job) = reply.jobs.first() {
                    if job.state == JobState::Running || job.state == JobState::Queued {
                        job_id = Some(job.job_id.clone());
                        break;
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let job_id = job_id.expect("the slow build should reach running/queued");
    let cancel = e2e.run(&["cancel", "--host", "local", &job_id]);
    assert!(
        cancel.status.success(),
        "cancel failed: {}",
        stderr(&cancel)
    );
    let status = build.wait().expect("build process exits");
    assert_eq!(status.code(), Some(4), "expected canceled exit code 4");

    let (_, state) = e2e.job_id_from_jobs();
    assert_eq!(state, JobState::Canceled);
}

#[test]
fn unknown_host_is_a_usage_error() {
    let e2e = E2e::new("success");
    let output = e2e.run(&["status", "--host", "nope", "job_01J8Z3K4T9ABCDEFGHJKMNPQRS"]);
    assert_eq!(output.status.code(), Some(2));
    assert!(stderr(&output).contains("unknown host"));
}
