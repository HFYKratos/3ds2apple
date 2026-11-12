//! Windows path handling: extended-length paths, reserved names and Unicode.
//!
//! Windows still limits most tools to `MAX_PATH` (260 characters) unless
//! long-path support is enabled, and its file name rules reject characters and
//! device names that are legal on Unix. The frontend does two things:
//!
//! * it runs the standard file operations of the Builder on extended-length
//!   (`\\?\`) paths, so long paths, spaces, Unicode and CJK names work without
//!   changing the system-wide registry setting;
//! * it reports path problems in advance instead of letting a build fail later
//!   inside the Agent or the archive/zip step.
//!
//! The conversion and validation functions are pure so they can be tested on
//! any platform; only [`ensure_dir`] touches the filesystem style specifics.

use std::path::{Path, PathBuf};

/// Classic Windows path limit in UTF-16 units.
pub const MAX_PATH: usize = 260;

/// Extended-length (`\\?\`) path limit in UTF-16 units.
pub const MAX_EXTENDED_PATH: usize = 32767;

const VERBATIM_PREFIX: &str = r"\\?\";
const VERBATIM_UNC_PREFIX: &str = r"\\?\UNC\";
const DEVICE_PREFIX: &str = r"\\.\";

/// Is this a Windows build of the frontend?
pub fn is_windows_build() -> bool {
    cfg!(windows)
}

/// Convert an absolute Windows path to extended-length (`\\?\`) form.
///
/// * `C:\dir\file.cci` becomes `\\?\C:\dir\file.cci`
/// * `\\server\share\dir` becomes `\\?\UNC\server\share\dir`
/// * already-extended and device paths are returned unchanged
/// * relative or drive-relative paths are returned unchanged, because the
///   extended form requires a fully qualified path
///
/// `/` separators are normalised to `\` for the converted forms: verbatim paths
/// only accept backslashes.
pub fn extended_windows_path(input: &str) -> String {
    if input.is_empty() {
        return String::new();
    }
    if input.starts_with(VERBATIM_PREFIX) || input.starts_with(DEVICE_PREFIX) {
        return input.to_string();
    }
    let normalized = input.replace('/', r"\");
    if let Some(rest) = normalized.strip_prefix(r"\\") {
        if rest.is_empty() {
            return input.to_string();
        }
        return format!("{VERBATIM_UNC_PREFIX}{rest}");
    }
    let bytes = normalized.as_bytes();
    let drive_absolute =
        bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'\\';
    if drive_absolute {
        return format!("{VERBATIM_PREFIX}{normalized}");
    }
    input.to_string()
}

/// Extended-length form of a path, on Windows only.
///
/// On other platforms the path is returned unchanged; the frontend itself only
/// runs on Windows, the conversion exists for tests and for shares.
pub fn extended_length_path(path: &Path) -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(extended_windows_path(&path.to_string_lossy()))
    } else {
        path.to_path_buf()
    }
}

/// Strip the extended-length prefix for messages. Purely cosmetic.
pub fn display_path(path: &Path) -> String {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(VERBATIM_UNC_PREFIX) {
        return format!(r"\\{rest}");
    }
    if let Some(rest) = text.strip_prefix(VERBATIM_PREFIX) {
        return rest.to_string();
    }
    text.to_string()
}

/// A problem found in a would-be Windows path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PathIssue {
    /// A component is a reserved DOS device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9).
    ReservedName { component: String },
    /// A component ends in a space or a dot, which Windows silently strips.
    TrailingDotOrSpace { component: String },
    /// A character that Windows file names cannot contain.
    InvalidCharacter { component: String, character: char },
    /// Two separators in a row.
    EmptyComponent,
    /// Longer than the extended-length limit supports.
    ExtendedLengthExceeded { utf16_units: usize },
}

