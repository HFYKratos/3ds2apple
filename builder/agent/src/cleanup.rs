//! Cleanup and garbage collection.
//!
//! Two kinds of data are deleted at the end of a job:
//!
//! * the job's staged inputs (ROM, keys, partial uploads) unless `keep_input`
//!   was explicitly set;
//! * the build products the scripts created inside the checkout (`build/game/
//!   <name>`, `build/ios/<name>`, the generated Xcode project, `IPA/<name>-*`).
//!
//! Every target is checked to be inside the directory it is supposed to be in,
//! and symlinks are never followed.

use std::path::{Path, PathBuf};

use builder_core::protocol::valid_game_name;

use crate::config::AgentConfig;
use crate::store::{self, DataRoot};
use crate::util;

/// Result of removing a job's inputs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputCleanup {
    /// True when the input directory is empty afterwards.
    pub removed: bool,
    /// Files that are still present (their paths), if cleanup failed.
    pub leftovers: Vec<String>,
}

/// Remove every entry under `<job>/input`, including the staging directory.
pub fn remove_inputs(job_dir: &Path) -> InputCleanup {
    let input = store::input_dir(job_dir);
    let mut leftovers = Vec::new();
    match std::fs::read_dir(&input) {
        Ok(entries) => {
            for entry in entries.flatten() {
                let path = entry.path();
                if let Err(error) = util::remove_path_if_exists(&path) {
                    leftovers.push(format!("{} ({error})", path.display()));
                } else if path.exists() {
                    leftovers.push(path.display().to_string());
                }
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => leftovers.push(format!("{} ({error})", input.display())),
    }
    // Verify by re-listing: "deleted" in the status must mean deleted.
    if let Ok(entries) = std::fs::read_dir(&input) {
        for entry in entries.flatten() {
            leftovers.push(entry.path().display().to_string());
        }
    }
    InputCleanup {
        removed: leftovers.is_empty(),
        leftovers,
    }
}

/// Remove the generated build products for one game from the checkout.
///
/// Returns human-readable warnings for anything that was skipped or failed;
/// never fails the job by itself (the protocol reports `input_cleanup_failed`
/// only for inputs, and this is best-effort derived data).
pub fn remove_build_products(checkout: &Path, name: &str) -> Vec<String> {
    let mut warnings = Vec::new();
    if !valid_game_name(name) {
        warnings.push(format!(
            "refusing to clean build products for invalid name {name:?}"
        ));
        return warnings;
    }
    let mut targets: Vec<PathBuf> = vec![
        checkout.join("build").join("game").join(name),
        checkout.join("build").join("ios").join(name),
        checkout.join("build").join("cargo-target").join(name),
        checkout.join("ios").join("app").join("3ds2apple.xcodeproj"),
    ];

    // Per-name IPAs left in the checkout's IPA/ directory.
    if let Ok(entries) = std::fs::read_dir(checkout.join("IPA")) {
        for entry in entries.flatten() {
            let file_name = entry.file_name();
            let file_name = file_name.to_string_lossy();
            if file_name.starts_with(&format!("{name}-"))
                && (file_name.ends_with(".ipa") || file_name.ends_with(".sha256"))
            {
                targets.push(entry.path());
            }
        }
    }

    for target in targets {
        if !target.exists() && std::fs::symlink_metadata(&target).is_err() {
            continue;
        }
        if !util::path_is_within(&target, checkout) {
            warnings.push(format!(
                "refusing to remove {}: outside the configured checkout",
                target.display()
            ));
            continue;
        }
        match std::fs::symlink_metadata(&target) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                warnings.push(format!("refusing to follow symlink {}", target.display()));
            }
            Ok(_) => {
                if let Err(error) = util::remove_path_if_exists(&target) {
                    warnings.push(format!("could not remove {}: {error}", target.display()));
                } else if target.exists() {
                    warnings.push(format!("{} still exists after cleanup", target.display()));
                }
            }
            Err(error) => warnings.push(format!("could not stat {}: {error}", target.display())),
        }
    }
    warnings
}

/// Summary of a `gc` run.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GcReport {
    pub removed_jobs: Vec<String>,
    pub removed_staging_files: u64,
    pub removed_bytes: u64,
    pub warnings: Vec<String>,
}

fn directory_size(path: &Path) -> u64 {
    let mut total = 0_u64;
    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.is_dir() => total += directory_size(&path),
            Ok(metadata) => total += metadata.len(),
            Err(_) => {}
        }
    }
    total
}

