//! Persistent import/build queue (`<out>/aot-queue.json`).
//!
//! The queue is the desktop app's state: which ROM the user imported, what the
//! detected metadata was, and whether its AOT build finished. It is
//! deterministic (sorted by title ID, no timestamps) and lives in the
//! gitignored output directory, so re-importing the same ROMs is idempotent.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::{PackError, Result};
use crate::gameinfo::{GameInfo, PackageState};
use crate::rom::RomInfo;

/// Queue file name under the output root.
pub const QUEUE_FILE: &str = "aot-queue.json";
/// Queue schema version.
pub const QUEUE_SCHEMA_VERSION: u32 = 1;

/// State of one queued build.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QueueState {
    /// Imported; the AOT pack is not built yet.
    Queued,
    /// The pack is built and recorded in `GameInfo.json`.
    Built,
    /// The last build attempt failed (see `error`).
    Failed,
}

/// One imported ROM waiting for or holding an AOT build.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueEntry {
    /// Canonical title ID (also the package directory name).
    #[serde(rename = "titleID")]
    pub title_id: String,
    /// ROM path the user selected (local; used by the macOS build scripts).
    #[serde(rename = "romPath")]
    pub rom_path: String,
    /// Display name recorded at import.
    #[serde(rename = "displayName")]
    pub display_name: String,
    /// Product code (may be empty).
    #[serde(rename = "productCode")]
    pub product_code: String,
    /// Build slug for the scripts (`[A-Za-z0-9._-]`), e.g. `pokemon-y-00055e00`.
    pub slug: String,
    /// AOT version to write into the catalogue.
    #[serde(rename = "aotVersion")]
    pub aot_version: u32,
    /// Current state.
    pub state: QueueState,
    /// Last build failure message (for `state: failed`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl QueueEntry {
    /// Entry for a freshly imported ROM.
    pub fn from_import(info: &GameInfo, rom: &RomInfo) -> Self {
        Self {
            title_id: info.title_id.clone(),
            rom_path: rom.path.display().to_string(),
            display_name: info.display_name.clone(),
            product_code: info.product_code.clone(),
            slug: crate::plan::slug_for(&info.display_name, &info.title_id),
            aot_version: info.aot_version,
            state: if info.pack.is_some() {
                QueueState::Built
            } else {
                QueueState::Queued
            },
            error: None,
        }
    }

    /// Entry reconstructed from an existing package (manual/adopted packs).
    pub fn from_package(info: &GameInfo) -> Self {
        Self {
            title_id: info.title_id.clone(),
            rom_path: info
                .rom
                .as_ref()
                .and_then(|rom| rom.path.clone())
                .unwrap_or_default(),
            display_name: info.display_name.clone(),
            product_code: info.product_code.clone(),
            slug: crate::plan::slug_for(&info.display_name, &info.title_id),
            aot_version: info.aot_version,
            state: if info.pack.is_some() {
                QueueState::Built
            } else {
                QueueState::Queued
            },
            error: None,
        }
    }

    /// Queue state derived from a package summary.
    pub fn state_from_package(state: PackageState) -> QueueState {
        match state {
            PackageState::Built => QueueState::Built,
            PackageState::Broken | PackageState::Queued => QueueState::Queued,
        }
    }
}

/// The whole queue document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Queue {
    /// Queue schema version.
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    /// Entries, sorted by title ID when saved.
    pub entries: Vec<QueueEntry>,
}

impl Default for Queue {
    fn default() -> Self {
        Self {
            schema_version: QUEUE_SCHEMA_VERSION,
            entries: Vec::new(),
        }
    }
}

