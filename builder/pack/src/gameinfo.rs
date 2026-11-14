//! Per-game package manifest (`GameInfo.json`) and package directory layout.
//!
//! One package per title:
//!
//! ```text
//! out/packages/<TITLE_ID>/
//!   GameInfo.json      metadata + provenance (this module)
//!   GamePack.dylib     AOT game pack produced on macOS (built by the scripts)
//!   GameRom.<ext>      optional user ROM copy, so the phone never imports data
//!   cover.png          optional, user-supplied; never committed
//! ```
//!
//! The manifest is deterministic: fixed field order, pretty JSON, no
//! timestamps, so importing/cataloguing the same ROM set twice produces
//! byte-identical files. The pack itself is hashed with the shared
//! `builder-core` streaming SHA256 (never loaded into memory).

use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{PackError, Result};
use crate::rom::{self, RomInfo};

/// Directory name under the output root that holds one directory per title ID.
pub const PACKAGES_DIR: &str = "packages";
/// Package metadata file name.
pub const GAME_INFO_FILE: &str = "GameInfo.json";
/// AOT game pack file name inside a package directory.
pub const GAME_PACK_FILE: &str = "GamePack.dylib";
/// File name prefix of the user ROM bundled inside a self-contained package.
pub const GAME_ROM_PREFIX: &str = "GameRom";
/// ROM file extensions a self-contained package may bundle (Zakuro boots NCSD
/// images; `.cia` archives are not a runtime format).
pub const GAME_ROM_EXTENSIONS: &[&str] = &["cci", "3ds", "ncch", "cxi"];
/// Generated catalogue file name (written into `<out>/packages/` and the app).
pub const CATALOG_FILE: &str = "GameCatalog.json";
/// Schema version of `GameInfo.json`.
pub const GAME_INFO_SCHEMA_VERSION: u32 = 1;
/// First line of a fake (non-Mach-O) placeholder pack used by `--fake`.
pub const PLACEHOLDER_PACK_PREFIX: &str = "3ds2apple-placeholder-gamepack";

/// Where the user's ROM lives, for provenance/rebuilds. Local paths only stay
/// in the gitignored output tree; they are never uploaded anywhere.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RomSource {
    /// Path the ROM was imported from (informational, may be absent).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// ROM file name.
    #[serde(rename = "fileName")]
    pub file_name: String,
    /// ROM size in bytes.
    pub bytes: u64,
}

impl RomSource {
    /// Provenance record for a detected ROM.
    pub fn from_rom(rom: &RomInfo) -> Self {
        Self {
            path: Some(rom.path.display().to_string()),
            file_name: rom
                .path
                .file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_else(|| rom.display_name.clone()),
            bytes: rom.bytes,
        }
    }
}

/// How the `GamePack.dylib` was produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PackFormat {
    /// A real arm64 Mach-O dynamic library (built on macOS).
    Macho,
    /// A deterministic placeholder written by `--fake`; previews only, never
    /// installable and never shipped.
    Placeholder,
}

/// Hash and size of the pack file, recorded after the pack is built/adopted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PackFile {
    /// Lower-case hex SHA256 of `GamePack.dylib`.
    pub sha256: String,
    /// Size in bytes.
    pub bytes: u64,
    /// Real Mach-O or `--fake` placeholder.
    pub format: PackFormat,
}

/// `GameInfo.json`: one package's metadata, package manifest and provenance.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameInfo {
    /// Manifest schema version (1).
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    /// Canonical 16 upper-case hex title ID; also the directory name.
    #[serde(rename = "titleID")]
    pub title_id: String,
    /// Display name shown by the desktop tool and the shell.
    #[serde(rename = "displayName")]
    pub display_name: String,
    /// 3DS product code (may be empty), e.g. `CTR-P-EK2A`.
    #[serde(rename = "productCode")]
    pub product_code: String,
    /// Version of the AOT pack; matches the catalogue's `aotVersion`.
    #[serde(rename = "aotVersion")]
    pub aot_version: u32,
    /// Save namespace allocated to this game (the title ID; see docs/desktop-aot.md).
    #[serde(rename = "saveNamespace")]
    pub save_namespace: String,
    /// Pack file name inside the package directory (`GamePack.dylib`).
    #[serde(rename = "packFile")]
    pub pack_file: String,
    /// Present once the pack has been built/adopted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pack: Option<PackFile>,
    /// File name of the user ROM copy shipped inside the package
    /// (`GameRom.<ext>`), written by `--include-rom`. When present the package
    /// is self-contained: the shell reads the game data from the app bundle and
    /// the phone never imports a ROM.
    #[serde(rename = "romFile", default, skip_serializing_if = "Option::is_none")]
    pub rom_file: Option<String>,
    /// Lower-case hex SHA256 of the bundled ROM copy.
    #[serde(rename = "romSha256", default, skip_serializing_if = "Option::is_none")]
    pub rom_sha256: Option<String>,
    /// Size in bytes of the bundled ROM copy.
    #[serde(rename = "romBytes", default, skip_serializing_if = "Option::is_none")]
    pub rom_bytes: Option<u64>,
    /// ROM provenance.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rom: Option<RomSource>,
    /// Free-form note (kept short; shown in the catalogue).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub notes: String,
}

