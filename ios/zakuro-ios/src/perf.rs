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
use zakuro_gpu::{
    draw_class_name, GpuTimes, PassTimes, BREAK_KINDS, DRAW_CLASSES, GPU_WORK, SORT_REASONS,
};

/// Frames between `zk_perf` log lines: about two seconds at 30 fps.
pub const DEFAULT_LOG_INTERVAL: u32 = 60;

/// Guest PC hot spots listed in the log when the profiler runs.
const LOGGED_HOT_SPOTS: usize = 3;

/// Render targets listed in the GPU line, the one that cost most first.
const REPORTED_PASSES: usize = 5;

/// Draw-state classes listed in the GPU line, the one that cost most first.
const REPORTED_DRAW_CLASSES: usize = 8;

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
    /// the render targets' cumulative GPU times at the window's start.
    gpu_passes: Vec<PassTimes>,
    /// the last per-pass report the renderer logged, at the window's start.
    gpu_passes_line: String,
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
            gpu_passes: system.gpu.gpu_passes(),
            gpu_passes_line: system.gpu.gpu_passes_line(),
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
    work_ms: [f64; GPU_WORK.len()],
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
    /// the front-to-back sort per frame, 0 when it is off: the draws it
    /// considered, the ones it held back, the runs it recorded, and the
    /// reason each draw was held or not in `zakuro_gpu::SORT_REASONS` order.
    sort_draws: f64,
    sort_candidates: f64,
    sort_runs: f64,
    sort_reasons: [f64; SORT_REASONS.len()],
    /// draws a render pass kept instead of ending it and beginning its own per
    /// frame (`ZAKURO_MERGE_PASSES=1`).
    merged_draws: f64,
    /// render passes that ended per frame, by what needed the drawings first,
    /// in `zakuro_gpu::BREAK_KINDS` order.
    breaks: [f64; BREAK_KINDS.len()],
    /// how many times each kind of work started per frame, in
    /// `zakuro_gpu::GPU_WORK` order.
    work_ops: [f64; GPU_WORK.len()],
    /// captures skipped because the surface still held the batch's picture per
    /// frame (`ZAKURO_DEDUPE_CAPTURE=1`).
    captures_skipped: f64,
    /// the draw-state classes the GPU's time went to per frame, the one that
    /// cost most first: what a frame's draws cost apart by blend, alpha test,
    /// texture units, writes and estimated coverage, see
    /// `zakuro_gpu::DRAW_CLASSES`.
    draw_classes: Vec<DrawClass>,
    /// draws skipped because they could not change either buffer per frame,
    /// and the pixels they would have covered (`ZAKURO_SAFE_SKIPS=1`).
    safe_skips: f64,
    safe_skipped_pixels: f64,
    /// the last per-pass report when it changed in this window: the dominant
    /// render target's passes in recording order.
    passes_line: String,
    /// the render targets the GPU's own time went to per frame, the one that
    /// cost most first.
    passes: Vec<GpuPass>,
}

/// One draw-state class the GPU's own time went to over the window, per frame.
#[derive(Debug, Default)]
struct DrawClass {
    /// the class's parts, `blend/alpha/tex/write/coverage`, see
    /// `zakuro_gpu::draw_class_name`.
    name: String,
    /// milliseconds the GPU spent in draws of the class per frame, the draws
    /// recorded and the pixels their triangles estimate to cover.
    ms: f64,
    draws: f64,
    pixels: f64,
}

