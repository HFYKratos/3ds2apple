//! Portable .32a build packages: manifest v1, export, import and listing.
//!
//! A .32a file is a ZIP container (see builder/core/src/zip.rs) holding the AOT
//! build of one game together with the game data the user chose to include.
//! Root entries of the container:
//!
//! - manifest.json: schema v1, the single source of truth (first entry)
//! - GamePack-<TITLEID>.dylib: the real arm64 Mach-O GamePack
//! - GameInfo.json: the package manifest as it was exported
//! - cover.png: optional SMDH cover (present when exported)
//! - GameRom.<ext>: optional user ROM copy (present when a ROM was found)
//!
//! The format is user data, not repository content: a .32a can contain a user's
//! ROM, so it lives in the gitignored workspace builds directory and must never
//! be committed or uploaded. This module is the single schema writer; the
//! Windows and macOS launchers only orchestrate the CLI and show the paths.
//!
//! Export is atomic (temporary file then rename), import validates the ZIP
//! structure, manifest schema/version, title ID, pack SHA256 + Mach-O magic,
//! GameInfo.json hash/shape and every optional payload hash before installing
//! anything into packages/<TITLE_ID>/. An existing package is only replaced when
//! the caller passes --replace; unrelated files are never deleted.

use std::collections::BTreeSet;
use std::io::{BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use builder_core::hash::{sha256_file, sha256_hex, HashingWriter};
use builder_core::zip::{ZipArchive, ZipWriter};

use crate::error::{PackError, Result};
use crate::gameinfo::{
    self, GameInfo, PackFormat, COVER_FILE, GAME_INFO_FILE, GAME_PACK_FILE, GAME_ROM_EXTENSIONS,
};
use crate::queue::{Queue, QueueEntry, QueueState};
use crate::{plan, rom, GAMEPACK_ABI_VERSION};

/// Manifest format identifier written to every .32a.
pub const BUILD_FORMAT: &str = "3ds2apple-build";
/// Manifest schema version written (and the highest one accepted).
pub const BUILD_SCHEMA_VERSION: u32 = 1;
/// File extension of a build package.
pub const BUILD_PACKAGE_EXTENSION: &str = "32a";
/// Manifest file name (first ZIP entry).
pub const MANIFEST_FILE: &str = "manifest.json";
/// Directory below the pack CLI output root that holds exported .32a files.
pub const BUILDS_DIRECTORY: &str = "builds";
/// Maximum accepted manifest size (bytes) when reading a foreign archive.
pub const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;
/// Maximum accepted cover size (bytes): an SMDH cover is a few KiB.
pub const MAX_COVER_BYTES: u64 = 8 * 1024 * 1024;
/// Pack format tag written into the manifest (real Mach-O GamePack).
pub const PACK_FORMAT_MACHO: &str = "gamepack-macho";

const GAME_PACK_PREFIX: &str = "GamePack-";

fn default_opt_level() -> String {
    "O2".to_string()
}

fn default_pack_format() -> String {
    PACK_FORMAT_MACHO.to_string()
}

fn default_pack_abi_version() -> u32 {
    GAMEPACK_ABI_VERSION
}

fn default_absent_rom() -> BuildRomRef {
    BuildRomRef {
        included: false,
        file: None,
        bytes: None,
        sha256: None,
    }
}

/// Compiler versions recorded by the launcher that produced the pack.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildToolchain {
    #[serde(default)]
    pub clang: String,
    #[serde(default)]
    pub llvm: String,
}

/// Codegen options the pack was built with (advanced build settings).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildOptions {
    #[serde(rename = "optLevel", default = "default_opt_level")]
    pub opt_level: String,
    #[serde(default)]
    pub lto: bool,
    #[serde(rename = "fastMath", default)]
    pub fast_math: bool,
}

impl Default for BuildOptions {
    fn default() -> Self {
        Self {
            opt_level: default_opt_level(),
            lto: false,
            fast_math: false,
        }
    }
}

impl BuildOptions {
    /// Validate the optimization level (one of O1/O2/O3/Oz).
    pub fn validate(&self) -> Result<()> {
        match self.opt_level.as_str() {
            "O1" | "O2" | "O3" | "Oz" => Ok(()),
            other => Err(PackError::invalid(format!(
                "buildOptions.optLevel must be O1, O2, O3 or Oz (got {other:?})"
            ))),
        }
    }

    /// Canonical short marker used in launcher build-cache keys.
    pub fn cache_marker(&self) -> String {
        format!(
            "opt={};lto={};fastmath={}",
            self.opt_level,
            if self.lto { 1 } else { 0 },
            if self.fast_math { 1 } else { 0 }
        )
    }
}

/// Pack reference inside the manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuildPackRef {
    pub file: String,
    pub bytes: u64,
    pub sha256: String,
    #[serde(default = "default_pack_format")]
    pub format: String,
    #[serde(rename = "abiVersion", default = "default_pack_abi_version")]
    pub abi_version: u32,
}

/// Bundled game data reference. When included is false every other field is absent.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuildRomRef {
    pub included: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
}

/// Which launcher/host produced the package.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceLauncher {
    #[serde(default)]
    pub os: String,
    #[serde(default)]
    pub version: String,
}

/// Manifest v1 of a .32a build package.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildManifest {
    pub format: String,
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    #[serde(rename = "titleID")]
    pub title_id: String,
    pub display_name: String,
    pub product_code: String,
    #[serde(rename = "aotVersion")]
    pub aot_version: u32,
    #[serde(rename = "appVersion")]
    pub app_version: String,
    #[serde(rename = "builtAt")]
    pub built_at: String,
    pub platform: String,
    #[serde(default)]
    pub toolchain: BuildToolchain,
    #[serde(rename = "buildOptions", default)]
    pub build_options: BuildOptions,
    pub pack: BuildPackRef,
    #[serde(rename = "gameInfoSha256")]
    pub game_info_sha256: String,
    #[serde(
        rename = "coverSha256",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub cover_sha256: Option<String>,
    #[serde(default = "default_absent_rom")]
    pub rom: BuildRomRef,
    #[serde(rename = "sourceLauncher", default)]
    pub source_launcher: SourceLauncher,
}

fn is_hex_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .chars()
            .all(|character| character.is_ascii_hexdigit() && !character.is_ascii_uppercase())
}

fn require_sha256(field: &str, value: &str) -> Result<()> {
    if is_hex_sha256(value) {
        Ok(())
    } else {
        Err(PackError::invalid(format!(
            "{field} must be 64 lower-case hex digits (got {value:?})"
        )))
    }
}

fn validate_single_line(field: &str, value: &str, max_chars: usize) -> Result<()> {
    if value.trim().is_empty() {
        return Err(PackError::invalid(format!("{field} must not be empty")));
    }
    if value.chars().any(|character| character.is_control()) {
        return Err(PackError::invalid(format!(
            "{field} must not contain control characters"
        )));
    }
    if value.chars().count() > max_chars {
        return Err(PackError::invalid(format!(
            "{field} must be at most {max_chars} characters"
        )));
    }
    Ok(())
}

fn validate_printable_ascii(field: &str, value: &str, max_chars: usize) -> Result<()> {
    if value.chars().count() > max_chars {
        return Err(PackError::invalid(format!(
            "{field} must be at most {max_chars} characters"
        )));
    }
    if !value
        .chars()
        .all(|character| character.is_ascii_graphic() || character == ' ')
    {
        return Err(PackError::invalid(format!(
            "{field} must be printable ASCII (got {value:?})"
        )));
    }
    Ok(())
}

/// True for the ISO-8601 UTC timestamps this module writes (YYYY-MM-DDTHH:MM:SSZ).
pub fn is_iso8601_utc(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T' {
        return false;
    }
    if bytes[13] != b':' || bytes[16] != b':' || bytes[19] != b'Z' {
        return false;
    }
    for index in [0_usize, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] {
        if !bytes[index].is_ascii_digit() {
            return false;
        }
    }
    true
}

