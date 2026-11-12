//! Protocol data model: job states, stages, requests, views, events and the
//! artifact record.
//!
//! These are the shapes documented in `builder/PROTOCOL.md` §5–§6. They are
//! plain `serde` structs; unknown fields are ignored on decode, so additive
//! protocol changes stay compatible inside protocol major 1.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::protocol::codes::ErrorCode;
use crate::protocol::PROTOCOL;

/// The protocol string this build speaks.
pub fn protocol_string() -> &'static str {
    PROTOCOL
}

// ---------------------------------------------------------------------------
// Job states and stages
// ---------------------------------------------------------------------------

/// Job state machine value (PROTOCOL.md §6.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Created,
    Queued,
    Running,
    Canceling,
    Succeeded,
    Failed,
    Canceled,
    Interrupted,
}

impl JobState {
    pub const ALL: [JobState; 8] = [
        JobState::Created,
        JobState::Queued,
        JobState::Running,
        JobState::Canceling,
        JobState::Succeeded,
        JobState::Failed,
        JobState::Canceled,
        JobState::Interrupted,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            JobState::Created => "created",
            JobState::Queued => "queued",
            JobState::Running => "running",
            JobState::Canceling => "canceling",
            JobState::Succeeded => "succeeded",
            JobState::Failed => "failed",
            JobState::Canceled => "canceled",
            JobState::Interrupted => "interrupted",
        }
    }

    /// Terminal states never change again and release the build slot.
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            JobState::Succeeded | JobState::Failed | JobState::Canceled | JobState::Interrupted
        )
    }

    /// States that hold (or wait for) a build slot.
    pub fn is_active(self) -> bool {
        !self.is_terminal()
    }

    /// Title-case label for human output.
    pub fn label(self) -> &'static str {
        match self {
            JobState::Created => "Created",
            JobState::Queued => "Queued",
            JobState::Running => "Running",
            JobState::Canceling => "Canceling",
            JobState::Succeeded => "Succeeded",
            JobState::Failed => "Failed",
            JobState::Canceled => "Canceled",
            JobState::Interrupted => "Interrupted",
        }
    }
}

impl std::fmt::Display for JobState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Build stages in execution order (PROTOCOL.md §6.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Preparing,
    Recompiling,
    Linking,
    Packaging,
    Verifying,
}

impl Stage {
    pub const ALL: [Stage; 5] = [
        Stage::Preparing,
        Stage::Recompiling,
        Stage::Linking,
        Stage::Packaging,
        Stage::Verifying,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Stage::Preparing => "preparing",
            Stage::Recompiling => "recompiling",
            Stage::Linking => "linking",
            Stage::Packaging => "packaging",
            Stage::Verifying => "verifying",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Stage::Preparing => "Preparing",
            Stage::Recompiling => "Recompiling",
            Stage::Linking => "Linking",
            Stage::Packaging => "Packaging",
            Stage::Verifying => "Verifying",
        }
    }

    /// One-sentence explanation shown by the CLI/GUI ("what is happening").
    pub fn description(self) -> &'static str {
        match self {
            Stage::Preparing => "checking the Mac, the toolchain and the source checkout",
            Stage::Recompiling => "translating the game's code to C and compiling it for iOS",
            Stage::Linking => "building the linked runtime and the game archive",
            Stage::Packaging => "building the app with Xcode and packaging the unsigned IPA",
            Stage::Verifying => "checking the SHA256 and manifest, finalising the artifact",
        }
    }

    /// Position in the stage list (0-based).
    pub fn index(self) -> usize {
        match self {
            Stage::Preparing => 0,
            Stage::Recompiling => 1,
            Stage::Linking => 2,
            Stage::Packaging => 3,
            Stage::Verifying => 4,
        }
    }

    /// Coarse, honest percent floor for a stage: progress is reported as
    /// "somewhere in this stage" rather than as a fake number.
    pub fn base_percent(self) -> u8 {
        match self {
            Stage::Preparing => 2,
            Stage::Recompiling => 15,
            Stage::Linking => 70,
            Stage::Packaging => 88,
            Stage::Verifying => 97,
        }
    }

    /// Percent span of a stage; used with sub-progress counters when known.
    pub fn percent_span(self) -> u8 {
        match self {
            Stage::Preparing => 13,
            Stage::Recompiling => 55,
            Stage::Linking => 18,
            Stage::Packaging => 9,
            Stage::Verifying => 3,
        }
    }

    pub fn next(self) -> Option<Stage> {
        Stage::ALL.get(self.index() + 1).copied()
    }
}

