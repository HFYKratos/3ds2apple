//! `zkb doctor` and `zkb config`.

use std::path::Path;

use builder_core::client::BuilderClient;
use builder_core::config::BuilderConfig;
use builder_core::transport::ssh;
use builder_core::transport::TransportSpec;

use crate::{CliError, Printer, EXIT_HOST, EXIT_SUCCESS};

/// Local Builder checks, or the remote Agent's doctor report.
pub fn run(
    config: &BuilderConfig,
    host: Option<&str>,
    config_path: &Path,
    printer: Printer,
) -> Result<i32, CliError> {
    printer.line(format!(
        "zkb {} (protocol {})",
        env!("CARGO_PKG_VERSION"),
        builder_core::PROTOCOL
    ));
    printer.line(format!("config: {}", config_path.display()));
    printer.line(format!("hosts: {}", config.hosts.len()));
    match ssh::ssh_available() {
        Ok(()) => printer.line("ssh: available"),
        Err(message) => printer.line(format!("ssh: {message}")),
    }
    printer.line(format!(
        "config dir: {}",
        builder_core::config::default_config_dir().display()
    ));

    let Some(host) = host else {
        return Ok(EXIT_SUCCESS);
    };
    let profile = config
        .find(host)
        .cloned()
        .ok_or_else(|| CliError::usage(format!("unknown host {host:?}")))?;
    printer.line(format!(
        "host: {} ({})",
        profile.name,
        profile.transport.describe()
    ));
    let client = BuilderClient::connect(profile.transport.clone())?;
    let hello = client.hello().clone();
    printer.line(format!(
        "agent: builder-agent {} (id {}, {} {}, protocol {})",
        hello.agent.version, hello.agent.id, hello.agent.os, hello.agent.arch, hello.protocol
    ));
    printer.line(format!("toolchain: {}", hello.toolchain.summary()));
    printer.line(format!(
        "source: revision {} ({}), scripts {}",
        hello.source.revision.as_deref().unwrap_or("unknown"),
        if hello.source.dirty { "dirty" } else { "clean" },
        if hello.source.scripts_present {
            "present"
        } else {
            "missing"
        }
    ));
    printer.line(format!(
        "limits: max input {}, queue {}, builds {}",
        crate::output::format_bytes(hello.limits.max_input_bytes),
        hello.limits.max_queued_jobs,
        hello.limits.max_concurrent_builds
    ));
    if hello.ready {
        printer.line("ready: yes");
        Ok(EXIT_SUCCESS)
    } else {
        printer.line(format!("ready: no ({})", hello.refusals.join(", ")));
        Ok(EXIT_HOST)
    }
}

/// Print the configuration with secrets removed.
pub fn show_config(config: &BuilderConfig, config_path: &Path) -> Result<i32, CliError> {
    let mut redacted = config.clone();
    for host in &mut redacted.hosts {
        if let TransportSpec::Local(local) = &mut host.transport {
            for (key, value) in local.env.iter_mut() {
                let upper = key.to_ascii_uppercase();
                if upper.contains("TOKEN") || upper.contains("SECRET") || upper.contains("PASSWORD")
                {
                    *value = "<redacted>".to_string();
                }
            }
        }
    }
    println!("# {}", config_path.display());
    match toml::to_string_pretty(&redacted) {
        Ok(text) => println!("{text}"),
        Err(error) => {
            return Err(CliError::Config(format!(
                "could not render the config: {error}"
            )))
        }
    }
    Ok(EXIT_SUCCESS)
}
