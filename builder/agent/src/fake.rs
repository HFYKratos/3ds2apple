//! Scripted fake build, used to exercise the Agent end-to-end on Linux.
//!
//! It runs the real protocol, job store, queue, event stream, cancellation,
//! cleanup and artifact verification, but replaces the macOS pipeline with
//! deterministic stages that emit the same kind of events. The produced
//! "IPA" is a clearly marked text file; it never resembles a real build output
//! and never leaves the Agent's temporary data root.

use std::sync::Arc;

use builder_core::hash::sha256_hex;
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::model::{
    ArtifactFile, ArtifactRecord, ArtifactSource, BuildTiming, ErrorInfo, LogLevel, LogSource,
    Stage,
};
use builder_core::util::rfc3339_from_unix;

use crate::service::Service;
use crate::stages;
use crate::store::JobEntry;
use crate::util;
use crate::worker::WorkerOutcome;

/// Scripted build outcomes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FakePlan {
    Success,
    FailRecompiling,
    FailPackaging,
    /// Slow stages with cancellation checkpoints (for cancellation tests).
    Slow,
    /// Succeeds but records a bogus artifact SHA256 (verification must fail).
    CorruptArtifact,
}

impl FakePlan {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "success" => Some(FakePlan::Success),
            "fail-recompiling" => Some(FakePlan::FailRecompiling),
            "fail-packaging" => Some(FakePlan::FailPackaging),
            "slow" => Some(FakePlan::Slow),
            "corrupt-artifact" => Some(FakePlan::CorruptArtifact),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            FakePlan::Success => "success",
            FakePlan::FailRecompiling => "fail-recompiling",
            FakePlan::FailPackaging => "fail-packaging",
            FakePlan::Slow => "slow",
            FakePlan::CorruptArtifact => "corrupt-artifact",
        }
    }
}

/// Run the scripted plan for one job.
pub fn run(service: &Arc<Service>, entry: &Arc<JobEntry>) -> WorkerOutcome {
    let plan = FakePlan::parse(&service.cfg.fake_plan).unwrap_or(FakePlan::Success);
    let stage_ms = if plan == FakePlan::Slow { 900 } else { 80 };
    service.log(
        entry,
        None,
        LogSource::Agent,
        LogLevel::Info,
        &format!("fake build mode: plan {}", plan.as_str()),
    );

    if !run_stage(
        service,
        entry,
        Stage::Preparing,
        stage_ms,
        &[
            "fake build: checking toolchain (simulated)",
            "fake build: source checkout accepted (simulated)",
        ],
    ) {
        return WorkerOutcome::Canceled;
    }
    if plan == FakePlan::FailRecompiling {
        service.enter_stage(entry, Stage::Recompiling);
        service.log(
            entry,
            Some(Stage::Recompiling),
            LogSource::Script,
            LogLevel::Info,
            "[build-recomp-ios] fake recompile started",
        );
        service.log(
            entry,
            Some(Stage::Recompiling),
            LogSource::Script,
            LogLevel::Error,
            "[build-recomp-ios] error: missing librecomp.a (simulated failure)",
        );
        return WorkerOutcome::Failed {
            error: ErrorInfo::new(
                ErrorCode::BuildFailed,
                "build-recomp-ios.sh failed (exit 1, simulated)",
            )
            .with_stage(Stage::Recompiling)
            .with_hint("The 3dsrecomp step did not finish; see the recompiling log.")
            .with_details(serde_json::json!({ "exit_code": 1, "fake": true }))
            .with_log_tail(vec![
                "[build-recomp-ios] fake recompile started".to_string(),
                "[build-recomp-ios] error: missing librecomp.a (simulated failure)".to_string(),
            ]),
            warnings: Vec::new(),
        };
    }
    if !run_stage(
        service,
        entry,
        Stage::Recompiling,
        stage_ms,
        &[
            "fake build: translating game code (simulated)",
            "fake build: compiling generated code (318/761)",
            "fake build: compiling generated code (761/761)",
        ],
    ) {
        return WorkerOutcome::Canceled;
    }
    if !run_stage(
        service,
        entry,
        Stage::Linking,
        stage_ms,
        &[
            "fake build: building linked runtime (simulated)",
            "fake build: collecting libgame.a (simulated)",
        ],
    ) {
        return WorkerOutcome::Canceled;
    }
    if plan == FakePlan::FailPackaging {
        service.enter_stage(entry, Stage::Packaging);
        service.log(
            entry,
            Some(Stage::Packaging),
            LogSource::Script,
            LogLevel::Error,
            "[build-game-ipa] error: xcodebuild failed (exit 65, simulated)",
        );
        return WorkerOutcome::Failed {
            error: ErrorInfo::new(
                ErrorCode::BuildFailed,
                "xcodebuild failed (exit 65) while linking the app (simulated)",
            )
            .with_stage(Stage::Packaging)
            .with_hint(
                "Undefined _recomp_* symbols: check that -lzakuro_ios is listed before -lgame.",
            )
            .with_details(serde_json::json!({ "exit_code": 65, "fake": true }))
            .with_log_tail(vec![
                "[build-game-ipa] error: xcodebuild failed (exit 65, simulated)".to_string(),
            ]),
            warnings: Vec::new(),
        };
    }
    if !run_stage(
        service,
        entry,
        Stage::Packaging,
        stage_ms,
        &[
            "fake build: xcodebuild (simulated)",
            "fake build: packaging unsigned IPA (simulated)",
        ],
    ) {
        return WorkerOutcome::Canceled;
    }
    service.enter_stage(entry, Stage::Verifying);
    service.log(
        entry,
        Some(Stage::Verifying),
        LogSource::Agent,
        LogLevel::Info,
        "fake build: writing artifact record (simulated)",
    );
    match write_fake_artifact(service, entry, plan == FakePlan::CorruptArtifact) {
        Ok(record) => {
            service.finish_stage(entry, Stage::Verifying);
            WorkerOutcome::Succeeded {
                artifact: record,
                warnings: Vec::new(),
            }
        }
        Err(error) => WorkerOutcome::Failed {
            error,
            warnings: Vec::new(),
        },
    }
}

