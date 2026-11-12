//
//  ROMSession.swift
//  3ds2apple
//
//  I2-T1: ROM import + zk_create() wiring.
//  I2-T2: frame loop (zk_run_frame → zk_read_screen → CGImage) on the same
//         serial queue.
//
//  Threading contract (docs/integration.md, ios/zakuro-ios/README.md):
//  - every zk_* call that takes a handle runs on `runtimeQueue`, a single
//    serial queue;
//  - zk_create() runs off the main thread (it may take seconds);
//  - zk_last_error() is thread-local and only valid until the next
//    zk_create()/zk_last_error() call on the same thread, so a failure is
//    copied to a Swift String inside the same queue block;
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

/// Rolling status of the frame loop, shown in the UI status line.
struct FrameStats {
    /// Frames per second over the last sampling window (0 when stopped).
    var fps: Double = 0
    /// Frames executed since the loop started.
    var frames: UInt64 = 0
    /// Last `zk_run_frame` result: 0 completed, 1 exited, -1 faulted,
    /// -2 bad handle (see ZK_FRAME_* in ios/ZakuroBridge.h).
    var lastResult: Int32 = 0
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
    private var lastStatsTime = Date()
    private var didLogScreenReadFailure = false

    init() {
        if let relativePath = UserDefaults.standard.string(forKey: Self.lastROMPathKey) {
            let name = URL(fileURLWithPath: relativePath).lastPathComponent
            lastROM = ImportedROM(name: name, relativePath: relativePath)
        }
    }

    deinit {
        controllerManager?.stop()
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
        // Stop ticking before the current runtime is replaced.
        stopFrameLoop()
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
        NSLog("[3ds2apple] zk_create OK after %.1f s: %@", elapsed, rom.relativePath)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastROM = rom
            UserDefaults.standard.set(rom.relativePath, forKey: Self.lastROMPathKey)
            self.inputState.clearAll()
            self.clearScreens()
            self.setPhase(.loaded(name: rom.name))
            self.startFrameLoop()
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
        lastStatsTime = Date()
        didLogScreenReadFailure = false
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

    /// Executes one frame and publishes its screens. runtimeQueue only.
    private func renderFrame() {
        guard let system else { return }

        // The only place that pushes input: same serial queue, immediately
        // before the frame that consumes it.
        let input = inputState.snapshot()
        zk_set_input(system, input.buttons, input.circleX, input.circleY,
                     input.touch ? 1 : 0, input.touchX, input.touchY)

        let result = zk_run_frame(system)
        framesRendered += 1

        switch result {
        case 0:
            // ZK_FRAME_COMPLETED: read both screens for this frame.
            let top = screenImage(system: system, which: 0)
            let bottom = screenImage(system: system, which: 1)
            publishFrame(top: top, bottom: bottom, result: result)
        case 1:
            // ZK_FRAME_EXITED.
            finishRuntime(message: "The game requested exit (zk_run_frame = 1).", isError: false)
        case -1:
            // ZK_FRAME_FAULTED.
            finishRuntime(message: "Runtime fault (zk_run_frame = -1).", isError: true)
        default:
            // ZK_FRAME_BAD_HANDLE (-2).
            finishRuntime(message: "Invalid runtime handle (zk_run_frame = \(result)).", isError: true)
        }
    }

    /// Reads one screen into a CGImage. runtimeQueue only.
    private func screenImage(system: zk_system_t, which: UInt32) -> CGImage? {
        let width = Int(zk_screen_width(which))
        let height = Int(zk_screen_height(which))
        guard width > 0, height > 0 else { return nil }
        let byteCount = width * height * 4

        var pixels = Data(count: byteCount)
        let written: Int = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return zk_read_screen(system, which, base, byteCount)
        }

        guard written >= byteCount else {
            if !didLogScreenReadFailure {
                didLogScreenReadFailure = true
                NSLog("[3ds2apple] zk_read_screen(which=%u) returned %ld of %ld bytes",
                      which, written, byteCount)
            }
            return nil
        }
        return ScreenImage.makeImage(rgba: pixels, width: width, height: height)
    }

    /// Publishes a rendered frame and (throttled) stats on the main queue.
    private func publishFrame(top: CGImage?, bottom: CGImage?, result: Int32) {
        framesSinceStats += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsTime)
        var stats: FrameStats?
        if elapsed >= 0.5 {
            let fps = elapsed > 0 ? Double(framesSinceStats) / elapsed : 0
            stats = FrameStats(fps: fps, frames: framesRendered, lastResult: result)
            framesSinceStats = 0
            lastStatsTime = now
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let top { self.topScreenImage = top }
            if let bottom { self.bottomScreenImage = bottom }
            if let stats { self.frameStats = stats }
        }
    }

    /// Handles zk_run_frame exit/fault: stops the loop, releases the handle and
    /// publishes a terminal state. runtimeQueue only.
    private func finishRuntime(message: String, isError: Bool) {
        NSLog("[3ds2apple] frame loop ending: %@", message)
        destroySystem()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopFrameLoopOnMain()
            self.inputState.clearAll()
            var stats = self.frameStats
            stats.fps = 0
            stats.lastResult = isError ? -1 : 1
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
