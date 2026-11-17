//
//  FrameTiming.swift
//  3ds2apple
//
//  I3-T6: per-phase frame timing for the diagnostics report and the
//  fast-forward automatic fallback.
//
//  Threading: every `record` happens on the runtime serial queue, right around
//  the call it measures (zk_run_frame, zk_present or zk_read_screen, CGImage
//  creation, the audio pump). Only an immutable FrameTimingSnapshot is hopped
//  to the main queue with the frame stats, so the UI never touches the runtime
//  handle or the timing accumulators.
//
//  0.1.2 splits `run` into the software GPU's command walk (`runGPU`, the `gpu`
//  column of `zk_perf`) and the emulated CPU/HLE rest (`runCPU`), records the
//  frame-to-frame interval, and fixes the stutter attribution: a long frame no
//  longer counts a second time as `other` on the frame after it (`other` is now
//  only the gap between the previous frame's end and this frame's start).
//
//  Clock: mach_absolute_time() — monotonic, never affected by wall-clock
//  changes, and cheaper than Date()/CACurrentMediaTime() in a per-frame path.
//  The timebase is converted to milliseconds once at display time, so the
//  measured path only copies UInt64 tick deltas.
//

import Darwin
import Foundation

/// Monotonic clock used by the frame timing and pacing code (`mach_absolute_time`).
enum FrameClock {
    /// mach timebase (constant for the lifetime of the process).
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        _ = mach_timebase_info(&info)
        if info.denom == 0 {
            // Defensive: a zero denominator would divide by zero below.
            info.numer = 1
            info.denom = 1
        }
        return info
    }()

    /// Current monotonic timestamp in mach ticks.
    @inline(__always)
    static func now() -> UInt64 {
        mach_absolute_time()
    }

    /// Converts a tick count to milliseconds.
    @inline(__always)
    static func milliseconds(_ ticks: UInt64) -> Double {
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000.0
    }

    /// Converts a tick count to seconds.
    @inline(__always)
    static func seconds(_ ticks: UInt64) -> Double {
        milliseconds(ticks) / 1_000.0
    }

    /// Converts a duration in seconds to a mach tick count. Used by the
    /// free-run frame loop to turn its 1/60 s period and the remaining time
    /// until the next deadline into ticks / a `DispatchTimeInterval`.
    @inline(__always)
    static func ticks(seconds: Double) -> UInt64 {
        let nanoseconds = seconds * 1_000_000_000.0
        guard nanoseconds > 0 else { return 0 }
        let ticks = nanoseconds * Double(timebase.denom) / Double(timebase.numer)
        if ticks >= Double(UInt64.max) { return UInt64.max }
        return UInt64(ticks.rounded())
    }
}

/// One timing field in a frame-timing snapshot: `average`/`maximum`/`last` in
/// milliseconds. `samples == 0` means the phase has not been measured yet.
struct FramePhaseStats: Equatable {
    /// Most recent single-frame duration.
    var last: Double = 0
    /// Mean over the last stats window (0.5 s).
    var average: Double = 0
    /// Worst single frame since the frame loop started.
    var maximum: Double = 0
    /// Frames measured in the window this snapshot was built from.
    var samples: Int = 0

    var isAvailable: Bool { samples > 0 }
}

