//! `zkb build`: hash and upload a ROM, stream progress, download and verify the
//! unsigned IPA.

use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};

use builder_core::client::{ArtifactWhat, BuilderClient};
use builder_core::config::BuilderConfig;
use builder_core::hash::sha256_reader;
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::model::{
    ErrorInfo, EventKind, InputRole, InputSpec, JobCreateRequest, JobOptions, JobState,
    SourceExpectation, TransportMode,
};
use builder_core::util::unix_now;
use clap::Args;

use crate::output::format_bytes;
use crate::{jobs, CliError, Printer, EXIT_HOST, EXIT_SUCCESS};

#[derive(Debug, Args)]
pub struct BuildArgs {
    /// Host name or id from `zkb host list`.
    #[arg(long)]
    pub host: String,
    /// Local decrypted ROM (.3ds or .cci).
    #[arg(long)]
    pub rom: PathBuf,
    /// Build name (slug, default: derived from the ROM file name).
    #[arg(long)]
    pub name: Option<String>,
    /// Home-screen display name (default: ROM file stem).
    #[arg(long)]
    pub display_name: Option<String>,
    /// Bundle identifier override (advanced).
    #[arg(long)]
    pub bundle_id: Option<String>,
    /// 16-hex title id (advanced; detected by the build otherwise).
    #[arg(long)]
    pub title_id: Option<String>,
    /// Directory for the downloaded IPA (default: ./out).
    #[arg(long)]
    pub out: Option<PathBuf>,
    /// Do not embed the MoltenVK framework.
    #[arg(long)]
    pub no_moltenvk: bool,
    /// Build with the hardware renderer environment enabled.
    #[arg(long)]
    pub hardware_renderer: bool,
    /// Force a clean build (discard Agent-side reuse).
    #[arg(long)]
    pub clean: bool,
    /// Keep the ROM on the Mac after the build (privacy warning).
    #[arg(long)]
    pub keep_input: bool,
    /// Expected 3ds2apple source revision on the Mac.
    #[arg(long)]
    pub expected_revision: Option<String>,
    /// Skip downloading the IPA (the job id is printed instead).
    #[arg(long)]
    pub no_download: bool,
    /// Accept a ROM whose extension is not .3ds/.cci.
    #[arg(long)]
    pub allow_any_file: bool,
}