impl GameInfo {
    /// A queued package for a detected ROM.
    pub fn new(
        rom: &RomInfo,
        display_name: &str,
        product_code: &str,
        aot_version: u32,
    ) -> Result<Self> {
        let mut info =
            Self::new_without_rom(&rom.title_id, display_name, product_code, aot_version)?;
        info.rom = Some(RomSource::from_rom(rom));
        Ok(info)
    }

    /// A queued package from metadata only (used when a pack is recorded for a
    /// package whose ROM was imported elsewhere).
    pub fn new_without_rom(
        title_id: &str,
        display_name: &str,
        product_code: &str,
        aot_version: u32,
    ) -> Result<Self> {
        let title_id = rom::canonical_title_id(title_id)?;
        let display_name = display_name.trim().to_string();
        validate_display_name(&display_name)?;
        let product_code = product_code.trim().to_string();
        validate_product_code(&product_code)?;
        if aot_version < 1 {
            return Err(PackError::invalid(format!(
                "aotVersion must be >= 1 (got {aot_version})"
            )));
        }
        let info = Self {
            schema_version: GAME_INFO_SCHEMA_VERSION,
            title_id: title_id.clone(),
            display_name,
            product_code,
            aot_version,
            save_namespace: title_id,
            pack_file: GAME_PACK_FILE.to_string(),
            pack: None,
            rom_file: None,
            rom_sha256: None,
            rom_bytes: None,
            rom: None,
            notes: String::new(),
        };
        Ok(info)
    }

    /// Validate the manifest (and every optional field) before it is written or
    /// used to generate a catalogue.
    pub fn validate(&self) -> Result<()> {
        if self.schema_version != GAME_INFO_SCHEMA_VERSION {
            return Err(PackError::invalid(format!(
                "unsupported GameInfo schemaVersion {} (expected {})",
                self.schema_version, GAME_INFO_SCHEMA_VERSION
            )));
        }
        let canonical = rom::canonical_title_id(&self.title_id)?;
        if canonical != self.title_id {
            return Err(PackError::invalid(format!(
                "titleID {} is not canonical (expected {})",
                self.title_id, canonical
            )));
        }
        validate_display_name(&self.display_name)?;
        validate_product_code(&self.product_code)?;
        if self.aot_version < 1 {
            return Err(PackError::invalid(format!(
                "{}: aotVersion must be >= 1 (got {})",
                self.title_id, self.aot_version
            )));
        }
        if self.save_namespace != self.title_id {
            return Err(PackError::invalid(format!(
                "{}: saveNamespace must equal the title ID for the per-title layout (got '{}')",
                self.title_id, self.save_namespace
            )));
        }
        if self.pack_file != GAME_PACK_FILE {
            return Err(PackError::invalid(format!(
                "{}: packFile must be '{}' (got '{}')",
                self.title_id, GAME_PACK_FILE, self.pack_file
            )));
        }
        if let Some(pack) = &self.pack {
            validate_pack_file(&self.title_id, pack)?;
        }
        validate_rom_fields(self)?;
        if self.notes.chars().any(|c| c.is_control()) {
            return Err(PackError::invalid(format!(
                "{}: notes must not contain control characters",
                self.title_id
            )));
        }
        Ok(())
    }

    /// Deterministic pretty JSON with a trailing newline.
    pub fn to_json(&self) -> Result<String> {
        self.validate()?;
        let mut text = serde_json::to_string_pretty(self)?;
        text.push('\n');
        Ok(text)
    }

