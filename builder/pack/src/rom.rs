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
//! builder/README.md.
//!
//! Only the headers are read (a few KiB), never the whole ROM: a 3DS ROM is
//! several gigabytes and importing must stay instant and leave no copy behind.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::error::{PackError, Result};
use crate::smdh;

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
/// NCCH ExeFS offset field offset (in media units of 512 bytes).
pub const NCCH_EXEFS_OFFSET_AT: usize = 0x1A0;
/// NCCH ExeFS size field offset (in media units of 512 bytes).
pub const NCCH_EXEFS_SIZE_AT: usize = 0x1A4;
/// Number of entries in the ExeFS header.
pub const EXEFS_ENTRY_COUNT: usize = 10;
/// Size of one ExeFS entry (`name[8]`, offset u32, size u32).
pub const EXEFS_ENTRY_SIZE: usize = 0x10;
/// Size of the ExeFS header (the entry table); entry data follows it.
pub const EXEFS_HEADER_SIZE: usize = 0x200;
/// ExeFS entry that carries the SMDH (localized titles, publisher, icon).
pub const EXEFS_ICON_ENTRY: &str = "icon";
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
    /// Suggested display name: the English SMDH title when the ROM has one,
    /// else the file name stem; the user can override it with `--display-name`.
    pub display_name: String,
    /// Localized short titles from the SMDH (`en`, `ja`, ...), sorted by
    /// language key. Empty when the ROM has no readable ExeFS icon/SMDH.
    #[serde(
        rename = "displayNames",
        default,
        skip_serializing_if = "BTreeMap::is_empty"
    )]
    pub display_names: BTreeMap<String, String>,
    /// Publisher from the SMDH; empty when unknown.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub publisher: String,
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
        let ncch_offset = 0;
        let ncch = parse_ncch_header(&first, path, ncch_offset)?;
        rom_info_from_ncch(
            path,
            RomContainer::Ncch,
            len,
            ncch,
            ncch_offset,
            &mut file,
            display_name,
        )
    } else {
        Err(PackError::invalid(format!(
            "{}: not a decrypted 3DS ROM this pipeline can read (no NCSD magic at 0x100 and no NCCH magic). \
             Expected a decrypted .3ds/.cci (NCSD) or a raw NCCH (.ncch/.cxi/.app). \
             CIA/encrypted containers are not supported by this MVP; see builder/README.md.",
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
    rom_info_from_ncch(
        path,
        RomContainer::Ncsd,
        len,
        ncch,
        partition_offset,
        file,
        display_name,
    )
}

struct NcchHeader {
    title_id: u64,
    product_code: Option<String>,
    content_bytes: Option<u64>,
    title_version: Option<u16>,
    /// ExeFS offset in bytes relative to the NCCH start (None when zero).
    exefs_offset: Option<u64>,
    /// ExeFS size in bytes (None when zero).
    exefs_size: Option<u64>,
}

fn parse_ncch_header(header: &[u8; HEADER_LEN], path: &Path, offset: u64) -> Result<NcchHeader> {
    if &header[0x100..0x104] != NCCH_MAGIC {
        return Err(PackError::invalid(format!(
            "{}: no NCCH header at 0x{:x}; partition is not a game executable",
            path.display(),
            offset
        )));
    }
    let ncch = parse_ncch_fields(header);
    if !is_application_title(ncch.title_id) {
        return Err(PackError::invalid(format!(
            "{}: title ID {:016X} at 0x{:x} is not a game application title (expected the 00040000 high word)",
            path.display(),
            ncch.title_id,
            offset + NCCH_PROGRAM_ID_AT as u64
        )));
    }
    Ok(ncch)
}

/// Parse the NCCH header fields without validating the title kind, so the
/// best-effort SMDH reader can reuse them.
fn parse_ncch_fields(header: &[u8; HEADER_LEN]) -> NcchHeader {
    let product_code =
        parse_product_code(&header[NCCH_PRODUCT_CODE_AT..NCCH_PRODUCT_CODE_AT + 0x10]);
    let content_units = read_u32_le(header, NCCH_CONTENT_SIZE_AT) as u64;
    let content_bytes = if content_units == 0 {
        None
    } else {
        Some(content_units * MEDIA_UNIT)
    };
    let version = read_u16_le(header, NCCH_VERSION_AT);
    let exefs_offset_units = u64::from(read_u32_le(header, NCCH_EXEFS_OFFSET_AT));
    let exefs_size_units = u64::from(read_u32_le(header, NCCH_EXEFS_SIZE_AT));
    let (exefs_offset, exefs_size) = if exefs_offset_units == 0 || exefs_size_units == 0 {
        (None, None)
    } else {
        (
            Some(exefs_offset_units * MEDIA_UNIT),
            Some(exefs_size_units * MEDIA_UNIT),
        )
    };
    NcchHeader {
        title_id: read_u64_le(header, NCCH_PROGRAM_ID_AT),
        product_code,
        content_bytes,
        title_version: Some(version),
        exefs_offset,
        exefs_size,
    }
}

fn rom_info_from_ncch(
    path: &Path,
    container: RomContainer,
    len: u64,
    ncch: NcchHeader,
    ncch_offset: u64,
    file: &mut File,
    fallback_display_name: String,
) -> Result<RomInfo> {
    let smdh_bytes = read_smdh_at(file, len, ncch_offset, &ncch, path)?;
    let metadata = smdh_bytes.as_deref().and_then(smdh::parse);
    let display_name = metadata
        .as_ref()
        .and_then(smdh::SmdhMetadata::english_title)
        .map(str::to_string)
        .unwrap_or(fallback_display_name);
    let (display_names, publisher) = match metadata {
        Some(metadata) => (metadata.display_names, metadata.publisher),
        None => (BTreeMap::new(), String::new()),
    };
    Ok(RomInfo {
        path: path.to_path_buf(),
        container,
        title_id: format_title_id(ncch.title_id),
        product_code: ncch.product_code,
        display_name,
        display_names,
        publisher,
        bytes: len,
        content_bytes: ncch.content_bytes,
        title_version: ncch.title_version,
    })
}

/// Read the SMDH (the `icon` ExeFS entry) of an already-parsed NCCH.
///
/// Best effort: a ROM without an ExeFS, without an `icon` entry, or with an
/// entry pointing outside the file simply returns `None`; a malformed or
/// truncated container never makes metadata detection fail or panic.
fn read_smdh_at(
    file: &mut File,
    len: u64,
    ncch_offset: u64,
    ncch: &NcchHeader,
    path: &Path,
) -> Result<Option<Vec<u8>>> {
    let (Some(exefs_relative), Some(exefs_size)) = (ncch.exefs_offset, ncch.exefs_size) else {
        return Ok(None);
    };
    let exefs_offset = ncch_offset.saturating_add(exefs_relative);
    let exefs_end = exefs_offset.saturating_add(exefs_size);
    if exefs_offset.saturating_add(EXEFS_HEADER_SIZE as u64) > len {
        return Ok(None);
    }
    let mut header = [0_u8; EXEFS_HEADER_SIZE];
    read_at(file, exefs_offset, &mut header, path)?;
    for index in 0..EXEFS_ENTRY_COUNT {
        let base = index * EXEFS_ENTRY_SIZE;
        let name_end = header[base..base + 8]
            .iter()
            .position(|byte| *byte == 0)
            .unwrap_or(8);
        if &header[base..base + name_end] != EXEFS_ICON_ENTRY.as_bytes() {
            continue;
        }
        let data_offset = u64::from(read_u32_le(&header, base + 8));
        let data_size = u64::from(read_u32_le(&header, base + 12));
        if data_size == 0 {
            return Ok(None);
        }
        let entry_offset = exefs_offset + EXEFS_HEADER_SIZE as u64 + data_offset;
        if entry_offset.saturating_add(data_size) > len
            || (exefs_size != 0 && entry_offset.saturating_add(data_size) > exefs_end)
        {
            return Ok(None);
        }
        let read_len = data_size.min(smdh::FULL_SMDH_SIZE as u64) as usize;
        if read_len < smdh::TITLE_TABLE_END {
            return Ok(None);
        }
        let mut bytes = vec![0_u8; read_len];
        read_at(file, entry_offset, &mut bytes, path)?;
        if &bytes[..smdh::SMDH_MAGIC.len()] != smdh::SMDH_MAGIC {
            return Ok(None);
        }
        return Ok(Some(bytes));
    }
    Ok(None)
}

/// Read the SMDH bytes of a ROM (best effort, for cover extraction).
///
/// Re-reads the container and NCCH headers (a few hundred bytes) and then the
/// 14 KiB `icon` entry; the rest of the ROM is never read or hashed. Returns
/// `Ok(None)` for unsupported containers, a missing ExeFS/`icon` entry, or
/// truncated/invalid data.
pub fn read_smdh_bytes(path: &Path) -> Result<Option<Vec<u8>>> {
    let metadata = std::fs::metadata(path).map_err(|error| PackError::io(path, error))?;
    let len = metadata.len();
    if len < HEADER_LEN as u64 {
        return Ok(None);
    }
    let mut file = File::open(path).map_err(|error| PackError::io(path, error))?;
    let mut first = [0_u8; HEADER_LEN];
    read_at(&mut file, 0, &mut first, path)?;
    let (ncch_offset, ncch_header) = if &first[0x100..0x104] == NCSD_MAGIC {
        let units = u64::from(read_u32_le(&first, NCSD_PARTITION_OFFSET_AT));
        if units == 0 {
            return Ok(None);
        }
        let offset = units * MEDIA_UNIT;
        if offset.saturating_add(HEADER_LEN as u64) > len {
            return Ok(None);
        }
        let mut header = [0_u8; HEADER_LEN];
        read_at(&mut file, offset, &mut header, path)?;
        (offset, header)
    } else if &first[0x100..0x104] == NCCH_MAGIC {
        (0, first)
    } else {
        return Ok(None);
    };
    if &ncch_header[0x100..0x104] != NCCH_MAGIC {
        return Ok(None);
    }
    let ncch = parse_ncch_fields(&ncch_header);
    read_smdh_at(&mut file, len, ncch_offset, &ncch, path)
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

    /// Build a synthetic NCSD image whose ExeFS contains one `icon` entry
    /// carrying `smdh`. Headers and zero padding only: no real game data.
    pub fn synthetic_ncsd_with_smdh(title_id: u64, product_code: &str, smdh: &[u8]) -> Vec<u8> {
        let partition_offset = 0x4000_usize;
        let exefs_relative = 0x400_u64;
        let mut bytes = synthetic_exefs_image(
            partition_offset,
            exefs_relative,
            title_id,
            product_code,
            smdh,
        );
        let media_units = (bytes.len() / 512) as u32;
        bytes[0x100..0x104].copy_from_slice(NCSD_MAGIC);
        bytes[0x104..0x108].copy_from_slice(&media_units.to_le_bytes());
        bytes[NCSD_TITLE_ID_AT..NCSD_TITLE_ID_AT + 8].copy_from_slice(&title_id.to_le_bytes());
        bytes[NCSD_PARTITION_OFFSET_OFFSET..NCSD_PARTITION_OFFSET_OFFSET + 4]
            .copy_from_slice(&((partition_offset / 512) as u32).to_le_bytes());
        bytes
    }

    /// Build a synthetic raw NCCH image whose ExeFS contains one `icon` entry.
    pub fn synthetic_ncch_with_smdh(title_id: u64, product_code: &str, smdh: &[u8]) -> Vec<u8> {
        synthetic_exefs_image(0, 0x400, title_id, product_code, smdh)
    }

    /// Lay out an NCCH header + ExeFS header + `icon` data at `ncch_offset`.
    fn synthetic_exefs_image(
        ncch_offset: usize,
        exefs_relative: u64,
        title_id: u64,
        product_code: &str,
        smdh: &[u8],
    ) -> Vec<u8> {
        let exefs_size = EXEFS_HEADER_SIZE as u64 + smdh.len() as u64;
        let end = ncch_offset as u64 + exefs_relative + exefs_size;
        let len = (end.div_ceil(0x200) * 0x200) as usize;
        let mut bytes = vec![0_u8; len];
        let ncch = &mut bytes[ncch_offset..];
        ncch[0x100..0x104].copy_from_slice(NCCH_MAGIC);
        ncch[NCCH_PROGRAM_ID_AT..NCCH_PROGRAM_ID_AT + 8].copy_from_slice(&title_id.to_le_bytes());
        let code = product_code.as_bytes();
        ncch[NCCH_PRODUCT_CODE_AT..NCCH_PRODUCT_CODE_AT + code.len()].copy_from_slice(code);
        ncch[NCCH_EXEFS_OFFSET_AT..NCCH_EXEFS_OFFSET_AT + 4]
            .copy_from_slice(&((exefs_relative / 512) as u32).to_le_bytes());
        ncch[NCCH_EXEFS_SIZE_AT..NCCH_EXEFS_SIZE_AT + 4]
            .copy_from_slice(&((exefs_size.div_ceil(0x200)) as u32).to_le_bytes());
        let exefs = ncch_offset + exefs_relative as usize;
        bytes[exefs..exefs + 4].copy_from_slice(b"icon");
        bytes[exefs + 8..exefs + 12].copy_from_slice(&0_u32.to_le_bytes());
        bytes[exefs + 12..exefs + 16].copy_from_slice(&(smdh.len() as u32).to_le_bytes());
        bytes[exefs + EXEFS_HEADER_SIZE..exefs + EXEFS_HEADER_SIZE + smdh.len()]
            .copy_from_slice(smdh);
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
    use crate::smdh::test_support::synthetic_smdh;
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

    fn test_smdh() -> Vec<u8> {
        synthetic_smdh(&[(0, "テスト", "Example"), (1, "Test Game", "Example")])
    }

    #[test]
    fn reads_smdh_titles_publisher_and_icon() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("game.cci");
        let smdh = test_smdh();
        write_rom(
            &path,
            &synthetic_ncsd_with_smdh(POKEMON_Y, "CTR-P-EK2A", &smdh),
        );
        let info = detect_rom(&path).unwrap();
        assert_eq!(info.display_name, "Test Game");
        assert_eq!(
            info.display_names.get("en").map(String::as_str),
            Some("Test Game")
        );
        assert_eq!(
            info.display_names.get("ja").map(String::as_str),
            Some("テスト")
        );
        assert_eq!(info.publisher, "Example");
        let bytes = read_smdh_bytes(&path).unwrap().expect("SMDH bytes");
        assert_eq!(bytes.len(), smdh.len());
        assert!(smdh::large_icon(&bytes).is_some());
    }

    #[test]
    fn reads_smdh_from_raw_ncch() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("game.ncch");
        write_rom(
            &path,
            &synthetic_ncch_with_smdh(0x0004_0000_0011_C500, "CTR-P-ECLA", &test_smdh()),
        );
        let info = detect_rom(&path).unwrap();
        assert_eq!(info.display_name, "Test Game");
        assert_eq!(info.publisher, "Example");
        assert_eq!(info.product_code.as_deref(), Some("CTR-P-ECLA"));
    }

    #[test]
    fn malformed_or_truncated_smdh_falls_back_safely() {
        let dir = tempdir().unwrap();
        let mut bad_magic = test_smdh();
        bad_magic[0..4].copy_from_slice(b"XXXX");
        let path = dir.path().join("bad-icon.cci");
        write_rom(
            &path,
            &synthetic_ncsd_with_smdh(POKEMON_Y, "CTR-P-EK2A", &bad_magic),
        );
        let info = detect_rom(&path).unwrap();
        assert_eq!(info.display_name, "bad-icon");
        assert!(info.display_names.is_empty());
        assert!(info.publisher.is_empty());
        assert!(read_smdh_bytes(&path).unwrap().is_none());

        let path = dir.path().join("truncated-icon.cci");
        let mut bytes = synthetic_ncsd_with_smdh(POKEMON_Y, "CTR-P-EK2A", &test_smdh());
        bytes.truncate(bytes.len() - 0x400);
        write_rom(&path, &bytes);
        let info = detect_rom(&path).unwrap();
        assert_eq!(info.display_name, "truncated-icon");
        assert!(info.display_names.is_empty());
        assert!(read_smdh_bytes(&path).unwrap().is_none());

        let path = dir.path().join("bad-exefs.cci");
        let mut bytes = synthetic_ncsd(POKEMON_Y, "CTR-P-EK2A", 1);
        bytes[0x4000 + NCCH_EXEFS_OFFSET_AT..0x4000 + NCCH_EXEFS_OFFSET_AT + 4]
            .copy_from_slice(&0xFFFF_u32.to_le_bytes());
        bytes[0x4000 + NCCH_EXEFS_SIZE_AT..0x4000 + NCCH_EXEFS_SIZE_AT + 4]
            .copy_from_slice(&1_u32.to_le_bytes());
        write_rom(&path, &bytes);
        let info = detect_rom(&path).unwrap();
        assert!(info.display_names.is_empty());
        assert!(read_smdh_bytes(&path).unwrap().is_none());
    }

    #[test]
    fn read_smdh_bytes_is_none_for_unknown_files() {
        let dir = tempdir().unwrap();
        let missing = dir.path().join("missing.cci");
        assert!(read_smdh_bytes(&missing).is_err());
        let unknown = dir.path().join("unknown.3ds");
        std::fs::write(&unknown, vec![0_u8; 0x400]).unwrap();
        assert!(read_smdh_bytes(&unknown).unwrap().is_none());
    }
}
