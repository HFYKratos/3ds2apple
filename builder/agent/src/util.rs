//! Agent-local helpers: ids, permissions, atomic writes, host facts.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub use builder_core::util::{rfc3339_now as now, unix_now};

/// Crockford base32 alphabet (ULID canonical).
const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Read cryptographically random bytes from the OS.
pub fn random_bytes(length: usize) -> io::Result<Vec<u8>> {
    let mut bytes = vec![0_u8; length];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes)
}

/// A ULID: 48-bit millisecond timestamp followed by 80 random bits, encoded as
/// 26 Crockford base32 characters (lexicographically sortable by time).
pub fn ulid_now() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0);
    let mut bytes = [0_u8; 16];
    bytes[..6].copy_from_slice(&millis.to_be_bytes()[2..8]);
    match random_bytes(10) {
        Ok(random) => bytes[6..].copy_from_slice(&random),
        Err(_) => {
            // Extremely unlikely; still produce a unique unpredicted-enough id.
            let mut seed = millis ^ u64::from(std::process::id());
            for byte in &mut bytes[6..] {
                seed = seed
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1_442_695_040_888_963_407);
                *byte = (seed >> 33) as u8;
            }
        }
    }
    encode_ulid(&bytes)
}

fn encode_ulid(bytes: &[u8; 16]) -> String {
    let mut out = String::with_capacity(26);
    for index in 0..26 {
        let mut value = 0_u8;
        for offset in 0..5 {
            let bit_index = 129_i32 - (index * 5 + offset);
            let bit = if bit_index < 128 {
                (bytes[(bit_index / 8) as usize] >> (7 - (bit_index % 8))) & 1
            } else {
                0
            };
            value = (value << 1) | bit;
        }
        out.push(CROCKFORD[value as usize] as char);
    }
    out
}

/// New Agent-generated job id: no client-controlled path components.
pub fn new_job_id() -> String {
    format!("job_{}", ulid_now())
}

/// 32 random bytes as unpadded base64url (pairing token).
pub fn new_token() -> String {
    let bytes = random_bytes(32).unwrap_or_else(|_| vec![0_u8; 32]);
    base64url_encode(&bytes)
}

/// Unpadded base64url encoding.
pub fn base64url_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let byte0 = chunk[0];
        let byte1 = chunk.get(1).copied().unwrap_or(0);
        let byte2 = chunk.get(2).copied().unwrap_or(0);
        out.push(ALPHABET[(byte0 >> 2) as usize] as char);
        out.push(ALPHABET[(((byte0 & 0b11) << 4) | (byte1 >> 4)) as usize] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[(((byte1 & 0b1111) << 2) | (byte2 >> 6)) as usize] as char);
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[(byte2 & 0b111111) as usize] as char);
        }
    }
    out
}

/// Hostname for the Agent identity, sanitised to `[A-Za-z0-9._-]`.
pub fn hostname() -> String {
    let raw = std::env::var("HOSTNAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            std::process::Command::new("hostname")
                .output()
                .ok()
                .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        })
        .unwrap_or_default();
    sanitize_id(&raw, "build-agent")
}

/// Login user name, used by `doctor` and the root check.
pub fn username() -> Option<String> {
    std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .ok()
        .filter(|value| !value.trim().is_empty())
}

/// Whether the current process is root (the Agent refuses to run as root).
pub fn is_root() -> bool {
    std::process::Command::new("id")
        .arg("-u")
        .output()
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim() == "0")
        .unwrap_or(false)
}

/// Keep only safe identifier characters, replacing runs of others with '-'.
pub fn sanitize_id(value: &str, fallback: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
            out.push(ch);
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    let trimmed = out.trim_matches(|c: char| !c.is_ascii_alphanumeric());
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

/// Create a directory tree with owner-only permissions (`0700`).
pub fn ensure_private_dir(path: &Path) -> io::Result<()> {
    fs::create_dir_all(path)?;
    set_mode(path, 0o700)
}

/// Restrict an existing file to `0600` (no-op on non-Unix platforms).
pub fn set_private_file(path: &Path) -> io::Result<()> {
    set_mode(path, 0o600)
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(mode);
    fs::set_permissions(path, permissions)
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

/// Write a file atomically: temporary sibling then rename, `0600`.
pub fn write_atomic(path: &Path, contents: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension(format!("tmp.{}", std::process::id()));
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&temp)?;
        file.write_all(contents)?;
        file.flush()?;
    }
    set_private_file(&temp)?;
    fs::rename(&temp, path)?;
    Ok(())
}

