//! Data root layout and the on-disk job store.
//!
//! Layout (PROTOCOL.md §7):
//!
//! ```text
//! <data root>/                      0700
//!   config.toml                     0600
//!   agent.sock                      Unix socket for ssh-dispatch
//!   audit.jsonl                     0600
//!   jobs/<job id>/                  0700
//!     job.json                      0600  (metadata only, no ROM contents)
//!     input/{rom,keys}              0600  (deleted at terminal state)
//!     input/.staging/<role>.part    upload scratch
//!     logs/events.ndjson            0600  (job event log, replay source)
//!     out/<name>-AOT.ipa            artifact
//!     out/manifest.txt
//!     out/artifact.json
//!   cache/
//!   tmp/
//! ```
//!
//! A state transition is persisted to `job.json` before it is reported, so a
//! reconnect (or a restart) sees the same history.

use std::collections::VecDeque;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Instant;

use builder_core::protocol::model::{
    ArtifactSummary, InputSpec, JobCreateRequest, JobEvent, JobOptions, JobState, JobView, Stage,
    StageProgress, StageState, Toolchain,
};
use builder_core::protocol::{initial_stages, valid_job_id};

use crate::util;

/// Maximum number of events kept in memory for replay; the on-disk log keeps
/// the full history until the job is deleted.
pub const EVENT_TAIL_LIMIT: usize = 2_000;

/// Environment variable overriding the data root (used by tests and packagers).
pub const DATA_ROOT_ENV: &str = "BUILDER_AGENT_DATA_ROOT";

/// The Agent's private directory.
#[derive(Debug, Clone)]
pub struct DataRoot {
    pub root: PathBuf,
}

impl DataRoot {
    pub fn new(root: PathBuf) -> Self {
        Self { root }
    }

    /// Explicit flag > environment variable > platform default.
    pub fn discover(explicit: Option<PathBuf>) -> Self {
        if let Some(root) = explicit {
            return Self::new(root);
        }
        if let Some(root) = std::env::var_os(DATA_ROOT_ENV) {
            return Self::new(PathBuf::from(root));
        }
        Self::new(Self::platform_default())
    }

    pub fn platform_default() -> PathBuf {
        #[cfg(target_os = "macos")]
        {
            if let Some(home) = std::env::var_os("HOME") {
                return PathBuf::from(home)
                    .join("Library")
                    .join("Application Support")
                    .join("3ds2apple-builder-agent");
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            if let Some(data) = std::env::var_os("XDG_DATA_HOME") {
                return PathBuf::from(data).join("3ds2apple-builder-agent");
            }
            if let Some(home) = std::env::var_os("HOME") {
                return PathBuf::from(home)
                    .join(".local")
                    .join("share")
                    .join("3ds2apple-builder-agent");
            }
        }
        PathBuf::from(".3ds2apple-builder-agent")
    }

    /// Create the directory tree with owner-only permissions.
    pub fn ensure_layout(&self) -> io::Result<()> {
        util::ensure_private_dir(&self.root)?;
        util::ensure_private_dir(&self.jobs_dir())?;
        util::ensure_private_dir(&self.cache_dir())?;
        util::ensure_private_dir(&self.tmp_dir())?;
        Ok(())
    }

    pub fn socket_path(&self) -> PathBuf {
        self.root.join("agent.sock")
    }

    pub fn audit_log_path(&self) -> PathBuf {
        self.root.join("audit.jsonl")
    }

    pub fn jobs_dir(&self) -> PathBuf {
        self.root.join("jobs")
    }

    pub fn cache_dir(&self) -> PathBuf {
        self.root.join("cache")
    }

    pub fn tmp_dir(&self) -> PathBuf {
        self.root.join("tmp")
    }

    pub fn job_dir(&self, job_id: &str) -> PathBuf {
        self.jobs_dir().join(job_id)
    }

    pub fn events_path(&self, job_id: &str) -> PathBuf {
        self.job_dir(job_id).join("logs").join("events.ndjson")
    }

    /// Append one audit line (job actions; never file contents).
    pub fn audit(&self, action: &str, job_id: &str, detail: &str) {
        let line = format!(
            "{{\"ts\":\"{}\",\"action\":\"{}\",\"job_id\":\"{}\",\"detail\":\"{}\"}}\n",
            util::now(),
            action,
            job_id,
            detail.replace(['"', '\\', '\n', '\r'], " ")
        );
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.audit_log_path())
        {
            let _ = util::set_private_file(&self.audit_log_path());
            let _ = file.write_all(line.as_bytes());
        }
    }
}

/// Path helpers for one job's directory tree.
pub fn input_dir(job_dir: &Path) -> PathBuf {
    job_dir.join("input")
}

pub fn staging_dir(job_dir: &Path) -> PathBuf {
    job_dir.join("input").join(".staging")
}

