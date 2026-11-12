//! The Agent's job service: job store in memory, one build slot, event
//! broadcast, cancellation and terminal cleanup.
//!
//! One [`Service`] per Agent process. The control sessions (stdio or the Unix
//! socket daemon) talk to it; a single worker thread consumes the FIFO queue.

use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Instant;

use builder_core::hash::sha256_hex;
use builder_core::protocol::codes::ErrorCode;
use builder_core::protocol::frames::{
    HelloResult, JobCancelResult, JobCreated, JobDeleteResult, JobInputReadyResult, JobListResult,
    JobSubscribeResult,
};
use builder_core::protocol::model::{
    AgentInfo, ArtifactRecord, ArtifactSummary, ErrorInfo, EventKind, JobCreateRequest, JobEvent,
    JobListEntry, JobState, Limits, LogLevel, LogSource, QueueLimits, Stage, StageState, Toolchain,
    UploadPlan, UploadRole,
};
use builder_core::protocol::{
    valid_job_id, valid_request_id, DEFAULT_CHUNK_HINT, MAX_LOG_LINE_BYTES, PROTOCOL,
};
use builder_core::util::{canonical_json_string, rfc3339_from_unix, unix_now};

use crate::cleanup;
use crate::config::AgentConfig;
use crate::doctor;
use crate::store::{self, DataRoot, JobEntry, JobPersist, EVENT_TAIL_LIMIT};
use crate::util;
use crate::worker::WorkerOutcome;

/// Default lifetime of a `created` job waiting for its inputs.
pub const INPUT_TIMEOUT_SECONDS: u64 = 3_600;

/// Capabilities advertised by this Agent.
pub const AGENT_CAPABILITIES: [&str; 7] = [
    "events.stream",
    "upload.resume",
    "artifact.range",
    "keep_input",
    "gpu_options",
    "job.delete",
    "job.list",
];

/// Shared Agent state.
pub struct Service {
    pub cfg: AgentConfig,
    pub data: DataRoot,
    pub toolchain: Toolchain,
    pub source: builder_core::protocol::model::SourceInfo,
    pub started_at: String,
    jobs: Mutex<BTreeMap<String, Arc<JobEntry>>>,
    subscribers: Arc<Mutex<Vec<Subscriber>>>,
    next_subscriber: AtomicU64,
    queue: Mutex<QueueState>,
    queue_cv: Condvar,
}

impl std::fmt::Debug for Service {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Service")
            .field("cfg", &self.cfg)
            .field("data", &self.data)
            .field("started_at", &self.started_at)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone)]
struct Subscriber {
    id: u64,
    job_id: String,
    tx: Sender<JobEvent>,
}

#[derive(Debug, Default)]
struct QueueState {
    queued: VecDeque<String>,
    running: Option<String>,
}

/// A live event subscription. Dropping it unregisters the channel.
pub struct SubscriberGuard {
    registry: Arc<Mutex<Vec<Subscriber>>>,
    id: u64,
}

impl std::fmt::Debug for SubscriberGuard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SubscriberGuard")
            .field("id", &self.id)
            .finish()
    }
}

impl Drop for SubscriberGuard {
    fn drop(&mut self) {
        if let Ok(mut subscribers) = self.registry.lock() {
            subscribers.retain(|subscriber| subscriber.id != self.id);
        }
    }
}

/// Result of `job.subscribe`: retained events first, then live ones.
#[derive(Debug)]
pub struct Subscription {
    pub _guard: SubscriberGuard,
    pub replay: Vec<JobEvent>,
    pub events: Receiver<JobEvent>,
}

impl Service {
    /// Open the data root, recover persisted jobs and prepare the toolchain
    /// description. The worker thread is started separately with
    /// [`Service::start_worker`].
    pub fn open(cfg: AgentConfig, data: DataRoot) -> Result<Arc<Self>, String> {
        cfg.validate()?;
        if util::is_root() {
            return Err("the Build Agent refuses to run as root".to_string());
        }
        data.ensure_layout()
            .map_err(|error| format!("could not create data root: {error}"))?;
        let toolchain = doctor::detect_toolchain();
        let source = doctor::detect_source(cfg.checkout.as_deref());
        let service = Arc::new(Self {
            cfg,
            data,
            toolchain,
            source,
            started_at: util::now(),
            jobs: Mutex::new(BTreeMap::new()),
            subscribers: Arc::new(Mutex::new(Vec::new())),
            next_subscriber: AtomicU64::new(1),
            queue: Mutex::new(QueueState::default()),
            queue_cv: Condvar::new(),
        });
        service.load_persisted_jobs()?;
        Ok(service)
    }

    /// Start the single build-slot worker thread (idempotent).
    pub fn start_worker(self: &Arc<Self>) {
        let service = Arc::clone(self);
        std::thread::Builder::new()
            .name("builder-agent-worker".to_string())
            .spawn(move || service.worker_loop())
            .expect("could not start the build worker thread");
    }

    fn load_persisted_jobs(&self) -> Result<(), String> {
        let mut jobs = BTreeMap::new();
        for (dir, mut job) in store::load_all_jobs(&self.data) {
            let events_path = self.data.events_path(&job.job_id);
            let mut tail: VecDeque<JobEvent> =
                store::read_events(&events_path).into_iter().collect();
            while tail.len() > EVENT_TAIL_LIMIT {
                tail.pop_front();
            }
            if let Some(last) = tail.back() {
                job.seq = job.seq.max(last.seq);
            }
            if !job.state.is_terminal() {
                // Recovery: no automatic resume in this version.
                job.state = JobState::Interrupted;
                job.error = Some(ErrorInfo::new(
                    ErrorCode::Interrupted,
                    "the Agent restarted while this job was active; start a new build",
                ));
                job.finished_at = Some(util::now());
                job.updated_at = util::now();
                job.updated_unix = unix_now();
                job.cancel_requested = true;
                let cleanup = cleanup::remove_inputs(&dir);
                job.inputs_present = !cleanup.removed;
                let _ = store::write_job_json(&dir, &job);
                // Record the terminal event for anyone replaying later.
                let event = JobEvent {
                    seq: job.seq + 1,
                    job_id: job.job_id.clone(),
                    ts: util::now(),
                    kind: EventKind::End,
                    stage: job.stage,
                    source: None,
                    level: None,
                    line: None,
                    line_part: None,
                    line_parts: None,
                    state: Some(JobState::Interrupted),
                    error: job.error.clone(),
                    artifact: None,
                    message: Some("the Agent restarted while this job was active".to_string()),
                };
                let _ = store::append_event(&events_path, &event);
                tail.push_back(event);
            }
            jobs.insert(
                job.job_id.clone(),
                Arc::new(JobEntry::new(dir, events_path, job)),
            );
        }
        if let Ok(mut map) = self.jobs.lock() {
            *map = jobs;
        }
        Ok(())
    }

