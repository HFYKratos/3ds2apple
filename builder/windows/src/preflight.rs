//! Local preflight: validate the ROM (and optional supplementary file) before a
//! single byte is uploaded, and check the output volume.
//!
//! The goal is to fail on this PC with a fixable message rather than after a
//! multi-gigabyte upload. Everything here is read-only except
//! [`prepare_output_dir`], which creates the output directory and proves it is
//! writable.

use std::path::{Path, PathBuf};

use builder_core::protocol;

use crate::errors::FrontendError;
use crate::probe;
use crate::{paths, MINIMUM_FREE_BYTES, RECOMMENDED_FREE_BYTES};

/// A local file that will be declared to the Agent as an input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputFile {
    /// Absolute path as the local filesystem reports it (on Windows this can be
    /// an extended-length `\\?\` path).
    pub path: PathBuf,
    /// Display name (never used as a path on the Agent).
    pub name: String,
    pub bytes: u64,
    /// Non-fatal observations (long path, Unicode name, ...).
    pub warnings: Vec<String>,
}

/// What to do about free space on the output volume.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskStatus {
    /// Enough space for the IPA and its manifest.
    Ok,
    /// Enough to proceed, but below the recommended amount.
    Limited,
    /// Not enough space; refuse the download.
    Insufficient,
    /// The platform probe could not report free space.
    Unknown,
}

/// Options that are sent with the job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanOptions {
    pub embed_moltenvk: bool,
    pub hardware_renderer: bool,
    pub clean: bool,
    pub keep_input: bool,
}

impl Default for PlanOptions {
    fn default() -> Self {
        Self {
            embed_moltenvk: true,
            hardware_renderer: false,
            clean: false,
            keep_input: false,
        }
    }
}

/// A fully validated build request, ready to be sent to an Agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildPlan {
    /// Host id or name from the shared configuration.
    pub host: String,
    pub rom: InputFile,
    /// Optional supplementary file; the current pipeline does not read it.
    pub keys: Option<InputFile>,
    /// Build name (`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`) used by the build scripts.
    pub name: String,
    /// Home-screen display name; Unicode and CJK are allowed.
    pub display_name: String,
    /// Optional bundle identifier override (advanced).
    pub bundle_id: Option<String>,
    /// Optional 16-hex title id override (advanced).
    pub title_id: Option<String>,
    /// Optional expected 3ds2apple source revision on the Mac.
    pub expected_revision: Option<String>,
    pub out_dir: PathBuf,
    pub options: PlanOptions,
}

/// Format a byte count for humans (matches the `zkb` CLI).
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

fn absolute_existing(path: &Path) -> PathBuf {
    // `canonicalize` also resolves symlinks and, on Windows, returns the
    // extended-length form for long paths.
    path.canonicalize().unwrap_or_else(|_| {
        if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()
                .map(|directory| directory.join(path))
                .unwrap_or_else(|_| path.to_path_buf())
        }
    })
}

fn local_warnings(path: &Path) -> Vec<String> {
    let mut warnings = Vec::new();
    let text = paths::display_path(path);
    for warning in paths::path_warnings(&text) {
        warnings.push(warning);
    }
    if text.encode_utf16().count() > paths::MAX_PATH {
        warnings.push(format!(
            "the path is longer than the classic {} character limit; the Builder uses extended-length paths, but other tools may not",
            paths::MAX_PATH
        ));
    }
    warnings
}

fn check_input_name(name: &str) -> Result<(), FrontendError> {
    if name.is_empty() {
        return Err(FrontendError::usage("the selected file has no name"));
    }
    if name.chars().count() > 255 {
        return Err(FrontendError::usage(
            "the selected file name is longer than the 255 character limit the Agent accepts",
        ));
    }
    if name.chars().any(char::is_control) {
        return Err(FrontendError::usage(
            "the selected file name contains control characters; rename it first",
        ));
    }
    Ok(())
}