    /// Parse and validate a manifest from a JSON string.
    pub fn from_json(text: &str, source: &Path) -> Result<Self> {
        let info: Self = serde_json::from_str(text)
            .map_err(|error| PackError::json(source.to_path_buf(), error))?;
        info.validate()?;
        Ok(info)
    }

    /// Read `<dir>/GameInfo.json`.
    pub fn read(dir: &Path) -> Result<Self> {
        let path = dir.join(GAME_INFO_FILE);
        let text = std::fs::read_to_string(&path).map_err(|error| PackError::io(&path, error))?;
        Self::from_json(&text, &path)
    }

    /// Write `<dir>/GameInfo.json`, creating the directory if needed.
    pub fn write(&self, dir: &Path) -> Result<PathBuf> {
        self.validate()?;
        std::fs::create_dir_all(dir).map_err(|error| PackError::io(dir, error))?;
        let path = dir.join(GAME_INFO_FILE);
        std::fs::write(&path, self.to_json()?).map_err(|error| PackError::io(&path, error))?;
        Ok(path)
    }

    /// Whether the manifest carries a built pack (the file may still be missing;
    /// use `verify_package` for that check).
    pub fn has_pack(&self) -> bool {
        self.pack.is_some()
    }
}

fn validate_display_name(name: &str) -> Result<()> {
    if name.trim().is_empty() {
        return Err(PackError::invalid("displayName must not be empty"));
    }
    if name.contains('\n') || name.contains('\r') {
        return Err(PackError::invalid(format!(
            "displayName must be a single line (got {name:?})"
        )));
    }
    if name.chars().any(|c| c.is_control()) {
        return Err(PackError::invalid(format!(
            "displayName must not contain control characters (got {name:?})"
        )));
    }
    if name.chars().count() > 120 {
        return Err(PackError::invalid(
            "displayName must be at most 120 characters",
        ));
    }
    Ok(())
}

fn validate_product_code(code: &str) -> Result<()> {
    if code.chars().count() > 32 {
        return Err(PackError::invalid(
            "productCode must be at most 32 characters",
        ));
    }
    if !code.chars().all(|c| c.is_ascii_graphic() || c == ' ') {
        return Err(PackError::invalid(format!(
            "productCode must be printable ASCII (got {code:?})"
        )));
    }
    Ok(())
}

fn validate_pack_file(title_id: &str, pack: &PackFile) -> Result<()> {
    if pack.sha256.len() != 64
        || !pack
            .sha256
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    {
        return Err(PackError::invalid(format!(
            "{title_id}: pack.sha256 must be 64 lower-case hex digits"
        )));
    }
    if pack.bytes == 0 {
        return Err(PackError::invalid(format!(
            "{title_id}: pack.bytes must be > 0"
        )));
    }
    Ok(())
}

/// Validate the optional bundled-ROM triplet: all three fields or none, a
/// canonical `GameRom.<ext>` name, a real SHA256 and a size that agrees with the
/// provenance record.
fn validate_rom_fields(info: &GameInfo) -> Result<()> {
    let title = &info.title_id;
    let present = info.rom_file.is_some() as u8
        + info.rom_sha256.is_some() as u8
        + info.rom_bytes.is_some() as u8;
    if present == 0 {
        return Ok(());
    }
    if present != 3 {
        return Err(PackError::invalid(format!(
            "{title}: romFile, romSha256 and romBytes must be present together"
        )));
    }
    let file = info.rom_file.as_deref().unwrap_or_default();
    if !is_game_rom_file_name(file) {
        return Err(PackError::invalid(format!(
            "{title}: romFile must be '{}.<{}>' (got '{file}')",
            GAME_ROM_PREFIX,
            GAME_ROM_EXTENSIONS.join("|")
        )));
    }
    let sha = info.rom_sha256.as_deref().unwrap_or_default();
    if sha.len() != 64
        || !sha
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    {
        return Err(PackError::invalid(format!(
            "{title}: romSha256 must be 64 lower-case hex digits"
        )));
    }
    let bytes = info.rom_bytes.unwrap_or(0);
    if bytes == 0 {
        return Err(PackError::invalid(format!("{title}: romBytes must be > 0")));
    }
    if let Some(rom) = &info.rom {
        if rom.bytes != bytes {
            return Err(PackError::invalid(format!(
                "{title}: romBytes is {bytes} but the provenance record says {} (the ROM changed; re-import it)",
                rom.bytes
            )));
        }
    }
    Ok(())
}