impl BuildManifest {
    /// Validate every field before writing or acting on the manifest.
    pub fn validate(&self) -> Result<()> {
        if self.format != BUILD_FORMAT {
            return Err(PackError::invalid(format!(
                "manifest format must be {BUILD_FORMAT:?} (got {:?})",
                self.format
            )));
        }
        if self.schema_version != BUILD_SCHEMA_VERSION {
            if self.schema_version > BUILD_SCHEMA_VERSION {
                return Err(PackError::invalid(format!(
                    "unsupported build manifest schemaVersion {} (this launcher understands up to {}); update 3ds2apple",
                    self.schema_version, BUILD_SCHEMA_VERSION
                )));
            }
            return Err(PackError::invalid(format!(
                "unsupported build manifest schemaVersion {} (expected {})",
                self.schema_version, BUILD_SCHEMA_VERSION
            )));
        }
        let canonical = rom::canonical_title_id(&self.title_id)?;
        if canonical != self.title_id {
            return Err(PackError::invalid(format!(
                "manifest titleID {} is not canonical (expected {})",
                self.title_id, canonical
            )));
        }
        validate_single_line("manifest displayName", &self.display_name, 120)?;
        validate_printable_ascii("manifest productCode", &self.product_code, 32)?;
        if self.aot_version < 1 {
            return Err(PackError::invalid(format!(
                "manifest aotVersion must be >= 1 (got {})",
                self.aot_version
            )));
        }
        validate_printable_ascii("manifest appVersion", &self.app_version, 64)?;
        if self.app_version.trim().is_empty() {
            return Err(PackError::invalid("manifest appVersion must not be empty"));
        }
        if !is_iso8601_utc(&self.built_at) {
            return Err(PackError::invalid(format!(
                "manifest builtAt must be an ISO-8601 UTC timestamp like 2026-01-31T12:34:56Z (got {:?})",
                self.built_at
            )));
        }
        validate_printable_ascii("manifest platform", &self.platform, 32)?;
        if self.platform.trim().is_empty() {
            return Err(PackError::invalid("manifest platform must not be empty"));
        }
        validate_printable_ascii("manifest sourceLauncher.os", &self.source_launcher.os, 32)?;
        validate_printable_ascii(
            "manifest sourceLauncher.version",
            &self.source_launcher.version,
            64,
        )?;
        self.build_options.validate()?;
        self.pack.validate(&self.title_id)?;
        require_sha256("gameInfoSha256", &self.game_info_sha256)?;
        if let Some(cover) = &self.cover_sha256 {
            require_sha256("coverSha256", cover)?;
        }
        self.rom.validate()?;
        Ok(())
    }

    /// Deterministic pretty JSON, the exact bytes stored as manifest.json.
    pub fn to_json(&self) -> Result<String> {
        self.validate()?;
        Ok(serde_json::to_string_pretty(self)?)
    }

    /// Parse and validate a manifest from JSON text.
    pub fn from_json(text: &str, source: &Path) -> Result<Self> {
        let manifest: Self = serde_json::from_str(text)
            .map_err(|error| PackError::json(source.to_path_buf(), error))?;
        manifest.validate()?;
        Ok(manifest)
    }
}

impl BuildPackRef {
    fn validate(&self, title_id: &str) -> Result<()> {
        let expected = format!("{GAME_PACK_PREFIX}{title_id}.dylib");
        if self.file != expected {
            return Err(PackError::invalid(format!(
                "manifest pack.file must be {expected:?} (got {:?})",
                self.file
            )));
        }
        if self.bytes == 0 {
            return Err(PackError::invalid("manifest pack.bytes must be > 0"));
        }
        require_sha256("manifest pack.sha256", &self.sha256)?;
        if self.format != PACK_FORMAT_MACHO {
            return Err(PackError::invalid(format!(
                "manifest pack.format must be {PACK_FORMAT_MACHO:?} (got {:?}); placeholder packs cannot be exported",
                self.format
            )));
        }
        if self.abi_version != GAMEPACK_ABI_VERSION {
            return Err(PackError::invalid(format!(
                "manifest pack.abiVersion {} is not the host ABI this launcher supports ({})",
                self.abi_version, GAMEPACK_ABI_VERSION
            )));
        }
        Ok(())
    }
}

impl BuildRomRef {
    fn validate(&self) -> Result<()> {
        if !self.included {
            if self.file.is_some() || self.bytes.is_some() || self.sha256.is_some() {
                return Err(PackError::invalid(
                    "manifest rom.included is false but rom.file/bytes/sha256 are present",
                ));
            }
            return Ok(());
        }
        let file = self
            .file
            .as_deref()
            .ok_or_else(|| PackError::invalid("manifest rom.file is required when rom.included is true"))?;
        if !gameinfo::is_game_rom_file_name(file) {
            return Err(PackError::invalid(format!(
                "manifest rom.file must be GameRom.<{}> (got {file:?})",
                GAME_ROM_EXTENSIONS.join("|")
            )));
        }
        let bytes = self
            .bytes
            .ok_or_else(|| PackError::invalid("manifest rom.bytes is required when rom.included is true"))?;
        if bytes == 0 {
            return Err(PackError::invalid("manifest rom.bytes must be > 0"));
        }
        let sha = self
            .sha256
            .as_deref()
            .ok_or_else(|| PackError::invalid("manifest rom.sha256 is required when rom.included is true"))?;
        require_sha256("manifest rom.sha256", sha)?;
        Ok(())
    }
}

/// File name of the GamePack inside a .32a (and inside packages/).
pub fn pack_file_name(title_id: &str) -> String {
    format!("{GAME_PACK_PREFIX}{title_id}.dylib")
}

/// File-name component for a game name: Windows/macOS-invalid characters become
/// '_', trailing dots/spaces are trimmed (Windows refuses them) and an empty name
/// falls back to "game". The component keeps readable non-ASCII names (CJK) and is
/// capped at 120 UTF-8 bytes so TITLE_ID-name.ext stays under the 255-byte limit.
pub fn sanitize_file_name(name: &str) -> String {
    fn is_invalid(character: char) -> bool {
        character.is_control() || matches!(character, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*')
    }
    let mut cleaned = String::new();
    let mut bytes = 0usize;
    for character in name.trim().chars() {
        let mapped = if is_invalid(character) { '_' } else { character };
        let added = mapped.len_utf8();
        if bytes + added > 120 {
            break;
        }
        bytes += added;
        cleaned.push(mapped);
    }
    let cleaned = cleaned.trim_end_matches(['.', ' ']).to_string();
    if cleaned.is_empty() {
        "game".to_string()
    } else {
        cleaned
    }
}

/// File name of a .32a for one game: TITLE_ID-English display name.32a
/// (0.2.2-beta4; no build slug). The single-game IPA uses the same base name.
pub fn build_package_file_name(display_name: &str, title_id: &str) -> String {
    format!(
        "{}-{}.{}",
        title_id.trim().to_uppercase(),
        sanitize_file_name(display_name),
        BUILD_PACKAGE_EXTENSION
    )
}

/// Directory that holds the exported .32a files for an output root.
pub fn builds_root(root: &Path) -> PathBuf {
    root.join(BUILDS_DIRECTORY)
}

/// Convert a Unix timestamp (seconds) into YYYY-MM-DDTHH:MM:SSZ.
pub fn format_iso8601_utc(seconds_since_epoch: i64) -> String {
    let days = seconds_since_epoch.div_euclid(86_400);
    let seconds_of_day = seconds_since_epoch.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// Howard Hinnant civil_from_days: days since 1970-01-01 to (year, month, day).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = if month_prime < 10 {
        month_prime + 3
    } else {
        month_prime - 9
    };
    let year = if month <= 2 { year + 1 } else { year };
    (year, month as u32, day as u32)
}

/// Current UTC time as the manifest timestamp.
pub fn now_iso8601_utc() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0);
    format_iso8601_utc(seconds)
}