/// Publishable timing for one frame, all in milliseconds.
struct FrameTimingSnapshot: Equatable {
    /// Entire renderFrame work item on the runtime queue up to publication:
    /// set_input + run + presentation + audio pump.
    var renderTotal = FramePhaseStats()
    /// zk_run_frame() alone (emulated CPU/HLE work plus the software GPU's
    /// command walk).
    var runFrame = FramePhaseStats()
    /// The software GPU's command-list walk inside `zk_run_frame` (`zk_perf`'s
    /// `gpu` column). A pipeline a scene first uses is created during the walk,
    /// so a spike here is the pipeline-compile / command-walk suspect.
    var runGPU = FramePhaseStats()
    /// `zk_run_frame` without the command walk: emulated CPU and HLE services
    /// (a CPU-bound scene grows this, not `runGPU`).
    var runCPU = FramePhaseStats()
    /// zk_present() (A1: swapchain present; 0 on the CGImage path).
    var present = FramePhaseStats()
    /// zk_read_screen() for the upper 400x240 screen (CGImage path only).
    var topScreenRead = FramePhaseStats()
    /// zk_read_screen() for the lower 320x240 screen (CGImage path only).
    var bottomScreenRead = FramePhaseStats()
    /// Both CGImage creations of the frame (CGImage path only).
    var cgImage = FramePhaseStats()
    /// zk_take_audio() + ring-buffer enqueue.
    var audioPump = FramePhaseStats()
    /// Frame start to frame start: what the player sees, including the pacing
    /// wait for the 60 Hz slot and any scheduling stall. Not summed into the
    /// work-share columns (it overlaps the previous frame's work).
    var frameInterval = FramePhaseStats()
}

/// One presented frame that ran long enough to be seen as a hitch.
struct StutterEvent: Equatable {
    /// Milliseconds between the start of the frame loop and this frame.
    var atMilliseconds: Double = 0
    /// Start-to-start interval: how long after the previous frame started this
    /// one began. Reported for context only; it contains the previous frame's
    /// work, so using it for the threshold would blame the frame after a long
    /// frame again (one hitch counted twice, once as `run`, once as `other`).
    var intervalMilliseconds: Double = 0
    /// How long the player was actually held up: the larger of this frame's
    /// measured work item and the unexplained gap between the previous frame's
    /// end and this frame's start. The stutter threshold counts this value, so
    /// one physical hitch produces one event.
    var milliseconds: Double = 0
    /// Measured `renderFrame` work item: set_input + run + presentation + audio.
    /// Its part above `gpuBusyMilliseconds` is emulated CPU/HLE work.
    var workMilliseconds: Double = 0
    /// The software GPU's command walk inside the work item (`gpu` column of
    /// `zk_perf`). New pipelines compile in the walk on first use.
    var gpuBusyMilliseconds: Double = 0
    /// Phase with the largest measured share of this frame.
    var phase: StutterPhase = .other
    /// 1-based presented frame number since the loop started.
    var frame: UInt64 = 0
}

/// Phase a stutter frame is attributed to: the measured phase that took the
/// largest share of that frame. `other` covers time no phase accounted for
/// (for example waiting for a CAMetalLayer drawable in `zk_present`).
enum StutterPhase: Int, CaseIterable {
    /// The software GPU's command-list walk inside `zk_run_frame`. The first
    /// use of new pipelines compiles in it and stalls the frame that waits for
    /// them, so a spike here is the pipeline-compile suspect.
    case runGPU
    /// Emulated CPU / HLE work inside `zk_run_frame`: a CPU-bound scene.
    case runCPU
    case present
    case read
    case cgImage
    case audio
    /// Time no measured phase explains: the gap between the previous frame's
    /// end and this frame's start (scheduling / pacing).
    case other

    /// Stable English label for the device log and the diagnostics report.
    var label: String {
        switch self {
        case .runGPU: return "run-gpu"
        case .runCPU: return "run-cpu"
        case .present: return "present"
        case .read: return "read"
        case .cgImage: return "cgImage"
        case .audio: return "audio"
        case .other: return "other"
        }
    }
}

/// Rolling stutter statistics carried by `FrameStats` into the UI and the
/// diagnostics report. Built from `StutterTracker.snapshot` at the 0.5 s stats
/// boundary, so the frame path itself only does a tick comparison.
struct StutterSnapshot: Equatable {
    /// A presented frame slower than this is a stutter (two 60 Hz slots).
    static let thresholdMilliseconds = 1000.0 / 30.0
    /// A presented frame slower than this is severe: a visible freeze.
    static let severeThresholdMilliseconds = 100.0