    /// Advertised handshake reply.
    pub fn hello_result(&self) -> HelloResult {
        let disk = doctor::free_disk_bytes(&self.data);
        let (ready, refusals) = doctor::readiness(&self.cfg, &self.toolchain, &self.source, disk);
        HelloResult {
            tag: String::new(),
            protocol: PROTOCOL.to_string(),
            agent: AgentInfo {
                version: builder_core::VERSION.to_string(),
                id: self.cfg.agent_id.clone(),
                os: std::env::consts::OS.to_string(),
                os_version: None,
                arch: std::env::consts::ARCH.to_string(),
            },
            capabilities: AGENT_CAPABILITIES
                .iter()
                .map(|capability| capability.to_string())
                .collect(),
            toolchain: self.toolchain.clone(),
            source: self.source.clone(),
            limits: self.cfg.limits(),
            ready,
            min_client: builder_core::MIN_AGENT_VERSION.to_string(),
            refusals,
        }
    }

    // -----------------------------------------------------------------
    // Job lookup and status
    // -----------------------------------------------------------------

    pub fn entry(&self, job_id: &str) -> Result<Arc<JobEntry>, ErrorInfo> {
        if !valid_job_id(job_id) {
            return Err(ErrorInfo::new(
                ErrorCode::BadRequest,
                format!("invalid job id {job_id:?}"),
            ));
        }
        let jobs = self.jobs.lock().map_err(|_| internal("job map poisoned"))?;
        jobs.get(job_id)
            .cloned()
            .ok_or_else(|| ErrorInfo::new(ErrorCode::NotFound, format!("unknown job {job_id}")))
    }

    pub fn job_view(
        &self,
        job_id: &str,
    ) -> Result<builder_core::protocol::model::JobView, ErrorInfo> {
        Ok(self.entry(job_id)?.snapshot())
    }

    // -----------------------------------------------------------------
    // Job creation
    // -----------------------------------------------------------------

    pub fn create_job(&self, request: JobCreateRequest) -> Result<JobCreated, ErrorInfo> {
        self.validate_create(&request)?;
        let fingerprint = request_fingerprint(&request);
        let mut jobs = self.jobs.lock().map_err(|_| internal("job map poisoned"))?;

        // Idempotency: same request id + same parameters returns the same job.
        for entry in jobs.values() {
            let record = entry
                .rec
                .lock()
                .map_err(|_| internal("job record poisoned"))?;
            if record.job.request.request_id == request.request_id {
                if record.job.request_fingerprint == fingerprint {
                    return Ok(created_reply(&record.job, &self.cfg.limits()));
                }
                return Err(ErrorInfo::new(
                    ErrorCode::Conflict,
                    format!(
                        "request id {} was already used with different parameters",
                        request.request_id
                    ),
                ));
            }
        }

        // Queue capacity (one build slot).
        let mut active = 0_u32;
        let mut queued = 0_u32;
        for entry in jobs.values() {
            let record = entry
                .rec
                .lock()
                .map_err(|_| internal("job record poisoned"))?;
            if record.job.state.is_active() {
                active += 1;
                if record.job.state == JobState::Queued {
                    queued += 1;
                }
            }
        }
        if queued >= self.cfg.max_queued_jobs
            || active
                >= self
                    .cfg
                    .max_queued_jobs
                    .saturating_add(self.cfg.max_concurrent_builds)
        {
            return Err(ErrorInfo::new(
                ErrorCode::QueueFull,
                format!(
                    "the Mac is already building or has {} jobs queued",
                    self.cfg.max_queued_jobs
                ),
            )
            .with_details(serde_json::json!({ "retry_after_seconds": 30 })));
        }

        let job_id = util::new_job_id();
        let dir = self.data.job_dir(&job_id);
        store::create_job_layout(&dir)
            .map_err(|error| internal(format!("could not create the job directory: {error}")))?;
        let mut job = JobPersist::new(
            job_id.clone(),
            request,
            fingerprint,
            self.toolchain.clone(),
            self.source.revision.clone(),
            util::now(),
        );
        job.fake = Some(self.cfg.fake_build);
        store::write_job_json(&dir, &job)
            .map_err(|error| internal(format!("could not persist the job: {error}")))?;
        let entry = Arc::new(JobEntry::new(dir, self.data.events_path(&job_id), job));
        jobs.insert(job_id.clone(), Arc::clone(&entry));
        drop(jobs);

        self.data.audit("job_created", &job_id, "state=created");
        let game = entry.with(|record| record.job.request.game.name.clone());
        self.log(
            &entry,
            None,
            LogSource::Agent,
            LogLevel::Info,
            &format!("job accepted for game {game}; waiting for the input upload"),
        );
        let record = entry
            .rec
            .lock()
            .map_err(|_| internal("job record poisoned"))?;
        Ok(created_reply(&record.job, &self.cfg.limits()))
    }