/// Options for exporting build packages.
#[derive(Debug, Clone)]
pub struct ExportOptions {
    /// Destination directory; default: the output root builds directory.
    pub output_dir: Option<PathBuf>,
    /// Host platform tag recorded in the manifest (windows/macos/linux).
    pub platform: String,
    /// App/shell version recorded in the manifest.
    pub app_version: String,
    /// Launcher version recorded under sourceLauncher.
    pub launcher_version: String,
    pub toolchain: BuildToolchain,
    pub build_options: BuildOptions,
    /// Extra directories searched for the user's ROM (beyond the package copy,
    /// the queue path and the default launcher-roms locations).
    pub rom_search_dirs: Vec<PathBuf>,
    /// Fixed timestamp for tests.
    pub built_at: Option<String>,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            output_dir: None,
            platform: std::env::consts::OS.to_string(),
            app_version: crate::VERSION.to_string(),
            launcher_version: crate::VERSION.to_string(),
            toolchain: BuildToolchain::default(),
            build_options: BuildOptions::default(),
            rom_search_dirs: Vec::new(),
            built_at: None,
        }
    }
}

/// One exported .32a.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportedBuild {
    #[serde(rename = "titleID")]
    pub title_id: String,
    pub display_name: String,
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
    pub rom_included: bool,
    pub pack_bytes: u64,
    pub pack_sha256: String,
    pub warnings: Vec<String>,
}

/// One title that could not be exported.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportError {
    #[serde(rename = "titleID")]
    pub title_id: String,
    pub error: String,
}

/// Result of one export run (explicit titles or every built package).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportReport {
    pub output_dir: String,
    pub builds: Vec<ExportedBuild>,
    pub errors: Vec<ExportError>,
}

/// One imported .32a.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportedBuild {
    #[serde(rename = "titleID")]
    pub title_id: String,
    pub display_name: String,
    pub path: String,
    pub package_dir: String,
    pub pack_bytes: u64,
    pub pack_sha256: String,
    pub rom_included: bool,
    pub replaced: bool,
    pub warnings: Vec<String>,
}

/// One .32a listed by builds list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildSummary {
    #[serde(rename = "titleID")]
    pub title_id: String,
    pub display_name: String,
    pub path: String,
    pub bytes: u64,
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    #[serde(rename = "aotVersion")]
    pub aot_version: u32,
    pub built_at: String,
    pub platform: String,
    pub app_version: String,
    pub rom_included: bool,
    pub pack_bytes: u64,
    pub pack_sha256: String,
}

/// Resolved user ROM ready to be bundled.
#[derive(Debug, Clone)]
struct ResolvedRom {
    source: PathBuf,
    file_name: String,
    bytes: u64,
    sha256: String,
}

fn path_string(path: &Path) -> String {
    path.display().to_string()
}

fn file_size(path: &Path) -> Result<u64> {
    std::fs::metadata(path)
        .map_err(|error| PackError::io(path, error))
        .map(|metadata| metadata.len())
}

fn hash_file(path: &Path) -> Result<builder_core::hash::HashResult> {
    sha256_file(path).map_err(|error| PackError::io(path, error))
}

fn remove_if_exists(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(PackError::io(path, error)),
    }
}

/// Rename over an existing destination. Windows rename fails when the target
/// exists, so the destination is removed first (the source is already complete).
fn replace_file(source: &Path, destination: &Path) -> Result<()> {
    if destination.exists() {
        std::fs::remove_file(destination).map_err(|error| PackError::io(destination, error))?;
    }
    std::fs::rename(source, destination).map_err(|error| PackError::io(destination, error))
}

/// Run the export for a set of title IDs (or every built package when None).
pub fn export(
    root: &Path,
    title_ids: Option<&[String]>,
    options: &ExportOptions,
) -> Result<ExportReport> {
    options.build_options.validate()?;
    let output_dir = options
        .output_dir
        .clone()
        .unwrap_or_else(|| builds_root(root));
    std::fs::create_dir_all(&output_dir).map_err(|error| PackError::io(&output_dir, error))?;
    let queue = Queue::load(root)?;

    let titles: Vec<String> = match title_ids {
        Some(titles) => titles
            .iter()
            .map(|title| rom::canonical_title_id(title))
            .collect::<Result<_>>()?,
        None => {
            let report = crate::ops::scan(root)?;
            let mut built: Vec<String> = report
                .packages
                .iter()
                .filter(|package| package.state == gameinfo::PackageState::Built)
                .map(|package| package.title_id.clone())
                .collect();
            built.sort();
            built
        }
    };

    let mut builds = Vec::new();
    let mut errors = Vec::new();
    for title in &titles {
        match export_one(root, &queue, title, options, &output_dir) {
            Ok(build) => builds.push(build),
            Err(error) => errors.push(ExportError {
                title_id: title.clone(),
                error: error.to_string(),
            }),
        }
    }
    Ok(ExportReport {
        output_dir: path_string(&output_dir),
        builds,
        errors,
    })
}

fn export_one(
    root: &Path,
    queue: &Queue,
    title_id: &str,
    options: &ExportOptions,
    output_dir: &Path,
) -> Result<ExportedBuild> {
    let title = rom::canonical_title_id(title_id)?;
    let package_dir = gameinfo::package_dir(root, &title);
    if !package_dir.is_dir() {
        return Err(PackError::invalid(format!(
            "no package for {title} in {}; import the ROM and build the GamePack first",
            gameinfo::packages_root(root).display()
        )));
    }
    let info = gameinfo::read_package(&package_dir)?;
    let verification = gameinfo::verify_package(&package_dir)?;
    if !verification.ok {
        return Err(PackError::invalid(format!(
            "{title}: the package is inconsistent and cannot be exported: {}",
            verification.issues.join("; ")
        )));
    }
    let pack_ref = info.pack.clone().ok_or_else(|| {
        PackError::invalid(format!(
            "{title}: the package has no GamePack yet; build it first"
        ))
    })?;
    if pack_ref.format != PackFormat::Macho {
        return Err(PackError::invalid(format!(
            "{title}: the recorded pack is a placeholder; build the real GamePack before exporting a .32a"
        )));
    }

    let pack_path = package_dir.join(GAME_PACK_FILE);
    let pack_hash = hash_file(&pack_path)?;
    if pack_hash.bytes != pack_ref.bytes || pack_hash.sha256 != pack_ref.sha256 {
        return Err(PackError::invalid(format!(
            "{title}: {} no longer matches GameInfo.json; re-record the pack",
            pack_path.display()
        )));
    }

    let game_info_path = package_dir.join(GAME_INFO_FILE);
    let game_info_file_bytes =
        std::fs::read(&game_info_path).map_err(|error| PackError::io(&game_info_path, error))?;

    let mut warnings = Vec::new();
    let mut cover_bytes: Option<Vec<u8>> = None;
    if let Some(cover_path) = &info.cover_path {
        let cover = package_dir.join(cover_path);
        let bytes = std::fs::read(&cover).map_err(|error| PackError::io(&cover, error))?;
        if bytes.len() as u64 > MAX_COVER_BYTES {
            return Err(PackError::invalid(format!(
                "{title}: {} is {} bytes; the maximum accepted cover is {}",
                cover.display(),
                bytes.len(),
                MAX_COVER_BYTES
            )));
        }
        cover_bytes = Some(bytes);
    }
    let cover_sha256 = cover_bytes.as_ref().map(|bytes| sha256_hex(bytes));

    let queue_entry = queue.get(&title);
    let rom = resolve_rom(
        root,
        &package_dir,
        &info,
        queue_entry,
        &options.rom_search_dirs,
        &mut warnings,
    )?;

    // A .32a that bundles the ROM must carry a GameInfo.json whose ROM triplet
    // records it, otherwise the imported package would claim a bundled ROM the
    // manifest does not describe. The exported copy also drops the original local
    // ROM path (provenance without a machine-specific path) so the user-data file
    // does not leak the source folder.
    let mut export_info = info.clone();
    if let Some(resolved) = &rom {
        export_info.rom_file = Some(resolved.file_name.clone());
        export_info.rom_sha256 = Some(resolved.sha256.clone());
        export_info.rom_bytes = Some(resolved.bytes);
        export_info.rom = Some(match info.rom.clone().filter(|source| source.bytes == resolved.bytes) {
            Some(mut source) => {
                source.path = None;
                source
            }
            None => crate::gameinfo::RomSource {
                path: None,
                file_name: resolved.file_name.clone(),
                bytes: resolved.bytes,
            },
        });
    }
    export_info.validate()?;
    let game_info_bytes = if export_info == info {
        game_info_file_bytes
    } else {
        export_info.to_json()?.into_bytes()
    };
    let game_info_sha256 = sha256_hex(&game_info_bytes);

    let built_at = options
        .built_at
        .clone()
        .unwrap_or_else(now_iso8601_utc);
    let manifest = BuildManifest {
        format: BUILD_FORMAT.to_string(),
        schema_version: BUILD_SCHEMA_VERSION,
        title_id: title.clone(),
        display_name: info.display_name.clone(),
        product_code: info.product_code.clone(),
        aot_version: info.aot_version,
        app_version: options.app_version.trim().to_string(),
        built_at,
        platform: options.platform.trim().to_string(),
        toolchain: options.toolchain.clone(),
        build_options: options.build_options.clone(),
        pack: BuildPackRef {
            file: pack_file_name(&title),
            bytes: pack_ref.bytes,
            sha256: pack_ref.sha256.clone(),
            format: PACK_FORMAT_MACHO.to_string(),
            abi_version: GAMEPACK_ABI_VERSION,
        },
        game_info_sha256,
        cover_sha256,
        rom: match &rom {
            Some(rom) => BuildRomRef {
                included: true,
                file: Some(rom.file_name.clone()),
                bytes: Some(rom.bytes),
                sha256: Some(rom.sha256.clone()),
            },
            None => default_absent_rom(),
        },
        source_launcher: SourceLauncher {
            os: std::env::consts::OS.to_string(),
            version: options.launcher_version.trim().to_string(),
        },
    };
    manifest.validate()?;
    let manifest_json = manifest.to_json()?;

    let file_name = build_package_file_name(&info.display_name, &title);
    let destination = output_dir.join(&file_name);
    let temporary = output_dir.join(format!(".{file_name}.tmp"));
    remove_if_exists(&temporary)?;

    write_build_package(
        &temporary,
        &manifest_json,
        &manifest,
        &pack_path,
        &game_info_bytes,
        cover_bytes.as_deref(),
        rom.as_ref(),
    )?;
    let package_hash = hash_file(&temporary)?;
    replace_file(&temporary, &destination)?;

    if rom.is_none() {
        warnings.push(
            "no game data was found for this title (package copy, queue ROM path and launcher-roms were all checked); the .32a does not contain the ROM, so deploying it needs the original ROM".to_string(),
        );
    }
    Ok(ExportedBuild {
        title_id: title,
        display_name: info.display_name,
        path: path_string(&destination),
        bytes: package_hash.bytes,
        sha256: package_hash.sha256,
        rom_included: rom.is_some(),
        pack_bytes: pack_ref.bytes,
        pack_sha256: pack_ref.sha256,
        warnings,
    })
}

