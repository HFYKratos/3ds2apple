//! Real build pipeline: invoke the documented `scripts/` commands for the
//! five protocol stages, stream their output, and verify the produced IPA.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use builder_core::hash::sha256_file;
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::model::{
    ArtifactFile, ArtifactRecord, ArtifactSource, BuildTiming, ErrorInfo, LogLevel, LogSource,
    Stage,
};
use builder_core::util::rfc3339_from_unix;

use crate::doctor;
use crate::exec::{self, RunFailure, ScriptOutcome};
use crate::service::Service;
use crate::stages::{self, ScriptCall};
use crate::store::JobEntry;
use crate::util;

/// Final outcome of one build slot.
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
pub enum WorkerOutcome {
    Succeeded {
        artifact: ArtifactRecord,
        warnings: Vec<String>,
    },
    Failed {
        error: ErrorInfo,
        warnings: Vec<String>,
    },
    Canceled,
}

/// Run the real pipeline in the configured checkout.
pub fn run(service: &Arc<Service>, entry: &Arc<JobEntry>) -> WorkerOutcome {
    let request = entry.with(|record| record.job.request.clone());
    let game = request.game.clone();
    let expected_revision = request
        .source
        .as_ref()
        .and_then(|source| source.expected_revision.clone());

    service.enter_stage(entry, Stage::Preparing);
    let Some(checkout) = service.cfg.checkout.clone() else {
        return failed(
            ErrorInfo::new(
                ErrorCode::RepoMissing,
                "the Agent has no source checkout configured",
            )
            .with_stage(Stage::Preparing)
            .with_hint("Start the Agent with --checkout pointing at the 3ds2apple checkout."),
        );
    };
    let report = doctor::gather(&service.cfg, &service.data);
    service.log(
        entry,
        Some(Stage::Preparing),
        LogSource::Agent,
        LogLevel::Info,
        &format!(
            "checkout {} (revision {})",
            checkout.display(),
            report.source.revision.as_deref().unwrap_or("unknown")
        ),
    );
    service.log(
        entry,
        Some(Stage::Preparing),
        LogSource::Agent,
        LogLevel::Info,
        &format!("toolchain: {}", report.toolchain.summary()),
    );
    if !report.ready {
        let refusal = refusal_error(&report, Stage::Preparing);
        return failed(refusal);
    }
    if let Some(expected) = &expected_revision {
        let actual = report.source.revision.clone().unwrap_or_default();
        if !actual.eq_ignore_ascii_case(expected) {
            return failed(
                ErrorInfo::new(
                    ErrorCode::SourceMismatch,
                    format!("checkout revision is {actual}, expected {expected}"),
                )
                .with_stage(Stage::Preparing)
                .with_details(serde_json::json!({ "expected": expected, "actual": actual })),
            );
        }
    }
    service.finish_stage(entry, Stage::Preparing);

    // --- recompiling -------------------------------------------------------
    service.enter_stage(entry, Stage::Recompiling);
    let rom = stages::rom_input_path(&entry.dir);
    let call = stages::recomp_call(&rom, &game.name);
    let outcome = match run_stage(service, entry, Stage::Recompiling, &call, &[], &game.name) {
        StageResult::Ok(outcome) => outcome,
        StageResult::Canceled => return WorkerOutcome::Canceled,
        StageResult::Failed(error) => return failed(error),
    };
    let _ = outcome;
    service.finish_stage(entry, Stage::Recompiling);
    service.update_progress(entry, Some(70), None);

    // --- linking -----------------------------------------------------------
    service.enter_stage(entry, Stage::Linking);
    let call = stages::linked_call(&game.name, game.title_id.as_deref());
    match run_stage(service, entry, Stage::Linking, &call, &[], &game.name) {
        StageResult::Ok(_) => service.finish_stage(entry, Stage::Linking),
        StageResult::Canceled => return WorkerOutcome::Canceled,
        StageResult::Failed(error) => return failed(error),
    }
    service.update_progress(entry, Some(88), None);

    // --- packaging ---------------------------------------------------------
    service.enter_stage(entry, Stage::Packaging);
    let mut envs: Vec<(String, String)> = Vec::new();
    if request.options.embed_moltenvk {
        if let Some(framework) = &service.cfg.moltenvk_framework {
            envs.push((
                "MOLTENVK_FRAMEWORK".to_string(),
                framework.display().to_string(),
            ));
        } else {
            service.warning(
                entry,
                "MoltenVK framework is not configured; the app is packaged without the embedded renderer framework",
            );
        }
    }
    if request.options.hardware_renderer {
        envs.push(("ZAKURO_IOS_HARDWARE".to_string(), "1".to_string()));
    }
    let ipa_name = stages::ipa_name(&game.name);
    let call = stages::package_call(
        &game.name,
        &game.display_name,
        game.bundle_id.as_deref(),
        &entry.out_dir,
        &ipa_name,
    );
    let packaging = match run_stage(service, entry, Stage::Packaging, &call, &envs, &game.name) {
        StageResult::Ok(outcome) => outcome,
        StageResult::Canceled => return WorkerOutcome::Canceled,
        StageResult::Failed(error) => return failed(error),
    };
    let parsed = stages::parse_package_output(&packaging.combined());
    let ipa_path = match parsed.resolve_ipa(&entry.out_dir, &ipa_name) {
        Ok(path) => path,
        Err(message) => {
            return failed(
                ErrorInfo::new(ErrorCode::VerifyFailed, message)
                    .with_stage(Stage::Packaging)
                    .with_log_tail(packaging.tail(40)),
            )
        }
    };
    service.finish_stage(entry, Stage::Packaging);
    service.update_progress(entry, Some(97), None);

    // --- verifying ---------------------------------------------------------
    service.enter_stage(entry, Stage::Verifying);
    let manifest_path = parsed.manifest_path.clone().unwrap_or_else(|| {
        checkout
            .join("build")
            .join("ios")
            .join(&game.name)
            .join("manifest.txt")
    });
    let manifest_text = match std::fs::read_to_string(&manifest_path) {
        Ok(text) => text,
        Err(error) => {
            return failed(
                ErrorInfo::new(
                    ErrorCode::VerifyFailed,
                    format!(
                        "could not read the build manifest {}: {error}",
                        manifest_path.display()
                    ),
                )
                .with_stage(Stage::Verifying),
            )
        }
    };
    let manifest = stages::parse_manifest(&manifest_text);
    let actual = match sha256_file(&ipa_path) {
        Ok(hash) => hash,
        Err(error) => {
            return failed(
                ErrorInfo::new(
                    ErrorCode::VerifyFailed,
                    format!("could not hash the produced IPA: {error}"),
                )
                .with_stage(Stage::Verifying),
            )
        }
    };
    if let Some(expected) = manifest.ipa_sha256() {
        if !actual.sha256.eq_ignore_ascii_case(expected) {
            return failed(verify_mismatch(expected, &actual.sha256, actual.bytes));
        }
    }
    if let Some(expected) = &parsed.sha256 {
        if !actual.sha256.eq_ignore_ascii_case(expected) {
            return failed(verify_mismatch(expected, &actual.sha256, actual.bytes));
        }
    }
    let out_manifest = entry.out_dir.join("manifest.txt");
    if let Err(error) = copy_private(&manifest_path, &out_manifest) {
        return failed(
            ErrorInfo::new(
                ErrorCode::VerifyFailed,
                format!("could not copy the build manifest: {error}"),
            )
            .with_stage(Stage::Verifying),
        );
    }
    let manifest_hash = match sha256_file(&out_manifest) {
        Ok(hash) => hash,
        Err(error) => {
            return failed(
                ErrorInfo::new(
                    ErrorCode::VerifyFailed,
                    format!("could not hash the manifest: {error}"),
                )
                .with_stage(Stage::Verifying),
            )
        }
    };
    let ipa_file_name = ipa_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(ipa_name.as_str())
        .to_string();
    if !builder_core::protocol::valid_file_name(&ipa_file_name) {
        return failed(
            ErrorInfo::new(
                ErrorCode::VerifyFailed,
                "the build produced an unsafe IPA file name",
            )
            .with_stage(Stage::Verifying),
        );
    }
    let started_at = entry
        .with(|record| record.job.started_at.clone())
        .unwrap_or_else(|| entry.with(|record| record.job.created_at.clone()));
    let retention_hours = service.cfg.artifact_retention_hours;
    let record = ArtifactRecord {
        artifact_version: 1,
        job_id: entry.job_id(),
        game: game.clone(),
        ipa: ArtifactFile {
            name: ipa_file_name,
            bytes: actual.bytes,
            sha256: actual.sha256.clone(),
        },
        manifest_txt: ArtifactFile {
            name: "manifest.txt".to_string(),
            bytes: manifest_hash.bytes,
            sha256: manifest_hash.sha256,
        },
        source: ArtifactSource {
            repo_revision: report.source.revision.clone(),
            expected_revision: expected_revision.clone(),
            revision_matches: match &expected_revision {
                Some(expected) => report
                    .source
                    .revision
                    .as_deref()
                    .map(|actual| actual.eq_ignore_ascii_case(expected))
                    .unwrap_or(false),
                None => true,
            },
        },
        toolchain: report.toolchain.clone(),
        build: BuildTiming {
            started_at,
            finished_at: util::now(),
            warnings: Vec::new(),
        },
        retention_until: rfc3339_from_unix(util::unix_now() + retention_hours * 3_600),
        fake: None,
    };
    let artifact_path = entry.out_dir.join("artifact.json");
    if let Err(error) = util::write_json(&artifact_path, &record) {
        return failed(
            ErrorInfo::new(
                ErrorCode::Internal,
                format!("could not write {}: {error}", artifact_path.display()),
            )
            .with_stage(Stage::Verifying),
        );
    }
    service.finish_stage(entry, Stage::Verifying);
    service.log(
        entry,
        Some(Stage::Verifying),
        LogSource::Agent,
        LogLevel::Info,
        &format!(
            "artifact ready: {} ({} bytes, sha256 {})",
            record.ipa.name, record.ipa.bytes, record.ipa.sha256
        ),
    );
    WorkerOutcome::Succeeded {
        artifact: record,
        warnings: Vec::new(),
    }
}

