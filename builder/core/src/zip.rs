//! Minimal streaming ZIP archive reader/writer used by the .32a build packages.
//!
//! The desktop pipeline needs exactly two operations: write a handful of named
//! root entries from files that can be several gigabytes (the user's ROM) and
//! read them back while verifying size and CRC-32. This module implements that
//! narrow subset of the ZIP format directly (deflate via flate2, CRC via
//! crc32fast):
//!
//! - writer: local file header with a data descriptor (sizes/CRC are known only
//!   after streaming), deflate payload, central directory, end of central
//!   directory. UTF-8 names and a fixed 1980-01-01 DOS timestamp, so two
//!   archives with the same entries are byte-identical.
//! - reader: locates the end-of-central-directory record, parses the central
//!   directory, then streams the requested entry and verifies CRC-32 and the
//!   declared lengths instead of trusting the archive.
//!
//! Deliberate limits (documented errors instead of silent truncation): no ZIP64,
//! at most u16::MAX entries, entry names must be safe relative names (no parent
//! segments, no absolute paths, no backslashes), payloads must fit 4 GiB.
//!
//! See builder/README.md for the .32a layout that uses this module and
//! builder/pack/src/builds.rs for the manifest/validation layer.

use std::io::{self, Read, Seek, SeekFrom, Write};

use crc32fast::Hasher;
use flate2::read::DeflateDecoder;
use flate2::write::DeflateEncoder;
use flate2::Compression;

const LOCAL_FILE_HEADER_SIGNATURE: u32 = 0x0403_4b50;
const CENTRAL_DIRECTORY_SIGNATURE: u32 = 0x0201_4b50;
const END_OF_CENTRAL_DIRECTORY_SIGNATURE: u32 = 0x0605_4b50;
const DATA_DESCRIPTOR_SIGNATURE: u32 = 0x0807_4b50;

const VERSION_NEEDED: u16 = 20;
const FLAG_DATA_DESCRIPTOR: u16 = 0x0008;
const FLAG_UTF8_NAMES: u16 = 0x0800;
const METHOD_STORED: u16 = 0;
const METHOD_DEFLATE: u16 = 8;
const DOS_TIME: u16 = 0;
/// 1980-01-01 00:00:00, the DOS epoch: deterministic across hosts/timezones.
const DOS_DATE: u16 = 0x0021;

const EOCD_MIN_SIZE: u64 = 22;
const MAX_COMMENT_SIZE: u64 = 0xFFFF;
const COPY_BUFFER: usize = 1024 * 1024;
/// NUL and backslash are the two bytes an archive entry name must never contain.
const FORBIDDEN_NAME_BYTES: [u8; 2] = [0, 92];

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