impl std::fmt::Display for PathIssue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PathIssue::ReservedName { component } => write!(
                f,
                "{component:?} is a reserved Windows device name and cannot be used as a file name"
            ),
            PathIssue::TrailingDotOrSpace { component } => write!(
                f,
                "{component:?} ends with a space or a dot, which Windows strips; rename it"
            ),
            PathIssue::InvalidCharacter {
                component,
                character,
            } => write!(
                f,
                "{component:?} contains {character:?}, which is not allowed in a Windows file name"
            ),
            PathIssue::EmptyComponent => {
                write!(f, "the path contains two separators in a row")
            }
            PathIssue::ExtendedLengthExceeded { utf16_units } => write!(
                f,
                "the path is {utf16_units} characters long; Windows extended paths support at most {MAX_EXTENDED_PATH}"
            ),
        }
    }
}

fn is_reserved_base(component: &str) -> bool {
    let base = component
        .split('.')
        .next()
        .unwrap_or(component)
        .trim_end_matches([' ', '.'])
        .to_ascii_uppercase();
    if matches!(base.as_str(), "CON" | "PRN" | "AUX" | "NUL") {
        return true;
    }
    if base.len() == 4 {
        let (prefix, digit) = base.split_at(3);
        if matches!(prefix, "COM" | "LPT")
            && matches!(digit, "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9")
        {
            return true;
        }
    }
    false
}

fn has_forbidden_character(component: &str) -> Option<char> {
    component
        .chars()
        .find(|ch| matches!(ch, '<' | '>' | ':' | '"' | '|' | '?' | '*') || ch.is_control())
}

/// Validate a Windows path without touching the filesystem.
///
/// Returns every problem found, so the user can fix a file name once instead of
/// discovering one issue per retry.
pub fn check_windows_path(input: &str) -> Vec<PathIssue> {
    // Accept extended-length paths: validate what the user would see in
    // Explorer, not the `\\?\` implementation prefix.
    let input = if let Some(rest) = input.strip_prefix(VERBATIM_UNC_PREFIX) {
        rest
    } else if let Some(rest) = input.strip_prefix(VERBATIM_PREFIX) {
        rest
    } else {
        input
    };
    let mut issues = Vec::new();
    let utf16_units = input.encode_utf16().count();
    if utf16_units > MAX_EXTENDED_PATH {
        issues.push(PathIssue::ExtendedLengthExceeded { utf16_units });
    }
    if input.is_empty() {
        return issues;
    }
    let normalized = input.replace('/', r"\");
    let parts: Vec<&str> = normalized.split(r"\").collect();
    let mut start = 0;
    let unc = parts.len() >= 2 && parts[0].is_empty() && parts[1].is_empty();
    if unc {
        start = 2;
    } else if parts.first() == Some(&"") {
        start = 1;
    }
    let drive = if !unc && start == 0 && parts[0].len() == 2 && parts[0].ends_with(':') {
        let bytes = parts[0].as_bytes();
        if bytes[0].is_ascii_alphabetic() {
            start = 1;
            Some(parts[0])
        } else {
            None
        }
    } else {
        None
    };
    for (position, component) in parts.iter().enumerate().skip(start) {
        if component.is_empty() {
            // A trailing separator is fine ("C:\dir\"); a doubled one is not.
            if position + 1 < parts.len() {
                issues.push(PathIssue::EmptyComponent);
            }
            continue;
        }
        if let Some(character) = has_forbidden_character(component) {
            issues.push(PathIssue::InvalidCharacter {
                component: component.to_string(),
                character,
            });
        }
        if component.ends_with('.') || component.ends_with(' ') {
            issues.push(PathIssue::TrailingDotOrSpace {
                component: component.to_string(),
            });
        }
        if is_reserved_base(component) {
            issues.push(PathIssue::ReservedName {
                component: component.to_string(),
            });
        }
    }
    if let Some(drive) = drive {
        if !drive.as_bytes()[0].is_ascii_alphabetic() {
            issues.push(PathIssue::InvalidCharacter {
                component: drive.to_string(),
                character: ':',
            });
        }
    }
    issues
}

/// Human-readable warnings for a path, prefixed for console output.
pub fn path_warnings(input: &str) -> Vec<String> {
    check_windows_path(input)
        .iter()
        .map(|issue| issue.to_string())
        .collect()
}

/// Create a directory (and parents), working with long paths on Windows.
pub fn ensure_dir(path: &Path) -> std::io::Result<PathBuf> {
    if path.as_os_str().is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "empty directory path",
        ));
    }
    let target = extended_length_path(path);
    std::fs::create_dir_all(&target)?;
    Ok(path.to_path_buf())
}

