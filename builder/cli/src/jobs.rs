//! `zkb status | logs | cancel | download | jobs | delete`.

use std::path::{Path, PathBuf};

use crate::{connect, CliError, Printer, EXIT_SUCCESS};
use builder_core::client::{ArtifactWhat, BuilderClient};
use builder_core::config::BuilderConfig;
use builder_core::protocol::model::{ArtifactRecord, EventKind, JobState, JobView};

/// Download the IPA and manifest, verify the SHA256 and acknowledge the
/// artifact to the Agent.
pub fn download_verified(
    client: &mut BuilderClient,
    job_id: &str,
    out_dir: &Path,
    printer: Printer,
) -> Result<(PathBuf, ArtifactRecord), CliError> {
    let artifact = client.artifact_manifest(job_id)?;
    std::fs::create_dir_all(out_dir).map_err(|error| {
        CliError::Local(format!("cannot create {}: {error}", out_dir.display()))
    })?;
    let destination = out_dir.join(&artifact.ipa.name);
    printer.progress(format!(
        "downloading {} ({})",
        artifact.ipa.name,
        crate::output::format_bytes(artifact.ipa.bytes)
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
                printer.progress(format!(
                    "  downloaded {} / {}",
                    crate::output::format_bytes(received),
                    crate::output::format_bytes(total)
                ));
            }
        },
    )?;
    let manifest_destination = out_dir.join("manifest.txt");
    client.download_artifact(
        job_id,
        ArtifactWhat::ManifestTxt,
        &manifest_destination,
        artifact.manifest_txt.bytes,
        &artifact.manifest_txt.sha256,
        0,
        |_, _| {},
    )?;
    let local_record = out_dir.join(format!("{}-artifact.json", artifact.game.name));
    if let Ok(text) = serde_json::to_string_pretty(&artifact) {
        let _ = std::fs::write(&local_record, text);
    }
    client.ack_artifact(job_id, &outcome.sha256)?;
    Ok((outcome.path, artifact))
}

pub fn status(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    printer: Printer,
) -> Result<i32, CliError> {
    let (mut client, _profile) = connect(config, host)?;
    let view = client.status(job_id)?;
    print_view(&view, printer);
    printer.json_result(&view);
    Ok(EXIT_SUCCESS)
}

fn print_view(view: &JobView, printer: Printer) {
    if printer.json {
        return;
    }
    printer.line(format!(
        "job {}: {}{}",
        view.job_id,
        view.state,
        view.stage
            .map(|stage| format!(" ({})", stage.label()))
            .unwrap_or_default()
    ));
    if let Some(game) = &view.game {
        printer.line(format!("game: {} ({})", game.name, game.display_name));
    }
    printer.line(format!("created: {}", view.created_at));
    if let Some(started) = &view.started_at {
        printer.line(format!("started: {started}"));
    }
    if let Some(finished) = &view.finished_at {
        printer.line(format!("finished: {finished}"));
    }
    if let Some(percent) = view.percent {
        printer.line(format!("progress: {percent}%"));
    }
    printer.line(format!(
        "inputs: {} · kept: {}",
        if view.inputs_present {
            "on the Mac"
        } else {
            "deleted"
        },
        view.inputs_kept
    ));
    if !view.warnings.is_empty() {
        for warning in &view.warnings {
            printer.line(format!("warning: {warning}"));
        }
    }
    if let Some(error) = &view.error {
        printer.line(format!("error: {}: {}", error.code, error.message));
        if let Some(hint) = &error.hint {
            printer.line(format!("hint: {hint}"));
        }
    }
    if let Some(artifact) = &view.artifact {
        printer.line(format!(
            "artifact: {} ({} bytes, sha256 {})",
            artifact.name, artifact.bytes, artifact.sha256
        ));
    }
}

pub fn follow(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    since: u64,
    printer: Printer,
) -> Result<i32, CliError> {
    let (mut client, _profile) = connect(config, host)?;
    let reply = client.subscribe(job_id, since)?;
    printer.json_result(&reply);
    while let Some(event) = client.next_event()? {
        let end = event.kind == EventKind::End;
        printer.event(&event);
        if end {
            break;
        }
    }
    if let Ok(view) = client.status(job_id) {
        if view.state.is_terminal() {
            print_view(&view, printer);
            if printer.json {
                printer.json_result(&view);
            }
            if view.state == JobState::Failed {
                return Ok(crate::EXIT_BUILD_FAILED);
            }
        }
    }
    Ok(EXIT_SUCCESS)
}

pub fn logs_only(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    since: u64,
    printer: Printer,
) -> Result<i32, CliError> {
    let (mut client, _profile) = connect(config, host)?;
    let reply = client.subscribe(job_id, since)?;
    if !reply.job.state.is_terminal() {
        return Err(CliError::usage(
            "the job is still running; use `zkb logs --follow` (or omit --no-follow)",
        ));
    }
    printer.json_result(&reply);
    while let Some(event) = client.next_event()? {
        let end = event.kind == EventKind::End;
        printer.event(&event);
        if end {
            break;
        }
    }
    Ok(EXIT_SUCCESS)
}

pub fn cancel(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    reason: Option<&str>,
    printer: Printer,
) -> Result<i32, CliError> {
    let (mut client, _profile) = connect(config, host)?;
    let reply = client.cancel(job_id, reason)?;
    printer.line(format!("job {}: {}", reply.job_id, reply.state));
    printer.json_result(&reply);
    Ok(EXIT_SUCCESS)
}

pub fn download(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    out: &Path,
    verify: bool,
    printer: Printer,
) -> Result<i32, CliError> {
    let _ = verify; // verification is always performed while writing
    let (mut client, _profile) = connect(config, host)?;
    let (path, artifact) = download_verified(&mut client, job_id, out, printer)?;
    printer.line(format!("ipa: {}", path.display()));
    printer.line(format!("sha256: {}", artifact.ipa.sha256));
    printer.line(format!("manifest: {}", out.join("manifest.txt").display()));
    printer.json_result(&artifact);
    Ok(EXIT_SUCCESS)
}

pub fn list(
    config: &BuilderConfig,
    host: &str,
    limit: Option<u32>,
    printer: Printer,
) -> Result<i32, CliError> {
    let (mut client, _profile) = connect(config, host)?;
    let reply = client.list_jobs(limit, None)?;
    if !printer.json {
        if reply.jobs.is_empty() {
            printer.line("the Agent holds no jobs");
        } else {
            for job in &reply.jobs {
                let game = job
                    .game
                    .as_ref()
                    .map(|game| game.display_name.clone())
                    .unwrap_or_else(|| "-".to_string());
                let artifact = job
                    .artifact
                    .as_ref()
                    .map(|artifact| format!("{} ({} bytes)", artifact.name, artifact.bytes))
                    .unwrap_or_else(|| "-".to_string());
                printer.line(format!(
                    "{:<34} {:<12} {:<28} {:<14} {}",
                    job.job_id, job.state, game, job.created_at, artifact
                ));
            }
        }
    }
    printer.json_result(&reply);
    Ok(EXIT_SUCCESS)
}

pub fn delete(
    config: &BuilderConfig,
    host: &str,
    job_id: &str,
    printer: Printer,
) -> Result<i32, CliError> {
    let (mut client, _profile) = connect(config, host)?;
    let reply = client.delete_job(job_id)?;
    printer.line(format!("job {} deleted from the Mac", reply.job_id));
    printer.json_result(&reply);
    Ok(EXIT_SUCCESS)
}