#[allow(clippy::too_many_arguments)]
fn write_build_package(
    destination: &Path,
    manifest_json: &str,
    manifest: &BuildManifest,
    pack_path: &Path,
    game_info_bytes: &[u8],
    cover_bytes: Option<&[u8]>,
    rom: Option<&ResolvedRom>,
) -> Result<()> {
    let file =
        std::fs::File::create(destination).map_err(|error| PackError::io(destination, error))?;
    let mut writer = ZipWriter::new(BufWriter::new(file));
    writer
        .add_data(MANIFEST_FILE, manifest_json.as_bytes())
        .map_err(|error| PackError::io(destination, error))?;
    let pack_file =
        std::fs::File::open(pack_path).map_err(|error| PackError::io(pack_path, error))?;
    writer
        .add_file(&manifest.pack.file, BufReader::new(pack_file))
        .map_err(|error| PackError::io(destination, error))?;
    writer
        .add_data(GAME_INFO_FILE, game_info_bytes)
        .map_err(|error| PackError::io(destination, error))?;
    if let (Some(expected), Some(bytes)) = (&manifest.cover_sha256, cover_bytes) {
        if sha256_hex(bytes) != *expected {
            return Err(PackError::invalid(
                "cover changed while the build package was being written",
            ));
        }
        writer
            .add_data(COVER_FILE, bytes)
            .map_err(|error| PackError::io(destination, error))?;
    }
    if let (Some(rom), Some(rom_ref)) = (rom, manifest.rom.included.then_some(&manifest.rom)) {
        let source =
            std::fs::File::open(&rom.source).map_err(|error| PackError::io(&rom.source, error))?;
        let file_name = rom_ref
            .file
            .as_deref()
            .ok_or_else(|| PackError::invalid("rom.file is missing from the manifest"))?;
        writer
            .add_file(file_name, BufReader::new(source))
            .map_err(|error| PackError::io(destination, error))?;
    }
    let buffered = writer
        .finish()
        .map_err(|error| PackError::io(destination, error))?;
    let mut inner = buffered
        .into_inner()
        .map_err(|error| PackError::io(destination, error.into()))?;
    inner
        .flush()
        .map_err(|error| PackError::io(destination, error))?;
    Ok(())
}

fn rom_candidate_for_extension(directory: &Path, title_id: &str, extension: &str) -> PathBuf {
    directory.join(format!("{title_id}.{extension}"))
}

fn is_expected_rom(path: &Path, title_id: &str) -> bool {
    match rom::detect_rom(path) {
        Ok(detected) => detected.title_id == title_id,
        Err(_) => false,
    }
}

fn hash_resolved_rom(source: &Path) -> Result<ResolvedRom> {
    let file_name = gameinfo::game_rom_file_name(source)?;
    let hash = hash_file(source)?;
    Ok(ResolvedRom {
        source: source.to_path_buf(),
        file_name,
        bytes: hash.bytes,
        sha256: hash.sha256,
    })
}

fn resolve_rom(
    root: &Path,
    package_dir: &Path,
    info: &GameInfo,
    queue_entry: Option<&QueueEntry>,
    extra_search_dirs: &[PathBuf],
    warnings: &mut Vec<String>,
) -> Result<Option<ResolvedRom>> {
    let title = info.title_id.as_str();
    // 1. The package's own bundled copy is authoritative when present.
    if let Some(file_name) = &info.rom_file {
        let bundled = package_dir.join(file_name);
        if bundled.is_file() {
            let hash = hash_file(&bundled)?;
            match (&info.rom_sha256, info.rom_bytes) {
                (Some(expected_sha), Some(expected_bytes)) => {
                    if hash.sha256 != *expected_sha || hash.bytes != expected_bytes {
                        return Err(PackError::invalid(format!(
                            "{title}: the bundled ROM {} no longer matches GameInfo.json; re-import it",
                            bundled.display()
                        )));
                    }
                }
                _ => {
                    return Err(PackError::invalid(format!(
                        "{title}: GameInfo.json records romFile but not romSha256/romBytes"
                    )));
                }
            }
            return Ok(Some(ResolvedRom {
                source: bundled,
                file_name: file_name.clone(),
                bytes: hash.bytes,
                sha256: hash.sha256,
            }));
        }
        warnings.push(format!(
            "{title}: the package's bundled ROM copy is missing ({}); looking for the original ROM",
            bundled.display()
        ));
    }
    // 2. The queue records the original ROM path the user imported.
    if let Some(entry) = queue_entry {
        if !entry.rom_path.trim().is_empty() {
            let candidate = PathBuf::from(&entry.rom_path);
            if candidate.is_file() {
                if is_expected_rom(&candidate, title) {
                    return Ok(Some(hash_resolved_rom(&candidate)?));
                }
                warnings.push(format!(
                    "{title}: the queued ROM {} does not belong to this title; skipping it",
                    candidate.display()
                ));
            }
        }
    }
    // 3. Launcher ROM staging directories (workspace/launcher-roms) and the
    //    explicit --rom-dir overrides.
    let mut directories: Vec<PathBuf> = Vec::new();
    directories.push(root.join("launcher-roms"));
    if let Some(parent) = root.parent() {
        directories.push(parent.join("launcher-roms"));
    }
    directories.extend(extra_search_dirs.iter().cloned());
    let mut seen = BTreeSet::new();
    for directory in directories {
        if !seen.insert(directory.clone()) {
            continue;
        }
        for extension in GAME_ROM_EXTENSIONS {
            let candidate = rom_candidate_for_extension(&directory, title, extension);
            if candidate.is_file() && is_expected_rom(&candidate, title) {
                return Ok(Some(hash_resolved_rom(&candidate)?));
            }
        }
    }
    Ok(None)
}