pub fn out_dir(job_dir: &Path) -> PathBuf {
    job_dir.join("out")
}

pub fn logs_dir(job_dir: &Path) -> PathBuf {
    job_dir.join("logs")
}

/// Create the subdirectories for a new job with owner-only permissions.
pub fn create_job_layout(job_dir: &Path) -> io::Result<()> {
    util::ensure_private_dir(job_dir)?;
    util::ensure_private_dir(&input_dir(job_dir))?;
    util::ensure_private_dir(&staging_dir(job_dir))?;
    util::ensure_private_dir(&out_dir(job_dir))?;
    util::ensure_private_dir(&logs_dir(job_dir))
}

/// Persisted job metadata (`job.json`).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct JobPersist {
    pub job_id: String,
    pub request: JobCreateRequest,
    /// SHA256 of the canonical create request; detects a reused `request_id`
    /// with different parameters.
    pub request_fingerprint: String,
    pub state: JobState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage: Option<Stage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stage_state: Option<StageState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub percent: Option<u8>,
    pub seq: u64,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    pub updated_at: String,
    pub updated_unix: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<String>,
    #[serde(default)]
    pub queue_position: Option<u32>,
    #[serde(default)]
    pub stages: Vec<StageProgress>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_revision: Option<String>,
    #[serde(default)]
    pub toolchain: Toolchain,
    #[serde(default)]
    pub inputs_verified: bool,
    #[serde(default)]
    pub inputs_present: bool,
    #[serde(default)]
    pub inputs_kept: bool,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<builder_core::protocol::model::ErrorInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact: Option<ArtifactSummary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<serde_json::Value>,
    #[serde(default)]
    pub cancel_requested: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub process_group: Option<i32>,
    #[serde(default)]
    pub artifact_acked: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fake: Option<bool>,
}

impl JobPersist {
    /// Build fresh metadata for an accepted job.
    pub fn new(
        job_id: String,
        request: JobCreateRequest,
        request_fingerprint: String,
        toolchain: Toolchain,
        source_revision: Option<String>,
        now: String,
    ) -> Self {
        Self {
            job_id,
            request,
            request_fingerprint,
            state: JobState::Created,
            stage: None,
            stage_state: None,
            percent: None,
            seq: 0,
            created_at: now.clone(),
            started_at: None,
            updated_at: now,
            updated_unix: util::unix_now(),
            finished_at: None,
            queue_position: None,
            stages: initial_stages(),
            source_revision,
            toolchain,
            inputs_verified: false,
            inputs_present: false,
            inputs_kept: false,
            warnings: Vec::new(),
            error: None,
            artifact: None,
            detail: None,
            cancel_requested: false,
            process_group: None,
            artifact_acked: false,
            fake: None,
        }
    }

    pub fn options(&self) -> &JobOptions {
        &self.request.options
    }

    pub fn expected_revision(&self) -> Option<&str> {
        self.request
            .source
            .as_ref()
            .and_then(|source| source.expected_revision.as_deref())
    }

    pub fn declared_input(
        &self,
        role: builder_core::protocol::model::InputRole,
    ) -> Option<&InputSpec> {
        self.request.inputs.iter().find(|input| input.role == role)
    }

    /// Public status snapshot.
    pub fn to_view(&self) -> JobView {
        JobView {
            job_id: self.job_id.clone(),
            game: Some(self.request.game.clone()),
            state: self.state,
            stage: self.stage,
            stage_state: self.stage_state,
            percent: self.percent,
            detail: self.detail.clone(),
            created_at: self.created_at.clone(),
            started_at: self.started_at.clone(),
            updated_at: self.updated_at.clone(),
            finished_at: self.finished_at.clone(),
            queue_position: self.queue_position,
            stages: self.stages.clone(),
            source_revision: self.source_revision.clone(),
            toolchain: Some(self.toolchain.clone()),
            inputs_present: self.inputs_present,
            inputs_kept: self.inputs_kept,
            warnings: self.warnings.clone(),
            error: self.error.clone(),
            artifact: self.artifact.clone(),
        }
    }
}

/// Runtime state for a job: persisted metadata plus the in-memory event tail and
/// stage timer.
#[derive(Debug)]
pub struct JobRecord {
    pub job: JobPersist,
    pub tail: VecDeque<JobEvent>,
    pub stage_started: Option<Instant>,
}

impl JobRecord {
    pub fn new(job: JobPersist) -> Self {
        Self {
            job,
            tail: VecDeque::new(),
            stage_started: None,
        }
    }
}

/// A job owned by the running service.
#[derive(Debug)]
pub struct JobEntry {
    pub dir: PathBuf,
    pub events_path: PathBuf,
    pub out_dir: PathBuf,
    pub rec: Mutex<JobRecord>,
}