    /// Presented frames over the stutter threshold since the loop started.
    var count: Int = 0
    /// Of those, frames over the severe threshold.
    var severeCount: Int = 0
    /// `count` per minute of measured frame-loop time (pauses excluded).
    var perMinute: Double = 0
    /// Worst presented frame since the loop started, in milliseconds.
    var worstMilliseconds: Double = 0
    /// Frames whose software GPU command walk alone overran the 60 Hz budget:
    /// the scene is limited by the command walk, not by the guest CPU.
    var gpuWalkBoundFrames: Int = 0
    /// Severe stutters whose largest cost was the command walk: the first use
    /// of a pipeline compiled during that frame and the walk waited for it.
    /// Compare this count between a cold and a warm pipeline cache.
    var pipelineCompileSuspects: Int = 0
    /// Stutter frames per attribution phase, indexed by `StutterPhase`.
    var phaseCounts: [Int] = [Int](repeating: 0, count: StutterPhase.allCases.count)
    /// Most recent events, oldest first (at most `StutterTracker.maximumEvents`).
    var events: [StutterEvent] = []

    /// Stutter frames attributed to one phase.
    func count(for phase: StutterPhase) -> Int {
        let index = phase.rawValue
        return index < phaseCounts.count ? phaseCounts[index] : 0
    }

    /// Phase most stutter frames are attributed to; `.other` with no stutters.
    var topPhase: StutterPhase {
        var best = StutterPhase.other
        var bestCount = 0
        for phase in StutterPhase.allCases {
            let value = count(for: phase)
            if value > bestCount {
                best = phase
                bestCount = value
            }
        }
        return best
    }

    /// Share of the stutter frames attributed to one phase, 0...100.
    func share(for phase: StutterPhase) -> Double {
        guard count > 0 else { return 0 }
        return Double(count(for: phase)) / Double(count) * 100.0
    }
}

/// Collects the rolling stutter statistics of the presented frame loop.
///
/// `record` runs once per presented frame on the runtime serial queue: it
/// compares mach ticks and, only on a rare stutter, writes one preallocated
/// ring-buffer slot. No lock, no allocation on the frame path and no disk I/O.
/// `snapshot` runs at the existing 0.5 s stats boundary and is copied into
/// `FrameStats` for the UI and the diagnostics exporter.
struct StutterTracker {
    /// Recent events kept for the diagnostics report.
    static let maximumEvents = 20

    private var startedTicks: UInt64 = 0
    /// Tick the last presented frame started at; pauses between frames are not
    /// counted into the per-minute rate.
    private var lastFrameStartTicks: UInt64 = 0
    /// Work ticks of the previous frame, so the unexplained gap is measured
    /// from that frame's end and not from its start.
    private var lastWorkTicks: UInt64 = 0
    /// One 60 Hz frame budget in ticks, for the command-walk-bound counter.
    private var budgetTicks: UInt64 = 0
    /// Frames whose command walk overran `budgetTicks`, and severe stutters
    /// attributed to the command walk (pipeline-compile suspects).
    private var gpuWalkBoundFrames = 0
    private var pipelineCompileSuspects = 0
    private var stutterTicks: UInt64 = 0
    private var severeTicks: UInt64 = 0
    private var count = 0
    private var severeCount = 0
    private var worstTicks: UInt64 = 0
    private var phaseCounts: [Int] = []
    private var events: [StutterEvent] = []
    private var recordedEvents = 0
    /// FrameClock tick the current pause began at, nil while the loop runs.
    /// A pause is not frame-loop time: it must not become a stutter, a
    /// start-to-start interval or part of the per-minute rate.
    private var pauseStartTicks: UInt64?

    init() {
        phaseCounts = [Int](repeating: 0, count: StutterPhase.allCases.count)
        events = [StutterEvent](repeating: StutterEvent(), count: StutterTracker.maximumEvents)
        start(at: 0)
    }