/// Options for importing a .32a.
#[derive(Debug, Clone, Default)]
pub struct ImportOptions {
    /// Replace an existing package for the same title ID (unrelated files stay).
    pub replace: bool,
}

/// Import one .32a file into the packages directory of an output root.
pub fn import(root: &Path, package_path: &Path, options: &ImportOptions) -> Result<ImportedBuild> {
    if !package_path.is_file() {
        return Err(PackError::invalid(format!(
            "the build package does not exist: {}",
            package_path.display()
        )));
    }
    if package_path
        .extension()
        .map(|extension| !extension.eq_ignore_ascii_case(BUILD_PACKAGE_EXTENSION))
        .unwrap_or(true)
    {
        return Err(PackError::invalid(format!(
            "{} does not look like a .32a build package",
            package_path.display()
        )));
    }
    let file =
        std::fs::File::open(package_path).map_err(|error| PackError::io(package_path, error))?;
    let mut archive = ZipArchive::open(BufReader::new(file))
        .map_err(|error| PackError::io(package_path, error))?;

    // --- read and validate the manifest -----------------------------------
    let manifest_index = archive.find(MANIFEST_FILE).ok_or_else(|| {
        PackError::invalid(format!(
            "{} has no {MANIFEST_FILE}; it is not a 3ds2apple build package",
            package_path.display()
        ))
    })?;
    {
        let entry = archive
            .entry(manifest_index)
            .ok_or_else(|| PackError::invalid("manifest index is out of range"))?;
        if entry.is_directory() {
            return Err(PackError::invalid(format!(
                "{MANIFEST_FILE} must be a file entry"
            )));
        }
        if entry.uncompressed_size > MAX_MANIFEST_BYTES {
            return Err(PackError::invalid(format!(
                "{MANIFEST_FILE} is {} bytes; the maximum accepted manifest is {}",
                entry.uncompressed_size, MAX_MANIFEST_BYTES
            )));
        }
    }
    let manifest_bytes = archive
        .read_to_vec(manifest_index)
        .map_err(|error| PackError::io(package_path, error))?;
    let manifest_text = String::from_utf8(manifest_bytes)
        .map_err(|_| PackError::invalid(format!("{MANIFEST_FILE} is not valid UTF-8")))?;
    let manifest = BuildManifest::from_json(&manifest_text, package_path)?;
    let title = manifest.title_id.clone();

    // --- structural validation: only the expected root files ---------------
    let pack_name = manifest.pack.file.clone();
    let mut allowed: BTreeSet<&str> = BTreeSet::new();
    allowed.insert(MANIFEST_FILE);
    allowed.insert(pack_name.as_str());
    allowed.insert(GAME_INFO_FILE);
    if manifest.cover_sha256.is_some() {
        allowed.insert(COVER_FILE);
    }
    if let Some(rom_file) = manifest.rom.file.as_deref() {
        allowed.insert(rom_file);
    }
    let mut seen: BTreeSet<String> = BTreeSet::new();
    for entry in archive.entries() {
        if entry.is_directory() {
            continue;
        }
        if !allowed.contains(entry.name.as_str()) {
            return Err(PackError::invalid(format!(
                "{} contains unexpected entry {:?}; refusing to import an unknown .32a layout",
                package_path.display(),
                entry.name
            )));
        }
        if !seen.insert(entry.name.clone()) {
            return Err(PackError::invalid(format!(
                "{} contains the entry {:?} more than once",
                package_path.display(),
                entry.name
            )));
        }
    }
    for required in [MANIFEST_FILE, pack_name.as_str(), GAME_INFO_FILE] {
        if !seen.contains(required) {
            return Err(PackError::invalid(format!(
                "{} is missing the required entry {required:?}",
                package_path.display()
            )));
        }
    }

    let package_dir = gameinfo::package_dir(root, &title);
    let replaced = package_dir.exists();
    if replaced && !options.replace {
        return Err(PackError::invalid(format!(
            "a package for {title} already exists at {}; pass --replace to overwrite its build files (user data such as pushed ROMs is kept)",
            package_dir.display()
        )));
    }

    // --- stage validated files next to the package --------------------------
    let packages_root = gameinfo::packages_root(root);
    std::fs::create_dir_all(&packages_root).map_err(|error| PackError::io(&packages_root, error))?;
    let staging = packages_root.join(format!(".import-{title}"));
    if staging.exists() {
        std::fs::remove_dir_all(&staging).map_err(|error| PackError::io(&staging, error))?;
    }
    std::fs::create_dir_all(&staging).map_err(|error| PackError::io(&staging, error))?;
    let staged = match import_into_staging(&mut archive, package_path, &manifest, &staging) {
        Ok(staged) => staged,
        Err(error) => {
            let _ = std::fs::remove_dir_all(&staging);
            return Err(error);
        }
    };

    // --- publish: create the package dir and move validated files in --------
    let mut warnings = staged.warnings;
    let publish = (|| -> Result<()> {
        std::fs::create_dir_all(&package_dir).map_err(|error| PackError::io(&package_dir, error))?;
        replace_file(&staging.join(GAME_PACK_FILE), &package_dir.join(GAME_PACK_FILE))?;
        if let Some(cover) = &staged.cover_file {
            replace_file(&staging.join(cover), &package_dir.join(cover))?;
        }
        if let Some(rom_file) = &staged.rom_file {
            replace_file(&staging.join(rom_file), &package_dir.join(rom_file))?;
        }
        replace_file(&staging.join(GAME_INFO_FILE), &package_dir.join(GAME_INFO_FILE))?;
        Ok(())
    })();
    if let Err(error) = publish {
        let _ = std::fs::remove_dir_all(&staging);
        return Err(error);
    }
    let _ = std::fs::remove_dir_all(&staging);

    // --- queue/state: a built package the launchers can deploy --------------
    let mut queue = Queue::load(root)?;
    let existing_rom_path = queue
        .get(&title)
        .map(|entry| entry.rom_path.clone())
        .filter(|path| !path.trim().is_empty());
    let rom_path = match (&staged.rom_file, existing_rom_path) {
        (Some(rom_file), _) => package_dir
            .join(rom_file)
            .display()
            .to_string(),
        (None, existing) => existing.unwrap_or_default(),
    };
    queue.upsert(QueueEntry {
        title_id: title.clone(),
        rom_path,
        display_name: manifest.display_name.clone(),
        product_code: manifest.product_code.clone(),
        slug: plan::slug_for(&manifest.display_name, &title),
        aot_version: manifest.aot_version,
        state: QueueState::Built,
        error: None,
    });
    queue.save(root)?;

    if staged.rom_file.is_none() {
        warnings.push(
            "the imported build package does not contain game data; deploying it needs the original ROM".to_string(),
        );
    }
    if replaced {
        warnings.push(format!(
            "replaced the existing package metadata for {title}; unrelated files in the package directory were kept"
        ));
    }
    Ok(ImportedBuild {
        title_id: title,
        display_name: manifest.display_name.clone(),
        path: path_string(package_path),
        package_dir: path_string(&package_dir),
        pack_bytes: manifest.pack.bytes,
        pack_sha256: manifest.pack.sha256.clone(),
        rom_included: staged.rom_file.is_some(),
        replaced,
        warnings,
    })
}

struct StagedImport {
    cover_file: Option<String>,
    rom_file: Option<String>,
    warnings: Vec<String>,
}

fn copy_archive_entry(
    archive: &mut ZipArchive<BufReader<std::fs::File>>,
    name: &str,
    destination: &Path,
) -> Result<builder_core::hash::HashResult> {
    let index = archive.find(name).ok_or_else(|| {
        PackError::invalid(format!("the build package is missing the entry {name:?}"))
    })?;
    let file =
        std::fs::File::create(destination).map_err(|error| PackError::io(destination, error))?;
    let mut buffered = BufWriter::new(file);
    let mut hashing = HashingWriter::new(&mut buffered);
    archive
        .copy_to(index, &mut hashing)
        .map_err(|error| PackError::io(destination, error))?;
    hashing
        .flush()
        .map_err(|error| PackError::io(destination, error))?;
    let sha256 = hashing.finish();
    buffered
        .flush()
        .map_err(|error| PackError::io(destination, error))?;
    let bytes = file_size(destination)?;
    Ok(builder_core::hash::HashResult { sha256, bytes })
}

