//! `GameCatalog.json` generation for one shell carrying several AOT game packs.
//!
//! Schema (schemaVersion 1, additive to the single-game catalog the scripts
//! already write; see docs/desktop-aot.md):
//!
//! ```json
//! {"schemaVersion":1,"games":[
//!   {"titleID":"0004000000055E00","displayName":"Pokémon Y",
//!    "productCode":"CTR-P-EK2A","packFile":"Frameworks/GamePack-0004000000055E00.dylib",
//!    "aot":true,"aotVersion":1,"notes":""}]}
//! ```
//!
//! Rules enforced here (and by `scripts/lib/game-catalog.sh`):
//!
//! - games are sorted by title ID and unique: allocation is deterministic;
//! - `titleID` is 16 upper-case hex digits;
//! - `packFile` is the app-bundle-relative dylib path for exactly that title;
//! - `aot` is true and `aotVersion` >= 1 (a catalogue entry means "AOT built");
//! - the file is compact one-line JSON + newline, like the existing catalogs.
//!
//! The `packFile` field is the new, additive part that the AOT shell task must
//! read to load several packs; the current shell ignores unknown keys, so a
//! multi-game IPA is only meaningful once that task lands (see the gaps section
//! in docs/desktop-aot.md).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{PackError, Result};
use crate::gameinfo::{GameInfo, PackFormat};

/// Directory inside the app bundle that carries the per-game packs.
pub const FRAMEWORKS_DIR: &str = "Frameworks";

/// One game entry in `GameCatalog.json` (schema 2; see docs/aot-first.md §7.1
/// and `ios/app/Sources/GameCatalog.swift`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogGame {
    /// Canonical title ID (16 upper-case hex digits).
    #[serde(rename = "titleID")]
    pub title_id: String,
    /// Display name shown on the library card.
    #[serde(rename = "displayName")]
    pub display_name: String,
    /// Product code (may be empty).
    #[serde(rename = "productCode")]
    pub product_code: String,
    /// Whether an AOT pack is available for this title.
    pub aot: bool,
    /// AOT pack version.
    #[serde(rename = "aotVersion")]
    pub aot_version: u32,
    /// App-bundle-relative pack path, `Frameworks/GamePack-<TITLE_ID>.dylib`.
    /// Empty for a legacy schema-1 entry whose AOT code is statically linked.
    #[serde(rename = "packFile", default)]
    pub pack_file: String,
    /// GamePack C ABI version the pack implements (host ABI, currently 1).
    #[serde(rename = "packABIVersion", default = "default_pack_abi_version")]
    pub pack_abi_version: u32,
    /// Optional override of the registration symbol (default
    /// `zk_gamepack_register` when absent).
    #[serde(
        rename = "registrationSymbol",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub registration_symbol: Option<String>,
    /// Optional bundle-relative cover image, `Covers/<TITLE_ID>.png`.
    #[serde(rename = "coverFile", default, skip_serializing_if = "Option::is_none")]
    pub cover_file: Option<String>,
    /// Free-form note.
    #[serde(default)]
    pub notes: String,
}

fn default_pack_abi_version() -> u32 {
    crate::GAMEPACK_ABI_VERSION
}

/// The whole `GameCatalog.json` document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameCatalog {
    /// Schema version (currently 1).
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    /// Games, sorted by title ID.
    pub games: Vec<CatalogGame>,
}

/// `Frameworks/GamePack-<TITLE_ID>.dylib` (path inside the app bundle).
pub fn pack_relative_path(title_id: &str) -> String {
    format!("{FRAMEWORKS_DIR}/GamePack-{title_id}.dylib")
}

/// `GamePack-<TITLE_ID>.dylib` (file name inside `Frameworks/`).
pub fn pack_file_name(title_id: &str) -> String {
    format!("GamePack-{title_id}.dylib")
}

impl CatalogGame {
    /// Catalogue entry for a built package.
    pub fn from_game_info(info: &GameInfo) -> Result<Self> {
        info.validate()?;
        if info.pack.is_none() {
            return Err(PackError::invalid(format!(
                "{} ({}): package has no AOT pack yet; run the build first",
                info.display_name, info.title_id
            )));
        }
        Ok(Self {
            title_id: info.title_id.clone(),
            display_name: info.display_name.clone(),
            product_code: info.product_code.clone(),
            aot: true,
            aot_version: info.aot_version,
            pack_file: pack_relative_path(&info.title_id),
            pack_abi_version: crate::GAMEPACK_ABI_VERSION,
            registration_symbol: None,
            cover_file: None,
            notes: info.notes.clone(),
        })
    }
}

