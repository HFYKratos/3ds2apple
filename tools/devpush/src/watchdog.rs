//! Stall watchdog (default 90s).
//!
//! The AFC layer can block forever when the cable/Wi-Fi connection dies mid
//! transfer (observed in the field: progress frozen at 86% for 20 minutes).
//! A background thread aborts the process with exit code 6 / stall_timeout when
//! no payload progress happened for the configured timeout.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use serde_json::json;

static ALIVE_MS: AtomicU64 = AtomicU64::new(0);
static JSON_MODE: AtomicBool = AtomicBool::new(false);
static START: OnceLock<Instant> = OnceLock::new();
static COMMAND: OnceLock<String> = OnceLock::new();

pub fn now_ms() -> u64 {
    START.get_or_init(Instant::now).elapsed().as_millis() as u64
}

pub fn stalled(alive_ms: u64, now_ms: u64, limit: Duration) -> bool {
    now_ms.saturating_sub(alive_ms) > limit.as_millis() as u64
}

/// Start the watchdog. A zero timeout disables it. Only arm for commands that
/// talk to the device filesystem; install/uninstall are exempt because
/// installation_proxy can legitimately be silent for minutes.
pub fn arm(stall: Duration, json: bool, command: &str) {
    if stall.is_zero() {
        return;
    }
    JSON_MODE.store(json, Ordering::Relaxed);
    let _ = COMMAND.set(command.to_string());
    ALIVE_MS.store(now_ms(), Ordering::Relaxed);
    let limit = stall.as_millis() as u64;
    let _ = std::thread::Builder::new().name("devpush-watchdog".into()).spawn(move || loop {
        std::thread::sleep(Duration::from_millis(500));
        let alive = ALIVE_MS.load(Ordering::Relaxed);
        if stalled(alive, now_ms(), Duration::from_millis(limit)) {
            let seconds = stall.as_secs();
            let message = format!("no transfer progress for {seconds}s; the connection to the device probably dropped (cable/Wi-Fi, or the app was reinstalled)");
            if JSON_MODE.load(Ordering::Relaxed) {
                let command = COMMAND.get().map(String::as_str).unwrap_or("unknown");
                crate::output::emit_json_line(&json!({
                    "schema": "devpush/1",
                    "type": "error",
                    "command": command,
                    "ok": false,
                    "error": {
                        "code": "stall_timeout",
                        "message": message,
                        "hint": crate::error::ErrorCode::StallTimeout.hint(),
                    },
                    "exitCode": 6,
                }));
            }
            eprintln!("devpush: stall_timeout: {message}");
            std::process::exit(6);
        }
    });
}

/// Report transfer progress; resets the stall timer.
pub fn tick() {
    ALIVE_MS.store(now_ms(), Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stall_detection_uses_strict_timeout() {
        let limit = Duration::from_secs(90);
        assert!(!stalled(0, 90_000, limit));
        assert!(stalled(0, 90_001, limit));
        assert!(!stalled(89_000, 90_000, limit));
        assert!(stalled(89_000, 180_000, limit));
    }
}
