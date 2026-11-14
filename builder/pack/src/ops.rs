//! High-level desktop operations: import, fake build, verify, allocate, pack,
//! remove. The CLI is a thin shell over these functions and the tests drive them
//! directly.

use std::path::{Path, PathBuf};

use crate::catalog::GameCatalog;
use crate::error::{PackError, Result};
use crate::gameinfo::{self, GameInfo, PackFormat, RomSource, VerifyReport};
use crate::queue::{Queue, QueueEntry, QueueState};
use crate::rom::{self, RomInfo};

/// Options for importing ROMs.
#[derive(Debug, Clone)]
pub struct ImportOptions {
    /// Re-import an already built package (keeps its pack, refreshes metadata).
    pub force: bool,
    /// Override the display name (single-ROM imports only; the CLI enforces it).
    pub display_name: Option<String>,
    /// AOT version to request for this game.
    pub aot_version: u32,
}

impl Default for ImportOptions {
    fn default() -> Self {
        Self {
            force: false,
            display_name: None,
            aot_version: 1,
        }
    }
}

/// What happened to one imported ROM.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportStatus {
    /// New package directory and queue entry.
    Imported,
    /// Existing queued/metadata-only package refreshed.
    Refreshed,
    /// Existing built package refreshed with --force (pack kept).
    AlreadyBuilt,
}

/// Result of importing one ROM.
#[derive(Debug, Clone)]
pub struct ImportResult {
    /// Detected ROM metadata.
    pub rom: RomInfo,
    /// Package directory.
    pub package_dir: PathBuf,
    /// Package manifest after the import.
    pub game_info: GameInfo,
    /// What happened.
    pub status: ImportStatus,
}

/// Import one ROM: detect headers, create/refresh its package directory and
/// queue entry. The ROM itself is never copied or hashed.
pub fn import_rom(root: &Path, rom_path: &Path, options: &ImportOptions) -> Result<ImportResult> {
    let rom = rom::detect_rom(rom_path)?;
    let display_name = options
        .display_name
        .as_deref()
        .unwrap_or(rom.display_name.as_str());
    let product_code = rom.product_code.clone().unwrap_or_default();
    let mut info = GameInfo::new(&rom, display_name, &product_code, options.aot_version)?;
    let dir = gameinfo::package_dir(root, &info.title_id);

    let status = if dir.join(gameinfo::GAME_INFO_FILE).is_file() {
        let existing = GameInfo::read(&dir)?;
        let built = existing.pack.is_some() && dir.join(gameinfo::GAME_PACK_FILE).is_file();
        if built && !options.force {
            return Err(PackError::invalid(format!(
                "{} ({}) is already built in {}; pass --force to re-import, or remove it first with 'packages remove {}'",
                existing.display_name,
                existing.title_id,
                dir.display(),
                existing.title_id
            )));
        }
        // Keep the pack record and any note the user added; refresh detection data.
        info.pack = existing.pack.clone();
        info.notes = existing.notes.clone();
        if built {
            ImportStatus::AlreadyBuilt
        } else {
            ImportStatus::Refreshed
        }
    } else {
        ImportStatus::Imported
    };

    info.write(&dir)?;
    let mut queue = Queue::load(root)?;
    queue.upsert(QueueEntry::from_import(&info, &rom));
    queue.save(root)?;
    Ok(ImportResult {
        rom,
        package_dir: dir,
        game_info: info,
        status,
    })
}

/// A fake-built package for the --fake preview path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeBuild {
    /// Title ID.
    pub title_id: String,
    /// Package directory.
    pub package_dir: PathBuf,
    /// Placeholder pack SHA256.
    pub sha256: String,
    /// Placeholder pack size.
    pub bytes: u64,
}