    /// Starts a new measurement window (a new frame loop). The runtime queue is
    /// idle when this runs, so no recorded frame can race it.
    mutating func start(at ticks: UInt64) {
        startedTicks = ticks
        lastFrameStartTicks = ticks
        lastWorkTicks = 0
        budgetTicks = FrameClock.ticks(seconds: 1.0 / 60.0)
        stutterTicks = FrameClock.ticks(seconds: StutterSnapshot.thresholdMilliseconds / 1000.0)
        severeTicks = FrameClock.ticks(seconds: StutterSnapshot.severeThresholdMilliseconds / 1000.0)
        count = 0
        severeCount = 0
        worstTicks = 0
        gpuWalkBoundFrames = 0
        pipelineCompileSuspects = 0
        recordedEvents = 0
        for index in phaseCounts.indices {
            phaseCounts[index] = 0
        }
    }

    /// Marks the start of a pause. runtimeQueue only (the frame that applies it
    /// is the first one after the resume). A pause that is already open keeps
    /// its first start time, so a nested pause (menu + keyboard) stays one
    /// record. No frame is recorded while the pause is open.
    mutating func pause(at ticks: UInt64) {
        guard pauseStartTicks == nil else { return }
        pauseStartTicks = ticks
    }

    /// Ends a pause at `ticks`: the paused wall time is excluded from the
    /// per-minute denominator and from the start-to-start baselines, so the next
    /// recorded frame measures only the frame-loop time that actually ran.
    /// runtimeQueue only.
    mutating func resume(at ticks: UInt64) {
        guard let started = pauseStartTicks else { return }
        pauseStartTicks = nil
        let pausedTicks = ticks > started ? ticks - started : 0
        // Shift the measurement origin forward instead of subtracting at
        // snapshot time: `atMilliseconds` (t since loop start) and the
        // per-minute rate are then frame-loop time only. Rebase both
        // start-to-start baselines to the resume so the first frame after a
        // pause cannot report the paused gap as an interval or a stutter.
        startedTicks &+= pausedTicks
        lastFrameStartTicks = ticks
        lastWorkTicks = 0
    }

    /// True while a recorded pause is open.
    var isPaused: Bool { pauseStartTicks != nil }

