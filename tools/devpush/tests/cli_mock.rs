//! CLI contract tests against the filesystem mock backend (no device needed).

use std::path::Path;
use std::process::Command;

use serde_json::Value;

const HELLO_SHA256: &str = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";

fn run(mock: &Path, args: &[&str]) -> (i32, Vec<Value>, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_devpush"))
        .arg("--mock-dir")
        .arg(mock)
        .args(args)
        .arg("--json")
        .output()
        .expect("devpush runs");
    let code = output.status.code().unwrap_or(-1);
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let events = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str::<Value>(line)
                .unwrap_or_else(|error| panic!("stdout line is not JSON: {line}: {error}"))
        })
        .collect::<Vec<_>>();
    (code, events, stderr)
}

fn done_payload(events: &[Value]) -> &Value {
    let done = events
        .iter()
        .find(|event| event["type"] == "done")
        .expect("a done event");
    assert_eq!(done["schema"], "devpush/1");
    done
}

fn error_payload(events: &[Value]) -> &Value {
    let error = events
        .iter()
        .find(|event| event["type"] == "error")
        .expect("an error event");
    assert_eq!(error["schema"], "devpush/1");
    error
}

fn tempdir() -> tempfile::TempDir {
    tempfile::tempdir().expect("tempdir")
}

fn write_file(path: &Path, bytes: &[u8]) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, bytes).unwrap();
}

fn mock_install(mock: &Path, ipa: &Path, bundle: &str) {
    let (code, events, stderr) = run(
        mock,
        &[
            "install",
            "--ipa",
            ipa.to_str().unwrap(),
            "--bundle-id",
            bundle,
        ],
    );
    assert_eq!(code, 0, "install failed: {stderr}");
    assert_eq!(done_payload(&events)["installed"], true);
}

#[test]
fn capabilities_devices_and_json_contract() {
    let dir = tempdir();
    let mock = dir.path().join("mock");
    let (code, events, _stderr) = run(&mock, &["capabilities"]);
    assert_eq!(code, 0);
    let payload = done_payload(&events);
    assert_eq!(payload["schema"], "devpush/1".to_string());
    assert_eq!(payload["backend"], "mock");
    assert!(payload["commands"]
        .as_array()
        .unwrap()
        .iter()
        .any(|command| command == "put"));

    let (code, events, _stderr) = run(&mock, &["devices"]);
    assert_eq!(code, 0);
    let devices = done_payload(&events)["devices"].as_array().unwrap().clone();
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0]["udid"], "MOCK-0000000000000001");
    assert_eq!(devices[0]["connection"], "usb");
    assert_eq!(devices[0]["paired"], true);
}

