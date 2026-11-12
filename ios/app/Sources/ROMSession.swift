//
//  ROMSession.swift
//  3ds2apple
//
//  I2-T1: ROM import + zk_create() wiring.
//  I2-T2: frame loop (zk_run_frame → zk_read_screen → CGImage) on the same
//         serial queue.
//  I3-T6: per-phase timing for the performance HUD and a reusable RGBA /
//         CGDataProvider buffer pool instead of per-frame allocations.
//  I3-T9: the frame loop is free-running on the runtime serial queue, capped at
//         the 3DS 60 Hz timeline, instead of being paced by CADisplayLink. The
//         display-link loop is kept behind the `frameLoopDriver` constant as a
//         one-line fallback.
//  A1:     the screens can be presented on a CAMetalLayer owned by the app
//          (`MetalScreenView`) instead of being read back into a CGImage. The
//          presenter and the Metal view are main-queue objects; `zk_present()`
//          runs on the runtime queue right after `zk_run_frame()`. When the
//          layer/presenter cannot be made the session falls back to the
//          `zk_read_screen` + CGImage path unchanged.
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
//  - free-run frames execute back-to-back on runtimeQueue (I3-T9): a frame
//    schedules exactly one successor (immediately when it overran its 1/60 s
//    slot, or with a delay up to that deadline when it finished early). The
//    serial queue guarantees no overlap and the generation guard makes a
//    queued frame a no-op once the loop is stopped;
//  - the CADisplayLink fallback fires on the main thread and enqueues at most
//    one frame at a time: a semaphore drops ticks while the previous frame is
//    still running;
//  - @Published state is only mutated on the main queue.
//

import Combine
import CoreGraphics
import Foundation
import QuartzCore
import UIKit

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

/// A1: how the frame loop reaches the display.
enum Presentation: Equatable {
    /// No CAMetalLayer: `zk_read_screen` into a `CGImage` (pre-A1 path).
    case readback
    /// CAMetalLayer: the renderer's GPU images go straight to the swapchain.
    case metalDirect
    /// CAMetalLayer: the renderer is software, so the presenter uploads pixels.
    case metalUploaded

    /// Whether the screens are shown through a CAMetalLayer at all.
    var usesMetalLayer: Bool { self != .readback }

    /// One line for the status area and the device log.
    var label: String {
        switch self {
        case .readback: return "CGImage readback"
        case .metalDirect: return "CAMetalLayer · GPU direct"
        case .metalUploaded: return "CAMetalLayer · uploaded"
        }
    }
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
    /// Active frame-loop driver (`free-run · cap 60 fps` or
    /// `CADisplayLink · 60 Hz`). Shown in the status line so a device
    /// screenshot records which loop is running (I3-T9).
    @Published private(set) var frameLoopLabel: String = "—"
    /// A1: the Metal view the presenter draws into, nil while the Metal path is
    /// off or unavailable. The session keeps it for the app's lifetime: the
    /// presenter's swapchain references its layer.
    @Published private(set) var metalScreenView: MetalScreenView?
    /// A1: how the loaded runtime reaches the display (status line + which
    /// screen surface the UI shows).
    @Published private(set) var displayPath: Presentation = .readback
    /// A1: drawable size of `metalScreenView` in pixels. Main queue only.
    private(set) var presentedDrawableSize = CGSize.zero
    /// A1: presenter handle (`zk_presenter_*`). Created and destroyed on the
    /// main queue; the value is handed to the runtime queue for `zk_present`.
    private var presenter: UnsafeMutableRawPointer?
    /// A1: presenter copy the frame loop presents through. runtimeQueue only.
    private var framePresenter: UnsafeMutableRawPointer?
    /// A1: set once the Metal view/presenter could not be made; later loads use
    /// the readback path instead of retrying the same failure every time.
    private var presenterUnavailable = false
    /// A1: consecutive `zk_present` failures. runtimeQueue only.
    private var presentFailures = 0

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

