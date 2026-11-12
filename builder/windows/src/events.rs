//! Turn protocol job events into console output.
//!
//! The same renderer is what a graphical shell would consume: it reassembles
//! split log lines, suppresses duplicate stage transitions and keeps the state
//! machine knowledge (`EventKind`, `Stage`) out of the presentation code.

use builder_core::protocol::model::{EventKind, JobEvent, JobView, Stage, StageState};

/// One piece of console output produced from an event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rendered {
    /// A build stage started.
    Stage { stage: Stage },
    /// A complete log line (split lines are reassembled).
    Log(String),
    /// A warning reported by the Agent.
    Warning(String),
    /// A job state transition.
    State(String),
    /// The artifact summary.
    Artifact {
        name: String,
        bytes: u64,
        sha256: String,
    },
}

impl Rendered {
    /// Render to a console line (no trailing newline).
    pub fn line(&self) -> String {
        match self {
            Rendered::Stage { stage } => format!("== {}: {}", stage.label(), stage.description()),
            Rendered::Log(line) => line.clone(),
            Rendered::Warning(message) => format!("warning: {message}"),
            Rendered::State(state) => format!("== job {state}"),
            Rendered::Artifact {
                name,
                bytes,
                sha256,
            } => format!("artifact: {name} ({} bytes, sha256 {sha256})", bytes),
        }
    }
}

/// Stateful event renderer.
#[derive(Debug, Default)]
pub struct EventRenderer {
    last_stage: Option<Stage>,
    pending_parts: Vec<String>,
    pending_parts_expected: Option<u32>,
}

impl EventRenderer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Forget per-job state; call when attaching to a different job.
    pub fn reset(&mut self) {
        self.last_stage = None;
        self.pending_parts.clear();
        self.pending_parts_expected = None;
    }

    /// Render one event, or `None` when it produces no output.
    pub fn render(&mut self, event: &JobEvent) -> Option<Rendered> {
        match event.kind {
            EventKind::Log => self.render_log(event),
            EventKind::State => {
                if let Some(state) = event.state {
                    if state == builder_core::protocol::model::JobState::Running {
                        if let Some(stage) = event.stage {
                            if self.last_stage != Some(stage) {
                                self.last_stage = Some(stage);
                                return Some(Rendered::Stage { stage });
                            }
                            return None;
                        }
                    }
                    if state != builder_core::protocol::model::JobState::Created {
                        return Some(Rendered::State(state.label().to_string()));
                    }
                }
                None
            }
            EventKind::Warning => event.message.clone().map(Rendered::Warning),
            EventKind::Artifact => event.artifact.as_ref().map(|artifact| Rendered::Artifact {
                name: artifact.name.clone(),
                bytes: artifact.bytes,
                sha256: artifact.sha256.clone(),
            }),
            EventKind::End | EventKind::Heartbeat => None,
        }
    }

    fn render_log(&mut self, event: &JobEvent) -> Option<Rendered> {
        let part = event.line_part.unwrap_or(1);
        let parts = event.line_parts.unwrap_or(1);
        if parts <= 1 {
            let line = event.line.clone().unwrap_or_default();
            if line.trim().is_empty() {
                return None;
            }
            return Some(Rendered::Log(line));
        }
        if part == 1 {
            self.pending_parts.clear();
            self.pending_parts_expected = Some(parts);
        }
        if self.pending_parts_expected != Some(parts) {
            // A new split line started while the previous one was incomplete;
            // drop the stale fragments rather than joining unrelated output.
            self.pending_parts.clear();
            self.pending_parts_expected = Some(parts);
        }
        if let Some(line) = &event.line {
            self.pending_parts.push(line.clone());
        }
        if part < parts {
            return None;
        }
        let joined = std::mem::take(&mut self.pending_parts);
        self.pending_parts_expected = None;
        let text = joined.join("");
        if text.trim().is_empty() {
            return None;
        }
        Some(Rendered::Log(text))
    }
}

fn stage_symbol(state: StageState) -> &'static str {
    // Text markers rather than colour-only or emoji output, so the console stays
    // readable with any code page and screen reader.
    match state {
        StageState::Done => "[done ]",
        StageState::Running => "[>    ]",
        StageState::Pending => "[     ]",
        StageState::Failed => "[FAIL ]",
        StageState::Skipped => "[skip ]",
    }
}

fn format_duration(milliseconds: u64) -> String {
    let seconds = milliseconds / 1000;
    if seconds < 60 {
        format!("{seconds}s")
    } else {
        let minutes = seconds / 60;
        let rest = seconds % 60;
        format!("{minutes}m {rest:02}s")
    }
}