fn invalid_input(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn read_u16(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

fn push_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn push_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn checked_u32(value: u64, what: &str) -> io::Result<u32> {
    u32::try_from(value).map_err(|_| {
        invalid(format!(
            "{what} is {value} bytes; this writer does not support ZIP64 archives"
        ))
    })
}

/// Validate an archive entry name: relative, forward slashes only, no parent
/// segments. Directory entries (names ending in a slash) are accepted by the
/// reader; the writer rejects them because every .32a entry is a root file.
pub fn validate_entry_name(name: &str) -> io::Result<()> {
    if name.is_empty() {
        return Err(invalid_input("archive entry name must not be empty"));
    }
    if name.len() > 255 {
        return Err(invalid_input(format!(
            "archive entry name is {} bytes; the maximum is 255",
            name.len()
        )));
    }
    if name.as_bytes().iter().any(|byte| FORBIDDEN_NAME_BYTES.contains(byte)) {
        return Err(invalid_input(format!(
            "archive entry name {name:?} contains a NUL or backslash byte"
        )));
    }
    if name.starts_with('/') {
        return Err(invalid_input(format!(
            "archive entry name {name:?} must be relative"
        )));
    }
    if name.len() >= 2 && name.as_bytes()[1] == b':' {
        return Err(invalid_input(format!(
            "archive entry name {name:?} must not start with a drive letter"
        )));
    }
    for segment in name.split('/') {
        if segment.is_empty() {
            return Err(invalid_input(format!(
                "archive entry name {name:?} has an empty path segment"
            )));
        }
        if segment == "." || segment == ".." {
            return Err(invalid_input(format!(
                "archive entry name {name:?} must not contain dot segments"
            )));
        }
    }
    Ok(())
}

fn validate_file_entry_name(name: &str) -> io::Result<()> {
    validate_entry_name(name)?;
    if name.ends_with('/') {
        return Err(invalid_input(format!(
            "archive entry {name:?} is a directory; only files can be written"
        )));
    }
    Ok(())
}

/// Result of writing one entry: name, uncompressed size and CRC-32.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZipEntryInfo {
    pub name: String,
    pub bytes: u64,
    pub crc32: u32,
}

#[derive(Debug)]
struct CentralEntry {
    name: String,
    flags: u16,
    method: u16,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    header_offset: u32,
}

/// Streaming ZIP writer; entries are written in call order.
#[derive(Debug)]
pub struct ZipWriter<W: Write> {
    inner: W,
    position: u64,
    entries: Vec<CentralEntry>,
}

impl<W: Write> ZipWriter<W> {
    /// Start a new archive on the writer.
    pub fn new(inner: W) -> Self {
        Self {
            inner,
            position: 0,
            entries: Vec::new(),
        }
    }

    /// Add one file entry, streaming the source through a deflate encoder.
    pub fn add_file<R: Read>(
        &mut self,
        name: &str,
        mut source: R,
    ) -> io::Result<ZipEntryInfo> {
        validate_file_entry_name(name)?;
        if self.entries.iter().any(|entry| entry.name == name) {
            return Err(invalid_input(format!(
                "archive entry {name:?} is already present"
            )));
        }
        if self.entries.len() >= u16::MAX as usize {
            return Err(invalid_input(
                "archive has too many entries for ZIP32 (maximum 65535)",
            ));
        }
        let header_offset = checked_u32(self.position, "archive offset")?;
        let flags = FLAG_DATA_DESCRIPTOR | FLAG_UTF8_NAMES;

        let mut header = Vec::with_capacity(30 + name.len());
        push_u32(&mut header, LOCAL_FILE_HEADER_SIGNATURE);
        push_u16(&mut header, VERSION_NEEDED);
        push_u16(&mut header, flags);
        push_u16(&mut header, METHOD_DEFLATE);
        push_u16(&mut header, DOS_TIME);
        push_u16(&mut header, DOS_DATE);
        push_u32(&mut header, 0);
        push_u32(&mut header, 0);
        push_u32(&mut header, 0);
        push_u16(&mut header, name.len() as u16);
        push_u16(&mut header, 0);
        header.extend_from_slice(name.as_bytes());
        self.write_all(&header)?;

        let mut hasher = Hasher::new();
        let mut uncompressed = 0_u64;
        let mut buffer = vec![0_u8; COPY_BUFFER];
        let mut counting = CountingWriter {
            inner: &mut self.inner,
            written: 0,
        };
        {
            let mut encoder = DeflateEncoder::new(&mut counting, Compression::default());
            loop {
                let read = source.read(&mut buffer)?;
                if read == 0 {
                    break;
                }
                hasher.update(&buffer[..read]);
                uncompressed += read as u64;
                encoder.write_all(&buffer[..read])?;
            }
            encoder.finish()?;
        }
        let compressed = counting.written;
        self.position += compressed;

        let crc32 = hasher.finalize();
        let compressed = checked_u32(compressed, "compressed payload")?;
        let uncompressed_u32 = checked_u32(uncompressed, "payload")?;

        let mut descriptor = Vec::with_capacity(16);
        push_u32(&mut descriptor, DATA_DESCRIPTOR_SIGNATURE);
        push_u32(&mut descriptor, crc32);
        push_u32(&mut descriptor, compressed);
        push_u32(&mut descriptor, uncompressed_u32);
        self.write_all(&descriptor)?;

        self.entries.push(CentralEntry {
            name: name.to_string(),
            flags,
            method: METHOD_DEFLATE,
            crc32,
            compressed_size: compressed,
            uncompressed_size: uncompressed_u32,
            header_offset,
        });
        Ok(ZipEntryInfo {
            name: name.to_string(),
            bytes: uncompressed,
            crc32,
        })
    }

    /// Add one entry from an in-memory buffer (tests, small metadata files).
    pub fn add_data(&mut self, name: &str, data: &[u8]) -> io::Result<ZipEntryInfo> {
        self.add_file(name, data)
    }

    /// Write the central directory and return the underlying writer.
    pub fn finish(mut self) -> io::Result<W> {
        if self.position > u32::MAX as u64 {
            return Err(invalid(
                "archive is larger than 4 GiB; ZIP64 archives are not supported",
            ));
        }
        let central_offset = checked_u32(self.position, "central directory offset")?;
        let entries = std::mem::take(&mut self.entries);
        for entry in &entries {
            let mut header = Vec::with_capacity(46 + entry.name.len());
            push_u32(&mut header, CENTRAL_DIRECTORY_SIGNATURE);
            push_u16(&mut header, VERSION_NEEDED);
            push_u16(&mut header, VERSION_NEEDED);
            push_u16(&mut header, entry.flags);
            push_u16(&mut header, entry.method);
            push_u16(&mut header, DOS_TIME);
            push_u16(&mut header, DOS_DATE);
            push_u32(&mut header, entry.crc32);
            push_u32(&mut header, entry.compressed_size);
            push_u32(&mut header, entry.uncompressed_size);
            push_u16(&mut header, entry.name.len() as u16);
            push_u16(&mut header, 0);
            push_u16(&mut header, 0);
            push_u16(&mut header, 0);
            push_u16(&mut header, 0);
            push_u32(&mut header, 0);
            push_u32(&mut header, entry.header_offset);
            header.extend_from_slice(entry.name.as_bytes());
            self.write_all(&header)?;
        }
        let central_size =
            checked_u32(self.position - u64::from(central_offset), "central directory")?;

        let mut eocd = Vec::with_capacity(22);
        push_u32(&mut eocd, END_OF_CENTRAL_DIRECTORY_SIGNATURE);
        push_u16(&mut eocd, 0);
        push_u16(&mut eocd, 0);
        push_u16(&mut eocd, entries.len() as u16);
        push_u16(&mut eocd, entries.len() as u16);
        push_u32(&mut eocd, central_size);
        push_u32(&mut eocd, central_offset);
        push_u16(&mut eocd, 0);
        self.write_all(&eocd)?;
        self.inner.flush()?;
        Ok(self.inner)
    }

    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.inner.write_all(bytes)?;
        self.position += bytes.len() as u64;
        Ok(())
    }
}

