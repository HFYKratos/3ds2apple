//! Frame-time accounting, profiler bridging and log forwarding for the iOS C ABI.
//!
//! The app can read the last timings (`zk_last_frame_micros` and friends) and
//! also gets a periodic one-line summary on stderr, which `idevicesyslog`
//! captures without any Swift change. That line is what tells CPU emulation,
//! the software PICA200 and presentation apart; `PERF.md` explains how to read
//! it.
//!
//! A `profiling` build additionally samples guest PCs and puts the hottest
//! ones in that line. Sampling costs a little per step, so release builds
//! leave it off.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, Once};
use std::time::{Duration, Instant};

use zakuro_core::kernel::thread::CPU_CLOCK_HZ;
use zakuro_core::System;

/// Frames between `zk_perf` log lines: about two seconds at 30 fps.
pub const DEFAULT_LOG_INTERVAL: u32 = 60;

/// Guest PC hot spots listed in the log when the profiler runs.
const LOGGED_HOT_SPOTS: usize = 3;

/// Microseconds the last `zk_run_frame` call took.
static LAST_FRAME_MICROS: AtomicU64 = AtomicU64::new(0);
/// Microseconds the last `zk_read_screen` call took, index 0 top, 1 bottom.
static LAST_SCREEN_READ_MICROS: [AtomicU64; 2] = [AtomicU64::new(0), AtomicU64::new(0)];
/// Microseconds the last `zk_take_audio` call took.
static LAST_AUDIO_TAKE_MICROS: AtomicU64 = AtomicU64::new(0);

/// Logs Zakuro's own records (`log::info!`/`log::warn!`) to stderr.
///
/// The loader explains why it refused linked code through `log`, but an iOS
/// app installs no logger, so without this those records go nowhere and the
/// only clue on a device is `zk_recompiled()` returning 0.
struct StderrLogger;

impl log::Log for StderrLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record<'_>) {
        if self.enabled(record.metadata()) {
            eprintln!("zk[{}] {}", record.level(), record.args());
        }
    }

    fn flush(&self) {}
}

static LOGGER: StderrLogger = StderrLogger;
static INSTALL_LOGGER: Once = Once::new();

/// Installs [`StderrLogger`] once, keeping the level at info.
///
/// If the embedding app already installed a logger, this leaves it alone (it
/// may even be showing these records elsewhere).
pub fn install_logger() {
    INSTALL_LOGGER.call_once(|| {
        if log::set_logger(&LOGGER).is_ok() {
            log::set_max_level(log::LevelFilter::Info);
        }
    });
}

/// The window of frames a log line summarizes, with the cumulative system
/// counters at the window's start so deltas can be worked out.
struct Window {
    started: Instant,
    frames: u64,
    frame_total_us: u64,
    frame_max_us: u64,
    screen_reads: u64,
    screen_total_us: [u64; 2],
    screen_max_us: [u64; 2],
    audio_takes: u64,
    audio_total_us: u64,
    // baselines of the System's cumulative counters.
    gpu_busy: Duration,
    draws: u64,
    transfers: u64,
    fills: u64,
    cycles: u64,
    interpreted: u64,
    recompiled: u64,
    /// instructions the linked code handed back, cumulative in the `System`.
    fallbacks: u64,
}

impl Window {
    fn new(system: &System) -> Window {
        Window {
            started: Instant::now(),
            frames: 0,
            frame_total_us: 0,
            frame_max_us: 0,
            screen_reads: 0,
            screen_total_us: [0; 2],
            screen_max_us: [0; 2],
            audio_takes: 0,
            audio_total_us: 0,
            gpu_busy: system.gpu.busy,
            draws: system.gpu.draw_calls,
            transfers: system.gpu.transfers,
            fills: system.gpu.fills,
            cycles: system.cpu.cycles,
            interpreted: system.interpreted_instructions,
            recompiled: system.recompiled_instructions,
            fallbacks: system
                .recompiled
                .as_ref()
                .map_or(0, |library| library.fallbacks()),
        }
    }
}