impl std::fmt::Display for Stage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Per-stage state inside a job status snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StageState {
    Pending,
    Running,
    Done,
    Failed,
    Skipped,
}

/// One entry of the stage list in a job status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StageProgress {
    pub name: Stage,
    pub state: StageState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

impl StageProgress {
    pub fn pending(stage: Stage) -> Self {
        Self {
            name: stage,
            state: StageState::Pending,
            duration_ms: None,
        }
    }
}

/// Build the initial stage list (all pending) for a new job.
pub fn initial_stages() -> Vec<StageProgress> {
    Stage::ALL
        .iter()
        .copied()
        .map(StageProgress::pending)
        .collect()
}

// ---------------------------------------------------------------------------
// Game, inputs and options
// ---------------------------------------------------------------------------

/// Game identity used by the build scripts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameSpec {
    /// Build name: `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`; becomes a path component
    /// inside the Agent's checkout build tree.
    pub name: String,
    /// Home-screen display name (1–48 printable characters).
    pub display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title_id: Option<String>,
}

/// Input roles the protocol defines in v1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputRole {
    Rom,
    Keys,
}

impl InputRole {
    pub const ALL: [InputRole; 2] = [InputRole::Rom, InputRole::Keys];

    /// Stable file name inside the job input directory (never the user's name).
    pub fn file_name(self) -> &'static str {
        match self {
            InputRole::Rom => "rom",
            InputRole::Keys => "keys",
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            InputRole::Rom => "rom",
            InputRole::Keys => "keys",
        }
    }
}

impl std::fmt::Display for InputRole {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::str::FromStr for InputRole {
    type Err = ();

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "rom" => Ok(InputRole::Rom),
            "keys" => Ok(InputRole::Keys),
            _ => Err(()),
        }
    }
}

/// Declared input file in `job.create`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InputSpec {
    pub role: InputRole,
    /// Display metadata only; never used as a path.
    pub name: String,
    pub bytes: u64,
    /// Lowercase hex SHA256.
    pub sha256: String,
}

/// Build options (PROTOCOL.md §6.2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobOptions {
    #[serde(default = "default_true")]
    pub embed_moltenvk: bool,
    #[serde(default)]
    pub hardware_renderer: bool,
    #[serde(default)]
    pub clean: bool,
    /// Keep the ROM/keys on the Mac after the job. Explicit opt-in; the client
    /// shows a warning before setting it.
    #[serde(default)]
    pub keep_input: bool,
}

fn default_true() -> bool {
    true
}

impl Default for JobOptions {
    fn default() -> Self {
        Self {
            embed_moltenvk: true,
            hardware_renderer: false,
            clean: false,
            keep_input: false,
        }
    }
}

/// How the Agent obtains the inputs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransportMode {
    #[default]
    Upload,
    Path,
}

/// Optional source revision expectation.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct SourceExpectation {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_revision: Option<String>,
}

/// `job.create` request body (without the frame envelope).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobCreateRequest {
    /// Idempotency key chosen by the client.
    pub request_id: String,
    pub game: GameSpec,
    pub inputs: Vec<InputSpec>,
    #[serde(default)]
    pub options: JobOptions,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceExpectation>,
    #[serde(default)]
    pub transport: TransportMode,
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

/// Client description sent in `hello`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientInfo {
    pub name: String,
    pub version: String,
    pub os: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
}

/// Agent description returned in `hello.result`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentInfo {
    pub version: String,
    pub id: String,
    pub os: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    pub arch: String,
}

/// Toolchain versions the Agent reports. Missing tools are `None`; the Agent is
/// expected to say clearly what it does not have rather than guessing.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Toolchain {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xcode: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ios_sdk: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rust: Option<String>,
    #[serde(default)]
    pub rust_target_installed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub xcodegen: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub python: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git: Option<String>,
}

impl Toolchain {
    /// One-line summary for `zkb host test` / `doctor`.
    pub fn summary(&self) -> String {
        let mut parts = Vec::new();
        parts.push(format!(
            "Xcode {}",
            self.xcode.as_deref().unwrap_or("missing")
        ));
        parts.push(format!(
            "iOS SDK {}",
            self.ios_sdk.as_deref().unwrap_or("missing")
        ));
        parts.push(format!(
            "Rust {}",
            self.rust.as_deref().unwrap_or("missing")
        ));
        if !self.rust_target_installed {
            parts.push("iOS Rust target missing".to_string());
        }
        parts.push(format!(
            "xcodegen {}",
            self.xcodegen.as_deref().unwrap_or("missing")
        ));
        parts.push(format!(
            "Python {}",
            self.python.as_deref().unwrap_or("missing")
        ));
        parts.join(", ")
    }
}

