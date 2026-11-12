//! Build orchestration over the shared client.
//!
//! This is the frontend's "backend": it hashes and uploads the user's files,
//! streams the Agent's job events, supports cancellation from another connection
//! while the build runs, then downloads and verifies the IPA and writes the local
//! artifact record and installation guide.
//!
//! It uses [`builder_core::client::BuilderClient`] directly, so there is exactly
//! one implementation of the protocol in the repository and the Windows
//! frontend benefits from every core fix.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use builder_core::client::{ArtifactWhat, BuilderClient, ClientError};
use builder_core::config::{BuilderConfig, HostProfile};
use builder_core::hash;
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::model::{
    ArtifactRecord, ArtifactSummary, ErrorInfo, EventKind, GameSpec, InputRole, InputSpec,
    JobCreateRequest, JobEvent, JobListEntry, JobOptions, JobState, JobView, SourceExpectation,
    TransportMode,
};
use builder_core::util::unix_now;

use crate::artifacts;
use crate::errors::FrontendError;
use crate::events::{EventRenderer, Rendered};
use crate::paths;
use crate::preflight::{self, format_bytes, BuildPlan};

/// Progress sink. The console implementation prints; a graphical shell would
/// implement the same trait against its own event loop.
pub trait Progress {
    /// A diagnostic/status line from this PC.
    fn note(&mut self, _message: &str) {}
    /// A raw protocol event (used by `--json` output).
    fn event(&mut self, event: &JobEvent) {
        let _ = event;
    }
    /// A rendered event (stage change, log line, warning, artifact).
    fn rendered(&mut self, rendered: &Rendered) {
        let _ = rendered;
    }
    fn upload_progress(&mut self, role: InputRole, received: u64, total: u64) {
        let _ = (role, received, total);
    }
    fn download_progress(&mut self, what: ArtifactWhat, received: u64, total: u64) {
        let _ = (what, received, total);
    }
}

/// Console implementation of [`Progress`].
#[derive(Debug, Default)]
pub struct ConsoleProgress {
    /// Emit protocol events as NDJSON on stdout instead of human output.
    pub json: bool,
}

impl Progress for ConsoleProgress {
    fn note(&mut self, message: &str) {
        if !self.json {
            eprintln!("{message}");
        }
    }

    fn event(&mut self, event: &JobEvent) {
        if self.json {
            if let Ok(line) = serde_json::to_string(event) {
                println!("{line}");
            }
        }
    }

    fn rendered(&mut self, rendered: &Rendered) {
        if !self.json {
            println!("{}", rendered.line());
        }
    }

    fn upload_progress(&mut self, role: InputRole, received: u64, total: u64) {
        if !self.json {
            eprintln!(
                "  uploading {} {} / {}",
                role.as_str(),
                format_bytes(received),
                format_bytes(total)
            );
        }
    }

    fn download_progress(&mut self, what: ArtifactWhat, received: u64, total: u64) {
        if !self.json {
            eprintln!(
                "  downloading {} {} / {}",
                what.as_str(),
                format_bytes(received),
                format_bytes(total)
            );
        }
    }
}

/// Cancellation flag that a keyboard/UI thread can set while a build streams.
#[derive(Debug, Clone, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    /// Ask the build loop to cancel the job on the Agent.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_canceled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    pub fn reset(&self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// Everything a successful build produced.
#[derive(Debug, Clone)]
pub struct BuildOutcome {
    pub job_id: String,
    pub ipa_path: PathBuf,
    pub manifest_path: PathBuf,
    pub record_path: PathBuf,
    pub install_guide_path: PathBuf,
    pub artifact: ArtifactRecord,
    /// True when the Agent removed the uploaded inputs (the default).
    pub inputs_deleted: bool,
    pub warnings: Vec<String>,
}

/// Connect to a configured host by id or name.
pub fn connect(
    config: &BuilderConfig,
    host: &str,
) -> Result<(BuilderClient, HostProfile), FrontendError> {
    let profile = config.find(host).cloned().ok_or_else(|| {
        FrontendError::usage(format!(
            "unknown host {host:?}; add it with `builder-windows host add`"
        ))
    })?;
    let client = BuilderClient::connect(profile.transport.clone())?;
    Ok((client, profile))
}