/// One `zk_perf` line's numbers, taken while the lock is held.
struct Summary {
    frames: u64,
    seconds: f64,
    frame_avg_ms: f64,
    frame_max_ms: f64,
    screen_avg_ms: [f64; 2],
    screen_max_ms: [f64; 2],
    screen_reads: u64,
    audio_avg_ms: f64,
    audio_takes: u64,
    gpu_ms_per_frame: f64,
    non_gpu_ms_per_frame: f64,
    speed_percent: f64,
    cycles_per_second: f64,
    draws_per_frame: f64,
    transfers_per_frame: f64,
    fills_per_frame: f64,
    interpreted_percent: f64,
    aot_active: bool,
    hot_spots: Vec<(String, u32, u64)>,
}

static WINDOW: Mutex<Option<Window>> = Mutex::new(None);

/// Locks the window without ever panicking across the FFI boundary (a panic
/// would abort the app; a poisoned lock still holds usable counts).
fn lock_window() -> std::sync::MutexGuard<'static, Option<Window>> {
    WINDOW
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

/// Records one completed `zk_run_frame` call and, every
/// [`DEFAULT_LOG_INTERVAL`] frames, logs a summary of the window.
pub fn record_frame(system: &System, duration: Duration, result: i32) {
    let elapsed_us = micros(duration);
    LAST_FRAME_MICROS.store(elapsed_us, Ordering::Relaxed);

    let mut guard = lock_window();
    let Some(window) = guard.as_mut() else {
        // The first frame is worth its own line: it carries the boot cost.
        eprintln!(
            "zk_perf: first frame {:.1}ms (emulation boot + first frame); later lines are window averages",
            elapsed_us as f64 / 1000.0
        );
        *guard = Some(Window::new(system));
        drop(guard);
        if result != 0 {
            eprintln!("zk_perf: first frame ended with result {result}");
        }
        return;
    };

    window.frames += 1;
    window.frame_total_us += elapsed_us;
    window.frame_max_us = window.frame_max_us.max(elapsed_us);

    if window.frames >= u64::from(DEFAULT_LOG_INTERVAL) || result != 0 {
        let summary = summarize(window, system);
        *guard = Some(Window::new(system));
        drop(guard);
        eprintln!("{}", format_summary(&summary));
        if result != 0 {
            eprintln!("zk_perf: frame loop stopped with result {result}");
        }
    }
}

/// Records one `zk_read_screen` call, `which` uses the same 0/other split as
/// `zk_screen_width`.
pub fn record_screen_read(which: u32, duration: Duration) {
    let index = usize::from(which != 0);
    let elapsed_us = micros(duration);
    LAST_SCREEN_READ_MICROS[index].store(elapsed_us, Ordering::Relaxed);

    if let Some(window) = lock_window().as_mut() {
        window.screen_reads += 1;
        window.screen_total_us[index] += elapsed_us;
        window.screen_max_us[index] = window.screen_max_us[index].max(elapsed_us);
    }
}

/// Records one `zk_take_audio` call.
pub fn record_audio_take(duration: Duration) {
    let elapsed_us = micros(duration);
    LAST_AUDIO_TAKE_MICROS.store(elapsed_us, Ordering::Relaxed);

    if let Some(window) = lock_window().as_mut() {
        window.audio_takes += 1;
        window.audio_total_us += elapsed_us;
    }
}

/// Clears the last-call timings and the window, so a new `System` starts from
/// zero and the log says "first frame" again.
///
/// Called by [`crate::zk_create`]: the previous system's counters mean nothing
/// for a new one, and a reload would otherwise report a mix of both.
pub fn reset() {
    LAST_FRAME_MICROS.store(0, Ordering::Relaxed);
    for cell in &LAST_SCREEN_READ_MICROS {
        cell.store(0, Ordering::Relaxed);
    }
    LAST_AUDIO_TAKE_MICROS.store(0, Ordering::Relaxed);
    *lock_window() = None;
}

/// The last `zk_run_frame` duration in microseconds, 0 before the first frame.
pub fn last_frame_micros() -> u64 {
    LAST_FRAME_MICROS.load(Ordering::Relaxed)
}

/// The last `zk_read_screen` duration in microseconds, 0 before the first read.
pub fn last_screen_read_micros(which: u32) -> u64 {
    LAST_SCREEN_READ_MICROS[usize::from(which != 0)].load(Ordering::Relaxed)
}

