//! End-to-end test of the Linux frontend against the real Build Agent in
//! fake-build mode.
//!
//! The Agent runs as a daemon on a Unix socket; the frontend pairs it through
//! its `zkb` passthrough (local transport), builds a deterministic non-ROM
//! payload, streams the NDJSON log, downloads the fake IPA, re-hashes it and
//! prints the installation guide. No ROM, macOS, Xcode or network is involved.
#![cfg(unix)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

const FRONTEND: &str = env!("CARGO_BIN_EXE_3ds2apple-builder");

struct E2e {
    _dir: tempfile::TempDir,
    config_dir: PathBuf,
    data_dir: PathBuf,
    agent_data: PathBuf,
    agent: Child,
    frontend: PathBuf,
    zkb: PathBuf,
}

impl E2e {
    fn new(fake_plan: &str) -> Self {
        let frontend = PathBuf::from(FRONTEND);
        let debug_dir = frontend
            .parent()
            .expect("frontend has a parent directory")
            .to_path_buf();
        let zkb = debug_dir.join("zkb");
        let agent_bin = debug_dir.join("builder-agent");
        assert!(
            zkb.is_file(),
            "{} is missing; run the workspace tests (`cargo test --workspace`) so all binaries \
             are built",
            zkb.display()
        );
        assert!(
            agent_bin.is_file(),
            "{} is missing; run the workspace tests (`cargo test --workspace`) so all binaries \
             are built",
            agent_bin.display()
        );
        let dir = tempfile::tempdir().expect("temp dir");
        let config_dir = dir.path().join("config");
        let data_dir = dir.path().join("data");
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
                "linux-frontend-e2e",
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
            data_dir,
            agent_data,
            agent,
            frontend,
            zkb,
        };
        e2e.wait_for_socket(&socket);
        let add = e2e.run(&[
            "zkb",
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

    fn command(&self) -> Command {
        let mut command = Command::new(&self.frontend);
        command
            .env("ZKB_CONFIG_DIR", &self.config_dir)
            .env("ZKB_DATA_DIR", &self.data_dir)
            .env("ZKB_BIN", &self.zkb)
            .env_remove("ZKB_VM_SSH")
            .env_remove("ZKB_VM_HOST")
            .env_remove("ZKB_VM_PORT")
            .env_remove("ZKB_VM_USER");
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command()
            .args(args)
            .stdin(Stdio::null())
            .output()
            .expect("frontend runs")
    }

    fn write_payload(&self, name: &str, bytes: usize) -> PathBuf {
        let path = self._dir.path().join(name);
        let mut file = std::fs::File::create(&path).expect("create payload");
        // Deterministic test payload; this is not a ROM.
        let payload: Vec<u8> = (0..bytes).map(|index| (index % 251) as u8).collect();
        file.write_all(&payload).expect("write payload");
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
            "demo-game".to_string(),
            "--display-name".to_string(),
            "Demo Game".to_string(),
            "--out".to_string(),
            out.to_str().unwrap().to_string(),
        ];
        args.extend(extra.iter().map(|value| value.to_string()));
        let refs: Vec<&str> = args.iter().map(String::as_str).collect();
        self.run(&refs)
    }

    fn job_inputs_are_clean(&self) -> bool {
        let jobs = match std::fs::read_dir(self.agent_data.join("jobs")) {
            Ok(jobs) => jobs,
            Err(_) => return true,
        };
        for job in jobs.flatten() {
            if let Ok(entries) = std::fs::read_dir(job.path().join("input")) {
                if entries.flatten().next().is_some() {
                    return false;
                }
            }
        }
        true
    }
}

impl Drop for E2e {
    fn drop(&mut self) {
        let _ = self.agent.kill();
        let _ = self.agent.wait();
    }
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).to_string()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).to_string()
}