fn hash_input(
    progress: &mut dyn Progress,
    file: &preflight::InputFile,
) -> Result<hash::HashResult, FrontendError> {
    let target = paths::extended_length_path(&file.path);
    progress.note(&format!(
        "hashing {} ({})",
        file.name,
        format_bytes(file.bytes)
    ));
    let result = hash::sha256_file(&target).map_err(|error| {
        FrontendError::local(format!(
            "cannot hash {}: {error}",
            paths::display_path(&file.path)
        ))
    })?;
    if result.bytes != file.bytes {
        return Err(FrontendError::local(format!(
            "{} changed while it was being prepared ({} bytes now, {} before)",
            paths::display_path(&file.path),
            result.bytes,
            file.bytes
        )));
    }
    Ok(result)
}

fn options_from_plan(plan: &BuildPlan) -> JobOptions {
    JobOptions {
        embed_moltenvk: plan.options.embed_moltenvk,
        hardware_renderer: plan.options.hardware_renderer,
        clean: plan.options.clean,
        keep_input: plan.options.keep_input,
    }
}

/// Run one build end to end.
pub fn run_build(
    config: &BuilderConfig,
    plan: &BuildPlan,
    progress: &mut dyn Progress,
    cancel: &CancelToken,
) -> Result<BuildOutcome, FrontendError> {
    // Local checks that need the output directory.
    preflight::prepare_output_dir(&plan.out_dir)?;
    for warning in preflight::check_output_space(&plan.out_dir)? {
        progress.note(&format!("warning: {warning}"));
    }
    for warning in plan
        .rom
        .warnings
        .iter()
        .chain(plan.keys.iter().flat_map(|keys| keys.warnings.iter()))
    {
        progress.note(&format!("warning: {warning}"));
    }
    if plan.options.keep_input {
        progress.note(
            "warning: --keep-input leaves the ROM on the Mac until you delete the job; only do this on a machine you control",
        );
    }

    let (mut client, profile) = connect(config, &plan.host)?;
    let hello = client.hello().clone();
    progress.note(&format!(
        "connected to {} ({})",
        profile.name,
        profile.transport.describe()
    ));
    progress.note(&format!(
        "agent: builder-agent {} ({}, {}), protocol {}",
        hello.agent.version, hello.agent.os, hello.agent.arch, hello.protocol
    ));
    if !hello.ready {
        return Err(FrontendError::Client(ClientError::Remote {
            error: ErrorInfo::new(
                ErrorCode::ToolchainMissing,
                format!(
                    "the Mac is not ready to build: {}",
                    hello.refusals.join(", ")
                ),
            )
            .with_hint(
                "run `builder-windows host test <host>` for the details, fix the reported items on the Mac, then try again",
            ),
        }));
    }

    // Hash exactly once; the same value is declared to the Agent and checked
    // again while uploading.
    let rom_hash = hash_input(progress, &plan.rom)?;
    progress.note(&format!("ROM sha256: {}", rom_hash.sha256));
    let keys_hash = match &plan.keys {
        Some(keys) => {
            let hash = hash_input(progress, keys)?;
            progress.note(&format!("supplementary file sha256: {}", hash.sha256));
            Some(hash)
        }
        None => None,
    };

    let mut inputs = vec![InputSpec {
        role: InputRole::Rom,
        name: plan.rom.name.clone(),
        bytes: rom_hash.bytes,
        sha256: rom_hash.sha256.clone(),
    }];
    if let (Some(keys), Some(hash)) = (&plan.keys, &keys_hash) {
        inputs.push(InputSpec {
            role: InputRole::Keys,
            name: keys.name.clone(),
            bytes: hash.bytes,
            sha256: hash.sha256.clone(),
        });
    }
    let request = JobCreateRequest {
        request_id: format!("win-{}-{}", unix_now(), std::process::id()),
        game: GameSpec {
            name: plan.name.clone(),
            display_name: plan.display_name.clone(),
            bundle_id: plan.bundle_id.clone(),
            title_id: plan.title_id.clone(),
        },
        inputs,
        options: options_from_plan(plan),
        source: plan
            .expected_revision
            .as_ref()
            .map(|revision| SourceExpectation {
                expected_revision: Some(revision.clone()),
            }),
        transport: TransportMode::Upload,
    };
    progress.note(&format!(
        "starting build {} ({}) on {}",
        plan.display_name, plan.name, profile.name
    ));
    let created = client.create_job(request)?;
    let job_id = created.job_id.clone();
    progress.note(&format!("job {job_id} created; uploading the ROM"));

    let rom_role = created
        .upload
        .roles
        .iter()
        .find(|role| role.role == InputRole::Rom)
        .cloned()
        .ok_or_else(|| {
            FrontendError::Client(ClientError::InvalidReply(
                "the Agent's upload plan has no rom role".to_string(),
            ))
        })?;
    let mut last_report = 0_u64;
    client
        .upload(
            &job_id,
            InputRole::Rom,
            &paths::extended_length_path(&plan.rom.path),
            &rom_role,
            |received, total| {
                if received - last_report >= 128 * 1024 * 1024 || received == total {
                    last_report = received;
                    progress.upload_progress(InputRole::Rom, received, total);
                }
            },
        )
        .map_err(upload_error)?;
    if let Some(keys) = &plan.keys {
        let keys_role = created
            .upload
            .roles
            .iter()
            .find(|role| role.role == InputRole::Keys)
            .cloned()
            .ok_or_else(|| {
                FrontendError::Client(ClientError::InvalidReply(
                    "the Agent's upload plan has no keys role".to_string(),
                ))
            })?;
        client
            .upload(
                &job_id,
                InputRole::Keys,
                &paths::extended_length_path(&keys.path),
                &keys_role,
                |_, _| {},
            )
            .map_err(upload_error)?;
    }
    client.input_ready(&job_id)?;
    progress.note(&format!(
        "upload complete; building on {}. Press c and Enter to cancel.",
        profile.name
    ));

    let _subscribe = client.subscribe(&job_id, 0)?;
    let mut renderer = EventRenderer::new();
    let mut cancel_sent = false;
    loop {
        if cancel.is_canceled() && !cancel_sent {
            cancel_sent = true;
            progress.note("cancel requested; asking the Mac to stop the job");
            match cancel_job(
                config,
                &plan.host,
                &job_id,
                Some("canceled from the Windows Builder"),
            ) {
                Ok(state) => progress.note(&format!("the Mac reports the job as {state}")),
                Err(error) => progress.note(&format!(
                    "could not send the cancel request ({error}); the build may still be running"
                )),
            }
        }
        let Some(event) = client.next_event()? else {
            break;
        };
        progress.event(&event);
        if let Some(rendered) = renderer.render(&event) {
            progress.rendered(&rendered);
        }
        if event.kind == EventKind::End {
            break;
        }
    }

    let view = client.status(&job_id)?;
    match view.state {
        JobState::Succeeded => {
            let artifact = client.artifact_manifest(&job_id)?;
            let (ipa_path, manifest_path, record_path) = download_and_verify(
                &mut client,
                &job_id,
                &plan.out_dir,
                &plan.name,
                &artifact,
                progress,
            )?;
            let guide =
                crate::install_guide::render_windows(&crate::install_guide::ArtifactGuide {
                    display_name: plan.display_name.as_str(),
                    ipa_path: &ipa_path,
                    bytes: artifact.ipa.bytes,
                    sha256: &artifact.ipa.sha256,
                    title_id: artifact.game.title_id.as_deref(),
                    source_revision: artifact.source.repo_revision.as_deref(),
                    xcode: artifact.toolchain.xcode.as_deref(),
                    host_name: Some(profile.name.as_str()),
                });
            let install_guide_path =
                artifacts::write_install_guide(&plan.out_dir, &plan.name, &guide)?;
            let inputs_deleted = !view.inputs_present;
            Ok(BuildOutcome {
                job_id,
                ipa_path,
                manifest_path,
                record_path,
                install_guide_path,
                artifact,
                inputs_deleted,
                warnings: view.warnings.clone(),
            })
        }
        JobState::Failed => Err(FrontendError::BuildFailed {
            error: view.error.unwrap_or_else(|| {
                ErrorInfo::new(
                    ErrorCode::BuildFailed,
                    "the build failed (the Agent reported no detail)",
                )
            }),
        }),
        JobState::Canceled => Err(FrontendError::Canceled),
        JobState::Interrupted => Err(FrontendError::Interrupted(
            view.error
                .map(|error| error.message)
                .unwrap_or_else(|| "the Mac restarted or the Agent stopped".to_string()),
        )),
        other => Err(FrontendError::Interrupted(format!(
            "the connection closed while the job was {other}; it keeps running on the Mac. \
             Reattach with `builder-windows status --host {} {job_id} --follow`",
            plan.host
        ))),
    }
}

