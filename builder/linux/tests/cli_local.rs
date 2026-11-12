//! Local integration tests for the Linux frontend.
//!
//! These run the real binary with an isolated config/data directory. They do
//! not need a macOS host: anything that would talk to one either fails on the
//! endpoint probe or is exercised against the fake Agent in
//! `e2e_fake_agent.rs`.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const BIN: &str = env!("CARGO_BIN_EXE_3ds2apple-builder");

/// Find the shared `zkb` binary next to this test binary.
fn sibling_bin(name: &str) -> Option<PathBuf> {
    let bin = PathBuf::from(BIN);
    let candidate = bin.parent()?.join(name);
    candidate.is_file().then_some(candidate)
}

struct Env {
    _dir: tempfile::TempDir,
    config_dir: PathBuf,
    data_dir: PathBuf,
    zkb: Option<PathBuf>,
}

impl Env {
    fn new() -> Self {
        let dir = tempfile::tempdir().expect("temp dir");
        let config_dir = dir.path().join("config");
        let data_dir = dir.path().join("data");
        Self {
            _dir: dir,
            config_dir,
            data_dir,
            zkb: sibling_bin("zkb"),
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(BIN);
        command
            .env("ZKB_CONFIG_DIR", &self.config_dir)
            .env("ZKB_DATA_DIR", &self.data_dir)
            .env_remove("ZKB_VM_SSH")
            .env_remove("ZKB_VM_HOST")
            .env_remove("ZKB_VM_PORT")
            .env_remove("ZKB_VM_USER")
            .env_remove("ZKB_BIN");
        if let Some(zkb) = &self.zkb {
            command.env("ZKB_BIN", zkb);
        }
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command()
            .args(args)
            .stdin(std::process::Stdio::null())
            .output()
            .expect("frontend runs")
    }

    fn write_config(&self, hosts: &[(&str, &str)]) {
        // A minimal config with Local transport profiles: no macOS needed.
        let mut text = String::from("version = 1\n");
        for (id, program) in hosts {
            text.push_str(&format!(
                "\n[[hosts]]\nid = \"{id}\"\nname = \"{id} name\"\ncreated_at = \
                 \"2026-01-01T00:00:00Z\"\ntransport = {{ kind = \"local\", program = \
                 \"{program}\", args = [], env = {{}} }}\n"
            ));
        }
        std::fs::create_dir_all(&self.config_dir).expect("config dir");
        std::fs::write(self.config_dir.join("config.toml"), text).expect("write config");
    }
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).to_string()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).to_string()
}

/// Whether the OpenSSH client is installed (the doctor "openssh" check).
fn openssh_available() -> bool {
    Command::new("ssh")
        .arg("-V")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok()
}

#[test]
fn status_reports_the_first_run_state() {
    let env = Env::new();
    let output = env.run(&[]);
    assert!(output.status.success(), "{}", stderr(&output));
    let text = stdout(&output);
    assert!(text.contains("3ds2apple Builder (Linux)"), "{text}");
    assert!(text.contains("Next steps:"), "{text}");
    assert!(text.contains("vm setup"), "{text}");
    assert!(text.contains("unsigned"), "{text}");
    assert!(text.contains("never asks for an Apple ID"), "{text}");
}

#[test]
fn status_json_is_parseable() {
    let env = Env::new();
    let output = env.run(&["--json"]);
    assert!(output.status.success(), "{}", stderr(&output));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("status JSON on stdout");
    assert_eq!(value["hosts"].as_array().unwrap().len(), 0);
    assert!(value["next_steps"].as_array().unwrap().len() >= 2);
    assert!(value["config_path"]
        .as_str()
        .unwrap()
        .ends_with("config.toml"));
}

#[test]
fn doctor_reports_ready_on_an_isolated_setup() {
    let env = Env::new();
    if env.zkb.is_none() {
        panic!("zkb is missing next to the test binary; run `cargo test --workspace`");
    }
    if !openssh_available() {
        eprintln!("skipping: the OpenSSH client is not installed in this environment");
        return;
    }
    let output = env.run(&["doctor"]);
    assert!(output.status.success(), "{}", stderr(&output));
    let text = stdout(&output);
    assert!(text.contains("ready: yes"), "{text}");
    assert!(text.contains("[ok  ] zkb"), "{text}");
    assert!(text.contains("[ok  ] openssh"), "{text}");
}

#[test]
fn doctor_json_contains_named_checks() {
    let env = Env::new();
    let output = env.run(&["--json", "doctor"]);
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("doctor JSON on stdout");
    let checks = value["checks"].as_array().expect("checks array");
    let names: Vec<&str> = checks
        .iter()
        .map(|check| check["name"].as_str().unwrap_or(""))
        .collect();
    assert!(names.contains(&"zkb"), "{names:?}");
    assert!(names.contains(&"openssh"), "{names:?}");
    assert!(names.contains(&"config"), "{names:?}");
    assert!(value["ready"].is_boolean());
}

#[test]
fn vm_discover_json_reports_notes_without_a_vm() {
    let env = Env::new();
    let output = env.run(&["--json", "vm", "discover"]);
    assert!(output.status.success(), "{}", stderr(&output));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("discovery JSON on stdout");
    assert!(value["endpoints"].is_array());
    assert!(value["notes"].is_array());
}

