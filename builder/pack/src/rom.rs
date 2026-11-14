//! ROM container detection from headers only.
//!
//! Supported containers (decrypted, user-owned ROMs):
//!
//! - NCSD (`.3ds`, `.cci`): the 0x200-byte NCSD header at offset 0, then the
//!   first NCCH partition (the game executable) at the partition-0 offset.
//! - Raw NCCH (`.ncch`, `.cxi`, `.app`): one NCCH header at offset 0.
//!
//! A CIA is **not** parsed by this MVP: the title ID lives in the ticket and
//! the executable is encrypted; the desktop flow requires the decrypted
//! `.3ds`/`.cci` the existing AOT build scripts already consume. See
//! docs/desktop-aot.md.
//!
//! Only the headers are read (a few KiB), never the whole ROM: a 3DS ROM is
//! several gigabytes and importing must stay instant and leave no copy behind.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::error::{PackError, Result};

/// NCSD container magic, at header offset 0x100.
pub const NCSD_MAGIC: &[u8] = b"NCSD";
/// NCCH header magic, at offset 0x100 of the NCCH header (or of partition 0).
pub const NCCH_MAGIC: &[u8] = b"NCCH";
/// Size of an NCSD header and of an NCCH header.
pub const HEADER_LEN: usize = 0x200;
/// NCSD partition table offset (partition-0 offset, in media units).
pub const NCSD_PARTITION_OFFSET_AT: usize = 0x120;
/// NCSD title ID field offset.
pub const NCSD_TITLE_ID_AT: usize = 0x108;
/// NCCH program ID (title ID) field offset.
pub const NCCH_PROGRAM_ID_AT: usize = 0x118;
/// NCCH product code field offset.
pub const NCCH_PRODUCT_CODE_AT: usize = 0x150;
/// NCCH title version field offset.
pub const NCCH_VERSION_AT: usize = 0x112;
/// NCCH content size field offset (in media units of 512 bytes).
pub const NCCH_CONTENT_SIZE_AT: usize = 0x104;
/// One media unit is 512 bytes.
pub const MEDIA_UNIT: u64 = 0x200;
/// Upper 32 bits of a normal application title ID (`0004 0000 ...`).
pub const APPLICATION_TITLE_PREFIX: u64 = 0x0004_0000;

/// Which container the detector recognised.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RomContainer {
    /// NCSD cartridge image (`.3ds`, `.cci`).
    Ncsd,
    /// A single raw NCCH partition (`.ncch`, `.cxi`, `.app`).
    Ncch,
}

/// Metadata detected from one ROM. Deliberately contains no game content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RomInfo {
    /// The ROM the user selected (never copied).
    pub path: PathBuf,
    /// Container the headers came from.
    pub container: RomContainer,
    /// Canonical 16 upper-case hex title ID, e.g. `0004000000055E00`.
    #[serde(rename = "titleID")]
    pub title_id: String,
    /// Product code from the NCCH header, e.g. `CTR-P-EK2A` (optional).
    pub product_code: Option<String>,
    /// Suggested display name (file name stem); the user can override it.
    pub display_name: String,
    /// Size of the ROM file on disk.
    pub bytes: u64,
    /// Size of the NCCH content in bytes (content-size field * 512).
    pub content_bytes: Option<u64>,
    /// NCCH title version.
    pub title_version: Option<u16>,
}

impl RomInfo {
    /// Suggested build slug: ASCII lower-case name plus the last 8 title ID
    /// digits, e.g. `pokemon-y-00055e00`. Unique per title ID and safe for the
    /// existing scripts' name rule `[A-Za-z0-9._-]`.
    pub fn build_slug(&self) -> String {
        crate::plan::slug_for(&self.display_name, &self.title_id)
    }
}