/// Package-relative file name of a bundled ROM: `GameRom.<ext>`, with the
/// source extension lower-cased. Only the extensions the runtime can boot are
/// accepted, so a `.cia` archive is rejected at import time rather than at boot.
pub fn game_rom_file_name(source: &Path) -> Result<String> {
    let extension = source
        .extension()
        .map(|ext| ext.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    if !GAME_ROM_EXTENSIONS.contains(&extension.as_str()) {
        return Err(PackError::invalid(format!(
            "{}: cannot bundle a ROM with extension '.{}' (supported: {})",
            source.display(),
            extension,
            GAME_ROM_EXTENSIONS.join(", ")
        )));
    }
    Ok(format!("{GAME_ROM_PREFIX}.{extension}"))
}

/// True for a canonical bundled-ROM file name (`GameRom.cci`, `GameRom.3ds`, ...).
pub fn is_game_rom_file_name(name: &str) -> bool {
    let Some(rest) = name.strip_prefix(GAME_ROM_PREFIX) else {
        return false;
    };
    let Some(extension) = rest.strip_prefix('.') else {
        return false;
    };
    GAME_ROM_EXTENSIONS.contains(&extension)
}

/// Copy the user ROM into the package, verify the copy against the source and
/// record `romFile`/`romSha256`/`romBytes` in the manifest.
///
/// The ROM is stored raw (never compressed): the runtime `zk_create()` opens it
/// as a file and the package builder only copies bytes, so the cost is disk
/// space equal to the ROM (1.8 GB for Pokemon Y) in the gitignored output tree.
/// The copy is hashed and compared with the source before the manifest is
/// written, so a package can never claim a ROM it does not actually carry.
pub fn install_rom(dir: &Path, source: &Path) -> Result<GameInfo> {
    let mut info = read_package(dir)?;
    let file_name = game_rom_file_name(source)?;
    let destination = dir.join(&file_name);
    let source_hash =
        builder_core::hash::sha256_file(source).map_err(|error| PackError::io(source, error))?;
    std::fs::create_dir_all(dir).map_err(|error| PackError::io(dir, error))?;
    std::fs::copy(source, &destination).map_err(|error| PackError::io(&destination, error))?;
    let copied = builder_core::hash::sha256_file(&destination)
        .map_err(|error| PackError::io(&destination, error))?;
    if copied.sha256 != source_hash.sha256 || copied.bytes != source_hash.bytes {
        std::fs::remove_file(&destination).ok();
        return Err(PackError::invalid(format!(
            "{}: the bundled ROM copy does not match its source ({} bytes / {}, copy {} bytes / {})",
            destination.display(),
            source_hash.bytes,
            source_hash.sha256,
            copied.bytes,
            copied.sha256
        )));
    }
    if let Some(rom) = &info.rom {
        if rom.bytes != copied.bytes {
            std::fs::remove_file(&destination).ok();
            return Err(PackError::invalid(format!(
                "{}: the ROM is {} bytes but the package was imported with {} bytes; re-import it first",
                source.display(),
                copied.bytes,
                rom.bytes
            )));
        }
    }
    info.rom_file = Some(file_name);
    info.rom_sha256 = Some(copied.sha256);
    info.rom_bytes = Some(copied.bytes);
    info.write(dir)?;
    Ok(info)
}

/// Check the bundled ROM of one package against the manifest (size + SHA256).
/// Returns false and pushes an issue when it is missing or does not match.
fn verify_bundled_rom(info: &GameInfo, dir: &Path, issues: &mut Vec<String>) -> bool {
    let (Some(file), Some(expected_sha), Some(expected_bytes)) =
        (&info.rom_file, &info.rom_sha256, info.rom_bytes)
    else {
        return true;
    };
    let path = dir.join(file);
    if !path.is_file() {
        issues.push(format!("bundled ROM {} is missing", path.display()));
        return false;
    }
    let hash = match builder_core::hash::sha256_file(&path) {
        Ok(hash) => hash,
        Err(error) => {
            issues.push(format!(
                "could not hash bundled ROM {}: {error}",
                path.display()
            ));
            return false;
        }
    };
    let mut ok = true;
    if hash.bytes != expected_bytes {
        issues.push(format!(
            "bundled ROM is {} bytes but GameInfo.json records {expected_bytes}",
            hash.bytes
        ));
        ok = false;
    }
    if hash.sha256 != *expected_sha {
        issues.push(format!(
            "bundled ROM SHA256 is {} but GameInfo.json records {expected_sha}",
            hash.sha256
        ));
        ok = false;
    }
    ok
}

/// Package directory for one title: `<root>/packages/<TITLE_ID>`.
pub fn package_dir(root: &Path, title_id: &str) -> PathBuf {
    root.join(PACKAGES_DIR).join(title_id)
}

/// `<root>/packages`.
pub fn packages_root(root: &Path) -> PathBuf {
    root.join(PACKAGES_DIR)
}

/// `<root>/packages/GameCatalog.json`.
pub fn catalog_path(root: &Path) -> PathBuf {
    packages_root(root).join(CATALOG_FILE)
}

/// Existing package directories, sorted by directory name (title ID) so every
/// listing/allocation is deterministic.
pub fn list_package_dirs(root: &Path) -> Result<Vec<PathBuf>> {
    let packages = packages_root(root);
    let entries = match std::fs::read_dir(&packages) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(PackError::io(&packages, error)),
    };
    let mut dirs = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| PackError::io(&packages, error))?;
        let path = entry.path();
        if path.is_dir() {
            dirs.push(path);
        }
    }
    dirs.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
    Ok(dirs)
}

