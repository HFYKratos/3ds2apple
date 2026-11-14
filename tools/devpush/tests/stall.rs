//! The stall watchdog must abort instead of hanging forever when the device
//! connection goes silent (field report: progress frozen at 86% for 20 minutes).

use std::io::Read;
use std::net::TcpListener;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

#[test]
fn silent_device_service_times_out_with_stall_timeout() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    thread::spawn(move || {
        // Accept and hold connections without ever replying: a dead usbmuxd.
        let _held: Vec<_> = listener.incoming().take(4).collect();
        thread::sleep(Duration::from_secs(60));
    });

    let started = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_devpush"))
        .args(["--stall-seconds", "2", "--json", "devices"])
        .env("USBMUXD_SOCKET_ADDRESS", format!("127.0.0.1:{port}"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn devpush");

    let status = loop {
        if let Some(status) = child.try_wait().expect("try_wait") {
            break status;
        }
        if started.elapsed() > Duration::from_secs(25) {
            child.kill().ok();
            panic!("devpush hung without hitting the stall watchdog");
        }
        thread::sleep(Duration::from_millis(100));
    };

    let mut stdout = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut stdout)
        .unwrap();
    let mut stderr = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();

    assert_eq!(status.code(), Some(6), "stderr: {stderr}");
    assert!(
        started.elapsed() >= Duration::from_secs(2),
        "exited before the stall timeout"
    );
    let last = stdout
        .lines()
        .rfind(|line| !line.trim().is_empty())
        .expect("a JSON error line");
    let event: serde_json::Value = serde_json::from_str(last).expect("JSON line");
    assert_eq!(event["type"], "error");
    assert_eq!(event["error"]["code"], "stall_timeout");
    assert_eq!(event["exitCode"], 6);
    assert!(stderr.contains("stall_timeout"), "stderr: {stderr}");
}