/// Validate a ROM selected on this PC.
pub fn check_rom(path: &Path, allow_any_extension: bool) -> Result<InputFile, FrontendError> {
    if path.as_os_str().is_empty() {
        return Err(FrontendError::usage("no ROM file selected"));
    }
    if !path.exists() {
        return Err(FrontendError::usage(format!(
            "ROM file {} does not exist",
            paths::display_path(path)
        )));
    }
    if !path.is_file() {
        return Err(FrontendError::usage(format!(
            "{} is a directory; select a .3ds or .cci file",
            paths::display_path(path)
        )));
    }
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .unwrap_or_default();
    if !allow_any_extension && extension != "3ds" && extension != "cci" {
        return Err(FrontendError::usage(format!(
            "{} does not look like a decrypted .3ds/.cci ROM; rename it to the right extension or pass --allow-any-file",
            paths::display_path(path)
        )));
    }
    let absolute = absolute_existing(path);
    let metadata = std::fs::metadata(&absolute).map_err(|error| {
        FrontendError::local(format!(
            "cannot read {}: {error}",
            paths::display_path(&absolute)
        ))
    })?;
    let bytes = metadata.len();
    if bytes == 0 {
        return Err(FrontendError::usage(format!(
            "{} is empty",
            paths::display_path(&absolute)
        )));
    }
    let name = absolute
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .ok_or_else(|| FrontendError::usage("the ROM path has no file name"))?;
    check_input_name(&name)?;
    let mut warnings = local_warnings(&absolute);
    if !extension.is_empty() && !matches!(extension.as_str(), "3ds" | "cci") {
        warnings.push(format!(
            "the ROM extension is {extension:?}; the build scripts expect .3ds or .cci"
        ));
    }
    if !name.is_ascii() {
        warnings.push(
            "the ROM file name contains non-ASCII characters; they are supported, but build names and logs stay ASCII"
                .to_string(),
        );
    }
    Ok(InputFile {
        path: absolute,
        name,
        bytes,
        warnings,
    })
}

/// Validate an optional supplementary file (for example a keys file).
///
/// The current per-game pipeline builds from a decrypted ROM and does not read
/// supplementary files; they are uploaded to the user's own Agent unmodified for
/// future tooling and deletion with the job.
pub fn check_supplementary(path: &Path) -> Result<InputFile, FrontendError> {
    if !path.exists() || !path.is_file() {
        return Err(FrontendError::usage(format!(
            "supplementary file {} does not exist",
            paths::display_path(path)
        )));
    }
    let absolute = absolute_existing(path);
    let metadata = std::fs::metadata(&absolute).map_err(|error| {
        FrontendError::local(format!(
            "cannot read {}: {error}",
            paths::display_path(&absolute)
        ))
    })?;
    if metadata.len() == 0 {
        return Err(FrontendError::usage(format!(
            "{} is empty",
            paths::display_path(&absolute)
        )));
    }
    let name = absolute
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .ok_or_else(|| FrontendError::usage("the supplementary path has no file name"))?;
    check_input_name(&name)?;
    let mut warnings = local_warnings(&absolute);
    warnings.push(
        "the current pipeline builds from a decrypted ROM and does not read a keys file; this file is uploaded only to your own Agent and deleted with the job"
            .to_string(),
    );
    Ok(InputFile {
        path: absolute,
        name,
        bytes: metadata.len(),
        warnings,
    })
}

/// Derive the build name and home-screen name from a ROM file name.
///
/// The build name is always an ASCII slug because the build scripts use it as a
/// directory name; the display name keeps Unicode.
pub fn derive_names(rom_name: &str) -> (String, String) {
    let stem = Path::new(rom_name)
        .file_stem()
        .map(|stem| stem.to_string_lossy().to_string())
        .unwrap_or_else(|| rom_name.to_string());
    let mut build_name = protocol::slugify_game_name(&stem);
    if protocol::validate_game_name(&build_name).is_err() {
        build_name = "game".to_string();
    }
    let mut display_name = sanitize_display_name(&stem).unwrap_or_else(|| "Game".to_string());
    if protocol::validate_display_name(&display_name).is_err() {
        display_name = "Game".to_string();
    }
    (build_name, display_name)
}

fn sanitize_display_name(raw: &str) -> Option<String> {
    let cleaned: String = raw
        .chars()
        .filter(|character| !character.is_control())
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() {
        return None;
    }
    Some(cleaned.chars().take(48).collect())
}

/// Normalise and validate a user-provided home-screen name.
pub fn normalize_display_name(raw: &str) -> Result<String, FrontendError> {
    let name = sanitize_display_name(raw).ok_or_else(|| {
        FrontendError::usage("the home-screen name is empty; it must contain printable characters")
    })?;
    protocol::validate_display_name(&name)
        .map_err(|message| FrontendError::usage(format!("home-screen name: {message}")))?;
    Ok(name)
}

/// Validate an optional bundle identifier override.
pub fn normalize_bundle_id(raw: &str) -> Result<String, FrontendError> {
    let bundle_id = raw.trim();
    protocol::validate_bundle_id(bundle_id)
        .map_err(|message| FrontendError::usage(format!("bundle id: {message}")))?;
    Ok(bundle_id.to_string())
}