/// Read a package and check that the directory name is its title ID.
pub fn read_package(dir: &Path) -> Result<GameInfo> {
    let dir_name = dir
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .ok_or_else(|| PackError::invalid(format!("{}: not a package directory", dir.display())))?;
    let info = GameInfo::read(dir)?;
    if info.title_id != dir_name {
        return Err(PackError::invalid(format!(
            "{}: directory name does not match GameInfo titleID {}",
            dir.display(),
            info.title_id
        )));
    }
    Ok(info)
}

/// State of a package directory, derived from the manifest and the pack file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PackageState {
    /// Imported/metadata known, pack not built yet.
    Queued,
    /// Manifest and pack file agree.
    Built,
    /// Manifest/file disagree (e.g. pack file deleted) or stale file present.
    Broken,
}

/// Listing/verification view of one package.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageSummary {
    /// Title ID.
    pub title_id: String,
    /// Display name from the manifest.
    pub display_name: String,
    /// Product code from the manifest (may be empty).
    pub product_code: String,
    /// AOT version from the manifest.
    pub aot_version: u32,
    /// Queued / built / broken.
    pub state: PackageState,
    /// Pack metadata when present.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pack: Option<PackFile>,
    /// Non-fatal problems found while listing.
    pub issues: Vec<String>,
}

impl PackageSummary {
    /// True when the package can be packed into an IPA.
    pub fn is_usable(&self) -> bool {
        self.state == PackageState::Built && self.issues.is_empty()
    }
}

/// Summarise one package directory without hashing the pack (cheap; safe for
/// `packages list`). Use `verify_package` for the full hash check.
pub fn summarize_package(dir: &Path) -> Result<PackageSummary> {
    let info = read_package(dir)?;
    let pack_path = dir.join(GAME_PACK_FILE);
    let pack_present = pack_path.is_file();
    let mut issues = Vec::new();
    let state = match (&info.pack, pack_present) {
        (Some(_), true) => PackageState::Built,
        (None, false) => PackageState::Queued,
        (Some(_), false) => {
            issues.push(format!(
                "pack declared but {} is missing",
                pack_path.display()
            ));
            PackageState::Broken
        }
        (None, true) => {
            issues.push(format!(
                "{} exists but GameInfo.json has no pack record",
                pack_path.display()
            ));
            PackageState::Broken
        }
    };
    Ok(PackageSummary {
        title_id: info.title_id,
        display_name: info.display_name,
        product_code: info.product_code,
        aot_version: info.aot_version,
        state,
        pack: info.pack,
        issues,
    })
}

/// Full verification report for one package (hashes the pack).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VerifyReport {
    /// Title ID.
    pub title_id: String,
    /// Display name.
    pub display_name: String,
    /// Derived state.
    pub state: PackageState,
    /// True when the package can be allocated into an IPA.
    pub ok: bool,
    /// Problems that make the package unusable (empty when `ok`).
    pub issues: Vec<String>,
    /// Recomputed pack SHA256 when a pack file is present.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actual_sha256: Option<String>,
}

