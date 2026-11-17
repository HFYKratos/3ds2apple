//! Frame-time accounting, profiler bridging and log forwarding for the iOS C ABI.
//!
//! The app can read the last timings (`zk_last_frame_micros` and friends) and
//! also gets a periodic one-line summary on stderr, which `idevicesyslog`
//! captures without any Swift change. That line is what tells CPU emulation,
//! the software PICA200 and presentation apart; `ios/zakuro-ios/README.md` explains how to read
//! it.
//!
//! A `profiling` build additionally samples guest PCs and puts the hottest
//! ones in that line. Sampling costs a little per step, so release builds
//! leave it off.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, Once};
use std::time::{Duration, Instant};

use zakuro_core::kernel::thread::CPU_CLOCK_HZ;
use zakuro_core::System;
use zakuro_gpu::GpuTimes;

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
/// Microseconds the software GPU walked command lists inside the last
/// `zk_run_frame` call: the same slice the periodic `zk_perf` line prints as
/// `gpu`. The rest of the frame is emulated CPU / HLE work. 0 before the first
/// frame; the first frame after a reset carries the boot cost like
/// [`LAST_FRAME_MICROS`].
static LAST_FRAME_GPU_BUSY_MICROS: AtomicU64 = AtomicU64::new(0);
/// Cumulative `system.gpu.busy` at the previous recorded frame, so each frame
/// reports its own slice instead of the running total.
static GPU_BUSY_BASELINE_MICROS: AtomicU64 = AtomicU64::new(0);

/// Microseconds per frame the GPU itself executed over the last `zk_perf`
/// window, from its own timestamp queries (the hardware renderer's
/// `ZAKURO_GPU_TIMES=1`), 0 while they are not measured.
static LAST_GPU_EXEC_MICROS_PER_FRAME: AtomicU64 = AtomicU64::new(0);
/// Whether the loaded renderer measures the GPU's own times, so the app knows
/// whether [`last_gpu_exec_micros_per_frame`] means anything.
static GPU_TIMES_MEASURED: AtomicBool = AtomicBool::new(false);
/// The last window's full GPU breakdown, one line, for the diagnostics
/// export.
static GPU_TIMES_LINE: Mutex<String> = Mutex::new(String::new());

/// Locks the GPU line without ever panicking across the FFI boundary (a
/// poisoned lock still holds usable text).
fn lock_gpu_line() -> std::sync::MutexGuard<'static, String> {
    GPU_TIMES_LINE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

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
    /// the GPU's own timings at the window's start, when they are measured.
    gpu_times: Option<GpuTimes>,
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
            gpu_times: system.gpu.gpu_times(),
        }
    }
}

/// The GPU's own timestamps for a window, averaged per frame: the real
/// execution time the system Metal HUD shows as GPU time, split by the kind of
/// work the renderer changed to (see `zakuro_gpu::GPU_WORK`).
struct GpuSummary {
    /// milliseconds the GPU executed per frame.
    exec_ms: f64,
    /// milliseconds per kind of work per frame, in `zakuro_gpu::GPU_WORK`
    /// order.
    work_ms: [f64; 9],
    /// render passes, barriers and draws recorded per frame.
    renderings: f64,
    barriers: f64,
    draws: f64,
    /// milliseconds the host waited for the GPU per frame, and how many waits.
    host_wait_ms: f64,
    host_waits: u64,
    /// vertices, primitives past clipping, fragments and compute invocations
    /// per frame, 0 when the device keeps no pipeline statistics.
    shaded: [f64; 4],
    statistics: bool,
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
    /// the GPU's own times over the window, none while they are not measured.
    gpu: Option<GpuSummary>,
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

