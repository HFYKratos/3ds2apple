//
//  ROMSession.swift
//  3ds2apple
//
//  I2-T1: ROM import + zk_create() wiring.
//  I2-T2: frame loop (zk_run_frame → zk_read_screen → CGImage) on the same
//         serial queue.
//  I3-T6: per-phase timing for diagnostics and a reusable RGBA /
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
//    `FrameTimingSnapshot` for the diagnostics report;
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

/// Rolling status of the frame loop, shown in the UI status line and diagnostics.
struct FrameStats {
    /// Frames per second over the last sampling window (0 when stopped).
    var fps: Double = 0
    /// Frames executed since the loop started.
    var frames: UInt64 = 0
    /// Last `zk_run_frame` result: 0 completed, 1 exited, -1 faulted,
    /// -2 bad handle (see ZK_FRAME_* in ios/ZakuroBridge.h).
    var lastResult: Int32 = 0
    /// Per-phase durations in milliseconds (I3-T6; recorded for diagnostics).
    var timing = FrameTimingSnapshot()
}

/// Whether this build carries linked 3dsrecomp code and whether the loaded
/// title is actually executing it (rather than falling back to the interpreter).
enum AOTStatus: String {
    case unknown = "?"
    case shell = "interpreter shell"
    case linkedInterpreting = "linked, interpreting"
    case linkedActive = "linked, active"

    /// Stable English label for the device log and the diagnostics report.
    var label: String { rawValue }

    /// Localized label for the status line and the About/Settings pages.
    var title: String { L10n.tr(rawValue) }
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

    /// Stable English label for the device log and the diagnostics report.
    var label: String {
        switch self {
        case .readback: return "CGImage readback"
        case .metalDirect: return "CAMetalLayer · GPU direct"
        case .metalUploaded: return "CAMetalLayer · uploaded"
        }
    }

    /// Localized label for the status line and the About/Settings pages.
    var title: String {
        switch self {
        case .readback: return L10n.tr("CGImage readback")
        case .metalDirect: return L10n.tr("CAMetalLayer · GPU direct")
        case .metalUploaded: return L10n.tr("CAMetalLayer · uploaded")
        }
    }
}

