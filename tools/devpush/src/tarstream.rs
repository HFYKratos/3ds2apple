//! Minimal streaming pax/ustar writer + archive completeness check.
//!
//! put-tar streams a tar archive straight to the device (no temp file). The
//! archive is written as plain ustar blocks (pax extended headers for long
//! paths) so the shell-side unpacker only needs standard tar support.

use std::io::SeekFrom;
use std::path::{Path, PathBuf};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeek, AsyncSeekExt, AsyncWrite, AsyncWriteExt};

use crate::error::{DevpushError, ErrorCode};
use crate::output::Reporter;

pub const BLOCK: usize = 512;

#[derive(Debug, Clone)]
pub struct TarEntry {
    pub rel: String,
    pub local: PathBuf,
}

#[derive(Debug, Clone)]
pub struct TarStats {
    pub payload_bytes: u64,
    pub archive_bytes: u64,
    pub entries: usize,
}

/// Validate a manifest-relative path (UTF-8, forward slashes, no abs, no dot-dot).
pub fn normalize_rel(path: &str) -> Result<String, DevpushError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(DevpushError::invalid("empty manifest path"));
    }
    if trimmed.contains('\\') {
        return Err(DevpushError::invalid(format!(
            "manifest path must use forward slashes: {trimmed}"
        )));
    }
    if trimmed.starts_with('/') || trimmed.starts_with("~/") || trimmed.contains(':') {
        return Err(DevpushError::invalid(format!(
            "manifest path must be relative: {trimmed}"
        )));
    }
    let mut parts: Vec<&str> = Vec::new();
    for seg in trimmed.split('/') {
        match seg {
            "" | "." => continue,
            ".." => {
                return Err(DevpushError::invalid(format!(
                    "manifest path escapes the root: {trimmed}"
                )))
            }
            other => parts.push(other),
        }
    }
    if parts.is_empty() {
        return Err(DevpushError::invalid(format!(
            "manifest path has no file component: {trimmed}"
        )));
    }
    let joined = parts.join("/");
    if joined.len() > 4096 {
        return Err(DevpushError::invalid("manifest path is too long"));
    }
    Ok(joined)
}

/// Read a manifest (one relative path per line, blank lines and comments starting
/// with a hash ignored) and resolve entries against root.
pub fn read_manifest(list: &Path, root: &Path) -> Result<Vec<TarEntry>, DevpushError> {
    let text = std::fs::read_to_string(list).map_err(|e| {
        DevpushError::new(
            ErrorCode::IoError,
            format!("cannot read manifest {}: {e}", list.display()),
        )
    })?;
    let mut entries = Vec::new();
    for (idx, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let rel = normalize_rel(line).map_err(|mut e| {
            e.message = format!(
                "manifest {} line {}: {}",
                list.display(),
                idx + 1,
                e.message
            );
            e
        })?;
        let mut local = root.to_path_buf();
        for part in rel.split('/') {
            local.push(part);
        }
        let meta = std::fs::metadata(&local).map_err(|e| {
            DevpushError::new(
                ErrorCode::IoError,
                format!("manifest entry {} is not readable: {e}", local.display()),
            )
        })?;
        if !meta.is_file() {
            return Err(DevpushError::new(
                ErrorCode::IoError,
                format!("manifest entry {} is not a regular file", local.display()),
            ));
        }
        entries.push(TarEntry { rel, local });
    }
    if entries.is_empty() {
        return Err(DevpushError::usage(format!(
            "manifest {} lists no files",
            list.display()
        )));
    }
    Ok(entries)
}

/// True when a tar byte stream looks complete: 512-aligned, at least 2 blocks,
/// last 1024 bytes all zero. Mirrors the shell-side unpack contract.
#[allow(dead_code)]
pub fn tar_ok_bytes(bytes: &[u8]) -> bool {
    if bytes.len() < 1024 || bytes.len() % BLOCK != 0 {
        return false;
    }
    let tail = &bytes[bytes.len() - 1024..];
    tail.iter().all(|b| *b == 0)
}

/// Check a device-side tar archive without downloading it.
pub async fn tar_ok_reader<R>(reader: &mut R) -> Result<bool, DevpushError>
where
    R: AsyncRead + AsyncSeek + Unpin,
{
    let size = reader
        .seek(SeekFrom::End(0))
        .await
        .map_err(|e| DevpushError::io(format!("cannot seek remote archive: {e}")))?;
    if size < 1024 || size % BLOCK as u64 != 0 {
        return Ok(false);
    }
    reader
        .seek(SeekFrom::Start(size - 1024))
        .await
        .map_err(|e| DevpushError::io(format!("cannot seek remote archive: {e}")))?;
    let mut tail = [0u8; 1024];
    reader
        .read_exact(&mut tail)
        .await
        .map_err(|e| DevpushError::io(format!("cannot read remote archive tail: {e}")))?;
    Ok(tail.iter().all(|b| *b == 0))
}

