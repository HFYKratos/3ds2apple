//! Log redaction for exported build logs.
//!
//! The Agent never logs ROM contents, key material or tokens. Paths and the ROM
//! file name can legitimately appear in script output; the redacted export
//! offered for bug reports removes them and any configured secret.

/// Replaces configured secrets and absolute paths before a log leaves the
/// Builder's local machine.
#[derive(Debug, Clone, Default)]
pub struct Redactor {
    secrets: Vec<String>,
}

impl Redactor {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a literal string that must never appear in exported logs.
    pub fn add_secret(&mut self, secret: impl Into<String>) {
        let secret = secret.into();
        if !secret.is_empty() {
            self.secrets.push(secret);
            // Longer secrets first so a token that contains a shorter one is
            // still replaced as a whole.
            self.secrets
                .sort_by_key(|value| std::cmp::Reverse(value.len()));
        }
    }

    /// Build a redactor from a list of secrets.
    pub fn with_secrets<I, S>(secrets: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut redactor = Self::new();
        for secret in secrets {
            redactor.add_secret(secret);
        }
        redactor
    }

    /// Redact one line: configured secrets, ROM file names passed in, and the
    /// user's home directory prefix.
    pub fn line(&self, line: &str, rom_names: &[String]) -> String {
        let mut out = line.to_string();
        for secret in &self.secrets {
            out = out.replace(secret.as_str(), "<redacted>");
        }
        for name in rom_names {
            if name.len() >= 3 {
                out = out.replace(name.as_str(), "<rom-file>");
            }
        }
        if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
            let home = home.to_string_lossy().to_string();
            if home.len() > 1 && out.contains(&home) {
                out = out.replace(&home, "~");
            }
        }
        out
    }

    /// Redact a batch of lines.
    pub fn lines(&self, lines: &[String], rom_names: &[String]) -> Vec<String> {
        lines
            .iter()
            .map(|line| self.line(line, rom_names))
            .collect()
    }

    pub fn is_empty(&self) -> bool {
        self.secrets.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaces_secrets_longest_first() {
        let redactor = Redactor::with_secrets(["abc", "abcdef", "topsecret"]);
        assert_eq!(
            redactor.line("token=abcdef end", &[]),
            "token=<redacted> end"
        );
        assert_eq!(redactor.line("abc", &[]), "<redacted>");
        assert_eq!(redactor.line("nothing here", &[]), "nothing here");
    }

    #[test]
    fn replaces_rom_file_names() {
        let redactor = Redactor::new();
        let line = "[build-recomp] reading /Users/builder/ROM/Pokemon Y.cci";
        let redacted = redactor.line(line, &["Pokemon Y.cci".to_string()]);
        assert!(!redacted.contains("Pokemon Y.cci"));
        assert!(redacted.contains("<rom-file>"));
    }

    #[test]
    fn home_prefix_is_shortened() {
        if let Some(home) = std::env::var_os("HOME") {
            let home = home.to_string_lossy().to_string();
            if home.len() > 1 {
                let redactor = Redactor::new();
                let line = format!("path {home}/src/3ds2apple");
                assert_eq!(redactor.line(&line, &[]), "path ~/src/3ds2apple");
            }
        }
    }
}