/// Owns the Zakuro runtime handle, the ROM import pipeline and the frame loop.
final class ROMSession: ObservableObject, SaveStateRuntime {
    enum Phase {
        /// Nothing imported or loaded yet.
        case idle
        /// Copying the picked file into Documents/roms.
        case importing(name: String)
        /// zk_create() is running on the runtime queue.
        case starting(name: String)
        /// zk_create() succeeded and the first frames are running behind the
        /// "Preparing graphics" overlay while the GPU pipelines compile/cache.
        /// The game is not revealed (and input is not forwarded) yet.
        case preparing(name: String)
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
    /// `CADisplayLink · 60 Hz`). Stable English for logs and diagnostics.
    @Published private(set) var frameLoopLabel: String = "—"
    /// Localized copy of `frameLoopLabel` for the status line and About page.
    @Published private(set) var frameLoopDisplayLabel: String = "—"
    /// Fast-forward the frame loop is actually using: the setting from
    /// Settings, possibly reduced by the automatic fallback when frames take
    /// too long (`playbackSpeedAutoReduced`).
    @Published private(set) var effectivePlaybackSpeed: Int = 1
    /// True when the automatic fallback lowered `effectivePlaybackSpeed` below
    /// the value requested in Settings during this session.
    @Published private(set) var playbackSpeedAutoReduced = false
    /// A1: the Metal view the presenter draws into, nil while the Metal path is
    /// off or unavailable. The session keeps it for the app's lifetime: the
    /// presenter's swapchain references its layer.
    @Published private(set) var metalScreenView: MetalScreenView?
    /// A1: how the loaded runtime reaches the display (status line + which
    /// screen surface the UI shows).
    @Published private(set) var displayPath: Presentation = .readback
    /// First-run graphics warm-up: frames run behind the loading overlay while
    /// the GPU compiles its first pipelines (GraphicsWarmUp.swift).
    @Published private(set) var warmUp = GraphicsWarmUpStatus()
    /// Latest `zk_hardware_status()` text: whether the 3D draws on the host GPU
    /// via Vulkan (MoltenVK) and how the screens are presented; shown in
    /// diagnostics next to the warm-up/cache state.
    @Published private(set) var hardwareStatus: String = "—"
    /// Pipeline-cache files seen at the last check (load, warm-up end,
    /// unload/background). Used to tell a cold first run from a warmed one and
    /// exported in diagnostics.
    @Published private(set) var pipelineCacheStats = PipelineCacheStats.empty
    /// Emulation is paused (in-game menu open, or the user paused): the frame
    /// loop and the audio engine are stopped, the runtime handle stays.
    @Published private(set) var isPaused = false
    /// Instant save slots of the current game (SaveStateSupport.swift). Created
    /// on first use; the runtime itself is passed weakly, so the session owns
    /// the support object and not the other way around.
    private(set) lazy var saveStates: SaveStateSupport = SaveStateSupport(runtime: self)
    /// Screen arrangement chosen in Settings. Applied live: the Metal view's
    /// drawable is resized and the presenter is told the new layout, so the next
    /// frame shows it. Every layout goes through the CAMetalLayer presenter; the
    /// readback path is only used when no presenter can be made.
    private(set) var screenLayout: ScreenLayout = .stacked
    /// Turn of the screens inside their area (Settings → Display). Applied the
    /// same way as the layout.
    private(set) var screenRotation: ScreenRotation = .upright
    /// Drawable resolution factor (1 = the arrangement's own pixels ... 4 =
    /// four times them) requested for the presented screens. Applied to the Metal
    /// view (and its presenter) as soon as it exists, and remembered for the
    /// first load. The runtime's internal 3D renderer reads the same factor when
    /// a system loads (see `applyRenderScale`).
    private var requestedRenderScale: CGFloat = 1
    /// Integer scaling for the layer's magnification (nearest-pixel filtering).
    /// The layout box itself is computed by the game view from the setting.
    private var integerScaleSetting = false
    /// Free-run frame cap (frames per second). Mutable while playing.
    private let frameRateCap = LockedIntState(initialValue: 60)
    /// Fast-forward target the frame loop currently uses (1, 2 or 4). Written
    /// from the settings page on the main queue, read before every frame on the
    /// runtime queue; the automatic fallback lowers it from the runtime queue.
    private let playbackSpeedState = LockedIntState(initialValue: 1)
    /// Optional first-load graphics warm-up (Settings, off by default). Read
    /// when a load starts, so it can be toggled without re-loading a ROM.
    private let graphicsWarmUpSetting = LockedIntState(initialValue: 0)
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
    /// Serial queue for library imports: copying a multi-GB ROM must not block
    /// the main thread, and one import at a time keeps the progress status
    /// honest.
    private let importQueue = DispatchQueue(
        label: "com.kratos.3ds2apple.rom-import",
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
    /// Fast-forward value requested in Settings (main queue only). Kept apart
    /// from `playbackSpeedState` so diagnostics can show both the requested and
    /// the effective speed after an automatic fallback.
    private var requestedPlaybackSpeed = 1
    /// Consecutive 0.5 s windows in which fast-forward kept missing the speed
    /// floor; two in a row lower the speed one step. runtimeQueue only.
    private var slowPlaybackSpeedWindows = 0
    /// System Metal Performance HUD preference (main queue only); applied to
    /// the Metal view whenever it exists and when it is created.
    private var systemMetalHUDEnabled = false

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
    /// The warm-up running behind the loading overlay, nil when the game is
    /// already revealed. runtimeQueue only; `warmUp` is its main-queue copy.
    private var warmUpRun: GraphicsWarmUpRun?

    init() {
        // The library is the source of truth for "last game": restore its most
        // recent entry so the diagnostics line and loadLastROM have context
        // before the user taps a card.
        if let entry = GameLibrary.shared.entries.first {
            lastROM = ImportedROM(name: entry.fileName, relativePath: entry.relativePath)
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

    /// Copies the picked file into Documents/roms and adds it to the game
    /// library. Nothing is loaded: tapping the card starts it later.
    func importROM(from url: URL) {
        importROMs(from: [url])
    }

    /// Imports picked ROM files into the library, one at a time on a private
    /// queue so several multi-GB copies never run at once and the main thread
    /// stays responsive. `phase` reports the file being copied; failures are
    /// collected into one readable message.
    func importROMs(from urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        let names = urls.map { $0.lastPathComponent }
        if let unsupported = names.first(where: { !GameLibrary.isSupportedROM($0) }) {
            setPhase(.failed(message: L10n.format(
                "Unsupported file “%@”. Choose a decrypted .3ds, .cci or .cia ROM.",
                unsupported
            )))
            return
        }
        setPhase(.importing(name: names[0]))
        importQueue.async { [weak self] in
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                let name = names[index]
                DispatchQueue.main.async { [weak self] in
                    self?.setPhase(.importing(name: name))
                }
                do {
                    let entry = try GameLibrary.makeEntry(importing: url)
                    DispatchQueue.main.async {
                        GameLibrary.shared.add(entry)
                    }
                } catch {
                    let reason = error.localizedDescription
                    failures.append(L10n.format("“%@”: %@", name, reason))
                    AppLog.log("[3ds2apple] ROM import failed for %@: %@", name, reason)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if failures.isEmpty {
                    self.setPhase(.idle)
                } else {
                    self.setPhase(.failed(message: failures.joined(separator: "\n")))
                }
            }
        }
    }

    /// Whether an import is running (the home page disables import and play).
    var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    /// Starts a game from the library: marks it played and loads its ROM. The
    /// runtime path (beginLoad then startRuntime) is unchanged.
    func start(_ entry: GameEntry) {
        let url = GameLibrary.fileURL(for: entry)
        guard fileManager.fileExists(atPath: url.path) else {
            setPhase(.failed(message: L10n.format(
                "“%@” is no longer in this app's Documents folder. Import it again.",
                entry.title
            )))
            return
        }
        GameLibrary.shared.markPlayed(id: entry.id)
        lastROM = ImportedROM(name: entry.fileName, relativePath: entry.relativePath)
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        isPaused = false
        warmUp = GraphicsWarmUpStatus()
        setPhase(.starting(name: entry.fileName))
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.beginLoad(ImportedROM(name: entry.fileName, relativePath: entry.relativePath))
        }
    }

    /// Loads the most recently played game in the library.
    func loadLastROM() {
        guard let entry = GameLibrary.shared.mostRecentlyPlayed
            ?? GameLibrary.shared.entries.first else {
            setPhase(.failed(message: L10n.tr("No games in your library yet. Import a ROM first.")))
            return
        }
        start(entry)
    }

    /// Releases the runtime handle and returns to the "no ROM loaded" state.
    /// The imported file stays in Documents so it can be loaded again.
    func unload() {
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        isPaused = false
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.destroySystem()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearScreens()
                self.warmUp = GraphicsWarmUpStatus()
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
        isPaused = false
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            let hadRuntime = self.system != nil
            self.destroySystem()
            guard hadRuntime else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clearScreens()
                self.warmUp = GraphicsWarmUpStatus()
                self.setPhase(.finished(
                    message: L10n.tr("The runtime was stopped when the app went to the background. Load the ROM again to continue.")
                ))
            }
        }
    }