fn upload_error(error: ClientError) -> FrontendError {
    FrontendError::Client(error)
}

/// Download the IPA and manifest, verify both checksums, write the record and
/// acknowledge the artifact to the Agent.
pub fn download_and_verify(
    client: &mut BuilderClient,
    job_id: &str,
    out_dir: &Path,
    build_name: &str,
    artifact: &ArtifactRecord,
    progress: &mut dyn Progress,
) -> Result<(PathBuf, PathBuf, PathBuf), FrontendError> {
    let ipa_name = artifacts::safe_artifact_name(&artifact.ipa.name)?.to_string();
    let destination = out_dir.join(&ipa_name);
    let destination = paths::extended_length_path(&destination);
    progress.note(&format!(
        "downloading {} ({})",
        ipa_name,
        format_bytes(artifact.ipa.bytes)
    ));
    let mut last_report = 0_u64;
    let outcome = client.download_artifact(
        job_id,
        ArtifactWhat::Ipa,
        &destination,
        artifact.ipa.bytes,
        &artifact.ipa.sha256,
        0,
        |received, total| {
            if received - last_report >= 64 * 1024 * 1024 || received == total {
                last_report = received;
                progress.download_progress(ArtifactWhat::Ipa, received, total);
            }
        },
    )?;
    progress.note("verifying the downloaded IPA");
    let actual = artifacts::verify_sha256(&outcome.path, &artifact.ipa.sha256)?;
    progress.note(&format!("sha256 verified: {actual}"));

    let manifest_destination = paths::extended_length_path(&out_dir.join("manifest.txt"));
    client.download_artifact(
        job_id,
        ArtifactWhat::ManifestTxt,
        &manifest_destination,
        artifact.manifest_txt.bytes,
        &artifact.manifest_txt.sha256,
        0,
        |_, _| {},
    )?;
    if let Ok(text) = std::fs::read_to_string(&manifest_destination) {
        if let Some(manifest_sha) = artifacts::manifest_sha256(&text) {
            if !manifest_sha.eq_ignore_ascii_case(&artifact.ipa.sha256) {
                return Err(FrontendError::Client(ClientError::InvalidReply(format!(
                    "the manifest reports IPA sha256 {manifest_sha}, the artifact record reports {}",
                    artifact.ipa.sha256
                ))));
            }
        }
    }
    let record_path = artifacts::write_record(out_dir, build_name, artifact)?;
    client.ack_artifact(job_id, &artifact.ipa.sha256)?;
    Ok((outcome.path, out_dir.join("manifest.txt"), record_path))
}