/// Detect a ROM's metadata by reading its headers.
///
/// Errors are actionable and name the file; no ROM content is read beyond the
/// NCSD header and one NCCH header.
pub fn detect_rom(path: &Path) -> Result<RomInfo> {
    let metadata = std::fs::metadata(path).map_err(|error| PackError::io(path, error))?;
    if !metadata.is_file() {
        return Err(PackError::invalid(format!(
            "{}: not a regular file",
            path.display()
        )));
    }
    let len = metadata.len();
    if len < HEADER_LEN as u64 {
        return Err(PackError::invalid(format!(
            "{}: too small to be a 3DS ROM ({} bytes; expected at least {} bytes of header)",
            path.display(),
            len,
            HEADER_LEN
        )));
    }

    let mut file = File::open(path).map_err(|error| PackError::io(path, error))?;
    let mut first = [0_u8; HEADER_LEN];
    read_at(&mut file, 0, &mut first, path)?;

    let display_name = display_name_from_path(path);
    if &first[0x100..0x104] == NCSD_MAGIC {
        detect_ncsd(path, len, &first, &mut file, display_name)
    } else if &first[0x100..0x104] == NCCH_MAGIC {
        let ncch = parse_ncch_header(&first, path, 0)?;
        rom_from_ncch(path, RomContainer::Ncch, len, ncch, display_name)
    } else {
        Err(PackError::invalid(format!(
            "{}: not a decrypted 3DS ROM this pipeline can read (no NCSD magic at 0x100 and no NCCH magic). \
             Expected a decrypted .3ds/.cci (NCSD) or a raw NCCH (.ncch/.cxi/.app). \
             CIA/encrypted containers are not supported by this MVP; see docs/desktop-aot.md.",
            path.display()
        )))
    }
}

fn detect_ncsd(
    path: &Path,
    len: u64,
    header: &[u8; HEADER_LEN],
    file: &mut File,
    display_name: String,
) -> Result<RomInfo> {
    let media_title_id = read_u64_le(header, NCSD_TITLE_ID_AT);
    if media_title_id == 0 {
        return Err(PackError::invalid(format!(
            "{}: NCSD header has a zero title ID (not a game cartridge image)",
            path.display()
        )));
    }
    let partition_units = read_u32_le(header, NCSD_PARTITION_OFFSET_OFFSET);
    if partition_units == 0 {
        return Err(PackError::invalid(format!(
            "{}: NCSD header has no partition-0 offset; not a usable game image",
            path.display()
        )));
    }
    let partition_offset = partition_units as u64 * MEDIA_UNIT;
    if partition_offset + HEADER_LEN as u64 > len {
        return Err(PackError::invalid(format!(
            "{}: NCSD partition-0 offset 0x{:x} is beyond the end of the file ({} bytes); truncated or corrupt dump",
            path.display(),
            partition_offset,
            len
        )));
    }
    let mut ncch_header = [0_u8; HEADER_LEN];
    read_at(file, partition_offset, &mut ncch_header, path)?;
    let ncch = parse_ncch_header(&ncch_header, path, partition_offset)?;
    if ncch.title_id != media_title_id {
        return Err(PackError::invalid(format!(
            "{}: NCSD header title ID {:016X} does not match the NCCH program ID {:016X}; refusing to import a mismatched image",
            path.display(),
            media_title_id,
            ncch.title_id
        )));
    }
    rom_from_ncch(path, RomContainer::Ncsd, len, ncch, display_name)
}

struct NcchHeader {
    title_id: u64,
    product_code: Option<String>,
    content_bytes: Option<u64>,
    title_version: Option<u16>,
}

fn parse_ncch_header(header: &[u8; HEADER_LEN], path: &Path, offset: u64) -> Result<NcchHeader> {
    if &header[0x100..0x104] != NCCH_MAGIC {
        return Err(PackError::invalid(format!(
            "{}: no NCCH header at 0x{:x}; partition is not a game executable",
            path.display(),
            offset
        )));
    }
    let title_id = read_u64_le(header, NCCH_PROGRAM_ID_AT);
    if !is_application_title(title_id) {
        return Err(PackError::invalid(format!(
            "{}: title ID {:016X} at 0x{:x} is not a game application title (expected the 00040000 high word)",
            path.display(),
            title_id,
            offset + NCCH_PROGRAM_ID_AT as u64
        )));
    }
    let product_code =
        parse_product_code(&header[NCCH_PRODUCT_CODE_AT..NCCH_PRODUCT_CODE_AT + 0x10]);
    let content_units = read_u32_le(header, NCCH_CONTENT_SIZE_AT) as u64;
    let content_bytes = if content_units == 0 {
        None
    } else {
        Some(content_units * MEDIA_UNIT)
    };
    let version = read_u16_le(header, NCCH_VERSION_AT);
    Ok(NcchHeader {
        title_id,
        product_code,
        content_bytes,
        title_version: Some(version),
    })
}

