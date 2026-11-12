//! Command-line interface of the Linux Builder frontend.
//!
//! `build`, `vm` and `install-guide` are the Linux-specific commands; `zkb` is
//! a transparent passthrough to the shared client for anything not wrapped
//! here. All commands are non-interactive when `--no-input` is set or stdin is
//! not a terminal.

use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::{Args, Parser, Subcommand};

use crate::error::{Error, EXIT_SUCCESS};
use crate::output::Printer;
use crate::zkb::{self, Zkb};
use crate::{build, doctor, host_setup, install, overview, paths, vm};

/// Build your own 3ds2apple IPA on a macOS VM or Mac you control.
#[derive(Debug, Parser)]
#[command(
    name = "3ds2apple-builder",
    version,
    about = "Linux Builder frontend: build your own ROM into an unsigned IPA on a macOS host",
    long_about = "3ds2apple-builder is the Linux frontend for the 3ds2apple Builder. It pairs a \
                  macOS host you control (a local VM, a Mac on the LAN or a cloud Mac) over SSH, \
                  uploads one decrypted ROM you own, streams the AOT build, then downloads and \
                  verifies the unsigned IPA and prints the signing/installation steps.\n\n\
                  It never signs, installs or distributes anything, never asks for an Apple ID, \
                  and never contacts a project-operated server. The ROM goes only to the macOS \
                  host you configure and is deleted there when the build ends.",
    arg_required_else_help = false
)]
pub struct Cli {
    /// Path of the shared `zkb` client (default: $ZKB_BIN, next to this binary, or $PATH).
    #[arg(long, global = true, value_name = "PATH")]
    pub zkb: Option<PathBuf>,
    /// Builder config file (default: the shared client's config location).
    #[arg(long, global = true, value_name = "PATH")]
    pub config: Option<PathBuf>,
    /// Machine-readable output: JSON for this frontend's commands, NDJSON from the shared client.
    #[arg(long, global = true)]
    pub json: bool,
    /// Never prompt; choices that would need an answer are usage errors.
    #[arg(long, global = true)]
    pub no_input: bool,
    #[command(subcommand)]
    pub command: Option<Command>,
}

/// Commands implemented by the Linux frontend.
#[derive(Debug, Subcommand)]
pub enum Command {
    /// Show this machine's Builder status and the next steps (the default).
    Status,
    /// Find and pair a macOS VM or Mac.
    Vm(VmArgs),
    /// Build one ROM into an unsigned IPA and verify the download.
    Build(BuildArgs),
    /// Check the local setup and, optionally, the macOS host.
    Doctor(DoctorArgs),
    /// Print the signing/installation instructions for an IPA.
    InstallGuide(InstallGuideArgs),
    /// Run the shared `zkb` client with the given arguments (advanced).
    Zkb(ZkbArgs),
}

/// `vm` subcommands.
#[derive(Debug, Args)]
pub struct VmArgs {
    #[command(subcommand)]
    pub command: VmCommand,
}

/// Discover or pair a macOS VM/Mac.
#[derive(Debug, Subcommand)]
pub enum VmCommand {
    /// List SSH endpoints found in the environment, QEMU/KVM forwards and localhost ports.
    Discover(DiscoverArgs),
    /// Verify the host key and pair a macOS VM/Mac through the shared client.
    Setup(SetupArgs),
}

/// `vm discover` options.
#[derive(Debug, Args)]
pub struct DiscoverArgs {
    /// Also probe the default localhost port range.
    #[arg(long)]
    pub scan: bool,
    /// Ports to probe with --scan (comma-separated, ranges allowed: 2222,2200-2205).
    #[arg(long, value_name = "PORTS")]
    pub ports: Option<String>,
    /// Do not connect to the candidates (show what was found only).
    #[arg(long)]
    pub no_probe: bool,
    /// Per-connection timeout in milliseconds.
    #[arg(long, default_value_t = 700)]
    pub timeout_ms: u64,
}