/// One render target the GPU's own time went to over the window, per frame.
#[derive(Debug, Default)]
struct GpuPass {
    /// where the target's color buffer is in guest memory, its size at the
    /// console's resolution and whether its passes rendered to a depth buffer.
    addr: u32,
    width: u32,
    height: u32,
    depth: bool,
    /// milliseconds the GPU spent in the target's passes per frame, and the
    /// passes and draws they recorded per frame.
    ms: f64,
    passes: f64,
    draws: f64,
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
    let gpu = gpu_breakdown(
        window.gpu_times,
        system.gpu.gpu_times(),
        &window.gpu_passes,
        &system.gpu.gpu_passes(),
        &window.gpu_passes_line,
        &system.gpu.gpu_passes_line(),
        frames,
    );

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
fn gpu_breakdown(
    baseline: Option<GpuTimes>,
    current: Option<GpuTimes>,
    baseline_passes: &[PassTimes],
    current_passes: &[PassTimes],
    baseline_line: &str,
    current_line: &str,
    frames: u64,
) -> Option<GpuSummary> {
    let (baseline, current) = (baseline?, current?);
    if frames == 0 {
        return None;
    }
    let work = current.since(&baseline);
    let per_frame = |value: f64| value / frames as f64;
    // each target's window, from the cumulative readings at its two ends, the
    // one that cost most per frame first
    let mut passes: Vec<GpuPass> = current_passes
        .iter()
        .filter_map(|pass| {
            let before = baseline_passes.iter().find(|before| before.addr == pass.addr);
            let before = before.copied().unwrap_or_default();
            let ms = per_frame((pass.milliseconds - before.milliseconds).max(0.0));
            Some(GpuPass {
                addr: pass.addr,
                width: pass.width,
                height: pass.height,
                depth: pass.depth,
                ms,
                passes: per_frame(pass.passes.saturating_sub(before.passes) as f64),
                draws: per_frame(pass.draws.saturating_sub(before.draws) as f64),
            })
        })
        .filter(|pass| pass.ms > 0.0)
        .collect();
    passes.sort_by(|a, b| b.ms.total_cmp(&a.ms));
    passes.truncate(REPORTED_PASSES);
    let mut shaded = [0u64; 4];
    for (delta, (now, before)) in shaded.iter_mut().zip(current.shaded.iter().zip(baseline.shaded.iter())) {
        *delta = now.saturating_sub(*before);
    }
    // each draw-state class's share of the window's GPU time, the one that
    // cost most first: the classes are the buckets the timestamps at class
    // boundaries put the time in, so a frame's blended and opaque draws are
    // told apart, with the pixels their triangles estimate to cover
    let (class_ms, class_draws, class_pixels) = current.draw_classes_since(&baseline);
    let mut draw_classes: Vec<DrawClass> = (0..DRAW_CLASSES)
        .filter_map(|class| {
            let draws = class_draws[class];
            let pixels = class_pixels[class];
            (draws > 0 || pixels > 0).then(|| DrawClass {
                name: draw_class_name(class),
                ms: per_frame(class_ms[class]),
                draws: per_frame(draws as f64),
                pixels: per_frame(pixels as f64),
            })
        })
        .collect();
    draw_classes.sort_by(|a, b| b.ms.total_cmp(&a.ms));
    draw_classes.truncate(REPORTED_DRAW_CLASSES);
    // the sort's draws, the pass breaks, the kinds of work started and the
    // pass merge's draws are cumulative too, so take this window's share
    let sort = current.sort.since(&baseline.sort);
    let breaks = std::array::from_fn(|i| per_frame(current.breaks[i].saturating_sub(baseline.breaks[i]) as f64));
    let work_ops = std::array::from_fn(|i| per_frame(current.work_ops[i].saturating_sub(baseline.work_ops[i]) as f64));
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
        sort_draws: per_frame(sort.draws as f64),
        sort_candidates: per_frame(sort.candidates as f64),
        sort_runs: per_frame(sort.runs as f64),
        sort_reasons: std::array::from_fn(|i| per_frame(sort.reasons[i] as f64)),
        merged_draws: per_frame(current.merged_draws.saturating_sub(baseline.merged_draws) as f64),
        breaks,
        work_ops,
        captures_skipped: per_frame(current.captures_skipped.saturating_sub(baseline.captures_skipped) as f64),
        draw_classes,
        safe_skips: per_frame(current.safe_skips.saturating_sub(baseline.safe_skips) as f64),
        safe_skipped_pixels: per_frame(
            current.safe_skipped_pixels.saturating_sub(baseline.safe_skipped_pixels) as f64,
        ),
        passes_line: if current_line == baseline_line { String::new() } else { current_line.to_owned() },
        passes,
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
        if gpu.sort_candidates > 0.0 {
            line.push_str(&format!(" sorted {:.0}/f of {:.0}/f", gpu.sort_candidates, gpu.sort_draws));
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
    // the render targets the GPU's time went to, the one that cost most first,
    // so a profile tells its passes apart and a 2D/composite pass stands out
    for pass in &gpu.passes {
        line.push_str(&format!(
            " | target 0x{:08X} {}x{}{} {:.2}ms/f ({:.0} passes, {:.0} draws)",
            pass.addr,
            pass.width,
            pass.height,
            if pass.depth { "+d" } else { "" },
            pass.ms,
            pass.passes,
            pass.draws,
        ));
    }
    // the draws the front-to-back sort held and its reasons, so an A/B run
    // says whether it engaged and why not when it did not, see
    // `ZAKURO_SORT_OPAQUE`
    if gpu.sort_draws > 0.0 {
        let reasons: Vec<String> = SORT_REASONS
            .iter()
            .zip(gpu.sort_reasons)
            .filter(|&(_, count)| count > 0.0)
            .map(|(name, count)| format!("{name} {count:.0}/f"))
            .collect();
        line.push_str(&format!(
            " | sort {:.0}/f of {:.0}/f draws in {:.0}/f runs ({})",
            gpu.sort_candidates,
            gpu.sort_draws,
            gpu.sort_runs,
            reasons.join(", "),
        ));
    }
    if gpu.merged_draws > 0.0 {
        line.push_str(&format!(" | merged {:.0} draws/f", gpu.merged_draws));
    }
    if gpu.captures_skipped > 0.0 {
        line.push_str(&format!(" | captures_skipped {:.0}/f", gpu.captures_skipped));
    }
    // the draw-state classes the GPU's time went to, the one that cost most
    // first: each class's milliseconds, draws and estimated pixels per frame,
    // so an A/B run says which kind of draw the time is in
    if !gpu.draw_classes.is_empty() {
        let classes: Vec<String> = gpu
            .draw_classes
            .iter()
            .map(|class| {
                format!(
                    "{} {:.2}ms/f {:.0}/f {:.2}Mpx/f",
                    class.name,
                    class.ms,
                    class.draws,
                    class.pixels / 1e6
                )
            })
            .collect();
        line.push_str(&format!(" | draw_classes {}", classes.join(", ")));
    }
    if gpu.safe_skips > 0.0 {
        line.push_str(&format!(
            " | safe_skips {:.0}/f {:.2}Mpx/f",
            gpu.safe_skips,
            gpu.safe_skipped_pixels / 1e6
        ));
    }
    // the kinds of work the batches started, so an unexpected pass, copy or
    // readback is seen in the counts as well as in the time
    let ops: Vec<String> = GPU_WORK
        .iter()
        .zip(gpu.work_ops)
        .filter(|&(_, count)| count > 0.0)
        .map(|(name, count)| format!("{name} {count:.0}/f"))
        .collect();
    if !ops.is_empty() {
        line.push_str(&format!(" | ops {}", ops.join(", ")));
    }
    // what ended the window's passes
    let breaks: Vec<String> = BREAK_KINDS
        .iter()
        .zip(gpu.breaks)
        .filter(|&(_, count)| count > 0.0)
        .map(|(name, count)| format!("{name} {count:.0}/f"))
        .collect();
    if !breaks.is_empty() {
        line.push_str(&format!(" | pass_breaks {}", breaks.join(", ")));
    }
    // the per-pass report the renderer logs: the dominant target's passes in
    // recording order with each one's time, draws and what ended the pass
    // before it, so a run of passes into one buffer can be told apart
    if !gpu.passes_line.is_empty() {
        line.push_str(" | ");
        line.push_str(&gpu.passes_line);
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
        let mut milliseconds = [0.0; GPU_WORK.len()];
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
            sort: Default::default(),
            merged_draws: 0,
            breaks: [0; BREAK_KINDS.len()],
            work_ops: [0; GPU_WORK.len()],
            captures_skipped: 0,
            draw_class_ms: [0.0; DRAW_CLASSES],
            draw_class_draws: [0; DRAW_CLASSES],
            draw_class_pixels: [0; DRAW_CLASSES],
            safe_skips: 0,
            safe_skipped_pixels: 0,
        }
    }

    /// the draw-state classes in the GPU line are the window's, the one that
    /// cost most per frame first, and the safe skips are counted per frame too.
    #[test]
    fn draw_classes_and_safe_skips_average_the_window() {
        let mut baseline = gpu_times(100.0, 300, 20, 2_000);
        let mut current = gpu_times(400.0, 900, 80, 10_000);
        baseline.draw_class_ms[7] = 10.0;
        current.draw_class_ms[7] = 60.0;
        baseline.draw_class_draws[7] = 10;
        current.draw_class_draws[7] = 70;
        baseline.draw_class_pixels[7] = 1_000_000;
        current.draw_class_pixels[7] = 7_000_000;
        baseline.safe_skips = 1;
        current.safe_skips = 21;
        current.safe_skipped_pixels = 2_000_000;
        let gpu = gpu_breakdown(Some(baseline), Some(current), &[], &[], "", "", 10).expect("the GPU's times");
        assert_eq!(gpu.draw_classes.len(), 1);
        assert_eq!(gpu.draw_classes[0].name, draw_class_name(7));
        assert!((gpu.draw_classes[0].ms - 5.0).abs() < 1e-9, "ms {}", gpu.draw_classes[0].ms);
        assert!((gpu.draw_classes[0].draws - 6.0).abs() < 1e-9);
        assert!((gpu.draw_classes[0].pixels - 600_000.0).abs() < 1e-9);
        assert!((gpu.safe_skips - 2.0).abs() < 1e-9);
        assert!((gpu.safe_skipped_pixels - 200_000.0).abs() < 1e-9);
    }

    #[test]
    fn gpu_breakdown_averages_the_window() {
        let baseline = gpu_times(100.0, 300, 20, 2_000);
        let current = gpu_times(400.0, 900, 80, 10_000);
        let gpu = gpu_breakdown(Some(baseline), Some(current), &[], &[], "", "", 10).expect("the GPU's times");
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
        assert!(gpu_breakdown(None, Some(current), &[], &[], "", "", 10).is_none());
        assert!(gpu_breakdown(Some(baseline), None, &[], &[], "", "", 10).is_none());
        assert!(gpu_breakdown(Some(baseline), Some(baseline), &[], &[], "", "", 0).is_none());
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
                work_ms: [0.0, 20.0, 0.5, 0.2, 0.0, 0.3, 0.0, 0.0, 0.5, 0.2, 0.1],
                renderings: 12.0,
                barriers: 13.0,
                draws: 180.0,
                host_wait_ms: 0.4,
                host_waits: 6,
                shaded: [1_200_000.0, 600_000.0, 3_300_000.0, 0.0],
                statistics: true,
                sort_draws: 0.0,
                sort_candidates: 0.0,
                sort_runs: 0.0,
                sort_reasons: [0.0; SORT_REASONS.len()],
                merged_draws: 0.0,
                breaks: [0.0; BREAK_KINDS.len()],
                work_ops: [0.0; GPU_WORK.len()],
                captures_skipped: 0.0,
                draw_classes: vec![DrawClass {
                    name: "alphablend/alpha/tex2/c/cov-l".to_owned(),
                    ms: 12.0,
                    draws: 90.0,
                    pixels: 4_000_000.0,
                }],
                safe_skips: 3.0,
                safe_skipped_pixels: 500_000.0,
                passes_line: String::new(),
                passes: Vec::new(),
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
        for field in [
            "zk_gpu:",
            "gpu_exec 21.50ms/frame",
            "| draw 20.00ms/f",
            "passes 12/f",
            "3.30M fragments",
            "draw_classes alphablend/alpha/tex2/c/cov-l 12.00ms/f 90/f 4.00Mpx/f",
            "safe_skips 3/f 0.50Mpx/f",
        ] {
            assert!(gpu_line.contains(field), "missing {field}: {gpu_line}");
        }
        assert!(!gpu_line.contains("other 0.00"), "zero kinds are left out: {gpu_line}");
    }

    /// the render targets in the GPU line are the window's, the one that cost
    /// most per frame first, with a target that did no work left out.
    #[test]
    fn pass_attribution_averages_the_window_and_names_the_largest_target() {
        let baseline = gpu_times(100.0, 300, 20, 2_000);
        let current = gpu_times(400.0, 900, 80, 10_000);
        let pass = |addr: u32, width: u32, depth: bool, ms: f64, passes: u64, draws: u64| PassTimes {
            addr,
            width,
            height: 240,
            depth,
            milliseconds: ms,
            passes,
            draws,
        };
        let before = [
            pass(0x1800_0000, 400, true, 100.0, 10, 100),
            pass(0x1800_1000, 320, false, 900.0, 10, 200),
            pass(0x1800_2000, 64, true, 5.0, 5, 5),
        ];
        let now = [
            pass(0x1800_0000, 400, true, 400.0, 30, 700),
            pass(0x1800_1000, 320, false, 1500.0, 30, 300),
            // this target did nothing this window and is left out
            pass(0x1800_2000, 64, true, 5.0, 5, 5),
        ];
        let gpu = gpu_breakdown(Some(baseline), Some(current), &before, &now, "", "", 10).expect("the GPU's times");
        assert_eq!(gpu.passes.len(), 2, "{:?}", gpu.passes);
        assert_eq!(gpu.passes[0].addr, 0x1800_1000);
        assert!((gpu.passes[0].ms - 60.0).abs() < 1e-9, "{:?}", gpu.passes[0]);
        assert!((gpu.passes[0].passes - 2.0).abs() < 1e-9);
        assert!((gpu.passes[0].draws - 10.0).abs() < 1e-9);
        assert!((gpu.passes[1].ms - 30.0).abs() < 1e-9);
        // the same reading, as the diagnostics line reports it
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
            gpu: Some(gpu),
            hot_spots: Vec::new(),
        };
        let line = format_gpu_line(&summary);
        assert!(
            line.contains("| target 0x18001000 320x240 60.00ms/f (2 passes, 10 draws)"),
            "{line}"
        );
        assert!(line.contains("| target 0x18000000 400x240+d 30.00ms/f (2 passes, 60 draws)"), "{line}");
    }

