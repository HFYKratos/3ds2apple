//! Locating and running the shared `zkb` client.
//!
//! The Linux frontend is a thin, Linux-specific layer over the shared CLI: all
//! protocol, hashing and host-profile work stays in `builder-core`/`zkb`, and
//! this crate only adds VM discovery, first-run orchestration and the local
//! artifact/installation summary. Running `zkb` as a child process keeps its
//! behaviour (and its exit codes) identical to the Windows and macOS clients.

use std::ffi::{OsStr, OsString};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::error::{Error, EXIT_INTERNAL};

/// Environment override for the shared CLI path.
pub const ENV_ZKB_BIN: &str = "ZKB_BIN";
/// File name of the shared CLI binary.
pub const ZKB_BIN_NAME: &str = "zkb";

/// A resolved `zkb` executable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Zkb {
    path: PathBuf,
}

/// Captured output of one `zkb` run.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RunOutput {
    pub code: i32,
    pub stdout: Vec<String>,
    pub stderr: Vec<String>,
}

impl RunOutput {
    pub fn succeeded(&self) -> bool {
        self.code == 0
    }

    pub fn stdout_text(&self) -> String {
        self.stdout.join("\n")
    }

    pub fn stderr_text(&self) -> String {
        self.stderr.join("\n")
    }

    /// The last stdout line starting with `prefix`, without the prefix.
    pub fn last_marker(&self, prefix: &str) -> Option<String> {
        self.stdout
            .iter()
            .rev()
            .find_map(|line| line.strip_prefix(prefix).map(str::trim).map(str::to_string))
    }
}

impl Zkb {
    /// Find the shared `zkb` binary.
    ///
    /// Order: explicit `--zkb`, `$ZKB_BIN`, a sibling of this executable (the
    /// usual layout when both are built from this workspace), then `$PATH`.
    pub fn locate(
        explicit: Option<&Path>,
        env_bin: Option<OsString>,
        current_exe: &Path,
    ) -> Result<Self, Error> {
        if let Some(path) = explicit {
            return Self::from_path(path, "the --zkb path");
        }
        if let Some(env_bin) = env_bin {
            if !env_bin.is_empty() {
                return Self::from_path(Path::new(&env_bin), ENV_ZKB_BIN);
            }
        }
        if let Some(sibling) = sibling_binary(current_exe) {
            return Ok(Self { path: sibling });
        }
        if let Some(found) = search_path(std::env::var_os("PATH").as_deref()) {
            return Ok(Self { path: found });
        }
        Err(Error::local(format!(
            "the shared `zkb` client was not found. Build it with `cargo build --release -p builder-cli` \
             and put it on PATH, keep it next to this binary, set {ENV_ZKB_BIN}, or pass --zkb <path>."
        )))
    }

    fn from_path(path: &Path, origin: &str) -> Result<Self, Error> {
        if !path.is_file() {
            return Err(Error::local(format!(
                "{origin} points at {}, which does not exist or is not a file",
                path.display()
            )));
        }
        Ok(Self {
            path: path.to_path_buf(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// `zkb --version` output (first line), if the binary runs.
    pub fn version(&self) -> Option<String> {
        let output = self.run_capture(&["--version".to_string()]).ok()?;
        if !output.succeeded() {
            return None;
        }
        output
            .stdout
            .first()
            .map(|line| line.trim().to_string())
            .filter(|line| !line.is_empty())
    }

    /// Run with inherited stdio, returning the exit code unchanged.
    pub fn run_inherit(&self, args: &[String]) -> Result<i32, Error> {
        let status = Command::new(&self.path)
            .args(args)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .map_err(|error| {
                Error::local(format!("could not run {}: {error}", self.path.display()))
            })?;
        match status.code() {
            Some(code) => Ok(code),
            None => Err(Error::internal(format!(
                "{} was terminated by a signal while running {args:?}",
                self.path.display()
            ))),
        }
    }

    /// Run and capture stdout/stderr (used for `--version` and small queries).
    pub fn run_capture(&self, args: &[String]) -> Result<RunOutput, Error> {
        let output = Command::new(&self.path)
            .args(args)
            .stdin(Stdio::null())
            .output()
            .map_err(|error| {
                Error::local(format!("could not run {}: {error}", self.path.display()))
            })?;
        Ok(RunOutput {
            code: output.status.code().unwrap_or(EXIT_INTERNAL),
            stdout: split_lines(&output.stdout),
            stderr: split_lines(&output.stderr),
        })
    }

    /// Run while streaming each output line through this process.
    ///
    /// Both pipes are drained on separate threads, so a long build cannot
    /// deadlock on a full pipe and the user sees progress as it happens.
    pub fn run_streaming(&self, args: &[String], echo: bool) -> Result<RunOutput, Error> {
        let mut child = Command::new(&self.path)
            .args(args)
            .stdin(Stdio::inherit())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| {
                Error::local(format!("could not run {}: {error}", self.path.display()))
            })?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| Error::internal("zkb stdout pipe was not captured"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| Error::internal("zkb stderr pipe was not captured"))?;
        let stdout_handle = std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            let mut lines = Vec::new();
            for line in reader.lines() {
                match line {
                    Ok(line) => {
                        if echo {
                            println!("{line}");
                            let _ = std::io::stdout().flush();
                        }
                        lines.push(line);
                    }
                    Err(_) => break,
                }
            }
            lines
        });
        let stderr_handle = std::thread::spawn(move || {
            let reader = BufReader::new(stderr);
            let mut lines = Vec::new();
            for line in reader.lines() {
                match line {
                    Ok(line) => {
                        if echo {
                            eprintln!("{line}");
                        }
                        lines.push(line);
                    }
                    Err(_) => break,
                }
            }
            lines
        });
        let status = child.wait().map_err(|error| {
            Error::local(format!(
                "waiting for {} failed: {error}",
                self.path.display()
            ))
        })?;
        let stdout = stdout_handle.join().unwrap_or_default();
        let stderr = stderr_handle.join().unwrap_or_default();
        Ok(RunOutput {
            code: status.code().unwrap_or(EXIT_INTERNAL),
            stdout,
            stderr,
        })
    }
}

/// Prepend the global flags understood by `zkb` to a subcommand invocation.
pub fn with_globals(config: Option<&Path>, json: bool, rest: Vec<String>) -> Vec<String> {
    let mut args = Vec::new();
    if let Some(config) = config {
        args.push("--config".to_string());
        args.push(config.display().to_string());
    }
    if json {
        args.push("--json".to_string());
    }
    args.extend(rest);
    args
}

fn sibling_binary(current_exe: &Path) -> Option<PathBuf> {
    let dir = current_exe.parent()?;
    let name = format!("{ZKB_BIN_NAME}{}", std::env::consts::EXE_SUFFIX);
    let candidate = dir.join(name);
    candidate.is_file().then_some(candidate)
}

fn search_path(path_var: Option<&OsStr>) -> Option<PathBuf> {
    let path_var = path_var?;
    let name = format!("{ZKB_BIN_NAME}{}", std::env::consts::EXE_SUFFIX);
    for dir in std::env::split_paths(path_var) {
        let candidate = dir.join(&name);
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
    }
    None
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn split_lines(bytes: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(bytes)
        .lines()
        .map(|line| line.trim_end_matches('\r').to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn write_script(path: &Path, body: &str) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
        let mut permissions = std::fs::metadata(path).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(path, permissions).unwrap();
    }

    #[test]
    fn explicit_path_wins_and_missing_paths_are_errors() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("zkb");
        std::fs::write(&fake, b"x").unwrap();
        let zkb = Zkb::locate(Some(&fake), None, &dir.path().join("self")).unwrap();
        assert_eq!(zkb.path(), fake);

        let missing = dir.path().join("nope");
        let error = Zkb::locate(Some(&missing), None, &dir.path().join("self")).unwrap_err();
        assert_eq!(error.exit_code(), crate::error::EXIT_IO);
        assert!(error.to_string().contains("does not exist"));
    }

    #[test]
    fn finds_the_sibling_binary_next_to_this_executable() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("zkb");
        std::fs::write(&fake, b"x").unwrap();
        let current_exe = dir.path().join("3ds2apple-builder");
        let zkb = Zkb::locate(None, None, &current_exe).unwrap();
        assert_eq!(zkb.path(), fake);
    }