    /// Records one presented frame. runtimeQueue only.
    ///
    /// A hitch is detected on the measured work item and on the gap between
    /// the previous frame's end and this frame's start (a frame block the
    /// scheduler ran late); the larger of the two is the reported duration.
    /// The start-to-start interval is not used for the threshold: it contains
    /// the previous frame's work, which used to count one long frame twice (as
    /// `run`, then as `other` on the following frame). The unexplained gap is
    /// what `other` reports, and it is measured from the previous frame's end.
    mutating func record(frameStartTicks: UInt64,
                         workTicks: UInt64,
                         runTicks: UInt64,
                         gpuTicks: UInt64,
                         presentTicks: UInt64,
                         readTicks: UInt64,
                         cgImageTicks: UInt64,
                         audioTicks: UInt64,
                         frame: UInt64) {
        // A frame must never be measured while the loop is recorded as paused;
        // the resumed frame rebases every baseline before it is recorded.
        guard pauseStartTicks == nil else { return }
        let intervalTicks = frameStartTicks > lastFrameStartTicks
            ? frameStartTicks - lastFrameStartTicks
            : workTicks
        let previousWorkTicks = lastWorkTicks
        lastFrameStartTicks = frameStartTicks
        lastWorkTicks = workTicks
        // Time between the previous frame's end and this frame's start: the
        // normal pacing wait for the 60 Hz slot, or a scheduling stall when it
        // is long. The part above the work item is what `other` reports.
        let gapTicks = intervalTicks > previousWorkTicks
            ? intervalTicks - previousWorkTicks
            : 0
        let durationTicks = max(workTicks, gapTicks)
        // Split the work item into the software GPU's command walk and the
        // emulated CPU/HLE rest (the same split `zk_perf` prints per window).
        let runGpuTicks = min(gpuTicks, runTicks)
        let runCpuTicks = runTicks - runGpuTicks
        if runGpuTicks > budgetTicks {
            gpuWalkBoundFrames += 1
        }
        guard durationTicks > stutterTicks else { return }
        count += 1
        if durationTicks > severeTicks { severeCount += 1 }
        if durationTicks > worstTicks { worstTicks = durationTicks }
        // Attribute the hitch to the largest share: command walk or emulated
        // CPU inside the work item, a presentation/read/audio phase, or the
        // scheduling gap no phase accounts for.
        var topPhase = StutterPhase.other
        var topTicks = gapTicks
        if runGpuTicks > topTicks { topPhase = .runGPU; topTicks = runGpuTicks }
        if runCpuTicks > topTicks { topPhase = .runCPU; topTicks = runCpuTicks }
        if presentTicks > topTicks { topPhase = .present; topTicks = presentTicks }
        if readTicks > topTicks { topPhase = .read; topTicks = readTicks }
        if cgImageTicks > topTicks { topPhase = .cgImage; topTicks = cgImageTicks }
        if audioTicks > topTicks { topPhase = .audio; topTicks = audioTicks }
        if topPhase == .runGPU, durationTicks > severeTicks {
            pipelineCompileSuspects += 1
        }
        phaseCounts[topPhase.rawValue] += 1
        events[recordedEvents % StutterTracker.maximumEvents] = StutterEvent(
            atMilliseconds: FrameClock.milliseconds(frameStartTicks - startedTicks),
            intervalMilliseconds: FrameClock.milliseconds(intervalTicks),
            milliseconds: FrameClock.milliseconds(durationTicks),
            workMilliseconds: FrameClock.milliseconds(workTicks),
            gpuBusyMilliseconds: FrameClock.milliseconds(runGpuTicks),
            phase: topPhase,
            frame: frame
        )
        recordedEvents += 1
    }

    /// Immutable summary for `FrameStats`; called on the 0.5 s stats boundary.
    func snapshot() -> StutterSnapshot {
        var snapshot = StutterSnapshot()
        snapshot.count = count
        snapshot.severeCount = severeCount
        snapshot.worstMilliseconds = FrameClock.milliseconds(worstTicks)
        snapshot.gpuWalkBoundFrames = gpuWalkBoundFrames
        snapshot.pipelineCompileSuspects = pipelineCompileSuspects
        snapshot.phaseCounts = phaseCounts
        // A pause that is still open ends the measured window at its start, so
        // the paused wall time is never part of the per-minute rate.
        let measuredEndTicks = pauseStartTicks ?? lastFrameStartTicks
        let measuredSeconds = measuredEndTicks > startedTicks
            ? FrameClock.seconds(measuredEndTicks - startedTicks)
            : 0
        snapshot.perMinute = measuredSeconds > 0 ? Double(count) / (measuredSeconds / 60.0) : 0
        let available = min(recordedEvents, StutterTracker.maximumEvents)
        let first = recordedEvents > StutterTracker.maximumEvents
            ? recordedEvents % StutterTracker.maximumEvents
            : 0
        var recent: [StutterEvent] = []
        recent.reserveCapacity(available)
        for offset in 0..<available {
            recent.append(events[(first + offset) % StutterTracker.maximumEvents])
        }
        snapshot.events = recent
        return snapshot
    }
}

/// One pause of the presented frame loop that the runtime queue has not
/// applied to its timing baselines yet.
struct FramePause: Equatable {
    /// FrameClock tick the pause began at.
    var startedTicks: UInt64 = 0
    /// Wall time spent paused, in mach ticks.
    var pausedTicks: UInt64 = 0
}

/// Completed pauses of the presented frame loop, for the diagnostics report.
struct FramePauseStats: Equatable {
    /// Pauses that ended with a resume.
    var count: Int = 0
    /// Total paused wall time, in milliseconds.
    var totalMilliseconds: Double = 0
    /// Duration of the most recent pause, in milliseconds.
    var lastMilliseconds: Double = 0
}