impl JobEntry {
    pub fn new(dir: PathBuf, events_path: PathBuf, job: JobPersist) -> Self {
        Self {
            out_dir: out_dir(&dir),
            dir,
            events_path,
            rec: Mutex::new(JobRecord::new(job)),
        }
    }

    pub fn job_id(&self) -> String {
        self.rec
            .lock()
            .expect("job record poisoned")
            .job
            .job_id
            .clone()
    }

    pub fn with<R>(&self, f: impl FnOnce(&mut JobRecord) -> R) -> R {
        let mut record = self.rec.lock().expect("job record poisoned");
        f(&mut record)
    }

    pub fn snapshot(&self) -> JobView {
        self.with(|record| record.job.to_view())
    }

    /// Persist while the caller already holds the record lock.
    pub fn persist_locked(record: &JobRecord, dir: &Path) -> io::Result<()> {
        write_job_json(dir, &record.job)
    }
}

/// Write `job.json` for a job directory.
pub fn write_job_json(job_dir: &Path, job: &JobPersist) -> io::Result<()> {
    util::write_json(&job_dir.join("job.json"), job)
}

/// Load `job.json` from a job directory.
pub fn load_job_json(job_dir: &Path) -> io::Result<JobPersist> {
    util::read_json(&job_dir.join("job.json"))
}

/// Load every job under `<data root>/jobs`.
pub fn load_all_jobs(data: &DataRoot) -> Vec<(PathBuf, JobPersist)> {
    let Ok(entries) = std::fs::read_dir(data.jobs_dir()) else {
        return Vec::new();
    };
    let mut jobs = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        if !valid_job_id(name) {
            continue;
        }
        if let Ok(job) = load_job_json(&path) {
            jobs.push((path, job));
        }
    }
    jobs.sort_by(|left, right| right.1.created_at.cmp(&left.1.created_at));
    jobs
}

/// Append one event to the job's on-disk event log.
pub fn append_event(events_path: &Path, event: &JobEvent) -> io::Result<()> {
    if let Some(parent) = events_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut line = serde_json::to_string(event)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    line.push('\n');
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(events_path)?;
    file.write_all(line.as_bytes())?;
    Ok(())
}

/// Read the retained events for a job, in sequence order.
pub fn read_events(events_path: &Path) -> Vec<JobEvent> {
    let Ok(text) = std::fs::read_to_string(events_path) else {
        return Vec::new();
    };
    let mut events = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Ok(event) = serde_json::from_str::<JobEvent>(line) {
            events.push(event);
        }
    }
    events
}

/// Delete a job directory after validating that the id cannot escape the jobs
/// directory.
pub fn delete_job_dir(data: &DataRoot, job_id: &str) -> io::Result<()> {
    if !valid_job_id(job_id) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid job id",
        ));
    }
    let dir = data.job_dir(job_id);
    if !util::path_is_within(&dir, &data.jobs_dir()) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "refusing to delete a path outside the jobs directory",
        ));
    }
    util::remove_path_if_exists(&dir)
}

/// Input file path for a role inside the job directory.
pub fn input_path(job_dir: &Path, role: builder_core::protocol::model::InputRole) -> PathBuf {
    input_dir(job_dir).join(role.file_name())
}

/// Staging path for an in-progress upload of a role.
pub fn staging_path(job_dir: &Path, role: builder_core::protocol::model::InputRole) -> PathBuf {
    staging_dir(job_dir).join(format!("{}.part", role.file_name()))
}

/// Outcome of checking declared inputs against what is on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputCheck {
    Complete,
    Missing {
        role: String,
    },
    WrongSize {
        role: String,
        expected: u64,
        actual: u64,
    },
    WrongHash {
        role: String,
        expected: String,
        actual: String,
    },
}

/// Verify that every declared input is present with the declared size and hash.
pub fn verify_declared_inputs(job_dir: &Path, inputs: &[InputSpec]) -> InputCheck {
    for input in inputs {
        let path = input_path(job_dir, input.role);
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            return InputCheck::Missing {
                role: input.role.as_str().to_string(),
            };
        };
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return InputCheck::Missing {
                role: input.role.as_str().to_string(),
            };
        }
        if metadata.len() != input.bytes {
            return InputCheck::WrongSize {
                role: input.role.as_str().to_string(),
                expected: input.bytes,
                actual: metadata.len(),
            };
        }
        match builder_core::hash::sha256_file(&path) {
            Ok(hash) if hash.sha256.eq_ignore_ascii_case(&input.sha256) => {}
            Ok(hash) => {
                return InputCheck::WrongHash {
                    role: input.role.as_str().to_string(),
                    expected: input.sha256.clone(),
                    actual: hash.sha256,
                }
            }
            Err(_) => {
                return InputCheck::Missing {
                    role: input.role.as_str().to_string(),
                }
            }
        }
    }
    InputCheck::Complete
}

