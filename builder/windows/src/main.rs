//! `builder-windows`: the Windows frontend binary.
//!
//! Running it with no arguments starts the guided session. The subcommands expose
//! the same steps individually for shortcuts, scripted use and troubleshooting.

use std::path::PathBuf;

use builder_core::config::BuilderConfig;
use builder_windows::app::{self, ConsoleProgress};
use builder_windows::errors::{self, FrontendError};
use builder_windows::hosts::{self, AddHostOptions};
use builder_windows::paths;
use builder_windows::preflight::{self, BuildPlan, PlanOptions};
use builder_windows::wizard::{self, WizardOptions};
use clap::{Parser, Subcommand};

const EXIT_USAGE: i32 = 2;

#[derive(Debug, Parser)]
#[command(
    name = "builder-windows",
    version,
    about = "Build your own 3ds2apple IPA on a macOS host you control",
    long_about = "The Windows Builder turns a decrypted ROM you own into an unsigned iOS app by \
                  driving the Build Agent on a macOS host you control. It uploads the ROM only to \
                  that host, streams the build, and downloads and verifies the unsigned IPA. It \
                  never signs, installs or distributes anything, and never asks for an Apple ID."
)]
struct Cli {
    /// Builder configuration file (default: %APPDATA%\3ds2apple\builder\config.toml).
    #[arg(long, global = true)]
    config: Option<PathBuf>,
    /// Emit machine-readable JSON/NDJSON instead of human text where possible.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Guided session: set up a host, pick a ROM, build, install guide (default).
    App(AppArgs),
    /// Check this PC (and optionally a Mac) before building.
    Doctor {
        /// Also run the Agent's doctor checks on this host.
        #[arg(long)]
        host: Option<String>,
    },
    /// Manage macOS build hosts (shared with the zkb CLI).
    Host {
        #[command(subcommand)]
        command: HostCommand,
    },
    /// Build one game and download the unsigned IPA.
    Build(BuildArgs),
    /// Show a job's status.
    Status {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
        /// Keep streaming until the job finishes.
        #[arg(long)]
        follow: bool,
    },
    /// Print a job's log.
    Logs {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
        /// Resume from this event sequence number.
        #[arg(long, default_value_t = 0)]
        since: u64,
        /// Print the retained log and exit instead of following.
        #[arg(long)]
        no_follow: bool,
    },
    /// Cancel a running or queued job.
    Cancel {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
        #[arg(long)]
        reason: Option<String>,
    },
    /// Download and verify a finished build's IPA.
    Download {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
        /// Destination directory (default: the Builder artifacts directory).
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// List the jobs the Agent still holds.
    Jobs {
        /// Host name or id.
        #[arg(long)]
        host: String,
        #[arg(long)]
        limit: Option<u32>,
    },
    /// Delete a finished job's data on the Agent.
    Delete {
        /// Host name or id.
        #[arg(long)]
        host: String,
        job_id: String,
    },
    /// Print or write the installation guide for an IPA.
    InstallGuide(InstallGuideArgs),
    /// Run the on-PC compatibility checks (no Mac and no ROM needed).
    SelfTest,
    /// Show the Builder configuration.
    Config,
    /// Open a folder or file in Explorer.
    Open { path: PathBuf },
}

#[derive(Debug, clap::Args)]
struct AppArgs {
    /// Use this host instead of asking.
    #[arg(long)]
    host: Option<String>,
    /// ROM to build instead of asking.
    #[arg(long)]
    rom: Option<PathBuf>,
    /// Optional supplementary file uploaded with the ROM.
    #[arg(long)]
    keys: Option<PathBuf>,
    /// Output folder for the IPA (default: the Builder artifacts directory).
    #[arg(long)]
    out: Option<PathBuf>,
    /// Build name instead of asking.
    #[arg(long)]
    name: Option<String>,
    /// Home-screen name instead of asking.
    #[arg(long)]
    display_name: Option<String>,
    /// Keep the ROM on the Mac after the build (privacy warning).
    #[arg(long)]
    keep_input: bool,
    /// Force a clean build (discard Agent-side reuse).
    #[arg(long)]
    clean: bool,
    /// Validate and print the plan, then stop before connecting.
    #[arg(long)]
    dry_run: bool,
    /// Accept the defaults and skip the optional prompts (non-interactive use).
    #[arg(long)]
    yes: bool,
}

#[derive(Debug, clap::Args)]
struct BuildArgs {
    /// Host name or id from `builder-windows host list`.
    #[arg(long)]
    host: String,
    /// Local decrypted ROM (.3ds or .cci).
    #[arg(long)]
    rom: PathBuf,
    /// Optional supplementary file uploaded with the ROM.
    #[arg(long)]
    keys: Option<PathBuf>,
    /// Build name (slug, default: derived from the ROM file name).
    #[arg(long)]
    name: Option<String>,
    /// Home-screen display name (default: ROM file stem).
    #[arg(long)]
    display_name: Option<String>,
    /// Bundle identifier override (advanced).
    #[arg(long)]
    bundle_id: Option<String>,
    /// 16-hex title id (advanced; detected during the build otherwise).
    #[arg(long)]
    title_id: Option<String>,
    /// Expected 3ds2apple source revision on the Mac.
    #[arg(long)]
    expected_revision: Option<String>,
    /// Directory for the downloaded IPA (default: the Builder artifacts directory).
    #[arg(long)]
    out: Option<PathBuf>,
    /// Do not embed the MoltenVK framework.
    #[arg(long)]
    no_moltenvk: bool,
    /// Build with the hardware renderer environment enabled.
    #[arg(long)]
    hardware_renderer: bool,
    /// Force a clean build (discard Agent-side reuse).
    #[arg(long)]
    clean: bool,
    /// Keep the ROM on the Mac after the build (privacy warning).
    #[arg(long)]
    keep_input: bool,
    /// Accept a ROM whose extension is not .3ds/.cci.
    #[arg(long)]
    allow_any_file: bool,
    /// Do not check free disk space before downloading.
    #[arg(long)]
    skip_disk_check: bool,
    /// Open the output folder when the build succeeds.
    #[arg(long)]
    open: bool,
}

#[derive(Debug, clap::Args)]
struct InstallGuideArgs {
    /// The downloaded IPA.
    #[arg(long)]
    ipa: PathBuf,
    /// SHA256 of the IPA (as printed by the build).
    #[arg(long)]
    sha256: String,
    /// Home-screen name shown in the guide.
    #[arg(long)]
    display_name: Option<String>,
    /// Also write the guide to this file.
    #[arg(long)]
    out: Option<PathBuf>,
}

#[derive(Debug, Subcommand)]
enum HostCommand {
    /// Add a macOS build host (SSH pairing or a local Agent binary).
    Add(Box<HostAddArgs>),
    /// List configured hosts.
    List,
    /// Connect to a host and run its doctor checks.
    Test { name: String },
    /// Remove a host from this PC's configuration.
    Remove { name: String },
}

#[derive(Debug, clap::Args)]
struct HostAddArgs {
    /// Name for this host (also becomes its id).
    #[arg(long)]
    name: String,
    /// SSH destination `user@host` (system OpenSSH, key authentication only).
    #[arg(long)]
    ssh: Option<String>,
    /// SSH port.
    #[arg(long, default_value_t = 22)]
    port: u16,
    /// Existing private key to use instead of creating a dedicated one.
    #[arg(long)]
    identity: Option<PathBuf>,
    /// Run a `builder-agent` binary on this machine instead of connecting over SSH.
    #[arg(long)]
    local_agent: Option<PathBuf>,
    /// Extra argument for the local Agent binary (repeatable).
    #[arg(long = "local-arg")]
    local_args: Vec<String>,
    /// Extra environment variable `K=V` for the local Agent (repeatable).
    #[arg(long = "local-env")]
    local_env: Vec<String>,
    /// Trust the scanned host key without an interactive confirmation.
    #[arg(long)]
    yes: bool,
    /// Pin the host key by SHA256 fingerprint instead of using --yes.
    #[arg(long)]
    fingerprint: Option<String>,
    /// Path of `builder-agent` on the Mac (shown in the authorized_keys line).
    #[arg(long, default_value = "~/.local/bin/builder-agent")]
    agent_path: String,
}

fn load_config(config_path: &std::path::Path) -> Result<BuilderConfig, FrontendError> {
    BuilderConfig::load(config_path).map_err(FrontendError::Config)
}

fn main() {
    let cli = Cli::parse();
    let config_path = paths::config_file_path(cli.config.as_deref());
    let result = run(cli.command, cli.json, &config_path);
    match result {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            report_error(&error, cli.json);
            std::process::exit(errors::exit_code(&error));
        }
    }
}

