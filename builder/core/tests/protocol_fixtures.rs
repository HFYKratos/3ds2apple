//! Protocol conformance against the versioned golden fixtures in
//! `builder/tests/protocol/`.
//!
//! Each fixture contains a request, the expected reply and (for subscriptions)
//! the expected events. The test decodes every object into its typed message,
//! re-encodes it, and compares the canonical JSON. A mismatch means the wire
//! shape drifted and needs a deliberate protocol review.

use std::path::{Path, PathBuf};

use builder_core::protocol::frames::{
    ArtifactManifestRequest, ArtifactManifestResult, ErrorFrame, FrameMessage, HelloRequest,
    HelloResult, JobCancelRequest, JobCancelResult, JobCreateRequestFrame, JobCreated,
    JobEventFrame, JobInputReadyRequest, JobInputReadyResult, JobStatusRequest, JobStatusResult,
    JobSubscribeRequest, JobSubscribeResult, RawFrame, UploadComplete,
};
use builder_core::protocol::model::{LogLevel, LogSource, UploadProgress, UploadStatusReply};
use builder_core::protocol::{protocol_compatible, protocol_major, PROTOCOL};
use builder_core::util::{canonical_json, canonical_json_string};
use serde_json::Value;

fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/protocol")
}

fn fixture_files() -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(fixture_dir())
        .expect("fixtures directory exists")
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("json"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no protocol fixtures found");
    files
}

fn load(path: &Path) -> Value {
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("{} is not valid JSON: {error}", path.display()))
}

fn reencode<T: FrameMessage>(value: &Value, expected_type: &str) -> Result<Value, String> {
    let raw = RawFrame::new(value.clone()).map_err(|error| error.to_string())?;
    assert_eq!(raw.frame_type(), Some(expected_type), "frame type mismatch");
    let message: T = raw.decode().map_err(|error| error.to_string())?;
    let encoded = RawFrame::of(&message).map_err(|error| error.to_string())?;
    Ok(encoded.value().clone())
}

/// Typed round trip for one frame by wire type name.
fn round_trip(kind: &str, value: &Value) -> Value {
    let result = match kind {
        "hello" => reencode::<HelloRequest>(value, kind),
        "hello.result" => reencode::<HelloResult>(value, kind),
        "job.create" => reencode::<JobCreateRequestFrame>(value, kind),
        "job.created" => reencode::<JobCreated>(value, kind),
        "job.input_ready" => reencode::<JobInputReadyRequest>(value, kind),
        "job.input_ready.result" => reencode::<JobInputReadyResult>(value, kind),
        "job.status" => reencode::<JobStatusRequest>(value, kind),
        "job.status.result" => reencode::<JobStatusResult>(value, kind),
        "job.subscribe" => reencode::<JobSubscribeRequest>(value, kind),
        "job.subscribe.result" => reencode::<JobSubscribeResult>(value, kind),
        "job.cancel" => reencode::<JobCancelRequest>(value, kind),
        "job.cancel.result" => reencode::<JobCancelResult>(value, kind),
        "artifact.manifest" => reencode::<ArtifactManifestRequest>(value, kind),
        "artifact.manifest.result" => reencode::<ArtifactManifestResult>(value, kind),
        "error" => reencode::<ErrorFrame>(value, kind),
        "job.event" => reencode::<JobEventFrame>(value, kind),
        other => Err(format!("no typed decoder for frame type {other:?}")),
    };
    result.unwrap_or_else(|error| panic!("could not round-trip {kind}: {error}"))
}

