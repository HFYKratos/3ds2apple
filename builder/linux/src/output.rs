//! Output helpers: human-readable text, or JSON for scripting.
//!
//! With `--json`, stdout carries exactly one JSON object (or the NDJSON stream
//! from `zkb`) and everything else goes to stderr, mirroring the shared CLI
//! conventions.

use serde::Serialize;

/// Output sink selected by the global `--json` flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Printer {
    pub json: bool,
}

impl Printer {
    pub fn new(json: bool) -> Self {
        Self { json }
    }

    /// Human result line (stdout; suppressed in JSON mode).
    pub fn line(&self, message: impl AsRef<str>) {
        if !self.json {
            println!("{}", message.as_ref());
        }
    }

    /// Progress/diagnostic line (stderr; suppressed in JSON mode).
    pub fn progress(&self, message: impl AsRef<str>) {
        if !self.json {
            eprintln!("{}", message.as_ref());
        }
    }

    /// Warning shown in both modes.
    pub fn warn(&self, message: impl AsRef<str>) {
        eprintln!("warning: {}", message.as_ref());
    }

    /// Diagnostic that stays on stderr even in JSON mode (for summaries that
    /// must not pollute a machine-readable stdout stream).
    pub fn diagnostic(&self, message: impl AsRef<str>) {
        eprintln!("{}", message.as_ref());
    }

    /// Empty human line between blocks (no-op in JSON mode).
    pub fn blank(&self) {
        if !self.json {
            println!();
        }
    }

    /// Emit one JSON document on stdout in JSON mode.
    pub fn json<T: Serialize>(&self, value: &T) {
        if self.json {
            match serde_json::to_string_pretty(value) {
                Ok(text) => println!("{text}"),
                Err(error) => eprintln!("warning: could not serialise the report: {error}"),
            }
        }
    }
}

/// Human-readable byte count ("3.8 GiB").
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_formatting_is_stable() {
        assert_eq!(format_bytes(0), "0 B");
        assert_eq!(format_bytes(1023), "1023 B");
        assert_eq!(format_bytes(2048), "2.0 KiB");
        assert_eq!(format_bytes(3 * 1024 * 1024 * 1024), "3.0 GiB");
    }
}