/// Write adapter that counts the bytes the deflate encoder emits.
struct CountingWriter<'a, W: Write> {
    inner: &'a mut W,
    written: u64,
}

impl<W: Write> Write for CountingWriter<'_, W> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let written = self.inner.write(buffer)?;
        self.written += written as u64;
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// One entry read from the central directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZipEntry {
    pub name: String,
    pub flags: u16,
    pub method: u16,
    pub crc32: u32,
    pub compressed_size: u64,
    pub uncompressed_size: u64,
    pub header_offset: u64,
}

impl ZipEntry {
    /// True for a directory marker entry (the name ends with a slash).
    pub fn is_directory(&self) -> bool {
        self.name.ends_with('/')
    }
}

/// Reader for archives produced by the writer above (also accepts ordinary
/// ZIP32 archives with stored or deflate entries).
#[derive(Debug)]
pub struct ZipArchive<R: Read + Seek> {
    reader: R,
    entries: Vec<ZipEntry>,
}

impl<R: Read + Seek> ZipArchive<R> {
    /// Open an archive and parse its central directory.
    pub fn open(mut reader: R) -> io::Result<Self> {
        let length = reader.seek(SeekFrom::End(0))?;
        if length < EOCD_MIN_SIZE {
            return Err(invalid("not a ZIP archive: the file is too small"));
        }
        let tail_length = length.min(EOCD_MIN_SIZE + MAX_COMMENT_SIZE);
        let mut tail = vec![0_u8; tail_length as usize];
        reader.seek(SeekFrom::Start(length - tail_length))?;
        reader.read_exact(&mut tail)?;

        let mut eocd_offset = None;
        if tail.len() >= EOCD_MIN_SIZE as usize {
            for offset in (0..=tail.len() - EOCD_MIN_SIZE as usize).rev() {
                if read_u32(&tail, offset) != END_OF_CENTRAL_DIRECTORY_SIGNATURE {
                    continue;
                }
                let comment = read_u16(&tail, offset + 20) as usize;
                if offset + 22 + comment == tail.len() {
                    eocd_offset = Some(offset);
                    break;
                }
            }
        }
        let eocd_offset = eocd_offset
            .ok_or_else(|| invalid("not a ZIP archive: no end-of-central-directory record"))?;
        if read_u16(&tail, eocd_offset + 4) != 0 || read_u16(&tail, eocd_offset + 6) != 0 {
            return Err(invalid("multi-disk ZIP archives are not supported"));
        }
        let entries_on_disk = read_u16(&tail, eocd_offset + 8);
        let entries_total = read_u16(&tail, eocd_offset + 10);
        let central_size = read_u32(&tail, eocd_offset + 12);
        let central_offset = read_u32(&tail, eocd_offset + 16);
        if entries_on_disk != entries_total {
            return Err(invalid("multi-disk ZIP archives are not supported"));
        }
        if entries_total == u16::MAX || central_size == u32::MAX || central_offset == u32::MAX {
            return Err(invalid(
                "ZIP64 archives are not supported (the .32a format is ZIP32)",
            ));
        }

        reader.seek(SeekFrom::Start(u64::from(central_offset)))?;
        let mut entries = Vec::with_capacity(entries_total as usize);
        let mut header = [0_u8; 46];
        for _ in 0..entries_total {
            reader.read_exact(&mut header)?;
            if read_u32(&header, 0) != CENTRAL_DIRECTORY_SIGNATURE {
                return Err(invalid(
                    "corrupt ZIP archive: bad central-directory entry signature",
                ));
            }
            let flags = read_u16(&header, 8);
            let method = read_u16(&header, 10);
            let crc32 = read_u32(&header, 16);
            let compressed_size = u64::from(read_u32(&header, 20));
            let uncompressed_size = u64::from(read_u32(&header, 24));
            let name_length = read_u16(&header, 28) as usize;
            let extra_length = read_u16(&header, 30) as usize;
            let comment_length = read_u16(&header, 32) as usize;
            let header_offset = u64::from(read_u32(&header, 42));
            if !matches!(method, METHOD_STORED | METHOD_DEFLATE) {
                return Err(invalid(format!(
                    "unsupported ZIP compression method {method} (only stored/deflate are supported)"
                )));
            }
            let mut name_bytes = vec![0_u8; name_length];
            reader.read_exact(&mut name_bytes)?;
            let name = String::from_utf8(name_bytes)
                .map_err(|_| invalid("corrupt ZIP archive: entry name is not UTF-8"))?;
            validate_entry_name(&name)?;
            let skip = extra_length as u64 + comment_length as u64;
            if skip > 0 {
                reader.seek(SeekFrom::Current(skip as i64))?;
            }
            entries.push(ZipEntry {
                name,
                flags,
                method,
                crc32,
                compressed_size,
                uncompressed_size,
                header_offset,
            });
        }
        Ok(Self { reader, entries })
    }