    // Split the frame into the software GPU's command walk and the rest
    // (emulated CPU, HLE, audio). `System::gpu.busy` is cumulative, so keep a
    // baseline and store this frame's delta; the first frame after a reset
    // reports the boot cost, like the frame time itself.
    let gpu_busy_total = micros(system.gpu.busy);
    let gpu_busy_baseline = GPU_BUSY_BASELINE_MICROS.swap(gpu_busy_total, Ordering::Relaxed);
    LAST_FRAME_GPU_BUSY_MICROS.store(
        gpu_busy_total.saturating_sub(gpu_busy_baseline),
        Ordering::Relaxed,
    );

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
        // keep what the app and the diagnostics report read: the real GPU
        // execution time and its breakdown, whether it is measured at all.
        let exec = summary.gpu.as_ref().map_or(0, |gpu| (gpu.exec_ms * 1000.0).round() as u64);
        LAST_GPU_EXEC_MICROS_PER_FRAME.store(exec, Ordering::Relaxed);
        GPU_TIMES_MEASURED.store(system.gpu.gpu_times().is_some(), Ordering::Relaxed);
        let gpu_line = format_gpu_line(&summary);
        *lock_gpu_line() = gpu_line.clone();
        eprintln!("{}", format_summary(&summary));
        if !gpu_line.is_empty() {
            eprintln!("{gpu_line}");
        }
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
    LAST_FRAME_GPU_BUSY_MICROS.store(0, Ordering::Relaxed);
    GPU_BUSY_BASELINE_MICROS.store(0, Ordering::Relaxed);
    LAST_GPU_EXEC_MICROS_PER_FRAME.store(0, Ordering::Relaxed);
    GPU_TIMES_MEASURED.store(false, Ordering::Relaxed);
    lock_gpu_line().clear();
    *lock_window() = None;
}

/// The last `zk_run_frame` duration in microseconds, 0 before the first frame.
pub fn last_frame_micros() -> u64 {
    LAST_FRAME_MICROS.load(Ordering::Relaxed)
}

/// Microseconds the software GPU spent walking command lists inside the last
/// `zk_run_frame` call, 0 before the first frame.
///
/// The rest of [`last_frame_micros`] is emulated CPU / HLE work, so the app can
/// split `run` and tell a CPU-bound scene from a command-walk (pipeline
/// compile) spike on a device.
pub fn last_frame_gpu_busy_micros() -> u64 {
    LAST_FRAME_GPU_BUSY_MICROS.load(Ordering::Relaxed)
}

/// Microseconds per frame the GPU itself executed over the last `zk_perf`
/// window, from the renderer's own timestamp queries, 0 while the GPU's times
/// are not measured (the diagnostic switch is off) or before the first window.
///
/// This is the execution time the system Metal HUD reports as GPU time, not
/// the host time the renderer's command walk took (that is
/// [`last_frame_gpu_busy_micros`]). It lags by at most one window and covers
/// the window's frames, so a scene comparison holds each reading for the same
/// number of frames.
pub fn last_gpu_exec_micros_per_frame() -> u64 {
    LAST_GPU_EXEC_MICROS_PER_FRAME.load(Ordering::Relaxed)
}

/// Whether the loaded renderer measures the GPU's own execution times, which
/// the diagnostic build turns on with `ZAKURO_GPU_TIMES=1`.
pub fn gpu_times_enabled() -> bool {
    GPU_TIMES_MEASURED.load(Ordering::Relaxed)
}

/// The last window's full GPU breakdown as one line: execution time per kind
/// of work, render passes, barriers, draws, the host's waits for the GPU and
/// what the GPU shaded. Empty while the GPU's times are not measured or before
/// the first window.
pub fn gpu_times_line() -> String {
    lock_gpu_line().clone()
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
    let gpu = gpu_breakdown(window.gpu_times, system.gpu.gpu_times(), frames);

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
        gpu,
        hot_spots: if system.profile.is_some() {
            system.hot_spots(LOGGED_HOT_SPOTS)
        } else {
            Vec::new()
        },
    }
}