/// Records the wall-clock pauses of the presented frame loop.
///
/// A pause stops the loop for an arbitrary time (in-game menu, save-state
/// operation, software keyboard, scene transition). That wall time is not a
/// frame: it must never be counted as a start-to-start interval, a stutter, or
/// part of an FPS window. `pause`/`resume` are called from the main queue at the
/// session's pause control points; the first runtime-queue frame after a resume
/// consumes the recorded pause with `takePendingResume()` and rebases its timing
/// baselines (`ROMSession.applyPendingPauseResume`).
///
/// `forgetPendingResume()` is used when the loop is restarted from scratch: its
/// baselines are reset anyway, and a stale pending pause must not shift them.
/// Thread-safe (the lock is taken on pause/resume and once per frame).
final class FramePauseClock {
    private let lock = NSLock()
    /// Tick the open pause began at; nil while the loop runs.
    private var pausedAtTicks: UInt64?
    /// A pause the runtime queue has not consumed yet.
    private var pendingResume: FramePause?
    private var recordedCount = 0
    private var recordedTicks: UInt64 = 0
    private var lastRecordedTicks: UInt64 = 0

    /// True while a pause is open.
    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausedAtTicks != nil
    }

    /// Starts a pause. A pause that is already open keeps its first start time,
    /// so a request that arrives under an already paused loop stays one pause.
    func pause(at ticks: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard pausedAtTicks == nil else { return }
        pausedAtTicks = ticks
    }

    /// Ends the pause at `ticks` and hands the paused interval to the next
    /// frame. Returns false (and records nothing) when no pause was open.
    @discardableResult
    func resume(at ticks: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let started = pausedAtTicks else { return false }
        pausedAtTicks = nil
        let pausedTicks = ticks > started ? ticks - started : 0
        pendingResume = FramePause(startedTicks: started, pausedTicks: pausedTicks)
        recordedCount += 1
        recordedTicks &+= pausedTicks
        lastRecordedTicks = pausedTicks
        return true
    }

    /// The pause the runtime queue still has to apply, nil when the loop was not
    /// resumed since the last frame.
    func takePendingResume() -> FramePause? {
        lock.lock()
        defer { lock.unlock() }
        let pause = pendingResume
        pendingResume = nil
        return pause
    }

    /// Drops an open pause and its pending record without counting them: the
    /// frame loop was restarted and every timing baseline was reset.
    func forgetPendingResume() {
        lock.lock()
        defer { lock.unlock() }
        pausedAtTicks = nil
        pendingResume = nil
    }

    /// Pauses the session recorded, for the diagnostics header.
    func snapshot() -> FramePauseStats {
        lock.lock()
        defer { lock.unlock() }
        return FramePauseStats(
            count: recordedCount,
            totalMilliseconds: FrameClock.milliseconds(recordedTicks),
            lastMilliseconds: FrameClock.milliseconds(lastRecordedTicks)
        )
    }

    /// Forgets the session totals (a new load / unload / returned background).
    func resetSession() {
        lock.lock()
        defer { lock.unlock() }
        pausedAtTicks = nil
        pendingResume = nil
        recordedCount = 0
        recordedTicks = 0
        lastRecordedTicks = 0
    }
}

/// The phases recorded per frame. Recorded once per executed frame on the
/// runtime serial queue.
enum FramePhase {
    case renderTotal
    case runFrame
    case runGPU
    case runCPU
    case present
    case topScreenRead
    case bottomScreenRead
    case cgImage
    case audioPump
    /// Frame start to frame start: the pacing/scheduling baseline; recorded on
    /// the same per-frame path as the work-item phases.
    case frameInterval
}

