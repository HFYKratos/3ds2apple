//
//  ROMSession.swift
//  3ds2apple
//
//  I2-T1: ROM import + zk_create() wiring.
//  I2-T2: frame loop (zk_run_frame → zk_read_screen → CGImage) on the same
//         serial queue.
//  I3-T6: per-phase timing for the performance HUD and a reusable RGBA /
//         CGDataProvider buffer pool instead of per-frame allocations.
//
//  Threading contract (docs/integration.md, ios/zakuro-ios/README.md):
//  - every zk_* call that takes a handle runs on `runtimeQueue`, a single
//    serial queue;
//  - zk_create() runs off the main thread (it may take seconds);
//  - zk_last_error() is thread-local and only valid until the next
//    zk_create()/zk_last_error() call on the same thread, so a failure is
//    copied to a Swift String inside the same queue block;
//  - per-frame phase timings (mach_absolute_time deltas) are recorded on
//    runtimeQueue only; the main queue receives one immutable
//    `FrameTimingSnapshot` and only formats it in the HUD;
//  - CADisplayLink fires on the main thread and enqueues at most one frame at
//    a time: a semaphore drops ticks while the previous frame is still
//    running;
//  - @Published state is only mutated on the main queue.
//

import Combine
import CoreGraphics
import Foundation
import QuartzCore

/// A ROM stored in the app's Documents directory.
struct ImportedROM {
    /// Display name, e.g. "game.3ds".
    let name: String
    /// Path relative to the app's Documents directory, e.g. "roms/game.3ds".
    /// Persisted instead of an absolute path because the app container path
    /// changes between installs and updates.
    let relativePath: String
}

/// Rolling status of the frame loop, shown in the UI status line + perf HUD.
struct FrameStats {
    /// Frames per second over the last sampling window (0 when stopped).
    var fps: Double = 0
    /// Frames executed since the loop started.
    var frames: UInt64 = 0
    /// Last `zk_run_frame` result: 0 completed, 1 exited, -1 faulted,
    /// -2 bad handle (see ZK_FRAME_* in ios/ZakuroBridge.h).
    var lastResult: Int32 = 0
    /// Per-phase durations in milliseconds (I3-T6 performance HUD).
    var timing = FrameTimingSnapshot()
}

/// Whether this build carries linked 3dsrecomp code and whether the loaded
/// title is actually executing it (rather than falling back to the interpreter).
enum AOTStatus: String {
    case unknown = "?"
    case shell = "interpreter shell"
    case linkedInterpreting = "linked, interpreting"
    case linkedActive = "linked, active"

    var label: String { rawValue }
}