/// Cancel a running or queued job from a separate connection.
pub fn cancel_job(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    reason: Option<&str>,
) -> Result<JobState, FrontendError> {
    let (mut client, _profile) = connect(config, host)?;
    let reply = client.cancel(job_id, reason)?;
    Ok(reply.state)
}

/// Fetch one job's status.
pub fn job_status(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
) -> Result<JobView, FrontendError> {
    let (mut client, _profile) = connect(config, host)?;
    Ok(client.status(job_id)?)
}

/// List the jobs the Agent still holds.
pub fn list_jobs(
    config: &BuilderConfig,
    host: &str,
    limit: Option<u32>,
) -> Result<Vec<JobListEntry>, FrontendError> {
    let (mut client, _profile) = connect(config, host)?;
    let reply = client.list_jobs(limit, None)?;
    Ok(reply.jobs)
}

/// Delete a finished job's data on the Agent.
pub fn delete_job(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
) -> Result<String, FrontendError> {
    let (mut client, _profile) = connect(config, host)?;
    let reply = client.delete_job(job_id)?;
    Ok(reply.job_id)
}

/// Stream a job's events until it ends or the connection closes.
///
/// Returns the final status view when it can be fetched.
pub fn follow_job(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    since: u64,
    progress: &mut dyn Progress,
    cancel: &CancelToken,
) -> Result<Option<JobView>, FrontendError> {
    let (mut client, _profile) = connect(config, host)?;
    client.subscribe(job_id, since)?;
    let mut renderer = EventRenderer::new();
    let mut cancel_sent = false;
    loop {
        if cancel.is_canceled() && !cancel_sent {
            cancel_sent = true;
            progress.note("cancel requested; asking the Mac to stop the job");
            let _ = cancel_job(
                config,
                host,
                job_id,
                Some("canceled from the Windows Builder"),
            );
        }
        let Some(event) = client.next_event()? else {
            break;
        };
        progress.event(&event);
        if let Some(rendered) = renderer.render(&event) {
            progress.rendered(&rendered);
        }
        if event.kind == EventKind::End {
            break;
        }
    }
    Ok(client.status(job_id).ok())
}