fn import_into_staging(
    archive: &mut ZipArchive<BufReader<std::fs::File>>,
    package_path: &Path,
    manifest: &BuildManifest,
    staging: &Path,
) -> Result<StagedImport> {
    let title = &manifest.title_id;
    let mut warnings = Vec::new();

    // --- GamePack: hash + size + Mach-O magic ------------------------------
    let pack_stage = staging.join(GAME_PACK_FILE);
    let pack_hash = copy_archive_entry(archive, &manifest.pack.file, &pack_stage)?;
    if pack_hash.bytes != manifest.pack.bytes || pack_hash.sha256 != manifest.pack.sha256 {
        return Err(PackError::invalid(format!(
            "{title}: the GamePack inside {} is {} bytes / {} but manifest.json records {} bytes / {}",
            package_path.display(),
            pack_hash.bytes,
            pack_hash.sha256,
            manifest.pack.bytes,
            manifest.pack.sha256
        )));
    }
    let mut prefix = [0_u8; 8];
    {
        use std::io::Read;
        let mut file =
            std::fs::File::open(&pack_stage).map_err(|error| PackError::io(&pack_stage, error))?;
        let read = file
            .read(&mut prefix)
            .map_err(|error| PackError::io(&pack_stage, error))?;
        if read < 4 || !gameinfo::looks_like_macho(&prefix[..read]) {
            return Err(PackError::invalid(format!(
                "{title}: the GamePack inside the build package is not a Mach-O dylib"
            )));
        }
    }

    // --- GameInfo.json -----------------------------------------------------
    let game_info_index = archive
        .find(GAME_INFO_FILE)
        .ok_or_else(|| PackError::invalid(format!("the build package has no {GAME_INFO_FILE}")))?;
    let game_info_bytes = archive
        .read_to_vec(game_info_index)
        .map_err(|error| PackError::io(package_path, error))?;
    if sha256_hex(&game_info_bytes) != manifest.game_info_sha256 {
        return Err(PackError::invalid(format!(
            "{title}: {GAME_INFO_FILE} inside the build package does not match manifest.gameInfoSha256"
        )));
    }
    let game_info_text = String::from_utf8(game_info_bytes.clone())
        .map_err(|_| PackError::invalid(format!("{title}: {GAME_INFO_FILE} is not valid UTF-8")))?;
    let game_info = GameInfo::from_json(&game_info_text, package_path)?;
    if game_info.title_id != manifest.title_id {
        return Err(PackError::invalid(format!(
            "{title}: {GAME_INFO_FILE} belongs to {}",
            game_info.title_id
        )));
    }
    let game_info_pack = game_info.pack.clone().ok_or_else(|| {
        PackError::invalid(format!(
            "{title}: {GAME_INFO_FILE} has no pack record; the .32a is corrupt"
        ))
    })?;
    if game_info_pack.sha256 != manifest.pack.sha256
        || game_info_pack.bytes != manifest.pack.bytes
        || game_info_pack.format != PackFormat::Macho
    {
        return Err(PackError::invalid(format!(
            "{title}: {GAME_INFO_FILE} pack record does not match manifest.json"
        )));
    }

    // --- optional cover ----------------------------------------------------
    let cover_file = match &manifest.cover_sha256 {
        Some(expected_sha) => {
            let staged = staging.join(COVER_FILE);
            let hash = copy_archive_entry(archive, COVER_FILE, &staged)?;
            if &hash.sha256 != expected_sha {
                return Err(PackError::invalid(format!(
                    "{title}: {COVER_FILE} inside the build package does not match manifest.coverSha256"
                )));
            }
            if game_info.cover_path.as_deref() != Some(COVER_FILE) {
                return Err(PackError::invalid(format!(
                    "{title}: manifest.json includes a cover but {GAME_INFO_FILE} does not record coverPath {COVER_FILE}"
                )));
            }
            Some(COVER_FILE.to_string())
        }
        None => {
            if game_info.cover_path.is_some() {
                return Err(PackError::invalid(format!(
                    "{title}: {GAME_INFO_FILE} records a cover but manifest.json has no coverSha256"
                )));
            }
            None
        }
    };

    // --- optional bundled ROM ----------------------------------------------
    let rom_file = match (&manifest.rom.included, manifest.rom.file.as_deref()) {
        (true, Some(rom_name)) => {
            let expected_sha = manifest.rom.sha256.as_deref().unwrap_or_default();
            let expected_bytes = manifest.rom.bytes.unwrap_or(0);
            let staged = staging.join(rom_name);
            let hash = copy_archive_entry(archive, rom_name, &staged)?;
            if hash.bytes != expected_bytes || hash.sha256 != expected_sha {
                return Err(PackError::invalid(format!(
                    "{title}: {rom_name} inside the build package does not match manifest.rom"
                )));
            }
            let detected = rom::detect_rom(&staged)?;
            if detected.title_id != manifest.title_id {
                return Err(PackError::invalid(format!(
                    "{title}: the bundled ROM belongs to {}",
                    detected.title_id
                )));
            }
            match (
                game_info.rom_file.as_deref(),
                game_info.rom_sha256.as_deref(),
                game_info.rom_bytes,
            ) {
                (Some(file), Some(sha), Some(bytes))
                    if file == rom_name && sha == expected_sha && bytes == expected_bytes => {}
                _ => {
                    return Err(PackError::invalid(format!(
                        "{title}: {GAME_INFO_FILE} ROM record does not match manifest.rom"
                    )));
                }
            }
            Some(rom_name.to_string())
        }
        (false, _) => {
            if game_info.rom_file.is_some() {
                return Err(PackError::invalid(format!(
                    "{title}: {GAME_INFO_FILE} records a bundled ROM but manifest.json says rom.included is false"
                )));
            }
            warnings.push(format!(
                "{title}: the build package has no bundled ROM; deploying it needs the original ROM"
            ));
            None
        }
        (true, None) => {
            return Err(PackError::invalid(format!(
                "{title}: manifest.json says rom.included is true but lists no rom.file"
            )));
        }
    };

    // --- GameInfo.json (staged last) ---------------------------------------
    std::fs::write(staging.join(GAME_INFO_FILE), &game_info_bytes)
        .map_err(|error| PackError::io(staging.join(GAME_INFO_FILE), error))?;
    Ok(StagedImport {
        cover_file,
        rom_file,
        warnings,
    })
}

/// List every .32a in the builds directory with its manifest metadata.
pub fn list(root: &Path) -> Result<(Vec<BuildSummary>, Vec<(PathBuf, String)>)> {
    let directory = builds_root(root);
    let entries = match std::fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((Vec::new(), Vec::new()))
        }
        Err(error) => return Err(PackError::io(&directory, error)),
    };
    let mut paths: Vec<PathBuf> = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| PackError::io(&directory, error))?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let is_build = path
            .extension()
            .map(|extension| extension.eq_ignore_ascii_case(BUILD_PACKAGE_EXTENSION))
            .unwrap_or(false);
        if is_build {
            paths.push(path);
        }
    }
    paths.sort();
    let mut summaries = Vec::new();
    let mut errors = Vec::new();
    for path in paths {
        match summarize_build(&path) {
            Ok(summary) => summaries.push(summary),
            Err(error) => errors.push((path, error.to_string())),
        }
    }
    Ok((summaries, errors))
}