    fn validate_create(&self, request: &JobCreateRequest) -> Result<(), ErrorInfo> {
        let bad = |message: String| ErrorInfo::new(ErrorCode::BadRequest, message);
        if !valid_request_id(&request.request_id) {
            return Err(bad(format!(
                "request_id must be 1-128 characters of [A-Za-z0-9._:-], got {:?}",
                request.request_id
            )));
        }
        crate::stages::validate_build_arguments(
            &request.game.name,
            &request.game.display_name,
            request.game.bundle_id.as_deref(),
            request.game.title_id.as_deref(),
        )
        .map_err(bad)?;
        if !self.cfg.keep_input_allowed && request.options.keep_input {
            return Err(ErrorInfo::new(
                ErrorCode::Forbidden,
                "this Agent does not allow keeping inputs",
            ));
        }
        if request.options.keep_input {
            // The client is responsible for warning the user; the Agent only
            // records the opt-in.
        }
        if request.transport == builder_core::protocol::model::TransportMode::Path {
            return Err(bad(
                "transport mode \"path\" is not available in this Agent build; upload the input instead"
                    .to_string(),
            ));
        }
        if request.inputs.is_empty() {
            return Err(bad("the job declares no input files".to_string()));
        }
        let mut roles = std::collections::HashSet::new();
        let mut rom_seen = false;
        for input in &request.inputs {
            if !roles.insert(input.role) {
                return Err(bad(format!("duplicate input role {}", input.role)));
            }
            if input.bytes == 0 {
                return Err(bad(format!("input {} declares 0 bytes", input.role)));
            }
            if input.bytes > self.cfg.max_input_bytes {
                return Err(ErrorInfo::new(
                    ErrorCode::PayloadTooLarge,
                    format!(
                        "input {} is {} bytes; this Agent accepts at most {} bytes",
                        input.role, input.bytes, self.cfg.max_input_bytes
                    ),
                ));
            }
            if builder_core::protocol::normalize_sha256(&input.sha256).is_none() {
                return Err(bad(format!(
                    "input {} has an invalid SHA256 (expected 64 hex characters)",
                    input.role
                )));
            }
            if input.name.len() > 255 || input.name.chars().any(char::is_control) {
                return Err(bad(format!(
                    "input {} has an invalid display name",
                    input.role
                )));
            }
            if input.role == builder_core::protocol::model::InputRole::Rom {
                rom_seen = true;
            }
        }
        if !rom_seen {
            return Err(bad(
                "exactly one input with role \"rom\" is required".to_string()
            ));
        }
        if let Some(expected) = request
            .source
            .as_ref()
            .and_then(|source| source.expected_revision.as_deref())
        {
            let valid = (7..=64).contains(&expected.len())
                && expected.bytes().all(|byte| byte.is_ascii_hexdigit());
            if !valid {
                return Err(bad(format!(
                    "expected_revision {expected:?} is not a git commit id"
                )));
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------
    // Inputs -> queue
    // -----------------------------------------------------------------

    pub fn input_ready(&self, job_id: &str) -> Result<JobInputReadyResult, ErrorInfo> {
        let entry = self.entry(job_id)?;
        {
            let record = entry
                .rec
                .lock()
                .map_err(|_| internal("job record poisoned"))?;
            if record.job.state != JobState::Created {
                return Err(ErrorInfo::new(
                    ErrorCode::Conflict,
                    format!(
                        "job {} is {}; inputs are only accepted while it is created",
                        job_id, record.job.state
                    ),
                ));
            }
        }
        let inputs = entry.with(|record| record.job.request.inputs.clone());
        match store::verify_declared_inputs(&entry.dir, &inputs) {
            store::InputCheck::Complete => {}
            other => return Err(ErrorInfo::new(
                ErrorCode::InputInvalid,
                format!("declared inputs are not on the Agent: {other:?}"),
            )
            .with_hint(
                "Upload the missing or mismatched input again; the client verifies SHA256 locally.",
            )),
        }
        {
            let mut record = entry
                .rec
                .lock()
                .map_err(|_| internal("job record poisoned"))?;
            record.job.inputs_verified = true;
            record.job.inputs_present = true;
            record.job.state = JobState::Queued;
            record.job.updated_at = util::now();
            record.job.updated_unix = unix_now();
            JobEntry::persist_locked(&record, &entry.dir)
                .map_err(|error| internal(format!("could not persist the job: {error}")))?;
        }
        {
            let mut queue = self.queue.lock().map_err(|_| internal("queue poisoned"))?;
            queue.queued.push_back(job_id.to_string());
        }
        self.refresh_queue_positions();
        self.queue_cv.notify_all();
        self.data.audit("input_ready", job_id, "state=queued");
        self.log(
            &entry,
            None,
            LogSource::Agent,
            LogLevel::Info,
            "inputs verified; waiting for a build slot",
        );
        self.state_event(&entry, JobState::Queued, None, None);
        let state = entry.with(|record| record.job.state);
        Ok(JobInputReadyResult {
            tag: String::new(),
            job_id: job_id.to_string(),
            state,
            warnings: Vec::new(),
        })
    }

    // -----------------------------------------------------------------
    // Cancel, delete, list, artifact
    // -----------------------------------------------------------------

    pub fn cancel_job(
        &self,
        job_id: &str,
        reason: Option<&str>,
    ) -> Result<JobCancelResult, ErrorInfo> {
        let entry = self.entry(job_id)?;
        let state = entry.with(|record| record.job.state);
        let reason_text = reason.unwrap_or("client requested cancellation");
        match state {
            JobState::Created | JobState::Queued => {
                if state == JobState::Queued {
                    if let Ok(mut queue) = self.queue.lock() {
                        queue.queued.retain(|queued| queued != job_id);
                    }
                    self.refresh_queue_positions();
                }
                let cleanup = cleanup::remove_inputs(&entry.dir);
                {
                    let mut record = entry
                        .rec
                        .lock()
                        .map_err(|_| internal("job record poisoned"))?;
                    record.job.state = JobState::Canceled;
                    record.job.cancel_requested = true;
                    record.job.inputs_present = false;
                    record.job.finished_at = Some(util::now());
                    record.job.updated_at = util::now();
                    record.job.updated_unix = unix_now();
                    if !cleanup.removed {
                        record.job.warnings.push(format!(
                            "input_cleanup_failed: {}",
                            cleanup.leftovers.join(", ")
                        ));
                    }
                    JobEntry::persist_locked(&record, &entry.dir)
                        .map_err(|error| internal(format!("could not persist the job: {error}")))?;
                }
                self.data.audit("job_canceled", job_id, reason_text);
                self.log(
                    &entry,
                    None,
                    LogSource::Agent,
                    LogLevel::Warn,
                    &format!("canceled: {reason_text}"),
                );
                self.state_event(&entry, JobState::Canceled, None, None);
                self.end_event(&entry, JobState::Canceled, None);
                Ok(JobCancelResult {
                    tag: String::new(),
                    job_id: job_id.to_string(),
                    state: JobState::Canceled,
                })
            }
            JobState::Running | JobState::Canceling => {
                let pgid = {
                    let mut record = entry
                        .rec
                        .lock()
                        .map_err(|_| internal("job record poisoned"))?;
                    record.job.cancel_requested = true;
                    if record.job.state == JobState::Running {
                        record.job.state = JobState::Canceling;
                    }
                    record.job.updated_at = util::now();
                    record.job.updated_unix = unix_now();
                    JobEntry::persist_locked(&record, &entry.dir)
                        .map_err(|error| internal(format!("could not persist the job: {error}")))?;
                    record.job.process_group
                };
                if let Some(pgid) = pgid {
                    // The runner also polls the flag; signalling here keeps
                    // cancellation prompt.
                    let _ = crate::nix_util::signal_process_group(
                        pgid,
                        crate::nix_util::Signal::SIGTERM,
                    );
                }
                self.data.audit("job_canceling", job_id, reason_text);
                self.log(
                    &entry,
                    None,
                    LogSource::Agent,
                    LogLevel::Warn,
                    &format!("canceling: {reason_text}"),
                );
                self.state_event(
                    &entry,
                    JobState::Canceling,
                    entry.with(|record| record.job.stage),
                    None,
                );
                Ok(JobCancelResult {
                    tag: String::new(),
                    job_id: job_id.to_string(),
                    state: entry.with(|record| record.job.state),
                })
            }
            terminal => Err(ErrorInfo::new(
                ErrorCode::Conflict,
                format!("job {job_id} already finished as {terminal}"),
            )),
        }
    }

    pub fn list_jobs(
        &self,
        limit: Option<u32>,
        cursor: Option<&str>,
    ) -> Result<JobListResult, ErrorInfo> {
        let limit = limit.unwrap_or(20).clamp(1, 100) as usize;
        let mut entries: Vec<(JobListEntry, JobState, String)> = {
            let jobs = self.jobs.lock().map_err(|_| internal("job map poisoned"))?;
            let mut entries = Vec::with_capacity(jobs.len());
            for entry in jobs.values() {
                let record = entry
                    .rec
                    .lock()
                    .map_err(|_| internal("job record poisoned"))?;
                let job = &record.job;
                let list_entry = JobListEntry {
                    job_id: job.job_id.clone(),
                    state: job.state,
                    game: Some(job.request.game.clone()),
                    created_at: job.created_at.clone(),
                    finished_at: job.finished_at.clone(),
                    artifact: job.artifact.clone(),
                };
                entries.push((list_entry, job.state, job.created_at.clone()));
            }
            entries
        };
        entries.sort_by(|left, right| {
            let left_active = left.1.is_active();
            let right_active = right.1.is_active();
            right_active
                .cmp(&left_active)
                .then_with(|| right.2.cmp(&left.2))
        });
        let start = match cursor {
            Some(cursor) => entries
                .iter()
                .position(|(entry, _, _)| entry.job_id == cursor)
                .map(|index| index + 1)
                .ok_or_else(|| {
                    ErrorInfo::new(
                        ErrorCode::BadRequest,
                        format!("unknown job.list cursor {cursor:?}"),
                    )
                })?,
            None => 0,
        };
        let slice: Vec<JobListEntry> = entries
            .iter()
            .skip(start)
            .take(limit)
            .map(|(entry, _, _)| entry.clone())
            .collect();
        let next_cursor = if start + slice.len() < entries.len() {
            slice.last().map(|entry| entry.job_id.clone())
        } else {
            None
        };
        Ok(JobListResult {
            tag: String::new(),
            jobs: slice,
            next_cursor,
        })
    }

    pub fn delete_job(&self, job_id: &str) -> Result<JobDeleteResult, ErrorInfo> {
        let entry = self.entry(job_id)?;
        let state = entry.with(|record| record.job.state);
        if !state.is_terminal() {
            return Err(ErrorInfo::new(
                ErrorCode::Conflict,
                format!("job {job_id} is still {state}; cancel it before deleting"),
            ));
        }
        {
            let mut jobs = self.jobs.lock().map_err(|_| internal("job map poisoned"))?;
            jobs.remove(job_id);
        }
        if let Err(error) = store::delete_job_dir(&self.data, job_id) {
            return Err(internal(format!(
                "could not delete the job directory: {error}"
            )));
        }
        self.data.audit("job_deleted", job_id, "state=deleted");
        Ok(JobDeleteResult {
            tag: String::new(),
            job_id: job_id.to_string(),
            deleted: true,
        })
    }

    pub fn artifact_manifest(&self, job_id: &str) -> Result<ArtifactRecord, ErrorInfo> {
        let entry = self.entry(job_id)?;
        let state = entry.with(|record| record.job.state);
        if state != JobState::Succeeded {
            return Err(ErrorInfo::new(
                ErrorCode::ArtifactNotReady,
                format!("job {job_id} is {state}; the artifact is only available after success"),
            ));
        }
        let path = entry.out_dir.join("artifact.json");
        util::read_json(&path)
            .map_err(|error| internal(format!("could not read {}: {error}", path.display())))
    }

    pub fn ack_artifact(&self, job_id: &str, artifact_sha256: &str) -> Result<(), ErrorInfo> {
        if builder_core::protocol::normalize_sha256(artifact_sha256).is_none() {
            return Err(ErrorInfo::new(
                ErrorCode::BadRequest,
                "invalid artifact SHA256".to_string(),
            ));
        }
        let entry = self.entry(job_id)?;
        {
            let mut record = entry
                .rec
                .lock()
                .map_err(|_| internal("job record poisoned"))?;
            record.job.artifact_acked = true;
            record.job.updated_at = util::now();
            let _ = JobEntry::persist_locked(&record, &entry.dir);
        }
        self.data.audit("artifact_acked", job_id, artifact_sha256);
        Ok(())
    }

    /// Subscribe to a job's event stream: retained replay plus live events.
    pub fn subscribe(
        &self,
        job_id: &str,
        since_seq: u64,
    ) -> Result<(Subscription, JobSubscribeResult), ErrorInfo> {
        let entry = self.entry(job_id)?;
        let (tx, rx) = mpsc::channel();
        let id = self.next_subscriber.fetch_add(1, Ordering::SeqCst);
        {
            let mut subscribers = self
                .subscribers
                .lock()
                .map_err(|_| internal("subscriber list poisoned"))?;
            subscribers.push(Subscriber {
                id,
                job_id: job_id.to_string(),
                tx,
            });
        }
        let guard = SubscriberGuard {
            registry: Arc::clone(&self.subscribers),
            id,
        };
        let all = store::read_events(&entry.events_path);
        let earliest_seq = all.first().map(|event| event.seq).unwrap_or(0);
        let replay: Vec<JobEvent> = all
            .into_iter()
            .filter(|event| event.seq > since_seq)
            .collect();
        // Replay is truncated when the requested cursor is older than the first
        // event still on disk.
        let log_truncated = since_seq.saturating_add(1) < earliest_seq;
        let view = entry.snapshot();
        let reply = JobSubscribeResult {
            tag: String::new(),
            job: view,
            earliest_seq,
            log_truncated,
        };
        Ok((
            Subscription {
                _guard: guard,
                replay,
                events: rx,
            },
            reply,
        ))
    }

    // -----------------------------------------------------------------
    // Stage and event machinery used by the worker
    // -----------------------------------------------------------------

    fn emit(&self, entry: &Arc<JobEntry>, mut event: JobEvent) -> JobEvent {
        let mut record = entry.rec.lock().expect("job record poisoned");
        record.job.seq += 1;
        event.seq = record.job.seq;
        event.job_id = record.job.job_id.clone();
        event.ts = util::now();
        record.job.updated_at = event.ts.clone();
        record.job.updated_unix = unix_now();
        record.tail.push_back(event.clone());
        while record.tail.len() > EVENT_TAIL_LIMIT {
            record.tail.pop_front();
        }
        let _ = store::append_event(&entry.events_path, &event);
        drop(record);
        self.broadcast(&event);
        event
    }

    fn broadcast(&self, event: &JobEvent) {
        let Ok(mut subscribers) = self.subscribers.lock() else {
            return;
        };
        subscribers.retain(|subscriber| {
            if subscriber.job_id != event.job_id {
                return true;
            }
            subscriber.tx.send(event.clone()).is_ok()
        });
    }

    /// Log one line (split into parts when longer than the protocol limit).
    pub fn log(
        &self,
        entry: &Arc<JobEntry>,
        stage: Option<Stage>,
        source: LogSource,
        level: LogLevel,
        text: &str,
    ) {
        let parts = split_log_line(text);
        let total = parts.len() as u32;
        for (index, part) in parts.into_iter().enumerate() {
            let event = JobEvent {
                seq: 0,
                job_id: String::new(),
                ts: String::new(),
                kind: EventKind::Log,
                stage,
                source: Some(source),
                level: Some(level),
                line: Some(part),
                line_part: (total > 1).then_some(index as u32 + 1),
                line_parts: (total > 1).then_some(total),
                state: None,
                error: None,
                artifact: None,
                message: None,
            };
            self.emit(entry, event);
        }
    }

    /// Record a warning on the job and stream it to subscribers.
    pub fn warning(&self, entry: &Arc<JobEntry>, message: &str) {
        {
            let Ok(mut record) = entry.rec.lock() else {
                return;
            };
            record.job.warnings.push(message.to_string());
            let _ = JobEntry::persist_locked(&record, &entry.dir);
        }
        let event = JobEvent {
            seq: 0,
            job_id: String::new(),
            ts: String::new(),
            kind: EventKind::Warning,
            stage: entry.with(|record| record.job.stage),
            source: Some(LogSource::Agent),
            level: Some(LogLevel::Warn),
            line: None,
            line_part: None,
            line_parts: None,
            state: None,
            error: None,
            artifact: None,
            message: Some(message.to_string()),
        };
        self.emit(entry, event);
    }

    /// Enter a build stage: previous stages are done, this one is running.
    pub fn enter_stage(&self, entry: &Arc<JobEntry>, stage: Stage) {
        {
            let mut record = entry.rec.lock().expect("job record poisoned");
            let now = util::now();
            record.job.state = JobState::Running;
            record.job.stage = Some(stage);
            record.job.stage_state = Some(StageState::Running);
            record.job.percent = Some(stage.base_percent());
            record.job.updated_at = now.clone();
            record.job.updated_unix = unix_now();
            if record.job.started_at.is_none() {
                record.job.started_at = Some(now);
            }
            let current = stage.index();
            for (index, progress) in record.job.stages.iter_mut().enumerate() {
                progress.state = match index.cmp(&current) {
                    std::cmp::Ordering::Less => StageState::Done,
                    std::cmp::Ordering::Equal => StageState::Running,
                    std::cmp::Ordering::Greater => StageState::Pending,
                };
            }
            record.stage_started = Some(Instant::now());
            let _ = JobEntry::persist_locked(&record, &entry.dir);
        }
        self.state_event(entry, JobState::Running, Some(stage), None);
    }

    /// Complete a build stage.
    pub fn finish_stage(&self, entry: &Arc<JobEntry>, stage: Stage) {
        let duration = entry.with(|record| {
            record
                .stage_started
                .take()
                .map(|started| started.elapsed().as_millis() as u64)
        });
        {
            let mut record = entry.rec.lock().expect("job record poisoned");
            if let Some(progress) = record
                .job
                .stages
                .iter_mut()
                .find(|progress| progress.name == stage)
            {
                progress.state = StageState::Done;
                progress.duration_ms = duration;
            }
            record.job.stage_state = Some(StageState::Done);
            record.job.updated_at = util::now();
            let _ = JobEntry::persist_locked(&record, &entry.dir);
        }
    }

    /// Mark the currently running stage as failed.
    pub fn mark_stage_failed(&self, entry: &Arc<JobEntry>, stage: Stage) {
        {
            let mut record = entry.rec.lock().expect("job record poisoned");
            let duration = record
                .stage_started
                .take()
                .map(|started| started.elapsed().as_millis() as u64);
            if let Some(progress) = record
                .job
                .stages
                .iter_mut()
                .find(|progress| progress.name == stage)
            {
                progress.state = StageState::Failed;
                progress.duration_ms = duration;
            }
            record.job.stage_state = Some(StageState::Failed);
            record.job.updated_at = util::now();
            let _ = JobEntry::persist_locked(&record, &entry.dir);
        }
    }

    /// Update the coarse progress/detail counters (no state event).
    pub fn update_progress(
        &self,
        entry: &Arc<JobEntry>,
        percent: Option<u8>,
        detail: Option<serde_json::Value>,
    ) {
        let mut record = match entry.rec.lock() {
            Ok(record) => record,
            Err(_) => return,
        };
        let mut changed = false;
        if let Some(percent) = percent {
            if record.job.percent != Some(percent.min(100)) {
                record.job.percent = Some(percent.min(100));
                changed = true;
            }
        }
        if let Some(detail) = detail {
            record.job.detail = Some(detail);
            changed = true;
        }
        if changed {
            record.job.updated_at = util::now();
            let _ = JobEntry::persist_locked(&record, &entry.dir);
        }
    }

    fn state_event(
        &self,
        entry: &Arc<JobEntry>,
        state: JobState,
        stage: Option<Stage>,
        error: Option<ErrorInfo>,
    ) {
        let event = JobEvent {
            seq: 0,
            job_id: String::new(),
            ts: String::new(),
            kind: EventKind::State,
            stage,
            source: Some(LogSource::Agent),
            level: None,
            line: None,
            line_part: None,
            line_parts: None,
            state: Some(state),
            error,
            artifact: None,
            message: None,
        };
        self.emit(entry, event);
    }

    fn end_event(&self, entry: &Arc<JobEntry>, state: JobState, error: Option<ErrorInfo>) {
        let event = JobEvent {
            seq: 0,
            job_id: String::new(),
            ts: String::new(),
            kind: EventKind::End,
            stage: entry.with(|record| record.job.stage),
            source: Some(LogSource::Agent),
            level: None,
            line: None,
            line_part: None,
            line_parts: None,
            state: Some(state),
            error,
            artifact: None,
            message: None,
        };
        self.emit(entry, event);
    }

    fn artifact_event(&self, entry: &Arc<JobEntry>, artifact: &ArtifactSummary) {
        let event = JobEvent {
            seq: 0,
            job_id: String::new(),
            ts: String::new(),
            kind: EventKind::Artifact,
            stage: Some(Stage::Verifying),
            source: Some(LogSource::Agent),
            level: Some(LogLevel::Info),
            line: None,
            line_part: None,
            line_parts: None,
            state: None,
            error: None,
            artifact: Some(artifact.clone()),
            message: None,
        };
        self.emit(entry, event);
    }

    fn refresh_queue_positions(&self) {
        let Ok(queue) = self.queue.lock() else { return };
        let queued: Vec<(usize, String)> = queue
            .queued
            .iter()
            .enumerate()
            .map(|(index, id)| (index, id.clone()))
            .collect();
        drop(queue);
        for (index, job_id) in queued {
            if let Ok(entry) = self.entry(&job_id) {
                let mut record = match entry.rec.lock() {
                    Ok(record) => record,
                    Err(_) => continue,
                };
                let position = index as u32;
                if record.job.queue_position != Some(position) {
                    record.job.queue_position = Some(position);
                    let _ = JobEntry::persist_locked(&record, &entry.dir);
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Worker
    // -----------------------------------------------------------------

    fn worker_loop(self: Arc<Self>) {
        loop {
            let job_id = {
                let mut queue = match self.queue.lock() {
                    Ok(queue) => queue,
                    Err(_) => return,
                };
                while queue.queued.is_empty() {
                    queue = match self.queue_cv.wait(queue) {
                        Ok(queue) => queue,
                        Err(_) => return,
                    };
                }
                let Some(job_id) = queue.queued.pop_front() else {
                    continue;
                };
                queue.running = Some(job_id.clone());
                job_id
            };
            self.refresh_queue_positions();
            let Ok(entry) = self.entry(&job_id) else {
                if let Ok(mut queue) = self.queue.lock() {
                    queue.running = None;
                }
                continue;
            };
            let state = entry.with(|record| record.job.state);
            if state != JobState::Queued {
                // Canceled while waiting for the slot.
                if let Ok(mut queue) = self.queue.lock() {
                    queue.running = None;
                }
                continue;
            }
            self.data.audit("build_started", &job_id, "stage=preparing");
            let outcome = if self.cfg.fake_build {
                crate::fake::run(&self, &entry)
            } else {
                crate::worker::run(&self, &entry)
            };
            self.complete_run(&entry, outcome);
            if let Ok(mut queue) = self.queue.lock() {
                queue.running = None;
            }
        }
    }

    /// Apply a worker outcome: cleanup, terminal transition, final events.
    pub fn complete_run(&self, entry: &Arc<JobEntry>, outcome: WorkerOutcome) {
        // Inputs: deleted by default; kept only on explicit opt-in.
        let keep_input = entry.with(|record| record.job.options().keep_input);
        let real_build = entry.with(|record| record.job.fake != Some(true));
        let game_name = entry.with(|record| record.job.request.game.name.clone());
        if keep_input {
            entry.with(|record| {
                record.job.inputs_kept = true;
                record.job.inputs_present = true;
            });
            self.log(
                entry,
                None,
                LogSource::Agent,
                LogLevel::Info,
                "keeping the input files because keep_input was requested",
            );
        } else {
            let cleanup = cleanup::remove_inputs(&entry.dir);
            if cleanup.removed {
                entry.with(|record| record.job.inputs_present = false);
                self.log(
                    entry,
                    None,
                    LogSource::Agent,
                    LogLevel::Info,
                    "input files deleted from the Mac",
                );
            } else {
                let detail = cleanup.leftovers.join(", ");
                self.warning(
                    entry,
                    &format!("input_cleanup_failed: could not delete {detail}"),
                );
            }
        }
        if real_build {
            if let Some(checkout) = self.cfg.checkout.clone() {
                for warning in cleanup::remove_build_products(&checkout, &game_name) {
                    self.warning(entry, &warning);
                }
            }
        }

        let job_id = entry.job_id();
        match outcome {
            WorkerOutcome::Succeeded { artifact, warnings } => {
                for warning in &warnings {
                    self.warning(entry, warning);
                }
                match crate::worker::verify_artifact(entry, &artifact) {
                    Ok(()) => {
                        let summary = ArtifactSummary {
                            name: artifact.ipa.name.clone(),
                            bytes: artifact.ipa.bytes,
                            sha256: artifact.ipa.sha256.clone(),
                        };
                        {
                            let mut record = match entry.rec.lock() {
                                Ok(record) => record,
                                Err(_) => return,
                            };
                            record.job.state = JobState::Succeeded;
                            record.job.stage = Some(Stage::Verifying);
                            record.job.stage_state = Some(StageState::Done);
                            record.job.percent = Some(100);
                            for progress in record.job.stages.iter_mut() {
                                progress.state = StageState::Done;
                            }
                            record.job.artifact = Some(summary.clone());
                            record.job.finished_at = Some(util::now());
                            record.job.updated_at = util::now();
                            record.job.updated_unix = unix_now();
                            record.job.error = None;
                            let _ = JobEntry::persist_locked(&record, &entry.dir);
                        }
                        self.data
                            .audit("build_succeeded", &job_id, "artifact=ready");
                        self.log(
                            entry,
                            None,
                            LogSource::Agent,
                            LogLevel::Info,
                            "build succeeded; artifact ready",
                        );
                        self.state_event(entry, JobState::Succeeded, Some(Stage::Verifying), None);
                        self.artifact_event(entry, &summary);
                        self.end_event(entry, JobState::Succeeded, None);
                    }
                    Err(error) => self.fail_run(entry, error),
                }
            }
            WorkerOutcome::Failed { error, warnings } => {
                for warning in &warnings {
                    self.warning(entry, warning);
                }
                self.fail_run(entry, error);
            }
            WorkerOutcome::Canceled => {
                {
                    let mut record = match entry.rec.lock() {
                        Ok(record) => record,
                        Err(_) => return,
                    };
                    record.job.state = JobState::Canceled;
                    record.job.stage_state = Some(StageState::Skipped);
                    record.job.finished_at = Some(util::now());
                    record.job.updated_at = util::now();
                    record.job.updated_unix = unix_now();
                    let _ = JobEntry::persist_locked(&record, &entry.dir);
                }
                self.data.audit("build_canceled", &job_id, "state=canceled");
                self.log(
                    entry,
                    None,
                    LogSource::Agent,
                    LogLevel::Warn,
                    "build canceled; job data cleaned up",
                );
                self.state_event(entry, JobState::Canceled, None, None);
                self.end_event(entry, JobState::Canceled, None);
            }
        }
    }

    fn fail_run(&self, entry: &Arc<JobEntry>, error: ErrorInfo) {
        let job_id = entry.job_id();
        let stage = error
            .stage
            .or_else(|| entry.with(|record| record.job.stage));
        if let Some(stage) = stage {
            self.mark_stage_failed(entry, stage);
        }
        {
            let mut record = match entry.rec.lock() {
                Ok(record) => record,
                Err(_) => return,
            };
            record.job.state = JobState::Failed;
            record.job.stage = stage;
            record.job.stage_state = Some(StageState::Failed);
            record.job.error = Some(error.clone());
            record.job.finished_at = Some(util::now());
            record.job.updated_at = util::now();
            record.job.updated_unix = unix_now();
            let _ = JobEntry::persist_locked(&record, &entry.dir);
        }
        self.data
            .audit("build_failed", &job_id, error.code.as_str());
        let tail: Vec<String> = error.log_tail.clone().unwrap_or_default();
        for line in tail.iter().rev().take(10).rev() {
            self.log(entry, stage, LogSource::Agent, LogLevel::Error, line);
        }
        self.state_event(entry, JobState::Failed, stage, Some(error.clone()));
        self.end_event(entry, JobState::Failed, Some(error));
    }

    /// On a clean `serve --stdio` shutdown: active jobs cannot keep running in
    /// the dead process, so mark them interrupted and clean their inputs.
    pub fn interrupt_active_jobs(&self) {
        let Ok(jobs) = self.jobs.lock() else { return };
        let entries: Vec<Arc<JobEntry>> = jobs
            .values()
            .filter(|entry| entry.with(|record| record.job.state.is_active()))
            .cloned()
            .collect();
        for entry in entries {
            let pgid = {
                let Ok(mut record) = entry.rec.lock() else {
                    continue;
                };
                if let Some(pgid) = record.job.process_group {
                    let _ = crate::nix_util::signal_process_group(
                        pgid,
                        crate::nix_util::Signal::SIGTERM,
                    );
                }
                record.job.state = JobState::Interrupted;
                record.job.error = Some(ErrorInfo::new(
                    ErrorCode::Interrupted,
                    "the Agent stopped while this job was active",
                ));
                record.job.finished_at = Some(util::now());
                record.job.updated_at = util::now();
                record.job.updated_unix = unix_now();
                let _ = cleanup::remove_inputs(&entry.dir);
                record.job.inputs_present = false;
                let _ = JobEntry::persist_locked(&record, &entry.dir);
                record.job.process_group
            };
            let _ = pgid;
            let event = JobEvent {
                seq: 0,
                job_id: String::new(),
                ts: String::new(),
                kind: EventKind::End,
                stage: entry.with(|record| record.job.stage),
                source: Some(LogSource::Agent),
                level: None,
                line: None,
                line_part: None,
                line_parts: None,
                state: Some(JobState::Interrupted),
                error: None,
                artifact: None,
                message: Some("the Agent stopped while this job was active".to_string()),
            };
            self.emit(&entry, event);
        }
    }
}

/// Build the `job.created` reply for a persisted job.
fn created_reply(job: &JobPersist, limits: &Limits) -> JobCreated {
    let roles: Vec<UploadRole> = job
        .request
        .inputs
        .iter()
        .map(|input| UploadRole {
            role: input.role,
            bytes: input.bytes,
            sha256: input.sha256.to_ascii_lowercase(),
        })
        .collect();
    let created_unix = builder_core::util::parse_rfc3339(&job.created_at).unwrap_or_else(unix_now);
    JobCreated {
        tag: String::new(),
        job_id: job.job_id.clone(),
        state: JobState::Created,
        upload: UploadPlan {
            roles,
            chunk_hint: DEFAULT_CHUNK_HINT,
            expires_at: rfc3339_from_unix(created_unix + INPUT_TIMEOUT_SECONDS),
        },
        limits: QueueLimits {
            max_queued_jobs: limits.max_queued_jobs,
            max_concurrent_builds: limits.max_concurrent_builds,
        },
    }
}

/// Fingerprint of a create request, used for idempotent retries.
pub fn request_fingerprint(request: &JobCreateRequest) -> String {
    let value = serde_json::to_value(request).unwrap_or(serde_json::Value::Null);
    sha256_hex(canonical_json_string(&value).as_bytes())
}

/// Split a log line into protocol-sized parts on UTF-8 boundaries.
pub fn split_log_line(text: &str) -> Vec<String> {
    if text.len() <= MAX_LOG_LINE_BYTES {
        return vec![text.to_string()];
    }
    let mut parts = Vec::new();
    let mut start = 0;
    let bytes = text.as_bytes();
    while start < bytes.len() {
        let mut end = (start + MAX_LOG_LINE_BYTES).min(bytes.len());
        while end > start && !text.is_char_boundary(end) {
            end -= 1;
        }
        if end == start {
            end = (start + 1).min(bytes.len());
        }
        parts.push(text[start..end].to_string());
        start = end;
    }
    parts
}

fn internal(message: impl Into<String>) -> ErrorInfo {
    ErrorInfo::new(ErrorCode::Internal, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use builder_core::protocol::model::{
        GameSpec, InputRole, InputSpec, JobOptions, TransportMode,
    };

    fn fake_config(max_queued: u32) -> AgentConfig {
        AgentConfig {
            fake_build: true,
            checkout: None,
            max_queued_jobs: max_queued,
            ..AgentConfig::default()
        }
    }

    fn request(request_id: &str, name: &str) -> JobCreateRequest {
        JobCreateRequest {
            request_id: request_id.to_string(),
            game: GameSpec {
                name: name.to_string(),
                display_name: "Pokemon Y".to_string(),
                bundle_id: None,
                title_id: None,
            },
            inputs: vec![InputSpec {
                role: InputRole::Rom,
                name: "Pokemon Y.cci".to_string(),
                bytes: 4,
                sha256: builder_core::hash::sha256_hex(b"test"),
            }],
            options: JobOptions::default(),
            source: None,
            transport: TransportMode::Upload,
        }
    }

    struct TestService {
        _dir: tempfile::TempDir,
        service: Arc<Service>,
    }

    fn test_service(max_queued: u32) -> TestService {
        let dir = tempfile::tempdir().unwrap();
        let data = crate::store::DataRoot::new(dir.path().to_path_buf());
        let service = Service::open(fake_config(max_queued), data).unwrap();
        TestService { _dir: dir, service }
    }

    fn upload_input(service: &Service, job_id: &str) {
        let entry = service.entry(job_id).unwrap();
        let request = entry.with(|record| record.job.request.clone());
        let input = &request.inputs[0];
        let path = store::input_path(&entry.dir, input.role);
        std::fs::write(&path, b"test").unwrap();
    }

    #[test]
    fn create_is_idempotent_and_rejects_conflicts() {
        let test = test_service(4);
        let created = test.service.create_job(request("req-1", "game")).unwrap();
        assert_eq!(created.state, JobState::Created);
        assert_eq!(created.upload.roles.len(), 1);
        // Same request id + same parameters: same job.
        let again = test.service.create_job(request("req-1", "game")).unwrap();
        assert_eq!(again.job_id, created.job_id);
        // Same request id + different parameters: conflict.
        let error = test
            .service
            .create_job(request("req-1", "other"))
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Conflict);
    }

    #[test]
    fn validates_bad_requests() {
        let test = test_service(4);
        let mut bad = request("req-1", "-bad");
        assert_eq!(
            test.service.create_job(bad.clone()).unwrap_err().code,
            ErrorCode::BadRequest
        );
        bad = request("req-1", "ok");
        bad.inputs.clear();
        assert_eq!(
            test.service.create_job(bad.clone()).unwrap_err().code,
            ErrorCode::BadRequest
        );
        bad = request("bad request id", "ok");
        assert_eq!(
            test.service.create_job(bad).unwrap_err().code,
            ErrorCode::BadRequest
        );
        let mut too_big = request("req-2", "ok");
        too_big.inputs[0].bytes = u64::MAX;
        assert_eq!(
            test.service.create_job(too_big).unwrap_err().code,
            ErrorCode::PayloadTooLarge
        );
        let mut path_mode = request("req-3", "ok");
        path_mode.transport = TransportMode::Path;
        assert_eq!(
            test.service.create_job(path_mode).unwrap_err().code,
            ErrorCode::BadRequest
        );
    }

    #[test]
    fn input_ready_queues_and_verifies() {
        let test = test_service(4);
        let created = test.service.create_job(request("req-1", "game")).unwrap();
        // Missing input: refused, job stays created.
        assert_eq!(
            test.service.input_ready(&created.job_id).unwrap_err().code,
            ErrorCode::InputInvalid
        );
        upload_input(&test.service, &created.job_id);
        test.service.input_ready(&created.job_id).unwrap();
        let view = test.service.job_view(&created.job_id).unwrap();
        assert_eq!(view.state, JobState::Queued);
        // Second input_ready is a conflict.
        assert_eq!(
            test.service.input_ready(&created.job_id).unwrap_err().code,
            ErrorCode::Conflict
        );
    }

    #[test]
    fn queue_limit_is_enforced() {
        let test = test_service(1);
        let first = test.service.create_job(request("req-1", "game-a")).unwrap();
        upload_input(&test.service, &first.job_id);
        test.service.input_ready(&first.job_id).unwrap();
        // One job queued already (the worker may pick it up, but the service is
        // not started here, so it stays queued).
        let error = test
            .service
            .create_job(request("req-2", "game-b"))
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::QueueFull);
        assert!(error.retryable);
        assert!(error.details.is_some());
    }

    #[test]
    fn cancel_created_and_queued_jobs() {
        let test = test_service(4);
        let created = test.service.create_job(request("req-1", "game")).unwrap();
        let canceled = test
            .service
            .cancel_job(&created.job_id, Some("test"))
            .unwrap();
        assert_eq!(canceled.state, JobState::Canceled);
        let view = test.service.job_view(&created.job_id).unwrap();
        assert_eq!(view.state, JobState::Canceled);
        assert!(!view.inputs_present);
        // Canceling a terminal job is a conflict.
        assert_eq!(
            test.service
                .cancel_job(&created.job_id, None)
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
    }

    #[test]
    fn events_are_ordered_and_persisted() {
        let test = test_service(4);
        let created = test.service.create_job(request("req-1", "game")).unwrap();
        let entry = test.service.entry(&created.job_id).unwrap();
        test.service
            .log(&entry, None, LogSource::Agent, LogLevel::Info, "hello");
        test.service
            .log(&entry, None, LogSource::Agent, LogLevel::Info, "world");
        let events = store::read_events(&entry.events_path);
        // job acceptance emits one log event before the two test lines.
        assert_eq!(events.len(), 3);
        assert!(events[0].seq < events[1].seq && events[1].seq < events[2].seq);
        assert_eq!(events[1].line.as_deref(), Some("hello"));
        assert_eq!(events[2].line.as_deref(), Some("world"));
        let (subscription, reply) = test.service.subscribe(&created.job_id, 0).unwrap();
        assert_eq!(reply.earliest_seq, events[0].seq);
        assert!(!reply.log_truncated);
        assert_eq!(subscription.replay.len(), 3);
    }

    #[test]
    fn list_and_delete_require_terminal_state() {
        let test = test_service(4);
        let created = test.service.create_job(request("req-1", "game")).unwrap();
        assert_eq!(test.service.list_jobs(None, None).unwrap().jobs.len(), 1);
        assert_eq!(
            test.service.delete_job(&created.job_id).unwrap_err().code,
            ErrorCode::Conflict
        );
        test.service.cancel_job(&created.job_id, None).unwrap();
        test.service.delete_job(&created.job_id).unwrap();
        assert!(test.service.list_jobs(None, None).unwrap().jobs.is_empty());
    }

    #[test]
    fn split_log_lines_respects_utf8_and_limit() {
        assert_eq!(split_log_line("short"), vec!["short".to_string()]);
        let long = "é".repeat(MAX_LOG_LINE_BYTES);
        let parts = split_log_line(&long);
        assert!(parts.len() >= 2);
        for part in &parts {
            assert!(part.len() <= MAX_LOG_LINE_BYTES);
            assert!(part.is_char_boundary(part.len()));
        }
        assert_eq!(parts.concat(), long);
    }

    #[test]
    fn fingerprint_detects_parameter_changes() {
        let one = request("req-1", "game");
        let two = request("req-1", "game");
        let three = request("req-1", "other");
        assert_eq!(request_fingerprint(&one), request_fingerprint(&two));
        assert_ne!(request_fingerprint(&one), request_fingerprint(&three));
    }
}
