//! Operating-system probes and parsers.
//!
//! The frontend never uses a shell: every external command is spawned with an
//! argument array, and the values that come from the user (paths, host names)
//! are passed as arguments or environment variables, never interpolated into a
//! command string. PowerShell is used only for one read-only query (free space),
//! with the path handed over through an environment variable.
//!
//! Every parser here is a pure function with unit tests, so the Windows-specific
//! detection logic is verifiable on a development machine and the platform calls
//! stay a thin layer.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Captured output of a short probe command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

impl CommandOutput {
    pub fn success(&self) -> bool {
        self.code == Some(0)
    }

    /// stdout unless it is empty, otherwise stderr; trimmed.
    pub fn best_effort_text(&self) -> &str {
        let stdout = self.stdout.trim();
        if !stdout.is_empty() {
            return stdout;
        }
        self.stderr.trim()
    }
}

/// Run a command with an argument array and capture its output.
pub fn run_argv(program: &OsStr, args: &[&OsStr]) -> std::io::Result<CommandOutput> {
    let mut command = Command::new(program);
    command.args(args);
    hide_console(&mut command);
    let output = command.output()?;
    Ok(CommandOutput {
        code: output.status.code(),
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
    })
}

/// Run a command given as strings, returning `None` when it cannot be started.
pub fn run_str(program: &str, args: &[&str]) -> Option<CommandOutput> {
    run_argv(
        OsStr::new(program),
        &args.iter().map(OsStr::new).collect::<Vec<_>>(),
    )
    .ok()
}

/// Do not flash a console window for the short-lived probes started by a GUI.
fn hide_console(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    {
        let _ = command;
    }
}

/// Extensions tried when resolving a program name, following `PATHEXT` on
/// Windows and a plain name on other platforms.
pub fn executable_extensions() -> Vec<String> {
    #[cfg(windows)]
    {
        let pathext =
            std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string());
        let mut extensions: Vec<String> = pathext
            .split(';')
            .filter(|extension| !extension.trim().is_empty())
            .map(|extension| extension.trim().to_ascii_lowercase())
            .collect();
        if extensions.is_empty() {
            extensions = vec![".exe".to_string()];
        }
        extensions
    }
    #[cfg(not(windows))]
    {
        vec![String::new()]
    }
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(windows)]
    {
        true
    }
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
}

/// Resolve a program on `PATH` with explicit extensions (testable variant).
pub fn which_in(program: &str, path_var: &OsStr, extensions: &[String]) -> Option<PathBuf> {
    if program.is_empty() {
        return None;
    }
    let candidate = Path::new(program);
    if candidate.is_absolute() || program.contains('/') || program.contains('\\') {
        for extension in extensions {
            let path = PathBuf::from(format!("{program}{extension}"));
            if is_executable_file(&path) {
                return Some(path);
            }
        }
        return None;
    }
    for directory in std::env::split_paths(path_var) {
        if directory.as_os_str().is_empty() {
            continue;
        }
        for extension in extensions {
            let path = directory.join(format!("{program}{extension}"));
            if is_executable_file(&path) {
                return Some(path);
            }
        }
    }
    None
}

/// Resolve a program on this machine's `PATH`.
pub fn which(program: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH").unwrap_or_default();
    which_in(program, &path_var, &executable_extensions())
}

/// Parse the version out of `ssh -V` output, e.g.
/// `OpenSSH_for_Windows_9.5p1, LibreSSL 3.8.2` -> `9.5p1`.
pub fn parse_openssh_version(text: &str) -> Option<String> {
    for token in text
        .split(|character: char| character.is_whitespace() || character == ',' || character == ';')
    {
        let token = token.trim();
        let rest = if let Some(rest) = token.strip_prefix("OpenSSH_for_Windows_") {
            rest
        } else if let Some(rest) = token.strip_prefix("OpenSSH_") {
            rest
        } else {
            continue;
        };
        if rest.is_empty() {
            continue;
        }
        let version: String = rest
            .chars()
            .take_while(|character| character.is_ascii_digit() || *character == '.')
            .collect();
        if version.is_empty() {
            continue;
        }
        let suffix: String = rest[version.len()..]
            .chars()
            .take_while(|character| character.is_ascii_alphanumeric() || *character == '.')
            .collect();
        return Some(format!("{version}{suffix}"));
    }
    None
}

/// Parse a dotted numeric version directory name (`157.0.4341.42`).
pub fn parse_version_quad(name: &str) -> Option<Vec<u64>> {
    let parts: Vec<&str> = name.split('.').collect();
    if parts.len() < 2 {
        return None;
    }
    let mut numbers = Vec::with_capacity(parts.len());
    for part in parts {
        numbers.push(part.parse::<u64>().ok()?);
    }
    Some(numbers)
}

