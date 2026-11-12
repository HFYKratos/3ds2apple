//! Agent configuration persisted at `<data root>/config.toml`.
//!
//! `init` writes it; `serve` and `ssh-dispatch` read it. It never contains a
//! token in clear text: the HTTP binding (not enabled in this slice) stores only
//! `sha256(token)` here.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::util;

/// Config schema version.
pub const CONFIG_VERSION: u32 = 1;

/// Default retention for job metadata and artifacts (7 days).
pub const DEFAULT_RETENTION_HOURS: u64 = 168;

/// Default maximum input size (8 GiB).
pub const DEFAULT_MAX_INPUT_BYTES: u64 = 8 * 1024 * 1024 * 1024;

/// Agent behaviour and limits.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    #[serde(default = "default_version")]
    pub version: u32,
    #[serde(default)]
    pub agent_id: String,
    /// Source checkout the build scripts run in. Required for real builds.
    #[serde(default)]
    pub checkout: Option<PathBuf>,
    /// Run the scripted fake build instead of the real pipeline (Linux tests).
    #[serde(default)]
    pub fake_build: bool,
    /// Fake build plan: `success`, `fail-recompiling`, `fail-packaging`,
    /// `slow`, `corrupt-artifact`.
    #[serde(default = "default_fake_plan")]
    pub fake_plan: String,
    #[serde(default = "default_max_queued")]
    pub max_queued_jobs: u32,
    #[serde(default = "default_max_concurrent")]
    pub max_concurrent_builds: u32,
    #[serde(default = "default_max_input")]
    pub max_input_bytes: u64,
    #[serde(default)]
    pub allow_source_mismatch: bool,
    #[serde(default)]
    pub allow_dirty: bool,
    /// MoltenVK framework passed to the packaging script as
    /// `MOLTENVK_FRAMEWORK`; provisioned separately, never committed.
    #[serde(default)]
    pub moltenvk_framework: Option<PathBuf>,
    #[serde(default = "default_retention")]
    pub artifact_retention_hours: u64,
    #[serde(default = "default_retention")]
    pub job_retention_hours: u64,
    /// Reserved for the optional HTTP binding: `sha256(token)` in hex.
    #[serde(default)]
    pub token_sha256: Option<String>,
    /// Allow `keep_input: true` jobs (default yes, but the client warns).
    #[serde(default = "default_true")]
    pub keep_input_allowed: bool,
}

fn default_version() -> u32 {
    CONFIG_VERSION
}
fn default_fake_plan() -> String {
    "success".to_string()
}
fn default_max_queued() -> u32 {
    4
}
fn default_max_concurrent() -> u32 {
    1
}
fn default_max_input() -> u64 {
    DEFAULT_MAX_INPUT_BYTES
}
fn default_retention() -> u64 {
    DEFAULT_RETENTION_HOURS
}
fn default_true() -> bool {
    true
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            version: CONFIG_VERSION,
            agent_id: util::hostname(),
            checkout: None,
            fake_build: false,
            fake_plan: default_fake_plan(),
            max_queued_jobs: default_max_queued(),
            max_concurrent_builds: default_max_concurrent(),
            max_input_bytes: default_max_input(),
            allow_source_mismatch: false,
            allow_dirty: false,
            moltenvk_framework: None,
            artifact_retention_hours: default_retention(),
            job_retention_hours: default_retention(),
            token_sha256: None,
            keep_input_allowed: true,
        }
    }
}

impl AgentConfig {
    /// Effective advertised limits.
    pub fn limits(&self) -> builder_core::protocol::model::Limits {
        builder_core::protocol::model::Limits {
            max_input_bytes: self.max_input_bytes,
            max_queued_jobs: self.max_queued_jobs,
            max_concurrent_builds: self.max_concurrent_builds,
            artifact_retention_hours: self.artifact_retention_hours,
            job_retention_hours: self.job_retention_hours,
        }
    }

    /// Validate configuration before the Agent starts.
    pub fn validate(&self) -> Result<(), String> {
        if self.max_concurrent_builds == 0 {
            return Err("max_concurrent_builds must be at least 1".to_string());
        }
        if self.max_concurrent_builds > 1 {
            return Err(
                "max_concurrent_builds > 1 is not supported by this release (one build slot)"
                    .to_string(),
            );
        }
        if self.max_input_bytes == 0 {
            return Err("max_input_bytes must be positive".to_string());
        }
        if crate::fake::FakePlan::parse(&self.fake_plan).is_none() {
            return Err(format!(
                "unknown fake build plan {:?} (expected success, fail-recompiling, fail-packaging, slow or corrupt-artifact)",
                self.fake_plan
            ));
        }
        if !self.fake_build && self.checkout.is_none() {
            return Err(
                "a real build needs --checkout pointing at the 3ds2apple checkout".to_string(),
            );
        }
        Ok(())
    }
}

/// Config file path inside a data root.
pub fn config_path(data_root: &Path) -> PathBuf {
    data_root.join("config.toml")
}

/// Load `<data root>/config.toml`, or defaults when it does not exist.
pub fn load(data_root: &Path) -> Result<AgentConfig, String> {
    let path = config_path(data_root);
    match std::fs::read_to_string(&path) {
        Ok(text) => toml::from_str(&text)
            .map_err(|error| format!("{} is not a valid config file: {error}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(AgentConfig::default()),
        Err(error) => Err(format!("could not read {}: {error}", path.display())),
    }
}

/// Persist the config (`0600`).
pub fn save(data_root: &Path, config: &AgentConfig) -> Result<(), String> {
    util::ensure_private_dir(data_root).map_err(|error| error.to_string())?;
    let text = toml::to_string_pretty(config)
        .map_err(|error| format!("could not serialise config: {error}"))?;
    let path = config_path(data_root);
    util::write_atomic(&path, text.as_bytes())
        .map_err(|error| format!("could not write {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> AgentConfig {
        AgentConfig {
            checkout: Some(PathBuf::from("/Users/builder/src/3ds2apple")),
            agent_id: "mac-mini".to_string(),
            ..AgentConfig::default()
        }
    }

    #[test]
    fn round_trips_and_stays_private() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config();
        save(dir.path(), &cfg).unwrap();
        let loaded = load(dir.path()).unwrap();
        assert_eq!(loaded.agent_id, "mac-mini");
        assert_eq!(loaded.checkout, cfg.checkout);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(config_path(dir.path()))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600);
        }
    }

    #[test]
    fn missing_config_uses_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = load(dir.path()).unwrap();
        assert!(!cfg.fake_build);
        assert_eq!(cfg.max_concurrent_builds, 1);
        assert_eq!(cfg.max_queued_jobs, 4);
    }

    #[test]
    fn validation_requires_checkout_for_real_builds() {
        let mut cfg = AgentConfig {
            checkout: None,
            fake_build: false,
            ..AgentConfig::default()
        };
        assert!(cfg.validate().is_err());
        cfg.fake_build = true;
        assert!(cfg.validate().is_ok());
        cfg.max_concurrent_builds = 0;
        assert!(cfg.validate().is_err());
        cfg.max_concurrent_builds = 2;
        assert!(cfg.validate().is_err());
        cfg.max_concurrent_builds = 1;
        cfg.fake_plan = "nonsense".into();
        assert!(cfg.validate().is_err());
    }
}