    /// the round-3 lines: the sort's draws and reasons, the pass breaks, the
    /// pass merge's draws and the renderer's per-pass report travel in the
    /// `zk_gpu:` line the diagnostics export carries.
    #[test]
    fn sort_reasons_and_the_pass_report_travel_in_the_gpu_line() {
        let pass = |addr: u32, ms: f64, passes: u64, draws: u64| PassTimes {
            addr,
            width: 400,
            height: 240,
            depth: true,
            milliseconds: ms,
            passes,
            draws,
        };
        let mut baseline = gpu_times(100.0, 300, 20, 2_000);
        let mut current = gpu_times(400.0, 900, 80, 10_000);
        current.sort.draws = 120;
        current.sort.candidates = 80;
        current.sort.runs = 4;
        current.sort.reasons[11] = 80;
        current.sort.reasons[3] = 40;
        current.merged_draws = 60;
        current.breaks[2] = 8;
        current.captures_skipped = 3;
        current.work_ops[4] = 12;
        let line = "zk_passes: 0x18000000 400x240 20.0ms/f (1 passes, 1 draws), last 1: p0 20.00ms/1d +d after target";
        let gpu = gpu_breakdown(Some(baseline), Some(current), &[pass(0x1800_0000, 100.0, 10, 100)], &[pass(0x1800_0000, 300.0, 30, 700)], "", line, 2)
            .expect("the GPU's times");
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
            gpu: Some(gpu),
            hot_spots: Vec::new(),
        };
        let gpu_line = format_gpu_line(&summary);
        for field in [
            "| sort 40/f of 60/f draws in 2/f runs",
            "sorted 40/f",
            "no-depth 20/f",
            "| merged 30 draws/f",
            "| captures_skipped 2/f",
            "| pass_breaks target 4/f",
            "| ops transfer 6/f",
            line,
        ] {
            assert!(gpu_line.contains(field), "missing {field}: {gpu_line}");
        }
        let summary_line = format_summary(&summary);
        assert!(summary_line.contains("sorted 40/f of 60/f"), "{summary_line}");
    }
}