impl Queue {
    /// Load `<root>/aot-queue.json`; a missing file is an empty queue.
    pub fn load(root: &Path) -> Result<Self> {
        let path = root.join(QUEUE_FILE);
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self::default())
            }
            Err(error) => return Err(PackError::io(&path, error)),
        };
        let queue: Self =
            serde_json::from_str(&text).map_err(|error| PackError::json(&path, error))?;
        queue.validate()?;
        Ok(queue)
    }

    /// Validate schema, canonical unique title IDs, slug shape and state.
    pub fn validate(&self) -> Result<()> {
        if self.schema_version != QUEUE_SCHEMA_VERSION {
            return Err(PackError::invalid(format!(
                "unsupported queue schemaVersion {} (expected {})",
                self.schema_version, QUEUE_SCHEMA_VERSION
            )));
        }
        let mut seen = std::collections::BTreeSet::new();
        for entry in &self.entries {
            if !seen.insert(entry.title_id.clone()) {
                return Err(PackError::invalid(format!(
                    "duplicate titleID {} in the queue",
                    entry.title_id
                )));
            }
            if crate::rom::canonical_title_id(&entry.title_id)? != entry.title_id {
                return Err(PackError::invalid(format!(
                    "queue titleID {} is not canonical",
                    entry.title_id
                )));
            }
            if !crate::plan::is_valid_slug(&entry.slug) {
                return Err(PackError::invalid(format!(
                    "queue entry {} has an invalid build slug '{}'",
                    entry.title_id, entry.slug
                )));
            }
            if entry.display_name.trim().is_empty() {
                return Err(PackError::invalid(format!(
                    "queue entry {} has an empty display name",
                    entry.title_id
                )));
            }
        }
        Ok(())
    }

    /// Save the queue deterministically (sorted by title ID, fixed JSON).
    pub fn save(&mut self, root: &Path) -> Result<()> {
        self.entries.sort_by(|a, b| a.title_id.cmp(&b.title_id));
        self.validate()?;
        std::fs::create_dir_all(root).map_err(|error| PackError::io(root, error))?;
        let mut text = serde_json::to_string_pretty(self)?;
        text.push('\n');
        let path = root.join(QUEUE_FILE);
        std::fs::write(&path, text).map_err(|error| PackError::io(&path, error))?;
        Ok(())
    }

    /// Insert or replace an entry by title ID.
    pub fn upsert(&mut self, entry: QueueEntry) {
        match self
            .entries
            .iter_mut()
            .find(|current| current.title_id == entry.title_id)
        {
            Some(current) => *current = entry,
            None => self.entries.push(entry),
        }
    }

    /// Look an entry up by canonical title ID.
    pub fn get(&self, title_id: &str) -> Option<&QueueEntry> {
        self.entries.iter().find(|entry| entry.title_id == title_id)
    }

    /// Remove an entry; returns whether it existed.
    pub fn remove(&mut self, title_id: &str) -> bool {
        let before = self.entries.len();
        self.entries.retain(|entry| entry.title_id != title_id);
        before != self.entries.len()
    }

    /// Set the state (and clear the error on non-failed states).
    pub fn set_state(&mut self, title_id: &str, state: QueueState, error: Option<String>) {
        if let Some(entry) = self
            .entries
            .iter_mut()
            .find(|entry| entry.title_id == title_id)
        {
            entry.state = state;
            entry.error = if state == QueueState::Failed {
                error
            } else {
                None
            };
        }
    }

    /// Entries still waiting for a build, sorted by title ID.
    pub fn queued(&self) -> Vec<&QueueEntry> {
        let mut entries: Vec<&QueueEntry> = self
            .entries
            .iter()
            .filter(|entry| entry.state == QueueState::Queued)
            .collect();
        entries.sort_by(|a, b| a.title_id.cmp(&b.title_id));
        entries
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rom::test_support::{synthetic_ncsd, write_rom};
    use tempfile::tempdir;

    fn entry(title_id: u64, name: &str) -> QueueEntry {
        let id = crate::rom::format_title_id(title_id);
        QueueEntry {
            title_id: id.clone(),
            rom_path: format!("/roms/{name}.cci"),
            display_name: name.to_string(),
            product_code: String::new(),
            slug: crate::plan::slug_for(name, &id),
            aot_version: 1,
            state: QueueState::Queued,
            error: None,
        }
    }

    #[test]
    fn missing_file_is_an_empty_queue() {
        let temp = tempdir().unwrap();
        let queue = Queue::load(temp.path()).unwrap();
        assert!(queue.entries.is_empty());
        assert_eq!(queue.schema_version, QUEUE_SCHEMA_VERSION);
    }

    #[test]
    fn saves_sorted_and_deterministic() {
        let temp = tempdir().unwrap();
        let mut queue = Queue::default();
        queue.upsert(entry(0x0004_0000_0011_C500, "alpha"));
        queue.upsert(entry(0x0004_0000_0005_5E00, "y"));
        queue.save(temp.path()).unwrap();
        let first = std::fs::read_to_string(temp.path().join(QUEUE_FILE)).unwrap();
        let loaded = Queue::load(temp.path()).unwrap();
        assert_eq!(loaded.entries[0].title_id, "0004000000055E00");
        assert_eq!(loaded.entries[1].title_id, "000400000011C500");
        let mut again = loaded.clone();
        again.save(temp.path()).unwrap();
        let second = std::fs::read_to_string(temp.path().join(QUEUE_FILE)).unwrap();
        assert_eq!(first, second);
        assert!(first.ends_with('\n'));
    }

    #[test]
    fn upsert_remove_and_states() {
        let mut queue = Queue::default();
        queue.upsert(entry(0x0004_0000_0005_5E00, "y"));
        queue.set_state("0004000000055E00", QueueState::Failed, Some("boom".into()));
        assert_eq!(
            queue.get("0004000000055E00").unwrap().state,
            QueueState::Failed
        );
        queue.set_state("0004000000055E00", QueueState::Built, None);
        assert!(queue.get("0004000000055E00").unwrap().error.is_none());
        assert!(queue.remove("0004000000055E00"));
        assert!(!queue.remove("0004000000055E00"));
    }

    #[test]
    fn from_import_uses_detected_metadata() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("Pokemon Y.cci");
        write_rom(
            &path,
            &synthetic_ncsd(0x0004_0000_0005_5E00, "CTR-P-EK2A", 1),
        );
        let rom = crate::rom::detect_rom(&path).unwrap();
        let info = GameInfo::new(&rom, "Pokémon Y", "CTR-P-EK2A", 1).unwrap();
        let entry = QueueEntry::from_import(&info, &rom);
        assert_eq!(entry.slug, "pokemon-y-00055e00");
        assert_eq!(entry.state, QueueState::Queued);
        assert_eq!(entry.rom_path, path.display().to_string());
    }

    #[test]
    fn rejects_malformed_queue_files() {
        let temp = tempdir().unwrap();
        std::fs::write(
            temp.path().join(QUEUE_FILE),
            "{\"schemaVersion\":2,\"entries\":[]}",
        )
        .unwrap();
        assert!(Queue::load(temp.path()).is_err());
    }
}
