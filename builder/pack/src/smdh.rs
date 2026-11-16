//! SMDH (system menu data header) metadata: localized titles, publisher and
//! the 48x48 icon, read from the NCCH ExeFS.
//!
//! The SMDH is the `icon` entry of the NCCH ExeFS. Only the metadata block and
//! the icon are used (14 KiB); the ROM is never copied or hashed here. The byte
//! layout below is public format knowledge from the 3dbrew documentation:
//!
//! ```text
//! 0x0000  magic "SMDH", u32 version
//! 0x0008  title block x 16 (0x200 bytes each)                -> ends 0x2008
//! 0x2008  application settings (0x30) + reserved (0x8)       -> ends 0x2040
//! 0x2040  small icon, 24x24 RGB565 (0x480 bytes)             -> ends 0x24C0
//! 0x24C0  large icon, 48x48 RGB565 (0x1200 bytes)            -> ends 0x36C0
//! ```
//!
//! The small icon comes *first* in the icon graphics block; the large icon that
//! becomes the cover starts at `0x24C0`, not at `0x2040` and certainly not at
//! `0x2008` (application settings). Both icons are RGB565 little-endian but
//! stored as 8x8 tiles: tiles are ordered row-major and inside one tile the 2x2
//! pixel blocks follow a Morton/Z curve ([3dbrew SMDH]). Reading the icon
//! without the tile transform (or from the wrong offset) produces the garbled
//! rainbow covers seen in older builds.
//!
//! [3dbrew SMDH]: https://www.3dbrew.org/wiki/SMDH
//!
//! Title block (0x200 bytes): short description (0x80 bytes UTF-16LE), long
//! description (0x100 bytes UTF-16LE), publisher (0x80 bytes UTF-16LE).
//! Language order: ja, en, fr, de, it, es, zh-Hans, ko, nl, pt, ru, zh-Hant,
//! then four unused slots (no names are exposed for those).
//!
//! The cover is a deterministic PNG built with stored (uncompressed) deflate
//! blocks, so this crate needs no image dependency and the same icon always
//! produces byte-identical output. A cover extracted from the user ROM is local
//! user data and is never committed (`out/` is gitignored).

use std::collections::BTreeMap;
use std::path::Path;

use crate::error::{PackError, Result};

/// Magic at offset 0 of an SMDH.
pub const SMDH_MAGIC: &[u8] = b"SMDH";
/// Size of the SMDH header before the title table.
pub const SMDH_HEADER_SIZE: usize = 0x8;
/// Size of one title block (one language slot).
pub const TITLE_BLOCK_SIZE: usize = 0x200;
/// Number of title blocks (language slots).
pub const TITLE_BLOCK_COUNT: usize = 16;
/// Short description field size in bytes (UTF-16LE).
pub const SHORT_DESC_SIZE: usize = 0x80;
/// Long description field size in bytes (UTF-16LE).
pub const LONG_DESC_SIZE: usize = 0x100;
/// Publisher field offset inside a title block.
pub const PUBLISHER_OFFSET: usize = 0x180;
/// Publisher field size in bytes (UTF-16LE).
pub const PUBLISHER_SIZE: usize = 0x80;
/// End of the title table: header + 16 title blocks (`0x8 + 16 * 0x200`).
/// This is where the application settings block starts.
pub const TITLE_TABLE_END: usize = SMDH_HEADER_SIZE + TITLE_BLOCK_COUNT * TITLE_BLOCK_SIZE;
/// Application settings block (`0x30` bytes) that follows the title table.
pub const APPLICATION_SETTINGS_OFFSET: usize = TITLE_TABLE_END;
/// Application settings block size.
pub const APPLICATION_SETTINGS_SIZE: usize = 0x30;
/// Reserved bytes between the application settings and the icon graphics.
pub const APPLICATION_SETTINGS_RESERVED_SIZE: usize = 0x8;
/// Region-lockout bitmask inside the application settings block (3dbrew SMDH:
/// application settings + 0x10, i.e. absolute 0x2018).
pub const REGION_LOCKOUT_OFFSET: usize = APPLICATION_SETTINGS_OFFSET + 0x10;
/// Size of the region-lockout bitmask in bytes.
pub const REGION_LOCKOUT_SIZE: usize = 0x4;
/// Region codes and their region-lockout bits, in bit order (3dbrew SMDH).
pub const SMDH_REGIONS: [(&str, u32); 7] = [
    ("JP", 0x01),
    ("US", 0x02),
    ("EU", 0x04),
    ("AU", 0x08),
    ("CN", 0x10),
    ("KR", 0x20),
    ("TW", 0x40),
];
/// The mask Nintendo uses for a region-free title.
pub const REGION_FREE: u32 = 0x7FFF_FFFF;
/// Bits that name a known region in the region-lockout field.
pub const KNOWN_REGION_BITS: u32 = 0x7F;
/// Start of the icon graphics block. The small icon comes first.
pub const ICON_GRAPHICS_OFFSET: usize =
    APPLICATION_SETTINGS_OFFSET + APPLICATION_SETTINGS_SIZE + APPLICATION_SETTINGS_RESERVED_SIZE;