/// Verify one package: manifest validity, pack presence, size, format and hash.
///
/// A `--fake` placeholder is reported as an issue but the package is still
/// structurally valid, so preview IPAs can be built on Linux.
pub fn verify_package(dir: &Path) -> Result<VerifyReport> {
    let info = read_package(dir)?;
    let pack_path = dir.join(GAME_PACK_FILE);
    let pack_present = pack_path.is_file();
    let mut issues = Vec::new();
    let mut actual_sha256 = None;
    let mut state = PackageState::Queued;
    match (&info.pack, pack_present) {
        (None, false) => { /* queued: fine */ }
        (None, true) => {
            issues.push(format!(
                "{} exists but GameInfo.json has no pack record (re-run packages record)",
                pack_path.display()
            ));
            state = PackageState::Broken;
        }
        (Some(_pack), false) => {
            issues.push(format!("{} is missing", pack_path.display()));
            state = PackageState::Broken;
        }
        (Some(pack), true) => {
            let hash = builder_core::hash::sha256_file(&pack_path)
                .map_err(|error| PackError::io(&pack_path, error))?;
            actual_sha256 = Some(hash.sha256.clone());
            let mut blocking = false;
            if hash.bytes != pack.bytes {
                issues.push(format!(
                    "pack size is {} bytes but GameInfo.json records {}",
                    hash.bytes, pack.bytes
                ));
                blocking = true;
            }
            if hash.sha256 != pack.sha256 {
                issues.push(format!(
                    "pack SHA256 is {} but GameInfo.json records {}",
                    hash.sha256, pack.sha256
                ));
                blocking = true;
            }
            let prefix = read_prefix(&pack_path, 64)?;
            match classify_pack(&prefix) {
                Ok(format) if format != pack.format => {
                    issues.push(format!(
                        "pack is {:?} on disk but GameInfo.json records {:?}",
                        format, pack.format
                    ));
                    blocking = true;
                }
                Ok(_) => {}
                Err(message) => {
                    issues.push(message.to_string());
                    blocking = true;
                }
            }
            if pack.format == PackFormat::Placeholder {
                issues.push(
                    "pack is a --fake placeholder; build the real pack on macOS before shipping"
                        .to_string(),
                );
            }
            state = if blocking {
                PackageState::Broken
            } else {
                PackageState::Built
            };
        }
    }
    if !verify_bundled_rom(&info, dir, &mut issues) {
        state = PackageState::Broken;
    }
    let blocking = state == PackageState::Broken;
    Ok(VerifyReport {
        title_id: info.title_id,
        display_name: info.display_name,
        state,
        ok: !blocking,
        issues,
        actual_sha256,
    })
}

/// Install a built pack file into the package (copies + hashes it, updates the
/// manifest). Used by `packages record` for a pack produced by the macOS script.
pub fn install_pack(dir: &Path, source: &Path) -> Result<GameInfo> {
    let mut info = read_package(dir)?;
    let prefix = read_prefix(source, 64)?;
    let format = classify_pack(&prefix)
        .map_err(|message| PackError::invalid(format!("{}: {message}", source.display())))?;
    let destination = dir.join(GAME_PACK_FILE);
    let same_file = match (source.canonicalize(), destination.canonicalize()) {
        (Ok(from), Ok(to)) => from == to,
        _ => false,
    };
    if !same_file {
        std::fs::copy(source, &destination).map_err(|error| PackError::io(&destination, error))?;
    }
    finish_pack(&mut info, dir, format)
}

/// Write a deterministic `--fake` placeholder pack and record it.
pub fn install_placeholder_pack(dir: &Path, title_id: &str) -> Result<GameInfo> {
    let mut info = read_package(dir)?;
    if info.title_id != title_id {
        return Err(PackError::invalid(format!(
            "placeholder requested for {} but the package is {}",
            title_id, info.title_id
        )));
    }
    let destination = dir.join(GAME_PACK_FILE);
    std::fs::write(&destination, placeholder_pack_bytes(title_id))
        .map_err(|error| PackError::io(&destination, error))?;
    finish_pack(&mut info, dir, PackFormat::Placeholder)
}