fn rom_from_ncch(
    path: &Path,
    container: RomContainer,
    len: u64,
    header: NcchHeader,
    display_name: String,
) -> Result<RomInfo> {
    Ok(RomInfo {
        path: path.to_path_buf(),
        container,
        title_id: format_title_id(header.title_id),
        product_code: header.product_code,
        display_name,
        bytes: len,
        content_bytes: header.content_bytes,
        title_version: header.title_version,
    })
}

/// The NCSD partition-0 offset field offset (partition table starts at 0x120).
const NCSD_PARTITION_OFFSET_OFFSET: usize = NCSD_PARTITION_OFFSET_AT;

/// Canonical 16 upper-case hex title ID.
pub fn format_title_id(title_id: u64) -> String {
    format!("{title_id:016X}")
}

/// Whether a raw title ID is a normal application title (`00040000...`).
pub fn is_application_title(title_id: u64) -> bool {
    (title_id >> 32) & 0xFFFF_FFFF == APPLICATION_TITLE_PREFIX
}

/// Normalise a user-supplied title ID: optional `0x`/`0X` prefix, lower or
/// upper case hex, trims surrounding whitespace. Returns the canonical
/// 16-digit upper-case form.
pub fn canonical_title_id(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    let without_prefix = trimmed
        .strip_prefix("0x")
        .or_else(|| trimmed.strip_prefix("0X"))
        .unwrap_or(trimmed);
    if without_prefix.len() != 16 || !without_prefix.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(PackError::invalid(format!(
            "invalid title ID '{raw}' (expected 16 hex digits, e.g. 0004000000055E00)"
        )));
    }
    let value = u64::from_str_radix(without_prefix, 16)
        .map_err(|_| PackError::invalid(format!("invalid title ID '{raw}'")))?;
    if !is_application_title(value) {
        return Err(PackError::invalid(format!(
            "title ID {without_prefix} is not a game application title (expected the 00040000 high word)"
        )));
    }
    Ok(format_title_id(value))
}

/// Suggested display name from a ROM file name (stem, control characters
/// replaced, empty fallback `game`).
pub fn display_name_from_path(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("game");
    let cleaned: String = stem
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() {
        "game".to_string()
    } else {
        cleaned.to_string()
    }
}

fn parse_product_code(raw: &[u8]) -> Option<String> {
    let end = raw.iter().position(|byte| *byte == 0).unwrap_or(raw.len());
    let text = std::str::from_utf8(&raw[..end]).ok()?;
    let trimmed = text.trim();
    if trimmed.is_empty() || !trimmed.chars().all(|c| c.is_ascii_graphic() || c == ' ') {
        return None;
    }
    Some(trimmed.to_string())
}

fn read_u16_le(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}