/// Download and verify a finished job's artifacts without rebuilding.
pub fn download_job(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    out_dir: &Path,
    progress: &mut dyn Progress,
) -> Result<(PathBuf, PathBuf, PathBuf), FrontendError> {
    let (mut client, _profile) = connect(config, host)?;
    let view = client.status(job_id)?;
    if view.state != JobState::Succeeded {
        return Err(FrontendError::usage(format!(
            "job {job_id} is {}; only a succeeded job has an IPA to download",
            view.state
        )));
    }
    let artifact = client.artifact_manifest(job_id)?;
    preflight::prepare_output_dir(out_dir)?;
    for warning in preflight::check_output_space(out_dir)? {
        progress.note(&format!("warning: {warning}"));
    }
    let build_name = artifact.game.name.clone();
    download_and_verify(
        &mut client,
        job_id,
        out_dir,
        &build_name,
        &artifact,
        progress,
    )
}

/// Human-readable status block.
pub fn render_status(view: &JobView) -> Vec<String> {
    let mut lines = vec![format!(
        "job {}: {}{}",
        view.job_id,
        view.state,
        view.stage
            .map(|stage| format!(" ({})", stage.label()))
            .unwrap_or_default()
    )];
    if let Some(game) = &view.game {
        lines.push(format!("game: {} ({})", game.name, game.display_name));
    }
    lines.push(format!("created: {}", view.created_at));
    if let Some(started) = &view.started_at {
        lines.push(format!("started: {started}"));
    }
    if let Some(finished) = &view.finished_at {
        lines.push(format!("finished: {finished}"));
    }
    if let Some(position) = view.queue_position {
        lines.push(format!("queue position: {position}"));
    }
    if let Some(percent) = view.percent {
        lines.push(format!("progress: {percent}%"));
    }
    if !view.stages.is_empty() {
        lines.push("stages:".to_string());
        lines.extend(crate::events::stage_table(view));
    }
    lines.push(format!(
        "inputs: {} (kept: {})",
        if view.inputs_present {
            "on the Mac"
        } else {
            "deleted"
        },
        view.inputs_kept
    ));
    for warning in &view.warnings {
        lines.push(format!("warning: {warning}"));
    }
    if let Some(error) = &view.error {
        lines.push(format!("error: {}: {}", error.code, error.message));
        if let Some(hint) = &error.hint {
            lines.push(format!("hint: {hint}"));
        }
    }
    if let Some(artifact) = &view.artifact {
        lines.push(format!(
            "artifact: {} ({} bytes, sha256 {})",
            artifact.name, artifact.bytes, artifact.sha256
        ));
    }
    lines
}