/// Offset of the small icon (24 * 24 RGB565) at the start of the icon graphics.
pub const SMALL_ICON_OFFSET: usize = ICON_GRAPHICS_OFFSET;
/// Edge length in pixels of the small icon.
pub const SMALL_ICON_SIDE: u32 = 24;
/// Size of the small icon (24 * 24 RGB565 pixels).
pub const SMALL_ICON_SIZE: usize = 0x480;
/// Offset of the 48x48 icon that becomes the cover (`0x24C0`). The pre-fix code
/// used `0x2008` here, which is the application settings block, not icon data.
pub const LARGE_ICON_OFFSET: usize = SMALL_ICON_OFFSET + SMALL_ICON_SIZE;
/// Edge length in pixels of the large icon that becomes the cover.
pub const COVER_SIDE: u32 = 48;
/// Size of the large icon (48 * 48 RGB565 pixels).
pub const LARGE_ICON_SIZE: usize = 0x1200;
/// End of the large icon (and of the SMDH): the minimum length for a cover.
pub const LARGE_ICON_END: usize = LARGE_ICON_OFFSET + LARGE_ICON_SIZE;
/// Size of the icon graphics block (small icon + large icon, `0x1680`).
pub const ICON_GRAPHICS_SIZE: usize = SMALL_ICON_SIZE + LARGE_ICON_SIZE;
/// Full SMDH size (title table + application settings + icon graphics).
pub const FULL_SMDH_SIZE: usize = ICON_GRAPHICS_OFFSET + ICON_GRAPHICS_SIZE;
/// Edge length in pixels of one icon tile.
pub const ICON_TILE_SIDE: usize = 8;
/// Pixels in one icon tile (8 * 8).
pub const ICON_TILE_PIXELS: usize = ICON_TILE_SIDE * ICON_TILE_SIDE;
/// Index of the English title block.
pub const ENGLISH_SLOT: usize = 1;

/// Language keys in SMDH order. The four trailing slots are unused.
pub const LANGUAGES: [&str; TITLE_BLOCK_COUNT] = [
    "ja", "en", "fr", "de", "it", "es", "zh-Hans", "ko", "nl", "pt", "ru", "zh-Hant", "", "", "",
    "",
];

/// Localized titles, publisher and region-lockout parsed from one SMDH.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SmdhMetadata {
    /// Localized short titles keyed by language, sorted by key.
    pub display_names: BTreeMap<String, String>,
    /// Publisher (English slot first, else the first non-empty slot).
    pub publisher: String,
    /// Region-lockout bitmask from the application settings (0 when unset).
    pub region_lockout: u32,
}

impl SmdhMetadata {
    /// English short title: the fallback for a package display name.
    pub fn english_title(&self) -> Option<&str> {
        self.display_names
            .get("en")
            .map(String::as_str)
            .filter(|title| !title.is_empty())
    }
}

/// Parse the title table of an SMDH.
///
/// Returns `None` for a wrong magic, a truncated file, or an SMDH without any
/// usable title/publisher text (the caller then keeps the file-name fallback).
/// Invalid UTF-16 in one language only drops that language, never the whole
/// metadata block.
pub fn parse(bytes: &[u8]) -> Option<SmdhMetadata> {
    if bytes.len() < TITLE_TABLE_END || &bytes[..SMDH_MAGIC.len()] != SMDH_MAGIC {
        return None;
    }
    let mut display_names = BTreeMap::new();
    let mut publishers: Vec<Option<String>> = Vec::with_capacity(TITLE_BLOCK_COUNT);
    for (index, language) in LANGUAGES.iter().enumerate() {
        let base = SMDH_HEADER_SIZE + index * TITLE_BLOCK_SIZE;
        let block = bytes.get(base..base + TITLE_BLOCK_SIZE)?;
        if !language.is_empty() {
            if let Some(title) = utf16_field(&block[..SHORT_DESC_SIZE]) {
                display_names.insert((*language).to_string(), title);
            }
        }
        publishers.push(utf16_field(
            &block[PUBLISHER_OFFSET..PUBLISHER_OFFSET + PUBLISHER_SIZE],
        ));
    }
    let publisher = publishers
        .get(ENGLISH_SLOT)
        .cloned()
        .flatten()
        .or_else(|| publishers.iter().flatten().next().cloned())
        .unwrap_or_default();
    if display_names.is_empty() && publisher.is_empty() {
        return None;
    }
    Some(SmdhMetadata {
        display_names,
        publisher,
        region_lockout: read_region_lockout(bytes),
    })
}

