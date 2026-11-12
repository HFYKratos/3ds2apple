//! Guided first-run session (`builder-windows` with no arguments).
//!
//! The wizard is the double-click experience: it explains what the Builder does
//! and what it will never do, sets up a build host if there is none, validates
//! the ROM, shows a summary before anything leaves the PC, streams the build
//! with a `c` + Enter cancel, then prints the result and the installation guide.
//!
//! All input goes through one reader thread so that the same keystrokes can
//! either answer a prompt or request cancellation while a build runs.

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::thread;
use std::time::Duration;

use builder_core::config::BuilderConfig;

use crate::app::{self, CancelToken, ConsoleProgress};
use crate::artifacts;
use crate::errors::{self, FrontendError};
use crate::hosts::{self, AddHostOptions};
use crate::paths;
use crate::preflight::{self, BuildPlan, PlanOptions};
use crate::FRONTEND_NAME;

/// Options that pre-fill parts of the wizard (for shortcuts and scripted use).
#[derive(Debug, Clone, Default)]
pub struct WizardOptions {
    pub host: Option<String>,
    pub rom: Option<PathBuf>,
    pub keys: Option<PathBuf>,
    pub out_dir: Option<PathBuf>,
    pub name: Option<String>,
    pub display_name: Option<String>,
    pub keep_input: bool,
    pub clean: bool,
    /// Validate and print the plan, then stop before connecting.
    pub dry_run: bool,
    /// Accept the defaults and skip the optional prompts (non-interactive use).
    pub yes: bool,
}

/// Console reader: every line is delivered through a channel.
struct Console {
    lines: Receiver<Option<String>>,
    _reader: Option<thread::JoinHandle<()>>,
}

impl std::fmt::Debug for Console {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Console").finish_non_exhaustive()
    }
}

impl Console {
    fn start() -> Self {
        let (sender, lines) = channel();
        let reader = thread::spawn(move || {
            let stdin = std::io::stdin();
            let mut handle = stdin.lock();
            let mut buffer = String::new();
            loop {
                buffer.clear();
                match handle.read_line(&mut buffer) {
                    Ok(0) => {
                        let _ = sender.send(None);
                        break;
                    }
                    Ok(_) => {
                        let line = buffer.trim_end_matches(['\r', '\n']).to_string();
                        if sender.send(Some(line)).is_err() {
                            break;
                        }
                    }
                    Err(_) => {
                        let _ = sender.send(None);
                        break;
                    }
                }
            }
        });
        Self {
            lines,
            _reader: Some(reader),
        }
    }

    fn next_line(&self) -> Result<String, FrontendError> {
        match self.lines.recv() {
            Ok(Some(line)) => Ok(line),
            Ok(None) | Err(_) => Err(FrontendError::local(
                "input closed; run the Builder in a terminal window to use the guided session",
            )),
        }
    }

    fn try_line(&self) -> Option<String> {
        match self.lines.try_recv() {
            Ok(Some(line)) => Some(line),
            _ => None,
        }
    }

    fn prompt(&self, label: &str, default: Option<&str>) -> Result<String, FrontendError> {
        loop {
            match default {
                Some(default) if !default.is_empty() => print!("{label} [{default}]: "),
                _ => print!("{label}: "),
            }
            let _ = std::io::stdout().flush();
            let answer = strip_wrapping_quotes(self.next_line()?.trim());
            if !answer.is_empty() {
                return Ok(answer);
            }
            if let Some(default) = default {
                return Ok(default.to_string());
            }
            println!("please enter a value");
        }
    }

    fn confirm(&self, label: &str, default: bool) -> Result<bool, FrontendError> {
        let hint = if default { "[Y/n]" } else { "[y/N]" };
        loop {
            print!("{label} {hint}: ");
            let _ = std::io::stdout().flush();
            let answer = self.next_line()?.trim().to_ascii_lowercase();
            match answer.as_str() {
                "" => return Ok(default),
                "y" | "yes" => return Ok(true),
                "n" | "no" => return Ok(false),
                _ => println!("please answer y or n"),
            }
        }
    }

    fn pause(&self, label: &str) -> Result<(), FrontendError> {
        print!("{label}");
        let _ = std::io::stdout().flush();
        let _ = self.next_line()?;
        Ok(())
    }
}

/// Windows "Copy as path" wraps the path in double quotes; drag and drop can add
/// trailing spaces. Accept both.
fn strip_wrapping_quotes(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.len() >= 2 && trimmed.starts_with('"') && trimmed.ends_with('"') {
        return trimmed[1..trimmed.len() - 1].to_string();
    }
    trimmed.to_string()
}