enum StageResult {
    Ok(ScriptOutcome),
    Canceled,
    Failed(ErrorInfo),
}

fn run_stage(
    service: &Arc<Service>,
    entry: &Arc<JobEntry>,
    stage: Stage,
    call: &ScriptCall,
    envs: &[(String, String)],
    game_name: &str,
) -> StageResult {
    let _ = game_name;
    match exec::run_script(
        service,
        entry,
        stage,
        call,
        envs,
        exec::stage_timeout(stage),
    ) {
        Ok(outcome) if outcome.exit_code == 0 => StageResult::Ok(outcome),
        Ok(outcome) => StageResult::Failed(build_failure(stage, call, &outcome)),
        Err(RunFailure::Canceled) => StageResult::Canceled,
        Err(RunFailure::TimedOut { stage, seconds }) => StageResult::Failed(
            ErrorInfo::new(
                ErrorCode::Timeout,
                format!("stage {stage} exceeded its {seconds} s time limit"),
            )
            .with_stage(stage),
        ),
        Err(RunFailure::Spawn(message)) => StageResult::Failed(
            ErrorInfo::new(ErrorCode::ToolchainMissing, message).with_stage(stage),
        ),
        Err(RunFailure::Io(message)) => {
            StageResult::Failed(ErrorInfo::new(ErrorCode::Internal, message).with_stage(stage))
        }
    }
}