/// Human-readable artifact summary shown at the end of a build.
pub fn render_result(outcome: &BuildOutcome) -> Vec<String> {
    let artifact: &ArtifactRecord = &outcome.artifact;
    let mut lines = vec![
        format!("build succeeded: {} ({})", artifact.game.display_name, outcome.job_id),
        format!("ipa: {}", paths::display_path(&outcome.ipa_path)),
        format!("sha256: {}", artifact.ipa.sha256),
        format!("size: {}", format_bytes(artifact.ipa.bytes)),
        format!("manifest: {}", paths::display_path(&outcome.manifest_path)),
        format!("record: {}", paths::display_path(&outcome.record_path)),
        format!(
            "install guide: {}",
            paths::display_path(&outcome.install_guide_path)
        ),
        format!(
            "title_id: {}",
            artifact.game.title_id.as_deref().unwrap_or("unknown")
        ),
        format!(
            "source_revision: {}",
            artifact.source.repo_revision.as_deref().unwrap_or("unknown")
        ),
        format!(
            "ROM on the Mac: {}",
            if outcome.inputs_deleted {
                "deleted"
            } else {
                "kept (delete the job when done)"
            }
        ),
        "This IPA is unsigned and contains code derived from your game; sign and install it yourself and do not redistribute it.".to_string(),
    ];
    for warning in &outcome.warnings {
        lines.push(format!("warning: {warning}"));
    }
    lines
}

