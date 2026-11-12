//! SSH forced-command entry point.
//!
//! `authorized_keys` runs `builder-agent ssh-dispatch`; sshd puts the requested
//! command line in `SSH_ORIGINAL_COMMAND`. Only these subcommands are allowed:
//!
//! ```text
//! stdio
//! doctor --json
//! upload --job <id> --role <rom|keys> --bytes <n> --sha256 <hex> [--offset <n>]
//! upload-status --job <id> --role <rom|keys>
//! download-artifact --job <id> --what ipa|manifest-txt [--offset <n>]
//! ```
//!
//! Arguments are parsed strictly as `--flag value` pairs with a fixed allowlist;
//! no shell is involved on either side and unknown input is rejected.

use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::frames::error_frame;
use builder_core::protocol::model::ErrorInfo;
use builder_core::protocol::normalize_sha256;
use builder_core::transport::ssh::validate_remote_command;

use crate::config;
use crate::downloads::{self, ArtifactWhat};
use crate::store::DataRoot;
use crate::uploads::{self, UploadArgs};
use crate::util;

const SPAWN_WAIT: Duration = Duration::from_secs(20);

/// Run the dispatch entry point. Returns a process exit code.
pub fn run(data_root: &DataRoot, no_spawn: bool) -> i32 {
    let original = std::env::var("SSH_ORIGINAL_COMMAND").unwrap_or_default();
    let command_line = original.trim().to_string();
    if command_line.is_empty() {
        return usage_error(
            "SSH_ORIGINAL_COMMAND is empty; this binary must be the forced command of the SSH key",
        );
    }
    if let Err(message) = validate_remote_command(&command_line) {
        return usage_error(&message);
    }
    let tokens: Vec<&str> = command_line.split_whitespace().collect();
    let (subcommand, rest) = (tokens[0], &tokens[1..]);
    match subcommand {
        "stdio" => proxy_stdio(data_root, no_spawn),
        "doctor" => doctor_command(data_root, rest),
        "upload" => upload_command(data_root, rest),
        "upload-status" => status_command(data_root, rest),
        "download-artifact" => download_command(data_root, rest),
        _ => usage_error("unknown Agent subcommand"),
    }
}

fn usage_error(message: &str) -> i32 {
    print_error_frame(ErrorInfo::new(ErrorCode::BadRequest, message.to_string()));
    2
}

fn print_error_frame(error: ErrorInfo) {
    if let Ok(frame) = error_frame("", error) {
        if let Ok(line) = frame.to_line() {
            let mut stdout = io::stdout().lock();
            let _ = stdout.write_all(line.as_bytes());
            let _ = stdout.write_all(b"\n");
            let _ = stdout.flush();
        }
    }
}

/// Parse `--flag value` pairs against an allowlist.
fn parse_flags(args: &[&str], allowed: &[&str]) -> Result<BTreeMap<String, String>, String> {
    let mut values = BTreeMap::new();
    let mut index = 0;
    while index < args.len() {
        let argument = args[index];
        let Some(flag) = argument.strip_prefix("--") else {
            return Err(format!("unexpected argument {argument:?}"));
        };
        if !allowed.contains(&flag) {
            return Err(format!("unknown option --{flag}"));
        }
        let Some(value) = args.get(index + 1) else {
            return Err(format!("--{flag} requires a value"));
        };
        if values.insert(flag.to_string(), value.to_string()).is_some() {
            return Err(format!("duplicate option --{flag}"));
        }
        index += 2;
    }
    Ok(values)
}

fn required<'a>(flags: &'a BTreeMap<String, String>, key: &str) -> Result<&'a str, String> {
    flags
        .get(key)
        .map(String::as_str)
        .ok_or_else(|| format!("missing --{key}"))
}

fn parse_role(value: &str) -> Result<builder_core::protocol::model::InputRole, String> {
    value
        .parse()
        .map_err(|_| format!("role must be \"rom\" or \"keys\", got {value:?}"))
}

fn parse_u64(value: &str, what: &str) -> Result<u64, String> {
    value
        .parse::<u64>()
        .map_err(|_| format!("{what} must be a non-negative integer, got {value:?}"))
}