fn build_failure(stage: Stage, call: &ScriptCall, outcome: &ScriptOutcome) -> ErrorInfo {
    let tail = outcome.tail(60);
    let hint = stages::symptom_hint(&tail).unwrap_or_else(|| {
        format!("The {stage} stage failed; the log tail shows the script's last output.")
    });
    ErrorInfo::new(
        ErrorCode::BuildFailed,
        format!(
            "{} failed with exit code {}",
            call.script.display(),
            outcome.exit_code
        ),
    )
    .with_stage(stage)
    .with_hint(hint)
    .with_details(serde_json::json!({ "exit_code": outcome.exit_code }))
    .with_log_tail(outcome.tail(40))
}

fn verify_mismatch(expected: &str, actual: &str, bytes: u64) -> ErrorInfo {
    ErrorInfo::new(
        ErrorCode::VerifyFailed,
        format!("IPA SHA256 mismatch: manifest says {expected}, computed {actual}"),
    )
    .with_stage(Stage::Verifying)
    .with_details(serde_json::json!({
        "expected": expected,
        "actual": actual,
        "bytes": bytes,
    }))
}

fn refusal_error(report: &builder_core::protocol::model::DoctorReport, stage: Stage) -> ErrorInfo {
    let refusals = report.refusals.join(", ");
    let code = if report
        .refusals
        .iter()
        .any(|code| code == "toolchain_missing")
    {
        ErrorCode::ToolchainMissing
    } else if report.refusals.iter().any(|code| code == "repo_missing") {
        ErrorCode::RepoMissing
    } else if report.refusals.iter().any(|code| code == "repo_dirty") {
        ErrorCode::RepoDirty
    } else if report
        .refusals
        .iter()
        .any(|code| code == "insufficient_storage")
    {
        ErrorCode::InsufficientStorage
    } else {
        ErrorCode::Internal
    };
    let mut error = ErrorInfo::new(code, format!("the Mac is not ready to build: {refusals}"));
    if let Some(hint) = code.hint() {
        error = error.with_hint(hint.to_string());
    }
    error.with_stage(stage)
}