/// Size of the staging file for a role, or 0 when absent.
pub fn staging_size(job_dir: &Path, role: builder_core::protocol::model::InputRole) -> u64 {
    std::fs::metadata(staging_path(job_dir, role))
        .map(|metadata| metadata.len())
        .unwrap_or(0)
}

#[cfg(test)]
pub(crate) fn test_job_id() -> String {
    util::new_job_id()
}

#[cfg(test)]
pub(crate) fn sample_request(name: &str) -> JobCreateRequest {
    use builder_core::protocol::model::{GameSpec, InputRole, InputSpec};
    JobCreateRequest {
        request_id: format!("req-{name}"),
        game: GameSpec {
            name: name.to_string(),
            display_name: "Test Game".to_string(),
            bundle_id: None,
            title_id: None,
        },
        inputs: vec![InputSpec {
            role: InputRole::Rom,
            name: "test.cci".to_string(),
            bytes: 4,
            sha256: builder_core::hash::sha256_hex(b"test"),
        }],
        options: JobOptions::default(),
        source: None,
        transport: builder_core::protocol::model::TransportMode::Upload,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use builder_core::protocol::model::InputRole;

    fn temp_data() -> (tempfile::TempDir, DataRoot) {
        let dir = tempfile::tempdir().unwrap();
        let data = DataRoot::new(dir.path().to_path_buf());
        data.ensure_layout().unwrap();
        (dir, data)
    }

    #[test]
    fn layout_and_job_json_round_trip() {
        let (_dir, data) = temp_data();
        let job_id = test_job_id();
        let job_dir = data.job_dir(&job_id);
        create_job_layout(&job_dir).unwrap();
        let job = JobPersist::new(
            job_id.clone(),
            sample_request("pokemon-y"),
            "fingerprint".to_string(),
            Toolchain::default(),
            None,
            util::now(),
        );
        write_job_json(&job_dir, &job).unwrap();
        let loaded = load_job_json(&job_dir).unwrap();
        assert_eq!(loaded.job_id, job_id);
        assert_eq!(loaded.state, JobState::Created);
        let all = load_all_jobs(&data);
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].1.job_id, job_id);
    }

    #[test]
    fn delete_refuses_invalid_ids() {
        let (_dir, data) = temp_data();
        assert!(delete_job_dir(&data, "job_/etc").is_err());
        assert!(delete_job_dir(&data, "..").is_err());
        assert!(delete_job_dir(&data, &test_job_id()).is_ok());
    }

    #[test]
    fn event_log_round_trip_and_append() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("logs/events.ndjson");
        let event = JobEvent {
            seq: 1,
            job_id: test_job_id(),
            ts: util::now(),
            kind: builder_core::protocol::model::EventKind::Log,
            stage: None,
            source: None,
            level: None,
            line: Some("hello".to_string()),
            line_part: None,
            line_parts: None,
            state: None,
            error: None,
            artifact: None,
            message: None,
        };
        append_event(&path, &event).unwrap();
        append_event(
            &path,
            &JobEvent {
                seq: 2,
                ..event.clone()
            },
        )
        .unwrap();
        let events = read_events(&path);
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].seq, 2);
    }

    #[test]
    fn input_verification_detects_all_problems() {
        let dir = tempfile::tempdir().unwrap();
        let job_dir = dir.path();
        create_job_layout(job_dir).unwrap();
        let request = sample_request("game");
        let inputs = &request.inputs;
        assert!(matches!(
            verify_declared_inputs(job_dir, inputs),
            InputCheck::Missing { .. }
        ));
        std::fs::write(input_path(job_dir, InputRole::Rom), b"wrong").unwrap();
        assert!(matches!(
            verify_declared_inputs(job_dir, inputs),
            InputCheck::WrongSize { .. }
        ));
        std::fs::write(input_path(job_dir, InputRole::Rom), b"nope").unwrap();
        assert!(matches!(
            verify_declared_inputs(job_dir, inputs),
            InputCheck::WrongHash { .. }
        ));
        std::fs::write(input_path(job_dir, InputRole::Rom), b"test").unwrap();
        assert_eq!(
            verify_declared_inputs(job_dir, inputs),
            InputCheck::Complete
        );
    }

    #[test]
    fn events_are_private_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("events.ndjson");
        let event = JobEvent {
            seq: 1,
            job_id: test_job_id(),
            ts: util::now(),
            kind: builder_core::protocol::model::EventKind::Heartbeat,
            stage: None,
            source: None,
            level: None,
            line: None,
            line_part: None,
            line_parts: None,
            state: None,
            error: None,
            artifact: None,
            message: None,
        };
        append_event(&path, &event).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
    }
}