fn upload_command(data_root: &DataRoot, args: &[&str]) -> i32 {
    let flags = match parse_flags(args, &["job", "role", "bytes", "sha256", "offset"]) {
        Ok(flags) => flags,
        Err(message) => return usage_error(&message),
    };
    let parsed = (|| -> Result<UploadArgs, String> {
        let job_id = required(&flags, "job")?.to_string();
        if !builder_core::protocol::valid_job_id(&job_id) {
            return Err("invalid --job".to_string());
        }
        let role = parse_role(required(&flags, "role")?)?;
        let bytes = parse_u64(required(&flags, "bytes")?, "--bytes")?;
        let sha256 = normalize_sha256(required(&flags, "sha256")?)
            .ok_or_else(|| "--sha256 must be 64 hex characters".to_string())?;
        let offset = match flags.get("offset") {
            Some(value) => parse_u64(value, "--offset")?,
            None => 0,
        };
        Ok(UploadArgs {
            job_id,
            role,
            bytes,
            sha256,
            offset,
        })
    })();
    match parsed {
        Ok(args) => uploads::run_upload(data_root, &args),
        Err(message) => usage_error(&message),
    }
}

fn status_command(data_root: &DataRoot, args: &[&str]) -> i32 {
    let flags = match parse_flags(args, &["job", "role"]) {
        Ok(flags) => flags,
        Err(message) => return usage_error(&message),
    };
    let parsed = (|| -> Result<(String, builder_core::protocol::model::InputRole), String> {
        let job_id = required(&flags, "job")?.to_string();
        if !builder_core::protocol::valid_job_id(&job_id) {
            return Err("invalid --job".to_string());
        }
        let role = parse_role(required(&flags, "role")?)?;
        Ok((job_id, role))
    })();
    match parsed {
        Ok((job_id, role)) => uploads::run_status(data_root, &job_id, role),
        Err(message) => usage_error(&message),
    }
}

fn download_command(data_root: &DataRoot, args: &[&str]) -> i32 {
    let flags = match parse_flags(args, &["job", "what", "offset"]) {
        Ok(flags) => flags,
        Err(message) => return usage_error(&message),
    };
    let parsed = (|| -> Result<(String, ArtifactWhat, u64), String> {
        let job_id = required(&flags, "job")?.to_string();
        if !builder_core::protocol::valid_job_id(&job_id) {
            return Err("invalid --job".to_string());
        }
        let what = ArtifactWhat::parse(required(&flags, "what")?)
            .ok_or_else(|| "--what must be \"ipa\" or \"manifest-txt\"".to_string())?;
        let offset = match flags.get("offset") {
            Some(value) => parse_u64(value, "--offset")?,
            None => 0,
        };
        Ok((job_id, what, offset))
    })();
    match parsed {
        Ok((job_id, what, offset)) => downloads::run_download(data_root, &job_id, what, offset),
        Err(message) => usage_error(&message),
    }
}

fn doctor_command(data_root: &DataRoot, args: &[&str]) -> i32 {
    if !args.iter().all(|argument| *argument == "--json") {
        return usage_error("only `doctor --json` is supported over SSH");
    }
    let cfg = match config::load(&data_root.root) {
        Ok(cfg) => cfg,
        Err(message) => {
            print_error_frame(ErrorInfo::new(ErrorCode::Internal, message));
            return 64;
        }
    };
    let report = crate::doctor::gather(&cfg, data_root);
    match serde_json::to_string(&report) {
        Ok(json) => {
            let mut stdout = io::stdout().lock();
            let _ = writeln!(stdout, "{json}");
            let _ = stdout.flush();
            0
        }
        Err(error) => {
            print_error_frame(ErrorInfo::new(
                ErrorCode::Internal,
                format!("could not serialise the doctor report: {error}"),
            ));
            64
        }
    }
}

// ---------------------------------------------------------------------------
// `stdio`: proxy bytes to the daemon (auto-starting it when missing)
// ---------------------------------------------------------------------------

fn proxy_stdio(data_root: &DataRoot, no_spawn: bool) -> i32 {
    let socket = data_root.socket_path();
    let stream = match connect_or_spawn(&socket, data_root, no_spawn) {
        Ok(stream) => stream,
        Err(message) => {
            print_error_frame(ErrorInfo::new(ErrorCode::DaemonUnavailable, message));
            return 69;
        }
    };
    proxy(stream)
}