fn run(
    command: Option<Command>,
    json: bool,
    config_path: &std::path::Path,
) -> Result<i32, FrontendError> {
    let Some(command) = command else {
        let mut config = load_config(config_path)?;
        return wizard::run(&mut config, config_path, &WizardOptions::default());
    };
    match command {
        Command::App(args) => {
            let mut config = load_config(config_path)?;
            let options = WizardOptions {
                host: args.host,
                rom: args.rom,
                keys: args.keys,
                out_dir: args.out,
                name: args.name,
                display_name: args.display_name,
                keep_input: args.keep_input,
                clean: args.clean,
                dry_run: args.dry_run,
                yes: args.yes,
            };
            wizard::run(&mut config, config_path, &options)
        }
        Command::SelfTest => Ok(builder_windows::selftest::run(json)),
        Command::Open { path } => {
            builder_windows::artifacts::open_in_file_manager(&path)?;
            Ok(errors::EXIT_SUCCESS)
        }
        Command::Config => {
            let config = load_config(config_path)?;
            show_config(&config, config_path, json)
        }
        Command::Doctor { host } => {
            let mut config = load_config(config_path)?;
            builder_windows::doctor::run(&mut config, config_path, host.as_deref(), json)
        }
        Command::Host { command } => host_command(command, config_path, json),
        Command::Build(args) => {
            let config = load_config(config_path)?;
            build_command(args, &config, json)
        }
        Command::Status {
            host,
            job_id,
            follow,
        } => {
            let config = load_config(config_path)?;
            let mut progress = ConsoleProgress { json };
            if follow {
                let cancel = app::CancelToken::new();
                if let Some(view) =
                    app::follow_job(&config, &host, &job_id, 0, &mut progress, &cancel)?
                {
                    print_status(&view, json);
                }
            } else {
                let view = app::job_status(&config, &host, &job_id)?;
                print_status(&view, json);
            }
            Ok(errors::EXIT_SUCCESS)
        }
        Command::Logs {
            host,
            job_id,
            since,
            no_follow,
        } => {
            let config = load_config(config_path)?;
            let mut progress = ConsoleProgress { json };
            if no_follow {
                let view = app::job_status(&config, &host, &job_id)?;
                if !view.state.is_terminal() {
                    return Err(FrontendError::usage(
                        "the job is still running; use `builder-windows logs --host <host> <job-id>` to follow it",
                    ));
                }
            }
            let cancel = app::CancelToken::new();
            if let Some(view) =
                app::follow_job(&config, &host, &job_id, since, &mut progress, &cancel)?
            {
                if no_follow {
                    print_status(&view, json);
                }
            }
            Ok(errors::EXIT_SUCCESS)
        }
        Command::Cancel {
            host,
            job_id,
            reason,
        } => {
            let config = load_config(config_path)?;
            let state = app::cancel_job(&config, &host, &job_id, reason.as_deref())?;
            if json {
                println!(
                    "{}",
                    serde_json::json!({"job_id": job_id, "state": state.as_str()})
                );
            } else {
                println!("job {job_id}: {state}");
            }
            Ok(errors::EXIT_SUCCESS)
        }
        Command::Download { host, job_id, out } => {
            let config = load_config(config_path)?;
            let out = out.unwrap_or_else(paths::artifacts_dir);
            let mut progress = ConsoleProgress { json };
            let (ipa, manifest, record) =
                app::download_job(&config, &host, &job_id, &out, &mut progress)?;
            if json {
                println!(
                    "{}",
                    serde_json::json!({
                        "ipa": paths::display_path(&ipa),
                        "manifest": paths::display_path(&manifest),
                        "record": paths::display_path(&record),
                    })
                );
            } else {
                println!("ipa: {}", paths::display_path(&ipa));
                println!("manifest: {}", paths::display_path(&manifest));
                println!("record: {}", paths::display_path(&record));
            }
            Ok(errors::EXIT_SUCCESS)
        }
        Command::Jobs { host, limit } => {
            let config = load_config(config_path)?;
            let jobs = app::list_jobs(&config, &host, limit)?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&jobs).unwrap_or_else(|_| "[]".to_string())
                );
            } else if jobs.is_empty() {
                println!("the Agent holds no jobs");
            } else {
                for job in &jobs {
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
                    println!(
                        "{:<34} {:<12} {:<28} {:<14} {}",
                        job.job_id, job.state, game, job.created_at, artifact
                    );
                }
            }
            Ok(errors::EXIT_SUCCESS)
        }
        Command::Delete { host, job_id } => {
            let config = load_config(config_path)?;
            let deleted = app::delete_job(&config, &host, &job_id)?;
            if json {
                println!(
                    "{}",
                    serde_json::json!({"job_id": deleted, "deleted": true})
                );
            } else {
                println!("job {deleted} deleted from the Mac");
            }
            Ok(errors::EXIT_SUCCESS)
        }
        Command::InstallGuide(args) => install_guide_command(args, json),
    }
}