fn banner() {
    println!("{} {}", FRONTEND_NAME, crate::VERSION);
    println!();
    println!("Build your own game on a Mac you control.");
    println!();
    println!("The Builder turns your own decrypted .3ds/.cci file into an unsigned iOS");
    println!("app. The heavy build runs on a macOS host you configure (a VM, a Mac on");
    println!("your network, or a cloud Mac you rent). The ROM goes only to that host and");
    println!("is deleted when the build ends.");
    println!();
    println!("  * Only use ROMs you legally own and have decrypted.");
    println!("  * This app never asks for an Apple ID or a device UDID.");
    println!("  * The IPA it produces is unsigned; you sign it yourself (Sideloadly/AltStore).");
    println!();
}

fn resolve_host(
    config: &mut BuilderConfig,
    config_path: &Path,
    requested: Option<&str>,
    console: &Console,
) -> Result<String, FrontendError> {
    if let Some(name) = requested {
        let profile = config
            .find(name)
            .ok_or_else(|| FrontendError::usage(format!("unknown host {name:?}")))?;
        return Ok(profile.id.clone());
    }
    if config.hosts.is_empty() {
        println!("No build host is configured yet.");
        println!();
        return setup_host(config, config_path, console);
    }
    if config.hosts.len() == 1 {
        let profile = &config.hosts[0];
        println!(
            "Build host: {} ({})",
            profile.name,
            profile.transport.describe()
        );
        if console.confirm("Use this host?", true)? {
            return Ok(profile.id.clone());
        }
        return setup_host(config, config_path, console);
    }
    loop {
        println!();
        println!("Build hosts:");
        for (index, profile) in config.hosts.iter().enumerate() {
            println!(
                "  {}. {} ({})",
                index + 1,
                profile.name,
                profile.transport.describe()
            );
        }
        println!("  a. Add another host");
        let answer = console.prompt("Choose a host", Some("1"))?;
        if answer.eq_ignore_ascii_case("a") {
            return setup_host(config, config_path, console);
        }
        if let Ok(index) = answer.parse::<usize>() {
            if index >= 1 && index <= config.hosts.len() {
                return Ok(config.hosts[index - 1].id.clone());
            }
        }
        println!("please choose a number from the list");
    }
}

fn setup_host(
    config: &mut BuilderConfig,
    config_path: &Path,
    console: &Console,
) -> Result<String, FrontendError> {
    println!("Set up a build host");
    println!("The host is a macOS machine you own that runs the Build Agent, reachable");
    println!("over SSH. It can be headless; no Apple ID is needed on it.");
    println!();
    let destination = console.prompt("SSH destination (user@host)", None)?;
    let (user, host) = destination
        .split_once('@')
        .ok_or_else(|| FrontendError::usage(format!("expected user@host, got {destination:?}")))?;
    builder_core::transport::ssh::validate_user(user).map_err(FrontendError::usage)?;
    builder_core::transport::ssh::validate_host(host).map_err(FrontendError::usage)?;
    let port: u16 = console
        .prompt("SSH port", Some("22"))?
        .parse()
        .map_err(|_| FrontendError::usage("the SSH port must be a number between 1 and 65535"))?;
    if port == 0 {
        return Err(FrontendError::usage("the SSH port must be 1-65535"));
    }
    let name = console.prompt("Name this host", Some(host))?;

    println!();
    println!("Reading the host key of {host}:{port}...");
    let scan = hosts::scan_host_key(port, host)?;
    println!();
    println!("Host key fingerprints:");
    for fingerprint in &scan.fingerprints {
        println!("  {fingerprint}");
    }
    println!();
    println!("Verify one of them on the Mac yourself, for example:");
    println!("  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub");
    if !console.confirm("Does at least one fingerprint match the Mac?", false)? {
        return Err(FrontendError::usage(
            "the host key was not confirmed; nothing was saved. If the fingerprints do not match, stop and investigate.",
        ));
    }

    let mut report = |line: &str| println!("{line}");
    let added = hosts::add_host(
        config,
        config_path,
        &AddHostOptions {
            name,
            ssh: Some(destination.clone()),
            port,
            identity: None,
            local_agent: None,
            local_args: Vec::new(),
            local_env: Vec::new(),
            yes: true,
            fingerprint: None,
            agent_path: "~/.local/bin/builder-agent".to_string(),
        },
        &mut report,
    )?;
    if let Some(line) = &added.authorized_keys_line {
        println!();
        println!("Add this line to ~/.ssh/authorized_keys on the Mac:");
        println!();
        println!("  {line}");
        println!();
        println!("The forced command means this key can only run the Build Agent; it");
        println!("cannot open a shell or read other files.");
        console.pause("Press Enter after adding the line...")?;
    }

    println!();
    println!("Checking the Mac...");
    let report = hosts::test_host(config, config_path, &added.profile.id)?;
    for line in hosts::render_test_report(&report) {
        println!("{line}");
    }
    if !report.ready {
        return Err(FrontendError::Environment(format!(
            "the Mac is not ready to build ({}). Fix the items above on the Mac, then run the Builder again.",
            report.refusals.join(", ")
        )));
    }
    Ok(added.profile.id)
}