/// Timing accumulator for one phase. runtimeQueue only (no locking needed).
struct PhaseTimingWindow {
    private var windowSamples = 0
    private var windowSumTicks: UInt64 = 0
    private var windowMaxTicks: UInt64 = 0
    private var sessionMaxTicks: UInt64 = 0
    private var lastTicks: UInt64 = 0
    private var lastPublished = FramePhaseStats()

    /// Adds one measured frame. `ticks` is a mach tick delta.
    mutating func record(_ ticks: UInt64) {
        windowSamples += 1
        windowSumTicks &+= ticks
        lastTicks = ticks
        if ticks > windowMaxTicks {
            windowMaxTicks = ticks
        }
    }

    /// Builds the published values and clears the window:
    /// - `average` = mean of the window that just ended,
    /// - `maximum` = worst frame since the last `reset()` (session max),
    /// - `last` = most recent frame, kept across empty windows (e.g. a
    ///   non-completed frame produces no screen-read samples).
    mutating func publish() -> FramePhaseStats {
        if windowMaxTicks > sessionMaxTicks {
            sessionMaxTicks = windowMaxTicks
        }
        if windowSamples > 0 {
            lastPublished = FramePhaseStats(
                last: FrameClock.milliseconds(lastTicks),
                average: FrameClock.milliseconds(windowSumTicks / UInt64(windowSamples)),
                maximum: FrameClock.milliseconds(sessionMaxTicks),
                samples: windowSamples
            )
        }
        windowSamples = 0
        windowSumTicks = 0
        windowMaxTicks = 0
        return lastPublished
    }

    /// Forgets every sample (used when a new frame loop starts).
    mutating func reset() {
        self = PhaseTimingWindow()
    }
}

/// Collects the per-frame phase timings and turns them into one
/// `FrameTimingSnapshot` at the 0.5 s stats refresh boundary.
///
/// `record`/`publish` run on the runtime serial queue only. `reset()` is called
/// from the main thread when a new frame loop starts, while that queue is idle
/// (the frame loop is scheduled afterwards), so no recorded frame can race it.
struct FrameTimingWindow {
    private var renderTotal = PhaseTimingWindow()
    private var runFrame = PhaseTimingWindow()
    private var runGPU = PhaseTimingWindow()
    private var runCPU = PhaseTimingWindow()
    private var present = PhaseTimingWindow()
    private var topScreenRead = PhaseTimingWindow()
    private var bottomScreenRead = PhaseTimingWindow()
    private var cgImage = PhaseTimingWindow()
    private var audioPump = PhaseTimingWindow()
    private var frameInterval = PhaseTimingWindow()

    mutating func record(_ phase: FramePhase, ticks: UInt64) {
        switch phase {
        case .renderTotal: renderTotal.record(ticks)
        case .runFrame: runFrame.record(ticks)
        case .runGPU: runGPU.record(ticks)
        case .runCPU: runCPU.record(ticks)
        case .present: present.record(ticks)
        case .topScreenRead: topScreenRead.record(ticks)
        case .bottomScreenRead: bottomScreenRead.record(ticks)
        case .cgImage: cgImage.record(ticks)
        case .audioPump: audioPump.record(ticks)
        case .frameInterval: frameInterval.record(ticks)
        }
    }

    /// Snapshot for the frame stats and start a new averaging window.
    mutating func publish() -> FrameTimingSnapshot {
        FrameTimingSnapshot(
            renderTotal: renderTotal.publish(),
            runFrame: runFrame.publish(),
            runGPU: runGPU.publish(),
            runCPU: runCPU.publish(),
            present: present.publish(),
            topScreenRead: topScreenRead.publish(),
            bottomScreenRead: bottomScreenRead.publish(),
            cgImage: cgImage.publish(),
            audioPump: audioPump.publish(),
            frameInterval: frameInterval.publish()
        )
    }

    /// Forgets every sample. Called while the frame loop is stopped, so it
    /// cannot race a `record` on the runtime queue.
    mutating func reset() {
        self = FrameTimingWindow()
    }
}