#[test]
fn install_put_get_ls_stat_and_push_tar_roundtrip() {
    let dir = tempdir();
    let mock = dir.path().join("mock");
    let ipa = dir.path().join("Shell.ipa");
    write_file(&ipa, b"fake ipa bytes");
    mock_install(&mock, &ipa, "com.kratos.3ds2apple");

    let (code, events, _stderr) = run(
        &mock,
        &[
            "app-attr",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--key",
            "CFBundleVersion",
        ],
    );
    assert_eq!(code, 0);
    assert_eq!(done_payload(&events)["value"], "1.0");

    let local = dir.path().join("GamePack.dylib");
    write_file(&local, b"hello world");
    let (code, events, stderr) = run(
        &mock,
        &[
            "put",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--local",
            local.to_str().unwrap(),
            "--remote",
            "Documents/Games/0004000000055D00/GamePack.dylib",
        ],
    );
    assert_eq!(code, 0, "put failed: {stderr}");
    let put = done_payload(&events);
    assert_eq!(put["bytes"], 11);
    assert_eq!(put["sha256"], HELLO_SHA256);
    assert!(events.iter().any(|event| event["type"] == "progress"));

    let (code, events, _stderr) = run(
        &mock,
        &[
            "stat",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--path",
            "Documents/Games/0004000000055D00/GamePack.dylib",
        ],
    );
    assert_eq!(code, 0);
    assert_eq!(done_payload(&events)["size"], 11);
    assert_eq!(done_payload(&events)["isDir"], false);

    let (code, events, _stderr) = run(
        &mock,
        &[
            "ls",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--path",
            "Documents/Games/0004000000055D00",
        ],
    );
    assert_eq!(code, 0);
    let entries = done_payload(&events)["entries"].as_array().unwrap().clone();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["name"], "GamePack.dylib");

    let fetched = dir.path().join("fetched.dylib");
    let (code, events, _stderr) = run(
        &mock,
        &[
            "get",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--remote",
            "Documents/Games/0004000000055D00/GamePack.dylib",
            "--local",
            fetched.to_str().unwrap(),
        ],
    );
    assert_eq!(code, 0);
    assert_eq!(done_payload(&events)["sha256"], HELLO_SHA256);
    assert_eq!(std::fs::read(&fetched).unwrap(), b"hello world");

    // put-tar from a manifest; the archive must be complete and readable.
    let root = dir.path().join("stage");
    write_file(&root.join("GameInfo.json"), b"{\"schemaVersion\":1}");
    write_file(&root.join("GamePack.dylib"), b"pack bytes");
    let manifest = dir.path().join("files.txt");
    write_file(&manifest, b"GameInfo.json\nGamePack.dylib\n");
    let (code, events, stderr) = run(
        &mock,
        &[
            "put-tar",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--manifest",
            manifest.to_str().unwrap(),
            "--root",
            root.to_str().unwrap(),
            "--dest",
            "Documents/stage.tar",
        ],
    );
    assert_eq!(code, 0, "put-tar failed: {stderr}");
    assert_eq!(done_payload(&events)["tarOk"], true);
    assert_eq!(done_payload(&events)["entries"], 2);

    let (code, events, _stderr) = run(
        &mock,
        &[
            "tar-ok",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--path",
            "Documents/stage.tar",
        ],
    );
    assert_eq!(code, 0);
    assert_eq!(done_payload(&events)["ok"], true);

    let (code, events, _stderr) = run(
        &mock,
        &[
            "mkdir",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--path",
            "Documents/Games/0004000000055D00/Saves",
        ],
    );
    assert_eq!(code, 0);
    assert_eq!(done_payload(&events)["created"], true);

    let (code, events, _stderr) = run(
        &mock,
        &[
            "rm",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--path",
            "Documents/stage.tar",
        ],
    );
    assert_eq!(code, 0);
    assert_eq!(done_payload(&events)["removed"], true);
}

#[test]
fn stable_error_codes_and_exit_codes() {
    let dir = tempdir();
    let mock = dir.path().join("mock");
    let local = dir.path().join("x.bin");
    write_file(&local, b"x");

    // Not installed app -> exit 5 / app_missing.
    let (code, events, stderr) = run(
        &mock,
        &[
            "put",
            "--bundle-id",
            "missing.app",
            "--local",
            local.to_str().unwrap(),
            "--remote",
            "Documents/x",
        ],
    );
    assert_eq!(code, 5, "stderr: {stderr}");
    assert_eq!(error_payload(&events)["error"]["code"], "app_missing");
    assert_eq!(error_payload(&events)["exitCode"], 5);

    let ipa = dir.path().join("Shell.ipa");
    write_file(&ipa, b"fake ipa");
    mock_install(&mock, &ipa, "com.kratos.3ds2apple");

    // Path traversal is rejected as invalid_argument / exit 2.
    let (code, events, _stderr) = run(
        &mock,
        &[
            "put",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--local",
            local.to_str().unwrap(),
            "--remote",
            "../../evil",
        ],
    );
    assert_eq!(code, 2);
    assert_eq!(error_payload(&events)["error"]["code"], "invalid_argument");

    // Missing remote file -> path_not_found / exit 7.
    let (code, events, _stderr) = run(
        &mock,
        &[
            "stat",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--path",
            "Documents/nope",
        ],
    );
    assert_eq!(code, 7);
    assert_eq!(error_payload(&events)["error"]["code"], "path_not_found");

    // Unknown device -> device_not_found / exit 3.
    let (code, events, _stderr) = run(
        &mock,
        &[
            "stat",
            "--bundle-id",
            "com.kratos.3ds2apple",
            "--udid",
            "nope",
            "--path",
            "Documents",
        ],
    );
    assert_eq!(code, 3);
    assert_eq!(error_payload(&events)["error"]["code"], "device_not_found");
}