    /// Lets at most one frame be in flight on `runtimeQueue` in the
    /// CADisplayLink fallback mode; ticks that arrive while a frame is still
    /// running are dropped instead of queued.
    private let frameGate = DispatchSemaphore(value: 1)
    /// Display link; created, added and invalidated on the main thread. Only
    /// used when `frameLoopDriver == .displayLink` (I3-T9 fallback).
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: FrameLoopProxy?
    /// Generation-guarded on/off state of the free-run loop (I3-T9). Written by
    /// start/stop on the main thread, read by every queued frame on
    /// `runtimeQueue`, so a frame that was queued before a stop/Unload can
    /// never touch a destroyed handle.
    private let freeRunState = FreeRunLoopState()
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
        // Invalidate the free-run generation first: any frame that was already
        // scheduled on the runtime queue becomes a no-op instead of using the
        // handle destroyed below (I3-T9).
        freeRunState.stop()
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
        // A1: the presenter shares its Vulkan device with the renderer, so the
        // runtime went first above. `zk_presenter_destroy` touches UIKit
        // objects, so it runs on the main queue when this deinit does not.
        if let presenter {
            if Thread.isMainThread {
                zk_presenter_destroy(presenter)
            } else {
                DispatchQueue.main.async { zk_presenter_destroy(presenter) }
            }
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
                self.beginLoad(rom)
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
            self.beginLoad(rom)
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

    // MARK: - A1 presentation (main queue creates, runtimeQueue presents)

    /// Whether the app tries the CAMetalLayer presentation path. Set this to
    /// `false` for an on-device A/B against the pre-A1 `CGImage` path; the
    /// fallback is automatic when a presenter cannot be made (no MoltenVK in
    /// the app's Frameworks, a GPU that cannot make a Vulkan device, ...).
    private static let preferMetalPresentation = true

    /// Consecutive `zk_present()` failures after which the frame loop falls
    /// back to the CGImage readback path (≈ a second at 30-60 fps).
    private static let presentFailureLimit = 30

    /// A presented load is started from `runtimeQueue`; the Metal view and its
    /// presenter are main-queue objects, so this hops over, creates them if
    /// needed, and starts the load back on the runtime queue. runtimeQueue only
    /// (the calls themselves follow the queue rules above).
    private func beginLoad(_ rom: ImportedROM) {
        // Show "Starting Zakuro…" (and the Metal view, once it exists) while
        // the ROM loads; `importROM` was still showing the copy phase.
        setPhase(.starting(name: rom.name))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let presenter = self.presenterForLoadOnMain()
            let drawableSize = self.presentedDrawableSize
            self.runtimeQueue.async { [weak self] in
                self?.startRuntime(for: rom, presenter: presenter, drawableSize: drawableSize)
            }
        }
    }

    /// Creates the `MetalScreenView` and its presenter the first time a load
    /// asks for them and reuses them afterwards (the layer outlives a single
    /// ROM). Main queue only.
    ///
    /// Returns `nil` when the Metal path is off or unavailable; the caller then
    /// uses `zk_create` + `zk_read_screen`. A failure is remembered, so later
    /// loads do not retry the same missing/unsupported setup.
    private func presenterForLoadOnMain() -> UnsafeMutableRawPointer? {
        guard Self.preferMetalPresentation else { return nil }
        if let presenter { return presenter }
        if presenterUnavailable { return nil }

        let view: MetalScreenView
        if let existing = metalScreenView {
            view = existing
        } else {
            let created = MetalScreenView(frame: .zero)
            created.onDrawableSizeChanged = { [weak self] size in
                self?.presentedDrawableSizeChanged(size)
            }
            created.prepareForPresentation(provisionalSize: Self.provisionalPresentedPixelSize())
            metalScreenView = created
            view = created
        }

        let size = view.drawablePixelSize
        let width = UInt32(max(1, size.width.rounded()))
        let height = UInt32(max(1, size.height.rounded()))
        if let handle = zk_presenter_create(Unmanaged.passUnretained(view).toOpaque(),
                                            width, height) {
            presenter = handle
            presentedDrawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
            NSLog("[3ds2apple] zk_presenter_create: CAMetalLayer %ux%u · shared device: %@",
                  width, height, zk_presenter_shared_device(handle) == 1 ? "yes" : "no")
            return handle
        }
        // Read the thread-local error here, before anything else can replace it.
        let message = Self.currentRuntimeError()
        NSLog("[3ds2apple] zk_presenter_create failed; using the CGImage readback path: %@",
              message)
        presenterUnavailable = true
        metalScreenView = nil
        return nil
    }

