//! Output handling: human-readable text by default, NDJSON with `--json`.
//!
//! In JSON mode stdout carries protocol-shaped objects only; diagnostics go to
//! stderr. Human mode prints progress to stderr and results to stdout.

use builder_core::protocol::model::{EventKind, JobEvent};

/// Prints CLI output in the selected mode.
#[derive(Debug, Clone, Copy)]
pub struct Printer {
    pub json: bool,
}

impl Printer {
    pub fn new(json: bool) -> Self {
        Self { json }
    }

    /// Progress/diagnostic line (stderr, hidden in JSON mode where stdout is the
    /// contract).
    pub fn progress(&self, message: impl AsRef<str>) {
        if !self.json {
            eprintln!("{}", message.as_ref());
        }
    }

    /// Human result line (stdout; suppressed in JSON mode).
    pub fn line(&self, message: impl AsRef<str>) {
        if !self.json {
            println!("{}", message.as_ref());
        }
    }

    /// Emit a job event: NDJSON in JSON mode, a readable line otherwise.
    pub fn event(&self, event: &JobEvent) {
        if self.json {
            if let Ok(line) = serde_json::to_string(event) {
                println!("{line}");
            }
            return;
        }
        self.human_event(event);
    }

    fn human_event(&self, event: &JobEvent) {
        match event.kind {
            EventKind::Log => {
                // Long lines arrive in parts; print only complete lines here to
                // keep the terminal readable.
                let complete = match (event.line_part, event.line_parts) {
                    (Some(part), Some(parts)) => part == parts,
                    _ => true,
                };
                if !complete {
                    return;
                }
                let Some(line) = &event.line else { return };
                if line.trim().is_empty() {
                    return;
                }
                println!("{line}");
            }
            EventKind::State => {
                if let Some(state) = event.state {
                    match (state, event.stage) {
                        (builder_core::protocol::model::JobState::Running, Some(stage)) => {
                            println!("== {}", stage.label());
                        }
                        _ => println!("== job {state}"),
                    }
                }
            }
            EventKind::Warning => {
                if let Some(message) = &event.message {
                    println!("warning: {message}");
                }
            }
            EventKind::Artifact => {
                if let Some(artifact) = &event.artifact {
                    println!(
                        "artifact: {} ({} bytes, sha256 {})",
                        artifact.name, artifact.bytes, artifact.sha256
                    );
                }
            }
            EventKind::End | EventKind::Heartbeat => {}
        }
    }

    /// Emit a final machine-readable object in JSON mode.
    pub fn json_result<T: serde::Serialize>(&self, value: &T) {
        if self.json {
            if let Ok(line) = serde_json::to_string(value) {
                println!("{line}");
            }
        }
    }
}

/// Human-readable byte count used by progress lines.
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}