    #[test]
    fn finds_zkb_on_path_like_search_paths() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("zkb");
        std::fs::write(&fake, b"x").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = std::fs::metadata(&fake).unwrap().permissions();
            permissions.set_mode(0o755);
            std::fs::set_permissions(&fake, permissions).unwrap();
        }
        let path_var = std::env::join_paths([dir.path()]).unwrap();
        assert_eq!(search_path(Some(path_var.as_os_str())), Some(fake));
        assert_eq!(search_path(Some(OsStr::new("/nonexistent-only"))), None);
    }

    #[test]
    fn marker_parsing_takes_the_last_occurrence() {
        let output = RunOutput {
            code: 0,
            stdout: vec![
                "sha256: old".to_string(),
                "ipa: out/pokemon-y-AOT.ipa".to_string(),
                "sha256: new".to_string(),
            ],
            stderr: vec![],
        };
        assert_eq!(output.last_marker("sha256: "), Some("new".to_string()));
        assert_eq!(output.last_marker("missing: "), None);
        assert!(output.succeeded());
    }

    #[test]
    fn with_globals_puts_global_flags_before_the_subcommand() {
        let args = with_globals(
            Some(Path::new("/tmp/config.toml")),
            true,
            vec!["build".to_string(), "--host".to_string(), "vm".to_string()],
        );
        assert_eq!(
            args,
            vec![
                "--config",
                "/tmp/config.toml",
                "--json",
                "build",
                "--host",
                "vm"
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    fn captures_version_and_streams_output() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("zkb");
        write_script(
            &fake,
            "if [ \"$1\" = \"--version\" ]; then echo 'zkb 9.9.9'; exit 0; fi\n\
             echo out-line\necho err-line >&2\nexit 7",
        );
        let zkb = Zkb::locate(Some(&fake), None, &dir.path().join("self")).unwrap();
        assert_eq!(zkb.version().as_deref(), Some("zkb 9.9.9"));

        let captured = zkb.run_capture(&["build".to_string()]).unwrap();
        assert_eq!(captured.code, 7);
        assert_eq!(captured.stdout, vec!["out-line".to_string()]);
        assert_eq!(captured.stderr, vec!["err-line".to_string()]);

        let streamed = zkb.run_streaming(&["build".to_string()], false).unwrap();
        assert_eq!(streamed.code, 7);
        assert_eq!(streamed.stdout, vec!["out-line".to_string()]);
        assert_eq!(streamed.stderr, vec!["err-line".to_string()]);
    }

    #[test]
    fn non_executable_files_are_not_found_on_path() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("zkb");
        std::fs::write(&fake, b"not executable").unwrap();
        let path_var = std::env::join_paths([dir.path()]).unwrap();
        #[cfg(unix)]
        assert_eq!(search_path(Some(path_var.as_os_str())), None);
        #[cfg(not(unix))]
        assert_eq!(search_path(Some(path_var.as_os_str())), Some(fake));
    }
}