fn finish_pack(info: &mut GameInfo, dir: &Path, format: PackFormat) -> Result<GameInfo> {
    let pack_path = dir.join(GAME_PACK_FILE);
    let hash = builder_core::hash::sha256_file(&pack_path)
        .map_err(|error| PackError::io(&pack_path, error))?;
    info.pack = Some(PackFile {
        sha256: hash.sha256,
        bytes: hash.bytes,
        format,
    });
    info.write(dir)?;
    Ok(info.clone())
}

/// Deterministic placeholder pack bytes (not a Mach-O; clearly labelled).
pub fn placeholder_pack_bytes(title_id: &str) -> Vec<u8> {
    format!(
        "{PLACEHOLDER_PACK_PREFIX}\ntitleID={title_id}\nnote=not a Mach-O; generated by 3ds2apple-pack --fake for previews only\n"
    )
    .into_bytes()
}

/// True when the bytes start with the placeholder marker.
pub fn is_placeholder_pack(bytes: &[u8]) -> bool {
    bytes.starts_with(PLACEHOLDER_PACK_PREFIX.as_bytes())
}

/// True when the bytes start with a Mach-O (thin or universal) magic.
pub fn looks_like_macho(bytes: &[u8]) -> bool {
    if bytes.len() < 4 {
        return false;
    }
    let magic = [bytes[0], bytes[1], bytes[2], bytes[3]];
    matches!(
        magic,
        [0xCF, 0xFA, 0xED, 0xFE]
            | [0xFE, 0xED, 0xFA, 0xCF]
            | [0xCE, 0xFA, 0xED, 0xFE]
            | [0xFE, 0xED, 0xFA, 0xCE]
            | [0xCA, 0xFE, 0xBA, 0xBE]
            | [0xBE, 0xBA, 0xFE, 0xCA]
            | [0xCA, 0xFE, 0xBA, 0xBF]
            | [0xBF, 0xBA, 0xFE, 0xCA]
    )
}

/// Classify a pack file from its first bytes.
pub fn classify_pack(prefix: &[u8]) -> Result<PackFormat> {
    if looks_like_macho(prefix) {
        return Ok(PackFormat::Macho);
    }
    if is_placeholder_pack(prefix) {
        return Ok(PackFormat::Placeholder);
    }
    Err(PackError::invalid(
        "not a Mach-O dynamic library (and not a 3ds2apple placeholder); \
build the pack with scripts/build-game-pack.sh on macOS, or use --fake for a preview",
    ))
}

fn read_prefix(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let mut file = File::open(path).map_err(|error| PackError::io(path, error))?;
    let mut buffer = vec![0_u8; limit];
    let mut filled = 0;
    while filled < limit {
        match file.read(&mut buffer[filled..]) {
            Ok(0) => break,
            Ok(read) => filled += read,
            Err(error) => return Err(PackError::io(path, error)),
        }
    }
    buffer.truncate(filled);
    Ok(buffer)
}