/// Highest WebView2 (or similar) runtime version found in the given
/// `EdgeWebView\Application`-style directories.
pub fn highest_runtime_version(directories: &[PathBuf]) -> Option<String> {
    let mut best: Option<(Vec<u64>, String)> = None;
    for directory in directories {
        let Ok(entries) = std::fs::read_dir(directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let Some(parsed) = parse_version_quad(name) else {
                continue;
            };
            if !entry.path().is_dir() {
                continue;
            }
            if best
                .as_ref()
                .map(|(best, _)| parsed > *best)
                .unwrap_or(true)
            {
                best = Some((parsed, name.to_string()));
            }
        }
    }
    best.map(|(_, name)| name)
}

/// Parse `reg query ... /v LongPathsEnabled` output for the DWORD value.
pub fn parse_long_paths_registry(text: &str) -> Option<bool> {
    for line in text.lines() {
        let lower = line.to_ascii_lowercase();
        if !lower.contains("longpathsenabled") {
            continue;
        }
        let mut fields = line.split_whitespace();
        while let Some(field) = fields.next() {
            if field.eq_ignore_ascii_case("REG_DWORD") {
                let value = fields.next()?;
                let value = value.trim_start_matches("0x").trim_start_matches("0X");
                return u64::from_str_radix(value, 16).ok().map(|value| value != 0);
            }
        }
    }
    None
}

/// Parse `chcp.com` output (`Active code page: 65001`).
pub fn parse_console_code_page(text: &str) -> Option<u32> {
    for line in text.lines() {
        let line = line.trim();
        // The message is localised by conhost; accept the non-English variants
        // a Chinese Windows install prints.
        let lower = line.to_ascii_lowercase();
        let is_codepage_line = lower.contains("code page")
            || lower.contains("codepage")
            || line.contains("代码页")
            || line.contains("代碼頁")
            || line.contains(':');
        if !is_codepage_line {
            continue;
        }
        // conhost localises the text and writes it in the active code page, so
        // decoded bytes may be mojibake; the number after the last colon is
        // ASCII digits in the Windows code pages too.
        if let Some((_, tail)) = line.rsplit_once(':') {
            if let Ok(value) = tail.trim().parse::<u32>() {
                if (3..=65_535).contains(&value) {
                    return Some(value);
                }
            }
        }
        for token in line.split(|character: char| !character.is_ascii_digit()) {
            if token.is_empty() {
                continue;
            }
            if let Ok(value) = token.parse::<u32>() {
                if (3..=65_535).contains(&value) {
                    return Some(value);
                }
            }
        }
    }
    None
}

/// Parse the free-bytes number printed by the PowerShell disk probe.
pub fn parse_powershell_bytes(text: &str) -> Option<u64> {
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(value) = line.parse::<u64>() {
            return Some(value);
        }
    }
    None
}

/// Parse the available column of POSIX `df -kP` output.
pub fn parse_df_available_bytes(text: &str) -> Option<u64> {
    let mut lines = text.lines().filter(|line| !line.trim().is_empty());
    let _header = lines.next()?;
    let row = lines.next()?;
    let columns: Vec<&str> = row.split_whitespace().collect();
    if columns.len() < 4 {
        return None;
    }
    let available_kb = columns[3].parse::<u64>().ok()?;
    Some(available_kb.saturating_mul(1024))
}

fn nearest_existing_directory(path: &Path) -> Option<PathBuf> {
    let mut current = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    if current.is_file() {
        current.pop();
    }
    loop {
        if current.is_dir() {
            return Some(current);
        }
        if !current.pop() {
            return None;
        }
    }
}

/// Free bytes on the volume that holds `path` (or its nearest existing parent).
pub fn free_space(path: &Path) -> Option<u64> {
    let directory = nearest_existing_directory(path)?;
    #[cfg(windows)]
    {
        free_space_windows(&directory)
    }
    #[cfg(not(windows))]
    {
        let output = run_str("df", &["-kP", &directory.to_string_lossy()])?;
        if !output.success() {
            return None;
        }
        parse_df_available_bytes(&output.stdout)
    }
}

#[cfg(windows)]
fn free_space_windows(directory: &Path) -> Option<u64> {
    let mut command = Command::new("powershell.exe");
    command
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "$p = $env:BUILDER_WINDOWS_PROBE_PATH; \
             $item = Get-Item -LiteralPath $p -ErrorAction Stop; \
             $item.PSDrive.Free",
        ])
        .env("BUILDER_WINDOWS_PROBE_PATH", directory);
    hide_console(&mut command);
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    parse_powershell_bytes(&String::from_utf8_lossy(&output.stdout))
}