fn print_status(view: &builder_core::protocol::model::JobView, json: bool) {
    if json {
        if let Ok(text) = serde_json::to_string_pretty(view) {
            println!("{text}");
        }
        return;
    }
    for line in app::render_status(view) {
        println!("{line}");
    }
}

fn host_command(
    command: HostCommand,
    config_path: &std::path::Path,
    json: bool,
) -> Result<i32, FrontendError> {
    let mut config = load_config(config_path)?;
    match command {
        HostCommand::Add(args) => {
            let args = *args;
            let mut local_env = Vec::new();
            for pair in &args.local_env {
                let Some((key, value)) = pair.split_once('=') else {
                    return Err(FrontendError::usage(format!(
                        "--local-env expects K=V, got {pair:?}"
                    )));
                };
                local_env.push((key.to_string(), value.to_string()));
            }
            let mut report = |line: &str| {
                if json {
                    eprintln!("{line}");
                } else {
                    println!("{line}");
                }
            };
            let added = hosts::add_host(
                &mut config,
                config_path,
                &AddHostOptions {
                    name: args.name,
                    ssh: args.ssh,
                    port: args.port,
                    identity: args.identity,
                    local_agent: args.local_agent,
                    local_args: args.local_args,
                    local_env,
                    yes: args.yes,
                    fingerprint: args.fingerprint,
                    agent_path: args.agent_path,
                },
                &mut report,
            )?;
            if let Some(line) = &added.authorized_keys_line {
                if json {
                    eprintln!();
                    eprintln!("Add this line to ~/.ssh/authorized_keys on the Mac:");
                    eprintln!("  {line}");
                } else {
                    println!();
                    println!("Add this line to ~/.ssh/authorized_keys on the Mac:");
                    println!();
                    println!("  {line}");
                    println!();
                    println!("The forced command means this key can only run the Build Agent.");
                }
            }
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "host_id": added.profile.id,
                        "name": added.profile.name,
                        "endpoint": added.profile.transport.describe(),
                        "authorized_keys_line": added.authorized_keys_line,
                        "fingerprints": added.fingerprints,
                    }))
                    .unwrap_or_default()
                );
            } else {
                println!(
                    "test it with: builder-windows host test {}",
                    added.profile.id
                );
            }
            Ok(errors::EXIT_SUCCESS)
        }
        HostCommand::List => {
            let summaries = hosts::list_hosts(&config);
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&summaries).unwrap_or_else(|_| "[]".to_string())
                );
            } else if summaries.is_empty() {
                println!("no build hosts configured; add one with `builder-windows host add`");
            } else {
                for summary in &summaries {
                    println!(
                        "{:<24} {:<20} {:<44} {}",
                        summary.id, summary.name, summary.endpoint, summary.status
                    );
                }
            }
            Ok(errors::EXIT_SUCCESS)
        }
        HostCommand::Test { name } => {
            let report = hosts::test_host(&mut config, config_path, &name)?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&report).unwrap_or_default()
                );
            } else {
                for line in hosts::render_test_report(&report) {
                    println!("{line}");
                }
            }
            if report.ready {
                Ok(errors::EXIT_SUCCESS)
            } else {
                Ok(errors::EXIT_HOST)
            }
        }
        HostCommand::Remove { name } => {
            let removed = hosts::remove_host(&mut config, config_path, &name)?;
            if json {
                println!(
                    "{}",
                    serde_json::json!({"host_id": removed.id, "removed": true})
                );
            } else {
                println!("removed host {name}");
            }
            Ok(errors::EXIT_SUCCESS)
        }
    }
}

