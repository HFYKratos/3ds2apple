//! `builder-agent` command line.

use std::path::PathBuf;

use clap::{Parser, Subcommand};

use crate::config::{self, AgentConfig};
use crate::store::DataRoot;

#[derive(Debug, Parser)]
#[command(
    name = "builder-agent",
    version,
    about = "Build Agent for the 3ds2apple Builder (macOS host, headless)"
)]
struct Cli {
    /// Agent data root. Defaults to the platform data directory or
    /// $BUILDER_AGENT_DATA_ROOT.
    #[arg(long, global = true)]
    data_root: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Create the Agent configuration and data root, then print the setup line.
    Init {
        /// Path of the 3ds2apple checkout the build scripts run in.
        #[arg(long)]
        checkout: Option<PathBuf>,
        /// Run the scripted fake build instead of the real pipeline (tests).
        #[arg(long)]
        fake_build: bool,
        /// Fake build plan: success, fail-recompiling, fail-packaging, slow,
        /// corrupt-artifact.
        #[arg(long, default_value = "success")]
        fake_plan: String,
        /// Stable Agent id reported in the handshake.
        #[arg(long)]
        agent_id: Option<String>,
        #[arg(long)]
        max_queued_jobs: Option<u32>,
        #[arg(long)]
        max_concurrent_builds: Option<u32>,
        #[arg(long)]
        max_input_bytes: Option<u64>,
        /// MoltenVK framework passed to the packaging script.
        #[arg(long)]
        moltenvk_framework: Option<PathBuf>,
        /// Allow a checkout whose git revision is dirty.
        #[arg(long)]
        allow_dirty: bool,
        /// Allow source revision mismatches.
        #[arg(long)]
        allow_source_mismatch: bool,
        /// Print only the generated authorized_keys line to stdout.
        #[arg(long)]
        print_auth_line: bool,
    },
    /// Run the Agent: the Unix-socket daemon (default) or one stdio session.
    Serve {
        /// Listen on this Unix socket (default: <data root>/agent.sock).
        #[arg(long)]
        socket: Option<PathBuf>,
        /// Serve one control session on stdin/stdout instead of listening.
        #[arg(long)]
        stdio: bool,
        /// Override the configured checkout.
        #[arg(long)]
        checkout: Option<PathBuf>,
        /// Force fake build mode.
        #[arg(long)]
        fake_build: bool,
        /// Override the fake build plan.
        #[arg(long)]
        fake_plan: Option<String>,
    },
    /// Forced-command entry point used by the SSH authorized_keys line.
    SshDispatch {
        /// Fail instead of starting the daemon when it is not running.
        #[arg(long)]
        no_spawn: bool,
    },
    /// Print the environment/toolchain report used by `zkb host test`.
    Doctor {
        /// Machine-readable JSON report.
        #[arg(long)]
        json: bool,
    },
    /// Generate the token for the optional HTTP binding.
    Pair,
    /// Delete job data according to the retention policy.
    Gc {
        /// Delete every job, not only expired ones.
        #[arg(long)]
        all: bool,
        /// Required together with --all.
        #[arg(long)]
        yes: bool,
    },
}

/// Parse arguments and run. Returns the process exit code.
pub fn run() -> i32 {
    let cli = Cli::parse();
    let data = DataRoot::discover(cli.data_root.clone());
    match cli.command {
        Command::Init {
            checkout,
            fake_build,
            fake_plan,
            agent_id,
            max_queued_jobs,
            max_concurrent_builds,
            max_input_bytes,
            moltenvk_framework,
            allow_dirty,
            allow_source_mismatch,
            print_auth_line,
        } => init(
            &data,
            checkout,
            fake_build,
            fake_plan,
            agent_id,
            max_queued_jobs,
            max_concurrent_builds,
            max_input_bytes,
            moltenvk_framework,
            allow_dirty,
            allow_source_mismatch,
            print_auth_line,
        ),
        Command::Serve {
            socket,
            stdio,
            checkout,
            fake_build,
            fake_plan,
        } => serve(&data, socket, stdio, checkout, fake_build, fake_plan),
        Command::SshDispatch { no_spawn } => crate::ssh_dispatch::run(&data, no_spawn),
        Command::Doctor { json } => doctor(&data, json),
        Command::Pair => pair(&data),
        Command::Gc { all, yes } => gc(&data, all, yes),
    }
}

