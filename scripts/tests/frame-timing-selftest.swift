//
//  frame-timing-selftest.swift
//  3ds2apple
//
//  Logic check for the pause/resume timing of FrameTiming.swift.
//
//  The app code needs the Apple SDK, so this compiles the production
//  ios/app/Sources/FrameTiming.swift plus this file on the macOS build VM:
//
//    swiftc -parse-as-library -O -o /tmp/frame-timing-selftest \
//        ios/app/Sources/FrameTiming.swift scripts/tests/frame-timing-selftest.swift
//    /tmp/frame-timing-selftest
//
//  scripts/tests/perf-selfcheck.sh runs it when swiftc is available (the macOS
//  VM) and skips the section on a plain Linux host. Exit status 0 = all passed.
//
//  What it pins down: a pause is not a frame. Paused wall time must not become a
//  stutter, must not move the worst-frame value, must not enter the start-to-start
//  baseline and must not be part of the per-minute rate; a genuine hitch must
//  still be counted.
//

import Darwin
import Foundation

@main
struct FrameTimingSelfTest {
    static func main() {
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            if condition {
                print("  ok   \(label)")
            } else {
                failures += 1
                print("  FAIL \(label)")
            }
        }

        // Mach ticks of one 60 Hz frame, and of a wall-clock second.
        let frameTicks = FrameClock.ticks(seconds: 1.0 / 60.0)
        let base: UInt64 = 1_000_000
        func frameStart(_ frames: Double) -> UInt64 {
            base + UInt64((frames * Double(frameTicks)).rounded())
        }
        func duration(_ seconds: Double) -> UInt64 {
            FrameClock.ticks(seconds: seconds)
        }
        let fiveSeconds = duration(5.0)

        // 1) Steady frame loop: nothing is a stutter.
        var steady = StutterTracker()
        steady.start(at: base)
        for index in 0..<120 {
            steady.record(
                frameStartTicks: frameStart(Double(index)),
                workTicks: duration(0.001),
                runTicks: duration(0.001),
                gpuTicks: 0,
                presentTicks: 0,
                readTicks: 0,
                cgImageTicks: 0,
                audioTicks: 0,
                frame: UInt64(index + 1)
            )
        }
        let steadySnapshot = steady.snapshot()
        expect(steadySnapshot.count == 0, "steady 60 Hz frames record no stutter")
        expect(steadySnapshot.worstMilliseconds == 0, "no worst frame without a stutter")

        // 2) Regression guard: a real hitch is still one stutter.
        var hitch = StutterTracker()
        hitch.start(at: base)
        hitch.record(
            frameStartTicks: frameStart(0), workTicks: duration(0.001),
            runTicks: duration(0.001), gpuTicks: 0, presentTicks: 0,
            readTicks: 0, cgImageTicks: 0, audioTicks: 0, frame: 1
        )
        hitch.record(
            frameStartTicks: frameStart(3), workTicks: duration(0.050),
            runTicks: duration(0.050), gpuTicks: 0, presentTicks: 0,
            readTicks: 0, cgImageTicks: 0, audioTicks: 0, frame: 2
        )
        expect(hitch.snapshot().count == 1, "a 50 ms frame is still one stutter")

        // 3) A five-second keyboard/menu pause must not become a stutter, must
        //    not move the worst frame and must not enter the per-minute rate.
        var paused = StutterTracker()
        paused.start(at: base)
        paused.record(
            frameStartTicks: frameStart(0), workTicks: duration(0.001),
            runTicks: duration(0.001), gpuTicks: 0, presentTicks: 0,
            readTicks: 0, cgImageTicks: 0, audioTicks: 0, frame: 1
        )
        paused.pause(at: frameStart(1))
        let resumeTicks = frameStart(1) + fiveSeconds
        paused.resume(at: resumeTicks)
        // First frame after the resume: a normal 60 Hz frame.
        paused.record(
            frameStartTicks: resumeTicks + frameTicks,
            workTicks: duration(0.001), runTicks: duration(0.001),
            gpuTicks: 0, presentTicks: 0, readTicks: 0, cgImageTicks: 0,
            audioTicks: 0, frame: 2
        )
        // Then one genuine 50 ms hitch, so the per-minute denominator is visible.
        paused.record(
            frameStartTicks: resumeTicks + UInt64(4) * frameTicks,
            workTicks: duration(0.050), runTicks: duration(0.050),
            gpuTicks: 0, presentTicks: 0, readTicks: 0, cgImageTicks: 0,
            audioTicks: 0, frame: 3
        )
        let pausedSnapshot = paused.snapshot()
        expect(pausedSnapshot.count == 1, "the 5 s pause is not a stutter (only the hitch is)")
        expect(pausedSnapshot.worstMilliseconds < 100, "the worst frame is the hitch, not the pause")
        expect(pausedSnapshot.perMinute > 300, "the per-minute rate excludes the paused time")