/// Write deterministic placeholder packs for the given queue entries (Linux/
/// Windows previews and tests; never shipped).
pub fn fake_build(root: &Path, entries: &[QueueEntry], force: bool) -> Result<Vec<FakeBuild>> {
    let mut queue = Queue::load(root)?;
    let mut results = Vec::new();
    for entry in entries {
        let dir = gameinfo::package_dir(root, &entry.title_id);
        let info = GameInfo::read(&dir).map_err(|error| {
            PackError::invalid(format!(
                "{}: package metadata is missing ({error}); run 'packages add' first",
                entry.title_id
            ))
        })?;
        if info.pack.is_some() && !force {
            return Err(PackError::invalid(format!(
                "{} is already built in {}; pass --force to replace its pack",
                entry.title_id,
                dir.display()
            )));
        }
        let built = gameinfo::install_placeholder_pack(&dir, &entry.title_id)?;
        let pack = built.pack.clone().ok_or_else(|| {
            PackError::invalid(format!(
                "{}: placeholder pack was not recorded",
                entry.title_id
            ))
        })?;
        queue.upsert(QueueEntry {
            title_id: entry.title_id.clone(),
            rom_path: entry.rom_path.clone(),
            display_name: built.display_name.clone(),
            product_code: built.product_code.clone(),
            slug: crate::plan::slug_for(&built.display_name, &built.title_id),
            aot_version: built.aot_version,
            state: QueueState::Built,
            error: None,
        });
        results.push(FakeBuild {
            title_id: entry.title_id.clone(),
            package_dir: dir,
            sha256: pack.sha256,
            bytes: pack.bytes,
        });
    }
    queue.save(root)?;
    results.sort_by(|a, b| a.title_id.cmp(&b.title_id));
    Ok(results)
}

/// Scan report: summarised packages plus directories that could not be read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScanReport {
    /// Packages, sorted by title ID.
    pub packages: Vec<crate::gameinfo::PackageSummary>,
    /// Unreadable/malformed package directories, sorted by path.
    pub errors: Vec<(PathBuf, String)>,
}

/// Cheap listing of all package directories (no pack hashes).
pub fn scan(root: &Path) -> Result<ScanReport> {
    let mut report = ScanReport::default();
    for dir in gameinfo::list_package_dirs(root)? {
        match gameinfo::summarize_package(&dir) {
            Ok(summary) => report.packages.push(summary),
            Err(error) => report.errors.push((dir, error.to_string())),
        }
    }
    report.packages.sort_by(|a, b| a.title_id.cmp(&b.title_id));
    Ok(report)
}

/// Full verification of all package directories (hashes every pack).
pub fn verify(root: &Path) -> Result<(Vec<VerifyReport>, Vec<(PathBuf, String)>)> {
    let mut reports = Vec::new();
    let mut errors = Vec::new();
    for dir in gameinfo::list_package_dirs(root)? {
        match gameinfo::verify_package(&dir) {
            Ok(report) => reports.push(report),
            Err(error) => errors.push((dir, error.to_string())),
        }
    }
    reports.sort_by(|a, b| a.title_id.cmp(&b.title_id));
    Ok((reports, errors))
}

/// Build the catalogue from the built packages (all of them, or the given title
/// IDs). Returns the catalogue and the manifests in catalogue order.
pub fn allocate(root: &Path, filter: Option<&[String]>) -> Result<(GameCatalog, Vec<GameInfo>)> {
    let dirs = gameinfo::list_package_dirs(root)?;
    let mut infos = Vec::new();
    let mut available = Vec::new();
    for dir in &dirs {
        if let Ok(info) = gameinfo::read_package(dir) {
            available.push(info.title_id.clone());
            infos.push(info);
        }
    }
    let filtered: Vec<GameInfo> = match filter {
        None => infos,
        Some(title_ids) => {
            let mut wanted = Vec::new();
            for raw in title_ids {
                let title = rom::canonical_title_id(raw)?;
                if !available.contains(&title) {
                    return Err(PackError::invalid(format!(
                        "no package for title {title} in {} (known packages: {})",
                        gameinfo::packages_root(root).display(),
                        if available.is_empty() {
                            "none".to_string()
                        } else {
                            available.join(", ")
                        }
                    )));
                }
                let info = infos
                    .iter()
                    .find(|info| info.title_id == title)
                    .expect("checked above")
                    .clone();
                wanted.push(info);
            }
            wanted
        }
    };
    let unbuilt: Vec<&str> = filtered
        .iter()
        .filter(|info| info.pack.is_none())
        .map(|info| info.title_id.as_str())
        .collect();
    if !unbuilt.is_empty() {
        return Err(PackError::invalid(format!(
            "these packages have no AOT pack yet: {} (run 'build --fake --queued' for a preview or build on macOS)",
            unbuilt.join(", ")
        )));
    }
    let mut catalog = GameCatalog::from_packages(&filtered)?;
    for game in &mut catalog.games {
        let dir = gameinfo::package_dir(root, &game.title_id);
        apply_package_cover(game, &dir);
    }
    catalog.validate()?;
    let mut ordered = Vec::new();
    for game in &catalog.games {
        if let Some(info) = filtered.iter().find(|info| info.title_id == game.title_id) {
            ordered.push(info.clone());
        }
    }
    Ok((catalog, ordered))
}