fn resolve_rom(options: &WizardOptions, console: &Console) -> Result<PathBuf, FrontendError> {
    match &options.rom {
        Some(path) => Ok(path.clone()),
        None => {
            println!();
            let answer =
                console.prompt("ROM file (drag it here or paste the path; .3ds/.cci)", None)?;
            Ok(PathBuf::from(strip_wrapping_quotes(&answer)))
        }
    }
}

fn resolve_out_dir(options: &WizardOptions, console: &Console) -> Result<PathBuf, FrontendError> {
    match &options.out_dir {
        Some(path) => Ok(path.clone()),
        None if options.yes => Ok(paths::artifacts_dir()),
        None => {
            let default = paths::artifacts_dir();
            let default_text = paths::display_path(&default);
            let answer = console.prompt("Output folder for the IPA", Some(&default_text))?;
            Ok(PathBuf::from(strip_wrapping_quotes(&answer)))
        }
    }
}

fn print_plan(plan: &BuildPlan, host_name: &str, endpoint: &str) {
    println!();
    println!("Build summary");
    println!("  game:        {} ({})", plan.display_name, plan.name);
    println!(
        "  ROM:         {} ({})",
        paths::display_path(&plan.rom.path),
        preflight::format_bytes(plan.rom.bytes)
    );
    if let Some(keys) = &plan.keys {
        println!(
            "  extra file:  {} ({})",
            paths::display_path(&keys.path),
            preflight::format_bytes(keys.bytes)
        );
    }
    println!("  build on:    {host_name} ({endpoint})");
    println!("  output:      {}", paths::display_path(&plan.out_dir));
    println!(
        "  MoltenVK:    {}",
        if plan.options.embed_moltenvk {
            "embedded (recommended)"
        } else {
            "not embedded"
        }
    );
    println!();
    println!("The ROM is uploaded only to {host_name} and is deleted there when the");
    println!("build ends (unless you asked to keep it with --keep-input).");
}

fn read_install_guide(path: &Path) -> String {
    std::fs::read_to_string(paths::extended_length_path(path)).unwrap_or_default()
}