/// Source checkout the Agent will build from.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct SourceInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    #[serde(default)]
    pub dirty: bool,
    #[serde(default)]
    pub scripts_present: bool,
}

/// Agent limits advertised in `hello` (PROTOCOL.md §5).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Limits {
    pub max_input_bytes: u64,
    pub max_queued_jobs: u32,
    pub max_concurrent_builds: u32,
    pub artifact_retention_hours: u64,
    pub job_retention_hours: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_input_bytes: 8 * 1024 * 1024 * 1024,
            max_queued_jobs: 4,
            max_concurrent_builds: 1,
            artifact_retention_hours: 168,
            job_retention_hours: 168,
        }
    }
}

// ---------------------------------------------------------------------------
// Upload plan and job creation reply
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadRole {
    pub role: InputRole,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadPlan {
    pub roles: Vec<UploadRole>,
    pub chunk_hint: u64,
    /// RFC 3339 deadline after which an un-uploaded `created` job is canceled.
    pub expires_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueLimits {
    pub max_queued_jobs: u32,
    pub max_concurrent_builds: u32,
}

// ---------------------------------------------------------------------------
// Job status views
// ---------------------------------------------------------------------------

/// Machine-readable error object (PROTOCOL.md §8.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorInfo {
    pub code: ErrorCode,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<Stage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
    #[serde(default)]
    pub retryable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log_tail: Option<Vec<String>>,
}

impl ErrorInfo {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            stage: None,
            hint: code.hint().map(str::to_string),
            retryable: code.retryable(),
            details: None,
            log_tail: None,
        }
    }

    pub fn with_stage(mut self, stage: Stage) -> Self {
        self.stage = Some(stage);
        self
    }

    pub fn with_hint(mut self, hint: impl Into<String>) -> Self {
        self.hint = Some(hint.into());
        self
    }

    pub fn with_details(mut self, details: Value) -> Self {
        self.details = Some(details);
        self
    }

    pub fn with_log_tail(mut self, lines: Vec<String>) -> Self {
        if !lines.is_empty() {
            self.log_tail = Some(lines);
        }
        self
    }
}

impl std::fmt::Display for ErrorInfo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

/// Artifact summary used in status/list frames.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactSummary {
    pub name: String,
    pub bytes: u64,
    pub sha256: String,
}

/// Job status snapshot (`job.status.result` / `job.subscribe.result`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobView {
    pub job_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub game: Option<GameSpec>,
    pub state: JobState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<Stage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage_state: Option<StageState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub percent: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<Value>,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub queue_position: Option<u32>,
    pub stages: Vec<StageProgress>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toolchain: Option<Toolchain>,
    #[serde(default)]
    pub inputs_present: bool,
    #[serde(default)]
    pub inputs_kept: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<ArtifactSummary>,
}

impl JobView {
    /// True once the job cannot change anymore.
    pub fn is_terminal(&self) -> bool {
        self.state.is_terminal()
    }
}

/// Entry of `job.list.result`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobListEntry {
    pub job_id: String,
    pub state: JobState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub game: Option<GameSpec>,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<ArtifactSummary>,
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// Event kind carried by `job.event` (PROTOCOL.md §6.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    State,
    Log,
    Warning,
    Artifact,
    End,
    Heartbeat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LogSource {
    Agent,
    Script,
    Xcodebuild,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

/// One event in a job's ordered stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobEvent {
    pub seq: u64,
    pub job_id: String,
    /// RFC 3339 UTC timestamp.
    pub ts: String,
    pub kind: EventKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<Stage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<LogSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub level: Option<LogLevel>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<String>,
    /// 1-based part number when a long log line was split.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_part: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_parts: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<JobState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<ArtifactSummary>,
    /// Free-form short note for `warning` / `heartbeat` events.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl JobEvent {
    /// Reassemble the log line carried by a run of parts, if this event holds
    /// the last part; otherwise the caller keeps accumulating.
    pub fn is_log(&self) -> bool {
        self.kind == EventKind::Log
    }

    pub fn is_end(&self) -> bool {
        self.kind == EventKind::End
    }
}