#[test]
fn vm_discover_human_output_explains_the_next_step() {
    let env = Env::new();
    let output = env.run(&["vm", "discover", "--no-probe"]);
    assert!(output.status.success(), "{}", stderr(&output));
    let text = stdout(&output);
    assert!(
        text.contains("No macOS VM SSH endpoint found") || text.contains("Candidate macOS"),
        "{text}"
    );
    assert!(text.contains("note:"), "{text}");
}

#[test]
fn vm_setup_rejects_an_endpoint_that_is_not_ssh() {
    let env = Env::new();
    // Reserve a port, then release it so nothing listens there.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port().to_string();
    drop(listener);
    let output = env.run(&[
        "vm",
        "setup",
        "--name",
        "vm",
        "--host",
        "127.0.0.1",
        "--port",
        &port,
        "--no-input",
        "--yes",
    ]);
    assert_eq!(output.status.code(), Some(3), "{}", stderr(&output));
    assert!(stderr(&output).contains("not answering as an SSH server"));
}

#[test]
fn install_guide_with_a_missing_ipa_is_an_io_error() {
    let env = Env::new();
    let output = env.run(&["install-guide", "--ipa", "/nonexistent/file.ipa"]);
    assert_eq!(output.status.code(), Some(5), "{}", stderr(&output));
    assert!(stderr(&output).contains("does not exist"));
}

#[test]
fn install_guide_hashes_the_artifact() {
    let env = Env::new();
    let ipa = env._dir.path().join("demo-AOT.ipa");
    std::fs::write(&ipa, b"abc").expect("write ipa");
    let output = env.run(&["install-guide", "--ipa", ipa.to_str().expect("utf-8 path")]);
    assert!(output.status.success(), "{}", stderr(&output));
    let text = stdout(&output);
    let sha = builder_core::hash::sha256_hex(b"abc");
    assert!(text.contains(&sha), "{text}");
    assert!(text.contains("sha256sum"), "{text}");
    assert!(text.contains("Sideloadly"), "{text}");
    assert!(text.contains("AltStore"), "{text}");
}

#[test]
fn install_guide_json_shows_the_artifact_summary() {
    let env = Env::new();
    let ipa = env._dir.path().join("demo-AOT.ipa");
    std::fs::write(&ipa, b"abc").expect("write ipa");
    let output = env.run(&[
        "--json",
        "install-guide",
        "--ipa",
        ipa.to_str().expect("utf-8 path"),
    ]);
    assert!(output.status.success(), "{}", stderr(&output));
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("install-guide JSON on stdout");
    assert_eq!(value["bytes"], 3);
    assert_eq!(
        value["sha256"],
        builder_core::hash::sha256_hex(b"abc").as_str()
    );
}

#[test]
fn build_requires_a_rom_without_a_terminal() {
    let env = Env::new();
    if env.zkb.is_none() {
        panic!("zkb is missing next to the test binary; run `cargo test --workspace`");
    }
    env.write_config(&[("vm", "/bin/true")]);
    let rom_dir = env._dir.path().join("roms");
    std::fs::create_dir_all(&rom_dir).expect("rom dir");
    std::fs::write(rom_dir.join("game.cci"), b"payload").expect("fake rom");
    let output = env.run(&[
        "build",
        "--host",
        "vm",
        "--rom-dir",
        rom_dir.to_str().expect("utf-8 path"),
    ]);
    assert_eq!(output.status.code(), Some(2), "{}", stderr(&output));
    assert!(
        stderr(&output).contains("--rom is required"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn build_with_an_unknown_host_is_a_usage_error() {
    let env = Env::new();
    if env.zkb.is_none() {
        panic!("zkb is missing next to the test binary; run `cargo test --workspace`");
    }
    env.write_config(&[("vm", "/bin/true")]);
    let output = env.run(&["build", "--host", "nope", "--rom", "/etc/hostname"]);
    assert_eq!(output.status.code(), Some(2), "{}", stderr(&output));
    assert!(stderr(&output).contains("unknown host"));
}

#[test]
fn zkb_passthrough_needs_arguments() {
    let env = Env::new();
    let output = env.run(&["zkb"]);
    assert_eq!(output.status.code(), Some(2), "{}", stderr(&output));
    assert!(stderr(&output).contains("host list"));
}

#[test]
fn zkb_passthrough_forwards_the_shared_client_output() {
    let env = Env::new();
    if env.zkb.is_none() {
        panic!("zkb is missing next to the test binary; run `cargo test --workspace`");
    }
    let output = env.run(&["zkb", "host", "list"]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert!(stdout(&output).contains("no build hosts configured"));
}

/// The environment helper is not dead code: used by several tests above.
#[test]
fn env_helper_sets_isolated_directories() {
    let env = Env::new();
    let output = env.run(&["doctor", "--json"]);
    // The ready flag depends on the host's OpenSSH install; the JSON report is
    // produced either way (exit code 3 when a check fails).
    let value: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("doctor JSON on stdout");
    let config_detail = value["checks"]
        .as_array()
        .and_then(|checks| {
            checks
                .iter()
                .find(|check| check["name"] == "config")
                .and_then(|check| check["detail"].as_str())
                .map(str::to_string)
        })
        .unwrap_or_default();
    assert!(
        config_detail.contains(&env.config_dir.display().to_string()),
        "{config_detail}"
    );
    assert!(Path::new(&env.data_dir).exists());
}
