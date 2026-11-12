//! Filesystem conventions for the Linux frontend.
//!
//! The Builder's own data directory is the one the shared CLI uses
//! (`$XDG_DATA_HOME/3ds2apple/builder` by default, or `$ZKB_DATA_DIR`), so the
//! frontend's artifacts sit next to the shared CLI's history. ROMs are never
//! copied into that directory: the frontend only reads the path the user chose
//! and hands it to `zkb`, which uploads it to the user's own macOS host.

use std::path::{Path, PathBuf};

/// Environment override for the shared Builder data directory.
pub const ENV_DATA_DIR: &str = "ZKB_DATA_DIR";
/// Environment override for an extra ROM search directory.
pub const ENV_ROM_DIR: &str = "ZKB_ROM_DIR";
/// Environment override for the shared Builder config directory.
pub const ENV_CONFIG_DIR: &str = "ZKB_CONFIG_DIR";

/// Shared Builder data directory (config-adjacent caches and artifacts).
pub fn data_dir() -> PathBuf {
    match std::env::var_os(ENV_DATA_DIR) {
        Some(dir) => PathBuf::from(dir),
        None => builder_core::config::default_data_dir(),
    }
}

/// Directory where downloaded IPAs are collected by default.
pub fn artifacts_dir() -> PathBuf {
    data_dir().join("artifacts")
}

/// Default destination for one game's downloaded IPA.
pub fn default_out_dir(game_name: &str) -> PathBuf {
    artifacts_dir().join(game_name)
}

/// Config file path: the explicit `--config` value, or the shared default.
pub fn config_path(explicit: Option<&Path>) -> PathBuf {
    match explicit {
        Some(path) => path.to_path_buf(),
        None => builder_core::config::default_config_file(),
    }
}

/// Parent directory of a config file (used for profile directories).
pub fn config_dir(config_path: &Path) -> PathBuf {
    config_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// A ROM file found on this machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RomCandidate {
    pub path: PathBuf,
    pub bytes: u64,
}

/// Directories searched when the user does not pass `--rom`.
///
/// Order matters: explicit `--rom-dir` values, then `$ZKB_ROM_DIR`, the current
/// directory, `./ROM`, the repository's `ROM/` directory (the project's local
/// convention) and `~/ROM`.
pub fn rom_search_dirs(
    explicit: &[PathBuf],
    cwd: Option<&Path>,
    home: Option<&Path>,
    env_rom_dir: Option<&Path>,
) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    let mut push = |candidate: PathBuf| {
        if dirs.iter().any(|existing| same_dir(existing, &candidate)) {
            return;
        }
        dirs.push(candidate);
    };
    for dir in explicit {
        push(dir.clone());
    }
    if let Some(dir) = env_rom_dir {
        push(dir.to_path_buf());
    }
    if let Some(cwd) = cwd {
        push(cwd.to_path_buf());
        push(cwd.join("ROM"));
        if let Some(root) = project_root(cwd) {
            push(root.join("ROM"));
        }
    }
    if let Some(home) = home {
        push(home.join("ROM"));
    }
    dirs
}

fn same_dir(left: &Path, right: &Path) -> bool {
    let left = left.canonicalize().unwrap_or_else(|_| left.to_path_buf());
    let right = right.canonicalize().unwrap_or_else(|_| right.to_path_buf());
    left == right
}

/// `.3ds` and `.cci` files in the given directories, without duplicates.
///
/// Only metadata is touched; contents are never read, copied or logged.
pub fn list_roms(dirs: &[PathBuf]) -> Vec<RomCandidate> {
    let mut roms: Vec<RomCandidate> = Vec::new();
    for dir in dirs {
        let entries = match std::fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(_) => continue,
        };
        let mut in_dir: Vec<RomCandidate> = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            if !has_rom_extension(&path, false) {
                continue;
            }
            let bytes = entry.metadata().map(|meta| meta.len()).unwrap_or(0);
            let path = path.canonicalize().unwrap_or(path);
            if roms.iter().any(|existing| existing.path == path) {
                continue;
            }
            in_dir.push(RomCandidate { path, bytes });
        }
        in_dir.sort_by(|left, right| left.path.cmp(&right.path));
        roms.extend(in_dir);
    }
    roms
}