fn build_command(
    args: BuildArgs,
    config: &BuilderConfig,
    json: bool,
) -> Result<i32, FrontendError> {
    let rom = preflight::check_rom(&args.rom, args.allow_any_file)?;
    let keys = match &args.keys {
        Some(path) => Some(preflight::check_supplementary(path)?),
        None => None,
    };
    let (default_name, default_display) = preflight::derive_names(&rom.name);
    let name = match &args.name {
        Some(raw) => preflight::normalize_build_name(raw)?,
        None => preflight::normalize_build_name(&default_name)?,
    };
    let display_name = match &args.display_name {
        Some(raw) => preflight::normalize_display_name(raw)?,
        None => preflight::normalize_display_name(&default_display)?,
    };
    let bundle_id = match &args.bundle_id {
        Some(raw) => Some(preflight::normalize_bundle_id(raw)?),
        None => None,
    };
    let title_id = match &args.title_id {
        Some(raw) => Some(preflight::normalize_title_id(raw)?),
        None => None,
    };
    let expected_revision = match &args.expected_revision {
        Some(raw) => Some(preflight::normalize_expected_revision(raw)?),
        None => None,
    };
    let out_dir = args.out.unwrap_or_else(paths::artifacts_dir);
    let plan = BuildPlan {
        host: args.host.clone(),
        rom,
        keys,
        name,
        display_name,
        bundle_id,
        title_id,
        expected_revision,
        out_dir,
        options: PlanOptions {
            embed_moltenvk: !args.no_moltenvk,
            hardware_renderer: args.hardware_renderer,
            clean: args.clean,
            keep_input: args.keep_input,
        },
    };
    if !args.skip_disk_check {
        preflight::check_output_space(&plan.out_dir)?;
    }
    let mut progress = ConsoleProgress { json };
    let cancel = app::CancelToken::new();
    let outcome = app::run_build(config, &plan, &mut progress, &cancel)?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&outcome.artifact).unwrap_or_default()
        );
    } else {
        for line in app::render_result(&outcome) {
            println!("{line}");
        }
        println!();
        println!("{}", builder_windows::install_guide::responsibility_note());
        if args.open {
            let _ = builder_windows::artifacts::open_in_file_manager(&outcome.install_guide_path);
        }
    }
    Ok(errors::EXIT_SUCCESS)
}