    /// All entries, in central-directory order.
    pub fn entries(&self) -> &[ZipEntry] {
        &self.entries
    }

    /// Index of the entry named exactly name (case-sensitive).
    pub fn find(&self, name: &str) -> Option<usize> {
        self.entries.iter().position(|entry| entry.name == name)
    }

    /// One entry by index.
    pub fn entry(&self, index: usize) -> Option<&ZipEntry> {
        self.entries.get(index)
    }

    /// Stream one entry into the writer, verifying CRC-32 and the declared size.
    /// Returns the uncompressed byte count.
    pub fn copy_to<W: Write>(&mut self, index: usize, out: &mut W) -> io::Result<u64> {
        let entry = self
            .entries
            .get(index)
            .cloned()
            .ok_or_else(|| invalid(format!("archive entry index {index} is out of range")))?;
        if entry.is_directory() {
            return Ok(0);
        }
        self.reader.seek(SeekFrom::Start(entry.header_offset))?;
        let mut header = [0_u8; 30];
        self.reader.read_exact(&mut header)?;
        if read_u32(&header, 0) != LOCAL_FILE_HEADER_SIGNATURE {
            return Err(invalid(format!(
                "corrupt ZIP archive: bad local header for {:?}",
                entry.name
            )));
        }
        let method = read_u16(&header, 8);
        let name_length = read_u16(&header, 26) as usize;
        let extra_length = read_u16(&header, 28) as usize;
        if method != entry.method {
            return Err(invalid(format!(
                "corrupt ZIP archive: {:?} declares method {method} locally but {} centrally",
                entry.name, entry.method
            )));
        }
        let mut local_name = vec![0_u8; name_length];
        self.reader.read_exact(&mut local_name)?;
        if local_name != entry.name.as_bytes() {
            return Err(invalid(format!(
                "corrupt ZIP archive: local name for {:?} does not match the central directory",
                entry.name
            )));
        }
        if extra_length > 0 {
            self.reader.seek(SeekFrom::Current(extra_length as i64))?;
        }

        let mut hasher = Hasher::new();
        let mut total = 0_u64;
        let mut buffer = vec![0_u8; COPY_BUFFER];
        let mut limited = (&mut self.reader).take(entry.compressed_size);
        if entry.method == METHOD_DEFLATE {
            let mut decoder = DeflateDecoder::new(&mut limited);
            copy_hashed(&mut decoder, &mut hasher, out, &mut total, &mut buffer)?;
        } else {
            copy_hashed(&mut limited, &mut hasher, out, &mut total, &mut buffer)?;
        }
        if total != entry.uncompressed_size {
            return Err(invalid(format!(
                "corrupt ZIP archive: {:?} is {total} bytes but the directory says {}",
                entry.name, entry.uncompressed_size
            )));
        }
        let crc32 = hasher.finalize();
        if crc32 != entry.crc32 {
            return Err(invalid(format!(
                "corrupt ZIP archive: {:?} CRC-32 is {crc32:08x} but the directory says {:08x}",
                entry.name, entry.crc32
            )));
        }
        Ok(total)
    }