/// Validate an optional title id override (16 hex characters).
pub fn normalize_title_id(raw: &str) -> Result<String, FrontendError> {
    let title_id = raw.trim();
    if !protocol::valid_title_id(title_id) {
        return Err(FrontendError::usage(
            "title id must be 16 hex characters, for example 0004000000055E00",
        ));
    }
    Ok(title_id.to_string())
}

/// Validate an optional expected source revision.
pub fn normalize_expected_revision(raw: &str) -> Result<String, FrontendError> {
    let revision = raw.trim();
    let valid =
        (7..=64).contains(&revision.len()) && revision.bytes().all(|byte| byte.is_ascii_hexdigit());
    if !valid {
        return Err(FrontendError::usage(
            "the expected source revision must be a git commit id (7-64 hex characters)",
        ));
    }
    Ok(revision.to_string())
}

/// Normalise and validate a user-provided build name.
pub fn normalize_build_name(raw: &str) -> Result<String, FrontendError> {
    let name = raw.trim();
    protocol::validate_game_name(name)
        .map_err(|message| FrontendError::usage(format!("build name: {message}")))?;
    Ok(name.to_string())
}

/// Classify a free-space value.
pub fn disk_status(free: Option<u64>) -> DiskStatus {
    match free {
        None => DiskStatus::Unknown,
        Some(bytes) if bytes < MINIMUM_FREE_BYTES => DiskStatus::Insufficient,
        Some(bytes) if bytes < RECOMMENDED_FREE_BYTES => DiskStatus::Limited,
        Some(_) => DiskStatus::Ok,
    }
}

/// Check the output volume and refuse only when it is clearly too small.
pub fn check_output_space(out_dir: &Path) -> Result<Vec<String>, FrontendError> {
    let free = probe::free_space(out_dir);
    let mut warnings = Vec::new();
    match disk_status(free) {
        DiskStatus::Ok | DiskStatus::Unknown => {}
        DiskStatus::Limited => warnings.push(format!(
            "only {} free on the output volume; {} is recommended for the IPA, its manifest and temporary files",
            format_bytes(free.unwrap_or(0)),
            format_bytes(RECOMMENDED_FREE_BYTES)
        )),
        DiskStatus::Insufficient => {
            return Err(FrontendError::local(format!(
                "only {} free on the volume that will receive the IPA; free at least {} and try again",
                format_bytes(free.unwrap_or(0)),
                format_bytes(MINIMUM_FREE_BYTES)
            )));
        }
    }
    Ok(warnings)
}