/// The GPU's own timestamps for a window, averaged per frame, from the
/// renderer's cumulative readings at the window's start and end. None while the
/// GPU's times are not measured.
fn gpu_breakdown(baseline: Option<GpuTimes>, current: Option<GpuTimes>, frames: u64) -> Option<GpuSummary> {
    let (baseline, current) = (baseline?, current?);
    if frames == 0 {
        return None;
    }
    let work = current.since(&baseline);
    let per_frame = |value: f64| value / frames as f64;
    let mut shaded = [0u64; 4];
    for (delta, (now, before)) in shaded.iter_mut().zip(current.shaded.iter().zip(baseline.shaded.iter())) {
        *delta = now.saturating_sub(*before);
    }
    Some(GpuSummary {
        exec_ms: per_frame(work.iter().sum::<f64>()),
        work_ms: work.map(per_frame),
        renderings: per_frame(current.renderings.saturating_sub(baseline.renderings) as f64),
        barriers: per_frame(current.barriers.saturating_sub(baseline.barriers) as f64),
        draws: per_frame(current.draws.saturating_sub(baseline.draws) as f64),
        host_wait_ms: per_frame(
            (current.waited_room_ms - baseline.waited_room_ms).max(0.0)
                + (current.waited_done_ms - baseline.waited_done_ms).max(0.0),
        ),
        host_waits: current
            .waited_room_count
            .saturating_sub(baseline.waited_room_count)
            .saturating_add(current.waited_done_count.saturating_sub(baseline.waited_done_count)),
        shaded: shaded.map(|count| per_frame(count as f64)),
        statistics: current.pipeline_statistics,
    })
}

/// Formats one `zk_perf` line. Function names are not available for guest
/// addresses, so hot spots are PCs; `ios/zakuro-ios/README.md` says how to read them.
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
    if let Some(gpu) = &summary.gpu {
        // the GPU's own timestamps: the execution time the system Metal HUD
        // shows, not the host command walk `gpu_ms_per_frame` counts.
        line.push_str(&format!(
            " | gpu_exec {:.2}ms/f passes {:.0}/f barriers {:.0}/f",
            gpu.exec_ms, gpu.renderings, gpu.barriers
        ));
        if gpu.statistics {
            line.push_str(&format!(
                " shaded {:.1}M/{:.1}M/{:.1}M v/p/f/f",
                gpu.shaded[0] / 1e6,
                gpu.shaded[1] / 1e6,
                gpu.shaded[2] / 1e6
            ));
        }
    }
    if !summary.hot_spots.is_empty() {
        line.push_str(" | hot");
        for (thread, pc, hits) in &summary.hot_spots {
            line.push_str(&format!(" {thread}@0x{pc:08X}x{hits}"));
        }
    }
    line
}