fn connect_or_spawn(
    socket: &Path,
    data_root: &DataRoot,
    no_spawn: bool,
) -> Result<UnixStream, String> {
    if let Ok(stream) = UnixStream::connect(socket) {
        return Ok(stream);
    }
    if no_spawn {
        return Err(format!(
            "the Agent daemon is not running on {} (auto-start disabled)",
            socket.display()
        ));
    }
    spawn_daemon(data_root)?;
    let deadline = Instant::now() + SPAWN_WAIT;
    loop {
        match UnixStream::connect(socket) {
            Ok(stream) => return Ok(stream),
            Err(error) => {
                if Instant::now() > deadline {
                    return Err(format!(
                        "the Agent daemon did not start within {}s: {error}",
                        SPAWN_WAIT.as_secs()
                    ));
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

fn spawn_daemon(data_root: &DataRoot) -> Result<(), String> {
    data_root
        .ensure_layout()
        .map_err(|error| format!("could not create the data root: {error}"))?;
    let executable = std::env::current_exe()
        .map_err(|error| format!("could not locate the Agent binary: {error}"))?;
    let log_path = data_root.tmp_dir().join("daemon.log");
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|error| format!("could not open {}: {error}", log_path.display()))?;
    let _ = util::set_private_file(&log_path);
    let stderr_log = log
        .try_clone()
        .map_err(|error| format!("could not clone the daemon log handle: {error}"))?;
    Command::new(executable)
        .args(["serve", "--socket"])
        .arg(data_root.socket_path())
        .arg("--data-root")
        .arg(&data_root.root)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(stderr_log))
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("could not start the Agent daemon: {error}"))
}

fn proxy(stream: UnixStream) -> i32 {
    let mut read_stream = match stream.try_clone() {
        Ok(stream) => stream,
        Err(error) => {
            print_error_frame(ErrorInfo::new(
                ErrorCode::Internal,
                format!("could not split the daemon connection: {error}"),
            ));
            return 64;
        }
    };
    let mut write_stream = stream;
    let pump = std::thread::spawn(move || {
        let mut stdin = io::stdin();
        let mut buffer = vec![0_u8; 64 * 1024];
        loop {
            match stdin.read(&mut buffer) {
                Ok(0) => break,
                Ok(read) => {
                    if write_stream.write_all(&buffer[..read]).is_err() {
                        break;
                    }
                    let _ = write_stream.flush();
                }
                Err(_) => break,
            }
        }
        // Let the daemon session see EOF so it can finish and close its side.
        let _ = write_stream.shutdown(std::net::Shutdown::Write);
        write_stream
    });
    let mut stdout = io::stdout().lock();
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        match read_stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                if stdout.write_all(&buffer[..read]).is_err() {
                    break;
                }
                let _ = stdout.flush();
            }
            Err(_) => break,
        }
    }
    let _ = pump.join();
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flag_parsing_is_strict() {
        let flags = parse_flags(
            &["--job", "job_01J8Z3K4T9ABCDEFGHJKMNPQRS", "--role", "rom"],
            &["job", "role"],
        )
        .unwrap();
        assert_eq!(flags["role"], "rom");
        assert!(parse_flags(&["--job"], &["job"]).is_err());
        assert!(parse_flags(&["job"], &["job"]).is_err());
        assert!(parse_flags(&["--evil", "x"], &["job"]).is_err());
        assert!(parse_flags(&["--job", "a", "--job", "b"], &["job"]).is_err());
        assert!(parse_flags(&["--job", "a", "--job", "b"], &["job"]).is_err());
    }

    #[test]
    fn role_and_number_parsing() {
        assert!(parse_role("rom").is_ok());
        assert!(parse_role("keys").is_ok());
        assert!(parse_role("other").is_err());
        assert_eq!(parse_u64("10", "--bytes").unwrap(), 10);
        assert!(parse_u64("-1", "--bytes").is_err());
        assert!(parse_u64("x", "--bytes").is_err());
    }

    #[test]
    fn artifact_what_parsing() {
        assert_eq!(ArtifactWhat::parse("ipa"), Some(ArtifactWhat::Ipa));
        assert_eq!(
            ArtifactWhat::parse("manifest-txt"),
            Some(ArtifactWhat::ManifestTxt)
        );
        assert_eq!(ArtifactWhat::parse("other"), None);
    }
}