    /// Ends the running graphics warm-up at the next frame. The overlay's Skip
    /// button calls this; the game is revealed on the following frame.
    func skipGraphicsWarmUp() {
        guard case .preparing = phase else { return }
        AppLog.log("[3ds2apple] graphics warm-up: skip requested by the user")
        runtimeQueue.async { [weak self] in
            self?.warmUpRun?.skipRequested = true
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

    // MARK: - Settings (main queue)

    /// True while a runtime handle exists: a load is in progress or a game is
    /// running. The settings pages use it to disable actions that would race the
    /// runtime (clearing the pipeline cache, for example).
    var isRuntimeActive: Bool {
        switch phase {
        case .starting, .preparing, .loaded: return true
        case .idle, .importing, .failed, .finished: return false
        }
    }

    /// Records and applies the screen arrangement. Safe while a game runs: the
    /// Metal view's drawable becomes the arrangement's own size and the presenter
    /// uses the new layout from the next frame (the swapchain is resized on the
    /// runtime queue).
    func setScreenLayout(_ layout: ScreenLayout) {
        guard layout != screenLayout else { return }
        screenLayout = layout
        AppLog.log("[3ds2apple] screen layout: %@", layout.rawValue)
        applyPresentedGeometry()
    }

    /// Records and applies which way the screens are turned. Safe while a game
    /// runs (same path as the layout change).
    func setScreenRotation(_ rotation: ScreenRotation) {
        guard rotation != screenRotation else { return }
        screenRotation = rotation
        AppLog.log("[3ds2apple] screen rotation: %@", rotation.rawValue)
        applyPresentedGeometry()
    }

    /// Turns whole-console-pixel magnification on or off. The game view computes
    /// its box from the same setting; this only tells the layer which filter to
    /// magnify the drawable with.
    func setIntegerScaling(_ enabled: Bool) {
        guard enabled != integerScaleSetting else { return }
        integerScaleSetting = enabled
        applyPresentedGeometry()
    }

    /// Changes the free-run frame cap. Safe while a game is playing: the next
    /// scheduled frame uses the new period.
    func setFrameRateCap(_ framesPerSecond: Int) {
        let cap = framesPerSecond <= 30 ? 30 : 60
        frameRateCap.set(cap)
        if isRuntimeActive, !isPaused {
            setFrameLoopLabels(isFreeRun: Self.frameLoopDriver == .freeRun, cap: cap)
        }
        AppLog.log("[3ds2apple] frame cap: %d fps", cap)
    }

    /// The current free-run cap, for the diagnostics report.
    var frameRateCapValue: Int { frameRateCap.current }

    /// Updates the English (log/diagnostics) and localized (UI) frame-loop
    /// labels together. Main queue only.
    private func setFrameLoopLabels(isFreeRun: Bool, cap: Int) {
        if isFreeRun {
            frameLoopLabel = "free-run · cap \(cap) fps"
            frameLoopDisplayLabel = L10n.format("free-run · cap %ld fps", cap)
        } else {
            frameLoopLabel = "CADisplayLink · \(Self.displayLinkFramesPerSecond) Hz"
            frameLoopDisplayLabel = L10n.format("CADisplayLink · %ld Hz", Self.displayLinkFramesPerSecond)
        }
    }

    // MARK: - Fast-forward (main queue sets, runtimeQueue runs)

    /// Sets the fast-forward target from Settings (1 = 1×, 2 = 2×, 4 = 4×).
    /// Safe while playing: the next scheduled frame uses the new value. `1×`
    /// restores normal speed (and sound). A change also clears an automatic
    /// fallback, so the requested speed is tried again.
    func setPlaybackSpeed(_ speed: Int) {
        let clamped = speed >= 4 ? 4 : (speed >= 2 ? 2 : 1)
        requestedPlaybackSpeed = clamped
        playbackSpeedState.set(clamped)
        effectivePlaybackSpeed = clamped
        playbackSpeedAutoReduced = false
        slowPlaybackSpeedWindows = 0
        // Fast-forward does not feed audio (see renderFrame); drop whatever the
        // previous mode buffered so switching never replays stale samples.
        audioOutput.resetBuffer()
        AppLog.log("[3ds2apple] playback speed: %dx", clamped)
    }

    /// The speed asked for in Settings, for diagnostics (the effective value is
    /// in `effectivePlaybackSpeed`).
    var requestedPlaybackSpeedValue: Int { requestedPlaybackSpeed }

    // MARK: - System Metal HUD (main queue)

    /// Shows or hides the system Metal Performance HUD on the presented layer.
    /// Applies immediately when the layer exists and is re-applied whenever the
    /// Metal view is (re)used, so the choice survives menu navigation and ROM
    /// reloads. The readback path has no CAMetalLayer, so the setting only
    /// matters there once a presented load runs.
    func setSystemMetalHUD(_ enabled: Bool) {
        systemMetalHUDEnabled = enabled
        if let view = metalScreenView {
            view.applySystemMetalHUD(enabled: enabled)
        }
        AppLog.log("[3ds2apple] system Metal HUD: %@", enabled ? "on" : "off")
    }

    /// Whether the build's Info.plist enables the system Metal HUD. The runtime
    /// dictionary can only show/hide a HUD the build (or the device's Developer
    /// settings) enables.
    var buildEnablesSystemMetalHUD: Bool {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MetalHudEnabled") else {
            return false
        }
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            return value == "YES" || value == "true" || value == "1"
        }
        return false
    }

    // MARK: - Graphics warm-up (main queue sets, runtimeQueue reads)

    /// Turns the optional first-load graphics warm-up on or off. Off (the
    /// default) reveals the game as soon as the ROM is loaded; the runtime's
    /// pipeline-cache persistence is not affected either way.
    func setGraphicsWarmUpEnabled(_ enabled: Bool) {
        graphicsWarmUpSetting.set(enabled ? 1 : 0)
        AppLog.log("[3ds2apple] graphics warm-up: %@", enabled ? "on" : "off")
    }

    /// Whether the optional graphics warm-up is on, for diagnostics.
    var graphicsWarmUpEnabled: Bool { graphicsWarmUpSetting.current == 1 }

    /// Render resolution factor (1...4). The Metal drawable and the presenter
    /// geometry use the new factor at once; the runtime's internal 3D render
    /// scale is process-wide and only read when a system loads, so a game that is
    /// already loaded keeps its internal resolution until it is reloaded or
    /// restarted (see zk_set_render_scale in ios/ZakuroBridge.h).
    func applyRenderScale(_ scale: CGFloat) {
        let factor = min(max(Int(scale.rounded()), 1), 4)
        requestedRenderScale = CGFloat(factor)
        // The value is read while a system loads, and loads run on the runtime
        // queue: queue the write there so it can never race a load.
        runtimeQueue.async {
            let result = zk_set_render_scale(UInt32(factor))
            if result != 0 {
                AppLog.log("[3ds2apple] zk_set_render_scale(%d) failed: %@",
                      factor, Self.currentRuntimeError())
            }
        }
        applyPresentedGeometry()
        AppLog.log(
            "[3ds2apple] render scale: %dx · drawable resized now · internal 3D renderer applies on the next load",
            factor
        )
    }

