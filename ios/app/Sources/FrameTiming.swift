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
    /// zk_run_frame() alone.
    var runFrame = FramePhaseStats()
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
}

/// One presented frame that ran long enough to be seen as a hitch.
struct StutterEvent: Equatable {
    /// Milliseconds between the start of the frame loop and this frame.
    var atMilliseconds: Double = 0
    /// Frame-to-frame interval: how long this frame took before the next one
    /// started. This is the duration the player sees, and it includes a frame
    /// block that was scheduled late.
    var milliseconds: Double = 0
    /// Measured `renderFrame` work item: set_input + run + presentation + audio.
    /// `milliseconds - workMilliseconds` is time no phase accounted for
    /// (scheduling); such a frame is attributed to `other`.
    var workMilliseconds: Double = 0
    /// Phase with the largest measured share of this frame.
    var phase: StutterPhase = .other
    /// 1-based presented frame number since the loop started.
    var frame: UInt64 = 0
}

/// Phase a stutter frame is attributed to: the measured phase that took the
/// largest share of that frame. `other` covers time no phase accounted for
/// (for example waiting for a CAMetalLayer drawable in `zk_present`).
enum StutterPhase: Int, CaseIterable {
    case run
    case present
    case read
    case cgImage
    case audio
    case other

    /// Stable English label for the device log and the diagnostics report.
    var label: String {
        switch self {
        case .run: return "run"
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
    /// Stutter frames per attribution phase, indexed by `StutterPhase`.
    var phaseCounts: [Int] = [0, 0, 0, 0, 0, 0]
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
    private var stutterTicks: UInt64 = 0
    private var severeTicks: UInt64 = 0
    private var count = 0
    private var severeCount = 0
    private var worstTicks: UInt64 = 0
    private var phaseCounts: [Int] = []
    private var events: [StutterEvent] = []
    private var recordedEvents = 0

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
        stutterTicks = FrameClock.ticks(seconds: StutterSnapshot.thresholdMilliseconds / 1000.0)
        severeTicks = FrameClock.ticks(seconds: StutterSnapshot.severeThresholdMilliseconds / 1000.0)
        count = 0
        severeCount = 0
        worstTicks = 0
        recordedEvents = 0
        for index in phaseCounts.indices {
            phaseCounts[index] = 0
        }
    }

    /// Records one presented frame. runtimeQueue only.
    ///
    /// A hitch is detected on the frame-to-frame interval (what the player
    /// sees) and on the measured work item; the larger of the two is the
    /// reported duration. A frame whose interval is much longer than its work
    /// item is attributed to `other`: the phases cannot explain the wait (the
    /// frame block was scheduled late or the runtime queue was busy).
    mutating func record(frameStartTicks: UInt64,
                         workTicks: UInt64,
                         runTicks: UInt64,
                         presentTicks: UInt64,
                         readTicks: UInt64,
                         cgImageTicks: UInt64,
                         audioTicks: UInt64,
                         frame: UInt64) {
        let intervalTicks = frameStartTicks > lastFrameStartTicks
            ? frameStartTicks - lastFrameStartTicks
            : workTicks
        lastFrameStartTicks = frameStartTicks
        let durationTicks = max(intervalTicks, workTicks)
        guard durationTicks > stutterTicks else { return }
        count += 1
        if durationTicks > severeTicks { severeCount += 1 }
        if durationTicks > worstTicks { worstTicks = durationTicks }
        // Attribute the hitch to the largest share: the measured phase with the
        // most ticks, or the interval time the phases do not account for.
        var topPhase = StutterPhase.other
        var topTicks = intervalTicks > workTicks ? intervalTicks - workTicks : 0
        if runTicks > topTicks { topPhase = .run; topTicks = runTicks }
        if presentTicks > topTicks { topPhase = .present; topTicks = presentTicks }
        if readTicks > topTicks { topPhase = .read; topTicks = readTicks }
        if cgImageTicks > topTicks { topPhase = .cgImage; topTicks = cgImageTicks }
        if audioTicks > topTicks { topPhase = .audio; topTicks = audioTicks }
        phaseCounts[topPhase.rawValue] += 1
        events[recordedEvents % StutterTracker.maximumEvents] = StutterEvent(
            atMilliseconds: FrameClock.milliseconds(frameStartTicks - startedTicks),
            milliseconds: FrameClock.milliseconds(durationTicks),
            workMilliseconds: FrameClock.milliseconds(workTicks),
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
        snapshot.phaseCounts = phaseCounts
        let measuredSeconds = FrameClock.seconds(lastFrameStartTicks - startedTicks)
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

/// The phases recorded per frame. Recorded once per executed frame on the
/// runtime serial queue.
enum FramePhase {
    case renderTotal
    case runFrame
    case present
    case topScreenRead
    case bottomScreenRead
    case cgImage
    case audioPump
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
    private var present = PhaseTimingWindow()
    private var topScreenRead = PhaseTimingWindow()
    private var bottomScreenRead = PhaseTimingWindow()
    private var cgImage = PhaseTimingWindow()
    private var audioPump = PhaseTimingWindow()

    mutating func record(_ phase: FramePhase, ticks: UInt64) {
        switch phase {
        case .renderTotal: renderTotal.record(ticks)
        case .runFrame: runFrame.record(ticks)
        case .present: present.record(ticks)
        case .topScreenRead: topScreenRead.record(ticks)
        case .bottomScreenRead: bottomScreenRead.record(ticks)
        case .cgImage: cgImage.record(ticks)
        case .audioPump: audioPump.record(ticks)
        }
    }

    /// Snapshot for the frame stats and start a new averaging window.
    mutating func publish() -> FrameTimingSnapshot {
        FrameTimingSnapshot(
            renderTotal: renderTotal.publish(),
            runFrame: runFrame.publish(),
            present: present.publish(),
            topScreenRead: topScreenRead.publish(),
            bottomScreenRead: bottomScreenRead.publish(),
            cgImage: cgImage.publish(),
            audioPump: audioPump.publish()
        )
    }

    /// Forgets every sample. Called while the frame loop is stopped, so it
    /// cannot race a `record` on the runtime queue.
    mutating func reset() {
        self = FrameTimingWindow()
    }
}