fn failed(error: ErrorInfo) -> WorkerOutcome {
    WorkerOutcome::Failed {
        error,
        warnings: Vec::new(),
    }
}

fn copy_private(source: &Path, destination: &Path) -> std::io::Result<()> {
    std::fs::copy(source, destination)?;
    util::set_private_file(destination)
}

/// Verify the artifact record against the files in `out/`.
///
/// This is the Agent's own self-check before it reports success: the IPA and
/// manifest must exist, match their recorded size and SHA256, and stay inside
/// the job output directory.
pub fn verify_artifact(entry: &JobEntry, record: &ArtifactRecord) -> Result<(), ErrorInfo> {
    if record.artifact_version != 1 {
        return Err(ErrorInfo::new(
            ErrorCode::VerifyFailed,
            format!("unsupported artifact_version {}", record.artifact_version),
        ));
    }
    let out = entry.out_dir.canonicalize().map_err(|error| {
        ErrorInfo::new(
            ErrorCode::VerifyFailed,
            format!("job output directory is missing: {error}"),
        )
    })?;
    for (label, file) in [("ipa", &record.ipa), ("manifest", &record.manifest_txt)] {
        if !builder_core::protocol::valid_file_name(&file.name) {
            return Err(ErrorInfo::new(
                ErrorCode::VerifyFailed,
                format!("artifact {label} has an unsafe file name {:?}", file.name),
            ));
        }
        let path: PathBuf = out.join(&file.name);
        let canonical = path.canonicalize().map_err(|error| {
            ErrorInfo::new(
                ErrorCode::VerifyFailed,
                format!("artifact {label} {} is missing: {error}", path.display()),
            )
        })?;
        if !canonical.starts_with(&out) {
            return Err(ErrorInfo::new(
                ErrorCode::VerifyFailed,
                format!("artifact {label} resolves outside the job output directory"),
            ));
        }
        let hash = sha256_file(&canonical).map_err(|error| {
            ErrorInfo::new(
                ErrorCode::VerifyFailed,
                format!("could not hash artifact {label}: {error}"),
            )
        })?;
        if hash.bytes != file.bytes {
            return Err(ErrorInfo::new(
                ErrorCode::VerifyFailed,
                format!(
                    "artifact {label} is {} bytes, expected {}",
                    hash.bytes, file.bytes
                ),
            ));
        }
        if !hash.sha256.eq_ignore_ascii_case(&file.sha256) {
            return Err(ErrorInfo::new(
                ErrorCode::VerifyFailed,
                format!(
                    "artifact {label} SHA256 mismatch: expected {}, computed {}",
                    file.sha256, hash.sha256
                ),
            )
            .with_details(serde_json::json!({
                "expected": file.sha256,
                "actual": hash.sha256,
                "file": file.name,
            })));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store;
    use builder_core::hash::sha256_hex;
    use builder_core::protocol::model::GameSpec;

    fn artifact_for(entry: &JobEntry, ipa_name: &str, body: &[u8]) -> ArtifactRecord {
        let sha256 = sha256_hex(body);
        ArtifactRecord {
            artifact_version: 1,
            job_id: entry.job_id(),
            game: GameSpec {
                name: "game".into(),
                display_name: "Game".into(),
                bundle_id: None,
                title_id: None,
            },
            ipa: ArtifactFile {
                name: ipa_name.to_string(),
                bytes: body.len() as u64,
                sha256,
            },
            manifest_txt: ArtifactFile {
                name: "manifest.txt".to_string(),
                bytes: 2,
                sha256: sha256_hex(b"ok"),
            },
            source: ArtifactSource {
                repo_revision: None,
                expected_revision: None,
                revision_matches: true,
            },
            toolchain: Default::default(),
            build: BuildTiming {
                started_at: "2026-11-12T19:00:00Z".into(),
                finished_at: "2026-11-12T19:01:00Z".into(),
                warnings: vec![],
            },
            retention_until: "2026-11-19T19:00:00Z".into(),
            fake: None,
        }
    }

    fn entry_with_files(dir: &Path) -> JobEntry {
        let job_dir = dir.join("job");
        store::create_job_layout(&job_dir).unwrap();
        let job = store::JobPersist::new(
            util::new_job_id(),
            store::sample_request("game"),
            "fp".into(),
            Default::default(),
            None,
            util::now(),
        );
        JobEntry::new(job_dir.clone(), job_dir.join("logs/events.ndjson"), job)
    }

    #[test]
    fn verification_accepts_matching_files() {
        let dir = tempfile::tempdir().unwrap();
        let entry = entry_with_files(dir.path());
        std::fs::write(entry.out_dir.join("game-AOT.ipa"), b"fake ipa").unwrap();
        std::fs::write(entry.out_dir.join("manifest.txt"), b"ok").unwrap();
        let record = artifact_for(&entry, "game-AOT.ipa", b"fake ipa");
        assert!(verify_artifact(&entry, &record).is_ok());
    }

    #[test]
    fn verification_rejects_wrong_hash_and_missing_files() {
        let dir = tempfile::tempdir().unwrap();
        let entry = entry_with_files(dir.path());
        std::fs::write(entry.out_dir.join("game-AOT.ipa"), b"fake ipa").unwrap();
        std::fs::write(entry.out_dir.join("manifest.txt"), b"ok").unwrap();
        let mut record = artifact_for(&entry, "game-AOT.ipa", b"other ipa");
        assert_eq!(
            verify_artifact(&entry, &record).unwrap_err().code,
            ErrorCode::VerifyFailed
        );
        record = artifact_for(&entry, "game-AOT.ipa", b"fake ipa");
        std::fs::remove_file(entry.out_dir.join("game-AOT.ipa")).unwrap();
        assert_eq!(
            verify_artifact(&entry, &record).unwrap_err().code,
            ErrorCode::VerifyFailed
        );
    }

    #[test]
    fn verification_rejects_path_traversal_names() {
        let dir = tempfile::tempdir().unwrap();
        let entry = entry_with_files(dir.path());
        std::fs::write(entry.out_dir.join("manifest.txt"), b"ok").unwrap();
        let mut record = artifact_for(&entry, "game-AOT.ipa", b"fake ipa");
        record.ipa.name = "../escape.ipa".to_string();
        assert_eq!(
            verify_artifact(&entry, &record).unwrap_err().code,
            ErrorCode::VerifyFailed
        );
    }
}