/// Stage table for `status`/result output.
pub fn stage_table(view: &JobView) -> Vec<String> {
    let mut lines = Vec::new();
    for stage in &view.stages {
        let duration = stage
            .duration_ms
            .map(|milliseconds| format!("  {}", format_duration(milliseconds)))
            .unwrap_or_default();
        lines.push(format!(
            "  {} {}{}",
            stage_symbol(stage.state),
            stage.name.label(),
            duration
        ));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;
    use builder_core::protocol::model::{
        ArtifactSummary, ErrorInfo, JobState, LogLevel, LogSource,
    };

    fn event(kind: EventKind, seq: u64) -> JobEvent {
        JobEvent {
            seq,
            job_id: "job_01J8Z3K4T9ABCDEFGHJKMNPQRS".to_string(),
            ts: "2026-11-12T19:00:00Z".to_string(),
            kind,
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
        }
    }

    #[test]
    fn plain_log_lines_pass_through() {
        let mut renderer = EventRenderer::new();
        let mut log = event(EventKind::Log, 1);
        log.line = Some("[build-recomp] compiling 12/100".to_string());
        assert_eq!(
            renderer.render(&log),
            Some(Rendered::Log("[build-recomp] compiling 12/100".to_string()))
        );
        assert!(renderer.render(&log).is_some(), "stateless for plain lines");
    }

    #[test]
    fn split_log_lines_are_reassembled_once() {
        let mut renderer = EventRenderer::new();
        let mut first = event(EventKind::Log, 2);
        first.line = Some("long line part one ".to_string());
        first.line_part = Some(1);
        first.line_parts = Some(3);
        let mut second = event(EventKind::Log, 3);
        second.line = Some("part two ".to_string());
        second.line_part = Some(2);
        second.line_parts = Some(3);
        let mut third = event(EventKind::Log, 4);
        third.line = Some("part three".to_string());
        third.line_part = Some(3);
        third.line_parts = Some(3);
        assert_eq!(renderer.render(&first), None);
        assert_eq!(renderer.render(&second), None);
        assert_eq!(
            renderer.render(&third),
            Some(Rendered::Log(
                "long line part one part two part three".to_string()
            ))
        );
    }

    #[test]
    fn empty_and_blank_logs_are_dropped() {
        let mut renderer = EventRenderer::new();
        let mut blank = event(EventKind::Log, 1);
        blank.line = Some("   ".to_string());
        assert_eq!(renderer.render(&blank), None);
        assert_eq!(renderer.render(&event(EventKind::Log, 2)), None);
    }

    #[test]
    fn stage_transitions_are_reported_once() {
        let mut renderer = EventRenderer::new();
        let mut running = event(EventKind::State, 1);
        running.state = Some(JobState::Running);
        running.stage = Some(Stage::Recompiling);
        assert_eq!(
            renderer.render(&running),
            Some(Rendered::Stage {
                stage: Stage::Recompiling
            })
        );
        assert_eq!(renderer.render(&running), None);
        running.stage = Some(Stage::Linking);
        assert_eq!(
            renderer.render(&running),
            Some(Rendered::Stage {
                stage: Stage::Linking
            })
        );
    }

    #[test]
    fn terminal_states_are_reported() {
        let mut renderer = EventRenderer::new();
        let mut succeeded = event(EventKind::State, 1);
        succeeded.state = Some(JobState::Succeeded);
        assert_eq!(
            renderer.render(&succeeded),
            Some(Rendered::State("Succeeded".to_string()))
        );
        let mut created = event(EventKind::State, 2);
        created.state = Some(JobState::Created);
        assert_eq!(renderer.render(&created), None);
    }

    #[test]
    fn warnings_and_artifacts_are_rendered() {
        let mut renderer = EventRenderer::new();
        let mut warning = event(EventKind::Warning, 1);
        warning.message = Some("source revision differs".to_string());
        assert_eq!(
            renderer.render(&warning),
            Some(Rendered::Warning("source revision differs".to_string()))
        );
        let mut artifact = event(EventKind::Artifact, 2);
        artifact.artifact = Some(ArtifactSummary {
            name: "pokemon-y-AOT.ipa".to_string(),
            bytes: 101_000_000,
            sha256: "aa".repeat(32),
        });
        assert_eq!(
            renderer.render(&artifact),
            Some(Rendered::Artifact {
                name: "pokemon-y-AOT.ipa".to_string(),
                bytes: 101_000_000,
                sha256: "aa".repeat(32),
            })
        );
    }

    #[test]
    fn end_and_heartbeats_are_silent() {
        let mut renderer = EventRenderer::new();
        assert_eq!(renderer.render(&event(EventKind::End, 9)), None);
        assert_eq!(renderer.render(&event(EventKind::Heartbeat, 10)), None);
    }

    #[test]
    fn log_metadata_is_ignored_by_the_console() {
        let mut renderer = EventRenderer::new();
        let mut log = event(EventKind::Log, 1);
        log.line = Some("[xcodebuild] Building target".to_string());
        log.source = Some(LogSource::Xcodebuild);
        log.level = Some(LogLevel::Info);
        let rendered = renderer.render(&log).unwrap();
        assert_eq!(rendered.line(), "[xcodebuild] Building target");
    }

    #[test]
    fn stage_table_marks_states_with_text() {
        let mut view: JobView = serde_json::from_value(serde_json::json!({
            "job_id": "job_01J8Z3K4T9ABCDEFGHJKMNPQRS",
            "state": "running",
            "stage": "linking",
            "created_at": "2026-11-12T19:00:00Z",
            "updated_at": "2026-11-12T19:01:00Z",
            "stages": [
                {"name": "preparing", "state": "done", "duration_ms": 2000},
                {"name": "recompiling", "state": "done", "duration_ms": 662000},
                {"name": "linking", "state": "running"},
                {"name": "packaging", "state": "pending"},
                {"name": "verifying", "state": "pending"}
            ],
            "inputs_present": true
        }))
        .unwrap();
        assert_eq!(view.state, JobState::Running);
        let table = stage_table(&view);
        assert_eq!(table.len(), 5);
        assert!(table[0].contains("[done ] Preparing"), "{table:?}");
        assert!(table[1].contains("11m 02s"), "{table:?}");
        assert!(table[2].contains("[>    ] Linking"), "{table:?}");
        assert!(table[3].contains("[     ] Packaging"), "{table:?}");
        view.state = JobState::Succeeded;
    }

    #[test]
    fn rendered_lines_have_no_trailing_whitespace() {
        let rendered = Rendered::Stage {
            stage: Stage::Preparing,
        };
        assert_eq!(rendered.line().trim_end(), rendered.line());
        let warning = Rendered::Warning("careful".to_string()).line();
        assert_eq!(warning, "warning: careful");
        let _ = ErrorInfo::new(builder_core::protocol::codes::ErrorCode::BuildFailed, "x");
    }
}