fn write_octal(dst: &mut [u8], value: u64) {
    let width = dst.len() - 1;
    let s = format!("{value:o}");
    let bytes = s.as_bytes();
    let take = bytes.len().min(width);
    dst[..take].copy_from_slice(&bytes[bytes.len() - take..]);
    dst[width] = 0;
}

fn header_block(name: &str, size: u64, mtime: u64, mode: u32, typeflag: u8) -> [u8; BLOCK] {
    let mut h = [0u8; BLOCK];
    let name_bytes = name.as_bytes();
    let n = name_bytes.len().min(100);
    h[..n].copy_from_slice(&name_bytes[..n]);
    write_octal(&mut h[100..108], mode as u64);
    write_octal(&mut h[108..116], 0);
    write_octal(&mut h[116..124], 0);
    write_octal(&mut h[124..136], size.min(0o77777777777));
    write_octal(&mut h[136..148], mtime);
    for b in h[148..156].iter_mut() {
        *b = b' ';
    }
    h[156] = typeflag;
    h[257..263].copy_from_slice(b"ustar\0");
    h[263..265].copy_from_slice(b"00");
    let checksum: u32 = h.iter().map(|b| *b as u32).sum();
    let s = format!("{checksum:06o}\0 ");
    h[148..156].copy_from_slice(s.as_bytes());
    h
}

fn pax_record(key: &str, value: &str) -> Vec<u8> {
    let body = format!(" {key}={value}\n");
    let mut len = body.len() + 1;
    loop {
        let candidate = format!("{len}{body}");
        if candidate.len() == len {
            return candidate.into_bytes();
        }
        len = candidate.len();
    }
}

async fn write_pax<W>(writer: &mut W, path: &str) -> Result<u64, DevpushError>
where
    W: AsyncWrite + Unpin,
{
    let record = pax_record("path", path);
    let header = header_block(
        "PaxHeaders/devpush-path",
        record.len() as u64,
        0,
        0o644,
        b'x',
    );
    writer
        .write_all(&header)
        .await
        .map_err(|e| DevpushError::io(format!("cannot write pax header: {e}")))?;
    writer
        .write_all(&record)
        .await
        .map_err(|e| DevpushError::io(format!("cannot write pax record: {e}")))?;
    let pad = (BLOCK - record.len() % BLOCK) % BLOCK;
    if pad > 0 {
        writer
            .write_all(&vec![0u8; pad])
            .await
            .map_err(|e| DevpushError::io(format!("cannot write tar padding: {e}")))?;
    }
    Ok((BLOCK + record.len() + pad) as u64)
}