/// Region-lockout bitmask from the SMDH application settings.
///
/// The field is part of the application settings block (absolute 0x2018); a
/// truncated SMDH yields 0 so metadata detection never fails on it.
pub fn read_region_lockout(bytes: &[u8]) -> u32 {
    bytes
        .get(REGION_LOCKOUT_OFFSET..REGION_LOCKOUT_OFFSET + REGION_LOCKOUT_SIZE)
        .map(|raw| u32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]))
        .unwrap_or(0)
}

/// Human-readable region codes for an SMDH region-lockout bitmask.
///
/// The lockout mask names the regions a title may run in: 0x01 Japan,
/// 0x02 North America, 0x04 Europe, 0x08 Australia, 0x10 China, 0x20 Korea,
/// 0x40 Taiwan. Nintendo's region-free mask (0x7FFFFFFF) maps to
/// region-free; Europe is normally stored as Europe+Australia. Returns None
/// for an unset mask or one without a known region bit, so a manifest can
/// omit a region it does not actually know.
pub fn region_codes(lockout: u32) -> Option<String> {
    if lockout == 0 {
        return None;
    }
    if lockout == REGION_FREE {
        return Some("region-free".to_string());
    }
    if lockout & KNOWN_REGION_BITS == 0 {
        return None;
    }
    let codes: Vec<&str> = SMDH_REGIONS
        .iter()
        .filter(|(_, bit)| lockout & bit != 0)
        .map(|(code, _)| *code)
        .collect();
    (!codes.is_empty()).then(|| codes.join("+"))
}

/// The 48x48 RGB565 icon bytes, or `None` when the SMDH is too short.
pub fn large_icon(bytes: &[u8]) -> Option<&[u8]> {
    bytes.get(LARGE_ICON_OFFSET..LARGE_ICON_END)
}

/// Write the large icon of an SMDH to `destination` as a 48x48 RGB PNG.
///
/// Returns `false` (writing nothing) when the SMDH has no large icon or the
/// icon is entirely blank. The PNG is deterministic.
pub fn write_cover_png(smdh: &[u8], destination: &Path) -> Result<bool> {
    if smdh.len() < SMDH_HEADER_SIZE || &smdh[..SMDH_MAGIC.len()] != SMDH_MAGIC {
        return Ok(false);
    }
    let Some(icon) = large_icon(smdh) else {
        return Ok(false);
    };
    if icon.iter().all(|byte| *byte == 0) {
        return Ok(false);
    }
    let pixels = decode_tiled_rgb565(icon, COVER_SIDE as usize);
    let png = encode_rgb_png(COVER_SIDE, COVER_SIDE, &pixels);
    std::fs::write(destination, png).map_err(|error| PackError::io(destination, error))?;
    Ok(true)
}

fn utf16_field(raw: &[u8]) -> Option<String> {
    let mut units: Vec<u16> = raw
        .chunks_exact(2)
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
        .take_while(|unit| *unit != 0)
        .collect();
    while units.last().map(|unit| is_space(*unit)).unwrap_or(false) {
        units.pop();
    }
    if units.is_empty() {
        return None;
    }
    let text = String::from_utf16(&units).ok()?;
    let cleaned: String = text.chars().filter(|c| !c.is_control()).collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn is_space(unit: u16) -> bool {
    char::from_u32(u32::from(unit))
        .map(char::is_whitespace)
        .unwrap_or(false)
}

/// Offset of one pixel inside an 8x8 icon tile.
///
/// The tile is a 4x4 grid of 2x2 pixel blocks stored in Morton/Z order: the
/// block coordinates are bit-interleaved (x bit 0, y bit 0, x bit 1, y bit 1,
/// ...) and each block holds its four pixels row-major. This matches the
/// example table on 3dbrew: (0,0)=0, (1,0)=1, (2,0)=4, (3,0)=5, (0,1)=2,
/// (1,1)=3, (0,2)=8, (1,2)=9, (2,2)=12, (4,0)=16.
fn tile_pixel_offset(x: usize, y: usize) -> usize {
    let (mut block_x, mut block_y) = (x / 2, y / 2);
    let mut block = 0_usize;
    let mut bit = 0_u32;
    while block_x != 0 || block_y != 0 {
        block |= (block_x & 1) << bit;
        block |= (block_y & 1) << (bit + 1);
        block_x >>= 1;
        block_y >>= 1;
        bit += 2;
    }
    block * 4 + (y % 2) * 2 + (x % 2)
}

/// Index of one pixel of a `side` x `side` tiled icon, in row-major order.
///
/// 8x8 tiles are laid out row-major (`tiles_per_row = side / 8`); the small
/// 24x24 and the large 48x48 icon both use the same transform.
fn tiled_icon_index(side: usize, x: usize, y: usize) -> usize {
    let tiles_per_row = side / ICON_TILE_SIDE;
    let tile = (y / ICON_TILE_SIDE) * tiles_per_row + x / ICON_TILE_SIDE;
    tile * ICON_TILE_PIXELS + tile_pixel_offset(x % ICON_TILE_SIDE, y % ICON_TILE_SIDE)
}

/// Decode a row-major `side` x `side` RGB888 image from a tiled RGB565 icon.
fn decode_tiled_rgb565(icon: &[u8], side: usize) -> Vec<u8> {
    debug_assert!(icon.len() >= side * side * 2);
    let mut rgb = Vec::with_capacity(side * side * 3);
    for y in 0..side {
        for x in 0..side {
            let index = tiled_icon_index(side, x, y);
            let pixel = &icon[index * 2..index * 2 + 2];
            let value = u16::from_le_bytes([pixel[0], pixel[1]]);
            let r = ((value >> 11) & 0x1F) as u8;
            let g = ((value >> 5) & 0x3F) as u8;
            let b = (value & 0x1F) as u8;
            rgb.push((r << 3) | (r >> 2));
            rgb.push((g << 2) | (g >> 4));
            rgb.push((b << 3) | (b >> 2));
        }
    }
    rgb
}

fn encode_rgb_png(width: u32, height: u32, rgb: &[u8]) -> Vec<u8> {
    debug_assert_eq!(rgb.len(), width as usize * height as usize * 3);
    let stride = width as usize * 3;
    let mut raw = Vec::with_capacity((stride + 1) * height as usize);
    for row in 0..height as usize {
        raw.push(0); // filter type: none
        raw.extend_from_slice(&rgb[row * stride..(row + 1) * stride]);
    }

    // zlib stream with stored (uncompressed) deflate blocks.
    let mut zlib = vec![0x78, 0x01];
    let mut offset = 0;
    while offset < raw.len() {
        let len = (raw.len() - offset).min(0xFFFF);
        let last = offset + len == raw.len();
        zlib.push(u8::from(last));
        zlib.extend_from_slice(&(len as u16).to_le_bytes());
        zlib.extend_from_slice(&(!(len as u16)).to_le_bytes());
        zlib.extend_from_slice(&raw[offset..offset + len]);
        offset += len;
    }
    zlib.extend_from_slice(&adler32(&raw).to_be_bytes());

    let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]); // 8-bit RGB, deflate, no filter, no interlace
    png_chunk(b"IHDR", &ihdr, &mut png);
    png_chunk(b"IDAT", &zlib, &mut png);
    png_chunk(b"IEND", &[], &mut png);
    png
}