/// Whether a path has a `.3ds`/`.cci` extension (case-insensitive).
pub fn has_rom_extension(path: &Path, allow_any: bool) -> bool {
    if allow_any {
        return true;
    }
    matches!(
        path.extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("3ds") | Some("cci")
    )
}

/// Walk up from `start` to the 3ds2apple source checkout, if any.
pub fn project_root(start: &Path) -> Option<PathBuf> {
    let mut current = Some(start.canonicalize().unwrap_or_else(|_| start.to_path_buf()));
    while let Some(dir) = current {
        if dir.join("builder").join("Cargo.toml").is_file() && dir.join("scripts").is_dir() {
            return Some(dir);
        }
        current = dir.parent().map(Path::to_path_buf);
    }
    None
}

/// Current git revision of a checkout and whether it has uncommitted changes.
pub fn git_revision(root: &Path) -> Option<(String, bool)> {
    let revision = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()?;
    if !revision.status.success() {
        return None;
    }
    let revision = String::from_utf8_lossy(&revision.stdout).trim().to_string();
    if revision.is_empty() {
        return None;
    }
    let dirty = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["status", "--porcelain"])
        .output()
        .ok()
        .map(|output| !output.stdout.is_empty())
        .unwrap_or(false);
    Some((revision, dirty))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_file(path: &Path, bytes: &[u8]) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(path, bytes).unwrap();
    }

    #[test]
    fn lists_only_rom_extensions_and_deduplicates() {
        let dir = tempfile::tempdir().unwrap();
        let rom_dir = dir.path().join("ROM");
        write_file(&rom_dir.join("Pokemon Y.cci"), b"payload");
        write_file(&rom_dir.join("game.3ds"), b"payload");
        write_file(&rom_dir.join("readme.txt"), b"not a rom");
        write_file(&rom_dir.join("sub").join("nested.3ds"), b"payload");

        let roms = list_roms(&[rom_dir.clone(), rom_dir.clone()]);
        assert_eq!(roms.len(), 2);
        assert!(roms.iter().any(|rom| rom.path.ends_with("Pokemon Y.cci")));
        assert!(roms.iter().any(|rom| rom.path.ends_with("game.3ds")));
        assert_eq!(roms[0].bytes, 7);
    }

    #[test]
    fn rom_extension_check_is_case_insensitive() {
        assert!(has_rom_extension(Path::new("Game.3DS"), false));
        assert!(has_rom_extension(Path::new("game.cci"), false));
        assert!(!has_rom_extension(Path::new("game.zip"), false));
        assert!(has_rom_extension(Path::new("game.zip"), true));
    }

    #[test]
    fn search_directories_are_ordered_and_unique() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("work");
        let home = dir.path().join("home");
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        let explicit = vec![dir.path().join("roms")];
        let env_rom = dir.path().join("env-roms");
        let dirs = rom_search_dirs(&explicit, Some(&cwd), Some(&home), Some(env_rom.as_path()));
        assert_eq!(dirs[0], explicit[0]);
        assert_eq!(dirs[1], env_rom);
        assert!(dirs.contains(&cwd));
        assert!(dirs.contains(&cwd.join("ROM")));
        assert!(dirs.contains(&home.join("ROM")));
        // No path appears twice.
        let mut seen = std::collections::HashSet::new();
        for dir in &dirs {
            assert!(seen.insert(dir.clone()), "duplicate {}", dir.display());
        }
    }

    #[test]
    fn project_root_is_detected_from_a_child_directory() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("builder")).unwrap();
        std::fs::create_dir_all(root.join("scripts")).unwrap();
        std::fs::create_dir_all(root.join("ROM")).unwrap();
        std::fs::write(root.join("builder").join("Cargo.toml"), "[workspace]\n").unwrap();
        let nested = root.join("builder").join("linux").join("src");
        std::fs::create_dir_all(&nested).unwrap();
        assert_eq!(project_root(&nested), Some(root.to_path_buf()));
        let elsewhere = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(elsewhere.path().join("plain")).unwrap();
        assert_eq!(project_root(&elsewhere.path().join("plain")), None);
    }

    #[test]
    fn artifacts_live_under_the_shared_data_directory() {
        // The process environment is shared between tests, so only the suffix
        // that does not depend on $ZKB_DATA_DIR is asserted here.
        let path = default_out_dir("pokemon-y");
        assert!(
            path.ends_with(Path::new("artifacts").join("pokemon-y")),
            "{}",
            path.display()
        );
    }
}