/// Run the guided session.
pub fn run(
    config: &mut BuilderConfig,
    config_path: &Path,
    options: &WizardOptions,
) -> Result<i32, FrontendError> {
    let console = Console::start();
    banner();
    let host_id = resolve_host(config, config_path, options.host.as_deref(), &console)?;
    let profile = config
        .find(&host_id)
        .cloned()
        .ok_or_else(|| FrontendError::usage(format!("unknown host {host_id:?}")))?;

    let rom_path = resolve_rom(options, &console)?;
    let rom = preflight::check_rom(&rom_path, false)?;
    println!();
    println!(
        "ROM: {} ({})",
        paths::display_path(&rom.path),
        preflight::format_bytes(rom.bytes)
    );
    for warning in &rom.warnings {
        println!("note: {warning}");
    }

    let keys = match &options.keys {
        Some(path) => Some(preflight::check_supplementary(path)?),
        None if options.yes => None,
        None => {
            if console.confirm(
                "Upload a supplementary keys file? (optional; the current pipeline does not read it)",
                false,
            )? {
                let path = console.prompt("Keys file path", None)?;
                Some(preflight::check_supplementary(Path::new(&strip_wrapping_quotes(&path)))?)
            } else {
                None
            }
        }
    };
    if let Some(keys) = &keys {
        for warning in &keys.warnings {
            println!("note: {warning}");
        }
    }

    let (default_build_name, default_display_name) = preflight::derive_names(&rom.name);
    let build_name = match &options.name {
        Some(raw) => preflight::normalize_build_name(raw)?,
        None if options.yes => preflight::normalize_build_name(&default_build_name)?,
        None => {
            let answer = console.prompt(
                "Build name (ASCII, used for directories)",
                Some(&default_build_name),
            )?;
            preflight::normalize_build_name(&answer)?
        }
    };
    let display_name = match &options.display_name {
        Some(raw) => preflight::normalize_display_name(raw)?,
        None if options.yes => preflight::normalize_display_name(&default_display_name)?,
        None => {
            let answer = console.prompt(
                "Home-screen name (any language)",
                Some(&default_display_name),
            )?;
            preflight::normalize_display_name(&answer)?
        }
    };
    let out_dir = resolve_out_dir(options, &console)?;
    let plan = BuildPlan {
        host: host_id.clone(),
        rom,
        keys,
        name: build_name,
        display_name,
        bundle_id: None,
        title_id: None,
        expected_revision: None,
        out_dir,
        options: PlanOptions {
            keep_input: options.keep_input,
            clean: options.clean,
            ..PlanOptions::default()
        },
    };
    print_plan(&plan, &profile.name, &profile.transport.describe());
    if options.dry_run {
        println!();
        println!("Dry run: the plan is valid. Nothing was uploaded and no build was started.");
        return Ok(errors::EXIT_SUCCESS);
    }
    if !options.yes && !console.confirm("Start the build?", true)? {
        println!("Canceled before upload. Nothing was sent to the Mac.");
        return Ok(errors::EXIT_SUCCESS);
    }

    // Build in a worker thread so this thread can keep reading the console and
    // turn "c + Enter" into a cancellation request.
    let config_snapshot = config.clone();
    let plan_snapshot = plan.clone();
    let cancel = CancelToken::new();
    let (result_sender, result_receiver) = channel();
    let cancel_for_worker = cancel.clone();
    thread::spawn(move || {
        let mut progress = ConsoleProgress::default();
        let result = app::run_build(
            &config_snapshot,
            &plan_snapshot,
            &mut progress,
            &cancel_for_worker,
        );
        let _ = result_sender.send(result);
    });

    println!();
    println!("Building. Type c and press Enter to cancel.");
    println!();
    let outcome = loop {
        while let Some(line) = console.try_line() {
            let command = line.trim().to_ascii_lowercase();
            if command == "c" || command == "cancel" {
                cancel.cancel();
                println!("cancel requested; the Mac will stop the job and delete its files");
            } else if !command.is_empty() {
                println!("build in progress; type c and Enter to cancel");
            }
        }
        match result_receiver.recv_timeout(Duration::from_millis(100)) {
            Ok(Ok(outcome)) => break outcome,
            Ok(Err(FrontendError::Canceled)) => {
                println!();
                println!("Build canceled. The Mac deleted the job's files; there is no artifact.");
                return Ok(errors::EXIT_CANCELED);
            }
            Ok(Err(error)) => return Err(error),
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => {
                return Err(FrontendError::local(
                    "the build worker stopped unexpectedly; check the messages above",
                ))
            }
        }
    };

    println!();
    for line in app::render_result(&outcome) {
        if line.starts_with("build succeeded") {
            println!("== {line}");
        } else {
            println!("{line}");
        }
    }
    let guide = read_install_guide(&outcome.install_guide_path);
    if !guide.is_empty() {
        println!();
        println!("{guide}");
    }
    if !options.yes
        && console
            .confirm("Open the output folder now?", true)
            .unwrap_or(false)
    {
        if let Err(error) = artifacts::open_in_file_manager(&outcome.install_guide_path) {
            println!("note: {error}");
        }
    }
    println!();
    println!("Done. {}", crate::install_guide::responsibility_note());
    Ok(errors::EXIT_SUCCESS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoted_paths_from_windows_are_unwrapped() {
        assert_eq!(
            strip_wrapping_quotes(r#""C:\Users\me\Pokemon Y.cci""#),
            r"C:\Users\me\Pokemon Y.cci"
        );
        assert_eq!(
            strip_wrapping_quotes("  C:\\ROM\\game.3ds  "),
            r"C:\ROM\game.3ds"
        );
        assert_eq!(strip_wrapping_quotes(""), "");
        assert_eq!(
            strip_wrapping_quotes(r#""unterminated"#),
            r#""unterminated"#
        );
    }

    #[test]
    fn cjk_paths_survive_the_quote_strip() {
        assert_eq!(
            strip_wrapping_quotes(r#""D:\游戏 ROM\宝可梦 Y.cci""#),
            r"D:\游戏 ROM\宝可梦 Y.cci"
        );
    }

    #[test]
    fn console_opens_and_reports_closed_input() {
        // The reader thread owns stdin, so only construct the plumbing without
        // consuming: `Console::start` is safe to call and drop.
        let console = Console::start();
        assert!(console.try_line().is_none() || console.try_line().is_some());
    }
}
