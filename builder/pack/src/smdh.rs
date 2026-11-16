//! SMDH (system menu data header) metadata: localized titles, publisher and
//! the 48x48 icon, read from the NCCH ExeFS.
//!
//! The SMDH is the `icon` entry of the NCCH ExeFS. Only the metadata block and
//! the icon are used (14 KiB); the ROM is never copied or hashed here. The byte
//! layout below is public format knowledge from the 3dbrew documentation:
//!
//! ```text
//! 0x0000  magic "SMDH", u32 version
//! 0x0008  title block x 16 (0x200 bytes each)
//! 0x2008  large icon, 48x48 RGB565 (0x1200 bytes)
//! 0x3208  small icon, 24x24 RGB565 (0x480 bytes)
//! ```
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
/// Offset of the large icon (also the end of the title table).
pub const LARGE_ICON_OFFSET: usize = 0x2008;
/// Edge length in pixels of the large icon that becomes the cover.
pub const COVER_SIDE: u32 = 48;
/// Size of the large icon (48 * 48 RGB565 pixels).
pub const LARGE_ICON_SIZE: usize = 0x1200;
/// End of the large icon: the minimum SMDH length for a cover.
pub const LARGE_ICON_END: usize = LARGE_ICON_OFFSET + LARGE_ICON_SIZE;
/// Full SMDH size (title table + large icon + small icon + padding).
pub const FULL_SMDH_SIZE: usize = 0x36C0;
/// Index of the English title block.
pub const ENGLISH_SLOT: usize = 1;

/// Language keys in SMDH order. The four trailing slots are unused.
pub const LANGUAGES: [&str; TITLE_BLOCK_COUNT] = [
    "ja", "en", "fr", "de", "it", "es", "zh-Hans", "ko", "nl", "pt", "ru", "zh-Hant", "", "", "",
    "",
];

/// Localized titles and publisher parsed from one SMDH.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SmdhMetadata {
    /// Localized short titles keyed by language, sorted by key.
    pub display_names: BTreeMap<String, String>,
    /// Publisher (English slot first, else the first non-empty slot).
    pub publisher: String,
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
    if bytes.len() < LARGE_ICON_OFFSET || &bytes[..SMDH_MAGIC.len()] != SMDH_MAGIC {
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
    })
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
    if smdh.len() < LARGE_ICON_OFFSET || &smdh[..SMDH_MAGIC.len()] != SMDH_MAGIC {
        return Ok(false);
    }
    let Some(icon) = large_icon(smdh) else {
        return Ok(false);
    };
    if icon.iter().all(|byte| *byte == 0) {
        return Ok(false);
    }
    let pixels = rgb565_to_rgb888(icon);
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

fn rgb565_to_rgb888(icon: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(icon.len() / 2 * 3);
    for pixel in icon.chunks_exact(2) {
        let value = u16::from_le_bytes([pixel[0], pixel[1]]);
        let r = ((value >> 11) & 0x1F) as u8;
        let g = ((value >> 5) & 0x3F) as u8;
        let b = (value & 0x1F) as u8;
        rgb.push((r << 3) | (r >> 2));
        rgb.push((g << 2) | (g >> 4));
        rgb.push((b << 3) | (b >> 2));
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
        for (index, pixel) in bytes[LARGE_ICON_OFFSET..LARGE_ICON_END]
            .chunks_exact_mut(2)
            .enumerate()
        {
            let value = ((index * 977) & 0xFFFF) as u16;
            pixel.copy_from_slice(&value.to_le_bytes());
        }
        bytes
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
    use super::test_support::synthetic_smdh;
    use super::*;
    use tempfile::tempdir;

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
    fn publisher_falls_back_to_another_language() {
        let smdh = synthetic_smdh(&[(0, "テスト", "発売元")]);
        let metadata = parse(&smdh).unwrap();
        assert_eq!(metadata.english_title(), None);
        assert_eq!(metadata.publisher, "発売元");
    }

    #[test]
    fn rejects_malformed_or_truncated_smdh() {
        assert!(parse(&[]).is_none());
        assert!(parse(&vec![0_u8; LARGE_ICON_OFFSET]).is_none());
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
        assert!(parse(&smdh[..LARGE_ICON_OFFSET - 1]).is_none());
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

        let first = u16::from_le_bytes([smdh[LARGE_ICON_OFFSET], smdh[LARGE_ICON_OFFSET + 1]]);
        let r = ((first >> 11) & 0x1F) as u8;
        let g = ((first >> 5) & 0x3F) as u8;
        let b = (first & 0x1F) as u8;
        assert_eq!(
            &pixels[..3],
            &[
                (r << 3) | (r >> 2),
                (g << 2) | (g >> 4),
                (b << 3) | (b >> 2)
            ]
        );

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