    /// Read one entry into memory (metadata entries only; callers cap the size
    /// from the entry metadata before calling this).
    pub fn read_to_vec(&mut self, index: usize) -> io::Result<Vec<u8>> {
        let entry = self
            .entries
            .get(index)
            .ok_or_else(|| invalid(format!("archive entry index {index} is out of range")))?
            .clone();
        let capacity = usize::try_from(entry.uncompressed_size)
            .unwrap_or(0)
            .min(64 * 1024 * 1024);
        let mut bytes = Vec::with_capacity(capacity);
        self.copy_to(index, &mut bytes)?;
        Ok(bytes)
    }
}

fn copy_hashed<R: Read, W: Write>(
    source: &mut R,
    hasher: &mut Hasher,
    out: &mut W,
    total: &mut u64,
    buffer: &mut [u8],
) -> io::Result<()> {
    loop {
        let read = source.read(buffer)?;
        if read == 0 {
            return Ok(());
        }
        hasher.update(&buffer[..read]);
        *total += read as u64;
        out.write_all(&buffer[..read])?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn sample_payload(length: usize) -> Vec<u8> {
        (0..length).map(|index| (index * 31 + 7) as u8).collect()
    }

    #[test]
    fn round_trips_files_through_the_writer_and_reader() {
        let small = sample_payload(32);
        let payload = sample_payload(300_000);
        let mut writer = ZipWriter::new(Vec::new());
        let small_info = writer.add_data("manifest.json", &small).unwrap();
        let payload_info = writer.add_file("GamePack.dylib", payload.as_slice()).unwrap();
        writer.add_data("empty.bin", b"").unwrap();
        let archive_bytes = writer.finish().unwrap();

        assert_eq!(small_info.bytes, small.len() as u64);
        assert_eq!(small_info.crc32, crc32fast::hash(&small));
        assert_eq!(payload_info.bytes, payload.len() as u64);

        let mut archive = ZipArchive::open(Cursor::new(archive_bytes)).unwrap();
        assert_eq!(archive.entries().len(), 3);
        let names: Vec<&str> = archive
            .entries()
            .iter()
            .map(|entry| entry.name.as_str())
            .collect();
        assert_eq!(names, vec!["manifest.json", "GamePack.dylib", "empty.bin"]);

        let index = archive.find("GamePack.dylib").unwrap();
        assert_eq!(archive.read_to_vec(index).unwrap(), payload);
        let index = archive.find("manifest.json").unwrap();
        assert_eq!(archive.read_to_vec(index).unwrap(), small);
        let index = archive.find("empty.bin").unwrap();
        assert!(archive.read_to_vec(index).unwrap().is_empty());
        assert!(archive.find("missing").is_none());
    }

    #[test]
    fn archives_are_deterministic_for_the_same_input() {
        let build = || {
            let mut writer = ZipWriter::new(Vec::new());
            writer.add_data("a.txt", b"alpha").unwrap();
            writer.add_data("b.txt", b"beta").unwrap();
            writer.finish().unwrap()
        };
        assert_eq!(build(), build());
    }

    #[test]
    fn rejects_unsafe_or_duplicate_entry_names() {
        for name in ["", "../escape", "a/../b", "/absolute", "C:evil"] {
            assert!(
                validate_entry_name(name).is_err(),
                "expected {name:?} to be rejected"
            );
        }
        let backslash_name = format!("back{}slash", char::from(92));
        assert!(validate_entry_name(&backslash_name).is_err());
        let nul_name = format!("nul{}name", char::from(0));
        assert!(validate_entry_name(&nul_name).is_err());
        for name in ["manifest.json", "GamePack-0004000000055E00.dylib", "cover.png"] {
            validate_entry_name(name).unwrap();
        }
        assert!(validate_entry_name("dir/").is_err());
        let mut writer = ZipWriter::new(Vec::new());
        writer.add_data("same", b"one").unwrap();
        assert!(writer.add_data("same", b"two").is_err());
    }

    #[test]
    fn detects_corrupted_payload_through_crc() {
        let payload = b"payload-that-will-be-corrupted".to_vec();
        let mut writer = ZipWriter::new(Vec::new());
        writer.add_data("data.bin", &payload).unwrap();
        let mut bytes = writer.finish().unwrap();
        // The payload is deflate-compressed, so corrupt one byte of the
        // compressed stream (after the 30-byte local header and the name).
        let data_start = 30 + "data.bin".len();
        bytes[data_start] ^= 0xFF;
        let mut archive = ZipArchive::open(Cursor::new(bytes)).unwrap();
        let index = archive.find("data.bin").unwrap();
        assert!(archive.copy_to(index, &mut Vec::new()).is_err());
    }

    #[test]
    fn rejects_files_that_are_not_zip_archives() {
        assert!(ZipArchive::open(Cursor::new(b"not a zip archive at all".to_vec())).is_err());
        assert!(ZipArchive::open(Cursor::new(Vec::new())).is_err());
    }
}
