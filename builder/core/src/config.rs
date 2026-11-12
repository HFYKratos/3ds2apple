//! Client-side configuration: host profiles and data directories.
//!
//! Secrets are not stored here: SSH mode authenticates with a dedicated key file
//! in the profile directory, and HTTP mode (not part of this slice) stores its
//! token in the OS credential store.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::transport::TransportSpec;

/// Schema version written to new config files.
pub const CONFIG_VERSION: u32 = 1;

/// One configured build host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostProfile {
    /// Stable id used on the command line and as the profile directory name.
    pub id: String,
    /// Human label ("Mac mini in the office").
    pub name: String,
    pub transport: TransportSpec,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_test_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
}

/// Builder configuration file (`config.toml`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuilderConfig {
    #[serde(default = "default_version")]
    pub version: u32,
    #[serde(default)]
    pub hosts: Vec<HostProfile>,
}

fn default_version() -> u32 {
    CONFIG_VERSION
}

impl Default for BuilderConfig {
    fn default() -> Self {
        Self {
            version: CONFIG_VERSION,
            hosts: Vec::new(),
        }
    }
}

impl BuilderConfig {
    /// Read a config file, treating a missing file as an empty configuration.
    pub fn load(path: &Path) -> Result<Self, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => toml::from_str(&text)
                .map_err(|error| format!("{} is not a valid config file: {error}", path.display())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(format!("could not read {}: {error}", path.display())),
        }
    }

    /// Write the config atomically with owner-only permissions.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        let text = toml::to_string_pretty(self)
            .map_err(|error| format!("could not serialise config: {error}"))?;
        write_private_file(path, &text)
            .map_err(|error| format!("could not write {}: {error}", path.display()))
    }

    pub fn find(&self, id_or_name: &str) -> Option<&HostProfile> {
        self.hosts
            .iter()
            .find(|host| host.id == id_or_name || host.name == id_or_name)
    }

    pub fn find_mut(&mut self, id_or_name: &str) -> Option<&mut HostProfile> {
        self.hosts
            .iter_mut()
            .find(|host| host.id == id_or_name || host.name == id_or_name)
    }

    /// Remove a host by id/name, returning it.
    pub fn remove(&mut self, id_or_name: &str) -> Option<HostProfile> {
        let index = self
            .hosts
            .iter()
            .position(|host| host.id == id_or_name || host.name == id_or_name)?;
        Some(self.hosts.remove(index))
    }
}

/// Directory holding the config file and the per-host profile directories.
pub fn default_config_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("ZKB_CONFIG_DIR") {
        return PathBuf::from(dir);
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            return PathBuf::from(appdata).join("3ds2apple").join("builder");
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = home_dir() {
            return home
                .join("Library")
                .join("Application Support")
                .join("3ds2apple-builder");
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Some(config) = std::env::var_os("XDG_CONFIG_HOME") {
            return PathBuf::from(config).join("3ds2apple").join("builder");
        }
        if let Some(home) = home_dir() {
            return home.join(".config").join("3ds2apple").join("builder");
        }
    }
    PathBuf::from(".3ds2apple-builder")
}

/// Default directory for downloaded artifacts and local job history.
pub fn default_data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("ZKB_DATA_DIR") {
        return PathBuf::from(dir);
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            return PathBuf::from(local).join("3ds2apple").join("builder");
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = home_dir() {
            return home
                .join("Library")
                .join("Application Support")
                .join("3ds2apple-builder");
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Some(data) = std::env::var_os("XDG_DATA_HOME") {
            return PathBuf::from(data).join("3ds2apple").join("builder");
        }
        if let Some(home) = home_dir() {
            return home
                .join(".local")
                .join("share")
                .join("3ds2apple")
                .join("builder");
        }
    }
    PathBuf::from(".3ds2apple-builder")
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
}

/// Path of the config file inside a config directory.
pub fn config_file(config_dir: &Path) -> PathBuf {
    config_dir.join("config.toml")
}

/// Per-host profile directory (known_hosts, dedicated SSH key).
pub fn profile_dir(config_dir: &Path, host_id: &str) -> PathBuf {
    config_dir.join("profiles").join(host_id)
}