    /// Pushes the layout, rotation, render scale and integer-scaling choice into
    /// the Metal view (drawable size and magnification filter), and — when a
    /// system is presenting — tells the presenter the same layout/orientation and
    /// resizes its swapchain, all on the runtime serial queue. Main queue only.
    private func applyPresentedGeometry() {
        guard let view = metalScreenView else { return }
        configurePresentedGeometry(view)
        guard let presenter else { return }
        let layout = screenLayout.presenterValue
        let rotation = screenRotation.presenterValue
        let size = view.drawablePixelSize
        let width = UInt32(max(1, size.width.rounded()))
        let height = UInt32(max(1, size.height.rounded()))
        runtimeQueue.async { [weak self] in
            // Only a system mid-presentation needs the live change; a load that
            // is about to start gets the layout from presenterForLoadOnMain.
            guard let self, self.framePresenter != nil else { return }
            _ = zk_presenter_set_layout(presenter, layout)
            _ = zk_presenter_set_orientation(presenter, rotation)
            _ = zk_presenter_resize(presenter, width, height)
        }
    }

    /// Audio output volume, 0...1. Applied to the running mixer immediately.
    func setAudioVolume(_ volume: Float) {
        audioOutput.setVolume(volume)
    }

    /// Audio latency preference, in seconds. A running engine is restarted so
    /// the new buffer duration takes effect immediately.
    func setAudioBufferDuration(_ seconds: TimeInterval) {
        audioOutput.setPreferredBufferDuration(seconds)
        guard isRuntimeAudible else { return }
        if audioOutput.isMuted {
            audioState = .muted
        } else if audioOutput.startEngine() {
            audioState = .running
        } else {
            audioState = .failed(L10n.tr("the audio engine could not start"))
        }
    }

    // MARK: - In-game menu (main queue)

    /// Pauses the frame loop and the audio engine for the in-game menu. The
    /// runtime and the last frame stay; `resumeFromMenu()` continues the same
    /// session without re-loading the ROM.
    func pauseForMenu() {
        guard !isPaused, case .loaded = phase else { return }
        isPaused = true
        inputState.clearAll()
        stopFrameLoop()
        stopAudio()
        AppLog.log("[3ds2apple] runtime paused")
    }

    /// Continues a session paused by `pauseForMenu()`.
    func resumeFromMenu() {
        guard isPaused else { return }
        isPaused = false
        guard case .loaded = phase, let rom = lastROM else { return }
        startFrameLoop(warmUp: nil, romKey: rom.relativePath)
        startAudio()
        AppLog.log("[3ds2apple] runtime resumed")
    }

    /// Restarts the loaded game from its ROM. Save data is kept: the same
    /// per-ROM data directory is passed to the new runtime.
    func resetRuntime() {
        guard case .loaded = phase else { return }
        AppLog.log("[3ds2apple] runtime reset requested")
        isPaused = false
        loadLastROM()
    }

    // MARK: - Save states (main queue control, runtimeQueue executes)
    //
    // SaveStateSupport (SaveStateSupport.swift) owns the slots and the
    // size -> copy -> load protocol; the session provides what it needs: whether
    // a game is loaded, the pause/resume around the serialization, the audio
    // buffer drop after a load, and the serial queue that owns the handle.

    /// True while a game is loaded and its handle is alive: the console can be
    /// serialized or restored.
    var isRuntimeLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    /// ROM name used to name the save-state folder (the last imported game).
    var saveStateROMName: String? { lastROM?.name }

    /// Stops the frame loop and the audio engine before the console is
    /// serialized or restored, so a state is always taken between frames.
    /// Returns true when it stopped a running session; pass that to
    /// `resumeAfterStateWork(_:)` so the session only restarts what it paused
    /// (the in-game menu resumes a game it paused itself).
    func suspendForStateWork() -> Bool {
        guard !isPaused else { return false }
        guard case .loaded = phase else { return false }
        isPaused = true
        inputState.clearAll()
        stopFrameLoop()
        stopAudio()
        AppLog.log("[3ds2apple] runtime paused for a save-state operation")
        return true
    }

    /// Restarts what `suspendForStateWork()` stopped; a no-op when it stopped
    /// nothing (the caller paused the game separately).
    func resumeAfterStateWork(_ suspended: Bool) {
        guard suspended else { return }
        guard case .loaded = phase, let rom = lastROM else { return }
        isPaused = false
        startFrameLoop(warmUp: nil, romKey: rom.relativePath)
        startAudio()
        AppLog.log("[3ds2apple] runtime resumed after the save-state operation")
    }

    /// Drops audio buffered before a state load: the DSP state went back to the
    /// saved point too, so samples produced by the console before the load must
    /// not play.
    func discardBufferedAudio() {
        audioOutput.resetBuffer()
    }