/// Add the optional `cover.png` of a package to its catalogue entry. The pack
/// directory may carry a user-supplied cover; it is copied into the app bundle
/// as `Covers/<TITLE_ID>.png` by scripts/build-multi-game-ipa.sh. Covers are
/// local user content and are never committed.
fn apply_package_cover(game: &mut crate::catalog::CatalogGame, package_dir: &Path) {
    if package_dir.join("cover.png").is_file() {
        game.cover_file = Some(format!("Covers/{}.png", game.title_id));
    }
}

/// Build the catalogue from explicit package directories (used by the shell
/// script: the packages may live outside the default output root).
pub fn allocate_dirs(dirs: &[PathBuf]) -> Result<(GameCatalog, Vec<GameInfo>)> {
    let mut infos = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for dir in dirs {
        let info = gameinfo::read_package(dir)?;
        if !seen.insert(info.title_id.clone()) {
            return Err(PackError::invalid(format!(
                "duplicate package for title {} in the selection",
                info.title_id
            )));
        }
        if info.pack.is_none() {
            return Err(PackError::invalid(format!(
                "{} ({}): package has no AOT pack yet; build it first",
                info.display_name, info.title_id
            )));
        }
        infos.push(info);
    }
    let mut catalog = GameCatalog::from_packages(&infos)?;
    for game in &mut catalog.games {
        if let Some(dir) = dirs.iter().find(|dir| {
            dir.file_name()
                .map(|name| name.to_string_lossy().to_string())
                == Some(game.title_id.clone())
        }) {
            apply_package_cover(game, dir);
        }
    }
    catalog.validate()?;
    let mut ordered = Vec::new();
    for game in &catalog.games {
        if let Some(info) = infos.iter().find(|info| info.title_id == game.title_id) {
            ordered.push(info.clone());
        }
    }
    Ok((catalog, ordered))
}

/// Remove packages and their queue entries.
///
/// The request is validated completely before anything is touched, and the
/// queue is persisted before any directory is deleted. If a directory cannot be
/// deleted, its queue entry is restored and the error names it, so a partial
/// failure never leaves a stale queue entry or an unregistered directory.
pub fn remove(root: &Path, title_ids: &[String]) -> Result<Vec<String>> {
    if title_ids.is_empty() {
        return Err(PackError::invalid("no title IDs given to remove"));
    }
    let mut queue = Queue::load(root)?;

    // 1. Validate everything first: canonical IDs, no duplicates, all present.
    //    Nothing on disk is changed before this loop finishes.
    let mut targets: Vec<(String, std::path::PathBuf)> = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    let mut missing = Vec::new();
    for raw in title_ids {
        let title = rom::canonical_title_id(raw)?;
        if !seen.insert(title.clone()) {
            return Err(PackError::invalid(format!(
                "duplicate title ID in the remove request: {title}"
            )));
        }
        let dir = gameinfo::package_dir(root, &title);
        if !dir.is_dir() && queue.get(&title).is_none() {
            missing.push(title);
            continue;
        }
        targets.push((title, dir));
    }
    if !missing.is_empty() {
        return Err(PackError::invalid(format!(
            "no package or queue entry for: {} (nothing was removed)",
            missing.join(", ")
        )));
    }

    // 2. Persist the queue removal first. If this fails, nothing was deleted.
    for (title, _) in &targets {
        queue.remove(title);
    }
    queue.save(root)?;

    // 3. Delete the directories. A failed delete re-registers the package so
    //    the queue entry and the directory always agree.
    let mut removed = Vec::new();
    let mut failures = Vec::new();
    for (title, dir) in targets {
        match gameinfo::remove_package_dir(&dir) {
            Ok(()) => removed.push(title),
            Err(error) => failures.push((title, dir, error.to_string())),
        }
    }
    if !failures.is_empty() {
        for (title, dir, _) in &failures {
            match gameinfo::read_package(dir) {
                Ok(info) => queue.upsert(QueueEntry::from_package(&info)),
                Err(error) => {
                    // The manifest is gone or partial; report it rather than
                    // leaving a queue entry pointing at nothing.
                    return Err(PackError::invalid(format!(
                        "{title}: directory could not be removed ({}) and its GameInfo.json is unreadable ({error}); the queue entry was dropped, re-import the ROM",
                        dir.display()
                    )));
                }
            }
        }
        queue.save(root)?;
        let lines: Vec<String> = failures
            .iter()
            .map(|(title, dir, error)| format!("{title} ({}): {error}", dir.display()))
            .collect();
        return Err(PackError::invalid(format!(
            "could not remove: {}; the queue was restored for directories that still exist",
            lines.join("; ")
        )));
    }
    removed.sort();
    Ok(removed)
}