/// Owns the Zakuro runtime handle, the ROM import pipeline and the frame loop.
final class ROMSession: ObservableObject {
    enum Phase {
        /// Nothing imported or loaded yet.
        case idle
        /// Copying the picked file into Documents/roms.
        case importing(name: String)
        /// zk_create() is running on the runtime queue.
        case starting(name: String)
        /// zk_create() succeeded and a handle is alive.
        case loaded(name: String)
        /// Import or load failed; `message` is user-readable.
        case failed(message: String)
        /// The frame loop stopped after zk_run_frame reported a clean exit.
        case finished(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Most recent successfully loaded ROM (nil before the first success).
    @Published private(set) var lastROM: ImportedROM? = nil
    /// Latest upper screen frame (400x240), nil until the first frame arrives.
    @Published private(set) var topScreenImage: CGImage? = nil
    /// Latest lower screen frame (320x240), nil until the first frame arrives.
    @Published private(set) var bottomScreenImage: CGImage? = nil
    /// Frame-loop counters for the status line.
    @Published private(set) var frameStats = FrameStats()
    /// Human-readable name of the connected hardware controller, if any.
    @Published private(set) var controllerName: String? = nil
    /// Audio path state for the status line.
    @Published private(set) var audioState: AudioState = .off
    /// AOT/linked-code state for the status line.
    @Published private(set) var aotStatus: AOTStatus = .unknown

    /// Serial queue that owns every zk_* call.
    private let runtimeQueue = DispatchQueue(
        label: "com.kratos.3ds2apple.zakuro-runtime",
        qos: .userInitiated
    )
    /// Runtime handle; only read/written on `runtimeQueue` (except deinit).
    private var system: zk_system_t?
    private let fileManager = FileManager.default

    /// Merged on-screen + hardware-controller input, read once per frame.
    private let inputState = InputState()
    /// Hardware controller bridge; created by `startControllerSupport()`.
    private var controllerManager: GameControllerManager?

    /// Audio path: ring buffer + AVAudioEngine, started after a successful load.
    private let audioOutput = AudioOutput()
    /// Scratch buffer for zk_take_audio; runtimeQueue only. 16384 stereo frames.
    private var audioScratch = [Int16](repeating: 0, count: 16384 * 2)

    private static let lastROMPathKey = "I2.lastROMRelativePath"

    // MARK: Frame-loop state

    /// Lets at most one frame be in flight on `runtimeQueue`; ticks that arrive
    /// while a frame is still running are dropped instead of queued.
    private let frameGate = DispatchSemaphore(value: 1)
    /// Display link; created, added and invalidated on the main thread.
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: FrameLoopProxy?
    /// runtimeQueue only.
    private var framesRendered: UInt64 = 0
    private var framesSinceStats = 0
    /// FrameClock tick when the current 0.5 s stats window started.
    private var statsWindowStartTicks: UInt64 = 0
    /// Throttles the periodic `perf:` NSLog line (every 2 s).
    private var lastPerfLogTicks: UInt64 = 0
    private var didLogScreenReadFailure = false
    /// Per-phase frame timings; runtimeQueue only, published as snapshots.
    private var timingWindow = FrameTimingWindow()
    /// Reusable RGBA8 buffers for zk_read_screen + CGImage presentation.
    private let screenBufferPool = ScreenFrameBufferPool()

    init() {
        if let relativePath = UserDefaults.standard.string(forKey: Self.lastROMPathKey) {
            let name = URL(fileURLWithPath: relativePath).lastPathComponent
            lastROM = ImportedROM(name: name, relativePath: relativePath)
        }
    }

    deinit {
        controllerManager?.stop()
        audioOutput.stopEngine()
        // The display link lives on the main run loop; invalidate it there.
        // Capturing the link (not `self`) keeps this valid after deallocation.
        if let displayLink {
            DispatchQueue.main.async { displayLink.invalidate() }
        }
        // Every queue block captures `self` weakly, so once deinit runs no
        // other block can still be creating or using a handle. zk_destroy()
        // may be called from a different thread as long as no other thread uses
        // the pointer (ios/zakuro-ios/README.md: 线程规则).
        if let system {
            zk_destroy(system)
        }
    }

    // MARK: - Commands (main queue)

    /// Copies `url` picked in Files into `Documents/roms/` (reusing an existing
    /// import of the same name) and starts `zk_create`.
    func importROM(from url: URL) {
        let name = url.lastPathComponent
        guard Self.isSupportedROM(name) else {
            setPhase(.failed(message: "Unsupported file “\(name)”. Choose a decrypted .3ds or .cci ROM."))
            return
        }
        // Stop ticking/audio before the current runtime is replaced.
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        setPhase(.importing(name: name))
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            switch self.prepareROM(from: url) {
            case .success(let rom):
                self.startRuntime(for: rom)
            case .failure(let failure):
                self.publishFailure("Could not import “\(name)”: \(failure.message)")
            }
        }
    }

    /// Loads the last successfully imported ROM from Documents again.
    func loadLastROM() {
        guard let rom = lastROM else {
            setPhase(.failed(message: "No ROM has been imported yet. Tap “Import ROM…” first."))
            return
        }
        let url = documentsDirectory.appendingPathComponent(rom.relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            clearLastROM()
            setPhase(.failed(message: "“\(rom.name)” is no longer in this app's Documents folder. Import it again."))
            return
        }
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        setPhase(.starting(name: rom.name))
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.startRuntime(for: rom)
        }
    }