fn install_guide_command(args: InstallGuideArgs, json: bool) -> Result<i32, FrontendError> {
    use builder_windows::install_guide::{self, ArtifactGuide};
    if !args.ipa.is_file() {
        return Err(FrontendError::usage(format!(
            "IPA file {} does not exist",
            paths::display_path(&args.ipa)
        )));
    }
    let expected = builder_core::client::parse_sha256(&args.sha256)
        .or_else(|_| builder_core::client::parse_sha256(args.sha256.trim()))
        .map_err(FrontendError::usage)?;
    let actual = builder_windows::artifacts::compute_sha256(&args.ipa)?;
    let matches = actual.eq_ignore_ascii_case(&expected);
    let display_name = args.display_name.unwrap_or_else(|| {
        args.ipa
            .file_stem()
            .map(|stem| stem.to_string_lossy().to_string())
            .unwrap_or_else(|| "Game".to_string())
    });
    let text = install_guide::render_windows(&ArtifactGuide {
        display_name: &display_name,
        ipa_path: &args.ipa,
        bytes: std::fs::metadata(paths::extended_length_path(&args.ipa))
            .map(|metadata| metadata.len())
            .unwrap_or(0),
        sha256: &actual,
        title_id: None,
        source_revision: None,
        xcode: None,
        host_name: None,
    });
    if let Some(out) = &args.out {
        builder_windows::artifacts::write_atomic(out, text.as_bytes()).map_err(|error| {
            FrontendError::local(format!(
                "cannot write {}: {error}",
                paths::display_path(out)
            ))
        })?;
    }
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "ipa": paths::display_path(&args.ipa),
                "sha256": actual,
                "matches_expected": matches,
                "guide": text,
            }))
            .unwrap_or_default()
        );
    } else {
        println!("{text}");
        if !matches {
            eprintln!();
            eprintln!(
                "warning: the file's SHA256 does not match --sha256; it may be a different build"
            );
            eprintln!("  expected: {expected}");
            eprintln!("  actual:   {actual}");
            return Ok(errors::EXIT_IO);
        }
    }
    Ok(errors::EXIT_SUCCESS)
}

