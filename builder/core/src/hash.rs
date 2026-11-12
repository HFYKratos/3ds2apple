//! Streaming SHA256 helpers.
//!
//! A ROM is several gigabytes and an IPA tens to hundreds of megabytes; nothing
//! here buffers a whole file in memory.

use std::fs::File;
use std::io::{self, BufReader, Read, Write};
use std::path::Path;

use sha2::{Digest, Sha256};

/// Chunk size used by the streaming helpers.
pub const CHUNK: usize = 4 * 1024 * 1024;

/// SHA256 of an in-memory buffer, lowercase hex.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

/// Result of hashing a file or stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HashResult {
    pub sha256: String,
    pub bytes: u64,
}

/// Hash a reader, optionally reporting progress (bytes consumed so far).
pub fn sha256_reader<R: Read>(
    mut reader: R,
    mut on_progress: impl FnMut(u64),
) -> io::Result<HashResult> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; CHUNK];
    let mut total = 0_u64;
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        total += read as u64;
        on_progress(total);
    }
    Ok(HashResult {
        sha256: hex::encode(hasher.finalize()),
        bytes: total,
    })
}

/// Hash a file.
pub fn sha256_file(path: &Path) -> io::Result<HashResult> {
    let file = File::open(path)?;
    sha256_reader(BufReader::with_capacity(CHUNK, file), |_| {})
}

/// Writes bytes through and hashes them on the way, for downloads.
#[derive(Debug)]
pub struct HashingWriter<W: Write> {
    inner: W,
    hasher: Sha256,
    bytes: u64,
}

impl<W: Write> HashingWriter<W> {
    pub fn new(inner: W) -> Self {
        Self {
            inner,
            hasher: Sha256::new(),
            bytes: 0,
        }
    }

    pub fn bytes_written(&self) -> u64 {
        self.bytes
    }

    /// Finish hashing and return the lowercase hex digest.
    pub fn finish(self) -> String {
        hex::encode(self.hasher.finalize())
    }
}

impl<W: Write> Write for HashingWriter<W> {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let written = self.inner.write(buffer)?;
        self.hasher.update(&buffer[..written]);
        self.bytes += written as u64;
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// Outcome of verifying a file against the declared hash and size.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerifyOutcome {
    Match {
        sha256: String,
        bytes: u64,
    },
    HashMismatch {
        expected: String,
        actual: String,
        bytes: u64,
    },
    SizeMismatch {
        expected: u64,
        actual: u64,
    },
}

impl VerifyOutcome {
    pub fn is_match(&self) -> bool {
        matches!(self, VerifyOutcome::Match { .. })
    }
}

/// Verify a file's size and SHA256 against the declared values (lowercase hex).
pub fn verify_file(
    path: &Path,
    expected_sha256: &str,
    expected_bytes: u64,
) -> io::Result<VerifyOutcome> {
    let actual = sha256_file(path)?;
    if actual.bytes != expected_bytes {
        return Ok(VerifyOutcome::SizeMismatch {
            expected: expected_bytes,
            actual: actual.bytes,
        });
    }
    if !actual.sha256.eq_ignore_ascii_case(expected_sha256) {
        return Ok(VerifyOutcome::HashMismatch {
            expected: expected_sha256.to_ascii_lowercase(),
            actual: actual.sha256,
            bytes: actual.bytes,
        });
    }
    Ok(VerifyOutcome::Match {
        sha256: actual.sha256,
        bytes: actual.bytes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::io::Write;

    #[test]
    fn known_sha256_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b"The quick brown fox jumps over the lazy dog"),
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        );
    }

    #[test]
    fn reader_progress_and_length() {
        let data = vec![7_u8; 10_000];
        let mut last_progress = 0;
        let result = sha256_reader(Cursor::new(&data), |bytes| last_progress = bytes).unwrap();
        assert_eq!(result.bytes, 10_000);
        assert_eq!(last_progress, 10_000);
        assert_eq!(result.sha256, sha256_hex(&data));
    }

    #[test]
    fn hashing_writer_matches_buffer_hash() {
        let mut writer = HashingWriter::new(Vec::new());
        writer.write_all(b"abc").unwrap();
        let inner_len = writer.bytes_written();
        let digest = writer.finish();
        assert_eq!(inner_len, 3);
        assert_eq!(digest, sha256_hex(b"abc"));
    }

    #[test]
    fn verify_file_detects_all_mismatches() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("input.bin");
        std::fs::write(&path, b"hello").unwrap();
        let good = sha256_hex(b"hello");
        assert!(verify_file(&path, &good, 5).unwrap().is_match());
        assert!(matches!(
            verify_file(&path, &"0".repeat(64), 5).unwrap(),
            VerifyOutcome::HashMismatch { .. }
        ));
        assert!(matches!(
            verify_file(&path, &good, 6).unwrap(),
            VerifyOutcome::SizeMismatch {
                expected: 6,
                actual: 5
            }
        ));
    }
}