    /// The Metal view was laid out again (rotation, split view, a new screen):
    /// the runtime queue resizes the swapchain and the next `zk_present()`
    /// rebuilds it. Main queue only.
    private func presentedDrawableSizeChanged(_ size: CGSize) {
        presentedDrawableSize = size
        guard let presenter else { return }
        let width = UInt32(max(1, size.width.rounded()))
        let height = UInt32(max(1, size.height.rounded()))
        runtimeQueue.async { [weak self] in
            guard let self, self.framePresenter != nil else { return }
            _ = zk_presenter_resize(presenter, width, height)
        }
    }

    /// Size, in pixels, for the Metal view before SwiftUI lays it out. The real
    /// layout pass replaces it (and resizes the swapchain).
    private static func provisionalPresentedPixelSize() -> CGSize {
        let scale = max(UITraitCollection.current.displayScale, 1)
        var points: CGFloat = 390
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            points = max(scene.screen.bounds.width, 1)
        }
        let width = (points * scale).rounded()
        return CGSize(width: width, height: (width * 1.2).rounded())
    }

    /// A1: drag/tap on the presented layer, normalised to the view's 0...1
    /// space. Only the part of the layer that holds the lower screen is a touch
    /// surface; the runtime maps the point with `zk_present_touch_map()`.
    /// Main queue only.
    func setPresentedTouch(normalisedX: CGFloat, normalisedY: CGFloat) {
        guard displayPath.usesMetalLayer else {
            setTouchPoint(x: nil, y: nil)
            return
        }
        let size = presentedDrawableSize
        guard size.width >= 1, size.height >= 1 else { return }
        var x: UInt16 = 0
        var y: UInt16 = 0
        let onLowerScreen = zk_present_touch_map(
            UInt32(size.width.rounded()),
            UInt32(size.height.rounded()),
            Float(min(max(normalisedX, 0), 1)),
            Float(min(max(normalisedY, 0), 1)),
            &x,
            &y
        )
        if onLowerScreen != 0 {
            setTouchPoint(x: x, y: y)
        } else {
            setTouchPoint(x: nil, y: nil)
        }
    }

    // MARK: - Runtime (runtimeQueue only)

    /// Releases the current handle. Must run on `runtimeQueue`.
    private func destroySystem() {
        if let presenter = framePresenter {
            // The presenter's device and the screens it showed belong to this
            // runtime: stop presenting before the system goes away.
            framePresenter = nil
            NSLog("[3ds2apple] CAMetalLayer presentation detached (shared device: %@)",
                  zk_presenter_shared_device(presenter) == 1 ? "yes" : "no")
        }
        guard let system else { return }
        zk_destroy(system)
        self.system = nil
        presentFailures = 0
        NSLog("[3ds2apple] zk_destroy: runtime released")
    }

    /// zk_create() for `rom`: destroy old handle, create new one, publish state
    /// and start the frame loop. Must run on `runtimeQueue`.
    ///
    /// A1: with a non-nil `presenter` the ROM loads through
    /// `zk_create_presented`, so its screens are shown on the app's
    /// CAMetalLayer. A presented load that fails is retried once with the plain
    /// `zk_create` readback path, so a presenter problem cannot make a ROM
    /// unplayable.
    private func startRuntime(for rom: ImportedROM,
                              presenter: UnsafeMutableRawPointer?,
                              drawableSize: CGSize) {
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

        NSLog("[3ds2apple] zk_create: loading %@ (CAMetalLayer: %@)",
              romURL.path, presenter == nil ? "no" : "yes")
        let startedAt = Date()
        var usedPresenter = presenter
        var handle: zk_system_t?
        if let presenter {
            handle = zk_create_presented(romURL.path, dataDirectory.path, presenter)
            if handle == nil {
                // Copy the thread-local error before anything else can replace
                // it, then fall back to the pre-A1 load path.
                let presentedError = Self.currentRuntimeError()
                NSLog("[3ds2apple] zk_create_presented failed; retrying with zk_create: %@",
                      presentedError)
                usedPresenter = nil
                handle = zk_create(romURL.path, dataDirectory.path)
            }
        } else {
            handle = zk_create(romURL.path, dataDirectory.path)
        }
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
        framePresenter = usedPresenter
        if presenter != nil, usedPresenter == nil {
            // The presented load failed but the plain one worked, so the
            // presenter/device path is what broke: do not retry it on every
            // later load. The Metal view and presenter stay alive but unused.
            DispatchQueue.main.async { [weak self] in
                self?.presenterUnavailable = true
            }
        }
        if let usedPresenter {
            let width = UInt32(max(1, drawableSize.width.rounded()))
            let height = UInt32(max(1, drawableSize.height.rounded()))
            _ = zk_presenter_resize(usedPresenter, width, height)
        }
        let mode = zk_present_mode(handle, usedPresenter)
        let displayPath: Presentation
        switch mode {
        case 1: displayPath = .metalDirect
        case 2: displayPath = .metalUploaded
        default: displayPath = .readback
        }
        let linked = zk_linked_code() == 1
        let recompiled = zk_recompiled(handle) == 1
        let programID = zk_linked_program_id()
        let aot: AOTStatus = linked ? (recompiled ? .linkedActive : .linkedInterpreting) : .shell
        NSLog("[3ds2apple] AOT linked=%d recompiled=%d program=0x%016llx status=%@",
              linked ? 1 : 0, recompiled ? 1 : 0, programID, aot.label)
        NSLog("[3ds2apple] display: %@", displayPath.label)
        NSLog("[3ds2apple] hardware: %@", Self.hardwareStatusText(handle))
        NSLog("[3ds2apple] zk_create OK after %.1f s: %@", elapsed, rom.relativePath)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastROM = rom
            UserDefaults.standard.set(rom.relativePath, forKey: Self.lastROMPathKey)
            self.inputState.clearAll()
            self.clearScreens()
            self.aotStatus = aot
            self.displayPath = displayPath
            self.setPhase(.loaded(name: rom.name))
            self.startFrameLoop()
            self.startAudio()
        }
    }

    /// Copies `zk_hardware_status()` into a Swift String. The pointer is
    /// library-owned and only valid until the next status call on this thread.
    private static func hardwareStatusText(_ handle: zk_system_t) -> String {
        guard let pointer = zk_hardware_status(handle) else { return "no status" }
        let text = String(cString: pointer)
        return text.isEmpty ? "no status" : text
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

    // MARK: - Frame loop (main thread starts/stops, runtimeQueue executes)

    /// How `renderFrame()` is scheduled. I3-T9 defaults to `freeRun`; see the
    /// README ("Frame loop (I3-T9)") for why and how to revert.
    enum FrameLoopDriver {
        /// Frames execute back-to-back on the runtime serial queue and are
        /// only capped at the 3DS 60 Hz timeline (I3-T9).
        case freeRun
        /// Pre-I3-T9 loop: a CADisplayLink on the main thread enqueues at most
        /// one frame per refresh and drops ticks while a frame is still busy.
        case displayLink
    }

    /// **Fallback switch**: change this to `.displayLink` to restore the
    /// pre-I3-T9 CADisplayLink-paced loop. No other code change is needed.
    private static let frameLoopDriver: FrameLoopDriver = .freeRun

    /// Free-run cap: frames never start closer together than the 3DS 60 Hz
    /// timeline. This is a *cap*, not a target — a frame that takes longer than
    /// 1/60 s (e.g. the measured 22.6 ms Pokémon Y AOT frame) starts the next
    /// frame immediately instead of waiting for a display tick, so the loop
    /// runs at the real throughput (~44 fps) instead of a 30 fps multiple.
    private static let freeRunFramesPerSecond = 60

    /// CADisplayLink fallback rate. 60 reproduces the pre-I3-T9 behaviour; 120
    /// is the I3-T9 experiment (`preferredFramesPerSecond = 120`). 120 only
    /// helps once a frame is faster than 8.3 ms — at 22.6 ms a frame still
    /// spans several ticks, so the fallback would stay at ~30 fps.
    private static let displayLinkFramesPerSecond = 60

    /// One free-run slot in mach ticks (1/60 s).
    private static let freeRunPeriodTicks: UInt64 =
        FrameClock.ticks(seconds: 1.0 / Double(freeRunFramesPerSecond))

    /// Starts the configured frame-loop driver after a successful load.
    /// Main queue only.
    private func startFrameLoop() {
        stopFrameLoopOnMain()
        framesRendered = 0
        framesSinceStats = 0
        statsWindowStartTicks = FrameClock.now()
        lastPerfLogTicks = statsWindowStartTicks
        didLogScreenReadFailure = false
        // Accumulators are runtimeQueue-owned, but the queue is idle here: no
        // frame loop is running yet, so no frame can race this.
        timingWindow.reset()
        frameStats = FrameStats()

        switch Self.frameLoopDriver {
        case .freeRun:
            let generation = freeRunState.start()
            frameLoopLabel = "free-run · cap \(Self.freeRunFramesPerSecond) fps"
            // First frame right away; every later frame is scheduled by the
            // runtime queue after the previous one, so at most one frame is in
            // flight and at most one continuation is queued.
            scheduleFreeRunFrame(after: 0, generation: generation)
            NSLog("[3ds2apple] frame loop started (free-run, cap %d fps)",
                  Self.freeRunFramesPerSecond)
        case .displayLink:
            startDisplayLinkOnMain()
            frameLoopLabel = "CADisplayLink · \(Self.displayLinkFramesPerSecond) Hz"
            NSLog("[3ds2apple] frame loop started (CADisplayLink at %d fps)",
                  Self.displayLinkFramesPerSecond)
        }
    }

    /// Schedules exactly one free-run frame on the runtime queue. `delay` is 0
    /// when the previous frame overran its slot (continue immediately) and
    /// positive when it finished early (wait for the 60 Hz deadline). Called
    /// from the main queue for the first frame and from the runtime queue
    /// afterwards; it never blocks and never queues more than one frame.
    private func scheduleFreeRunFrame(after delay: TimeInterval, generation: UInt64) {
        // Cheap early check; the queued block re-checks because the loop can be
        // stopped between scheduling and execution.
        guard freeRunState.isCurrent(generation) else { return }
        if delay > 0 {
            runtimeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runFreeRunFrame(generation: generation)
            }
        } else {
            runtimeQueue.async { [weak self] in
                self?.runFreeRunFrame(generation: generation)
            }
        }
    }

    /// Executes one free-run frame and schedules its successor. runtimeQueue
    /// only. This is the I3-T9 core: the next frame starts as soon as this one
    /// finished (or at its 60 Hz deadline when it finished early), so the loop
    /// throughput is the real frame cost instead of a display-refresh multiple.
    private func runFreeRunFrame(generation: UInt64) {
        // A frame queued before a stop / Unload / destroy must do nothing.
        guard freeRunState.isCurrent(generation), system != nil else { return }

        let frameStart = FrameClock.now()
        let shouldContinue = renderFrame()
        // renderFrame() already stopped and destroyed the runtime on
        // exit/fault, so there is nothing left to schedule.
        guard shouldContinue,
              freeRunState.isCurrent(generation),
              system != nil else { return }

        // 60 Hz cap: only the early part of the slot is waited out. A frame
        // that overran its slot continues immediately (delay 0), which is what
        // removes the CADisplayLink quantization.
        let now = FrameClock.now()
        let deadline = frameStart &+ Self.freeRunPeriodTicks
        let delay = deadline > now ? FrameClock.seconds(deadline - now) : 0
        scheduleFreeRunFrame(after: delay, generation: generation)
    }

    /// Creates and adds the CADisplayLink fallback driver. Main queue only.
    private func startDisplayLinkOnMain() {
        let proxy = FrameLoopProxy()
        proxy.session = self
        let link = CADisplayLink(target: proxy, selector: #selector(FrameLoopProxy.displayLinkFired(_:)))
        link.preferredFramesPerSecond = Self.displayLinkFramesPerSecond
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
    }

    /// Stops whichever driver is running: invalidates the free-run generation
    /// (queued frames become no-ops) and invalidates the display link.
    /// Main queue only.
    private func stopFrameLoopOnMain() {
        let wasRunning = freeRunState.stop() || displayLink != nil
        if let link = displayLink {
            link.invalidate()
            displayLink = nil
            displayLinkProxy = nil
        }
        if wasRunning {
            NSLog("[3ds2apple] frame loop stopped")
        }
    }

    /// Stops the loop from any thread. The free-run generation is invalidated
    /// synchronously so no new frame can start; the display link lives on the
    /// main run loop, so its invalidation is hopped there.
    private func stopFrameLoop() {
        if Thread.isMainThread {
            stopFrameLoopOnMain()
        } else {
            freeRunState.stop()
            DispatchQueue.main.async { [weak self] in
                self?.stopFrameLoopOnMain()
            }
        }
    }

    /// CADisplayLink fallback callback (main thread). Schedules one frame, or
    /// drops the tick when the runtime queue is still busy with the previous
    /// frame.
    fileprivate func displayLinkFired(_ link: CADisplayLink) {
        guard frameGate.wait(timeout: .now()) == .success else { return }
        let gate = frameGate
        runtimeQueue.async { [weak self] in
            self?.renderFrame()
            gate.signal()
        }
    }

    /// Executes one frame, times every phase and publishes screens + stats.
    /// runtimeQueue only. Returns `false` when the runtime was stopped by an
    /// exit/fault (the caller must not schedule another frame); `true` when the
    /// frame completed and the loop may continue.
    @discardableResult
    private func renderFrame() -> Bool {
        guard let system else { return false }
        let frameStart = FrameClock.now()

        // The only place that pushes input: same serial queue, immediately
        // before the frame that consumes it.
        let input = inputState.snapshot()
        zk_set_input(system, input.buttons, input.circleX, input.circleY,
                     input.touch ? 1 : 0, input.touchX, input.touchY)

        let runStart = FrameClock.now()
        let result = zk_run_frame(system)
        timingWindow.record(.runFrame, ticks: FrameClock.now() - runStart)
        framesRendered += 1

        switch result {
        case 0:
            // ZK_FRAME_COMPLETED. Audio first: it does not depend on the
            // display, and in Metal mode a present can wait for a drawable,
            // which must not delay draining the ring buffer.
            let audioStart = FrameClock.now()
            pumpAudio(system: system)
            timingWindow.record(.audioPump, ticks: FrameClock.now() - audioStart)

            var top: CGImage?
            var bottom: CGImage?
            if let presenter = framePresenter {
                // A1: the screens go to the CAMetalLayer (straight from the
                // renderer's GPU images when the device is shared).
                let presentStart = FrameClock.now()
                let presented = zk_present(system, presenter)
                timingWindow.record(.present, ticks: FrameClock.now() - presentStart)
                if presented <= -2 {
                    presentFailed(result: presented)
                } else {
                    presentFailures = 0
                }
            } else {
                // Pre-A1 path: copy both screens to the CPU and build CGImages.
                var cgImageTicks: UInt64 = 0
                top = screenImage(system: system, which: 0, cgImageTicks: &cgImageTicks)
                bottom = screenImage(system: system, which: 1, cgImageTicks: &cgImageTicks)
                timingWindow.record(.cgImage, ticks: cgImageTicks)
            }

            timingWindow.record(.renderTotal, ticks: FrameClock.now() - frameStart)
            publishFrame(top: top, bottom: bottom, result: result)
            return true
        case 1:
            timingWindow.record(.renderTotal, ticks: FrameClock.now() - frameStart)
            // ZK_FRAME_EXITED.
            finishRuntime(message: "The game requested exit (zk_run_frame = 1).", isError: false)
            return false
        case -1:
            timingWindow.record(.renderTotal, ticks: FrameClock.now() - frameStart)
            // ZK_FRAME_FAULTED.
            finishRuntime(message: "Runtime fault (zk_run_frame = -1).", isError: true)
            return false
        default:
            timingWindow.record(.renderTotal, ticks: FrameClock.now() - frameStart)
            // ZK_FRAME_BAD_HANDLE (-2).
            finishRuntime(message: "Invalid runtime handle (zk_run_frame = \(result)).", isError: true)
            return false
        }
    }

    /// A1: `zk_present()` failed (a negative result below -1). Counts
    /// consecutive failures and, after a short run of them, stops presenting and
    /// lets the next frames use the CGImage readback path, so a broken swapchain
    /// cannot leave a black picture for the rest of the session. runtimeQueue
    /// only.
    private func presentFailed(result: Int32) {
        presentFailures += 1
        if presentFailures == 1 || presentFailures == Self.presentFailureLimit {
            NSLog("[3ds2apple] zk_present failed (result %d, %d in a row)",
                  result, presentFailures)
        }
        guard presentFailures >= Self.presentFailureLimit else { return }
        framePresenter = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayPath = .readback
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
        timingWindow.record(readPhase, ticks: FrameClock.now() - readStart)

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
        timingWindow.record(readPhase, ticks: FrameClock.now() - readStart)

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
                + "run=%.1f/%.1f present=%.2f/%.2f readTop=%.2f/%.2f "
                + "readBottom=%.2f/%.2f image=%.2f/%.2f audio=%.2f/%.2f ms "
                + "(avg/max; total avg/max/last)",
            stats.fps,
            stats.frames,
            timing.renderTotal.average, timing.renderTotal.maximum, timing.renderTotal.last,
            timing.runFrame.average, timing.runFrame.maximum,
            timing.present.average, timing.present.maximum,
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
        // No further frame may be scheduled, whichever driver is running. This
        // is safe to call from the runtime queue (the state is lock-guarded).
        freeRunState.stop()
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
        frameLoopLabel = "—"
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

/// Generation-guarded on/off switch for the free-run frame loop (I3-T9).
///
/// The main thread calls `start()` when a runtime is loaded and `stop()` on
/// Unload / Change ROM / background / exit / fault / deinit. The runtime queue
/// checks `isCurrent(_:)` before every frame and before scheduling the next one.
///
/// The generation is what makes stopping safe: a frame that was queued before
/// a stop carries the old generation, so it does nothing instead of touching a
/// handle that `zk_destroy()` already released. The lock covers the two
/// threads; it is taken twice per frame (≈ tens of nanoseconds), never inside
/// the measured `renderFrame` work.
private final class FreeRunLoopState {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false

    /// Marks the loop active and returns the generation the new loop belongs
    /// to. Main queue only (guarded anyway).
    func start() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        active = true
        return generation
    }

    /// Marks the loop stopped and invalidates every queued continuation.
    /// Returns whether a loop was actually running. Safe from any thread.
    @discardableResult
    func stop() -> Bool {
        lock.lock()
        let wasActive = active
        active = false
        generation &+= 1
        lock.unlock()
        return wasActive
    }

    /// `true` only while `generation` is the current, active loop.
    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active && generation == self.generation
    }
}