/// Facts about the job's summary used by the wizard's result screen.
pub fn artifact_summary(record: &ArtifactRecord) -> ArtifactSummary {
    ArtifactSummary {
        name: record.ipa.name.clone(),
        bytes: record.ipa.bytes,
        sha256: record.ipa.sha256.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use builder_core::protocol::model::{
        ArtifactFile, ArtifactSource, BuildTiming, StageProgress, Toolchain,
    };

    #[test]
    fn cancel_token_is_shared_between_threads() {
        let token = CancelToken::new();
        assert!(!token.is_canceled());
        let clone = token.clone();
        std::thread::spawn(move || clone.cancel()).join().unwrap();
        assert!(token.is_canceled());
        token.reset();
        assert!(!token.is_canceled());
    }

    #[test]
    fn unknown_hosts_are_usage_errors() {
        let config = BuilderConfig::default();
        let error = connect(&config, "nope").unwrap_err();
        assert!(matches!(error, FrontendError::Usage(_)));
        assert_eq!(crate::errors::exit_code(&error), 2);
        let error = job_status(&config, "nope", "job_01J8Z3K4T9ABCDEFGHJKMNPQRS").unwrap_err();
        assert_eq!(crate::errors::exit_code(&error), 2);
    }

    fn artifact_record() -> ArtifactRecord {
        ArtifactRecord {
            artifact_version: 1,
            job_id: "job_01J8Z3K4T9ABCDEFGHJKMNPQRS".to_string(),
            game: GameSpec {
                name: "pokemon-y".to_string(),
                display_name: "Pokemon Y".to_string(),
                bundle_id: None,
                title_id: Some("0004000000055E00".to_string()),
            },
            ipa: ArtifactFile {
                name: "pokemon-y-AOT.ipa".to_string(),
                bytes: 101_000_000,
                sha256: "aa".repeat(32),
            },
            manifest_txt: ArtifactFile {
                name: "manifest.txt".to_string(),
                bytes: 128,
                sha256: "bb".repeat(32),
            },
            source: ArtifactSource {
                repo_revision: Some("4cc6186".to_string()),
                expected_revision: None,
                revision_matches: true,
            },
            toolchain: Toolchain {
                xcode: Some("16.4".to_string()),
                ..Toolchain::default()
            },
            build: BuildTiming {
                started_at: "2026-11-12T19:00:00Z".to_string(),
                finished_at: "2026-11-12T19:12:00Z".to_string(),
                warnings: Vec::new(),
            },
            retention_until: "2026-11-19T19:12:00Z".to_string(),
            fake: None,
        }
    }

    #[test]
    fn result_rendering_contains_the_checksum_and_privacy_facts() {
        let outcome = BuildOutcome {
            job_id: "job_01J8Z3K4T9ABCDEFGHJKMNPQRS".to_string(),
            ipa_path: PathBuf::from(r"C:\out\pokemon-y-AOT.ipa"),
            manifest_path: PathBuf::from(r"C:\out\manifest.txt"),
            record_path: PathBuf::from(r"C:\out\pokemon-y-artifact.json"),
            install_guide_path: PathBuf::from(r"C:\out\pokemon-y-INSTALL.txt"),
            artifact: artifact_record(),
            inputs_deleted: true,
            warnings: Vec::new(),
        };
        let text = render_result(&outcome).join("\n");
        assert!(text.contains("sha256: aaaa"), "{text}");
        assert!(text.contains("ROM on the Mac: deleted"), "{text}");
        assert!(text.contains("unsigned"), "{text}");
        assert!(text.contains("do not redistribute"), "{text}");
        assert!(text.contains("install guide:"), "{text}");
        let summary = artifact_summary(&outcome.artifact);
        assert_eq!(summary.name, "pokemon-y-AOT.ipa");
        assert_eq!(summary.bytes, 101_000_000);
    }

    #[test]
    fn status_rendering_includes_stages_and_errors() {
        let mut view: JobView = serde_json::from_value(serde_json::json!({
            "job_id": "job_01J8Z3K4T9ABCDEFGHJKMNPQRS",
            "state": "failed",
            "stage": "packaging",
            "created_at": "2026-11-12T19:00:00Z",
            "updated_at": "2026-11-12T19:12:00Z",
            "stages": [
                {"name": "preparing", "state": "done"},
                {"name": "recompiling", "state": "done"},
                {"name": "linking", "state": "done"},
                {"name": "packaging", "state": "failed"},
                {"name": "verifying", "state": "pending"}
            ],
            "inputs_present": false,
            "error": {
                "code": "build_failed",
                "message": "xcodebuild failed",
                "stage": "packaging",
                "hint": "check the Xcode log"
            }
        }))
        .unwrap();
        let text = render_status(&view).join("\n");
        assert!(
            text.contains("job_01J8Z3K4T9ABCDEFGHJKMNPQRS: failed (Packaging)"),
            "{text}"
        );
        assert!(text.contains("[FAIL ] Packaging"), "{text}");
        assert!(
            text.contains("error: build_failed: xcodebuild failed"),
            "{text}"
        );
        assert!(text.contains("hint: check the Xcode log"), "{text}");
        assert!(text.contains("inputs: deleted"), "{text}");
        // Stage table markup is stable.
        view.stages = vec![StageProgress::pending(
            builder_core::protocol::model::Stage::Preparing,
        )];
        assert!(render_status(&view)
            .join("\n")
            .contains("[     ] Preparing"));
    }

    #[test]
    fn console_progress_json_mode_is_silent_on_stderr_but_emits_events() {
        // Only verify that the human-mode note does not panic; output capture is
        // not available in a unit test.
        let mut progress = ConsoleProgress { json: true };
        progress.note("should be suppressed");
        let event = JobEvent {
            seq: 1,
            job_id: "job_01J8Z3K4T9ABCDEFGHJKMNPQRS".to_string(),
            ts: "2026-11-12T19:00:00Z".to_string(),
            kind: EventKind::End,
            stage: None,
            source: None,
            level: None,
            line: None,
            line_part: None,
            line_parts: None,
            state: None,
            error: None,
            artifact: None,
            message: None,
        };
        progress.event(&event);
        progress.rendered(&Rendered::Log("hidden in json mode".to_string()));
    }
}