fn show_config(
    config: &BuilderConfig,
    config_path: &std::path::Path,
    json: bool,
) -> Result<i32, FrontendError> {
    let mut redacted = config.clone();
    for host in &mut redacted.hosts {
        if let builder_core::transport::TransportSpec::Local(local) = &mut host.transport {
            for (key, value) in local.env.iter_mut() {
                let upper = key.to_ascii_uppercase();
                if upper.contains("TOKEN") || upper.contains("SECRET") || upper.contains("PASSWORD")
                {
                    *value = "<redacted>".to_string();
                }
            }
        }
    }
    let text = toml::to_string_pretty(&redacted)
        .map_err(|error| FrontendError::Config(format!("could not render the config: {error}")))?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "config": paths::display_path(config_path),
                "hosts": redacted.hosts.iter().map(|host| serde_json::json!({
                    "id": host.id,
                    "name": host.name,
                    "endpoint": host.transport.describe(),
                    "agent_version": host.agent_version,
                    "last_test_at": host.last_test_at,
                })).collect::<Vec<_>>(),
            }))
            .unwrap_or_default()
        );
    } else {
        println!("# {}", paths::display_path(config_path));
        print!("{text}");
    }
    Ok(errors::EXIT_SUCCESS)
}

fn report_error(error: &FrontendError, json: bool) {
    if json {
        let payload = serde_json::json!({
            "error": {
                "code": error.protocol_code().map(|code| code.as_str()),
                "message": error.to_string(),
                "stage": error.stage(),
                "hint": error.hint(),
                "log_tail": error.log_tail(),
            }
        });
        println!("{payload}");
    }
    eprintln!("builder-windows: {error}");
    if let Some(stage) = error.stage() {
        eprintln!("stage: {stage}");
    }
    if let Some(hint) = error.hint() {
        eprintln!("hint: {hint}");
    }
    if let Some(tail) = error.log_tail() {
        eprintln!("last log lines:");
        for line in tail {
            eprintln!("  {line}");
        }
    }
    let _ = EXIT_USAGE;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cli_defines_the_documented_commands() {
        use clap::CommandFactory;
        let command = Cli::command();
        let names: Vec<String> = command
            .get_subcommands()
            .map(|sub| sub.get_name().to_string())
            .collect();
        for expected in [
            "app",
            "doctor",
            "host",
            "build",
            "status",
            "logs",
            "cancel",
            "download",
            "jobs",
            "delete",
            "install-guide",
            "self-test",
            "config",
            "open",
        ] {
            assert!(
                names.iter().any(|name| name == expected),
                "missing {expected}: {names:?}"
            );
        }
    }

    #[test]
    fn host_subcommands_are_complete() {
        use clap::CommandFactory;
        let command = Cli::command();
        let host = command
            .get_subcommands()
            .find(|sub| sub.get_name() == "host")
            .expect("host command");
        let names: Vec<String> = host
            .get_subcommands()
            .map(|sub| sub.get_name().to_string())
            .collect();
        for expected in ["add", "list", "test", "remove"] {
            assert!(names.iter().any(|name| name == expected), "{names:?}");
        }
    }

    #[test]
    fn the_product_name_is_stable() {
        assert!(builder_windows::FRONTEND_NAME.contains("Windows"));
        assert_eq!(builder_windows::VERSION, env!("CARGO_PKG_VERSION"));
    }
}