#[allow(clippy::too_many_arguments)]
fn init(
    data: &DataRoot,
    checkout: Option<PathBuf>,
    fake_build: bool,
    fake_plan: String,
    agent_id: Option<String>,
    max_queued_jobs: Option<u32>,
    max_concurrent_builds: Option<u32>,
    max_input_bytes: Option<u64>,
    moltenvk_framework: Option<PathBuf>,
    allow_dirty: bool,
    allow_source_mismatch: bool,
    print_auth_line: bool,
) -> i32 {
    let mut cfg = match config::load(&data.root) {
        Ok(cfg) => cfg,
        Err(message) => {
            eprintln!("builder-agent: {message}");
            return 2;
        }
    };
    if let Some(checkout) = checkout {
        cfg.checkout = Some(checkout);
    }
    if fake_build {
        cfg.fake_build = true;
    }
    cfg.fake_plan = fake_plan;
    if let Some(agent_id) = agent_id {
        cfg.agent_id = crate::util::sanitize_id(&agent_id, "build-agent");
    }
    if let Some(max_queued_jobs) = max_queued_jobs {
        cfg.max_queued_jobs = max_queued_jobs;
    }
    if let Some(max_concurrent_builds) = max_concurrent_builds {
        cfg.max_concurrent_builds = max_concurrent_builds;
    }
    if let Some(max_input_bytes) = max_input_bytes {
        cfg.max_input_bytes = max_input_bytes;
    }
    if moltenvk_framework.is_some() {
        cfg.moltenvk_framework = moltenvk_framework;
    }
    if allow_dirty {
        cfg.allow_dirty = true;
    }
    if allow_source_mismatch {
        cfg.allow_source_mismatch = true;
    }
    if cfg.agent_id.is_empty() {
        cfg.agent_id = crate::util::hostname();
    }
    if let Err(message) = cfg.validate() {
        eprintln!("builder-agent: invalid configuration: {message}");
        return 2;
    }
    if let Err(message) = config::save(&data.root, &cfg) {
        eprintln!("builder-agent: {message}");
        return 2;
    }
    if print_auth_line {
        println!("{}", authorized_keys_hint(&cfg));
        return 0;
    }
    println!("Agent configured.");
    println!("  data root: {}", data.root.display());
    println!("  agent id:  {}", cfg.agent_id);
    println!(
        "  checkout:  {}",
        cfg.checkout
            .as_ref()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "(none: fake build only)".to_string())
    );
    println!(
        "  build:     {}",
        if cfg.fake_build {
            "fake (tests only)"
        } else {
            "real"
        }
    );
    println!();
    println!("On the Mac, start the Agent (or let ssh-dispatch auto-start it):");
    println!("  builder-agent serve");
    println!();
    println!("Then add this line to ~/.ssh/authorized_keys for your SSH key:");
    println!("  {}", authorized_keys_hint(&cfg));
    0
}

fn authorized_keys_hint(cfg: &AgentConfig) -> String {
    let executable = std::env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "builder-agent".to_string());
    format!(
        "command=\"{executable} ssh-dispatch\",restrict <your-build-key.pub> 3ds2apple-builder {}",
        cfg.agent_id
    )
}

fn serve(
    data: &DataRoot,
    socket: Option<PathBuf>,
    stdio: bool,
    checkout: Option<PathBuf>,
    fake_build: bool,
    fake_plan: Option<String>,
) -> i32 {
    let mut cfg = match config::load(&data.root) {
        Ok(cfg) => cfg,
        Err(message) => {
            eprintln!("builder-agent: {message}");
            return 2;
        }
    };
    if let Some(checkout) = checkout {
        cfg.checkout = Some(checkout);
    }
    if fake_build {
        cfg.fake_build = true;
    }
    if let Some(fake_plan) = fake_plan {
        cfg.fake_plan = fake_plan;
    }
    if let Err(message) = cfg.validate() {
        eprintln!("builder-agent: invalid configuration: {message}");
        return 2;
    }
    let service = match crate::service::Service::open(cfg, data.clone()) {
        Ok(service) => service,
        Err(message) => {
            eprintln!("builder-agent: {message}");
            return 1;
        }
    };
    service.start_worker();
    if stdio {
        let code = match crate::server::run_session(
            &service,
            Box::new(std::io::stdin()),
            Box::new(std::io::stdout()),
        ) {
            Ok(()) => 0,
            Err(error) => {
                eprintln!("builder-agent: session failed: {error}");
                1
            }
        };
        service.interrupt_active_jobs();
        return code;
    }
    let socket = socket.unwrap_or_else(|| data.socket_path());
    match crate::server::run_daemon(service, &socket) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("builder-agent: {error}");
            1
        }
    }
}

