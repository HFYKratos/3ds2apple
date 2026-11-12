//! NDJSON framing for control channels.
//!
//! One frame per line (LF), UTF-8, no BOM, at most [`MAX_FRAME_BYTES`]. Blank
//! lines are tolerated and skipped; a line that is not a JSON object is a
//! protocol error that closes the channel.

use std::io::{BufRead, Write};

use crate::protocol::frames::RawFrame;
use crate::protocol::{ProtocolError, MAX_FRAME_BYTES};

/// Reads newline-delimited frames from a buffered stream.
#[derive(Debug)]
pub struct FrameReader<R: BufRead> {
    inner: R,
    max_frame: usize,
    buffer: String,
}

impl<R: BufRead> FrameReader<R> {
    pub fn new(inner: R) -> Self {
        Self {
            inner,
            max_frame: MAX_FRAME_BYTES,
            buffer: String::new(),
        }
    }

    pub fn with_max_frame(mut self, max: usize) -> Self {
        self.max_frame = max;
        self
    }

    /// Read the next frame. `Ok(None)` means the peer closed the stream.
    pub fn read_frame(&mut self) -> Result<Option<RawFrame>, ProtocolError> {
        loop {
            self.buffer.clear();
            let read = self.inner.read_line(&mut self.buffer)?;
            if read == 0 {
                return Ok(None);
            }
            if self.buffer.len() > self.max_frame {
                return Err(ProtocolError::FrameTooLarge {
                    bytes: self.buffer.len(),
                    limit: self.max_frame,
                });
            }
            let line = self.buffer.trim_end_matches('\n').trim_end_matches('\r');
            if line.trim().is_empty() {
                continue;
            }
            return RawFrame::from_line(line).map(Some);
        }
    }
}

/// Writes newline-delimited frames to a stream.
#[derive(Debug)]
pub struct FrameWriter<W: Write> {
    inner: W,
}

impl<W: Write> FrameWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner }
    }

    /// Write one frame and flush it, so the peer sees it immediately.
    pub fn write_frame(&mut self, frame: &RawFrame) -> Result<(), ProtocolError> {
        let line = frame.to_line()?;
        self.inner.write_all(line.as_bytes())?;
        self.inner.write_all(b"\n")?;
        self.inner.flush()?;
        Ok(())
    }

    pub fn into_inner(self) -> W {
        self.inner
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::frames::HelloRequest;
    use crate::protocol::frames::Pong;
    use crate::protocol::model::ClientInfo;
    use crate::protocol::PROTOCOL;
    use std::io::Cursor;

    #[test]
    fn reads_frames_and_skips_blank_lines() {
        let input =
            "\n{\"type\":\"ping\",\"tag\":\"t-1\"}\r\n\n{\"type\":\"pong\",\"tag\":\"t-2\"}\n";
        let mut reader = FrameReader::new(Cursor::new(input));
        let first = reader.read_frame().unwrap().unwrap();
        assert_eq!(first.frame_type(), Some("ping"));
        assert_eq!(first.tag(), Some("t-1"));
        let second = reader.read_frame().unwrap().unwrap();
        assert_eq!(second.frame_type(), Some("pong"));
        assert!(reader.read_frame().unwrap().is_none());
    }

    #[test]
    fn reports_malformed_and_oversized_frames() {
        let mut reader = FrameReader::new(Cursor::new("not json\n"));
        assert!(reader.read_frame().is_err());

        let mut small =
            FrameReader::new(Cursor::new("{\"type\":\"ping\",\"tag\":\"0123456789\"}\n"))
                .with_max_frame(10);
        assert!(matches!(
            small.read_frame(),
            Err(ProtocolError::FrameTooLarge { .. })
        ));
    }

    #[test]
    fn write_then_read_round_trip() {
        let hello = HelloRequest {
            tag: "t-1".into(),
            protocol: PROTOCOL.into(),
            client: ClientInfo {
                name: "3ds2apple-builder".into(),
                version: "0.1.0".into(),
                os: "linux".into(),
                os_version: None,
            },
            features: vec![],
        };
        let mut sink = Vec::new();
        {
            let mut writer = FrameWriter::new(&mut sink);
            writer.write_frame(&RawFrame::of(&hello).unwrap()).unwrap();
            writer
                .write_frame(&RawFrame::of(&Pong { tag: "t-2".into() }).unwrap())
                .unwrap();
        }
        assert!(sink.ends_with(b"\n"));
        let mut reader = FrameReader::new(Cursor::new(sink));
        let first = reader.read_frame().unwrap().unwrap();
        assert_eq!(first.decode::<HelloRequest>().unwrap().tag, "t-1");
        let second = reader.read_frame().unwrap().unwrap();
        assert_eq!(second.decode::<Pong>().unwrap().tag, "t-2");
        assert!(reader.read_frame().unwrap().is_none());
    }
}