/// The last `zk_take_audio` duration in microseconds, 0 before the first call.
pub fn last_audio_take_micros() -> u64 {
    LAST_AUDIO_TAKE_MICROS.load(Ordering::Relaxed)
}

/// Finishes the window into the numbers the log line shows.
fn summarize(window: &mut Window, system: &System) -> Summary {
    let seconds = window.started.elapsed().as_secs_f64();
    let frames = window.frames;
    let frame_avg_us = window.frame_total_us as f64 / frames as f64;

    // host time the software GPU spent walking command lists inside the frame.
    let gpu_busy = system.gpu.busy.saturating_sub(window.gpu_busy);
    let gpu_us = micros(gpu_busy) as f64 / frames as f64;
    let non_gpu_us = (frame_avg_us - gpu_us).max(0.0);

    let cycles = system.cpu.cycles.saturating_sub(window.cycles);
    let cycles_per_second = if seconds > 0.0 {
        cycles as f64 / seconds
    } else {
        0.0
    };

    // what ran in the interpreter despite the recompiled library, as
    // `status_line` counts it (fallbacks happen inside recompiled code). The
    // library's count is cumulative, so take the window's delta: adding the
    // total again every window would inflate the percentage.
    let fallbacks = system
        .recompiled
        .as_ref()
        .map_or(0, |library| library.fallbacks())
        .saturating_sub(window.fallbacks);
    let interpreted = system
        .interpreted_instructions
        .saturating_sub(window.interpreted)
        .saturating_add(fallbacks);
    let recompiled = system
        .recompiled_instructions
        .saturating_sub(window.recompiled);
    let interpreted_percent = if interpreted + recompiled == 0 {
        0.0
    } else {
        interpreted as f64 * 100.0 / (interpreted + recompiled) as f64
    };

    let per_frame = |count: u64| count as f64 / frames as f64;

    Summary {
        frames,
        seconds,
        frame_avg_ms: frame_avg_us / 1000.0,
        frame_max_ms: window.frame_max_us as f64 / 1000.0,
        screen_avg_ms: [
            window.screen_total_us[0] as f64 / frames as f64 / 1000.0,
            window.screen_total_us[1] as f64 / frames as f64 / 1000.0,
        ],
        screen_max_ms: [
            window.screen_max_us[0] as f64 / 1000.0,
            window.screen_max_us[1] as f64 / 1000.0,
        ],
        screen_reads: window.screen_reads,
        audio_avg_ms: window.audio_total_us as f64 / frames as f64 / 1000.0,
        audio_takes: window.audio_takes,
        gpu_ms_per_frame: gpu_us / 1000.0,
        non_gpu_ms_per_frame: non_gpu_us / 1000.0,
        speed_percent: cycles_per_second * 100.0 / CPU_CLOCK_HZ as f64,
        cycles_per_second,
        draws_per_frame: per_frame(system.gpu.draw_calls.saturating_sub(window.draws)),
        transfers_per_frame: per_frame(system.gpu.transfers.saturating_sub(window.transfers)),
        fills_per_frame: per_frame(system.gpu.fills.saturating_sub(window.fills)),
        interpreted_percent,
        aot_active: system.recompiled.is_some(),
        hot_spots: if system.profile.is_some() {
            system.hot_spots(LOGGED_HOT_SPOTS)
        } else {
            Vec::new()
        },
    }
}

/// Formats one `zk_perf` line. Function names are not available for guest
/// addresses, so hot spots are PCs; `PERF.md` says how to read them.
fn format_summary(summary: &Summary) -> String {
    let mut line = format!(
        "zk_perf: {} frames in {:.2}s | frame avg {:.2}ms max {:.2}ms | \
         read top {:.2}ms/{:.2}ms bottom {:.2}ms/{:.2}ms ({} reads) | \
         audio {:.2}ms ({} takes) | gpu {:.2}ms/frame non-gpu {:.2}ms/frame | \
         cpu {:.1}M cyc/s ({:.1}% of real time) | draws {:.0}/f xfr {:.0}/f fills {:.0}/f | \
         interpreted {:.2}% | AOT {}",
        summary.frames,
        summary.seconds,
        summary.frame_avg_ms,
        summary.frame_max_ms,
        summary.screen_avg_ms[0],
        summary.screen_max_ms[0],
        summary.screen_avg_ms[1],
        summary.screen_max_ms[1],
        summary.screen_reads,
        summary.audio_avg_ms,
        summary.audio_takes,
        summary.gpu_ms_per_frame,
        summary.non_gpu_ms_per_frame,
        summary.cycles_per_second / 1e6,
        summary.speed_percent,
        summary.draws_per_frame,
        summary.transfers_per_frame,
        summary.fills_per_frame,
        summary.interpreted_percent,
        if summary.aot_active {
            "active"
        } else {
            "interpreting"
        },
    );
    if !summary.hot_spots.is_empty() {
        line.push_str(" | hot");
        for (thread, pc, hits) in &summary.hot_spots {
            line.push_str(&format!(" {thread}@0x{pc:08X}x{hits}"));
        }
    }
    line
}