fn png_chunk(kind: &[u8; 4], data: &[u8], out: &mut Vec<u8>) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut crc_input = Vec::with_capacity(4 + data.len());
    crc_input.extend_from_slice(kind);
    crc_input.extend_from_slice(data);
    out.extend_from_slice(&crc32(&crc_input).to_be_bytes());
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFF_u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
        }
    }
    !crc
}

fn adler32(bytes: &[u8]) -> u32 {
    const MOD: u32 = 65_521;
    let mut a: u32 = 1;
    let mut b: u32 = 0;
    for byte in bytes {
        a = (a + u32::from(*byte)) % MOD;
        b = (b + a) % MOD;
    }
    (b << 16) | a
}

// --- tests -----------------------------------------------------------------

#[cfg(test)]
pub(crate) mod test_support {
    //! Synthetic SMDH bytes for unit tests: no real game data, only the format
    //! fields under test and a deterministic gradient icon.

    use super::*;

    /// Build a synthetic SMDH: `titles` is `(language slot, short title,
    /// publisher)`; the 48x48 icon is a deterministic gradient.
    pub fn synthetic_smdh(titles: &[(usize, &str, &str)]) -> Vec<u8> {
        let mut bytes = vec![0_u8; FULL_SMDH_SIZE];
        bytes[..SMDH_MAGIC.len()].copy_from_slice(SMDH_MAGIC);
        for (index, short, publisher) in titles {
            let base = SMDH_HEADER_SIZE + index * TITLE_BLOCK_SIZE;
            put_utf16(&mut bytes, base, SHORT_DESC_SIZE, short);
            put_utf16(
                &mut bytes,
                base + PUBLISHER_OFFSET,
                PUBLISHER_SIZE,
                publisher,
            );
        }
        // The application settings block is not icon data; fill it with a
        // constant so a decoder using the wrong offset produces different
        // pixels. The small icon (0x2040) is flat green and the large icon
        // (0x24C0) is a deterministic gradient encoded through the tile layout.
        bytes[APPLICATION_SETTINGS_OFFSET..ICON_GRAPHICS_OFFSET].fill(0x5A);
        // The region-lockout field is meaningful metadata: a fixture without a
        // region stays 0 (tests set it explicitly when they need one).
        set_region_lockout(&mut bytes, 0);
        for pixel in
            bytes[SMALL_ICON_OFFSET..SMALL_ICON_OFFSET + SMALL_ICON_SIZE].chunks_exact_mut(2)
        {
            pixel.copy_from_slice(&0x07E0_u16.to_le_bytes());
        }
        for y in 0..COVER_SIDE as usize {
            for x in 0..COVER_SIDE as usize {
                let value = (((y * COVER_SIDE as usize + x) * 977 + 0x1234) & 0xFFFF) as u16;
                put_tiled_pixel(
                    &mut bytes,
                    LARGE_ICON_OFFSET,
                    COVER_SIDE as usize,
                    x,
                    y,
                    value,
                );
            }
        }
        bytes
    }