#[test]
fn build_succeeds_verifies_the_ipa_and_prints_the_install_guide() {
    let e2e = E2e::new("success");
    let rom = e2e.write_payload("Pokemon Y.cci", 256 * 1024);
    let out = e2e._dir.path().join("out");
    let output = e2e.build(&rom, &out, &[]);
    assert!(
        output.status.success(),
        "build failed: {}{}",
        stdout(&output),
        stderr(&output)
    );
    let text = stdout(&output);
    assert!(text.contains("Build succeeded"), "{text}");
    assert!(text.contains("verified:"), "{text}");
    assert!(text.contains("demo-game-AOT.ipa"), "{text}");
    assert!(text.contains("Sideloadly"), "{text}");
    assert!(
        text.contains("AltStore") || text.contains("install-guide"),
        "{text}"
    );

    let ipa = out.join("demo-game-AOT.ipa");
    assert!(ipa.is_file(), "IPA missing at {}", ipa.display());
    let manifest = std::fs::read_to_string(out.join("manifest.txt")).expect("manifest");
    let expected = manifest
        .lines()
        .find_map(|line| line.strip_prefix("ipa_sha256="))
        .expect("manifest sha256");
    let actual = builder_core::hash::sha256_file(&ipa).expect("ipa hash");
    assert_eq!(actual.sha256, expected);
    assert!(
        text.contains(&actual.sha256),
        "the frontend must print the verified SHA256"
    );

    // The Agent must have deleted the uploaded ROM (default cleanup).
    assert!(
        e2e.job_inputs_are_clean(),
        "the job input directory still contains files"
    );

    // The optional host self-test in `doctor --host` also works. The local
    // "openssh" check depends on the host machine, so only the remote host
    // check and the overall report shape are asserted strictly here.
    let doctor = e2e.run(&["doctor", "--host", "local"]);
    let doctor_text = stdout(&doctor);
    assert!(
        doctor_text.contains("[ok  ] host test"),
        "{}",
        stderr(&doctor)
    );
    if doctor.status.success() {
        assert!(doctor_text.contains("ready: yes"), "{doctor_text}");
    } else {
        assert!(
            doctor_text.contains("[FAIL] openssh") || doctor_text.contains("[warn] macos vm"),
            "{doctor_text}"
        );
    }
}

#[test]
fn failed_build_forwards_the_build_exit_code_and_hint() {
    let e2e = E2e::new("fail-packaging");
    let rom = e2e.write_payload("fail.cci", 4096);
    let out = e2e._dir.path().join("out");
    let output = e2e.build(&rom, &out, &[]);
    assert_eq!(output.status.code(), Some(1), "{}", stderr(&output));
    let errors = stderr(&output);
    assert!(errors.contains("build failed"), "{errors}");
    assert!(errors.contains("hint:"), "{errors}");
    assert!(!out.join("demo-game-AOT.ipa").exists());
}

#[test]
fn failed_build_reports_a_fixable_stage() {
    let e2e = E2e::new("fail-packaging");
    let rom = e2e.write_payload("fail.cci", 4096);
    let out = e2e._dir.path().join("out");
    let output = e2e.build(&rom, &out, &[]);
    let errors = stderr(&output);
    assert!(
        errors.contains("build failed") && errors.contains("_recomp_"),
        "the forwarded Agent log should mention the failing linker symbols: {errors}"
    );
}

#[test]
fn canceled_build_exits_4() {
    let e2e = E2e::new("slow");
    let rom = e2e.write_payload("slow.cci", 4096);
    let out = e2e._dir.path().join("out");
    let mut build = e2e
        .command()
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

    // Wait until the job is visible on the Agent, then cancel through the
    // shared client passthrough.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut job_id = None;
    while Instant::now() < deadline {
        let output = e2e.run(&["--json", "zkb", "jobs", "--host", "local"]);
        if output.status.success() {
            if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                if let Some(job) = value["jobs"].as_array().and_then(|jobs| jobs.first()) {
                    if let Some(id) = job["job_id"].as_str() {
                        job_id = Some(id.to_string());
                        break;
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let job_id = job_id.expect("the slow build should appear on the Agent");
    let cancel = e2e.run(&["zkb", "cancel", "--host", "local", &job_id]);
    assert!(cancel.status.success(), "{}", stderr(&cancel));
    let status = build.wait().expect("build process exits");
    assert_eq!(status.code(), Some(4), "expected the canceled exit code 4");
}

#[test]
fn json_build_keeps_stdout_machine_readable() {
    let e2e = E2e::new("success");
    let rom = e2e.write_payload("json.cci", 64 * 1024);
    let out = e2e._dir.path().join("out-json");
    let output = e2e.build(&rom, &out, &["--json"]);
    assert!(
        output.status.success(),
        "build failed: {}{}",
        stdout(&output),
        stderr(&output)
    );
    // stdout is the shared client's NDJSON stream; every line is one object.
    let text = stdout(&output);
    assert!(!text.trim().is_empty(), "expected NDJSON on stdout");
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let value: serde_json::Value = serde_json::from_str(line)
            .unwrap_or_else(|error| panic!("stdout line is not JSON: {line}: {error}"));
        assert!(value.is_object(), "not a JSON object: {line}");
    }
    // The local verification summary is on stderr and still present.
    let diagnostics = stderr(&output);
    assert!(diagnostics.contains("demo-game-AOT.ipa"), "{diagnostics}");
    assert!(out.join("demo-game-AOT.ipa").is_file());
}