// ---------------------------------------------------------------------------
// Artifact record (artifact.json)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactFile {
    pub name: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactSource {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_revision: Option<String>,
    #[serde(rename = "match")]
    pub revision_matches: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuildTiming {
    pub started_at: String,
    pub finished_at: String,
    #[serde(default)]
    pub warnings: Vec<String>,
}

/// The machine-readable artifact record written to `out/artifact.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactRecord {
    pub artifact_version: u32,
    pub job_id: String,
    pub game: GameSpec,
    pub ipa: ArtifactFile,
    pub manifest_txt: ArtifactFile,
    pub source: ArtifactSource,
    pub toolchain: Toolchain,
    pub build: BuildTiming,
    pub retention_until: String,
    /// Set only by the Agent's fake-build mode used for tests; never present on
    /// a real build.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fake: Option<bool>,
}

// ---------------------------------------------------------------------------
// Upload progress frames (SSH data channels / HTTP bodies)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadProgress {
    #[serde(rename = "type")]
    pub frame_type: String,
    pub received_bytes: u64,
    pub bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadStatusReply {
    #[serde(rename = "type")]
    pub frame_type: String,
    pub received_bytes: u64,
    pub bytes: u64,
    pub sha256_ok: bool,
    pub complete: bool,
}

// ---------------------------------------------------------------------------
// Doctor report (ssh `doctor --json` and `zkb host test`)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DoctorReport {
    pub agent_version: String,
    pub protocol: String,
    pub os: String,
    pub arch: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    pub is_root: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
    pub data_root: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkout: Option<String>,
    pub source: SourceInfo,
    pub toolchain: Toolchain,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disk_free_bytes: Option<u64>,
    pub disk_required_bytes: u64,
    pub limits: Limits,
    pub ready: bool,
    #[serde(default)]
    pub refusals: Vec<String>,
    /// Non-fatal notes such as "fake build mode" or "MoltenVK not cached".
    #[serde(default)]
    pub notes: Vec<String>,
    pub generated_at: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stages_are_ordered_and_complete() {
        for (index, stage) in Stage::ALL.iter().enumerate() {
            assert_eq!(stage.index(), index);
            assert!(stage.base_percent() <= 100);
            assert!(stage.percent_span() > 0);
        }
        assert_eq!(Stage::Preparing.next(), Some(Stage::Recompiling));
        assert_eq!(Stage::Verifying.next(), None);
    }

    #[test]
    fn job_state_terminality() {
        for state in JobState::ALL {
            assert_eq!(state.is_terminal(), !state.is_active());
            assert_eq!(
                state.is_terminal(),
                matches!(
                    state,
                    JobState::Succeeded
                        | JobState::Failed
                        | JobState::Canceled
                        | JobState::Interrupted
                )
            );
        }
    }

    #[test]
    fn artifact_json_shape_round_trips() {
        let record = ArtifactRecord {
            artifact_version: 1,
            job_id: "job_01J8Z3K4T9ABCDEFGHJKMNPQRS".into(),
            game: GameSpec {
                name: "pokemon-y".into(),
                display_name: "Pokemon Y".into(),
                bundle_id: Some("com.kratos.3ds2apple.pokemon-y".into()),
                title_id: Some("0004000000055E00".into()),
            },
            ipa: ArtifactFile {
                name: "pokemon-y-AOT.ipa".into(),
                bytes: 100,
                sha256: "ab".into(),
            },
            manifest_txt: ArtifactFile {
                name: "manifest.txt".into(),
                bytes: 10,
                sha256: "cd".into(),
            },
            source: ArtifactSource {
                repo_revision: Some("abc".into()),
                expected_revision: None,
                revision_matches: true,
            },
            toolchain: Toolchain {
                xcode: Some("16.4".into()),
                ..Toolchain::default()
            },
            build: BuildTiming {
                started_at: "2026-11-12T19:33:10Z".into(),
                finished_at: "2026-11-12T19:58:02Z".into(),
                warnings: vec![],
            },
            retention_until: "2026-11-19T19:58:02Z".into(),
            fake: None,
        };
        let json = serde_json::to_string(&record).unwrap();
        let back: ArtifactRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(record, back);
        let value: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["source"]["match"], Value::Bool(true));
        assert!(value["ipa"]["sha256"].is_string());
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let json = r#"{
            "job_id": "job_x", "state": "running", "stage": null,
            "created_at": "2026-11-12T19:33:10Z", "updated_at": "2026-11-12T19:33:10Z",
            "stages": [], "inputs_present": true, "inputs_kept": false,
            "future_field": {"anything": 1}
        }"#;
        let view: JobView = serde_json::from_str(json).unwrap();
        assert_eq!(view.state, JobState::Running);
    }
}