/// Enforce retention policies:
///
/// * delete terminal jobs whose `updated_at` is older than the retention
///   window (or every job with `all`);
/// * delete abandoned staging files older than the input timeout.
pub fn gc(data: &DataRoot, cfg: &AgentConfig, all: bool) -> Result<GcReport, String> {
    let mut report = GcReport::default();
    let now = util::unix_now();
    let retention_seconds = cfg.job_retention_hours.saturating_mul(3_600);
    let staging_timeout = 3_600_u64;

    for (dir, job) in store::load_all_jobs(data) {
        let expired = now.saturating_sub(job.updated_unix) > retention_seconds;
        if all || (job.state.is_terminal() && expired) {
            let size = directory_size(&dir);
            match store::delete_job_dir(data, &job.job_id) {
                Ok(()) => {
                    report.removed_jobs.push(job.job_id.clone());
                    report.removed_bytes += size;
                }
                Err(error) => report
                    .warnings
                    .push(format!("could not remove job {}: {error}", job.job_id)),
            }
            continue;
        }
        // Abandoned partial uploads: remove stale staging files for jobs that
        // never completed their inputs.
        let staging = store::staging_dir(&dir);
        if let Ok(entries) = std::fs::read_dir(&staging) {
            for entry in entries.flatten() {
                let path = entry.path();
                let Ok(metadata) = std::fs::symlink_metadata(&path) else {
                    continue;
                };
                if !metadata.is_file() {
                    continue;
                }
                let stale = metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|duration| now.saturating_sub(duration.as_secs()) > staging_timeout)
                    .unwrap_or(false);
                if stale {
                    if std::fs::remove_file(&path).is_ok() {
                        report.removed_staging_files += 1;
                        report.removed_bytes += metadata.len();
                    } else {
                        report
                            .warnings
                            .push(format!("could not remove staging file {}", path.display()));
                    }
                }
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use builder_core::protocol::model::InputRole;

    #[test]
    fn removes_inputs_and_confirms_deletion() {
        let dir = tempfile::tempdir().unwrap();
        let job_dir = dir.path().join("job");
        store::create_job_layout(&job_dir).unwrap();
        std::fs::write(store::input_path(&job_dir, InputRole::Rom), b"rom").unwrap();
        std::fs::write(store::staging_path(&job_dir, InputRole::Rom), b"partial").unwrap();
        let cleanup = remove_inputs(&job_dir);
        assert!(cleanup.removed, "{cleanup:?}");
        assert!(cleanup.leftovers.is_empty());
        assert!(!store::input_path(&job_dir, InputRole::Rom).exists());
        assert!(!store::staging_path(&job_dir, InputRole::Rom).exists());
    }

    #[test]
    fn remove_inputs_on_missing_directory_is_ok() {
        let dir = tempfile::tempdir().unwrap();
        let cleanup = remove_inputs(&dir.path().join("does-not-exist"));
        assert!(cleanup.removed);
    }

    #[test]
    fn removes_only_name_scoped_build_products() {
        let dir = tempfile::tempdir().unwrap();
        let checkout = dir.path();
        for path in [
            "build/game/pokemon-y/code/librecomp.a",
            "build/ios/pokemon-y/libgame.a",
            "build/cargo-target/pokemon-y/debug/x",
            "build/game/other-game/code/librecomp.a",
            "IPA/pokemon-y-AOT.ipa",
            "IPA/other-game-AOT.ipa",
            "ios/app/3ds2apple.xcodeproj/project.pbxproj",
        ] {
            let full = checkout.join(path);
            std::fs::create_dir_all(full.parent().unwrap()).unwrap();
            std::fs::write(full, b"x").unwrap();
        }
        let warnings = remove_build_products(checkout, "pokemon-y");
        assert!(warnings.is_empty(), "{warnings:?}");
        assert!(!checkout.join("build/game/pokemon-y").exists());
        assert!(!checkout.join("build/ios/pokemon-y").exists());
        assert!(!checkout.join("build/cargo-target/pokemon-y").exists());
        assert!(!checkout.join("IPA/pokemon-y-AOT.ipa").exists());
        assert!(!checkout.join("ios/app/3ds2apple.xcodeproj").exists());
        // Other games are untouched.
        assert!(checkout
            .join("build/game/other-game/code/librecomp.a")
            .exists());
        assert!(checkout.join("IPA/other-game-AOT.ipa").exists());
    }

    #[test]
    fn invalid_names_are_never_used_for_deletion() {
        let dir = tempfile::tempdir().unwrap();
        let warnings = remove_build_products(dir.path(), "../escape");
        assert!(!warnings.is_empty());
        assert!(dir.path().exists());
    }

    #[test]
    fn gc_removes_only_expired_terminal_jobs() {
        let dir = tempfile::tempdir().unwrap();
        let data = DataRoot::new(dir.path().to_path_buf());
        data.ensure_layout().unwrap();
        let cfg = AgentConfig::default();

        let make_job = |id: &str, terminal: bool, age_seconds: u64| {
            let job_dir = data.job_dir(id);
            store::create_job_layout(&job_dir).unwrap();
            let mut job = store::JobPersist::new(
                id.to_string(),
                store::sample_request("game"),
                "fp".to_string(),
                builder_core::protocol::model::Toolchain::default(),
                None,
                util::now(),
            );
            if terminal {
                job.state = builder_core::protocol::model::JobState::Succeeded;
            }
            job.updated_unix = util::unix_now().saturating_sub(age_seconds);
            store::write_job_json(&job_dir, &job).unwrap();
        };
        let expired = util::new_job_id();
        let recent = util::new_job_id();
        let active = util::new_job_id();
        make_job(&expired, true, 8 * 24 * 3600);
        make_job(&recent, true, 60);
        make_job(&active, false, 8 * 24 * 3600);

        let report = gc(&data, &cfg, false).unwrap();
        assert_eq!(report.removed_jobs, vec![expired.clone()]);
        assert!(!data.job_dir(&expired).exists());
        assert!(data.job_dir(&recent).exists());
        assert!(data.job_dir(&active).exists());

        let report = gc(&data, &cfg, true).unwrap();
        assert_eq!(report.removed_jobs.len(), 2);
        assert!(!data.job_dir(&active).exists());
    }
}
