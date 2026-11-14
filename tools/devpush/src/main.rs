//! devpush - 3ds2apple device bridge.
//!
//! Talks to Apple usbmuxd (USB or Wi-Fi), opens an installed app container with
//! house_arrest (VendContainer / VendDocuments) and writes/reads files over AFC,
//! and installs/uninstalls/queries apps with installation_proxy.
//!
//! Contract v1 (docs/device-bridge.md): with --json every result is NDJSON on
//! stdout with schema devpush/1 and type begin|progress|warn|done|error; exit
//! codes and error codes are stable for launchers.

mod backend;
mod error;
mod output;
mod tarstream;
mod watchdog;

use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::io::AsyncWriteExt;

use crate::backend::{Backend, ContainerKind, GetRequest, PutRequest, PutTarRequest, PutTarSource};
use crate::error::{DevpushError, ErrorCode};
use crate::output::{Out, Reporter};

const COMMANDS: &[&str] = &[
    "capabilities",
    "devices",
    "install",
    "uninstall",
    "app-attr",
    "ls",
    "stat",
    "put",
    "get",
    "put-tar",
    "tar-ok",
    "mkdir",
    "rm",
    "free",
    "tar-local",
    "tar-ok-local",
];

#[derive(Parser, Debug)]
#[command(
    name = "devpush",
    version = env!("CARGO_PKG_VERSION"),
    about = "3ds2apple device bridge: usbmuxd + house_arrest/AFC file push and IPA install",
    disable_help_subcommand = true,
    arg_required_else_help = true
)]
struct Cli {
    /// Emit NDJSON events on stdout (stable launcher contract, schema devpush/1).
    #[arg(long, global = true)]
    json: bool,
    /// Abort a transfer when no payload progress happened for N seconds (0 disables).
    #[arg(
        long,
        global = true,
        env = "DEVPUSH_STALL_SECONDS",
        default_value_t = 90
    )]
    stall_seconds: u64,
    /// Filesystem mock backend root: exercises the full CLI without a device.
    #[arg(long, global = true, env = "DEVPUSH_MOCK_DIR")]
    mock_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Print the CLI contract and backend capabilities as JSON.
    Capabilities,
    /// List connected devices (USB first).
    Devices,
    /// Install an already-signed IPA through installation_proxy.
    Install {
        #[arg(long)]
        ipa: PathBuf,
        #[arg(long)]
        bundle_id: Option<String>,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Uninstall an app (removes its container).
    Uninstall {
        #[arg(long)]
        bundle_id: String,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Query an installed app's Info.plist attributes (installation_proxy).
    AppAttr {
        #[arg(long)]
        bundle_id: String,
        /// Return a single Info.plist key instead of the scalar attribute map.
        #[arg(long)]
        key: Option<String>,
        #[arg(long)]
        udid: Option<String>,
    },
    /// List a container directory.
    Ls {
        #[arg(long)]
        bundle_id: String,
        #[arg(long, visible_alias = "remote")]
        path: String,
        #[arg(long, value_enum, default_value = "app")]
        container: ContainerKind,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Stat one container path.
    Stat {
        #[arg(long)]
        bundle_id: String,
        #[arg(long, visible_alias = "remote")]
        path: String,
        #[arg(long, value_enum, default_value = "app")]
        container: ContainerKind,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Stream one local file into the app container.
    Put {
        #[arg(long)]
        bundle_id: String,
        #[arg(long)]
        local: PathBuf,
        #[arg(long)]
        remote: String,
        #[arg(long, value_enum, default_value = "app")]
        container: ContainerKind,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Stream one container file back to the host.
    Get {
        #[arg(long)]
        bundle_id: String,
        #[arg(long)]
        remote: String,
        #[arg(long)]
        local: PathBuf,
        #[arg(long, value_enum, default_value = "app")]
        container: ContainerKind,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Stream a tar archive (prepared file or manifest+root) into the container.
    PutTar {
        #[arg(long)]
        bundle_id: String,
        /// Existing local tar file to stream as-is.
        #[arg(long)]
        tar: Option<PathBuf>,
        /// Manifest of relative paths, one per line.
        #[arg(long)]
        manifest: Option<PathBuf>,
        /// Local root that manifest entries are resolved against.
        #[arg(long)]
        root: Option<PathBuf>,
        /// Container-relative destination path for the tar file.
        #[arg(long)]
        dest: String,
        #[arg(long, value_enum, default_value = "app")]
        container: ContainerKind,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Check that a device-side tar archive is complete (512-aligned, zero tail).
    TarOk {
        #[arg(long)]
        bundle_id: String,
        #[arg(long, visible_alias = "remote")]
        path: String,
        #[arg(long, value_enum, default_value = "app")]
        container: ContainerKind,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Create a container directory (parents included).
    Mkdir {
        #[arg(long)]
        bundle_id: String,
        #[arg(long, visible_alias = "remote")]
        path: String,
        #[arg(long, value_enum, default_value = "app")]
        container: ContainerKind,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Remove a container file or directory (idempotent).
    Rm {
        #[arg(long)]
        bundle_id: String,
        #[arg(long, visible_alias = "remote")]
        path: String,
        #[arg(long, value_enum, default_value = "app")]
        container: ContainerKind,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Report free space from the app container's device info.
    Free {
        #[arg(long)]
        bundle_id: String,
        #[arg(long)]
        udid: Option<String>,
    },
    /// Host-side helper: build the same tar stream locally (no device).
    TarLocal {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },
    /// Host-side helper: completeness check for a local tar file.
    TarOkLocal {
        #[arg(long)]
        path: PathBuf,
    },
}

impl Command {
    fn name(&self) -> &'static str {
        match self {
            Self::Capabilities => "capabilities",
            Self::Devices => "devices",
            Self::Install { .. } => "install",
            Self::Uninstall { .. } => "uninstall",
            Self::AppAttr { .. } => "app-attr",
            Self::Ls { .. } => "ls",
            Self::Stat { .. } => "stat",
            Self::Put { .. } => "put",
            Self::Get { .. } => "get",
            Self::PutTar { .. } => "put-tar",
            Self::TarOk { .. } => "tar-ok",
            Self::Mkdir { .. } => "mkdir",
            Self::Rm { .. } => "rm",
            Self::Free { .. } => "free",
            Self::TarLocal { .. } => "tar-local",
            Self::TarOkLocal { .. } => "tar-ok-local",
        }
    }
}

fn to_value<T: Serialize>(value: &T) -> Result<Value, DevpushError> {
    serde_json::to_value(value)
        .map_err(|e| DevpushError::new(ErrorCode::Internal, format!("cannot encode result: {e}")))
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let cli = Cli::parse();
    let out = Out::new(cli.json);
    let command = cli.command.name();
    let exempt = matches!(
        cli.command,
        Command::Install { .. }
            | Command::Uninstall { .. }
            | Command::Capabilities
            | Command::TarLocal { .. }
            | Command::TarOkLocal { .. }
    );
    if cli.mock_dir.is_none() && !exempt {
        watchdog::arm(Duration::from_secs(cli.stall_seconds), cli.json, command);
    }
    if let Err(err) = run(cli, out).await {
        out.error(command, &err);
        std::process::exit(err.code.exit_code());
    }
}

async fn run(cli: Cli, out: Out) -> Result<(), DevpushError> {
    let json = cli.json;
    let mock_dir = cli.mock_dir.clone();
    match cli.command {
        Command::Capabilities => {
            out.begin("capabilities", json!({}));
            let backend = if mock_dir.is_some() {
                "mock"
            } else {
                "idevice"
            };
            let payload = json!({
                "version": env!("CARGO_PKG_VERSION"),
                "schema": output::SCHEMA,
                "backend": backend,
                "commands": COMMANDS,
                "features": {
                    "mock": true, "progress": true, "stallWatchdog": true, "install": true,
                    "appAttr": true, "putTar": true, "get": true, "launch": false
                },
                "stallSeconds": cli.stall_seconds
            });
            out.done(
                "capabilities",
                payload,
                &format!("devpush {} (backend: {backend})", env!("CARGO_PKG_VERSION")),
            );
            Ok(())
        }
        Command::Devices => {
            out.begin(
                "devices",
                json!({"backend": if mock_dir.is_some() { "mock" } else { "idevice" }}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            let devices = backend.devices().await?;
            let count = devices.len();
            out.done(
                "devices",
                json!({"devices": to_value(&devices)?, "count": count}),
                &format!("{count} device(s)"),
            );
            Ok(())
        }
        Command::Install {
            ipa,
            bundle_id,
            udid,
        } => {
            out.begin("install", json!({"ipa": ipa.display().to_string()}));
            let mut backend = Backend::connect(mock_dir).await?;
            let result = backend
                .install(&ipa, bundle_id.as_deref(), udid.as_deref())
                .await?;
            let human = format!("installed {} ({} bytes)", result.ipa, result.bytes);
            out.done("install", to_value(&result)?, &human);
            Ok(())
        }
        Command::Uninstall { bundle_id, udid } => {
            out.begin("uninstall", json!({"bundleId": bundle_id}));
            let mut backend = Backend::connect(mock_dir).await?;
            let result = backend.uninstall(&bundle_id, udid.as_deref()).await?;
            let human = format!("uninstalled {}", result.bundle_id);
            out.done("uninstall", to_value(&result)?, &human);
            Ok(())
        }
        Command::AppAttr {
            bundle_id,
            key,
            udid,
        } => {
            out.begin("app-attr", json!({"bundleId": bundle_id}));
            let mut backend = Backend::connect(mock_dir).await?;
            let attr = backend.app_attr(&bundle_id, udid.as_deref()).await?;
            let payload = match key {
                Some(key) => {
                    let value = attr.keys.get(&key).cloned().unwrap_or(Value::Null);
                    json!({"bundleId": bundle_id, "installed": attr.installed, "key": key, "value": value})
                }
                None => {
                    let mut payload = to_value(&attr)?;
                    payload["bundleId"] = json!(bundle_id);
                    payload
                }
            };
            let human = format!("app-attr {bundle_id}");
            out.done("app-attr", payload, &human);
            Ok(())
        }
        Command::Ls {
            bundle_id,
            path,
            container,
            udid,
        } => {
            out.begin(
                "ls",
                json!({"bundleId": bundle_id, "path": path, "container": container.as_str()}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            let entries = backend
                .ls(&bundle_id, &path, container, udid.as_deref())
                .await?;
            let count = entries.len();
            let payload = json!({
                "bundleId": bundle_id, "path": path, "container": container.as_str(),
                "entries": to_value(&entries)?, "count": count
            });
            out.done("ls", payload, &format!("{count} entries in {path}"));
            Ok(())
        }
        Command::Stat {
            bundle_id,
            path,
            container,
            udid,
        } => {
            out.begin(
                "stat",
                json!({"bundleId": bundle_id, "path": path, "container": container.as_str()}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            let stat = backend
                .stat(&bundle_id, &path, container, udid.as_deref())
                .await?;
            let human = format!(
                "{} bytes ({})",
                stat.size,
                if stat.is_dir { "directory" } else { "file" }
            );
            let mut payload = to_value(&stat)?;
            payload["bundleId"] = json!(bundle_id);
            payload["container"] = json!(container.as_str());
            out.done("stat", payload, &human);
            Ok(())
        }
        Command::Put {
            bundle_id,
            local,
            remote,
            container,
            udid,
        } => {
            out.begin(
                "put",
                json!({"bundleId": bundle_id, "local": local.display().to_string(), "remote": remote, "container": container.as_str()}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            let request = PutRequest {
                bundle_id,
                container,
                local,
                remote,
                udid,
            };
            let mut reporter = Reporter::new("put", json);
            let result = backend.put(&request, &mut reporter).await?;
            let human = format!("put {} bytes -> {}", result.bytes, result.remote_path);
            out.done("put", to_value(&result)?, &human);
            Ok(())
        }
        Command::Get {
            bundle_id,
            remote,
            local,
            container,
            udid,
        } => {
            out.begin(
                "get",
                json!({"bundleId": bundle_id, "remote": remote, "local": local.display().to_string(), "container": container.as_str()}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            let request = GetRequest {
                bundle_id,
                container,
                remote,
                local,
                udid,
            };
            let mut reporter = Reporter::new("get", json);
            let result = backend.get(&request, &mut reporter).await?;
            let human = format!("get {} bytes -> {}", result.bytes, result.local_path);
            out.done("get", to_value(&result)?, &human);
            Ok(())
        }
        Command::PutTar {
            bundle_id,
            tar,
            manifest,
            root,
            dest,
            container,
            udid,
        } => {
            let source =
                match (tar, manifest, root) {
                    (Some(tar), None, None) => PutTarSource::TarFile(tar),
                    (None, Some(list), Some(root)) => PutTarSource::Manifest { list, root },
                    _ => return Err(DevpushError::usage(
                        "put-tar needs either --tar <local.tar> or --manifest <list> --root <dir>",
                    )),
                };
            let source_kind = match &source {
                PutTarSource::TarFile(_) => "tar",
                PutTarSource::Manifest { .. } => "manifest",
            };
            out.begin(
                "put-tar",
                json!({"bundleId": bundle_id, "dest": dest, "container": container.as_str(), "source": source_kind}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            let request = PutTarRequest {
                bundle_id,
                container,
                dest,
                source,
                udid,
            };
            let mut reporter = Reporter::new("put-tar", json);
            let result = backend.put_tar(&request, &mut reporter).await?;
            if !result.tar_ok {
                out.warn(
                    "put-tar",
                    "archive_incomplete",
                    "tar stream is not 512-aligned with a zero tail; the app will reject it",
                );
            }
            let human = format!(
                "put-tar {} bytes -> {} (tarOk: {})",
                result.bytes, result.dest, result.tar_ok
            );
            out.done("put-tar", to_value(&result)?, &human);
            Ok(())
        }
        Command::TarOk {
            bundle_id,
            path,
            container,
            udid,
        } => {
            out.begin(
                "tar-ok",
                json!({"bundleId": bundle_id, "path": path, "container": container.as_str()}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            let ok = backend
                .tar_ok(&bundle_id, &path, container, udid.as_deref())
                .await?;
            out.done(
                "tar-ok",
                json!({"bundleId": bundle_id, "path": path, "ok": ok}),
                &format!("tar-ok {path}: {ok}"),
            );
            Ok(())
        }
        Command::Mkdir {
            bundle_id,
            path,
            container,
            udid,
        } => {
            out.begin(
                "mkdir",
                json!({"bundleId": bundle_id, "path": path, "container": container.as_str()}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            backend
                .mkdir(&bundle_id, &path, container, udid.as_deref())
                .await?;
            out.done(
                "mkdir",
                json!({"bundleId": bundle_id, "path": path, "container": container.as_str(), "created": true}),
                &format!("mkdir {path}"),
            );
            Ok(())
        }
        Command::Rm {
            bundle_id,
            path,
            container,
            udid,
        } => {
            out.begin(
                "rm",
                json!({"bundleId": bundle_id, "path": path, "container": container.as_str()}),
            );
            let mut backend = Backend::connect(mock_dir).await?;
            let removed = backend
                .rm(&bundle_id, &path, container, udid.as_deref())
                .await?;
            out.done(
                "rm",
                json!({"bundleId": bundle_id, "path": path, "container": container.as_str(), "removed": removed}),
                &format!("rm {path} (removed: {removed})"),
            );
            Ok(())
        }
        Command::Free { bundle_id, udid } => {
            out.begin("free", json!({"bundleId": bundle_id}));
            let mut backend = Backend::connect(mock_dir).await?;
            let result = backend.free(&bundle_id, udid.as_deref()).await?;
            let human = format!("{} bytes free", result.free_bytes);
            out.done("free", to_value(&result)?, &human);
            Ok(())
        }
        Command::TarLocal {
            manifest,
            root,
            output,
        } => {
            out.begin(
                "tar-local",
                json!({"manifest": manifest.display().to_string(), "root": root.display().to_string(), "output": output.display().to_string()}),
            );
            let entries = tarstream::read_manifest(&manifest, &root)?;
            if let Some(parent) = output.parent() {
                if !parent.as_os_str().is_empty() {
                    tokio::fs::create_dir_all(parent).await.map_err(|e| {
                        DevpushError::io(format!("cannot create {}: {e}", parent.display()))
                    })?;
                }
            }
            let mut file = tokio::fs::File::create(&output).await.map_err(|e| {
                DevpushError::io(format!("cannot create {}: {e}", output.display()))
            })?;
            let mut reporter = Reporter::new("tar-local", json);
            reporter.set_total(None);
            let stats = tarstream::write_tar(&mut file, &entries, &mut reporter).await?;
            file.flush()
                .await
                .map_err(|e| DevpushError::io(format!("cannot flush {}: {e}", output.display())))?;
            reporter.finish();
            let mut check = tokio::fs::File::open(&output).await.map_err(|e| {
                DevpushError::io(format!("cannot reopen {}: {e}", output.display()))
            })?;
            let tar_ok = tarstream::tar_ok_reader(&mut check).await?;
            let payload = json!({
                "output": output.display().to_string(),
                "bytes": stats.archive_bytes,
                "payloadBytes": stats.payload_bytes,
                "entries": stats.entries,
                "tarOk": tar_ok
            });
            out.done(
                "tar-local",
                payload,
                &format!(
                    "tar-local {} bytes -> {} (tarOk: {tar_ok})",
                    stats.archive_bytes,
                    output.display()
                ),
            );
            Ok(())
        }
        Command::TarOkLocal { path } => {
            out.begin("tar-ok-local", json!({"path": path.display().to_string()}));
            let mut file = tokio::fs::File::open(&path)
                .await
                .map_err(|e| DevpushError::io(format!("cannot open {}: {e}", path.display())))?;
            let ok = tarstream::tar_ok_reader(&mut file).await?;
            out.done(
                "tar-ok-local",
                json!({"path": path.display().to_string(), "ok": ok}),
                &format!("tar-ok-local {}: {ok}", path.display()),
            );
            Ok(())
        }
    }
}
