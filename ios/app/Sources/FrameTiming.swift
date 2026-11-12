//
//  FrameTiming.swift
//  3ds2apple
//
//  I3-T6: per-phase frame timing for the performance HUD.
//
//  Threading: every `record` happens on the runtime serial queue, right around
//  the call it measures (zk_run_frame, zk_read_screen, CGImage creation, the
//  audio pump). Only an immutable FrameTimingSnapshot is hopped to the main
//  queue for display, so the HUD never touches the runtime handle or the
//  timing accumulators.
//
//  Clock: mach_absolute_time() — monotonic, never affected by wall-clock
//  changes, and cheaper than Date()/CACurrentMediaTime() in a per-frame path.
//  The timebase is converted to milliseconds once at display time, so the
//  measured path only copies UInt64 tick deltas.
//

import Darwin
import Foundation

/// Monotonic clock used by the frame timing HUD (`mach_absolute_time`).
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
}

/// One timing field shown in the HUD: `average`/`maximum`/`last` in
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
    /// set_input + run + screen reads + CGImages + audio pump.
    var renderTotal = FramePhaseStats()
    /// zk_run_frame() alone.
    var runFrame = FramePhaseStats()
    /// zk_read_screen() for the upper 400x240 screen.
    var topScreenRead = FramePhaseStats()
    /// zk_read_screen() for the lower 320x240 screen.
    var bottomScreenRead = FramePhaseStats()
    /// Both CGImage creations of the frame (provider + CGImage, no pixel copy).
    var cgImage = FramePhaseStats()
    /// zk_take_audio() + ring-buffer enqueue.
    var audioPump = FramePhaseStats()
}

/// The phases the HUD reports. Recorded once per executed frame on the
/// runtime serial queue.
enum FramePhase {
    case renderTotal
    case runFrame
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

    /// Builds the HUD values and clears the window:
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

/// Collects the six per-frame phase timings and turns them into one
/// `FrameTimingSnapshot` at the 0.5 s HUD refresh boundary.
///
/// `record`/`publish` run on the runtime serial queue only. `reset()` is called
/// from the main thread when a new frame loop starts, while that queue is idle
/// (the display link is added afterwards), so no recorded frame can race it.
struct FrameTimingWindow {
    private var renderTotal = PhaseTimingWindow()
    private var runFrame = PhaseTimingWindow()
    private var topScreenRead = PhaseTimingWindow()
    private var bottomScreenRead = PhaseTimingWindow()
    private var cgImage = PhaseTimingWindow()
    private var audioPump = PhaseTimingWindow()

    mutating func record(_ phase: FramePhase, ticks: UInt64) {
        switch phase {
        case .renderTotal: renderTotal.record(ticks)
        case .runFrame: runFrame.record(ticks)
        case .topScreenRead: topScreenRead.record(ticks)
        case .bottomScreenRead: bottomScreenRead.record(ticks)
        case .cgImage: cgImage.record(ticks)
        case .audioPump: audioPump.record(ticks)
        }
    }

    /// Snapshot for the HUD and start a new averaging window.
    mutating func publish() -> FrameTimingSnapshot {
        FrameTimingSnapshot(
            renderTotal: renderTotal.publish(),
            runFrame: runFrame.publish(),
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