/// The last window's full GPU breakdown as one line, for the device log and
/// the diagnostics export: the execution time per kind of work, the passes,
/// barriers and draws it took, the host's waits and what the GPU shaded.
/// Empty while the GPU's own times are not measured.
fn format_gpu_line(summary: &Summary) -> String {
    let Some(gpu) = &summary.gpu else { return String::new() };
    let mut line = format!(
        "zk_gpu: {} frames | gpu_exec {:.2}ms/frame | passes {:.0}/f barriers {:.0}/f draws {:.0}/f host_wait {:.2}ms/f ({} waits)",
        summary.frames, gpu.exec_ms, gpu.renderings, gpu.barriers, gpu.draws, gpu.host_wait_ms, gpu.host_waits
    );
    for (name, milliseconds) in zakuro_gpu::raster::GPU_WORK.iter().zip(gpu.work_ms) {
        if milliseconds > 0.0 {
            line.push_str(&format!(" | {name} {milliseconds:.2}ms/f"));
        }
    }
    if gpu.statistics {
        line.push_str(&format!(
            " | shaded {:.2}M vertices {:.2}M primitives {:.2}M fragments {:.3}M compute per frame",
            gpu.shaded[0] / 1e6,
            gpu.shaded[1] / 1e6,
            gpu.shaded[2] / 1e6,
            gpu.shaded[3] / 1e6
        ));
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
        assert_eq!(last_frame_gpu_busy_micros(), 0);
        assert_eq!(last_screen_read_micros(0), 0);
        assert_eq!(last_screen_read_micros(1), 0);
        assert_eq!(last_audio_take_micros(), 0);
    }

    #[test]
    fn reset_clears_the_measurements() {
        reset();
        assert_eq!(last_frame_micros(), 0);
        assert_eq!(last_frame_gpu_busy_micros(), 0);
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
            gpu: None,
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
            gpu: None,
            hot_spots: Vec::new(),
        };
        !format_summary(&summary).contains(" | hot")
    }

    /// A GPU reading with `draw` time filled in and every other kind 0, as
    /// the renderer's timestamps report them.
    fn gpu_times(draw_ms: f64, draws: u64, renderings: u64, fragments: u64) -> GpuTimes {
        let mut milliseconds = [0.0; 9];
        milliseconds[1] = draw_ms;
        GpuTimes {
            batches: 1,
            milliseconds,
            draws,
            renderings,
            barriers: renderings + 1,
            waited_room_ms: 0.0,
            waited_room_count: 0,
            waited_done_ms: 0.0,
            waited_done_count: 0,
            shaded: [100, 50, fragments, 0],
            pipeline_statistics: true,
        }
    }

    #[test]
    fn gpu_breakdown_averages_the_window() {
        let baseline = gpu_times(100.0, 300, 20, 2_000);
        let current = gpu_times(400.0, 900, 80, 10_000);
        let gpu = gpu_breakdown(Some(baseline), Some(current), 10).expect("the GPU's times");
        assert!((gpu.exec_ms - 30.0).abs() < 1e-9, "exec {} ms", gpu.exec_ms);
        assert!((gpu.work_ms[1] - 30.0).abs() < 1e-9, "draw {} ms", gpu.work_ms[1]);
        assert!((gpu.draws - 60.0).abs() < 1e-9);
        assert!((gpu.renderings - 6.0).abs() < 1e-9);
        assert!((gpu.barriers - 6.0).abs() < 1e-9);
        assert!((gpu.shaded[2] - 800.0).abs() < 1e-9, "fragments {}", gpu.shaded[2]);
        assert!(gpu.statistics);
        assert_eq!(gpu.host_waits, 0);
        // no reading at the window's start or no frames means no average, not
        // a zero line
        assert!(gpu_breakdown(None, Some(current), 10).is_none());
        assert!(gpu_breakdown(Some(baseline), None, 10).is_none());
        assert!(gpu_breakdown(Some(baseline), Some(baseline), 0).is_none());
    }

    #[test]
    fn summary_and_gpu_line_carry_the_gpu_execution_time() {
        let summary = Summary {
            frames: 60,
            seconds: 2.0,
            frame_avg_ms: 22.0,
            frame_max_ms: 30.0,
            screen_avg_ms: [0.0; 2],
            screen_max_ms: [0.0; 2],
            screen_reads: 0,
            audio_avg_ms: 0.0,
            audio_takes: 60,
            gpu_ms_per_frame: 5.0,
            non_gpu_ms_per_frame: 17.0,
            speed_percent: 80.0,
            cycles_per_second: 214_000_000.0,
            draws_per_frame: 180.0,
            transfers_per_frame: 0.0,
            fills_per_frame: 2.0,
            interpreted_percent: 0.1,
            aot_active: true,
            gpu: Some(GpuSummary {
                exec_ms: 21.5,
                work_ms: [0.0, 20.0, 0.5, 0.2, 0.0, 0.3, 0.0, 0.0, 0.5],
                renderings: 12.0,
                barriers: 13.0,
                draws: 180.0,
                host_wait_ms: 0.4,
                host_waits: 6,
                shaded: [1_200_000.0, 600_000.0, 3_300_000.0, 0.0],
                statistics: true,
            }),
            hot_spots: Vec::new(),
        };
        let line = format_summary(&summary);
        for field in ["gpu_exec 21.50ms/f", "passes 12/f", "barriers 13/f", "shaded 1.2M/0.6M/3.3M"] {
            assert!(line.contains(field), "missing {field}: {line}");
        }
        // the host command walk keeps its own column, so the two are not
        // confused when reading a log
        assert!(line.contains("gpu 5.00ms/frame"), "missing the walk column: {line}");
        let gpu_line = format_gpu_line(&summary);
        for field in ["zk_gpu:", "gpu_exec 21.50ms/frame", "| draw 20.00ms/f", "passes 12/f", "3.30M fragments"] {
            assert!(gpu_line.contains(field), "missing {field}: {gpu_line}");
        }
        assert!(!gpu_line.contains("other 0.00"), "zero kinds are left out: {gpu_line}");
    }
}
