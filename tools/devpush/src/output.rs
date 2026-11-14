//! Machine-readable NDJSON events (--json) and human progress output.

use std::io::Write;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::error::DevpushError;
use crate::watchdog;

pub const SCHEMA: &str = "devpush/1";

/// Write one NDJSON object to stdout and flush. Only called in --json mode.
pub fn emit_json_line(value: &Value) {
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    if serde_json::to_writer(&mut lock, value).is_ok() {
        let _ = lock.write_all(b"\n");
        let _ = lock.flush();
    }
}

pub fn merge(mut base: Value, extra: Value) -> Value {
    if let (Some(base_obj), Some(extra_obj)) = (base.as_object_mut(), extra.as_object()) {
        for (k, v) in extra_obj {
            base_obj.insert(k.clone(), v.clone());
        }
    }
    base
}

#[derive(Clone, Copy, Debug)]
pub struct Out {
    pub json: bool,
}

impl Out {
    pub fn new(json: bool) -> Self {
        Self { json }
    }

    pub fn begin(&self, command: &str, fields: Value) {
        if self.json {
            let base = json!({"schema": SCHEMA, "type": "begin", "command": command});
            emit_json_line(&merge(base, fields));
        }
    }

    pub fn done(&self, command: &str, payload: Value, human: &str) {
        if self.json {
            let base = json!({"schema": SCHEMA, "type": "done", "command": command, "ok": true});
            emit_json_line(&merge(base, payload));
        } else {
            println!("{human}");
        }
    }

    pub fn warn(&self, command: &str, code: &str, message: &str) {
        if self.json {
            emit_json_line(&json!({
                "schema": SCHEMA, "type": "warn", "command": command,
                "warn": {"code": code, "message": message}
            }));
        } else {
            eprintln!("devpush: warning: {code}: {message}");
        }
    }

    pub fn error(&self, command: &str, err: &DevpushError) {
        if self.json {
            emit_json_line(&json!({
                "schema": SCHEMA, "type": "error", "command": command, "ok": false,
                "error": err.to_json(),
                "exitCode": err.code.exit_code(),
            }));
        }
        eprintln!("devpush: {}: {}", err.code.as_str(), err.message);
        if let Some(hint) = &err.detail {
            eprintln!("devpush: hint: {hint}");
        }
    }
}

/// Byte-progress reporter for put/get/put-tar. Updates the stall watchdog on
/// every chunk and emits throttled progress events.
pub struct Reporter {
    command: &'static str,
    json: bool,
    file: Option<String>,
    total: Option<u64>,
    sent: u64,
    last_emit: Instant,
    interval: Duration,
    emitted_human: bool,
}

impl Reporter {
    pub fn new(command: &'static str, json: bool) -> Self {
        let interval_ms = std::env::var("DEVPUSH_PROGRESS_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|v| *v >= 50)
            .unwrap_or(1000);
        Self {
            command,
            json,
            file: None,
            total: None,
            sent: 0,
            last_emit: Instant::now(),
            interval: Duration::from_millis(interval_ms),
            emitted_human: false,
        }
    }

    pub fn set_file(&mut self, file: impl Into<String>) {
        self.file = Some(file.into());
    }

    pub fn set_total(&mut self, total: Option<u64>) {
        self.total = total;
    }

    fn percent(&self) -> Option<f64> {
        self.total
            .filter(|t| *t > 0)
            .map(|t| (self.sent as f64 / t as f64 * 100.0).min(100.0))
    }

    fn emit(&mut self) {
        self.last_emit = Instant::now();
        if self.json {
            emit_json_line(&json!({
                "schema": SCHEMA,
                "type": "progress",
                "command": self.command,
                "file": self.file,
                "bytesSent": self.sent,
                "bytesTotal": self.total,
                "percent": self.percent(),
            }));
        } else {
            match (self.total, self.percent()) {
                (Some(total), Some(pct)) => {
                    eprint!(
                        "\r{} {}/{} bytes ({pct:.1}%)",
                        self.file.clone().unwrap_or_default(),
                        self.sent,
                        total
                    )
                }
                _ => eprint!(
                    "\r{} {} bytes",
                    self.file.clone().unwrap_or_default(),
                    self.sent
                ),
            }
            self.emitted_human = true;
        }
    }

    /// Record progress after `sent` payload bytes were accepted by the device.
    pub fn tick(&mut self, sent: u64) {
        watchdog::tick();
        self.sent = sent;
        if self.last_emit.elapsed() >= self.interval {
            self.emit();
        }
    }

    /// Force a final progress event and close the human progress line.
    pub fn finish(&mut self) {
        if self.sent > 0 {
            self.emit();
        }
        if !self.json && self.emitted_human {
            eprintln!();
        }
    }
}