impl GameCatalog {
    /// Build the catalogue from built packages (input order is irrelevant: the
    /// result is sorted by title ID and duplicate title IDs are rejected).
    pub fn from_packages(packages: &[GameInfo]) -> Result<Self> {
        let mut games = Vec::with_capacity(packages.len());
        for package in packages {
            games.push(CatalogGame::from_game_info(package)?);
        }
        games.sort_by(|a, b| a.title_id.cmp(&b.title_id));
        let catalog = Self {
            schema_version: crate::CATALOG_SCHEMA_VERSION,
            games,
        };
        catalog.validate()?;
        Ok(catalog)
    }

    /// Validate schema, uniqueness, title IDs and pack paths.
    pub fn validate(&self) -> Result<()> {
        // Version 1 is the legacy statically-linked catalog; version 2 is what
        // this pipeline writes and what the AOT shell reads. Reject anything
        // newer than this pipeline understands instead of guessing.
        if !matches!(self.schema_version, 1 | 2) {
            return Err(PackError::invalid(format!(
                "unsupported catalogue schemaVersion {} (expected 1 or {})",
                self.schema_version,
                crate::CATALOG_SCHEMA_VERSION
            )));
        }
        let mut seen = std::collections::BTreeSet::new();
        let mut previous: Option<&str> = None;
        for game in &self.games {
            let canonical = crate::rom::canonical_title_id(&game.title_id)?;
            if canonical != game.title_id {
                return Err(PackError::invalid(format!(
                    "catalogue titleID {} is not canonical (expected {})",
                    game.title_id, canonical
                )));
            }
            if !seen.insert(game.title_id.clone()) {
                return Err(PackError::invalid(format!(
                    "duplicate titleID {} in the catalogue",
                    game.title_id
                )));
            }
            if let Some(previous) = previous {
                if previous >= game.title_id.as_str() {
                    return Err(PackError::invalid(
                        "catalogue games are not sorted by title ID",
                    ));
                }
            }
            previous = Some(&game.title_id);
            if game.display_name.trim().is_empty() || game.display_name.contains('\n') {
                return Err(PackError::invalid(format!(
                    "{}: displayName must be a non-empty single line",
                    game.title_id
                )));
            }
            if game.product_code.chars().count() > 32
                || !game
                    .product_code
                    .chars()
                    .all(|c| c.is_ascii_graphic() || c == ' ')
            {
                return Err(PackError::invalid(format!(
                    "{}: productCode must be printable ASCII (at most 32 characters)",
                    game.title_id
                )));
            }
            if !game.aot {
                return Err(PackError::invalid(format!(
                    "{}: catalogue entries from this pipeline are always AOT; aot=false is not supported",
                    game.title_id
                )));
            }
            if game.aot_version < 1 {
                return Err(PackError::invalid(format!(
                    "{}: aotVersion must be >= 1",
                    game.title_id
                )));
            }
            if game.pack_file.is_empty() {
                // Legacy schema-1 entries (statically linked single-game
                // builds) have no packFile. A schema-2 catalogue must name the
                // pack for every AOT game.
                if self.schema_version >= 2 {
                    return Err(PackError::invalid(format!(
                        "{}: a schema-2 AOT entry must list packFile '{}'",
                        game.title_id,
                        pack_relative_path(&game.title_id)
                    )));
                }
            } else if game.pack_file != pack_relative_path(&game.title_id) {
                return Err(PackError::invalid(format!(
                    "{}: packFile must be '{}' (got '{}')",
                    game.title_id,
                    pack_relative_path(&game.title_id),
                    game.pack_file
                )));
            }
            if game.pack_abi_version < 1 {
                return Err(PackError::invalid(format!(
                    "{}: packABIVersion must be >= 1 (got {})",
                    game.title_id, game.pack_abi_version
                )));
            }
            if let Some(symbol) = &game.registration_symbol {
                if symbol.is_empty()
                    || !symbol
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '_')
                {
                    return Err(PackError::invalid(format!(
                        "{}: registrationSymbol must be a C identifier (got {:?})",
                        game.title_id, symbol
                    )));
                }
            }
            if let Some(cover) = &game.cover_file {
                let expected = format!("Covers/{}.png", game.title_id);
                if cover != &expected {
                    return Err(PackError::invalid(format!(
                        "{}: coverFile must be '{}' (got '{}')",
                        game.title_id, expected, cover
                    )));
                }
            }
            if game.notes.chars().any(|c| c.is_control()) {
                return Err(PackError::invalid(format!(
                    "{}: notes must not contain control characters",
                    game.title_id
                )));
            }
        }
        Ok(())
    }

    /// Number of games in the catalogue.
    pub fn len(&self) -> usize {
        self.games.len()
    }

    /// Whether the catalogue is empty.
    pub fn is_empty(&self) -> bool {
        self.games.is_empty()
    }

    /// One-line human summary, e.g. `games=2; AOT: Pokémon Y (...); ...`.
    pub fn summary(&self) -> String {
        if self.games.is_empty() {
            return "games=0; no AOT games".to_string();
        }
        let joined = self
            .games
            .iter()
            .map(|game| format!("{} ({})", game.display_name, game.title_id))
            .collect::<Vec<_>>()
            .join("; ");
        format!("games={}; AOT: {}", self.games.len(), joined)
    }

    /// Compact deterministic JSON with a trailing newline (the format the build
    /// scripts and the shell already use).
    pub fn to_json(&self) -> Result<String> {
        self.validate()?;
        let mut text = serde_json::to_string(self)?;
        text.push('\n');
        Ok(text)
    }

    /// Parse and validate a catalogue from JSON.
    pub fn from_json(text: &str, source: &Path) -> Result<Self> {
        let catalog: Self = serde_json::from_str(text)
            .map_err(|error| PackError::json(source.to_path_buf(), error))?;
        catalog.validate()?;
        Ok(catalog)
    }

    /// Write the catalogue file, creating parent directories.
    pub fn write(&self, path: &Path) -> Result<PathBuf> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|error| PackError::io(parent, error))?;
        }
        std::fs::write(path, self.to_json()?).map_err(|error| PackError::io(path, error))?;
        Ok(path.to_path_buf())
    }

    /// Read a catalogue file.
    pub fn read(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path).map_err(|error| PackError::io(path, error))?;
        Self::from_json(&text, path)
    }

    /// Whether every package behind this catalogue is a `--fake` placeholder.
    pub fn all_placeholders(&self, packages: &[GameInfo]) -> bool {
        !packages.is_empty()
            && packages.iter().all(|package| {
                package
                    .pack
                    .as_ref()
                    .map(|pack| pack.format == PackFormat::Placeholder)
                    .unwrap_or(false)
            })
            && !self.games.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rom::test_support::{synthetic_ncsd, write_rom};
    use tempfile::tempdir;

    const GOLDEN: &str = include_str!("../tests/fixtures/catalog-multi.json");

    fn built_package(temp: &Path, title_id: u64, name: &str, code: &str) -> GameInfo {
        let path = temp.join(format!("{name}.cci"));
        write_rom(&path, &synthetic_ncsd(title_id, code, 1));
        let rom = crate::rom::detect_rom(&path).unwrap();
        let info = GameInfo::new(&rom, name, code, 1).unwrap();
        let dir = crate::gameinfo::package_dir(temp, &info.title_id);
        info.write(&dir).unwrap();
        crate::gameinfo::install_placeholder_pack(&dir, &info.title_id).unwrap()
    }

    #[test]
    fn multi_game_catalog_is_byte_exact_and_sorted() {
        let temp = tempdir().unwrap();
        let pokemon_y = built_package(
            temp.path(),
            0x0004_0000_0005_5E00,
            "Pokémon Y",
            "CTR-P-EK2A",
        );
        let alpha = built_package(
            temp.path(),
            0x0004_0000_0011_C500,
            "Pokémon Alpha Sapphire",
            "CTR-P-ECLA",
        );
        // Reverse the input order: output must still be sorted by title ID.
        let catalog = GameCatalog::from_packages(&[alpha, pokemon_y]).unwrap();
        assert_eq!(catalog.to_json().unwrap(), GOLDEN);
        assert_eq!(catalog.len(), 2);
        assert!(catalog.summary().contains("Pokémon Y (0004000000055E00)"));
        assert!(catalog
            .summary()
            .contains("Pokémon Alpha Sapphire (000400000011C500)"));
    }

    #[test]
    fn catalog_validation_and_roundtrip() {
        let golden = GameCatalog::from_json(GOLDEN, Path::new("GameCatalog.json")).unwrap();
        assert_eq!(golden.to_json().unwrap(), GOLDEN);
        assert_eq!(
            golden.games[0].pack_file,
            pack_relative_path("0004000000055E00")
        );

        let mut broken = golden.clone();
        broken.games.reverse();
        assert!(broken.validate().is_err());

        let mut broken = golden.clone();
        broken.games[0].pack_file = "Frameworks/other.dylib".to_string();
        assert!(broken.validate().is_err());

        let mut broken = golden.clone();
        broken.games[1].title_id = broken.games[0].title_id.clone();
        assert!(broken.validate().is_err());

        let mut broken = golden.clone();
        broken.games[0].aot_version = 0;
        assert!(broken.validate().is_err());

        let mut broken = golden.clone();
        broken.schema_version = 3;
        assert!(broken.validate().is_err());

        let mut broken = golden.clone();
        broken.games[0].pack_abi_version = 0;
        assert!(broken.validate().is_err());

        let mut broken = golden.clone();
        broken.games[0].registration_symbol = Some("not a symbol".to_string());
        assert!(broken.validate().is_err());

        let mut broken = golden.clone();
        broken.games[0].cover_file = Some("Covers/other.png".to_string());
        assert!(broken.validate().is_err());

        let mut valid = golden.clone();
        valid.games[0].registration_symbol = Some("zk_gamepack_register".to_string());
        valid.games[0].cover_file = Some("Covers/0004000000055E00.png".to_string());
        assert!(valid.validate().is_ok());
    }

    #[test]
    fn legacy_version_1_catalog_is_accepted() {
        // The single-game build scripts still write schemaVersion 1 (static link).
        let legacy = concat!(
            "{\"schemaVersion\":1,\"games\":[{\"titleID\":\"0004000000055E00\",",
            "\"displayName\":\"Pokémon Y\",\"productCode\":\"CTR-P-EK2A\",",
            "\"aot\":true,\"aotVersion\":1,\"notes\":\"\"}]}\n"
        );
        let catalog = GameCatalog::from_json(legacy, Path::new("GameCatalog.json")).unwrap();
        assert_eq!(catalog.schema_version, 1);
        assert_eq!(catalog.games[0].pack_abi_version, 1);
        assert_eq!(catalog.games.len(), 1);

        // A version 1 entry with a packFile is accepted as well (mixed builds).
        let mut upgraded = catalog.clone();
        upgraded.schema_version = 2;
        upgraded.games[0].pack_file = pack_relative_path("0004000000055E00");
        assert!(upgraded.validate().is_ok());
    }

    #[test]
    fn queued_packages_are_rejected() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("Pokemon Y.cci");
        write_rom(
            &path,
            &synthetic_ncsd(0x0004_0000_0005_5E00, "CTR-P-EK2A", 1),
        );
        let rom = crate::rom::detect_rom(&path).unwrap();
        let info = GameInfo::new(&rom, "Pokémon Y", "CTR-P-EK2A", 1).unwrap();
        assert!(GameCatalog::from_packages(&[info]).is_err());
    }

    #[test]
    fn catalogue_file_roundtrip() {
        let temp = tempdir().unwrap();
        let package = built_package(
            temp.path(),
            0x0004_0000_0005_5E00,
            "Pokémon Y",
            "CTR-P-EK2A",
        );
        let catalog = GameCatalog::from_packages(&[package.clone()]).unwrap();
        let path = temp.path().join("GameCatalog.json");
        catalog.write(&path).unwrap();
        assert_eq!(GameCatalog::read(&path).unwrap(), catalog);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.ends_with('\n'));
        assert_eq!(
            text.lines().count(),
            1,
            "catalog must be one line + newline"
        );
        assert!(catalog.all_placeholders(std::slice::from_ref(&package)));
    }
}