/// `ssh -V` version and binary path, if the OpenSSH client is installed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshProbe {
    pub program: Option<PathBuf>,
    pub version: Option<String>,
}

pub fn ssh_probe() -> SshProbe {
    let program = which("ssh");
    let version = program
        .as_ref()
        .and_then(|_| run_str("ssh", &["-V"]))
        .and_then(|output| parse_openssh_version(output.best_effort_text()));
    SshProbe { program, version }
}

/// Whether an auxiliary pairing tool (`ssh-keygen`, `ssh-keyscan`) is present.
pub fn pairing_tool(name: &str) -> Option<PathBuf> {
    which(name)
}

/// WebView2 runtime version, needed only by a graphical build.
pub fn webview2_runtime() -> Option<String> {
    #[allow(unused_mut)]
    let mut directories: Vec<PathBuf> = Vec::new();
    #[cfg(windows)]
    {
        if let Some(program_files) = std::env::var_os("ProgramFiles(x86)") {
            directories.push(
                PathBuf::from(program_files)
                    .join("Microsoft")
                    .join("EdgeWebView")
                    .join("Application"),
            );
        }
        if let Some(program_files) = std::env::var_os("ProgramFiles") {
            directories.push(
                PathBuf::from(program_files)
                    .join("Microsoft")
                    .join("EdgeWebView")
                    .join("Application"),
            );
        }
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            directories.push(
                PathBuf::from(local)
                    .join("Microsoft")
                    .join("EdgeWebView")
                    .join("Application"),
            );
        }
    }
    if directories.is_empty() {
        return None;
    }
    highest_runtime_version(&directories)
}