    /// Write one RGB565 pixel into the tiled icon starting at `base`.
    pub fn put_tiled_pixel(
        icon: &mut [u8],
        base: usize,
        side: usize,
        x: usize,
        y: usize,
        value: u16,
    ) {
        let offset = base + tiled_icon_index(side, x, y) * 2;
        icon[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
    }

    /// Record a region-lockout mask in an existing synthetic SMDH.
    pub fn set_region_lockout(bytes: &mut [u8], mask: u32) {
        bytes[REGION_LOCKOUT_OFFSET..REGION_LOCKOUT_OFFSET + REGION_LOCKOUT_SIZE]
            .copy_from_slice(&mask.to_le_bytes());
    }

    fn put_utf16(bytes: &mut [u8], offset: usize, size: usize, text: &str) {
        let mut units: Vec<u16> = text.encode_utf16().take(size / 2 - 1).collect();
        units.push(0);
        for (index, unit) in units.iter().enumerate() {
            let start = offset + index * 2;
            bytes[start..start + 2].copy_from_slice(&unit.to_le_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{put_tiled_pixel, synthetic_smdh};
    use super::*;
    use tempfile::tempdir;

    /// Decode one pixel of a tiled RGB565 icon (row-major `(x, y)`) to RGB888,
    /// with the same rounding as the PNG encoder.
    fn tiled_pixel(bytes: &[u8], base: usize, side: usize, x: usize, y: usize) -> [u8; 3] {
        let offset = base + tiled_icon_index(side, x, y) * 2;
        let value = u16::from_le_bytes([bytes[offset], bytes[offset + 1]]);
        let r = ((value >> 11) & 0x1F) as u8;
        let g = ((value >> 5) & 0x3F) as u8;
        let b = (value & 0x1F) as u8;
        [
            (r << 3) | (r >> 2),
            (g << 2) | (g >> 4),
            (b << 3) | (b >> 2),
        ]
    }

    #[test]
    fn layout_constants_match_the_3dbrew_smdh_layout() {
        // 3dbrew SMDH: title table -> application settings -> icon graphics,
        // with the small icon first and the large icon at 0x24C0.
        assert_eq!(
            SMDH_HEADER_SIZE + TITLE_BLOCK_COUNT * TITLE_BLOCK_SIZE,
            0x2008
        );
        assert_eq!(TITLE_TABLE_END, 0x2008);
        assert_eq!(APPLICATION_SETTINGS_OFFSET, 0x2008);
        assert_eq!(APPLICATION_SETTINGS_SIZE, 0x30);
        assert_eq!(APPLICATION_SETTINGS_RESERVED_SIZE, 0x8);
        assert_eq!(ICON_GRAPHICS_OFFSET, 0x2040);
        assert_eq!(SMALL_ICON_OFFSET, 0x2040);
        assert_eq!(SMALL_ICON_SIDE, 24);
        assert_eq!(SMALL_ICON_SIZE, 0x480);
        assert_eq!(LARGE_ICON_OFFSET, 0x24C0);
        assert_eq!(COVER_SIDE, 48);
        assert_eq!(LARGE_ICON_SIZE, 0x1200);
        assert_eq!(LARGE_ICON_END, 0x36C0);
        assert_eq!(FULL_SMDH_SIZE, 0x36C0);
        assert_eq!(ICON_GRAPHICS_SIZE, 0x1680);
        assert_eq!(ICON_GRAPHICS_OFFSET + ICON_GRAPHICS_SIZE, FULL_SMDH_SIZE);
        assert_eq!(SMALL_ICON_OFFSET + SMALL_ICON_SIZE, LARGE_ICON_OFFSET);
        assert_eq!(LARGE_ICON_END, FULL_SMDH_SIZE);
        assert_eq!(ICON_TILE_SIDE, 8);
        // The region-lockout bitmask sits at application settings + 0x10.
        assert_eq!(REGION_LOCKOUT_OFFSET, 0x2018);
        assert_eq!(REGION_LOCKOUT_SIZE, 4);
        assert!(REGION_LOCKOUT_OFFSET >= APPLICATION_SETTINGS_OFFSET);
        assert!(
            REGION_LOCKOUT_OFFSET + REGION_LOCKOUT_SIZE
                <= APPLICATION_SETTINGS_OFFSET + APPLICATION_SETTINGS_SIZE
        );
        assert_eq!(KNOWN_REGION_BITS, 0x7F);
    }

    #[test]
    fn tile_pixels_follow_the_3dbrew_example_table() {
        // 3dbrew SMDH example table: within an 8x8 tile the 2x2 pixel blocks
        // are stored in Morton/Z order and the four pixels inside a block are
        // row-major.
        assert_eq!(tile_pixel_offset(0, 0), 0);
        assert_eq!(tile_pixel_offset(1, 0), 1);
        assert_eq!(tile_pixel_offset(2, 0), 4);
        assert_eq!(tile_pixel_offset(3, 0), 5);
        assert_eq!(tile_pixel_offset(0, 1), 2);
        assert_eq!(tile_pixel_offset(1, 1), 3);
        assert_eq!(tile_pixel_offset(0, 2), 8);
        assert_eq!(tile_pixel_offset(1, 2), 9);
        assert_eq!(tile_pixel_offset(2, 2), 12);
        assert_eq!(tile_pixel_offset(4, 0), 16);

        let expected: [[usize; 8]; 8] = [
            [0, 1, 4, 5, 16, 17, 20, 21],
            [2, 3, 6, 7, 18, 19, 22, 23],
            [8, 9, 12, 13, 24, 25, 28, 29],
            [10, 11, 14, 15, 26, 27, 30, 31],
            [32, 33, 36, 37, 48, 49, 52, 53],
            [34, 35, 38, 39, 50, 51, 54, 55],
            [40, 41, 44, 45, 56, 57, 60, 61],
            [42, 43, 46, 47, 58, 59, 62, 63],
        ];
        let mut seen = [false; ICON_TILE_PIXELS];
        for (y, row) in expected.iter().enumerate() {
            for (x, offset) in row.iter().enumerate() {
                assert_eq!(tile_pixel_offset(x, y), *offset, "tile pixel ({x}, {y})");
                assert!(!seen[*offset], "tile offset {offset} used twice");
                seen[*offset] = true;
            }
        }
        assert!(seen.iter().all(|used| *used), "all 64 tile pixels covered");
    }

    #[test]
    fn icon_tiles_are_laid_out_row_major() {
        // 48x48 = 6x6 tiles, 24x24 = 3x3 tiles; tiles are row-major.
        assert_eq!(tiled_icon_index(48, 0, 0), 0);
        assert_eq!(tiled_icon_index(48, 8, 0), ICON_TILE_PIXELS);
        assert_eq!(tiled_icon_index(48, 0, 8), 6 * ICON_TILE_PIXELS);
        assert_eq!(tiled_icon_index(48, 47, 47), 36 * ICON_TILE_PIXELS - 1);
        assert_eq!(tiled_icon_index(24, 0, 8), 3 * ICON_TILE_PIXELS);
        assert_eq!(tiled_icon_index(24, 23, 23), 9 * ICON_TILE_PIXELS - 1);
    }

    #[test]
    fn cover_encodes_the_tiled_large_icon_row_major() {
        // End-to-end: every large-icon pixel comes out row-major in the PNG.
        let smdh = synthetic_smdh(&[(1, "Test Game", "Example")]);
        let dir = tempdir().unwrap();
        let path = dir.path().join("cover.png");
        assert!(write_cover_png(&smdh, &path).unwrap());
        let (_, _, pixels) = decode_png(&std::fs::read(&path).unwrap());
        for y in 0..COVER_SIDE as usize {
            for x in 0..COVER_SIDE as usize {
                let expected = tiled_pixel(&smdh, LARGE_ICON_OFFSET, COVER_SIDE as usize, x, y);
                let start = (y * COVER_SIDE as usize + x) * 3;
                assert_eq!(
                    &pixels[start..start + 3],
                    &expected,
                    "cover pixel ({x}, {y})"
                );
            }
        }
    }

    #[test]
    fn decodes_the_small_icon_with_the_same_tile_transform() {
        // The small 24x24 icon at 0x2040 uses the same tile transform; the
        // fixture paints it flat green, so every decoded pixel is (0, 255, 0).
        let smdh = synthetic_smdh(&[(1, "Test Game", "Example")]);
        let small = &smdh[SMALL_ICON_OFFSET..SMALL_ICON_OFFSET + SMALL_ICON_SIZE];
        let rgb = decode_tiled_rgb565(small, SMALL_ICON_SIDE as usize);
        assert_eq!(
            rgb.len(),
            SMALL_ICON_SIDE as usize * SMALL_ICON_SIDE as usize * 3
        );
        assert!(
            rgb.chunks_exact(3).all(|pixel| pixel == [0, 255, 0]),
            "small icon decodes as flat green"
        );
    }

    #[test]
    fn parses_localized_titles_and_publisher() {
        let smdh = synthetic_smdh(&[
            (0, "テストゲーム", "Example"),
            (1, "Test Game", "Example"),
            (2, "Jeu de test", "Example"),
        ]);
        let metadata = parse(&smdh).expect("synthetic SMDH parses");
        assert_eq!(metadata.display_names.len(), 3);
        assert_eq!(
            metadata.display_names.get("ja").map(String::as_str),
            Some("テストゲーム")
        );
        assert_eq!(
            metadata.display_names.get("en").map(String::as_str),
            Some("Test Game")
        );
        assert_eq!(metadata.english_title(), Some("Test Game"));
        assert_eq!(metadata.publisher, "Example");
        // BTreeMap keeps the map sorted by language key.
        let keys: Vec<&str> = metadata.display_names.keys().map(String::as_str).collect();
        assert_eq!(keys, ["en", "fr", "ja"]);
    }

    #[test]
    fn skips_empty_languages_and_unused_slots() {
        let smdh = synthetic_smdh(&[(1, "Test Game", "Example")]);
        let metadata = parse(&smdh).unwrap();
        assert_eq!(metadata.display_names.len(), 1);
        assert!(metadata.display_names.contains_key("en"));
    }

    #[test]
    fn parses_the_region_lockout_and_maps_region_codes() {
        use super::test_support::set_region_lockout;
        let mut smdh = synthetic_smdh(&[(1, "Test Game", "Example")]);
        assert_eq!(parse(&smdh).unwrap().region_lockout, 0);
        assert_eq!(region_codes(0), None);

        set_region_lockout(&mut smdh, 0x04);
        assert_eq!(parse(&smdh).unwrap().region_lockout, 0x04);
        assert_eq!(region_codes(0x04).as_deref(), Some("EU"));
        assert_eq!(region_codes(0x02).as_deref(), Some("US"));
        assert_eq!(region_codes(0x01).as_deref(), Some("JP"));
        // Nintendo groups the Australian market with Europe.
        assert_eq!(region_codes(0x0C).as_deref(), Some("EU+AU"));
        assert_eq!(region_codes(0x7FFF_FFFF).as_deref(), Some("region-free"));
        // Only unknown bits: no usable region name.
        assert_eq!(region_codes(0x80), None);
        // A truncated SMDH (title table only) still parses and reports no region.
        assert_eq!(parse(&smdh[..TITLE_TABLE_END]).unwrap().region_lockout, 0);
    }

    #[test]
    fn publisher_falls_back_to_another_language() {
        let smdh = synthetic_smdh(&[(0, "テスト", "発売元")]);
        let metadata = parse(&smdh).unwrap();
        assert_eq!(metadata.english_title(), None);
        assert_eq!(metadata.publisher, "発売元");
    }

    #[test]
    fn rejects_malformed_or_truncated_smdh() {
        assert!(parse(&[]).is_none());
        assert!(parse(&vec![0_u8; TITLE_TABLE_END]).is_none());
        let mut no_magic = synthetic_smdh(&[(1, "Test Game", "Example")]);
        no_magic[0] = 0;
        assert!(parse(&no_magic).is_none());
        // Magic but no titles and no publisher: nothing usable.
        let empty = vec![0_u8; FULL_SMDH_SIZE];
        assert!(parse(&empty).is_none());
        let mut blank_magic = empty;
        blank_magic[..SMDH_MAGIC.len()].copy_from_slice(SMDH_MAGIC);
        assert!(parse(&blank_magic).is_none());
        // One title block cut short: parse fails instead of panicking.
        let smdh = synthetic_smdh(&[(1, "Test Game", "Example")]);
        assert!(parse(&smdh[..TITLE_TABLE_END - 1]).is_none());
        // Metadata parsing only needs the title table; the icon is optional.
        assert!(parse(&smdh[..TITLE_TABLE_END]).is_some());
    }

    #[test]
    fn invalid_utf16_only_drops_that_language() {
        let mut smdh = synthetic_smdh(&[(0, "テスト", "Example"), (1, "Test Game", "Example")]);
        // A lone surrogate in the English short description is not valid UTF-16.
        let en_short = SMDH_HEADER_SIZE + ENGLISH_SLOT * TITLE_BLOCK_SIZE;
        smdh[en_short..en_short + 2].copy_from_slice(&0xD800_u16.to_le_bytes());
        let metadata = parse(&smdh).expect("the Japanese title stays usable");
        assert!(metadata.display_names.contains_key("ja"));
        assert!(!metadata.display_names.contains_key("en"));
        assert_eq!(metadata.english_title(), None);
    }

    #[test]
    fn encodes_the_large_icon_as_a_valid_deterministic_png() {
        let smdh = synthetic_smdh(&[(1, "Test Game", "Example")]);
        let dir = tempdir().unwrap();
        let path = dir.path().join("cover.png");
        assert!(write_cover_png(&smdh, &path).unwrap());
        let png = std::fs::read(&path).unwrap();
        let (width, height, pixels) = decode_png(&png);
        assert_eq!((width, height), (COVER_SIDE, COVER_SIDE));
        assert_eq!(pixels.len(), COVER_SIDE as usize * COVER_SIDE as usize * 3);

        // The cover comes from the 48x48 large icon at 0x24C0, decoded through
        // the tile transform; the small icon at 0x2040 is flat green.
        let from_icon = tiled_pixel(&smdh, LARGE_ICON_OFFSET, COVER_SIDE as usize, 0, 0);
        let from_small = tiled_pixel(&smdh, SMALL_ICON_OFFSET, SMALL_ICON_SIDE as usize, 0, 0);
        assert_eq!(&pixels[..3], &from_icon);
        assert_ne!(from_small, from_icon);

        // Patch the large icon pixel (2, 0) pure red. Its tiled byte offset is
        // 4 while its flat offset is 2: the PNG must show it at x=2 and not at
        // x=4, proving the decoder applies the tile transform.
        let mut patched = smdh.clone();
        put_tiled_pixel(
            &mut patched,
            LARGE_ICON_OFFSET,
            COVER_SIDE as usize,
            2,
            0,
            0xF800,
        );
        let patched_path = dir.path().join("patched.png");
        assert!(write_cover_png(&patched, &patched_path).unwrap());
        let (_, _, patched_pixels) = decode_png(&std::fs::read(&patched_path).unwrap());
        assert_eq!(&patched_pixels[2 * 3..3 * 3], &[255, 0, 0]);
        assert_ne!(&patched_pixels[4 * 3..5 * 3], &[255, 0, 0]);

        let second = dir.path().join("cover-2.png");
        assert!(write_cover_png(&smdh, &second).unwrap());
        assert_eq!(
            std::fs::read(&second).unwrap(),
            png,
            "cover PNG is deterministic"
        );
    }

    #[test]
    fn blank_or_missing_icon_writes_nothing() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("cover.png");

        let mut blank = synthetic_smdh(&[(1, "Test Game", "Example")]);
        blank[LARGE_ICON_OFFSET..LARGE_ICON_END].fill(0);
        assert!(!write_cover_png(&blank, &path).unwrap());
        assert!(!path.exists());

        let truncated = vec![0_u8; LARGE_ICON_OFFSET];
        assert!(!write_cover_png(&truncated, &path).unwrap());

        // A valid SMDH cut one byte before the large icon ends: no cover.
        let mut short = synthetic_smdh(&[(1, "Test Game", "Example")]);
        short.truncate(LARGE_ICON_END - 1);
        assert!(!write_cover_png(&short, &path).unwrap());
        assert!(!path.exists());
    }

    /// Minimal PNG reader for the encoder tests: verifies the signature, every
    /// chunk CRC, the IHDR and the stored-deflate stream, then removes the
    /// filter bytes. Fails the test on any deviation.
    fn decode_png(png: &[u8]) -> (u32, u32, Vec<u8>) {
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
        let mut position = 8;
        let mut width = 0_u32;
        let mut height = 0_u32;
        let mut idat = Vec::new();
        let mut saw_end = false;
        while position < png.len() {
            let length =
                u32::from_be_bytes(png[position..position + 4].try_into().unwrap()) as usize;
            let kind = &png[position + 4..position + 8];
            let data = &png[position + 8..position + 8 + length];
            let expected_crc = u32::from_be_bytes(
                png[position + 8 + length..position + 12 + length]
                    .try_into()
                    .unwrap(),
            );
            assert_eq!(
                expected_crc,
                crc32(&png[position + 4..position + 8 + length]),
                "chunk CRC"
            );
            match kind {
                b"IHDR" => {
                    width = u32::from_be_bytes(data[0..4].try_into().unwrap());
                    height = u32::from_be_bytes(data[4..8].try_into().unwrap());
                    assert_eq!(&data[8..13], &[8, 2, 0, 0, 0]);
                }
                b"IDAT" => idat.extend_from_slice(data),
                b"IEND" => saw_end = true,
                other => panic!("unexpected PNG chunk {other:?}"),
            }
            position += 12 + length;
        }
        assert!(saw_end, "IEND chunk");
        let raw = inflate_stored(&idat);
        let stride = width as usize * 3;
        assert_eq!(raw.len(), (stride + 1) * height as usize);
        let mut pixels = Vec::with_capacity(stride * height as usize);
        for row in 0..height as usize {
            assert_eq!(raw[row * (stride + 1)], 0, "filter type must be none");
            pixels.extend_from_slice(&raw[row * (stride + 1) + 1..(row + 1) * (stride + 1)]);
        }
        (width, height, pixels)
    }

    fn inflate_stored(zlib: &[u8]) -> Vec<u8> {
        assert_eq!(&zlib[..2], &[0x78, 0x01]);
        let mut output = Vec::new();
        let mut position = 2;
        loop {
            let header = zlib[position];
            position += 1;
            assert_eq!((header >> 1) & 0b11, 0, "stored deflate block");
            let length = u16::from_le_bytes([zlib[position], zlib[position + 1]]) as usize;
            let complement = u16::from_le_bytes([zlib[position + 2], zlib[position + 3]]);
            assert_eq!(!(length as u16), complement);
            position += 4;
            output.extend_from_slice(&zlib[position..position + length]);
            position += length;
            if header & 1 == 1 {
                break;
            }
        }
        let adler = u32::from_be_bytes(zlib[position..position + 4].try_into().unwrap());
        assert_eq!(adler, adler32(&output));
        output
    }
}