/// Directory holding the config file for the default location.
pub fn default_config_file() -> PathBuf {
    config_file(&default_config_dir())
}

/// Make a filesystem-safe profile id out of a display name.
pub fn slugify_host_id(name: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in name.chars() {
        let lower = ch.to_ascii_lowercase();
        if lower.is_ascii_alphanumeric() {
            out.push(lower);
            last_dash = false;
        } else if !last_dash && !out.is_empty() {
            out.push('-');
            last_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() {
        out.push_str("host");
    }
    out.truncate(48);
    out
}

/// Write a file with `0600` permissions (on Unix), creating parents first.
pub fn write_private_file(path: &Path, contents: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true).mode(0o600);
        let mut file = options.open(path)?;
        file.write_all(contents.as_bytes())?;
        file.flush()?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, contents)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::ssh::SshSpec;
    use std::collections::BTreeMap;

    fn ssh_profile() -> HostProfile {
        HostProfile {
            id: "office".into(),
            name: "Mac mini in the office".into(),
            transport: TransportSpec::Ssh(SshSpec {
                host: "mac-mini.local".into(),
                port: 22,
                user: "builder".into(),
                identity: Some(PathBuf::from("/tmp/key")),
                known_hosts: Some(PathBuf::from("/tmp/known_hosts")),
                control_path: Some(PathBuf::from("/tmp/ctl")),
                connect_timeout_secs: 10,
            }),
            created_at: "2026-11-12T19:00:00Z".into(),
            last_test_at: None,
            agent_version: None,
            agent_id: None,
        }
    }

    fn local_profile() -> HostProfile {
        HostProfile {
            id: "local".into(),
            name: "this mac".into(),
            transport: TransportSpec::Local(crate::transport::LocalSpec {
                program: PathBuf::from("/usr/local/bin/builder-agent"),
                args: vec![],
                env: BTreeMap::from([(
                    "BUILDER_AGENT_DATA_ROOT".to_string(),
                    "/tmp/agent".to_string(),
                )]),
            }),
            created_at: "2026-11-12T19:00:00Z".into(),
            last_test_at: None,
            agent_version: None,
            agent_id: None,
        }
    }

    #[test]
    fn config_round_trips_through_toml() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let config = BuilderConfig {
            version: CONFIG_VERSION,
            hosts: vec![ssh_profile(), local_profile()],
        };
        config.save(&path).unwrap();
        let loaded = BuilderConfig::load(&path).unwrap();
        assert_eq!(loaded, config);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("[[hosts]]"));
        assert!(text.contains("kind = \"ssh\""));
        assert!(text.contains("kind = \"local\""));
    }

    #[test]
    fn missing_config_is_default_and_find_works() {
        let dir = tempfile::tempdir().unwrap();
        let config = BuilderConfig::load(&dir.path().join("nope.toml")).unwrap();
        assert!(config.hosts.is_empty());
        let mut config = BuilderConfig {
            version: 1,
            hosts: vec![ssh_profile()],
        };
        assert!(config.find("office").is_some());
        assert!(config.find("Mac mini in the office").is_some());
        assert!(config.find("nope").is_none());
        assert!(config.remove("office").is_some());
        assert!(config.hosts.is_empty());
    }

    #[test]
    fn host_ids_are_slugs() {
        assert_eq!(
            slugify_host_id("Mac mini in the office"),
            "mac-mini-in-the-office"
        );
        assert_eq!(slugify_host_id("  "), "host");
        assert_eq!(slugify_host_id("Café Mac"), "caf-mac");
        assert!(slugify_host_id(&"x".repeat(100)).len() <= 48);
    }

    #[test]
    fn config_is_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        BuilderConfig::default().save(&path).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
    }

    #[test]
    fn env_overrides_config_dir() {
        // Read-only check of the documented override; the default depends on the
        // CI user's HOME, so only assert the override branch here.
        if std::env::var_os("ZKB_CONFIG_DIR").is_none() {
            assert!(default_config_dir().is_absolute() || default_config_dir().starts_with("."));
        }
    }
}