/// Active console output code page (Windows only).
pub fn console_code_page() -> Option<u32> {
    #[cfg(windows)]
    {
        let output = run_str("chcp.com", &[])?;
        parse_console_code_page(output.best_effort_text())
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// Whether the system-wide long-path registry setting is on (Windows only).
pub fn long_paths_enabled() -> Option<bool> {
    #[cfg(windows)]
    {
        let output = run_str(
            "reg.exe",
            &[
                "query",
                r"HKLM\SYSTEM\CurrentControlSet\Control\FileSystem",
                "/v",
                "LongPathsEnabled",
            ],
        )?;
        parse_long_paths_registry(&output.stdout)
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// Human Windows build string from `cmd /c ver` (Windows only).
pub fn windows_version() -> Option<String> {
    #[cfg(windows)]
    {
        // `cmd /c ver` is localised and printed in the console code page, which
        // turns into mojibake when decoded as UTF-8; PowerShell's OSVersion
        // prints a plain dotted version number instead. `ver` is the fallback.
        if let Some(output) = run_str(
            "powershell.exe",
            &[
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[System.Environment]::OSVersion.Version.ToString()",
            ],
        ) {
            if let Some(version) = parse_windows_version_output(&output.stdout) {
                return Some(version);
            }
        }
        let output = run_str("cmd.exe", &["/c", "ver"])?;
        let text = output.best_effort_text().trim().to_string();
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }
    #[cfg(not(windows))]
    {
        None
    }
}

/// Pick a dotted Windows version number out of a probe's output.
pub fn parse_windows_version_output(text: &str) -> Option<String> {
    for line in text.lines() {
        let candidate = line.trim();
        if candidate.is_empty() {
            continue;
        }
        let parts: Vec<&str> = candidate.split('.').collect();
        if parts.len() < 2
            || !parts
                .iter()
                .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
        {
            continue;
        }
        return Some(candidate.to_string());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn openssh_versions_parse_on_windows_and_linux() {
        assert_eq!(
            parse_openssh_version("OpenSSH_for_Windows_9.5p1, LibreSSL 3.8.2"),
            Some("9.5p1".to_string())
        );
        assert_eq!(
            parse_openssh_version("OpenSSH_9.6p1 Ubuntu-3ubuntu13.5, OpenSSL 3.0.13"),
            Some("9.6p1".to_string())
        );
        assert_eq!(
            parse_openssh_version("OpenSSH_8.9p1, LibreSSL 3.3.6"),
            Some("8.9p1".to_string())
        );
        assert_eq!(parse_openssh_version("not ssh"), None);
        assert_eq!(parse_openssh_version(""), None);
    }

    #[test]
    fn version_quads_are_parsed_and_compared() {
        assert_eq!(
            parse_version_quad("157.0.4341.42"),
            Some(vec![157, 0, 4341, 42])
        );
        assert_eq!(parse_version_quad("157.0"), Some(vec![157, 0]));
        assert_eq!(parse_version_quad("Background"), None);
        assert_eq!(parse_version_quad("1..2"), None);
    }

    #[test]
    fn the_highest_webview_runtime_is_selected() {
        let dir = tempfile::tempdir().unwrap();
        for name in [
            "120.0.1.1",
            "157.0.4341.42",
            "157.0.4341.46",
            "SetupMetrics",
        ] {
            std::fs::create_dir(dir.path().join(name)).unwrap();
        }
        assert_eq!(
            highest_runtime_version(&[dir.path().to_path_buf()]),
            Some("157.0.4341.46".to_string())
        );
        assert_eq!(highest_runtime_version(&[]), None);
        assert_eq!(highest_runtime_version(&[dir.path().join("missing")]), None);
    }

    #[test]
    fn long_paths_registry_value_is_parsed() {
        let enabled = "
HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\FileSystem
    LongPathsEnabled    REG_DWORD    0x1
";
        assert_eq!(parse_long_paths_registry(enabled), Some(true));
        let disabled = "
    LongPathsEnabled    REG_DWORD    0x0
";
        assert_eq!(parse_long_paths_registry(disabled), Some(false));
        assert_eq!(parse_long_paths_registry("Access is denied."), None);
    }

    #[test]
    fn console_code_page_is_parsed() {
        assert_eq!(
            parse_console_code_page("Active code page: 65001"),
            Some(65001)
        );
        assert_eq!(parse_console_code_page("活动代码页: 936"), Some(936));
        // GBK-encoded Chinese decoded as UTF-8 becomes mojibake; the digits
        // after the colon still parse.
        assert_eq!(
            parse_console_code_page("\u{fffd}\u{fffd}\u{fffd}: 936"),
            Some(936)
        );
        assert_eq!(parse_console_code_page(""), None);
        assert_eq!(parse_console_code_page("Access denied."), None);
    }

    #[test]
    fn windows_version_output_is_parsed() {
        assert_eq!(
            parse_windows_version_output("10.0.26200.0\r\n"),
            Some("10.0.26200.0".to_string())
        );
        assert_eq!(parse_windows_version_output("not a version"), None);
        assert_eq!(parse_windows_version_output(""), None);
    }

    #[test]
    fn powershell_free_space_is_parsed() {
        assert_eq!(
            parse_powershell_bytes("  1063256064\r\n"),
            Some(1_063_256_064)
        );
        assert_eq!(parse_powershell_bytes("nope"), None);
        assert_eq!(parse_powershell_bytes(""), None);
    }

    #[test]
    fn df_output_is_parsed() {
        let text = "Filesystem 1024-blocks Used Available Capacity Mounted on\n\
                    /dev/nvme0n1p1 1000000000 400000000 600000000 40% /\n";
        assert_eq!(parse_df_available_bytes(text), Some(600_000_000 * 1024));
        assert_eq!(parse_df_available_bytes("garbage"), None);
    }

    #[test]
    fn which_finds_programs_in_a_given_path() {
        let dir = tempfile::tempdir().unwrap();
        let program = dir.path().join("tool");
        std::fs::write(&program, b"#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let extensions = if cfg!(windows) {
            vec![".exe".to_string()]
        } else {
            vec![String::new()]
        };
        let name = if cfg!(windows) {
            std::fs::write(dir.path().join("tool.exe"), b"x").unwrap();
            "tool"
        } else {
            "tool"
        };
        let path_var = std::env::join_paths([dir.path()]).unwrap();
        assert_eq!(
            which_in(name, &path_var, &extensions),
            Some(dir.path().join(format!("{name}{}", extensions[0])))
        );
        assert_eq!(
            which_in("definitely-not-a-real-tool", &path_var, &extensions),
            None
        );
        assert_eq!(which_in("", &path_var, &extensions), None);
    }

    #[test]
    fn which_accepts_absolute_paths() {
        let dir = tempfile::tempdir().unwrap();
        let program = dir.path().join("abs-tool");
        std::fs::write(&program, b"#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let extensions = vec![String::new()];
        let text = program.to_string_lossy().to_string();
        assert!(which_in(
            &text,
            &std::env::var_os("PATH").unwrap_or_default(),
            &extensions
        )
        .is_some());
    }

    #[test]
    fn free_space_of_the_temp_directory_is_plausible() {
        // The probe command exists on Windows and Linux development hosts; skip
        // if the platform tool is missing rather than failing the suite.
        if let Some(bytes) = free_space(&std::env::temp_dir()) {
            assert!(bytes > 1024 * 1024, "{bytes}");
        }
    }

    #[test]
    fn ssh_probe_does_not_panic_when_missing() {
        let probe = ssh_probe();
        if probe.program.is_none() {
            assert!(probe.version.is_none());
        }
    }
}