/// `vm setup` options.
#[derive(Debug, Args)]
pub struct SetupArgs {
    /// Name for this host (stored by the shared client, also used for --host).
    #[arg(long)]
    pub name: String,
    /// VM/Mac host name or IP (combined with --port for an explicit endpoint).
    #[arg(long)]
    pub host: Option<String>,
    /// SSH port (combined with --host).
    #[arg(long)]
    pub port: Option<u16>,
    /// SSH login user on the Mac (default: $ZKB_VM_USER, $USER, then "builder").
    #[arg(long)]
    pub user: Option<String>,
    /// Use an existing SSH private key instead of creating a dedicated one.
    #[arg(long, value_name = "PATH")]
    pub key: Option<PathBuf>,
    /// Path of `builder-agent` on the Mac (shown in the authorized_keys line).
    #[arg(long, default_value = host_setup::DEFAULT_AGENT_PATH)]
    pub agent_path: String,
    /// Trust the shown host key without an interactive confirmation.
    #[arg(long)]
    pub yes: bool,
    /// Pin the host key by its SHA256 fingerprint instead of --yes.
    #[arg(long, value_name = "SHA256:...")]
    pub fingerprint: Option<String>,
    /// Run the host self-test right after pairing.
    #[arg(long)]
    pub test: bool,
    /// Ports probed during discovery (comma-separated, ranges allowed).
    #[arg(long, value_name = "PORTS")]
    pub ports: Option<String>,
    /// Per-connection timeout in milliseconds.
    #[arg(long, default_value_t = 700)]
    pub timeout_ms: u64,
}

/// `build` options (the shared client's flags plus local ROM discovery).
#[derive(Debug, Args)]
pub struct BuildArgs {
    /// Host name or id (default: the only configured host).
    #[arg(long)]
    pub host: Option<String>,
    /// Decrypted ROM (.3ds or .cci); prompted for when omitted in a terminal.
    #[arg(long, value_name = "PATH")]
    pub rom: Option<PathBuf>,
    /// Extra directory to look for ROMs in (repeatable).
    #[arg(long = "rom-dir", value_name = "DIR")]
    pub rom_dirs: Vec<PathBuf>,
    /// Build name (slug; default: derived from the ROM file name).
    #[arg(long)]
    pub name: Option<String>,
    /// Home-screen display name (default: the ROM file name).
    #[arg(long)]
    pub display_name: Option<String>,
    /// Bundle identifier override (advanced).
    #[arg(long)]
    pub bundle_id: Option<String>,
    /// 16-hex title id (advanced; detected by the build otherwise).
    #[arg(long)]
    pub title_id: Option<String>,
    /// Directory for the downloaded IPA (default: the Builder artifacts directory).
    #[arg(long, value_name = "DIR")]
    pub out: Option<PathBuf>,
    /// Do not embed the MoltenVK framework.
    #[arg(long)]
    pub no_moltenvk: bool,
    /// Build with the hardware-renderer environment enabled.
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

/// `doctor` options.
#[derive(Debug, Args)]
pub struct DoctorArgs {
    /// Also run the remote `zkb host test` for this host.
    #[arg(long)]
    pub host: Option<String>,
    /// Probe QEMU forwards and scan localhost ports.
    #[arg(long)]
    pub probe: bool,
    /// Ports probed with --probe (comma-separated, ranges allowed).
    #[arg(long, value_name = "PORTS")]
    pub ports: Option<String>,
    /// Per-connection timeout in milliseconds.
    #[arg(long, default_value_t = 700)]
    pub timeout_ms: u64,
}

/// `install-guide` options.
#[derive(Debug, Args)]
pub struct InstallGuideArgs {
    /// Downloaded IPA; when given, its size and SHA256 fill in the guide.
    #[arg(long, value_name = "PATH")]
    pub ipa: Option<PathBuf>,
}

/// Arguments passed verbatim to the shared client.
#[derive(Debug, Args)]
pub struct ZkbArgs {
    /// Arguments for `zkb` (for example: host list).
    #[arg(
        trailing_var_arg = true,
        allow_hyphen_values = true,
        value_name = "ARGS"
    )]
    pub args: Vec<String>,
}

/// Parse-independent entry point: run the CLI and return the process exit code.
pub fn run(cli: Cli) -> i32 {
    let printer = Printer::new(cli.json);
    match execute(&cli, printer) {
        Ok(code) => code,
        Err(error) => {
            report(&error);
            error.exit_code()
        }
    }
}

fn report(error: &Error) {
    match error {
        Error::Forwarded(_) => {
            // The shared client already printed the diagnosis; add only the
            // next action when there is one.
            if let Some(hint) = error.hint() {
                eprintln!("hint: {hint}");
            }
        }
        _ => {
            eprintln!("3ds2apple-builder: {error}");
            if let Some(hint) = error.hint() {
                eprintln!("hint: {hint}");
            }
        }
    }
}