    /// Queues one save-state operation on the serial queue that owns the runtime
    /// handle. The block receives the handle, or nil when the game was unloaded
    /// before it ran; the support code turns that into an error instead of
    /// touching a released handle.
    func runOnRuntimeQueue(_ work: @escaping (zk_system_t?) -> Void) {
        runtimeQueue.async { [weak self] in
            work(self?.system)
        }
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

    /// Presented frames per second below which fast-forward lowers its speed
    /// (two consecutive 0.5 s windows). A 20 fps presentation means each frame
    /// takes about 50 ms, so 4× would spend 200 ms per presented frame.
    private static let speedFloorFPS: Double = 20

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

        let view: MetalScreenView
        if let existing = metalScreenView {
            view = existing
        } else {
            let created = MetalScreenView(frame: .zero)
            created.onDrawableSizeChanged = { [weak self] size in
                self?.presentedDrawableSizeChanged(size)
            }
            metalScreenView = created
            view = created
        }
        // The drawable is the arrangement's own pixels (400x480 for the stacked
        // console, 720x240 side by side, or the arrangement turned a quarter
        // turn), times the render scale. Set before the presenter is made so the
        // surface and first swapchain start at the right size.
        configurePresentedGeometry(view)
        // The setting applies to the layer, which lives for the app run: apply
        // it again on every load so it also survives app navigation/reloads.
        view.applySystemMetalHUD(enabled: systemMetalHUDEnabled)
        view.prepareForPresentation()

        if let presenter {
            // A reused presenter is configured for this load here on the main
            // queue: the frame loop is stopped (the load restarts it), so no
            // zk_present can be running at the same time.
            applyScreenArrangementOnMain(presenter)
            return presenter
        }
        if presenterUnavailable { return nil }

        let size = view.drawablePixelSize
        let width = UInt32(max(1, size.width.rounded()))
        let height = UInt32(max(1, size.height.rounded()))
        if let handle = zk_presenter_create(Unmanaged.passUnretained(view).toOpaque(),
                                            width, height) {
            presenter = handle
            presentedDrawableSize = CGSize(width: CGFloat(width), height: CGFloat(height))
            AppLog.log("[3ds2apple] zk_presenter_create: CAMetalLayer %ux%u · shared device: %@",
                  width, height, zk_presenter_shared_device(handle) == 1 ? "yes" : "no")
            applyScreenArrangementOnMain(handle)
            return handle
        }
        // Read the thread-local error here, before anything else can replace it.
        let message = Self.currentRuntimeError()
        AppLog.log("[3ds2apple] zk_presenter_create failed; using the CGImage readback path: %@",
              message)
        presenterUnavailable = true
        metalScreenView = nil
        return nil
    }

    /// Pushes the layout, rotation, render scale and integer-scaling choice into
    /// the Metal view. Main queue only.
    private func configurePresentedGeometry(_ view: MetalScreenView) {
        let native = ScreenGeometry.nativePixelSize(layout: screenLayout, rotation: screenRotation)
        view.setPresentedGeometry(
            nativePixelSize: native,
            renderScale: requestedRenderScale,
            integerScaling: integerScaleSetting
        )
        presentedDrawableSize = view.drawablePixelSize
    }

    /// Tells the presenter the layout/orientation a load will present with, and
    /// logs that the Swift geometry agrees with the Rust layout helper. Main
    /// queue, with the frame loop stopped (a load start); live changes go through
    /// `applyPresentedGeometry` on the runtime queue. `presenterForLoadOnMain`
    /// runs before the system is created, so no `zk_present` can overlap.
    private func applyScreenArrangementOnMain(_ handle: UnsafeMutableRawPointer) {
        let layout = screenLayout.presenterValue
        let rotation = screenRotation.presenterValue
        _ = zk_presenter_set_layout(handle, layout)
        _ = zk_presenter_set_orientation(handle, rotation)

        let native = ScreenGeometry.nativePixelSize(layout: screenLayout, rotation: screenRotation)
        var expectedWidth: UInt32 = 0
        var expectedHeight: UInt32 = 0
        guard zk_present_layout_size(layout, rotation, &expectedWidth, &expectedHeight) == 1 else {
            AppLog.log("[3ds2apple] zk_present_layout_size rejected layout %u orientation %u",
                  layout, rotation)
            return
        }
        let matches = Int(expectedWidth) == Int(native.width.rounded())
            && Int(expectedHeight) == Int(native.height.rounded())
        AppLog.log(
            "[3ds2apple] screen layout %@ · %@ · native drawable %ux%u · Swift %@%@",
            screenLayout.rawValue,
            screenRotation.rawValue,
            expectedWidth,
            expectedHeight,
            "\(Int(native.width.rounded()))x\(Int(native.height.rounded()))",
            matches ? "" : " (MISMATCH)"
        )
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
            screenLayout.presenterValue,
            screenRotation.presenterValue,
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
        // A warm-up cannot outlive the runtime it runs frames on.
        warmUpRun = nil
        if let presenter = framePresenter {
            // The presenter's device and the screens it showed belong to this
            // runtime: stop presenting before the system goes away.
            framePresenter = nil
            AppLog.log("[3ds2apple] CAMetalLayer presentation detached (shared device: %@)",
                  zk_presenter_shared_device(presenter) == 1 ? "yes" : "no")
        }
        guard let system else { return }
        zk_destroy(system)
        self.system = nil
        presentFailures = 0
        AppLog.log("[3ds2apple] zk_destroy: runtime released")
        // zk_destroy drops the runtime, and Zakuro writes the pipelines it
        // compiled to Caches/zakuro/pipelines/<title>.bin on the way out: log
        // the directory so a device log (or the exported diagnostics) proves a
        // session's cache survived an Unload / move to the background.
        let cache = PipelineCacheStats.read()
        AppLog.log("[3ds2apple] pipeline cache after zk_destroy: %@", cache.summary)
        DispatchQueue.main.async { [weak self] in
            self?.pipelineCacheStats = cache
        }
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
            .appendingPathComponent(SaveDataStore.gameDirectoryName(for: rom.name), isDirectory: true)
        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            publishFailure(L10n.format("Could not create the save-data directory: %@", error.localizedDescription))
            return
        }

        // Replacing a ROM always releases the previous handle first, and that
        // release is when Zakuro writes the pipelines it compiled to its cache
        // (Caches/zakuro/pipelines, one file per title). Read the directory
        // after it so the log/plan says whether this is a cold first run or a
        // warmed one.
        destroySystem()
        let cacheAtLoad = PipelineCacheStats.read()
        AppLog.log("[3ds2apple] pipeline cache at load: %@", cacheAtLoad.summary)