#[test]
fn fixtures_round_trip_through_typed_messages() {
    for path in fixture_files() {
        let fixture = load(&path);
        let name = fixture["name"].as_str().unwrap_or("unnamed");
        // Data-channel fixtures (upload status lines) are not control frames and
        // are covered by their own test below.
        let Some(request_type) = fixture["request_type"].as_str() else {
            continue;
        };
        let reply_type = fixture["reply_type"].as_str().expect("reply_type");
        let request = round_trip(request_type, &fixture["request"]);
        assert_eq!(
            canonical_json_string(&request),
            canonical_json_string(&fixture["request"]),
            "request shape drifted in fixture {name}"
        );
        let reply = round_trip(reply_type, &fixture["reply"]);
        assert_eq!(
            canonical_json_string(&reply),
            canonical_json_string(&fixture["reply"]),
            "reply shape drifted in fixture {name}"
        );

        // A documented shape must also survive a raw envelope round trip.
        let raw = RawFrame::new(fixture["request"].clone()).unwrap();
        let line = raw.to_line().unwrap();
        let parsed = RawFrame::from_line(&line).unwrap();
        assert_eq!(
            canonical_json(&parsed.value().clone()),
            canonical_json(&fixture["request"])
        );
    }
}

#[test]
fn event_fixtures_round_trip() {
    for path in fixture_files() {
        let fixture = load(&path);
        let Some(events) = fixture.get("events").and_then(Value::as_array) else {
            continue;
        };
        for event in events {
            let encoded = round_trip("job.event", event);
            assert_eq!(
                canonical_json_string(&encoded),
                canonical_json_string(event),
                "event shape drifted in {}",
                path.display()
            );
        }
    }
}

#[test]
fn event_fixture_covers_the_documented_kinds() {
    let path = fixture_dir().join("job_events.json");
    let fixture = load(&path);
    let events = fixture["events"].as_array().expect("events array");
    let kinds: Vec<String> = events
        .iter()
        .map(|event| {
            let frame: JobEventFrame = serde_json::from_value(event.clone()).expect("typed event");
            format!("{:?}", frame.kind)
        })
        .collect();
    assert!(kinds.contains(&"Log".to_string()));
    assert!(kinds.contains(&"State".to_string()));
    assert!(kinds.contains(&"Artifact".to_string()));
    assert!(kinds.contains(&"End".to_string()));

    // Log events carry the documented source/level and a human line.
    let log = &events[0];
    let level: LogLevel = serde_json::from_value(log["level"].clone()).unwrap();
    let source: LogSource = serde_json::from_value(log["source"].clone()).unwrap();
    assert_eq!(level, LogLevel::Info);
    assert_eq!(source, LogSource::Script);
    assert!(log["line"].as_str().unwrap().contains("build-recomp-ios"));
}

#[test]
fn data_channel_status_lines_round_trip() {
    let path = fixture_dir().join("upload_status.json");
    let fixture = load(&path);

    let status: UploadStatusReply =
        serde_json::from_value(fixture["status"].clone()).expect("upload.status");
    assert_eq!(status.frame_type, "upload.status");
    assert_eq!(status.received_bytes, 0);
    assert!(!status.complete);

    let progress: UploadProgress =
        serde_json::from_value(fixture["progress"].clone()).expect("upload.progress");
    assert_eq!(progress.received_bytes, 8 * 1024 * 1024);
    assert_eq!(progress.bytes, 4 * 1024 * 1024 * 1024);

    let complete: UploadComplete =
        serde_json::from_value(fixture["complete"].clone()).expect("upload.complete");
    assert!(complete.sha256_ok);
    assert_eq!(complete.received_bytes, complete.bytes);
}

#[test]
fn hello_fixture_uses_the_current_protocol_major() {
    let fixture = load(&fixture_dir().join("hello.json"));
    let protocol = fixture["request"]["protocol"].as_str().unwrap();
    assert_eq!(protocol, PROTOCOL);
    assert_eq!(protocol_major(protocol), Some(1));
    assert!(protocol_compatible(protocol));
    assert!(!protocol_compatible("3ds2apple-builder/2"));
}

#[test]
fn fixture_error_codes_are_known() {
    let fixture = load(&fixture_dir().join("error_build_failed.json"));
    let frame: ErrorFrame = serde_json::from_value(fixture["reply"].clone()).unwrap();
    assert_eq!(
        frame.error.code,
        builder_core::protocol::codes::ErrorCode::BuildFailed
    );
    assert!(!frame.error.retryable);
    assert!(frame.error.hint.is_some());
    assert!(frame.error.log_tail.as_ref().unwrap().len() <= 200);
}