/// Read and parse a JSON file.
pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> io::Result<T> {
    let text = fs::read_to_string(path)?;
    serde_json::from_str(&text).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

/// Serialise and write a JSON file atomically (`0600`).
pub fn write_json<T: serde::Serialize>(path: &Path, value: &T) -> io::Result<()> {
    let text = serde_json::to_vec_pretty(value)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    write_atomic(path, &text)
}

/// Remove a file/dir/symlink if it exists. Never follows symlinks.
pub fn remove_path_if_exists(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_dir() {
                fs::remove_dir_all(path)
            } else {
                fs::remove_file(path)
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// True when `child` resolves inside `parent`. Works for paths that do not exist
/// yet by canonicalising the longest existing ancestor and appending the rest.
pub fn path_is_within(child: &Path, parent: &Path) -> bool {
    let Ok(parent) = parent.canonicalize() else {
        return false;
    };
    let mut existing = child.to_path_buf();
    let mut suffix: Vec<std::ffi::OsString> = Vec::new();
    loop {
        if existing.exists() {
            let Ok(canonical) = existing.canonicalize() else {
                return false;
            };
            let mut resolved = canonical;
            for component in suffix.iter().rev() {
                if component == ".." {
                    if !resolved.pop() {
                        return false;
                    }
                } else {
                    resolved.push(component);
                }
            }
            return resolved.starts_with(&parent);
        }
        let Some(name) = existing.file_name().map(|name| name.to_os_string()) else {
            return false;
        };
        suffix.push(name);
        let Some(parent_path) = existing.parent().map(Path::to_path_buf) else {
            return false;
        };
        if parent_path == existing {
            return false;
        }
        existing = parent_path;
    }
}

/// Human-readable byte count for doctor output.
pub fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ulids_are_sortable_and_valid_job_ids() {
        let first = ulid_now();
        assert_eq!(first.len(), 26);
        std::thread::sleep(std::time::Duration::from_millis(3));
        let second = ulid_now();
        assert!(second > first, "{second} should sort after {first}");
        let job = new_job_id();
        assert!(job.starts_with("job_"));
        assert!(builder_core::protocol::valid_job_id(&job), "{job}");
    }

    #[test]
    fn ulid_encoding_matches_known_prefix() {
        // All-zero payload encodes to all-zero characters.
        let zero = encode_ulid(&[0_u8; 16]);
        assert_eq!(zero, "0".repeat(26));
    }

    #[test]
    fn base64url_encoding() {
        assert_eq!(base64url_encode(b""), "");
        assert_eq!(base64url_encode(b"f"), "Zg");
        assert_eq!(base64url_encode(b"fo"), "Zm8");
        assert_eq!(base64url_encode(b"foo"), "Zm9v");
        assert_eq!(base64url_encode(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64url_encode(&[0xfb, 0xff]), "-_8");
        let token = new_token();
        assert!(!token.contains('='));
        assert!(token.len() >= 40);
    }

    #[test]
    fn ids_are_sanitised() {
        assert_eq!(sanitize_id("mac-mini.local", "x"), "mac-mini.local");
        assert_eq!(sanitize_id("Mac mini (office)", "x"), "Mac-mini-office");
        assert_eq!(sanitize_id("   ", "fallback"), "fallback");
        assert_eq!(sanitize_id("", "fallback"), "fallback");
    }

    #[test]
    fn atomic_json_round_trip_is_private() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/state.json");
        #[derive(serde::Serialize, serde::Deserialize, PartialEq, Debug)]
        struct State {
            value: u32,
        }
        write_json(&path, &State { value: 7 }).unwrap();
        assert_eq!(read_json::<State>(&path).unwrap(), State { value: 7 });
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
    }

    #[test]
    fn containment_check() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        assert!(path_is_within(&root.join("build/game/x"), root));
        assert!(path_is_within(root, root));
        assert!(!path_is_within(Path::new("/etc/passwd"), root));
        assert!(!path_is_within(&root.join("../escaped"), root));
    }

    #[test]
    fn human_bytes_formatting() {
        assert_eq!(human_bytes(0), "0 B");
        assert_eq!(human_bytes(512), "512 B");
        assert_eq!(human_bytes(1024), "1.0 KiB");
        assert_eq!(human_bytes(20 * 1024 * 1024 * 1024), "20.0 GiB");
    }
}