/// Resolve the config file path, honouring an explicit `--config` override.
pub fn config_file_path(explicit: Option<&Path>) -> PathBuf {
    match explicit {
        Some(path) => path.to_path_buf(),
        None => builder_core::config::default_config_file(),
    }
}

/// Directory holding downloaded IPAs, manifests and installation guides.
pub fn artifacts_dir() -> PathBuf {
    builder_core::config::default_data_dir().join("artifacts")
}

/// Directory for the frontend's own logs (redacted build logs exported by the user).
pub fn logs_dir() -> PathBuf {
    builder_core::config::default_data_dir().join("logs")
}

/// One-line summary of where long-path support comes from, for `doctor`.
pub fn long_path_support_note() -> &'static str {
    "the Builder itself uses extended-length (\\\\?\\\\) paths, so ROMs, outputs and profiles can exceed \
     260 characters; other tools (Explorer, some archivers) may still refuse them unless the \
     system-wide LongPathsEnabled registry setting is on"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drive_paths_become_verbatim() {
        assert_eq!(
            extended_windows_path(r"C:\Users\me\ROM\Pokemon Y.cci"),
            r"\\?\C:\Users\me\ROM\Pokemon Y.cci"
        );
        assert_eq!(
            extended_windows_path("C:/Users/me/ROM/game.3ds"),
            r"\\?\C:\Users\me\ROM\game.3ds"
        );
    }

    #[test]
    fn unc_paths_use_the_unc_verbatim_form() {
        assert_eq!(
            extended_windows_path(r"\\nas\share\roms\game.cci"),
            r"\\?\UNC\nas\share\roms\game.cci"
        );
        assert_eq!(
            extended_windows_path("//nas/share/roms/game.cci"),
            r"\\?\UNC\nas\share\roms\game.cci"
        );
    }

    #[test]
    fn extended_and_device_paths_are_left_alone() {
        let verbatim = r"\\?\C:\already\extended";
        assert_eq!(extended_windows_path(verbatim), verbatim);
        let device = r"\\.\PhysicalDrive0";
        assert_eq!(extended_windows_path(device), device);
    }

    #[test]
    fn relative_and_drive_relative_paths_are_not_extended() {
        assert_eq!(extended_windows_path(r"ROM\game.cci"), r"ROM\game.cci");
        assert_eq!(extended_windows_path(r".\game.cci"), r".\game.cci");
        assert_eq!(extended_windows_path("C:game.cci"), "C:game.cci");
        assert_eq!(extended_windows_path(""), "");
    }

    #[test]
    fn display_strips_the_prefix() {
        assert_eq!(
            display_path(Path::new(r"\\?\C:\Users\me\game.cci")),
            r"C:\Users\me\game.cci"
        );
        assert_eq!(
            display_path(Path::new(r"\\?\UNC\nas\share\game.cci")),
            r"\\nas\share\game.cci"
        );
        assert_eq!(display_path(Path::new(r"C:\plain")), r"C:\plain");
    }

    #[test]
    fn cjk_and_spaces_are_accepted() {
        let path = r"C:\Users\玩家\游戏 ROM\宝可梦 Y (美版).cci";
        assert_eq!(check_windows_path(path), Vec::new());
        assert_eq!(
            extended_windows_path(path),
            r"\\?\C:\Users\玩家\游戏 ROM\宝可梦 Y (美版).cci"
        );
    }

    #[test]
    fn reserved_device_names_are_rejected() {
        for name in [
            r"C:\tmp\CON",
            r"C:\tmp\con.txt",
            r"C:\tmp\NUL.log",
            r"C:\tmp\COM1",
            r"C:\tmp\LPT9.cci",
            r"C:\tmp\aux ",
        ] {
            let issues = check_windows_path(name);
            assert!(
                issues
                    .iter()
                    .any(|issue| matches!(issue, PathIssue::ReservedName { .. })),
                "{name}: {issues:?}"
            );
        }
        assert!(check_windows_path(r"C:\tmp\CONSOLE.cci").is_empty());
        assert!(check_windows_path(r"C:\tmp\COM10.cci").is_empty());
    }

    #[test]
    fn forbidden_characters_are_reported() {
        let issues = check_windows_path(r"C:\tmp\bad<name>.cci");
        assert!(issues
            .iter()
            .any(|issue| matches!(issue, PathIssue::InvalidCharacter { .. })));
        let quote = check_windows_path(r#"C:\tmp\bad"name.cci"#);
        assert_eq!(quote.len(), 1, "{quote:?}");
        assert!(check_windows_path(r"C:\tmp\a*b.cci")
            .iter()
            .any(|issue| matches!(issue, PathIssue::InvalidCharacter { character: '*', .. })));
    }

    #[test]
    fn trailing_dot_or_space_is_reported() {
        let issues = check_windows_path(r"C:\tmp\game. ");
        assert!(issues
            .iter()
            .any(|issue| matches!(issue, PathIssue::TrailingDotOrSpace { .. })));
        let trailing_dot = check_windows_path(r"C:\tmp\game.");
        assert!(trailing_dot
            .iter()
            .any(|issue| matches!(issue, PathIssue::TrailingDotOrSpace { .. })));
    }

    #[test]
    fn doubled_separators_are_reported_but_trailing_is_fine() {
        let doubled = check_windows_path(r"C:\one\\two\game.cci");
        assert_eq!(
            doubled
                .iter()
                .filter(|issue| matches!(issue, PathIssue::EmptyComponent))
                .count(),
            1,
            "{doubled:?}"
        );
        assert!(check_windows_path(r"C:\one\two\").is_empty());
        assert!(check_windows_path(r"C:\one\two\game.cci").is_empty());
    }

    #[test]
    fn overlong_paths_are_reported() {
        let long = format!(r"C:\{}", "a".repeat(MAX_EXTENDED_PATH));
        let issues = check_windows_path(&long);
        assert!(issues
            .iter()
            .any(|issue| matches!(issue, PathIssue::ExtendedLengthExceeded { .. })));
        // UTF-16 length, not bytes: 20k CJK characters is still under the limit.
        let cjk = format!(r"C:\{}", "游".repeat(20_000));
        assert!(check_windows_path(&cjk).is_empty());
    }

    #[test]
    fn extended_length_paths_are_validated_without_the_prefix() {
        assert!(check_windows_path(r"\\?\C:\Users\玩家\宝可梦.cci").is_empty());
        assert!(check_windows_path(r"\\?\C:\tmp\CON")
            .iter()
            .any(|issue| matches!(issue, PathIssue::ReservedName { .. })));
        // Long enough to warn on the display length, but valid as an extended path.
        let long_verbatim = format!(r"\\?\C:\{}", "a".repeat(300));
        assert!(check_windows_path(&long_verbatim).is_empty());
    }

    #[test]
    fn unc_root_is_valid() {
        assert!(check_windows_path(r"\\server\share\game.cci").is_empty());
    }

    #[test]
    fn ensure_dir_creates_nested_directories() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("a").join("b").join("c");
        let returned = ensure_dir(&nested).unwrap();
        assert_eq!(returned, nested);
        assert!(nested.is_dir());
        assert!(ensure_dir(&nested).is_ok(), "creating twice is fine");
        assert!(ensure_dir(Path::new("")).is_err());
    }

    #[test]
    fn config_path_override_wins() {
        let explicit = PathBuf::from(r"D:\cfg\config.toml");
        assert_eq!(config_file_path(Some(&explicit)), explicit);
        let default = config_file_path(None);
        assert!(default.ends_with("config.toml"));
    }
}