/// Stream entries as a tar archive into writer (the device-side AFC file).
pub async fn write_tar<W>(
    writer: &mut W,
    entries: &[TarEntry],
    reporter: &mut Reporter,
) -> Result<TarStats, DevpushError>
where
    W: AsyncWrite + Unpin,
{
    let mut payload_bytes = 0u64;
    let mut archive_bytes = 0u64;
    for entry in entries {
        let meta = std::fs::metadata(&entry.local)
            .map_err(|e| DevpushError::io(format!("cannot stat {}: {e}", entry.local.display())))?;
        let size = meta.len();
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let base_name = entry.rel.rsplit('/').next().unwrap_or(&entry.rel);
        reporter.set_file(base_name);

        if entry.rel.len() > 100 {
            archive_bytes += write_pax(writer, &entry.rel).await?;
        }
        let header = header_block(&entry.rel, size, mtime, 0o644, b'0');
        writer
            .write_all(&header)
            .await
            .map_err(|e| DevpushError::io(format!("cannot write tar header: {e}")))?;
        archive_bytes += BLOCK as u64;

        let mut file = tokio::fs::File::open(&entry.local)
            .await
            .map_err(|e| DevpushError::io(format!("cannot read {}: {e}", entry.local.display())))?;
        let mut buf = vec![0u8; 128 * 1024];
        let mut copied = 0u64;
        loop {
            let n = file.read(&mut buf).await.map_err(|e| {
                DevpushError::io(format!("cannot read {}: {e}", entry.local.display()))
            })?;
            if n == 0 {
                break;
            }
            writer.write_all(&buf[..n]).await.map_err(|e| {
                DevpushError::new(
                    ErrorCode::AfcError,
                    format!("cannot write tar payload: {e}"),
                )
            })?;
            copied += n as u64;
            payload_bytes += n as u64;
            reporter.tick(payload_bytes);
        }
        if copied != size {
            return Err(DevpushError::io(format!(
                "{} changed size while streaming (expected {size}, copied {copied})",
                entry.local.display()
            )));
        }
        let pad = (BLOCK - (size as usize % BLOCK)) % BLOCK;
        if pad > 0 {
            writer
                .write_all(&vec![0u8; pad])
                .await
                .map_err(|e| DevpushError::io(format!("cannot write tar padding: {e}")))?;
            archive_bytes += pad as u64;
        }
    }
    writer
        .write_all(&[0u8; 1024])
        .await
        .map_err(|e| DevpushError::io(format!("cannot write tar trailer: {e}")))?;
    archive_bytes += 1024;
    writer.flush().await.map_err(|e| {
        DevpushError::new(ErrorCode::AfcError, format!("cannot flush tar stream: {e}"))
    })?;
    Ok(TarStats {
        payload_bytes,
        archive_bytes,
        entries: entries.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    struct VecSink(Vec<u8>);

    impl AsyncWrite for VecSink {
        fn poll_write(
            mut self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<std::io::Result<usize>> {
            self.0.extend_from_slice(buf);
            Poll::Ready(Ok(buf.len()))
        }
        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    fn make_entries(dir: &Path) -> Vec<TarEntry> {
        let long_rel = format!("Documents/Games/0004000000055D00/{}.bin", "x".repeat(120));
        for (rel, data) in [
            ("a.txt", &b"hello tar"[..]),
            ("sub/b.bin", &b"second file contents"[..]),
            (long_rel.as_str(), &b"long name payload"[..]),
        ] {
            let mut p = dir.to_path_buf();
            for part in rel.split('/') {
                p.push(part);
            }
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, data).unwrap();
        }
        let mut entries: Vec<TarEntry> = ["a.txt", "sub/b.bin", long_rel.as_str()]
            .iter()
            .map(|rel| TarEntry {
                rel: rel.to_string(),
                local: dir.join(rel),
            })
            .collect();
        entries.sort_by(|a, b| a.rel.cmp(&b.rel));
        entries
    }

    #[tokio::test]
    async fn tar_stream_is_valid_and_complete() {
        let dir = tempfile::tempdir().unwrap();
        let entries = make_entries(dir.path());
        let mut sink = VecSink(Vec::new());
        let mut reporter = Reporter::new("put-tar", true);
        let stats = write_tar(&mut sink, &entries, &mut reporter).await.unwrap();
        assert_eq!(stats.entries, entries.len());
        assert!(stats.archive_bytes >= stats.payload_bytes + 1024);
        assert!(
            tar_ok_bytes(&sink.0),
            "generated tar must pass the completeness contract"
        );
        assert!(
            !tar_ok_bytes(&sink.0[..sink.0.len() - 1]),
            "truncated tar must fail"
        );

        let out = dir.path().join("archive.tar");
        std::fs::write(&out, &sink.0).unwrap();
        let listing = std::process::Command::new("tar")
            .args(["-tf", out.to_str().unwrap()])
            .output();
        match listing {
            Ok(o) if o.status.success() => {
                let names = String::from_utf8_lossy(&o.stdout);
                assert!(names.contains("a.txt"));
                assert!(names.contains("sub/b.bin"));
                assert!(
                    names.contains(&"x".repeat(120)),
                    "pax long path must be readable: {names}"
                );
            }
            Ok(o) => panic!(
                "tar could not read generated archive: {}",
                String::from_utf8_lossy(&o.stderr)
            ),
            Err(_) => { /* host without tar: completeness check above is the contract */ }
        }
    }

    #[test]
    fn pax_records_are_self_describing() {
        let rec = pax_record("path", "abc");
        let text = String::from_utf8(rec.clone()).unwrap();
        let (len_part, rest) = text.split_at(text.find(' ').unwrap());
        assert_eq!(len_part.parse::<usize>().unwrap(), rec.len());
        assert_eq!(rest, " path=abc\n");
    }

    #[test]
    fn manifest_rejects_traversal_and_absolute_paths() {
        assert_eq!(
            normalize_rel("Documents/Games/a.bin").unwrap(),
            "Documents/Games/a.bin"
        );
        assert!(normalize_rel("../etc/passwd").is_err());
        assert!(normalize_rel("/etc/passwd").is_err());
        assert!(normalize_rel("a/../../b").is_err());
        assert!(normalize_rel("a\\b").is_err());
        assert!(normalize_rel("   ").is_err());
    }

    #[test]
    fn tar_ok_accepts_only_aligned_zero_tail() {
        let mut good = vec![0u8; 512];
        good[0] = 1;
        good.extend_from_slice(&[0u8; 1024]);
        assert!(tar_ok_bytes(&good));
        assert!(!tar_ok_bytes(&good[..good.len() - 512]));
        let mut bad_tail = good.clone();
        bad_tail[good.len() - 1] = 7;
        assert!(!tar_ok_bytes(&bad_tail));
    }
}
