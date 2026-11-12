//! Typed control frames.
//!
//! Every frame is one JSON object with a `type` field. Types are declared once
//! here through [`FrameMessage`]; encode/decode goes through [`RawFrame`], which
//! keeps unknown fields intact and lets the Agent ignore frame types it does
//! not implement (forward compatibility, PROTOCOL.md §3.3).

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::protocol::model::{
    AgentInfo, ArtifactRecord, ClientInfo, ErrorInfo, EventKind, GameSpec, InputRole,
    JobCreateRequest, JobEvent, JobListEntry, JobOptions, JobState, JobView, Limits, LogLevel,
    LogSource, QueueLimits, SourceExpectation, SourceInfo, Stage, Toolchain, TransportMode,
    UploadPlan,
};
use crate::protocol::{ProtocolError, MAX_FRAME_BYTES};

/// A frame type this build knows how to produce and consume.
pub trait FrameMessage: Serialize + DeserializeOwned {
    /// Wire value of the `type` field.
    const TYPE: &'static str;
    fn tag(&self) -> &str;
    fn tag_mut(&mut self) -> &mut String;
}

macro_rules! define_frame {
    ($(#[$meta:meta])* $name:ident => $ty:literal, { $($(#[$fmeta:meta])* $field:ident : $ftype:ty),* $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
        pub struct $name {
            #[serde(default, skip_serializing_if = "String::is_empty")]
            pub tag: String,
            $( $(#[$fmeta])* pub $field: $ftype, )*
        }

        impl FrameMessage for $name {
            const TYPE: &'static str = $ty;

            fn tag(&self) -> &str {
                &self.tag
            }

            fn tag_mut(&mut self) -> &mut String {
                &mut self.tag
            }
        }
    };
}

// --- handshake -------------------------------------------------------------

define_frame!(HelloRequest => "hello", {
    protocol: String,
    client: ClientInfo,
    #[serde(default)]
    features: Vec<String>,
});

define_frame!(HelloResult => "hello.result", {
    protocol: String,
    agent: AgentInfo,
    #[serde(default)]
    capabilities: Vec<String>,
    toolchain: Toolchain,
    source: SourceInfo,
    limits: Limits,
    ready: bool,
    #[serde(default)]
    min_client: String,
    #[serde(default)]
    refusals: Vec<String>,
});

define_frame!(Ping => "ping", {});

define_frame!(Pong => "pong", {});

// --- jobs ------------------------------------------------------------------

define_frame!(JobCreateRequestFrame => "job.create", {
    request_id: String,
    game: GameSpec,
    inputs: Vec<crate::protocol::model::InputSpec>,
    #[serde(default)]
    options: JobOptions,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source: Option<SourceExpectation>,
    #[serde(default)]
    transport: TransportMode,
});

/// Convenience: build a `job.create` frame body from the model type.
impl From<JobCreateRequest> for JobCreateRequestFrame {
    fn from(request: JobCreateRequest) -> Self {
        Self {
            tag: String::new(),
            request_id: request.request_id,
            game: request.game,
            inputs: request.inputs,
            options: request.options,
            source: request.source,
            transport: request.transport,
        }
    }
}

impl From<JobCreateRequestFrame> for JobCreateRequest {
    fn from(frame: JobCreateRequestFrame) -> Self {
        Self {
            request_id: frame.request_id,
            game: frame.game,
            inputs: frame.inputs,
            options: frame.options,
            source: frame.source,
            transport: frame.transport,
        }
    }
}

define_frame!(JobCreated => "job.created", {
    job_id: String,
    state: JobState,
    upload: UploadPlan,
    limits: QueueLimits,
});

define_frame!(JobInputReadyRequest => "job.input_ready", {
    job_id: String,
});

define_frame!(JobInputReadyResult => "job.input_ready.result", {
    job_id: String,
    state: JobState,
    #[serde(default)]
    warnings: Vec<String>,
});

define_frame!(JobStatusRequest => "job.status", {
    job_id: String,
});

define_frame!(JobStatusResult => "job.status.result", {
    job: JobView,
});

define_frame!(JobSubscribeRequest => "job.subscribe", {
    job_id: String,
    #[serde(default)]
    since_seq: u64,
});

define_frame!(JobSubscribeResult => "job.subscribe.result", {
    job: JobView,
    #[serde(default)]
    earliest_seq: u64,
    #[serde(default)]
    log_truncated: bool,
});

define_frame!(JobEventFrame => "job.event", {
    seq: u64,
    job_id: String,
    ts: String,
    kind: EventKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    stage: Option<Stage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    source: Option<LogSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    level: Option<LogLevel>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    line: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    line_part: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    line_parts: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    state: Option<JobState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    error: Option<ErrorInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    artifact: Option<crate::protocol::model::ArtifactSummary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    message: Option<String>,
});

define_frame!(JobCancelRequest => "job.cancel", {
    job_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
});

define_frame!(JobCancelResult => "job.cancel.result", {
    job_id: String,
    state: JobState,
});

define_frame!(JobListRequest => "job.list", {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cursor: Option<String>,
});

define_frame!(JobListResult => "job.list.result", {
    #[serde(default)]
    jobs: Vec<JobListEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    next_cursor: Option<String>,
});

define_frame!(JobDeleteRequest => "job.delete", {
    job_id: String,
});

define_frame!(JobDeleteResult => "job.delete.result", {
    job_id: String,
    deleted: bool,
});

// --- artifacts -------------------------------------------------------------

define_frame!(ArtifactManifestRequest => "artifact.manifest", {
    job_id: String,
});

define_frame!(ArtifactManifestResult => "artifact.manifest.result", {
    artifact: ArtifactRecord,
});

define_frame!(ArtifactAckRequest => "artifact.ack", {
    job_id: String,
    artifact_sha256: String,
});

// --- errors ----------------------------------------------------------------

define_frame!(ErrorFrame => "error", {
    error: ErrorInfo,
});

impl From<JobEvent> for JobEventFrame {
    fn from(event: JobEvent) -> Self {
        Self {
            tag: String::new(),
            seq: event.seq,
            job_id: event.job_id,
            ts: event.ts,
            kind: event.kind,
            stage: event.stage,
            source: event.source,
            level: event.level,
            line: event.line,
            line_part: event.line_part,
            line_parts: event.line_parts,
            state: event.state,
            error: event.error,
            artifact: event.artifact,
            message: event.message,
        }
    }
}

impl From<JobEventFrame> for JobEvent {
    fn from(frame: JobEventFrame) -> Self {
        Self {
            seq: frame.seq,
            job_id: frame.job_id,
            ts: frame.ts,
            kind: frame.kind,
            stage: frame.stage,
            source: frame.source,
            level: frame.level,
            line: frame.line,
            line_part: frame.line_part,
            line_parts: frame.line_parts,
            state: frame.state,
            error: frame.error,
            artifact: frame.artifact,
            message: frame.message,
        }
    }
}

// ---------------------------------------------------------------------------
// Raw frame envelope
// ---------------------------------------------------------------------------

/// A JSON control frame that has not been mapped onto a typed message yet.
///
/// Wraps the parsed JSON value so unknown fields survive a read-modify-write and
/// the Agent can ignore unknown `type` values without failing the channel.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RawFrame(Value);

impl RawFrame {
    /// Wrap a raw JSON value. The value must be an object.
    pub fn new(value: Value) -> Result<Self, ProtocolError> {
        if value.is_object() {
            Ok(RawFrame(value))
        } else {
            Err(ProtocolError::NotAnObject)
        }
    }

    /// Serialise a typed message and add its `type` discriminator.
    pub fn of<T: FrameMessage>(message: &T) -> Result<Self, ProtocolError> {
        let mut value = serde_json::to_value(message)?;
        let object = value.as_object_mut().ok_or(ProtocolError::NotAnObject)?;
        object.insert("type".to_string(), Value::String(T::TYPE.to_string()));
        Ok(RawFrame(value))
    }

    /// Frame type, when the object has a string `type`.
    pub fn frame_type(&self) -> Option<&str> {
        self.0.get("type").and_then(Value::as_str)
    }

    /// Frame tag, when present.
    pub fn tag(&self) -> Option<&str> {
        self.0.get("tag").and_then(Value::as_str)
    }

    /// Whether this is an `error` frame.
    pub fn is_error(&self) -> bool {
        self.frame_type() == Some(ErrorFrame::TYPE)
    }

    /// Decode a typed message, checking the frame type matches.
    pub fn decode<T: FrameMessage>(&self) -> Result<T, ProtocolError> {
        match self.frame_type() {
            Some(actual) if actual == T::TYPE => {}
            Some(other) => {
                return Err(ProtocolError::MismatchedFrameType {
                    expected: T::TYPE,
                    got: other.to_string(),
                })
            }
            None => {
                return Err(ProtocolError::InvalidField {
                    field: "type",
                    message: "missing string frame type".to_string(),
                })
            }
        }
        serde_json::from_value(self.0.clone()).map_err(ProtocolError::Json)
    }

    /// Decode an error frame.
    pub fn decode_error(&self) -> Result<ErrorInfo, ProtocolError> {
        Ok(self.decode::<ErrorFrame>()?.error)
    }

    /// JSON text of one frame, without the trailing newline.
    pub fn to_line(&self) -> Result<String, ProtocolError> {
        let text = serde_json::to_string(&self.0)?;
        if text.len() > MAX_FRAME_BYTES {
            return Err(ProtocolError::FrameTooLarge {
                bytes: text.len(),
                limit: MAX_FRAME_BYTES,
            });
        }
        if text.contains('\n') {
            // serde_json escapes newlines inside strings, so this can only be a
            // deliberately corrupted value; refuse rather than corrupt framing.
            return Err(ProtocolError::InvalidField {
                field: "frame",
                message: "serialised frame contains a raw newline".to_string(),
            });
        }
        Ok(text)
    }

    /// Parse one line into a frame.
    pub fn from_line(line: &str) -> Result<Self, ProtocolError> {
        if line.len() > MAX_FRAME_BYTES {
            return Err(ProtocolError::FrameTooLarge {
                bytes: line.len(),
                limit: MAX_FRAME_BYTES,
            });
        }
        let value: Value = serde_json::from_str(line)?;
        RawFrame::new(value)
    }

    /// Access one field.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.0.get(key)
    }

    /// Borrow the underlying JSON.
    pub fn value(&self) -> &Value {
        &self.0
    }
}

// ---------------------------------------------------------------------------
// Data-channel status lines (SSH `upload`, `upload-status`)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadComplete {
    #[serde(rename = "type")]
    pub frame_type: String,
    pub received_bytes: u64,
    pub bytes: u64,
    pub sha256_ok: bool,
}

/// Build the `error` frame for a failed operation. `tag` echoes the request
/// tag when there is one, otherwise it is left empty.
pub fn error_frame(tag: impl Into<String>, error: ErrorInfo) -> Result<RawFrame, ProtocolError> {
    RawFrame::of(&ErrorFrame {
        tag: tag.into(),
        error,
    })
}

// Keep the remaining model types referenced so protocol docs and code agree on
// which types belong to the wire format even when only one side uses them.
#[allow(dead_code)]
fn _wire_types_are_public(
    _role: InputRole,
    _limits: Limits,
    _agent: AgentInfo,
    _client: ClientInfo,
) {
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::model::{ClientInfo, EventKind};
    use crate::protocol::PROTOCOL;
    use serde_json::json;

    fn client_info() -> ClientInfo {
        ClientInfo {
            name: "3ds2apple-builder".into(),
            version: "0.1.0".into(),
            os: "linux".into(),
            os_version: Some("6.12".into()),
        }
    }

    #[test]
    fn hello_round_trip_has_type_and_tag() {
        let hello = HelloRequest {
            tag: "t-1".into(),
            protocol: PROTOCOL.into(),
            client: client_info(),
            features: vec!["events.stream".into()],
        };
        let raw = RawFrame::of(&hello).unwrap();
        assert_eq!(raw.frame_type(), Some("hello"));
        assert_eq!(raw.tag(), Some("t-1"));
        let text = raw.to_line().unwrap();
        assert!(!text.contains('\n'));
        let parsed = RawFrame::from_line(&text).unwrap();
        assert_eq!(parsed.decode::<HelloRequest>().unwrap(), hello);
        assert_eq!(parsed.value()["client"]["name"], json!("3ds2apple-builder"));
    }

    #[test]
    fn tag_is_echoed_when_decoding_replies() {
        let raw = RawFrame::from_line(r#"{"type":"pong","tag":"t-9"}"#).unwrap();
        assert_eq!(raw.decode::<Pong>().unwrap().tag, "t-9");
        let ping = RawFrame::of(&Ping { tag: "t-9".into() }).unwrap();
        assert_eq!(ping.frame_type(), Some("ping"));
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let raw = RawFrame::from_line(
            r#"{"type":"pong","tag":"t-1","added_later":{"x":1},"another":"field"}"#,
        )
        .unwrap();
        assert_eq!(raw.decode::<Pong>().unwrap().tag, "t-1");
    }

    #[test]
    fn decode_rejects_wrong_or_missing_type() {
        let raw = RawFrame::from_line(r#"{"type":"pong","tag":"t-1"}"#).unwrap();
        let error = raw.decode::<Ping>().unwrap_err();
        assert!(matches!(error, ProtocolError::MismatchedFrameType { .. }));
        let raw = RawFrame::from_line(r#"{"tag":"t-1"}"#).unwrap();
        assert!(raw.decode::<Ping>().is_err());
    }

    #[test]
    fn event_kinds_serialise_as_snake_case() {
        let event = JobEventFrame {
            tag: String::new(),
            seq: 7,
            job_id: "job_01J8Z3K4T9ABCDEFGHJKMNPQRS".into(),
            ts: "2026-11-12T19:44:01Z".into(),
            kind: EventKind::State,
            stage: None,
            source: None,
            level: None,
            line: None,
            line_part: None,
            line_parts: None,
            state: Some(JobState::Running),
            error: None,
            artifact: None,
            message: None,
        };
        let raw = RawFrame::of(&event).unwrap();
        assert_eq!(raw.value()["kind"], json!("state"));
        assert_eq!(raw.value()["state"], json!("running"));
        assert!(raw.get("line").is_none());
        let back = raw.decode::<JobEventFrame>().unwrap();
        assert_eq!(back.seq, 7);
    }

    #[test]
    fn error_frame_decodes() {
        let frame = error_frame(
            "t-31",
            ErrorInfo::new(
                crate::protocol::codes::ErrorCode::BuildFailed,
                "xcodebuild failed",
            )
            .with_stage(Stage::Packaging),
        )
        .unwrap();
        assert!(frame.is_error());
        let decoded = frame.decode_error().unwrap();
        assert_eq!(decoded.code, crate::protocol::codes::ErrorCode::BuildFailed);
        assert_eq!(decoded.stage, Some(Stage::Packaging));
    }

    #[test]
    fn non_object_frames_are_rejected() {
        assert!(RawFrame::new(json!([1, 2, 3])).is_err());
        assert!(RawFrame::from_line("42").is_err());
        assert!(RawFrame::from_line("not json").is_err());
    }

    #[test]
    fn job_create_frame_converts_both_ways() {
        let request = JobCreateRequest {
            request_id: "req-1".into(),
            game: GameSpec {
                name: "pokemon-y".into(),
                display_name: "Pokemon Y".into(),
                bundle_id: None,
                title_id: None,
            },
            inputs: vec![crate::protocol::model::InputSpec {
                role: InputRole::Rom,
                name: "Pokemon Y.cci".into(),
                bytes: 10,
                sha256: "a".repeat(64),
            }],
            options: JobOptions::default(),
            source: None,
            transport: TransportMode::Upload,
        };
        let frame = JobCreateRequestFrame::from(request.clone());
        let raw = RawFrame::of(&frame).unwrap();
        assert_eq!(raw.frame_type(), Some("job.create"));
        let decoded: JobCreateRequestFrame = raw.decode().unwrap();
        assert_eq!(JobCreateRequest::from(decoded), request);
    }
}