        AppLog.log("[3ds2apple] zk_create: loading %@ (CAMetalLayer: %@)",
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
                AppLog.log("[3ds2apple] zk_create_presented failed; retrying with zk_create: %@",
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
            AppLog.log("[3ds2apple] zk_create failed after %.1f s: %@", elapsed, message)
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
        let hardwareStatus = Self.hardwareStatusText(handle)
        AppLog.log("[3ds2apple] AOT linked=%d recompiled=%d program=0x%016llx status=%@",
              linked ? 1 : 0, recompiled ? 1 : 0, programID, aot.label)
        AppLog.log("[3ds2apple] display: %@", displayPath.label)
        AppLog.log("[3ds2apple] hardware: %@", hardwareStatus)
        AppLog.log("[3ds2apple] zk_create OK after %.1f s: %@", elapsed, rom.relativePath)

        // A cold first run spends hundreds of milliseconds per new GPU pipeline
        // inside a frame while the driver compiles it. The optional warm-up runs
        // those frames behind a loading overlay; it is OFF by default because
        // later pipelines still compile on first use, so the wait was judged
        // not worth it. The runtime's pipeline-cache persistence runs
        // regardless. A software renderer has no pipelines to warm.
        let warmUpSettingOn = graphicsWarmUpSetting.current == 1
        let plan = warmUpSettingOn
            ? Self.graphicsWarmUpPlan(hardwareStatus: hardwareStatus, cache: cacheAtLoad, rom: rom)
            : nil
        if !warmUpSettingOn {
            AppLog.log("[3ds2apple] graphics warm-up: off in Settings; revealing the game as soon as the ROM loads")
        } else if let plan {
            AppLog.log("[3ds2apple] graphics warm-up: planned %@ (%@, max %.0f s, %ld quiet frames)",
                  plan.fromWarmCache ? "short (pipelines cached)" : "full (cold cache)",
                  cacheAtLoad.summary, plan.maximumSeconds, plan.requiredQuietFrames)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastROM = rom
            self.inputState.clearAll()
            self.clearScreens()
            self.aotStatus = aot
            self.displayPath = displayPath
            self.hardwareStatus = hardwareStatus
            self.pipelineCacheStats = cacheAtLoad
            if let plan {
                self.beginGraphicsWarmUp(plan: plan, rom: rom)
            } else {
                // Disabled by the setting, or a software renderer: reveal now.
                self.warmUp = warmUpSettingOn
                    ? GraphicsWarmUpStatus.skippedForSoftware()
                    : GraphicsWarmUpStatus.skippedForDisabledSetting()
                AppLog.log("[3ds2apple] graphics warm-up: %@", self.warmUp.logLine)
                self.setPhase(.loaded(name: rom.name))
                self.startFrameLoop(warmUp: nil, romKey: rom.relativePath)
                self.startAudio()
            }
        }
    }

    /// Whether (and how long) to warm the GPU pipelines for this load.
    ///
    /// Only a renderer drawing on the host GPU compiles Vulkan pipelines; a
    /// software renderer is revealed immediately. A ROM whose warm-up completed
    /// in this app install, with cache files still on disk, gets the shorter
    /// `warm` plan: its pipelines only need to be loaded from the cache.
    private static func graphicsWarmUpPlan(hardwareStatus: String,
                                           cache: PipelineCacheStats,
                                           rom: ImportedROM) -> GraphicsWarmUpPlan? {
        guard hardwareStatus.contains("draws on the host GPU") else { return nil }
        let alreadyWarmed = GraphicsWarmUpMarker.wasCompleted(romKey: rom.relativePath)
        return alreadyWarmed && cache.isWarm ? .warm : .cold
    }

    /// Starts the warm-up behind the "Preparing graphics" overlay: publishes the
    /// phase, sets the runtime queue's tracker and starts the frame loop.
    /// Main queue only.
    private func beginGraphicsWarmUp(plan: GraphicsWarmUpPlan, rom: ImportedROM) {
        warmUp = GraphicsWarmUpStatus.starting(plan: plan)
        setPhase(.preparing(name: rom.name))
        AppLog.log("[3ds2apple] graphics warm-up: starting (%@)",
              plan.fromWarmCache ? "cached pipelines, short run" : "cold cache, full run")
        startFrameLoop(warmUp: plan, romKey: rom.relativePath)
        startAudio()
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
            return L10n.tr("The Zakuro runtime could not load this ROM (no error text was reported).")
        }
        let text = String(cString: pointer)
        return text.isEmpty ? L10n.tr("The Zakuro runtime could not load this ROM (empty error text).") : text
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

    // Free-run cap: frames never start closer together than 1/60 s by
    // default (the 3DS timeline; the Settings page can lower it to 30 fps in
    // `frameRateCap`). This is a *cap*, not a target — a frame that takes
    // longer than 1/60 s (e.g. the measured 22.6 ms Pokémon Y AOT frame) starts
    // the next frame immediately instead of waiting for a display tick, so the
    // loop runs at the real throughput (~44 fps) instead of a 30 fps multiple.

    /// CADisplayLink fallback rate. 60 reproduces the pre-I3-T9 behaviour; 120
    /// is the I3-T9 experiment (`preferredFramesPerSecond = 120`). 120 only
    /// helps once a frame is faster than 8.3 ms — at 22.6 ms a frame still
    /// spans several ticks, so the fallback would stay at ~30 fps.
    private static let displayLinkFramesPerSecond = 60

    /// One free-run slot in mach ticks for the current cap (1/60 s by default).
    private var freeRunPeriodTicks: UInt64 {
        FrameClock.ticks(seconds: 1.0 / Double(frameRateCap.current))
    }

    /// `DispatchQueue.asyncAfter` wakes about 1 ms after the requested
    /// deadline on this device. Without the compensation the loop misses the
    /// 60 Hz slot by ~1 ms every frame and settles at ~56–58 fps even though
    /// the frame itself only takes ~7 ms.
    private static let freeRunDispatchOverheadSeconds: TimeInterval = 0.001

    /// Starts the configured frame-loop driver after a successful load.
    ///
    /// `warmUp` starts the first-frame warm-up behind the loading overlay; the
    /// tracker is runtimeQueue-owned but no frame loop is running yet (this is
    /// called after `stopFrameLoopOnMain()`), so setting it here cannot race a
    /// frame. Main queue only.
    private func startFrameLoop(warmUp plan: GraphicsWarmUpPlan?, romKey: String) {
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
        if let plan {
            warmUpRun = GraphicsWarmUpRun(
                plan: plan,
                romKey: romKey,
                startedTicks: FrameClock.now()
            )
        } else {
            warmUpRun = nil
        }

        switch Self.frameLoopDriver {
        case .freeRun:
            let generation = freeRunState.start()
            let cap = frameRateCap.current
            setFrameLoopLabels(isFreeRun: true, cap: cap)
            // First frame right away; every later frame is scheduled by the
            // runtime queue after the previous one, so at most one frame is in
            // flight and at most one continuation is queued.
            scheduleFreeRunFrame(after: 0, generation: generation)
            AppLog.log("[3ds2apple] frame loop started (free-run, cap %d fps)", cap)
        case .displayLink:
            startDisplayLinkOnMain()
            setFrameLoopLabels(isFreeRun: false, cap: frameRateCap.current)
            AppLog.log("[3ds2apple] frame loop started (CADisplayLink at %d fps)",
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

        // 60 Hz cap (or the cap chosen in Settings): only the early part of the
        // slot is waited out. A frame that overran its slot continues
        // immediately (delay 0), which is what removes the CADisplayLink
        // quantization.
        let now = FrameClock.now()
        let deadline = frameStart &+ freeRunPeriodTicks
        let rawDelay = deadline > now ? FrameClock.seconds(deadline - now) : 0
        // Aim slightly early so asyncAfter's wake-up latency lands on the
        // 60 Hz deadline instead of ~1 ms after it.
        let delay = max(0, rawDelay - Self.freeRunDispatchOverheadSeconds)
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
            AppLog.log("[3ds2apple] frame loop stopped")
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

    /// Executes one presented frame, times every phase and publishes screens +
    /// stats. runtimeQueue only.
    ///
    /// Fast-forward: at 2×/4× the runtime advances `speed` console frames per
    /// presented frame. The extra frames call `zk_run_frame` without presenting
    /// or reading the screens, but their audio is queued too, so the sound
    /// speeds up with the game instead of being muted. The final frame is
    /// presented and published as usual, so input, pause, save states and unload
    /// keep working at the same serial-queue frame boundaries.
    ///
    /// Returns `false` when the runtime was stopped by an exit/fault (the caller
    /// must not schedule another frame); `true` when the frame completed and the
    /// loop may continue.
    @discardableResult
    private func renderFrame() -> Bool {
        guard let system else { return false }
        let frameStart = FrameClock.now()
        let speed = playbackSpeedState.current

        // The only place that pushes input: same serial queue, immediately
        // before the frame that consumes it. During the graphics warm-up the
        // game is hidden behind the overlay and receives neutral input, so a
        // button touched on the transparent overlay cannot move the title
        // before the player sees it; the merged input state itself is left
        // alone and is forwarded again from the first revealed frame.
        let input = warmUpRun == nil ? inputState.snapshot() : InputSnapshot()

        // Fast-forward: advance the console-only frames first. They produce no
        // visible frame and no audible samples.
        if speed > 1 {
            var fastForwarded = 1
            while fastForwarded < speed {
                if !runFastForwardFrame(system: system, input: input, frameStart: frameStart) {
                    return false
                }
                fastForwarded += 1
            }
        }

        zk_set_input(system, input.buttons, input.circleX, input.circleY,
                     input.touch ? 1 : 0, input.touchX, input.touchY)

        let runStart = FrameClock.now()
        let result = zk_run_frame(system)
        timingWindow.record(.runFrame, ticks: FrameClock.now() - runStart)
        framesRendered += 1

        guard result == 0 else {
            timingWindow.record(.renderTotal, ticks: FrameClock.now() - frameStart)
            return finishForRunFrameResult(result)
        }

        // ZK_FRAME_COMPLETED. Audio first: it does not depend on the display,
        // and in Metal mode a present can wait for a drawable, which must not
        // delay draining the ring buffer. Fast-forward keeps its audio: every
        // console frame (including the extra ones) feeds the same ring buffer,
        // so the sound speeds up with the game instead of being muted.
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
        advanceGraphicsWarmUp(frameMilliseconds: FrameClock.milliseconds(FrameClock.now() - frameStart))
        return true
    }

    /// One extra console frame while fast-forwarding: advances the game without
    /// presenting or reading the screens; its audio is queued like a normal frame.
    /// runtimeQueue only. Returns false when the runtime stopped.
    private func runFastForwardFrame(system: zk_system_t,
                                     input: InputSnapshot,
                                     frameStart: UInt64) -> Bool {
        zk_set_input(system, input.buttons, input.circleX, input.circleY,
                     input.touch ? 1 : 0, input.touchX, input.touchY)
        let runStart = FrameClock.now()
        let result = zk_run_frame(system)
        timingWindow.record(.runFrame, ticks: FrameClock.now() - runStart)
        framesRendered += 1
        // Queue this extra frame's samples as well: fast-forward is audible.
        pumpAudio(system: system)
        guard result == 0 else {
            timingWindow.record(.renderTotal, ticks: FrameClock.now() - frameStart)
            return finishForRunFrameResult(result)
        }
        return true
    }

    /// Handles a non-zero `zk_run_frame` result (exit, fault, bad handle): stops
    /// the loop, releases the runtime and publishes the terminal state.
    /// runtimeQueue only; always returns false for the frame loop.
    private func finishForRunFrameResult(_ result: Int32) -> Bool {
        switch result {
        case 1:
            finishRuntime(
                message: L10n.tr("The game requested exit (zk_run_frame = 1)."),
                isError: false
            )
        case -1:
            finishRuntime(
                message: L10n.tr("Runtime fault (zk_run_frame = -1)."),
                isError: true
            )
        default:
            finishRuntime(
                message: L10n.format("Invalid runtime handle (zk_run_frame = %d).", result),
                isError: true
            )
        }
        return false
    }


    // MARK: - Graphics warm-up (runtimeQueue advances, main queue reveals)

    /// Records one completed warm-up frame and reveals the game once the run is
    /// over. Called from `renderFrame()` for every frame; a no-op when no
    /// warm-up is running. runtimeQueue only.
    ///
    /// The frame's wall time is what a hitch would be: the first-run pipeline
    /// compiles happen inside `zk_run_frame`, so a >50 ms frame is exactly the
    /// freeze the warm-up is hiding.
    private func advanceGraphicsWarmUp(frameMilliseconds: Double) {
        guard var run = warmUpRun else { return }
        let now = FrameClock.now()
        if let outcome = run.record(frameMilliseconds: frameMilliseconds, nowTicks: now) {
            warmUpRun = nil
            finishGraphicsWarmUp(run: run, outcome: outcome)
            return
        }
        warmUpRun = run
        // Progress under the overlay: a few updates a second are plenty and
        // keep the main queue free for the screens/present path.
        if run.frames % 3 == 0 {
            let status = run.status(outcome: .running)
            DispatchQueue.main.async { [weak self] in
                guard let self, case .preparing = self.phase else { return }
                self.warmUp = status
            }
        }
    }

    /// Records the outcome, logs it with the pipeline-cache state and, for
    /// `ready`/`maximumTime`/`skippedByUser`, reveals the game. runtimeQueue
    /// only.
    private func finishGraphicsWarmUp(run: GraphicsWarmUpRun, outcome: GraphicsWarmUpOutcome) {
        let status = run.status(outcome: outcome)
        let cache = PipelineCacheStats.read()
        AppLog.log("[3ds2apple] graphics warm-up: %@", status.logLine)
        AppLog.log("[3ds2apple] pipeline cache after warm-up: %@", cache.summary)
        if outcome == .maximumTime {
            AppLog.log("[3ds2apple] graphics warm-up: frames were still spiking at the %.0f s cap; revealing the game anyway",
                  run.plan.maximumSeconds)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.warmUp = status
            self.pipelineCacheStats = cache
            // Only a quiet run proves the pipelines are warm; a skipped or
            // capped run leaves the next load with the full warm-up.
            if outcome == .ready {
                GraphicsWarmUpMarker.markCompleted(romKey: run.romKey)
            }
            if case .preparing = self.phase {
                self.setPhase(.loaded(name: self.lastROM?.name ?? ""))
            }
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
            AppLog.log("[3ds2apple] zk_present failed (result %d, %d in a row)",
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
        AppLog.log("[3ds2apple] zk_read_screen(which=%u) returned %ld of %ld bytes",
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
            considerPlaybackSpeedFallback(presentedFPS: fps)
            var snapshot = FrameStats(fps: fps, frames: framesRendered, lastResult: result)
            snapshot.timing = timingWindow.publish()
            stats = snapshot

            // One `perf:` line every ~2 s for idevicesyslog; the diagnostics
            // report carries the same numbers.
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

    /// Lowers the fast-forward target when the device cannot keep up: two
    /// consecutive 0.5 s windows below `speedFloorFPS` presented frames per
    /// second step 4× down to 2× and 2× down to 1×. The fallback is one-way for
    /// the session, so a heavy scene cannot turn the menu/input unresponsive;
    /// changing the speed in Settings (or a new load) resets it.
    /// runtimeQueue only.
    private func considerPlaybackSpeedFallback(presentedFPS: Double) {
        let speed = playbackSpeedState.current
        guard speed > 1 else {
            slowPlaybackSpeedWindows = 0
            return
        }
        guard presentedFPS > 0, presentedFPS < Self.speedFloorFPS else {
            slowPlaybackSpeedWindows = 0
            return
        }
        slowPlaybackSpeedWindows += 1
        guard slowPlaybackSpeedWindows >= 2 else { return }
        slowPlaybackSpeedWindows = 0
        let reduced = speed >= 4 ? 2 : 1
        playbackSpeedState.set(reduced)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.effectivePlaybackSpeed = reduced
            self.playbackSpeedAutoReduced = true
            self.audioOutput.resetBuffer()
            AppLog.log(
                "[3ds2apple] fast-forward auto-reduced to %dx: the presented frame rate stayed below %.0f fps",
                reduced, ROMSession.speedFloorFPS
            )
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
        AppLog.log("[3ds2apple] %@", line)
    }

    /// Handles zk_run_frame exit/fault: stops the loop, releases the handle and
    /// publishes a terminal state. runtimeQueue only.
    private func finishRuntime(message: String, isError: Bool) {
        AppLog.log("[3ds2apple] frame loop ending: %@", message)
        // A warm-up cannot finish once the runtime is gone: record why instead
        // of leaving the overlay thinking it is still preparing.
        let stoppedWarmUp = warmUpRun.map { $0.status(outcome: .runtimeStopped) }
        warmUpRun = nil
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
            self.isPaused = false
            if let stoppedWarmUp, case .preparing = self.phase {
                self.warmUp = stoppedWarmUp
                AppLog.log("[3ds2apple] graphics warm-up: %@", stoppedWarmUp.logLine)
            }
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
        frameLoopDisplayLabel = "—"
        frameStats = FrameStats()
        isPaused = false
    }

    // MARK: - Audio (main queue control, runtimeQueue feeding)

    /// Starts the audio engine after a successful load. Main queue only.
    private func startAudio() {
        guard !audioOutput.isMuted else {
            audioState = .muted
            return
        }
        guard audioOutput.startEngine() else {
            audioState = .failed(L10n.tr("the audio engine could not start"))
            return
        }
        audioState = .running
    }

    /// Stops the engine and drops buffered audio. Main queue only.
    private func stopAudio() {
        audioOutput.stopEngine()
        audioState = .off
    }

    /// Mute switch, persisted by the settings page.
    func setAudioMuted(_ muted: Bool) {
        audioOutput.setMuted(muted)
        // Audio runs during the warm-up too (boot sounds belong to loading),
        // so the switch stays live in the preparing phase as well. While the
        // in-game menu has paused the session only the preference changes; the
        // engine starts again on resume.
        guard isRuntimeAudible, !isPaused else { return }
        if muted {
            audioState = .muted
        } else {
            startAudio()
        }
    }

    /// Whether the runtime is in a phase that owns the audio engine.
    private var isRuntimeAudible: Bool {
        if case .loaded = phase { return true }
        if case .preparing = phase { return true }
        return false
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

    // MARK: - ROM storage

    /// The app's Documents folder: the library keeps ROMs under roms/, the
    /// runtime writes its battery save data under data/.
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
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
        AppLog.log("[3ds2apple] ROM load failed: %@", message)
        setPhase(.failed(message: message))
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

/// Lock-protected integer preference read on the runtime queue: the free-run
/// frame cap, the fast-forward speed and the optional graphics warm-up switch.
/// The settings UI writes them on the main queue; every scheduled frame reads
/// the current value without touching the main thread.
private final class LockedIntState {
    private let lock = NSLock()
    private var value: Int

    init(initialValue: Int) {
        value = initialValue
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Int) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