        // 4) A frame recorded while the loop is recorded as paused is ignored.
        var silent = StutterTracker()
        silent.start(at: base)
        silent.pause(at: frameStart(0))
        silent.record(
            frameStartTicks: frameStart(0) + fiveSeconds,
            workTicks: duration(0.500), runTicks: duration(0.500),
            gpuTicks: 0, presentTicks: 0, readTicks: 0, cgImageTicks: 0,
            audioTicks: 0, frame: 2
        )
        expect(silent.snapshot().count == 0, "a frame recorded inside a pause is ignored")

        // 5) The pause clock the session uses: one pause, one resume, one
        //    pending interval for the runtime queue, paused time in the totals.
        let clock = FramePauseClock()
        expect(!clock.isPaused, "the pause clock starts running")
        clock.pause(at: base)
        expect(clock.isPaused, "the pause clock reports the pause")
        expect(clock.resume(at: base + duration(2.0)), "resume ends the open pause")
        expect(!clock.isPaused, "the pause clock runs again after the resume")
        let pending = clock.takePendingResume()
        expect(pending != nil, "a resume leaves a pause for the runtime queue")
        if let pendingPause = pending {
            expect(pendingPause.startedTicks == base, "the pending pause keeps its start")
            expect(
                abs(FrameClock.seconds(pendingPause.pausedTicks) - 2.0) < 0.01,
                "the pending pause carries its duration"
            )
        }
        expect(clock.takePendingResume() == nil, "a pending pause is consumed exactly once")
        let clockStats = clock.snapshot()
        expect(clockStats.count == 1, "one pause recorded")
        expect(abs(clockStats.totalMilliseconds - 2000) < 10, "the paused time is in the totals")
        expect(abs(clockStats.lastMilliseconds - 2000) < 10, "the last pause is in the totals")

        // 6) A nested pause (menu + keyboard) is still one pause.
        let nested = FramePauseClock()
        nested.pause(at: base)
        nested.pause(at: base + duration(1.0))
        nested.resume(at: base + duration(3.0))
        let nestedPending = nested.takePendingResume()
        expect(
            nestedPending != nil
                && abs(FrameClock.seconds(nestedPending!.pausedTicks) - 3.0) < 0.01,
            "a nested pause keeps one start time"
        )
        expect(nested.snapshot().count == 1, "a nested pause is counted once")

        // 7) A fully restarted loop drops the pending pause but keeps the totals.
        let forgotten = FramePauseClock()
        forgotten.pause(at: base)
        forgotten.resume(at: base + duration(1.0))
        forgotten.pause(at: base + duration(2.0))
        forgotten.forgetPendingResume()
        expect(forgotten.takePendingResume() == nil, "a loop restart drops the pending pause")
        expect(!forgotten.isPaused, "a loop restart closes the open pause")
        expect(forgotten.snapshot().count == 1, "an already counted pause stays in the totals")

        // 8) A new session (load/unload/background) clears the totals.
        forgotten.resetSession()
        expect(forgotten.snapshot().count == 0, "a new session clears the pause count")
        expect(forgotten.snapshot().totalMilliseconds == 0, "a new session clears the paused time")

        if failures == 0 {
            print("frame-timing self-test: all checks passed")
            exit(0)
        }
        print("frame-timing self-test: \(failures) failure(s)")
        exit(1)
    }
}