    /// Releases the runtime handle and returns to the "no ROM loaded" state.
    /// The imported file stays in Documents so it can be loaded again.
    func unload() {
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.destroySystem()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearScreens()
                self.setPhase(.idle)
            }
        }
    }

    /// Stops the frame loop and releases the runtime when the app moves to the
    /// background: iOS may jettison a backgrounded process at any time, so the
    /// handle must not outlive the active scene.
    func stopForBackground() {
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            let hadRuntime = self.system != nil
            self.destroySystem()
            guard hadRuntime else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearScreens()
                self.setPhase(.finished(
                    message: "The runtime was stopped when the app went to the background. Load the ROM again to continue."
                ))
            }
        }
    }

    /// Clears a failure/finished notice without touching a loaded runtime.
    func dismissNotice() {
        if case .failed = phase {
            setPhase(.idle)
        } else if case .finished = phase {
            setPhase(.idle)
        }
    }

    // MARK: - Input (main queue)

    /// Attaches the hardware-controller bridge. Safe to call repeatedly; only
    /// the first call starts it. The view calls this from `onAppear`.
    func startControllerSupport() {
        guard controllerManager == nil else { return }
        let manager = GameControllerManager(input: inputState) { [weak self] name in
            DispatchQueue.main.async {
                self?.controllerName = name
            }
        }
        controllerManager = manager
        manager.start()
    }

    /// On-screen button press/release.
    func setOverlayButton(_ bit: UInt32, pressed: Bool) {
        inputState.setOverlayButton(bit, pressed: pressed)
    }

    /// Clears on-screen buttons and the touchscreen contact (overlay hidden).
    func clearOverlayInput() {
        inputState.clearOverlay()
    }

    /// Touchscreen contact in lower-screen pixels; nil releases the touch.
    func setTouchPoint(x: UInt16?, y: UInt16?) {
        inputState.setTouch(x: x, y: y)
    }

    // MARK: - Runtime (runtimeQueue only)

    /// Releases the current handle. Must run on `runtimeQueue`.
    private func destroySystem() {
        guard let system else { return }
        zk_destroy(system)
        self.system = nil
        NSLog("[3ds2apple] zk_destroy: runtime released")
    }

    /// zk_create() for `rom`: destroy old handle, create new one, publish state
    /// and start the frame loop. Must run on `runtimeQueue`.
    private func startRuntime(for rom: ImportedROM) {
        let romURL = documentsDirectory.appendingPathComponent(rom.relativePath)
        let dataDirectory = documentsDirectory
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(Self.dataDirectoryName(for: rom.name), isDirectory: true)
        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            publishFailure("Could not create the save-data directory: \(error.localizedDescription)")
            return
        }

        // Replacing a ROM always releases the previous handle first.
        destroySystem()

        NSLog("[3ds2apple] zk_create: loading %@", romURL.path)
        let startedAt = Date()
        let handle = zk_create(romURL.path, dataDirectory.path)
        let elapsed = Date().timeIntervalSince(startedAt)

        guard let handle else {
            // zk_last_error() is thread-local: read and copy it here, in the
            // same block, before hopping to the main queue.
            let message = Self.currentRuntimeError()
            NSLog("[3ds2apple] zk_create failed after %.1f s: %@", elapsed, message)
            publishFailure(message)
            return
        }

        system = handle
        let linked = zk_linked_code() == 1
        let recompiled = zk_recompiled(handle) == 1
        let programID = zk_linked_program_id()
        let aot: AOTStatus = linked ? (recompiled ? .linkedActive : .linkedInterpreting) : .shell
        NSLog("[3ds2apple] AOT linked=%d recompiled=%d program=0x%016llx status=%@",
              linked ? 1 : 0, recompiled ? 1 : 0, programID, aot.label)
        NSLog("[3ds2apple] zk_create OK after %.1f s: %@", elapsed, rom.relativePath)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastROM = rom
            UserDefaults.standard.set(rom.relativePath, forKey: Self.lastROMPathKey)
            self.inputState.clearAll()
            self.clearScreens()
            self.aotStatus = aot
            self.setPhase(.loaded(name: rom.name))
            self.startFrameLoop()
            self.startAudio()
        }
    }

    /// Copies `zk_last_error()` into a Swift String. Must run on the thread
    /// that just saw `zk_create()` fail (the error slot is thread-local).
    private static func currentRuntimeError() -> String {
        guard let pointer = zk_last_error() else {
            return "The Zakuro runtime could not load this ROM (no error text was reported)."
        }
        let text = String(cString: pointer)
        return text.isEmpty ? "The Zakuro runtime could not load this ROM (empty error text)." : text
    }

    // MARK: - Frame loop (main thread drives, runtimeQueue executes)

    /// Starts CADisplayLink after a successful load. Main queue only.
    private func startFrameLoop() {
        stopFrameLoopOnMain()
        let proxy = FrameLoopProxy()
        proxy.session = self
        let link = CADisplayLink(target: proxy, selector: #selector(FrameLoopProxy.displayLinkFired(_:)))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
        framesRendered = 0
        framesSinceStats = 0
        statsWindowStartTicks = FrameClock.now()
        lastPerfLogTicks = statsWindowStartTicks
        didLogScreenReadFailure = false
        // Accumulators are runtimeQueue-owned, but the queue is idle here: the
        // display link that feeds it is added below, so no frame can race this.
        timingWindow.reset()
        frameStats = FrameStats()
        NSLog("[3ds2apple] frame loop started")
    }

    /// Invalidates the display link. Main queue only.
    private func stopFrameLoopOnMain() {
        guard displayLink != nil else { return }
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        NSLog("[3ds2apple] frame loop stopped")
    }

    /// Stops the loop from any thread; the display link lives on the main run
    /// loop, so the invalidation is hopped there.
    private func stopFrameLoop() {
        if Thread.isMainThread {
            stopFrameLoopOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.stopFrameLoopOnMain()
            }
        }
    }

    /// CADisplayLink callback (main thread). Schedules one frame, or drops the
    /// tick when the runtime queue is still busy with the previous frame.
    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        guard frameGate.wait(timeout: .now()) == .success else { return }
        let gate = frameGate
        runtimeQueue.async { [weak self] in
            self?.renderFrame()
            gate.signal()
        }
    }

    /// Executes one frame, times every phase and publishes screens + stats.
    /// runtimeQueue only.
    private func renderFrame() {
        guard let system else { return }
        let frameStart = FrameClock.now()

        // The only place that pushes input: same serial queue, immediately
        // before the frame that consumes it.
        let input = inputState.snapshot()
        zk_set_input(system, input.buttons, input.circleX, input.circleY,
                     input.touch ? 1 : 0, input.touchX, input.touchY)

        let runStart = FrameClock.now()
        let result = zk_run_frame(system)
        timingWindow.record(.runFrame, FrameClock.now() - runStart)
        framesRendered += 1

        switch result {
        case 0:
            // ZK_FRAME_COMPLETED: read both screens + build their CGImages.
            var cgImageTicks: UInt64 = 0
            let top = screenImage(system: system, which: 0, cgImageTicks: &cgImageTicks)
            let bottom = screenImage(system: system, which: 1, cgImageTicks: &cgImageTicks)
            timingWindow.record(.cgImage, cgImageTicks)

            // Drain audio after the frame and before publishing: both run on
            // this queue, so the timings belong to the same frame.
            let audioStart = FrameClock.now()
            pumpAudio(system: system)
            timingWindow.record(.audioPump, FrameClock.now() - audioStart)

            timingWindow.record(.renderTotal, FrameClock.now() - frameStart)
            publishFrame(top: top, bottom: bottom, result: result)
        case 1:
            timingWindow.record(.renderTotal, FrameClock.now() - frameStart)
            // ZK_FRAME_EXITED.
            finishRuntime(message: "The game requested exit (zk_run_frame = 1).", isError: false)
        case -1:
            timingWindow.record(.renderTotal, FrameClock.now() - frameStart)
            // ZK_FRAME_FAULTED.
            finishRuntime(message: "Runtime fault (zk_run_frame = -1).", isError: true)
        default:
            timingWindow.record(.renderTotal, FrameClock.now() - frameStart)
            // ZK_FRAME_BAD_HANDLE (-2).
            finishRuntime(message: "Invalid runtime handle (zk_run_frame = \(result)).", isError: true)
        }
    }

    /// Reads one screen through the reusable buffer pool, then builds its
    /// CGImage. The zk_read_screen() time is recorded as the top/bottom read
    /// phase; the CGImage time is added to `cgImageTicks` (both images).
    /// runtimeQueue only.
    private func screenImage(system: zk_system_t,
                             which: UInt32,
                             cgImageTicks: inout UInt64) -> CGImage? {
        let width = Int(zk_screen_width(which))
        let height = Int(zk_screen_height(which))
        guard width > 0, height > 0 else { return nil }
        let byteCount = width * height * 4
        let readPhase: FramePhase = which == 0 ? .topScreenRead : .bottomScreenRead

        guard let buffer = screenBufferPool.acquire(width: width, height: height) else {
            // Pool exhausted (the presentation layer still holds every buffer
            // it was handed): fall back to the old per-frame allocation.
            // Correct, only slower.
            return screenImageWithTransientData(
                system: system,
                which: which,
                width: width,
                height: height,
                byteCount: byteCount,
                readPhase: readPhase,
                cgImageTicks: &cgImageTicks
            )
        }

        let readStart = FrameClock.now()
        let written: Int = zk_read_screen(system, which, buffer.address, byteCount)
        timingWindow.record(readPhase, FrameClock.now() - readStart)

        guard written >= byteCount else {
            screenBufferPool.recycle(buffer)
            logScreenReadFailure(which: which, written: written, expected: byteCount)
            return nil
        }

        let imageStart = FrameClock.now()
        // On failure ScreenImage already recycled the buffer; do not recycle
        // it twice.
        let image = ScreenImage.makeImage(buffer: buffer, pool: screenBufferPool)
        cgImageTicks += FrameClock.now() - imageStart
        return image
    }

    /// Pool-exhaustion fallback: one `Data` allocation for this frame only.
    /// runtimeQueue only.
    private func screenImageWithTransientData(system: zk_system_t,
                                              which: UInt32,
                                              width: Int,
                                              height: Int,
                                              byteCount: Int,
                                              readPhase: FramePhase,
                                              cgImageTicks: inout UInt64) -> CGImage? {
        var pixels = Data(count: byteCount)
        let readStart = FrameClock.now()
        let written: Int = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return zk_read_screen(system, which, base, byteCount)
        }
        timingWindow.record(readPhase, FrameClock.now() - readStart)

        guard written >= byteCount else {
            logScreenReadFailure(which: which, written: written, expected: byteCount)
            return nil
        }
        let imageStart = FrameClock.now()
        let image = ScreenImage.makeImage(rgba: pixels, width: width, height: height)
        cgImageTicks += FrameClock.now() - imageStart
        return image
    }

    /// Logs a short screen read once per loop; that frame is skipped so the
    /// previous image stays on screen.
    private func logScreenReadFailure(which: UInt32, written: Int, expected: Int) {
        guard !didLogScreenReadFailure else { return }
        didLogScreenReadFailure = true
        NSLog("[3ds2apple] zk_read_screen(which=%u) returned %ld of %ld bytes",
              which, written, expected)
    }

    /// Publishes a rendered frame and (on a 0.5 s boundary) a full timing
    /// snapshot. runtimeQueue computes everything; the main queue only assigns
    /// immutable values. runtimeQueue only.
    private func publishFrame(top: CGImage?, bottom: CGImage?, result: Int32) {
        framesSinceStats += 1
        let now = FrameClock.now()
        let windowMilliseconds = FrameClock.milliseconds(now - statsWindowStartTicks)
        var stats: FrameStats?
        if windowMilliseconds >= 500 {
            let windowSeconds = windowMilliseconds / 1000
            let fps = windowSeconds > 0 ? Double(framesSinceStats) / windowSeconds : 0
            var snapshot = FrameStats(fps: fps, frames: framesRendered, lastResult: result)
            snapshot.timing = timingWindow.publish()
            stats = snapshot

            // One `perf:` line every ~2 s for idevicesyslog (the HUD itself
            // refreshes every 0.5 s).
            if FrameClock.milliseconds(now - lastPerfLogTicks) >= 2000 {
                lastPerfLogTicks = now
                logPerfLine(snapshot)
            }

            framesSinceStats = 0
            statsWindowStartTicks = now
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let top { self.topScreenImage = top }
            if let bottom { self.bottomScreenImage = bottom }
            if let stats { self.frameStats = stats }
        }
    }

    /// One compact log line for device logs: average and maximum per phase in
    /// milliseconds (total also carries the last frame). runtimeQueue only.
    private func logPerfLine(_ stats: FrameStats) {
        let timing = stats.timing
        let line = String(
            format: "perf: fps=%.1f frames=%llu | total=%.1f/%.1f/%.1f "
                + "run=%.1f/%.1f readTop=%.2f/%.2f readBottom=%.2f/%.2f "
                + "image=%.2f/%.2f audio=%.2f/%.2f ms (avg/max; total avg/max/last)",
            stats.fps,
            stats.frames,
            timing.renderTotal.average, timing.renderTotal.maximum, timing.renderTotal.last,
            timing.runFrame.average, timing.runFrame.maximum,
            timing.topScreenRead.average, timing.topScreenRead.maximum,
            timing.bottomScreenRead.average, timing.bottomScreenRead.maximum,
            timing.cgImage.average, timing.cgImage.maximum,
            timing.audioPump.average, timing.audioPump.maximum
        )
        NSLog("[3ds2apple] %@", line)
    }

    /// Handles zk_run_frame exit/fault: stops the loop, releases the handle and
    /// publishes a terminal state. runtimeQueue only.
    private func finishRuntime(message: String, isError: Bool) {
        NSLog("[3ds2apple] frame loop ending: %@", message)
        destroySystem()
        // Show the timings accumulated up to the last frame even when the loop
        // died before the next 0.5 s boundary.
        let finalTiming = timingWindow.publish()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopFrameLoopOnMain()
            self.stopAudio()
            self.inputState.clearAll()
            var stats = self.frameStats
            stats.fps = 0
            stats.lastResult = isError ? -1 : 1
            stats.timing = finalTiming
            self.frameStats = stats
            self.setPhase(isError ? .failed(message: message) : .finished(message: message))
        }
    }

    /// Clears the published screens. Main queue only.
    private func clearScreens() {
        topScreenImage = nil
        bottomScreenImage = nil
        frameStats = FrameStats()
    }

    // MARK: - Audio (main queue control, runtimeQueue feeding)

    /// Starts the audio engine after a successful load. Main queue only.
    private func startAudio() {
        guard !audioOutput.isMuted else {
            audioState = .muted
            return
        }
        guard audioOutput.startEngine() else {
            audioState = .failed("the audio engine could not start")
            return
        }
        audioState = .running
    }

    /// Stops the engine and drops buffered audio. Main queue only.
    private func stopAudio() {
        audioOutput.stopEngine()
        audioState = .off
    }

    /// Mute switch, persisted by the view via @AppStorage.
    func setAudioMuted(_ muted: Bool) {
        audioOutput.setMuted(muted)
        guard case .loaded = phase else { return }
        if muted {
            audioState = .muted
        } else {
            startAudio()
        }
    }

    /// Drains whatever audio the runtime produced this frame into the ring
    /// buffer. runtimeQueue only; never blocks the frame loop (the ring drops
    /// the oldest audio when full and the render block outputs silence when
    /// empty).
    private func pumpAudio(system: zk_system_t) {
        let capacity = audioScratch.count
        let frames: Int = audioScratch.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return zk_take_audio(system, base, capacity)
        }
        guard frames > 0 else { return }
        audioScratch.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            audioOutput.enqueue(base, frameCount: frames)
        }
    }

    // MARK: - ROM storage (runtimeQueue only)

    private struct ROMImportFailure: Error {
        let message: String
    }

    /// Copies the picked file into `Documents/roms/` and returns its relative
    /// path. An existing file with the same name is reused.
    private func prepareROM(from url: URL) -> Result<ImportedROM, ROMImportFailure> {
        let romsDirectory = documentsDirectory.appendingPathComponent("roms", isDirectory: true)
        do {
            try fileManager.createDirectory(at: romsDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(ROMImportFailure(
                message: "Could not create Documents/roms: \(error.localizedDescription)"
            ))
        }

        let name = url.lastPathComponent
        let destination = romsDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            NSLog("[3ds2apple] reusing imported ROM: %@", destination.path)
            return .success(ImportedROM(name: name, relativePath: relativePath(of: destination)))
        }

        // Files picked in Files/iCloud Drive are security-scoped.
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        // Copy through a temporary file so an interrupted import cannot leave a
        // truncated ROM behind under the final name.
        let temporary = romsDirectory.appendingPathComponent(".incoming-\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: url, to: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .failure(ROMImportFailure(
                message: "Could not read the selected file: \(error.localizedDescription)"
            ))
        }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            // A concurrent import of the same file may have won the race.
            if fileManager.fileExists(atPath: destination.path) {
                return .success(ImportedROM(name: name, relativePath: relativePath(of: destination)))
            }
            return .failure(ROMImportFailure(
                message: "Could not store the ROM in Documents: \(error.localizedDescription)"
            ))
        }

        NSLog("[3ds2apple] imported ROM: %@", destination.path)
        return .success(ImportedROM(name: name, relativePath: relativePath(of: destination)))
    }

    /// Path relative to the app's Documents directory (persisted across
    /// launches; absolute container paths are not stable).
    private func relativePath(of url: URL) -> String {
        let documentsPath = documentsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(documentsPath + "/") {
            return String(path.dropFirst(documentsPath.count + 1))
        }
        return url.lastPathComponent
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Per-ROM directory for saves/cache, passed as `data_dir` to zk_create.
    private static func dataDirectoryName(for romName: String) -> String {
        let stem = (romName as NSString).deletingPathExtension
        let sanitized = stem.map { character -> Character in
            if character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." {
                return character
            }
            return "_"
        }
        return sanitized.isEmpty ? "rom" : String(sanitized)
    }

    /// .3ds / .cci have no registered UTTypes on iOS, so the picker offers
    /// public.data and we validate the extension ourselves.
    private static func isSupportedROM(_ fileName: String) -> Bool {
        ["3ds", "cci"].contains((fileName as NSString).pathExtension.lowercased())
    }

    // MARK: - State (main queue)

    private func setPhase(_ phase: Phase) {
        if Thread.isMainThread {
            self.phase = phase
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.phase = phase
            }
        }
    }

    private func publishFailure(_ message: String) {
        NSLog("[3ds2apple] ROM load failed: %@", message)
        setPhase(.failed(message: message))
    }

    private func clearLastROM() {
        UserDefaults.standard.removeObject(forKey: Self.lastROMPathKey)
        lastROM = nil
    }
}

/// CADisplayLink retains its target. Going through this proxy keeps that
/// reference off `ROMSession`, so the session can deallocate (and release the
/// runtime) when SwiftUI tears the view down.
private final class FrameLoopProxy: NSObject {
    weak var session: ROMSession?

    @objc func displayLinkFired(_ link: CADisplayLink) {
        session?.displayLinkFired(link)
    }
}