/// Mark a package's queue entry as built (called after the macOS scripts and
/// packages record succeeded).
pub fn mark_built(root: &Path, title_id: &str) -> Result<GameInfo> {
    let title = rom::canonical_title_id(title_id)?;
    let dir = gameinfo::package_dir(root, &title);
    let info = gameinfo::read_package(&dir)?;
    if info.pack.is_none() || !dir.join(gameinfo::GAME_PACK_FILE).is_file() {
        return Err(PackError::invalid(format!(
            "{title}: the build finished but the package has no GamePack.dylib; check the build log and run scripts/build-game-pack.sh again"
        )));
    }
    let mut queue = Queue::load(root)?;
    let slug = crate::plan::slug_for(&info.display_name, &title);
    queue.upsert(QueueEntry {
        title_id: title.clone(),
        rom_path: info
            .rom
            .as_ref()
            .and_then(|rom| rom.path.clone())
            .unwrap_or_default(),
        display_name: info.display_name.clone(),
        product_code: info.product_code.clone(),
        slug,
        aot_version: info.aot_version,
        state: QueueState::Built,
        error: None,
    });
    queue.save(root)?;
    Ok(info)
}

/// Record a failed build in the queue (the package keeps its state).
pub fn mark_failed(root: &Path, title_id: &str, message: &str) -> Result<()> {
    let title = rom::canonical_title_id(title_id)?;
    let mut queue = Queue::load(root)?;
    if queue.get(&title).is_none() {
        return Ok(());
    }
    let mut message = message.replace('\n', " ");
    if message.len() > 500 {
        message.truncate(500);
    }
    queue.set_state(&title, QueueState::Failed, Some(message));
    queue.save(root)?;
    Ok(())
}

/// Options for packages record (called by scripts/build-game-pack.sh).
#[derive(Debug, Clone, Default)]
pub struct RecordOptions {
    /// Title ID of the package.
    pub title_id: String,
    /// Existing GamePack.dylib produced on macOS.
    pub pack: Option<PathBuf>,
    /// Record a deterministic --fake placeholder instead of adopting a pack.
    pub fake_placeholder: bool,
    /// ROM to record as provenance (must match the title ID).
    pub rom: Option<PathBuf>,
    /// Override the display name.
    pub display_name: Option<String>,
    /// Override the product code.
    pub product_code: Option<String>,
    /// Override the AOT version.
    pub aot_version: Option<u32>,
}