fn summarize_build(path: &Path) -> Result<BuildSummary> {
    let bytes = file_size(path)?;
    let file = std::fs::File::open(path).map_err(|error| PackError::io(path, error))?;
    let mut archive =
        ZipArchive::open(BufReader::new(file)).map_err(|error| PackError::io(path, error))?;
    let index = archive
        .find(MANIFEST_FILE)
        .ok_or_else(|| PackError::invalid(format!("{} has no {MANIFEST_FILE}", path.display())))?;
    {
        let entry = archive
            .entry(index)
            .ok_or_else(|| PackError::invalid("manifest index is out of range"))?;
        if entry.uncompressed_size > MAX_MANIFEST_BYTES {
            return Err(PackError::invalid(format!(
                "{} has an oversized {MANIFEST_FILE}",
                path.display()
            )));
        }
    }
    let manifest_bytes = archive
        .read_to_vec(index)
        .map_err(|error| PackError::io(path, error))?;
    let text = String::from_utf8(manifest_bytes)
        .map_err(|_| PackError::invalid(format!("{} has a non-UTF-8 manifest", path.display())))?;
    let manifest = BuildManifest::from_json(&text, path)?;
    Ok(BuildSummary {
        title_id: manifest.title_id,
        display_name: manifest.display_name,
        path: path_string(path),
        bytes,
        schema_version: manifest.schema_version,
        aot_version: manifest.aot_version,
        built_at: manifest.built_at,
        platform: manifest.platform,
        app_version: manifest.app_version,
        rom_included: manifest.rom.included,
        pack_bytes: manifest.pack.bytes,
        pack_sha256: manifest.pack.sha256,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gameinfo::CoverSource;
    use crate::rom::test_support::{synthetic_ncsd, write_rom};
    use tempfile::tempdir;

    const TITLE_ID: &str = "0004000000055E00";

    fn fake_macho() -> Vec<u8> {
        let mut bytes: Vec<u8> = (0..4096).map(|index| (index * 7) as u8).collect();
        bytes[..4].copy_from_slice(&[0xCF, 0xFA, 0xED, 0xFE]);
        bytes
    }

    fn make_package(root: &Path, with_rom: bool, with_cover: bool) -> PathBuf {
        std::fs::create_dir_all(root).unwrap();
        let rom_path = root.join("ExampleGame.cci");
        write_rom(
            &rom_path,
            &synthetic_ncsd(0x0004_0000_0005_5E00, "CTR-T-EXMP", 8),
        );
        let rom = rom::detect_rom(&rom_path).unwrap();
        let mut info = GameInfo::new(&rom, "Example Game", "CTR-T-EXMP", 1).unwrap();
        let package_dir = gameinfo::package_dir(root, TITLE_ID);
        std::fs::create_dir_all(&package_dir).unwrap();
        if with_cover {
            std::fs::write(package_dir.join(COVER_FILE), b"fake-png-cover-bytes").unwrap();
            info.cover_path = Some(COVER_FILE.to_string());
            info.cover_source = Some(CoverSource::Smdh);
        }
        info.write(&package_dir).unwrap();
        let fake_pack = root.join("fake-GamePack.dylib");
        std::fs::write(&fake_pack, fake_macho()).unwrap();
        gameinfo::install_pack(&package_dir, &fake_pack).unwrap();
        if with_rom {
            gameinfo::install_rom(&package_dir, &rom_path).unwrap();
        }
        package_dir
    }

    fn options() -> ExportOptions {
        ExportOptions {
            app_version: "0.2.2".to_string(),
            launcher_version: "test-launcher/0.2.2".to_string(),
            toolchain: BuildToolchain {
                clang: "23.1.6".to_string(),
                llvm: "23.1.6".to_string(),
            },
            built_at: Some("2026-01-02T03:04:05Z".to_string()),
            ..Default::default()
        }
    }

    fn sample_manifest() -> BuildManifest {
        BuildManifest {
            format: BUILD_FORMAT.to_string(),
            schema_version: BUILD_SCHEMA_VERSION,
            title_id: TITLE_ID.to_string(),
            display_name: "Example Game".to_string(),
            product_code: "CTR-T-EXMP".to_string(),
            aot_version: 1,
            app_version: "0.2.2".to_string(),
            built_at: "2026-01-02T03:04:05Z".to_string(),
            platform: "windows".to_string(),
            toolchain: BuildToolchain {
                clang: "23.1.6".to_string(),
                llvm: "23.1.6".to_string(),
            },
            build_options: BuildOptions::default(),
            pack: BuildPackRef {
                file: pack_file_name(TITLE_ID),
                bytes: 4096,
                sha256: "a".repeat(64),
                format: PACK_FORMAT_MACHO.to_string(),
                abi_version: GAMEPACK_ABI_VERSION,
            },
            game_info_sha256: "b".repeat(64),
            cover_sha256: None,
            rom: default_absent_rom(),
            source_launcher: SourceLauncher {
                os: "windows".to_string(),
                version: "0.2.2".to_string(),
            },
        }
    }

    fn rewrite_zip(
        source: &Path,
        destination: &Path,
        mutate: impl Fn(&str, Vec<u8>) -> Vec<u8>,
    ) {
        let file = std::fs::File::open(source).unwrap();
        let mut archive = ZipArchive::open(BufReader::new(file)).unwrap();
        let names: Vec<String> = archive
            .entries()
            .iter()
            .map(|entry| entry.name.clone())
            .collect();
        let output = std::fs::File::create(destination).unwrap();
        let mut writer = ZipWriter::new(BufWriter::new(output));
        for name in names {
            let index = archive.find(&name).unwrap();
            let bytes = archive.read_to_vec(index).unwrap();
            let bytes = mutate(&name, bytes);
            writer.add_data(&name, &bytes).unwrap();
        }
        let mut buffered = writer.finish().unwrap();
        buffered.flush().unwrap();
    }

    #[test]
    fn timestamps_and_names_are_canonical() {
        assert_eq!(format_iso8601_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_iso8601_utc(1_700_000_000), "2023-11-14T22:13:20Z");
        assert!(is_iso8601_utc("2026-01-02T03:04:05Z"));
        assert!(!is_iso8601_utc("2026-01-02 03:04:05"));
        assert!(!is_iso8601_utc("2026-01-02T03:04:05"));
        assert_eq!(
            build_package_file_name("Example Game", TITLE_ID),
            "0004000000055E00-Example Game.32a"
        );
        assert_eq!(
            sanitize_file_name("Example/Game: Demo?*"),
            "Example_Game_ Demo__"
        );
        assert_eq!(sanitize_file_name("  "), "game");
        assert_eq!(
            pack_file_name(TITLE_ID),
            "GamePack-0004000000055E00.dylib"
        );
        assert_eq!(BuildOptions::default().cache_marker(), "opt=O2;lto=0;fastmath=0");
    }

    #[test]
    fn manifest_validation_rejects_bad_fields() {
        let manifest = sample_manifest();
        manifest.validate().unwrap();
        let json = manifest.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["format"], BUILD_FORMAT);
        assert_eq!(parsed["schemaVersion"], 1);
        assert_eq!(parsed["titleID"], TITLE_ID);
        assert_eq!(parsed["pack"]["abiVersion"], 1);
        assert_eq!(parsed["buildOptions"]["optLevel"], "O2");
        assert!(parsed["rom"]["included"].as_bool().unwrap() == false);

        let mut bad = sample_manifest();
        bad.format = "other".to_string();
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.schema_version = BUILD_SCHEMA_VERSION + 1;
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.title_id = "0004000000055e00".to_string();
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.pack.bytes = 0;
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.pack.sha256 = "A".repeat(64);
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.build_options.opt_level = "O4".to_string();
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.built_at = "yesterday".to_string();
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.rom.included = true;
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.display_name = String::new();
        assert!(bad.validate().is_err());
        let mut bad = sample_manifest();
        bad.pack.abi_version = GAMEPACK_ABI_VERSION + 1;
        assert!(bad.validate().is_err());
        let parsed = BuildManifest::from_json(&json, Path::new("manifest.json")).unwrap();
        assert_eq!(parsed, manifest);
    }

    #[test]
    fn export_and_import_round_trip() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root1");
        make_package(&root, true, true);
        let report = export(&root, Some(&[TITLE_ID.to_string()]), &options()).unwrap();
        assert!(report.errors.is_empty(), "{:?}", report.errors);
        assert_eq!(report.builds.len(), 1);
        let build = &report.builds[0];
        assert!(build.rom_included);
        assert!(Path::new(&build.path).is_file());
        assert!(build.path.ends_with("0004000000055E00-Example Game.32a"));
        assert_eq!(build.title_id, TITLE_ID);
        assert!(report.output_dir.ends_with("builds"));

        let (summaries, errors) = list(&root).unwrap();
        assert!(errors.is_empty());
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].title_id, TITLE_ID);
        assert!(summaries[0].rom_included);
        assert_eq!(summaries[0].built_at, "2026-01-02T03:04:05Z");
        assert_eq!(summaries[0].app_version, "0.2.2");
        assert_eq!(summaries[0].pack_bytes, build.pack_bytes);

        let root2 = temp.path().join("root2");
        std::fs::create_dir_all(&root2).unwrap();
        let imported = import(&root2, Path::new(&build.path), &ImportOptions::default()).unwrap();
        assert_eq!(imported.title_id, TITLE_ID);
        assert_eq!(imported.display_name, "Example Game");
        assert!(imported.rom_included);
        assert!(!imported.replaced);
        let package_dir = gameinfo::package_dir(&root2, TITLE_ID);
        assert!(package_dir.join(GAME_PACK_FILE).is_file());
        assert!(package_dir.join(GAME_INFO_FILE).is_file());
        assert!(package_dir.join("GameRom.cci").is_file());
        assert!(package_dir.join(COVER_FILE).is_file());
        let verification = gameinfo::verify_package(&package_dir).unwrap();
        assert!(verification.ok, "{:?}", verification.issues);
        let written = GameInfo::read(&package_dir).unwrap();
        assert_eq!(written.title_id, TITLE_ID);
        assert!(written.rom_file.is_some());
        assert_eq!(written.cover_path.as_deref(), Some(COVER_FILE));
        let queue = Queue::load(&root2).unwrap();
        assert_eq!(queue.get(TITLE_ID).unwrap().state, QueueState::Built);
        assert_eq!(
            queue.get(TITLE_ID).unwrap().slug,
            "example-game-00055e00"
        );
    }

    #[test]
    fn export_without_rom_succeeds_with_a_warning() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        make_package(&root, false, false);
        let report = export(&root, Some(&[TITLE_ID.to_string()]), &options()).unwrap();
        assert!(report.errors.is_empty());
        let build = &report.builds[0];
        assert!(!build.rom_included);
        assert!(!build.warnings.is_empty());

        let (summaries, errors) = list(&root).unwrap();
        assert!(errors.is_empty());
        assert!(!summaries[0].rom_included);

        let root2 = temp.path().join("root2");
        std::fs::create_dir_all(&root2).unwrap();
        let imported = import(&root2, Path::new(&build.path), &ImportOptions::default()).unwrap();
        assert!(!imported.rom_included);
        assert!(imported
            .warnings
            .iter()
            .any(|warning| warning.contains("does not contain game data")));
    }

    #[test]
    fn export_uses_the_queue_rom_path_when_the_package_has_no_copy() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        make_package(&root, false, false);
        let rom_path = root.join("ExampleGame.cci");
        let mut queue = Queue::default();
        queue.upsert(QueueEntry {
            title_id: TITLE_ID.to_string(),
            rom_path: rom_path.display().to_string(),
            display_name: "Example Game".to_string(),
            product_code: "CTR-T-EXMP".to_string(),
            slug: "example-game-00055e00".to_string(),
            aot_version: 1,
            state: QueueState::Built,
            error: None,
        });
        queue.save(&root).unwrap();
        let report = export(&root, Some(&[TITLE_ID.to_string()]), &options()).unwrap();
        assert!(report.errors.is_empty());
        assert!(report.builds[0].rom_included);
    }

    #[test]
    fn import_requires_replace_and_keeps_user_data() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        make_package(&root, true, false);
        let build = export(&root, Some(&[TITLE_ID.to_string()]), &options())
            .unwrap()
            .builds
            .remove(0);
        let root2 = temp.path().join("root2");
        std::fs::create_dir_all(&root2).unwrap();
        import(&root2, Path::new(&build.path), &ImportOptions::default()).unwrap();
        let package_dir = gameinfo::package_dir(&root2, TITLE_ID);
        let user_file = package_dir.join("user-notes.txt");
        std::fs::write(&user_file, b"keep me").unwrap();

        let error = import(&root2, Path::new(&build.path), &ImportOptions::default()).unwrap_err();
        assert!(error.to_string().contains("--replace"), "{error}");

        let replaced = import(
            &root2,
            Path::new(&build.path),
            &ImportOptions { replace: true },
        )
        .unwrap();
        assert!(replaced.replaced);
        assert!(user_file.is_file());
        assert_eq!(std::fs::read(&user_file).unwrap(), b"keep me");
    }

    #[test]
    fn import_rejects_tampered_pack_bytes() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        make_package(&root, true, false);
        let build = export(&root, Some(&[TITLE_ID.to_string()]), &options())
            .unwrap()
            .builds
            .remove(0);
        let tampered = temp.path().join("tampered.32a");
        let pack_name = pack_file_name(TITLE_ID);
        rewrite_zip(Path::new(&build.path), &tampered, |name, mut bytes| {
            if name == pack_name {
                bytes[16] ^= 0xFF;
            }
            bytes
        });
        let root2 = temp.path().join("root2");
        std::fs::create_dir_all(&root2).unwrap();
        let error = import(&root2, &tampered, &ImportOptions::default()).unwrap_err();
        let message = error.to_string();
        assert!(
            message.contains("GamePack") || message.contains("manifest"),
            "{message}"
        );
        assert!(!gameinfo::package_dir(&root2, TITLE_ID).join(GAME_INFO_FILE).is_file());
    }

    #[test]
    fn import_rejects_newer_manifest_schema() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        make_package(&root, true, false);
        let build = export(&root, Some(&[TITLE_ID.to_string()]), &options())
            .unwrap()
            .builds
            .remove(0);
        let newer = temp.path().join("newer.32a");
        rewrite_zip(Path::new(&build.path), &newer, |name, bytes| {
            if name == MANIFEST_FILE {
                let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                value["schemaVersion"] = serde_json::Value::from(2);
                return serde_json::to_vec_pretty(&value).unwrap();
            }
            bytes
        });
        let root2 = temp.path().join("root2");
        std::fs::create_dir_all(&root2).unwrap();
        let error = import(&root2, &newer, &ImportOptions::default()).unwrap_err();
        assert!(error.to_string().contains("schemaVersion"), "{error}");
    }

    #[test]
    fn import_rejects_unknown_entries() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        make_package(&root, true, false);
        let build = export(&root, Some(&[TITLE_ID.to_string()]), &options())
            .unwrap()
            .builds
            .remove(0);
        let smuggled = temp.path().join("smuggled.32a");
        let file = std::fs::File::open(&build.path).unwrap();
        let mut archive = ZipArchive::open(BufReader::new(file)).unwrap();
        let names: Vec<String> = archive
            .entries()
            .iter()
            .map(|entry| entry.name.clone())
            .collect();
        let output = std::fs::File::create(&smuggled).unwrap();
        let mut writer = ZipWriter::new(BufWriter::new(output));
        for name in names {
            let index = archive.find(&name).unwrap();
            let bytes = archive.read_to_vec(index).unwrap();
            writer.add_data(&name, &bytes).unwrap();
        }
        writer.add_data("evil.txt", b"smuggled").unwrap();
        let mut buffered = writer.finish().unwrap();
        buffered.flush().unwrap();
        let root2 = temp.path().join("root2");
        std::fs::create_dir_all(&root2).unwrap();
        let error = import(&root2, &smuggled, &ImportOptions::default()).unwrap_err();
        assert!(error.to_string().contains("unexpected entry"), "{error}");
    }

    #[test]
    fn list_reports_corrupt_entries_without_failing() {
        let temp = tempdir().unwrap();
        let root = temp.path().join("root");
        std::fs::create_dir_all(builds_root(&root)).unwrap();
        std::fs::write(builds_root(&root).join("broken.32a"), b"not a zip").unwrap();
        let (summaries, errors) = list(&root).unwrap();
        assert!(summaries.is_empty());
        assert_eq!(errors.len(), 1);
        assert!(list(&temp.path().join("missing-root"))
            .unwrap()
            .0
            .is_empty());
    }
}