/// Remove a package directory (the caller removes the queue entry separately).
pub fn remove_package_dir(dir: &Path) -> Result<()> {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(PackError::io(dir, error)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rom::test_support::{synthetic_ncsd, write_rom};
    use tempfile::tempdir;

    fn rom_info(dir: &Path) -> RomInfo {
        let path = dir.join("Pokemon Y.cci");
        write_rom(
            &path,
            &synthetic_ncsd(0x0004_0000_0005_5E00, "CTR-P-EK2A", 8),
        );
        rom::detect_rom(&path).unwrap()
    }

    #[test]
    fn deterministic_game_info_json() {
        let temp = tempdir().unwrap();
        let rom = rom_info(temp.path());
        let info = GameInfo::new(&rom, "Pokémon Y", "CTR-P-EK2A", 1).unwrap();
        let first = info.to_json().unwrap();
        let second = info.to_json().unwrap();
        assert_eq!(first, second);
        let expected = format!(
            concat!(
                "{{\n",
                "  \"schemaVersion\": 1,\n",
                "  \"titleID\": \"0004000000055E00\",\n",
                "  \"displayName\": \"Pokémon Y\",\n",
                "  \"productCode\": \"CTR-P-EK2A\",\n",
                "  \"aotVersion\": 1,\n",
                "  \"saveNamespace\": \"0004000000055E00\",\n",
                "  \"packFile\": \"GamePack.dylib\",\n",
                "  \"rom\": {{\n",
                "    \"path\": \"{}\",\n",
                "    \"fileName\": \"Pokemon Y.cci\",\n",
                "    \"bytes\": 16896\n",
                "  }}\n",
                "}}\n"
            ),
            rom.path.display()
        );
        assert_eq!(first, expected);
        let reparsed = GameInfo::from_json(&first, Path::new("GameInfo.json")).unwrap();
        assert_eq!(reparsed, info);
    }

    #[test]
    fn validation_rejects_bad_metadata() {
        let mut info =
            GameInfo::new_without_rom("0004000000055E00", "Pokémon Y", "CTR-P-EK2A", 1).unwrap();
        assert!(info.validate().is_ok());

        info.schema_version = 2;
        assert!(info.validate().is_err());
        info.schema_version = 1;
        info.title_id = "0004000000055e00".to_string();
        assert!(info.validate().is_err());
        info.title_id = "0004000000055E00".to_string();
        info.display_name = " two\nlines".to_string();
        assert!(info.validate().is_err());
        info.display_name = "Pokémon Y".to_string();
        info.save_namespace = "other".to_string();
        assert!(info.validate().is_err());
        info.save_namespace = "0004000000055E00".to_string();
        info.pack_file = "other.dylib".to_string();
        assert!(info.validate().is_err());
        info.pack_file = GAME_PACK_FILE.to_string();
        info.aot_version = 0;
        assert!(info.validate().is_err());
    }

    #[test]
    fn installs_placeholder_and_classifies_packs() {
        let temp = tempdir().unwrap();
        let rom = rom_info(temp.path());
        let info = GameInfo::new(&rom, "Pokémon Y", "CTR-P-EK2A", 1).unwrap();
        let dir = package_dir(temp.path(), &info.title_id);
        info.write(&dir).unwrap();
        let built = install_placeholder_pack(&dir, "0004000000055E00").unwrap();
        let pack = built.pack.as_ref().unwrap();
        assert_eq!(pack.format, PackFormat::Placeholder);
        assert_eq!(
            pack.bytes as usize,
            placeholder_pack_bytes("0004000000055E00").len()
        );
        assert_eq!(
            pack.sha256,
            builder_core::hash::sha256_hex(&placeholder_pack_bytes("0004000000055E00"))
        );
        let report = verify_package(&dir).unwrap();
        assert!(report.ok);
        assert!(report
            .issues
            .iter()
            .any(|issue| issue.contains("placeholder")));

        assert!(looks_like_macho(&[0xCF, 0xFA, 0xED, 0xFE, 0]));
        assert!(looks_like_macho(&[0xCA, 0xFE, 0xBA, 0xBE, 0]));
        assert!(!looks_like_macho(&[0x4D, 0x5A, 0, 0]));
        assert_eq!(
            classify_pack(&[0xCF, 0xFA, 0xED, 0xFE]).unwrap(),
            PackFormat::Macho
        );
        assert!(classify_pack(b"hello").is_err());
    }

    #[test]
    fn verifies_and_lists_packages() {
        let temp = tempdir().unwrap();
        let rom = rom_info(temp.path());
        let info = GameInfo::new(&rom, "Pokémon Y", "CTR-P-EK2A", 1).unwrap();
        let dir = package_dir(temp.path(), &info.title_id);
        info.write(&dir).unwrap();
        assert_eq!(summarize_package(&dir).unwrap().state, PackageState::Queued);
        install_placeholder_pack(&dir, &info.title_id).unwrap();
        assert_eq!(summarize_package(&dir).unwrap().state, PackageState::Built);
        std::fs::write(dir.join(GAME_PACK_FILE), b"tampered").unwrap();
        let report = verify_package(&dir).unwrap();
        assert!(!report.ok);
        assert!(report.issues.iter().any(|issue| issue.contains("SHA256")));

        assert_eq!(list_package_dirs(temp.path()).unwrap().len(), 1);
        assert_eq!(read_package(&dir).unwrap().display_name, "Pokémon Y");
    }

    #[test]
    fn directory_name_must_match_title() {
        let temp = tempdir().unwrap();
        let rom = rom_info(temp.path());
        let info = GameInfo::new(&rom, "Pokémon Y", "CTR-P-EK2A", 1).unwrap();
        let wrong = temp.path().join(PACKAGES_DIR).join("000400000011C500");
        info.write(&wrong).unwrap();
        assert!(read_package(&wrong)
            .unwrap_err()
            .to_string()
            .contains("does not match"));
    }
}