fn doctor(data: &DataRoot, json: bool) -> i32 {
    let cfg = match config::load(&data.root) {
        Ok(cfg) => cfg,
        Err(message) => {
            eprintln!("builder-agent: {message}");
            return 2;
        }
    };
    if let Err(error) = data.ensure_layout() {
        eprintln!("builder-agent: could not create the data root: {error}");
        return 2;
    }
    let report = crate::doctor::gather(&cfg, data);
    if json {
        match serde_json::to_string_pretty(&report) {
            Ok(text) => println!("{text}"),
            Err(error) => {
                eprintln!("builder-agent: could not serialise the report: {error}");
                return 64;
            }
        }
    } else {
        println!(
            "builder-agent {} (protocol {})",
            report.agent_version, report.protocol
        );
        println!(
            "os: {} {} · user: {} · root: {}",
            report.os,
            report.arch,
            report.user.as_deref().unwrap_or("unknown"),
            report.is_root
        );
        println!("data root: {}", report.data_root);
        println!(
            "checkout: {}",
            report.checkout.as_deref().unwrap_or("(not configured)")
        );
        println!(
            "source: revision {} ({}) · scripts {}",
            report.source.revision.as_deref().unwrap_or("unknown"),
            if report.source.dirty {
                "dirty"
            } else {
                "clean"
            },
            if report.source.scripts_present {
                "present"
            } else {
                "missing"
            }
        );
        println!("toolchain: {}", report.toolchain.summary());
        println!(
            "disk: {} free (need {})",
            report
                .disk_free_bytes
                .map(crate::util::human_bytes)
                .unwrap_or_else(|| "unknown".to_string()),
            crate::util::human_bytes(report.disk_required_bytes)
        );
        for note in &report.notes {
            println!("note: {note}");
        }
        if report.ready {
            println!("ready: yes");
        } else {
            println!("ready: no ({})", report.refusals.join(", "));
        }
    }
    if report.ready {
        0
    } else {
        3
    }
}

fn pair(data: &DataRoot) -> i32 {
    let mut cfg = match config::load(&data.root) {
        Ok(cfg) => cfg,
        Err(message) => {
            eprintln!("builder-agent: {message}");
            return 2;
        }
    };
    let token = crate::util::new_token();
    let hash = builder_core::hash::sha256_hex(token.as_bytes());
    cfg.token_sha256 = Some(hash);
    if let Err(message) = config::save(&data.root, &cfg) {
        eprintln!("builder-agent: {message}");
        return 2;
    }
    println!(
        "3ds2apple-builder://pair?host={}&port={}&token={}",
        crate::util::hostname(),
        builder_core::DEFAULT_AGENT_HTTP_PORT,
        token
    );
    println!("This token is printed once; the Agent stores only its SHA256.");
    println!(
        "HTTP/SSE pairing is not enabled in this build; use SSH host setup (`zkb host add --ssh`)."
    );
    0
}

fn gc(data: &DataRoot, all: bool, yes: bool) -> i32 {
    if all && !yes {
        eprintln!("builder-agent: --all deletes every job; pass --yes to confirm");
        return 2;
    }
    let cfg = match config::load(&data.root) {
        Ok(cfg) => cfg,
        Err(message) => {
            eprintln!("builder-agent: {message}");
            return 2;
        }
    };
    match crate::cleanup::gc(data, &cfg, all) {
        Ok(report) => {
            if report.removed_jobs.is_empty() && report.removed_staging_files == 0 {
                println!("nothing to delete");
            } else {
                for job_id in &report.removed_jobs {
                    println!("deleted job {job_id}");
                }
                if report.removed_staging_files > 0 {
                    println!(
                        "deleted {} abandoned staging files",
                        report.removed_staging_files
                    );
                }
                println!("freed {}", crate::util::human_bytes(report.removed_bytes));
            }
            for warning in &report.warnings {
                eprintln!("warning: {warning}");
            }
            0
        }
        Err(message) => {
            eprintln!("builder-agent: gc failed: {message}");
            1
        }
    }
}