/// Create the output directory and prove it is writable.
pub fn prepare_output_dir(out_dir: &Path) -> Result<PathBuf, FrontendError> {
    paths::ensure_dir(out_dir).map_err(|error| {
        FrontendError::local(format!(
            "cannot create the output directory {}: {error}",
            paths::display_path(out_dir)
        ))
    })?;
    let probe_path = out_dir.join(".builder-write-test");
    std::fs::write(&probe_path, b"ok").map_err(|error| {
        FrontendError::local(format!(
            "cannot write to {}: {error}",
            paths::display_path(out_dir)
        ))
    })?;
    let _ = std::fs::remove_file(&probe_path);
    Ok(out_dir.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_rom(dir: &Path, name: &str, bytes: usize) -> PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, vec![7_u8; bytes]).unwrap();
        path
    }

    #[test]
    fn a_valid_rom_is_accepted_and_counted() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_rom(dir.path(), "Pokemon Y.cci", 4096);
        let rom = check_rom(&path, false).unwrap();
        assert_eq!(rom.name, "Pokemon Y.cci");
        assert_eq!(rom.bytes, 4096);
        assert!(rom.path.is_absolute());
    }

    #[test]
    fn extension_filters_are_case_insensitive_and_overridable() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_rom(dir.path(), "game.3DS", 8);
        assert!(check_rom(&path, false).is_ok());
        let wrong = temp_rom(dir.path(), "game.bin", 8);
        let error = check_rom(&wrong, false).unwrap_err();
        assert!(error.to_string().contains(".3ds/.cci"), "{error}");
        assert!(check_rom(&wrong, true).is_ok());
    }

    #[test]
    fn missing_directories_and_empty_files_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("nope.cci");
        assert!(check_rom(&missing, false)
            .unwrap_err()
            .to_string()
            .contains("does not exist"));
        assert!(check_rom(dir.path(), false)
            .unwrap_err()
            .to_string()
            .contains("directory"));
        let empty = temp_rom(dir.path(), "empty.cci", 0);
        assert!(check_rom(&empty, false)
            .unwrap_err()
            .to_string()
            .contains("empty"));
    }

    #[test]
    fn cjk_file_names_are_supported_and_flagged_informatively() {
        let dir = tempfile::tempdir().unwrap();
        let path = temp_rom(dir.path(), "宝可梦 Y (美版).cci", 64);
        let rom = check_rom(&path, false).unwrap();
        assert_eq!(rom.name, "宝可梦 Y (美版).cci");
        assert!(
            rom.warnings
                .iter()
                .any(|warning| warning.contains("non-ASCII")),
            "{:?}",
            rom.warnings
        );
        let (build, display) = derive_names(&rom.name);
        assert_eq!(display, "宝可梦 Y (美版)");
        assert!(protocol::valid_game_name(&build), "{build}");
        assert!(build.is_ascii());
    }

    #[test]
    fn build_names_are_slugs_and_display_names_keep_unicode() {
        assert_eq!(derive_names("Pokemon Y.cci").0, "pokemon-y");
        assert_eq!(derive_names("Pokemon Y.cci").1, "Pokemon Y");
        let (build, display) = derive_names("塞尔达传说 时之笛.3ds");
        assert!(protocol::valid_game_name(&build));
        assert_eq!(display, "塞尔达传说 时之笛");
        let (build, display) = derive_names("游戏.cci");
        assert_eq!(build, "game");
        assert_eq!(display, "游戏");
        let (_, display) = derive_names(".cci");
        assert!(!display.is_empty());
    }

    #[test]
    fn display_names_are_sanitised_and_validated() {
        assert_eq!(
            normalize_display_name("  Pokemon Y  ").unwrap(),
            "Pokemon Y"
        );
        assert_eq!(normalize_display_name("宝可梦 Y").unwrap(), "宝可梦 Y");
        assert!(normalize_display_name("   ").is_err());
        assert!(normalize_display_name("bad\u{7}name").is_ok());
        let long = "x".repeat(80);
        assert_eq!(normalize_display_name(&long).unwrap().chars().count(), 48);
    }

    #[test]
    fn build_names_must_match_the_scripts_rule() {
        assert!(normalize_build_name("pokemon-y").is_ok());
        assert!(normalize_build_name("Pokemon Y").is_err());
        assert!(normalize_build_name("-leading").is_err());
        assert!(normalize_build_name("").is_err());
    }

    #[test]
    fn supplementary_files_are_validated_with_a_warning() {
        let dir = tempfile::tempdir().unwrap();
        let keys = temp_rom(dir.path(), "prod.keys", 32);
        let file = check_supplementary(&keys).unwrap();
        assert_eq!(file.name, "prod.keys");
        assert!(file
            .warnings
            .iter()
            .any(|warning| warning.contains("does not read a keys file")));
        assert!(check_supplementary(&dir.path().join("nope.keys")).is_err());
    }

    #[test]
    fn disk_thresholds_are_classified() {
        assert_eq!(disk_status(None), DiskStatus::Unknown);
        assert_eq!(disk_status(Some(10)), DiskStatus::Insufficient);
        assert_eq!(disk_status(Some(MINIMUM_FREE_BYTES)), DiskStatus::Limited);
        assert_eq!(disk_status(Some(RECOMMENDED_FREE_BYTES)), DiskStatus::Ok);
        assert_eq!(disk_status(Some(u64::MAX)), DiskStatus::Ok);
    }

    #[test]
    fn output_directory_is_created_and_writable() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("nested").join("out");
        let prepared = prepare_output_dir(&out).unwrap();
        assert_eq!(prepared, out);
        assert!(out.is_dir());
        assert!(!out.join(".builder-write-test").exists());
    }

    #[test]
    fn advanced_overrides_are_validated() {
        assert_eq!(
            normalize_bundle_id("com.example.pokemon-y").unwrap(),
            "com.example.pokemon-y"
        );
        assert!(normalize_bundle_id("not a bundle id").is_err());
        assert_eq!(
            normalize_title_id("0004000000055E00").unwrap(),
            "0004000000055E00"
        );
        assert!(normalize_title_id("123").is_err());
        assert!(normalize_title_id("ZZZZZZZZZZZZZZZZ").is_err());
        assert_eq!(normalize_expected_revision("4cc6186").unwrap(), "4cc6186");
        assert!(normalize_expected_revision("xyz").is_err());
    }

    #[test]
    fn byte_formatting_matches_the_cli() {
        assert_eq!(format_bytes(512), "512 B");
        assert_eq!(format_bytes(1024), "1.0 KiB");
        assert_eq!(format_bytes(3 * 1024 * 1024 * 1024), "3.0 GiB");
    }
}