/// Record a built pack (or placeholder) for an existing/queued package and mark
/// the queue entry built.
pub fn record_pack(root: &Path, options: &RecordOptions) -> Result<GameInfo> {
    let title = rom::canonical_title_id(&options.title_id)?;
    let dir = gameinfo::package_dir(root, &title);
    let mut info = if dir.join(gameinfo::GAME_INFO_FILE).is_file() {
        GameInfo::read(&dir)?
    } else {
        let display = options.display_name.clone().ok_or_else(|| {
            PackError::invalid(format!(
                "no package for {} in {}; pass --display-name (or import it first with 'packages add')",
                title,
                dir.display()
            ))
        })?;
        GameInfo::new_without_rom(
            &title,
            &display,
            options.product_code.as_deref().unwrap_or(""),
            options.aot_version.unwrap_or(1),
        )?
    };
    if let Some(display) = &options.display_name {
        info.display_name = display.trim().to_string();
    }
    if let Some(code) = &options.product_code {
        info.product_code = code.trim().to_string();
    }
    if let Some(version) = options.aot_version {
        info.aot_version = version;
    }
    if let Some(rom_path) = &options.rom {
        let detected = rom::detect_rom(rom_path)?;
        if detected.title_id != title {
            return Err(PackError::invalid(format!(
                "ROM title ID {} does not match --title-id {}",
                detected.title_id, title
            )));
        }
        info.rom = Some(RomSource::from_rom(&detected));
    }
    info.validate()?;
    info.write(&dir)?;

    let built = if options.fake_placeholder {
        gameinfo::install_placeholder_pack(&dir, &title)?
    } else {
        let pack = options.pack.as_ref().ok_or_else(|| {
            PackError::invalid("record --pack FILE or --fake-placeholder is required")
        })?;
        gameinfo::install_pack(&dir, pack)?
    };
    let mut queue = Queue::load(root)?;
    queue.upsert(QueueEntry {
        title_id: title.clone(),
        rom_path: built
            .rom
            .as_ref()
            .and_then(|rom| rom.path.clone())
            .unwrap_or_default(),
        display_name: built.display_name.clone(),
        product_code: built.product_code.clone(),
        slug: crate::plan::slug_for(&built.display_name, &built.title_id),
        aot_version: built.aot_version,
        state: QueueState::Built,
        error: None,
    });
    queue.save(root)?;
    Ok(built)
}