/// Enter a stage, emit its log lines with cancellation checkpoints, finish it.
///
/// Returns `false` when cancellation was requested during the stage.
fn run_stage(
    service: &Arc<Service>,
    entry: &Arc<JobEntry>,
    stage: Stage,
    total_ms: u64,
    lines: &[&str],
) -> bool {
    service.enter_stage(entry, stage);
    let per_line = (total_ms / lines.len().max(1) as u64).max(10);
    for line in lines {
        if !sleep_unless_canceled(service, entry, per_line) {
            return false;
        }
        service.log(entry, Some(stage), LogSource::Script, LogLevel::Info, line);
    }
    service.finish_stage(entry, stage);
    true
}

/// Sleep in small slices so cancellation is observed promptly.
pub fn sleep_unless_canceled(service: &Arc<Service>, entry: &Arc<JobEntry>, millis: u64) -> bool {
    let steps = (millis / 25).max(1);
    for _ in 0..steps {
        if entry.with(|record| record.job.cancel_requested) {
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    let _ = service;
    true
}

/// Write the fake IPA, manifest and artifact record.
fn write_fake_artifact(
    service: &Arc<Service>,
    entry: &Arc<JobEntry>,
    corrupt: bool,
) -> Result<ArtifactRecord, ErrorInfo> {
    let (job_id, game, started_at, source_revision, expected_revision, retention_hours) = entry
        .with(|record| {
            let job = &record.job;
            (
                job.job_id.clone(),
                job.request.game.clone(),
                job.started_at
                    .clone()
                    .unwrap_or_else(|| job.created_at.clone()),
                job.source_revision.clone(),
                job.expected_revision().map(str::to_string),
                service.cfg.artifact_retention_hours,
            )
        });
    std::fs::create_dir_all(&entry.out_dir)
        .map_err(|error| internal(format!("could not create the output directory: {error}")))?;

    let ipa_name = stages::ipa_name(&game.name);
    let mut body = format!(
        "FAKE IPA — not a real app, produced by the Agent's fake build mode\njob={job_id}\ngame={}\n",
        game.name
    )
    .into_bytes();
    body.resize(4_096, b'f');
    let sha256 = sha256_hex(&body);
    let ipa_path = entry.out_dir.join(format!("{ipa_name}.ipa"));
    write_private(&ipa_path, &body)?;

    let title_id = game
        .title_id
        .clone()
        .unwrap_or_else(|| "0004000000000000".to_string());
    let manifest_text = format!(
        "name={}\ntitle_id={}\nipa_bytes={}\nipa_sha256={}\nfake=1\n",
        game.name,
        title_id,
        body.len(),
        sha256
    );
    let manifest_path = entry.out_dir.join("manifest.txt");
    write_private(&manifest_path, manifest_text.as_bytes())?;
    let manifest_sha = sha256_hex(manifest_text.as_bytes());

    let recorded_sha = if corrupt { "0".repeat(64) } else { sha256 };
    let retention_until = rfc3339_from_unix(util::unix_now() + retention_hours * 3_600);
    let record = ArtifactRecord {
        artifact_version: 1,
        job_id,
        game,
        ipa: ArtifactFile {
            name: format!("{ipa_name}.ipa"),
            bytes: body.len() as u64,
            sha256: recorded_sha,
        },
        manifest_txt: ArtifactFile {
            name: "manifest.txt".to_string(),
            bytes: manifest_text.len() as u64,
            sha256: manifest_sha,
        },
        source: ArtifactSource {
            repo_revision: source_revision,
            expected_revision: expected_revision.clone(),
            revision_matches: expected_revision.is_none(),
        },
        toolchain: service.toolchain.clone(),
        build: BuildTiming {
            started_at,
            finished_at: util::now(),
            warnings: Vec::new(),
        },
        retention_until,
        fake: Some(true),
    };
    util::write_json(&entry.out_dir.join("artifact.json"), &record)
        .map_err(|error| internal(format!("could not write artifact.json: {error}")))?;
    Ok(record)
}

fn write_private(path: &std::path::Path, bytes: &[u8]) -> Result<(), ErrorInfo> {
    std::fs::write(path, bytes)
        .map_err(|error| internal(format!("could not write {}: {error}", path.display())))?;
    util::set_private_file(path)
        .map_err(|error| internal(format!("could not chmod {}: {error}", path.display())))?;
    Ok(())
}

fn internal(message: impl Into<String>) -> ErrorInfo {
    ErrorInfo::new(ErrorCode::Internal, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_parsing() {
        for plan in [
            FakePlan::Success,
            FakePlan::FailRecompiling,
            FakePlan::FailPackaging,
            FakePlan::Slow,
            FakePlan::CorruptArtifact,
        ] {
            assert_eq!(FakePlan::parse(plan.as_str()), Some(plan));
        }
        assert_eq!(FakePlan::parse("nope"), None);
    }
}