fn read_u32_le(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

fn read_u64_le(bytes: &[u8], offset: usize) -> u64 {
    let mut value = [0_u8; 8];
    value.copy_from_slice(&bytes[offset..offset + 8]);
    u64::from_le_bytes(value)
}

fn read_at(file: &mut File, offset: u64, buffer: &mut [u8], path: &Path) -> Result<()> {
    file.seek(SeekFrom::Start(offset))
        .map_err(|error| PackError::io(path, error))?;
    file.read_exact(buffer)
        .map_err(|error| PackError::io(path, error))
}

// --- tests -----------------------------------------------------------------

#[cfg(test)]
pub(crate) mod test_support {
    //! Synthetic NCSD/NCCH images for unit tests. They contain no game data:
    //! headers + zero-filled bytes.

    use super::*;

    /// Build a synthetic NCSD image with partition 0 at 0x4000.
    pub fn synthetic_ncsd(title_id: u64, product_code: &str, content_units: u32) -> Vec<u8> {
        let partition_offset = 0x4000_usize;
        let mut bytes = vec![0_u8; partition_offset + HEADER_LEN];
        let media_units = (bytes.len() / 512) as u32;
        bytes[0x100..0x104].copy_from_slice(NCSD_MAGIC);
        bytes[0x104..0x108].copy_from_slice(&media_units.to_le_bytes());
        bytes[NCSD_TITLE_ID_AT..NCSD_TITLE_ID_AT + 8].copy_from_slice(&title_id.to_le_bytes());
        bytes[NCSD_PARTITION_OFFSET_OFFSET..NCSD_PARTITION_OFFSET_OFFSET + 4]
            .copy_from_slice(&((partition_offset / 512) as u32).to_le_bytes());
        let ncch = &mut bytes[partition_offset..];
        ncch[0x100..0x104].copy_from_slice(NCCH_MAGIC);
        ncch[NCCH_CONTENT_SIZE_AT..NCCH_CONTENT_SIZE_AT + 4]
            .copy_from_slice(&content_units.to_le_bytes());
        ncch[NCCH_VERSION_AT..NCCH_VERSION_AT + 2].copy_from_slice(&2_u16.to_le_bytes());
        ncch[NCCH_PROGRAM_ID_AT..NCCH_PROGRAM_ID_AT + 8].copy_from_slice(&title_id.to_le_bytes());
        let code = product_code.as_bytes();
        ncch[NCCH_PRODUCT_CODE_AT..NCCH_PRODUCT_CODE_AT + code.len()].copy_from_slice(code);
        bytes
    }

    /// Build a synthetic raw NCCH image.
    pub fn synthetic_ncch(title_id: u64, product_code: &str) -> Vec<u8> {
        let mut bytes = vec![0_u8; HEADER_LEN];
        bytes[0x100..0x104].copy_from_slice(NCCH_MAGIC);
        bytes[NCCH_CONTENT_SIZE_AT..NCCH_CONTENT_SIZE_AT + 4]
            .copy_from_slice(&512_u32.to_le_bytes());
        bytes[NCCH_VERSION_AT..NCCH_VERSION_AT + 2].copy_from_slice(&1_u16.to_le_bytes());
        bytes[NCCH_PROGRAM_ID_AT..NCCH_PROGRAM_ID_AT + 8].copy_from_slice(&title_id.to_le_bytes());
        let code = product_code.as_bytes();
        bytes[NCCH_PRODUCT_CODE_AT..NCCH_PRODUCT_CODE_AT + code.len()].copy_from_slice(code);
        bytes
    }

    /// Write synthetic ROM bytes to a path.
    pub fn write_rom(path: &Path, bytes: &[u8]) {
        std::fs::write(path, bytes).expect("write synthetic ROM");
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use tempfile::tempdir;

    const POKEMON_Y: u64 = 0x0004_0000_0005_5E00;

    #[test]
    fn detects_ncsd_title_and_product_code() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("Pokemon Y.cci");
        write_rom(&path, &synthetic_ncsd(POKEMON_Y, "CTR-P-EK2A", 1024));
        let info = detect_rom(&path).unwrap();
        assert_eq!(info.container, RomContainer::Ncsd);
        assert_eq!(info.title_id, "0004000000055E00");
        assert_eq!(info.product_code.as_deref(), Some("CTR-P-EK2A"));
        assert_eq!(info.display_name, "Pokemon Y");
        assert_eq!(info.title_version, Some(2));
        assert_eq!(info.content_bytes, Some(1024 * 512));
        assert_eq!(info.bytes, 0x4200);
        assert_eq!(info.build_slug(), "pokemon-y-00055e00");
    }

    #[test]
    fn detects_raw_ncch() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("game.ncch");
        write_rom(&path, &synthetic_ncch(0x0004_0000_0011_C500, "CTR-P-ECLA"));
        let info = detect_rom(&path).unwrap();
        assert_eq!(info.container, RomContainer::Ncch);
        assert_eq!(info.title_id, "000400000011C500");
        assert_eq!(info.product_code.as_deref(), Some("CTR-P-ECLA"));
        assert_eq!(info.display_name, "game");
        assert_eq!(info.title_version, Some(1));
    }

    #[test]
    fn falls_back_when_product_code_is_blank_or_invalid() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("blank.cci");
        write_rom(&path, &synthetic_ncsd(POKEMON_Y, "", 1));
        assert_eq!(detect_rom(&path).unwrap().product_code, None);

        let path = dir.path().join("bad.cci");
        let mut bad = synthetic_ncsd(POKEMON_Y, "", 1);
        bad[0x4000 + NCCH_PRODUCT_CODE_AT] = 0x01;
        write_rom(&path, &bad);
        assert_eq!(detect_rom(&path).unwrap().product_code, None);
    }

    #[test]
    fn rejects_unknown_or_truncated_files() {
        let dir = tempdir().unwrap();
        let small = dir.path().join("small.3ds");
        std::fs::write(&small, [0_u8; 16]).unwrap();
        assert!(detect_rom(&small)
            .unwrap_err()
            .to_string()
            .contains("too small"));

        let unknown = dir.path().join("unknown.3ds");
        std::fs::write(&unknown, vec![0_u8; 0x400]).unwrap();
        let message = detect_rom(&unknown).unwrap_err().to_string();
        assert!(message.contains("not a decrypted 3DS ROM"), "{message}");

        let truncated = dir.path().join("truncated.cci");
        let mut bytes = synthetic_ncsd(POKEMON_Y, "CTR-P-EK2A", 1);
        bytes.truncate(0x100);
        bytes.resize(0x400, 0);
        // Restore a valid-looking NCSD header pointing past EOF.
        bytes[0x100..0x104].copy_from_slice(NCSD_MAGIC);
        bytes[NCSD_TITLE_ID_AT..NCSD_TITLE_ID_AT + 8].copy_from_slice(&POKEMON_Y.to_le_bytes());
        bytes[NCSD_PARTITION_OFFSET_OFFSET..NCSD_PARTITION_OFFSET_OFFSET + 4]
            .copy_from_slice(&0xFFFF_u32.to_le_bytes());
        write_rom(&truncated, &bytes);
        assert!(detect_rom(&truncated)
            .unwrap_err()
            .to_string()
            .contains("beyond the end"));
    }

    #[test]
    fn rejects_non_application_titles_and_mismatches() {
        let dir = tempdir().unwrap();
        // Update title (0004000E...) is not a game executable.
        let update = dir.path().join("update.ncch");
        write_rom(
            &update,
            &synthetic_ncch(0x0004_000E_0005_5E00, "CTR-P-EK2A"),
        );
        assert!(detect_rom(&update)
            .unwrap_err()
            .to_string()
            .contains("not a game application title"));

        // NCSD media title different from the NCCH program ID.
        let mismatch = dir.path().join("mismatch.cci");
        let mut bytes = synthetic_ncsd(POKEMON_Y, "CTR-P-EK2A", 1);
        bytes[NCSD_TITLE_ID_AT..NCSD_TITLE_ID_AT + 8]
            .copy_from_slice(&0x0004_0000_0011_C500_u64.to_le_bytes());
        write_rom(&mismatch, &bytes);
        assert!(detect_rom(&mismatch)
            .unwrap_err()
            .to_string()
            .contains("does not match"));
    }

    #[test]
    fn title_id_helpers_normalise() {
        assert_eq!(
            canonical_title_id("0004000000055E00").unwrap(),
            "0004000000055E00"
        );
        assert_eq!(
            canonical_title_id("0x0004000000055e00").unwrap(),
            "0004000000055E00"
        );
        assert_eq!(
            canonical_title_id(" 0004000000055E00 ").unwrap(),
            "0004000000055E00"
        );
        assert!(canonical_title_id("0004000000055E0").is_err());
        assert!(canonical_title_id("zzzz").is_err());
        assert!(canonical_title_id("0004000E00055E00").is_err());
        assert_eq!(
            display_name_from_path(Path::new("/x/My Game.cci")),
            "My Game"
        );
        assert_eq!(display_name_from_path(Path::new("/x/.hidden")), ".hidden");
        assert_eq!(display_name_from_path(Path::new("/")), "game");
    }
}