/// True when the package's pack is a --fake placeholder.
pub fn is_placeholder(info: &GameInfo) -> bool {
    info.pack
        .as_ref()
        .map(|pack| pack.format == PackFormat::Placeholder)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rom::test_support::{synthetic_ncsd, write_rom};
    use tempfile::tempdir;

    const GOLDEN: &str = include_str!("../tests/fixtures/catalog-multi.json");

    fn write_roms(dir: &Path) -> [PathBuf; 2] {
        let pokemon_y = dir.join("Pokémon Y.cci");
        write_rom(
            &pokemon_y,
            &synthetic_ncsd(0x0004_0000_0005_5E00, "CTR-P-EK2A", 4),
        );
        let alpha = dir.join("Pokémon Alpha Sapphire.cci");
        write_rom(
            &alpha,
            &synthetic_ncsd(0x0004_0000_0011_C500, "CTR-P-ECLA", 4),
        );
        [pokemon_y, alpha]
    }

    fn import_both(out: &Path, roms: &[PathBuf; 2]) {
        for rom in roms {
            import_rom(out, rom, &ImportOptions::default()).unwrap();
        }
    }

    #[test]
    fn imports_queues_and_fake_builds_to_a_deterministic_catalog() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        let mut imported = Vec::new();
        for rom in &roms {
            let result = import_rom(&out, rom, &ImportOptions::default()).unwrap();
            assert_eq!(result.status, ImportStatus::Imported);
            assert!(result.package_dir.join(gameinfo::GAME_INFO_FILE).is_file());
            imported.push(result);
        }
        assert_eq!(imported.len(), 2);
        // Importing again without --force refreshes (queued, not built).
        let again = import_rom(&out, &roms[0], &ImportOptions::default()).unwrap();
        assert_eq!(again.status, ImportStatus::Refreshed);

        let queue = Queue::load(&out).unwrap();
        assert_eq!(queue.entries.len(), 2);
        assert!(queue
            .entries
            .iter()
            .all(|entry| entry.state == QueueState::Queued));

        let entries = queue.entries.clone();
        let built = fake_build(&out, &entries, false).unwrap();
        assert_eq!(built.len(), 2);
        assert!(built
            .iter()
            .all(|pack| !pack.sha256.is_empty() && pack.bytes > 0));
        let queue = Queue::load(&out).unwrap();
        assert!(queue
            .entries
            .iter()
            .all(|entry| entry.state == QueueState::Built));

        let (catalog, packages) = allocate(&out, None).unwrap();
        assert_eq!(catalog.to_json().unwrap(), GOLDEN);
        assert_eq!(packages.len(), 2);
        assert_eq!(packages[0].title_id, "0004000000055E00");
        assert!(catalog.all_placeholders(&packages));

        // A second fake build is refused unless forced; --force is deterministic.
        let entries = queue.entries.clone();
        assert!(fake_build(&out, &entries, false).is_err());
        let dir = gameinfo::package_dir(&out, "0004000000055E00");
        let before = std::fs::read(dir.join(gameinfo::GAME_PACK_FILE)).unwrap();
        fake_build(&out, &entries, true).unwrap();
        let after = std::fs::read(dir.join(gameinfo::GAME_PACK_FILE)).unwrap();
        assert_eq!(before, after);

        // Verification: structurally fine; the placeholder is called out.
        let (reports, errors) = verify(&out).unwrap();
        assert!(errors.is_empty());
        assert_eq!(reports.len(), 2);
        assert!(reports.iter().all(|report| report.ok));
        assert!(reports.iter().all(|report| report
            .issues
            .iter()
            .any(|issue| issue.contains("placeholder"))));
    }

    #[test]
    fn import_refuses_to_overwrite_a_built_package_without_force() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        import_rom(&out, &roms[0], &ImportOptions::default()).unwrap();
        let queue = Queue::load(&out).unwrap();
        fake_build(&out, &queue.entries, false).unwrap();
        let error = import_rom(&out, &roms[0], &ImportOptions::default()).unwrap_err();
        assert!(error.to_string().contains("already built"), "{error}");
        let refreshed = import_rom(
            &out,
            &roms[0],
            &ImportOptions {
                force: true,
                ..ImportOptions::default()
            },
        )
        .unwrap();
        assert_eq!(refreshed.status, ImportStatus::AlreadyBuilt);
        assert!(refreshed.game_info.pack.is_some());
    }

    #[test]
    fn allocation_filter_and_unknown_titles() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        import_both(&out, &roms);
        let queue = Queue::load(&out).unwrap();
        fake_build(&out, &queue.entries, false).unwrap();

        let (catalog, packages) = allocate(&out, Some(&["0004000000055E00".to_string()])).unwrap();
        assert_eq!(catalog.len(), 1);
        assert_eq!(packages.len(), 1);
        assert_eq!(
            allocate(&out, Some(&["000400000011C500".to_string()]))
                .unwrap()
                .0
                .len(),
            1
        );
        assert!(allocate(&out, Some(&["0004000000000001".to_string()])).is_err());
        assert!(allocate(&out, Some(&["not-a-title".to_string()])).is_err());
    }

    #[test]
    fn remove_is_atomic_and_never_leaves_stale_queue_entries() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        import_both(&out, &roms);
        let queue = Queue::load(&out).unwrap();
        fake_build(&out, &queue.entries, false).unwrap();

        // One valid title + one unknown title: the whole request is refused and
        // neither the package directory nor the queue entry changes (S1).
        let error = remove(
            &out,
            &[
                "0004000000055E00".to_string(),
                "0004000000000001".to_string(),
            ],
        )
        .unwrap_err();
        assert!(error.to_string().contains("nothing was removed"), "{error}");
        let queue = Queue::load(&out).unwrap();
        assert_eq!(queue.entries.len(), 2);
        assert!(gameinfo::package_dir(&out, "0004000000055E00")
            .join(gameinfo::GAME_INFO_FILE)
            .is_file());
        assert!(gameinfo::package_dir(&out, "000400000011C500")
            .join(gameinfo::GAME_INFO_FILE)
            .is_file());
        // The failure must not poison later builds ("stale queue entry" bug).
        fake_build(&out, &queue.entries, true).expect("queue stays consistent");

        // Duplicate title IDs are rejected before touching anything.
        let error = remove(
            &out,
            &[
                "0004000000055E00".to_string(),
                "0004000000055E00".to_string(),
            ],
        )
        .unwrap_err();
        assert!(error.to_string().contains("duplicate title ID"), "{error}");
        assert_eq!(Queue::load(&out).unwrap().entries.len(), 2);

        // A fully valid request still removes package + queue entry.
        let removed = remove(&out, &["0004000000055E00".to_string()]).unwrap();
        assert_eq!(removed, vec!["0004000000055E00"]);
        assert!(!gameinfo::package_dir(&out, "0004000000055E00").exists());
        assert_eq!(Queue::load(&out).unwrap().entries.len(), 1);
    }

    #[test]
    fn removes_packages_and_queue_entries() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        import_both(&out, &roms);
        let removed = remove(&out, &["0004000000055E00".to_string()]).unwrap();
        assert_eq!(removed, vec!["0004000000055E00"]);
        assert_eq!(Queue::load(&out).unwrap().entries.len(), 1);
        assert!(remove(&out, &["0004000000055E00".to_string()]).is_err());
    }

    #[test]
    fn record_adopts_a_macho_pack() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        import_rom(&out, &roms[0], &ImportOptions::default()).unwrap();

        // A minimal fake Mach-O file (magic only), used to exercise record.
        let dylib = temp.path().join("GamePack.dylib");
        std::fs::write(&dylib, [0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]).unwrap();
        let info = record_pack(
            &out,
            &RecordOptions {
                title_id: "0004000000055E00".to_string(),
                pack: Some(dylib),
                ..RecordOptions::default()
            },
        )
        .unwrap();
        assert_eq!(info.pack.as_ref().unwrap().format, PackFormat::Macho);
        let report =
            crate::gameinfo::verify_package(&gameinfo::package_dir(&out, "0004000000055E00"))
                .unwrap();
        assert!(report.ok);
        assert!(report.issues.is_empty());
        assert_eq!(
            Queue::load(&out).unwrap().entries[0].state,
            QueueState::Built
        );
    }

    #[test]
    fn record_rejects_wrong_rom_and_bad_pack() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        import_rom(&out, &roms[0], &ImportOptions::default()).unwrap();
        // Recording a placeholder for a package that was not imported creates it
        // from the supplied metadata.
        let info = record_pack(
            &out,
            &RecordOptions {
                title_id: "000400000011C500".to_string(),
                fake_placeholder: true,
                display_name: Some("Other".to_string()),
                ..RecordOptions::default()
            },
        )
        .unwrap();
        assert_eq!(info.title_id, "000400000011C500");

        let bad_pack = temp.path().join("bad.dylib");
        std::fs::write(&bad_pack, b"not a macho").unwrap();
        let error = record_pack(
            &out,
            &RecordOptions {
                title_id: "0004000000055E00".to_string(),
                pack: Some(bad_pack),
                ..RecordOptions::default()
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("not a Mach-O"), "{error}");

        let mismatch = record_pack(
            &out,
            &RecordOptions {
                title_id: "0004000000055E00".to_string(),
                fake_placeholder: true,
                rom: Some(roms[1].clone()),
                ..RecordOptions::default()
            },
        )
        .unwrap_err();
        assert!(
            mismatch.to_string().contains("does not match"),
            "{mismatch}"
        );
    }

    #[test]
    fn mark_built_and_failed_update_the_queue() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        import_rom(&out, &roms[0], &ImportOptions::default()).unwrap();
        mark_failed(&out, "0004000000055E00", "toolchain missing\nsee log").unwrap();
        let queue = Queue::load(&out).unwrap();
        assert_eq!(queue.entries[0].state, QueueState::Failed);
        assert!(!queue.entries[0].error.as_ref().unwrap().contains('\n'));

        record_pack(
            &out,
            &RecordOptions {
                title_id: "0004000000055E00".to_string(),
                fake_placeholder: true,
                ..RecordOptions::default()
            },
        )
        .unwrap();
        let info = mark_built(&out, "0004000000055E00").unwrap();
        assert!(info.pack.is_some());
        let queue = Queue::load(&out).unwrap();
        assert_eq!(queue.entries[0].state, QueueState::Built);
    }

    #[test]
    fn scan_and_allocate_dirs() {
        let temp = tempdir().unwrap();
        let out = temp.path().join("out");
        let roms = write_roms(temp.path());
        import_both(&out, &roms);
        let queue = Queue::load(&out).unwrap();
        fake_build(&out, &queue.entries, false).unwrap();
        let report = scan(&out).unwrap();
        assert_eq!(report.packages.len(), 2);
        assert!(report.errors.is_empty());
        let dirs: Vec<PathBuf> = gameinfo::list_package_dirs(&out).unwrap();
        let (catalog, packages) = allocate_dirs(&dirs).unwrap();
        assert_eq!(catalog.len(), 2);
        assert_eq!(packages.len(), 2);
        assert_eq!(catalog.to_json().unwrap(), GOLDEN);
        assert_eq!(allocate_dirs(&dirs[..1]).unwrap().0.len(), 1);
    }
}