/// The top `count` sampled guest PCs as text, one per line, as
/// `zk_profiler_hot_spots` returns them.
pub fn format_hot_spots(system: &System, count: usize) -> String {
    let mut text = String::new();
    for (thread, pc, hits) in system.hot_spots(count) {
        text.push_str(&format!("{thread} 0x{pc:08X} {hits}\n"));
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timings_start_at_zero() {
        // No frame has run on this test's account, so nothing to report yet.
        // Other tests never call the frame entry points (there is no ROM).
        assert_eq!(last_frame_micros(), 0);
        assert_eq!(last_screen_read_micros(0), 0);
        assert_eq!(last_screen_read_micros(1), 0);
        assert_eq!(last_audio_take_micros(), 0);
    }

    #[test]
    fn reset_clears_the_measurements() {
        reset();
        assert_eq!(last_frame_micros(), 0);
        assert_eq!(last_screen_read_micros(0), 0);
        assert_eq!(last_screen_read_micros(1), 0);
        assert_eq!(last_audio_take_micros(), 0);
        // The first frame after a reset is logged with its boot cost again.
        assert!(lock_window().is_none());
    }

    #[test]
    fn hot_spots_format_is_empty_without_the_profiler() {
        // Without a System there is nothing to sample; the formatter must not
        // invent entries. The FFI entry point is checked in lib.rs.
        assert!(format_summary_empty_hot_spots());
    }

    #[test]
    fn summary_line_has_the_fields_perf_md_documents() {
        let summary = Summary {
            frames: 60,
            seconds: 2.0,
            frame_avg_ms: 34.5,
            frame_max_ms: 41.0,
            screen_avg_ms: [2.0, 1.8],
            screen_max_ms: [2.6, 2.3],
            screen_reads: 60,
            audio_avg_ms: 0.05,
            audio_takes: 60,
            gpu_ms_per_frame: 18.0,
            non_gpu_ms_per_frame: 16.5,
            speed_percent: 47.0,
            cycles_per_second: 126_000_000.0,
            draws_per_frame: 512.0,
            transfers_per_frame: 8.0,
            fills_per_frame: 2.0,
            interpreted_percent: 0.21,
            aot_active: true,
            hot_spots: Vec::new(),
        };
        let line = format_summary(&summary);
        for field in [
            "zk_perf:",
            "frame avg",
            "gpu",
            "non-gpu",
            "interpreted",
            "AOT active",
        ] {
            assert!(line.contains(field), "missing {field}: {line}");
        }
        assert!(line.len() < 512, "log line grew too long: {line}");
    }

    /// A summary with no hot spots has nothing to append; this keeps the
    /// formatter's empty branch exercised without a System.
    fn format_summary_empty_hot_spots() -> bool {
        let summary = Summary {
            frames: 1,
            seconds: 1.0,
            frame_avg_ms: 1.0,
            frame_max_ms: 1.0,
            screen_avg_ms: [0.0; 2],
            screen_max_ms: [0.0; 2],
            screen_reads: 0,
            audio_avg_ms: 0.0,
            audio_takes: 0,
            gpu_ms_per_frame: 0.0,
            non_gpu_ms_per_frame: 1.0,
            speed_percent: 1.0,
            cycles_per_second: 4_481_136.0,
            draws_per_frame: 0.0,
            transfers_per_frame: 0.0,
            fills_per_frame: 0.0,
            interpreted_percent: 100.0,
            aot_active: false,
            hot_spots: Vec::new(),
        };
        !format_summary(&summary).contains(" | hot")
    }
}