fn execute(cli: &Cli, printer: Printer) -> Result<i32, Error> {
    let current_exe = std::env::current_exe()
        .map_err(|error| Error::local(format!("cannot determine this executable: {error}")))?;
    let config_path = paths::config_path(cli.config.as_deref());
    let env_get = |key: &str| std::env::var(key).ok();
    let interactive = !cli.no_input && build::stdin_is_terminal();

    match &cli.command {
        None | Some(Command::Status) => overview::run(
            &config_path,
            cli.zkb.as_deref(),
            &current_exe,
            env_get,
            printer,
        ),
        Some(Command::Vm(args)) => match &args.command {
            VmCommand::Discover(discover) => {
                let options = vm::DiscoverOptions {
                    scan_ports: discover.scan,
                    probe: !discover.no_probe,
                    ports: resolve_ports(discover.ports.as_deref())?,
                    timeout: Duration::from_millis(discover.timeout_ms),
                };
                let discovery = vm::discover(&options, env_get, Path::new("/proc"));
                if printer.json {
                    printer.json(&discovery);
                } else {
                    vm::print_discovery(&discovery, printer);
                }
                Ok(EXIT_SUCCESS)
            }
            VmCommand::Setup(setup) => {
                let zkb = require_zkb(cli, &current_exe)?;
                let options = host_setup::SetupOptions {
                    name: setup.name.clone(),
                    host: setup.host.clone(),
                    port: setup.port,
                    user: setup.user.clone(),
                    key: setup.key.clone(),
                    agent_path: setup.agent_path.clone(),
                    yes: setup.yes,
                    fingerprint: setup.fingerprint.clone(),
                    test: setup.test,
                    ports: resolve_ports(setup.ports.as_deref())?,
                    timeout_ms: setup.timeout_ms,
                };
                host_setup::setup(&options, &config_path, env_get, &zkb, printer, interactive)
            }
        },
        Some(Command::Build(args)) => {
            let zkb = require_zkb(cli, &current_exe)?;
            let options = build::BuildOptions {
                host: args.host.clone(),
                rom: args.rom.clone(),
                rom_dirs: args.rom_dirs.clone(),
                name: args.name.clone(),
                display_name: args.display_name.clone(),
                bundle_id: args.bundle_id.clone(),
                title_id: args.title_id.clone(),
                out: args.out.clone(),
                no_moltenvk: args.no_moltenvk,
                hardware_renderer: args.hardware_renderer,
                clean: args.clean,
                keep_input: args.keep_input,
                expected_revision: args.expected_revision.clone(),
                no_download: args.no_download,
                allow_any_file: args.allow_any_file,
            };
            build::build(&options, &config_path, env_get, &zkb, printer, interactive)
        }
        Some(Command::Doctor(args)) => {
            let options = doctor::DoctorOptions {
                host: args.host.clone(),
                probe: args.probe,
                ports: resolve_ports(args.ports.as_deref())?,
                timeout_ms: args.timeout_ms,
            };
            doctor::run(
                &options,
                &config_path,
                cli.zkb.as_deref(),
                &current_exe,
                env_get,
                printer,
            )
        }
        Some(Command::InstallGuide(args)) => {
            let ipa = match &args.ipa {
                Some(path) => Some(install::inspect_ipa(path)?),
                None => None,
            };
            if printer.json {
                if let Some(ipa) = &ipa {
                    printer.json(ipa);
                }
            } else {
                install::print_guide(ipa.as_ref(), printer);
            }
            Ok(EXIT_SUCCESS)
        }
        Some(Command::Zkb(args)) => {
            if args.args.is_empty() {
                return Err(Error::usage(
                    "pass the shared client arguments, for example: \
                     `3ds2apple-builder zkb host list`",
                ));
            }
            let zkb = require_zkb(cli, &current_exe)?;
            let args = zkb::with_globals(cli.config.as_deref(), cli.json, args.args.clone());
            let code = zkb.run_inherit(&args)?;
            if code != 0 {
                return Err(Error::Forwarded(code));
            }
            Ok(EXIT_SUCCESS)
        }
    }
}

fn require_zkb(cli: &Cli, current_exe: &Path) -> Result<Zkb, Error> {
    Zkb::locate(
        cli.zkb.as_deref(),
        std::env::var_os(zkb::ENV_ZKB_BIN),
        current_exe,
    )
}

fn resolve_ports(value: Option<&str>) -> Result<Vec<u16>, Error> {
    match value {
        Some(value) => vm::parse_ports(value).map_err(Error::usage),
        None => Ok(vm::default_local_ports()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn cli_definition_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn ports_are_optional_and_validated() {
        assert_eq!(
            resolve_ports(None).unwrap().len(),
            vm::default_local_ports().len()
        );
        assert_eq!(resolve_ports(Some("2222")).unwrap(), vec![2222]);
        assert!(resolve_ports(Some("nope")).is_err());
    }

    #[test]
    fn forwarded_errors_keep_their_code() {
        assert_eq!(Error::Forwarded(3).exit_code(), 3);
        assert_eq!(Error::Forwarded(1).exit_code(), 1);
    }
}