pub fn run(args: &BuildArgs, config: &BuilderConfig, printer: Printer) -> Result<i32, CliError> {
    let rom = prepare_rom(args)?;
    let stem = rom
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("game")
        .to_string();
    let name = match &args.name {
        Some(name) => {
            builder_core::protocol::validate_game_name(name).map_err(CliError::usage)?;
            name.clone()
        }
        None => builder_core::protocol::slugify_game_name(&stem),
    };
    let display_name = match &args.display_name {
        Some(name) => name.clone(),
        None => default_display_name(&stem),
    };
    builder_core::protocol::validate_display_name(&display_name)
        .map_err(|message| CliError::usage(format!("--display-name: {message}")))?;
    if let Some(bundle_id) = &args.bundle_id {
        builder_core::protocol::validate_bundle_id(bundle_id)
            .map_err(|message| CliError::usage(format!("--bundle-id: {message}")))?;
    }
    if let Some(title_id) = &args.title_id {
        if !builder_core::protocol::valid_title_id(title_id) {
            return Err(CliError::usage(
                "--title-id must be 16 hex characters (for example 0004000000055E00)",
            ));
        }
    }
    if args.keep_input {
        printer.progress(
            "warning: --keep-input leaves the ROM on the Mac until you delete the job; only do this on a machine you control",
        );
    }

    let metadata = std::fs::metadata(&rom)
        .map_err(|error| CliError::Local(format!("cannot read {}: {error}", rom.display())))?;
    let total = metadata.len();
    printer.progress(format!(
        "hashing {} ({})",
        rom.display(),
        format_bytes(total)
    ));
    let file = File::open(&rom)
        .map_err(|error| CliError::Local(format!("cannot open {}: {error}", rom.display())))?;
    let mut last_report = 0_u64;
    let hash = sha256_reader(BufReader::new(file), |bytes| {
        if bytes - last_report >= 256 * 1024 * 1024 {
            last_report = bytes;
            printer.progress(format!(
                "  hashed {} / {}",
                format_bytes(bytes),
                format_bytes(total)
            ));
        }
    })
    .map_err(|error| CliError::Local(format!("hashing failed: {error}")))?;
    printer.progress(format!("sha256: {}", hash.sha256));

    let (mut client, _profile) = crate::connect(config, &args.host)?;
    let hello = client.hello().clone();
    if !hello.ready {
        return Err(CliError::Client(
            builder_core::client::ClientError::Remote {
                error: ErrorInfo::new(
                    ErrorCode::ToolchainMissing,
                    format!(
                        "the Mac is not ready to build: {}",
                        hello.refusals.join(", ")
                    ),
                )
                .with_hint("Run `zkb host test <host>` and fix the reported items on the Mac."),
            },
        ));
    }

    let request = JobCreateRequest {
        request_id: format!("req-{}-{}", unix_now(), std::process::id()),
        game: builder_core::protocol::model::GameSpec {
            name: name.clone(),
            display_name: display_name.clone(),
            bundle_id: args.bundle_id.clone(),
            title_id: args.title_id.clone(),
        },
        inputs: vec![InputSpec {
            role: InputRole::Rom,
            name: rom
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("rom")
                .to_string(),
            bytes: total,
            sha256: hash.sha256.clone(),
        }],
        options: JobOptions {
            embed_moltenvk: !args.no_moltenvk,
            hardware_renderer: args.hardware_renderer,
            clean: args.clean,
            keep_input: args.keep_input,
        },
        source: args
            .expected_revision
            .as_ref()
            .map(|revision| SourceExpectation {
                expected_revision: Some(revision.clone()),
            }),
        transport: TransportMode::Upload,
    };
    printer.progress(format!(
        "building {display_name} ({name}) on {}",
        profile_name(&args.host)
    ));
    let created = client.create_job(request)?;
    let job_id = created.job_id.clone();
    printer.progress(format!("job {job_id} created; uploading the ROM"));
    printer.json_result(&created);

    let declared = created
        .upload
        .roles
        .iter()
        .find(|role| role.role == InputRole::Rom)
        .ok_or_else(|| CliError::Local("the Agent's upload plan has no rom role".to_string()))?
        .clone();
    let mut last_report = 0_u64;
    client.upload(
        &job_id,
        InputRole::Rom,
        &rom,
        &declared,
        |received, total| {
            if received - last_report >= 128 * 1024 * 1024 || received == total {
                last_report = received;
                printer.progress(format!(
                    "  uploaded {} / {}",
                    format_bytes(received),
                    format_bytes(total)
                ));
            }
        },
    )?;
    client.input_ready(&job_id)?;
    printer.progress(format!(
        "upload complete; follow the build with `zkb logs --host {} {job_id}`",
        args.host
    ));

    let subscribe = client.subscribe(&job_id, 0)?;
    printer.json_result(&subscribe);
    while let Some(event) = client.next_event()? {
        let end = event.kind == EventKind::End;
        printer.event(&event);
        if end {
            break;
        }
    }

    let view = client.status(&job_id)?;
    match view.state {
        JobState::Succeeded => {
            let artifact = client.artifact_manifest(&job_id)?;
            if args.no_download {
                printer.line(format!("job {job_id} succeeded"));
                printer.line(format!("ipa: {}", artifact.ipa.name));
                printer.line(format!("sha256: {}", artifact.ipa.sha256));
                printer.line(format!(
                    "download it with: zkb download --host {} {job_id}",
                    args.host
                ));
                return Ok(EXIT_SUCCESS);
            }
            let out = args.out.clone().unwrap_or_else(|| PathBuf::from("out"));
            let (path, artifact) = jobs::download_verified(&mut client, &job_id, &out, printer)?;
            printer.line(format!("ipa: {}", path.display()));
            printer.line(format!("sha256: {}", artifact.ipa.sha256));
            printer.line(format!("manifest: {}", out.join("manifest.txt").display()));
            printer.line(format!(
                "title_id: {}",
                artifact.game.title_id.as_deref().unwrap_or("unknown")
            ));
            printer.line(format!(
                "source_revision: {}",
                artifact
                    .source
                    .repo_revision
                    .as_deref()
                    .unwrap_or("unknown")
            ));
            printer.line(
                "This IPA is unsigned and contains code derived from your game; sign and install it yourself (Sideloadly/AltStore) and do not redistribute it.",
            );
            printer.json_result(&artifact);
            Ok(EXIT_SUCCESS)
        }
        JobState::Failed => Err(CliError::BuildFailed {
            error: view.error.unwrap_or_else(|| {
                ErrorInfo::new(
                    ErrorCode::BuildFailed,
                    "the build failed (the Agent reported no detail)",
                )
            }),
        }),
        JobState::Canceled => Err(CliError::Canceled),
        JobState::Interrupted => Err(CliError::Interrupted(
            view.error
                .map(|error| error.message)
                .unwrap_or_else(|| "the Mac restarted or the Agent stopped".to_string()),
        )),
        other => {
            printer.progress(format!(
                "connection closed while the job was {other}; it keeps running on the Mac"
            ));
            printer.progress(format!(
                "reattach with: zkb status --host {} {job_id} --follow",
                args.host
            ));
            Ok(EXIT_HOST)
        }
    }
}

fn profile_name(host: &str) -> &str {
    host
}

fn prepare_rom(args: &BuildArgs) -> Result<PathBuf, CliError> {
    if !args.rom.is_file() {
        return Err(CliError::usage(format!(
            "ROM file {} does not exist",
            args.rom.display()
        )));
    }
    let extension = args
        .rom
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| extension.to_ascii_lowercase())
        .unwrap_or_default();
    if !args.allow_any_file && extension != "3ds" && extension != "cci" {
        return Err(CliError::usage(format!(
            "{} does not look like a .3ds/.cci ROM (pass --allow-any-file to try anyway)",
            args.rom.display()
        )));
    }
    let canonical = args.rom.canonicalize().map_err(|error| {
        CliError::Local(format!("cannot resolve {}: {error}", args.rom.display()))
    })?;
    Ok(canonical)
}

fn default_display_name(stem: &str) -> String {
    let trimmed: String = stem
        .chars()
        .filter(|ch| !ch.is_control() && *ch != '/' && *ch != '\\')
        .collect();
    let trimmed = trimmed.trim();
    if trimmed.is_empty() {
        return "Game".to_string();
    }
    trimmed.chars().take(48).collect()
}

// Keep the ArtifactWhat import used by the shared download helper signature.
#[allow(dead_code)]
fn _artifact_what() -> ArtifactWhat {
    ArtifactWhat::Ipa
}

// Keep the BuilderClient import meaningful for doc links in this module.
#[allow(dead_code)]
fn _client_type(_: &BuilderClient) {}

// Keep the ROM size helper reachable for tests.
#[allow(dead_code)]
fn _path_type(_: &Path) {}
