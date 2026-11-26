//
//  ROMSession.swift
//  3ds2apple
//
//  I2-T1: zk_create() wiring.
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
//  0.1.4: scene lifecycle. The inactive/background scene pauses the frame loop
//         and the audio engine but keeps the runtime, so the active scene
//         resumes the same session instead of returning to the home page. A
//         recovery snapshot is written while the app is in the background, so a
//         process the system jettisons can be resumed after the next launch.
//
//  Threading contract (ios/zakuro-ios/README.md, ios/zakuro-ios/README.md):
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

/// A catalog game that passed the AOT checks and is ready to load.
struct GameLaunch {
    /// The catalog entry being started.
    let entry: GameEntry
    /// The game data the runtime reads at load time: the ROM in
    /// Documents/Games/<TITLEID>/ for a launcher install, the bundled ROM for an
    /// app updated from the previous build, or the legacy Documents/roms file
    /// for a statically linked 0.1.x build.
    let cartridgeURL: URL
    /// Documents/data/<save namespace> (the title ID by default): the
    /// runtime's battery-save directory.
    let dataDirectory: URL
    /// Where the AOT code came from (diagnostics + status label). Both sources
    /// still end in zk_create() and the AOT-only post-create check.
    let aotStatus: AOTStatus
}

/// A user-facing message on the home page: an AOT-only launch refusal or a
/// missing-game-data hint. Dismissed with the card's Dismiss button.
struct SessionNotice: Identifiable, Equatable {
    /// How serious the message is; the home page paints the card red for an
    /// AOT-only refusal (the game did not start) and orange for a hint.
    enum Severity: Equatable {
        case warning
        case error
    }

    let id: UUID
    let title: String
    let message: String
    var severity: Severity = .warning
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
    /// Rolling stutter counts and the recent spike events (recorded for
    /// diagnostics; see `StutterTracker`).
    var stutter = StutterSnapshot()
}

/// The AOT state of the running session. The shell only ever starts a game
/// whose AOT code this build contains: there is no interpreter fallback, so a
/// title that is not executing AOT code is stopped instead of reported.
enum AOTStatus: String {
    case notLoaded = "AOT not loaded"
    case staticLinked = "AOT · linked"
    case package = "AOT · package"

    /// Stable English label for the device log and the diagnostics report.
    var label: String { rawValue }

    /// Localized label for the About page and diagnostics.
    var title: String { L10n.tr(rawValue) }
}

/// What the AOT checks reported for the loaded game: the build-level linked
/// code, the per-handle recompiled flag, the runtime's reason text and the
/// pack/catalog path. Logged on every load and exported in diagnostics, so a
/// device run proves whether the game really executed AOT code (the shell never
/// falls back to the interpreter).
struct AOTDiagnostics: Equatable {
    /// zk_linked_code(): 1 when this build carries linked AOT code at all.
    var linkedCode: Bool = false
    /// zk_linked_program_id(): title the linked code is for, 0 when none.
    var linkedProgramID: UInt64 = 0
    /// zk_recompiled(handle): 1 when the loaded system runs AOT code.
    var recompiled: Bool = false
    /// zk_recompiled_status(handle): why recompiled is false, and how much of
    /// the work is still interpreted when a title mixes AOT and interpreted
    /// code.
    var status: String = ""
    /// GamePack path registered with the runtime (bundle-relative), "static
    /// linked" for the single-game build, empty when none was registered.
    var packPath: String = ""
    /// zk_registered_gamepack_title_id(): title in the runtime's pack slot.
    var registeredTitleID: UInt64 = 0

    /// Interpreted share of executed instructions the runtime reported in
    /// `status` ("interpreted 0.21% of N instructions"). Nil when the text does
    /// not carry the figure (refusal reason, interpreter-only runtime, ...), so
    /// the badge and diagnostics can say "unknown" instead of inventing 0%.
    var interpretedPercent: Double? {
        guard let range = status.range(of: "interpreted ") else { return nil }
        let rest = status[range.upperBound...]
        guard let end = rest.firstIndex(of: "%") else { return nil }
        return Double(String(rest[..<end]).trimmingCharacters(in: .whitespaces))
    }

    /// Share of executed guest instructions that ran as AOT code
    /// (100 - interpreted), nil when the runtime text has no percentage.
    var aotPercent: Double? {
        interpretedPercent.map { min(100, max(0, 100 - $0)) }
    }

    /// Instruction fallbacks the runtime reported ("N instruction fallbacks"),
    /// nil when the text has no count. This is the interpreter work inside the
    /// linked code; the AOT percentage already includes it.
    var instructionFallbacks: Int? {
        guard let range = status.range(of: " instruction fallbacks") else { return nil }
        let head = status[..<range.lowerBound]
        guard let space = head.lastIndex(of: " ") else { return nil }
        return Int(head[head.index(after: space)...])
    }

    /// Stable English line for the device log and diagnostics.
    var label: String {
        "linked_code=\(linkedCode ? 1 : 0)"
            + " linked_program=\(String(format: "%016llX", linkedProgramID))"
            + " recompiled=\(recompiled ? 1 : 0)"
            + " registered_pack=\(String(format: "%016llX", registeredTitleID))"
            + " pack=\(packPath.isEmpty ? "none" : packPath)"
            + " status=\(status.isEmpty ? "-" : status)"
    }
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

/// Owns the Zakuro runtime handle, the AOT game launch pipeline and the frame loop.
final class ROMSession: ObservableObject, SaveStateRuntime {
    enum Phase: Equatable {
        /// Nothing loaded yet.
        case idle
        /// zk_create() is running on the runtime queue.
        case starting(name: String)
        /// Legacy warm-up phase: zk_create() succeeded while the first-load
        /// warm-up ran. Unreachable since 0.1.1 (the warm-up option was
        /// removed); kept so the phase plumbing stays compatible.
        case preparing(name: String)
        /// zk_create() succeeded and a handle is alive.
        case loaded(name: String)
        /// Import or load failed; `message` is user-readable.
        case failed(message: String)
        /// The frame loop stopped after zk_run_frame reported a clean exit.
        case finished(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The catalog game of this session: the game being loaded, loaded, or
    /// the last one started (nil before the first launch).
    @Published private(set) var currentGame: GameEntry? = nil
    /// A user-facing refusal/hint shown on the home page (AOT-only launches).
    @Published private(set) var notice: SessionNotice? = nil
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
    /// AOT state for the About page and diagnostics.
    @Published private(set) var aotStatus: AOTStatus = .notLoaded
    /// Active frame-loop driver (`free-run · cap 60 fps` or
    /// `CADisplayLink · 60 Hz`). Stable English for logs and diagnostics.
    @Published private(set) var frameLoopLabel: String = "—"
    /// Localized copy of `frameLoopLabel` for the status line and About page.
    @Published private(set) var frameLoopDisplayLabel: String = "—"
    /// Fast-forward the frame loop is actually using: the setting from
    /// Settings, possibly reduced by the automatic fallback when frames take
    /// too long (`playbackSpeedAutoReduced`).
    @Published private(set) var effectivePlaybackSpeed: Int = 1
    /// True while the runtime ignores the 1×–4× clamp and runs guest frames
    /// until the per-present time budget is used (Run speed limit off, or
    /// Turbo limit off while the Turbo button is active).
    @Published private(set) var isUnlimitedSpeedActive = false
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
    /// Removed first-run graphics warm-up state, kept for the unreachable
    /// GraphicsWarmUp plumbing (diagnostics report it as disabled).
    @Published private(set) var warmUp = GraphicsWarmUpStatus()
    /// Latest `zk_hardware_status()` text: whether the 3D draws on the host GPU
    /// via Vulkan (MoltenVK) and how the screens are presented; shown in
    /// diagnostics next to the warm-up/cache state.
    @Published private(set) var hardwareStatus: String = "—"
    /// True after the guest-PC sampling profiler started on the current runtime
    /// handle (CPUProfilerView). Sampling is cumulative and cannot be stopped;
    /// a new game load resets it. Main queue only.
    @Published private(set) var cpuProfilerStarted = false
    /// AOT checks of the last load (linked code, recompiled flag, runtime status
    /// text and the pack that was registered). Shown in About and exported in
    /// diagnostics; a refusal publishes it too, so the log and UI agree.
    @Published private(set) var aotDiagnostics = AOTDiagnostics()
    /// Pipeline-cache files seen at the last check (load, warm-up end,
    /// unload/background). Used to tell a cold first run from a warmed one and
    /// exported in diagnostics.
    @Published private(set) var pipelineCacheStats = PipelineCacheStats.empty
    /// Pipeline-cache files seen when the current load started: the cold/warm
    /// state its first frames ran with. A hitch at a scene's first use is
    /// compared against this (warm cache = cache hit instead of a compile).
    @Published private(set) var pipelineCacheAtLoad = PipelineCacheStats.empty
    /// Emulation is paused (in-game menu open, or the user paused): the frame
    /// loop and the audio engine are stopped, the runtime handle stays.
    @Published private(set) var isPaused = false
    /// The open 3DS software-keyboard request, nil when none: the game view
    /// shows the keyboard overlay while it is set. The title waits on the
    /// applet, so the frame loop is stopped until it is answered. Published on
    /// the main queue; the request is polled on the runtime queue.
    @Published private(set) var keyboardRequest: KeyboardRequest?
    /// Instant save slots of the current game (SaveStateSupport.swift). Created
    /// on first use; the runtime itself is passed weakly, so the session owns
    /// the support object and not the other way around.
    private(set) lazy var saveStates: SaveStateSupport = SaveStateSupport(runtime: self)
    /// Screen arrangement chosen in Settings. Applied live: the Metal view's
    /// drawable is resized and the presenter is told the new layout, so the next
    /// frame shows it. Every layout goes through the CAMetalLayer presenter; the
    /// readback path is only used when no presenter can be made.
    private(set) var screenLayout: ScreenLayout = .stacked

    /// The custom layout rectangles the presenter is configured with when the
    /// active layout is `.custom` (round 0.1.6). Updated from the game view like
    /// the layout preset; the presenter receives aspect-fitted normalised
    /// viewports when a custom presenter is configured.
    private var customScreenPlacement: CustomScreenPlacement?

    /// The on-screen Swap screens button's persisted setting (0.1.6-beta2).
    private var screenSwapped = false
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
    /// 1 = Run speed limit on (1×–4×), 0 = unlimited guest frames.
    private let runSpeedLimitState = LockedIntState(initialValue: 1)
    /// 1 = Turbo is running without a speed cap (Turbo limit off).
    private let turboUnlimitedState = LockedIntState(initialValue: 0)
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
    /// Called on the main thread when a physical hotkey combination fires.
    /// GameView installs the action handler while it is visible.
    var onHotkey: ((HotkeyAction) -> Void)?

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
    private var turboLimitEnabled = true
    /// The player's Save-audio mute choice, kept apart from the temporary mute
    /// used while unlimited speed is active.
    private var userAudioMuted = false
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
    /// FrameClock tick the previous frame started at, for the frame-interval
    /// phase (start to start, what the player sees). runtimeQueue only.
    private var lastFrameStartTicks: UInt64 = 0
    /// Throttles the periodic `perf:` NSLog line (every 2 s).
    private var lastPerfLogTicks: UInt64 = 0
    private var didLogScreenReadFailure = false
    /// Per-phase frame timings; runtimeQueue only, published as snapshots.
    private var timingWindow = FrameTimingWindow()
    /// Rolling stutter statistics; runtimeQueue only, published in FrameStats.
    private var stutterTracker = StutterTracker()
    /// Wall-clock pauses of the frame loop (in-game menu, save-state operation,
    /// software keyboard, scene transition). The pause control points record
    /// them on the main queue; the first frame after a resume excludes the
    /// paused interval from the FPS window, the start-to-start baseline and the
    /// stutter statistics (`applyPendingPauseResume`). Thread-safe.
    private let framePauseClock = FramePauseClock()
    /// True while the scene-phase pause (`pauseForInactiveScene`) holds the
    /// loop; main queue only. Kept apart from `isPaused` (the in-game menu) so
    /// returning to the app only resumes what the scene pause stopped.
    private var scenePauseActive = false
    /// True between the move to the background and the return to the active
    /// scene (0.1.4): the runtime is kept, the frame loop and audio are stopped,
    /// and the scene pause resumes the session instead of unloading it. Main
    /// queue only.
    private var backgroundSuspended = false
    /// Recovery snapshot the home page can offer after a cold launch, nil when
    /// there is none. Read at launch and refreshed after a library change.
    @Published private(set) var backgroundSnapshot: BackgroundSnapshot?
    /// Recovery snapshot the user asked to restore; applied once the runtime is
    /// loaded. Main queue only.
    private var pendingBackgroundSnapshot: BackgroundSnapshot?
    /// Generation guard for an in-flight snapshot write: the return to the
    /// foreground makes the write stale. Main queue only.
    private var backgroundSnapshotGeneration: UInt64 = 0
    /// Generation of the snapshot write in flight, nil when none is running.
    /// Main queue only.
    private var backgroundSnapshotInFlight: UInt64?
    /// UIKit background-task id that keeps the snapshot write alive after the
    /// scene backgrounded. Main queue only.
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Paused wall time excluded from the frame statistics (diagnostics header).
    var framePauseStats: FramePauseStats { framePauseClock.snapshot() }
    /// True while a software-keyboard request is open and the frame loop must not
    /// run: the title is waiting on the applet, so further frames would only burn
    /// CPU (the desktop frontend stops emulating while it types for the same
    /// reason). Written on the runtime queue, read by the CADisplayLink fallback.
    private let keyboardPauseState = LockedFlagState()
    /// Whether the runtime queue last saw an open applet request, so a request is
    /// published once instead of on every polled frame. runtimeQueue only.
    private var keyboardRequestPending = false
    /// Reusable RGBA8 buffers for zk_read_screen + CGImage presentation.
    private let screenBufferPool = ScreenFrameBufferPool()
    /// The warm-up running behind the loading overlay, nil when the game is
    /// already revealed. runtimeQueue only; `warmUp` is its main-queue copy.
    private var warmUpRun: GraphicsWarmUpRun?

    init() {
        // The catalog decides what exists; log it once like the old shell logged
        // the ROMs it had imported.
        AppLog.log("[3ds2apple] game library: %ld game(s)", GameLibrary.shared.entries.count)
        // The in-game Cheats page reads/toggles the runtime's list through
        // CheatRuntime; its handlers run the runtime queue (see the block below).
        configureCheatRuntime()
        // A recovery snapshot left by a session the system jettisoned while in
        // the background: the home page offers to continue it.
        backgroundSnapshot = SaveStateSupport.pendingBackgroundSnapshot()
        if let snapshot = backgroundSnapshot {
            AppLog.log(
                "[3ds2apple] background snapshot: offering to resume %@ (%@, captured %@)",
                snapshot.titleID,
                StorageFormat.size(snapshot.bytes),
                StorageFormat.date(snapshot.capturedAt)
            )
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

    /// Starts a game from the library. The shell only runs AOT code and only
    /// starts a game whose pushed game data validated: a game without AOT code,
    /// game data that is missing or still being pushed (size/SHA-256 mismatch)
    /// or a broken pack is refused with a clear per-game notice instead of
    /// falling back to the interpreter.
    func start(_ entry: GameEntry) {
        guard !isRuntimeActive else { return }
        let latest = GameLibrary.shared.entry(titleID: entry.titleID) ?? entry
        // Starting a game fresh replaces the interrupted session the home page
        // offered to resume, so its recovery snapshot is stale from here. (The
        // explicit Resume path clears `backgroundSnapshot` before calling this,
        // so it never reaches this branch.)
        if let snapshot = backgroundSnapshot, snapshot.titleID == latest.titleID {
            backgroundSnapshot = nil
            pendingBackgroundSnapshot = nil
            discardBackgroundSnapshot(foregroundReturn: false)
        }
        switch latest.validation {
        case .invalid(let issues):
            presentInstallationProblem(for: latest, issues: issues)
        case .checking:
            // The launcher recorded SHA-256 hashes and the check is still
            // running: wait for it, then start (or explain), so a tap right
            // after launch does not silently do nothing.
            GameLibrary.shared.ensureVerified(titleID: latest.titleID) { [weak self] state in
                guard let self else { return }
                let current = GameLibrary.shared.entry(titleID: latest.titleID) ?? latest
                switch state {
                case .valid:
                    self.startValidated(current)
                case .invalid(let issues):
                    self.presentInstallationProblem(for: current, issues: issues)
                case .checking:
                    self.presentNotice(
                        title: L10n.tr("Checking game files"),
                        message: L10n.tr("This game's files are still being checked. Try again when the check finishes.")
                    )
                }
            }
        case .valid:
            startValidated(latest)
        }
    }

    /// The AOT gate for a game whose pushed game data passed its checks. A game
    /// is only started from its bundle pack (the catalog lists it) or from
    /// statically linked AOT code; the GamePack registration path is the same in
    /// both cases.
    private func startValidated(_ entry: GameEntry) {
        switch AOTPackageLoader.shared.availability(for: entry) {
        case .unavailable(let reason):
            AppLog.log(
                "[3ds2apple] AOT gate: %@ (%@) is not runnable in this build: %@",
                entry.title,
                entry.titleID,
                reason.localizedMessage
            )
            presentNoAOTNotice(for: entry, reason: reason)
        case .available(.bundlePackage(_)):
            switch AOTPackageLoader.shared.resolve(for: entry) {
            case .package(let package):
                // The pack is dlopen()ed and its AOT tables are registered with
                // the runtime; the game data comes from the same install (see
                // startPackaged).
                AppLog.log(
                    "[3ds2apple] game package ready: %@ (title %@, registered: %@)",
                    package.path,
                    package.titleID,
                    package.registrationSymbol ?? "no"
                )
                startPackaged(entry)
            case .unavailable(let reason):
                presentNoAOTNotice(for: entry, reason: reason)
            case .staticLinked:
                startStaticallyLinked(entry)
            }
        case .available(.staticLinked):
            startStaticallyLinked(entry)
        }
    }

    /// Loads the game whose recompiled code is linked into this binary (the
    /// 0.1.x single-game IPA shape). The cartridge image comes from the old
    /// Documents/roms library; the save folders are moved to the title-id
    /// namespace first.
    private func startStaticallyLinked(_ entry: GameEntry) {
        guard let cartridgeURL = LegacyGameData.cartridgeURL(forTitleID: entry.titleID) else {
            presentNotice(
                title: L10n.tr("Game data missing"),
                message: L10n.format(
                    "This build contains the AOT code for “%@”, but its game data is not in this app any more. Reinstall the game build from your computer, or build it again with the desktop app.",
                    entry.title
                )
            )
            return
        }
        LegacyGameData.migrateSaveDirectories(
            titleID: entry.titleID,
            legacyFileName: cartridgeURL.lastPathComponent
        )
        startLaunch(entry: entry, cartridgeURL: cartridgeURL, aotStatus: .staticLinked)
    }

    /// Loads a game from its pack: the AOT code comes from the signed bundle
    /// GamePack dylib (already loaded and registered by AOTPackageLoader) and
    /// the game data is the ROM pushed into Documents/Games/<TITLEID>/ (or the
    /// bundled ROM of an app updated from the previous self-contained build).
    /// Nothing is imported or copied on the device.
    private func startPackaged(_ entry: GameEntry) {
        guard let cartridgeURL = AOTPackageLoader.launchROMURL(for: entry) else {
            if entry.hasPushedData {
                presentNotice(
                    title: L10n.tr("Game data missing"),
                    message: L10n.format(
                        "The pushed game data of “%@” cannot be read any more. Push it again with the desktop launcher.",
                        entry.title
                    )
                )
            } else {
                presentNotice(
                    title: L10n.tr("Game data missing"),
                    message: L10n.format(
                        "The launcher has not pushed the game data of “%@” yet. Install the build from the desktop launcher, then let it push the game's data into Documents/Games/%@.",
                        entry.title,
                        entry.titleID
                    )
                )
            }
            return
        }
        AppLog.log("[3ds2apple] starting %@ from %@", entry.title, cartridgeURL.path)
        startLaunch(entry: entry, cartridgeURL: cartridgeURL, aotStatus: .package)
    }

    /// Shared launch path for every AOT code source: publish the game, reset the
    /// runtime state, then load on the runtime queue. Save data is namespaced by
    /// the launcher's save namespace (the title ID by default) whichever way the
    /// game data arrived.
    private func startLaunch(entry: GameEntry, cartridgeURL: URL, aotStatus: AOTStatus) {
        let dataDirectory = documentsDirectory
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(
                SaveDataStore.directoryName(forNamespace: entry.saveNamespace),
                isDirectory: true
            )

        GameLibrary.shared.markPlayed(titleID: entry.titleID)
        let game = GameLibrary.shared.entry(titleID: entry.titleID) ?? entry
        currentGame = game
        // A new load starts from the file again; the launch below publishes the
        // loaded cheats once the runtime handle exists.
        CheatRuntime.shared.reset()
        notice = nil
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        isPaused = false
        warmUp = GraphicsWarmUpStatus()
        setPhase(.starting(name: game.title))
        let launch = GameLaunch(
            entry: game,
            cartridgeURL: cartridgeURL,
            dataDirectory: dataDirectory,
            aotStatus: aotStatus
        )
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.beginLoad(launch)
        }
    }

    /// Shows the per-game state of a pushed game's data: not pushed yet, which
    /// file is missing, or the size/SHA-256 mismatch, and what to do about it.
    func presentInstallationProblem(for entry: GameEntry, issues: [GameValidationIssue]) {
        guard !issues.isEmpty else { return }
        // The resume of an interrupted session cannot continue without the game
        // data: drop the pending restore (the snapshot file stays, so a later
        // launch can still offer it).
        pendingBackgroundSnapshot = nil
        let hasMissingData = issues.contains { issue in
            if case .gameDataMissing = issue { return true }
            return false
        }
        if hasMissingData && issues.count == 1 {
            // The normal pre-push state: the AOT pack is installed but the
            // launcher has not pushed the game data yet. This is not an error.
            presentNotice(
                title: L10n.tr("Game data missing"),
                message: L10n.format(
                    "The launcher has not pushed the game data of “%@” yet. Install the build from the desktop launcher, then let it push the game's data into Documents/Games/%@.",
                    entry.title,
                    entry.titleID
                )
            )
            return
        }
        let detail = issues.map { "• " + $0.localizedMessage }.joined(separator: "\n")
        presentNotice(
            title: L10n.tr("This game cannot be started"),
            message: "\(entry.title)\n\n\(detail)",
            severity: .error
        )
    }

    /// Shows the "No AOT build for this game" state on the home page (red: the
    /// game cannot run in this build).
    func presentNoAOTNotice(for entry: GameEntry, reason: AOTUnavailableReason) {
        presentNotice(
            title: L10n.tr("No AOT build for this game"),
            message: L10n.format("%@ — %@", entry.title, reason.localizedMessage),
            severity: .error
        )
    }

    /// Publishes one dismissible notice on the home page. `severity` is what
    /// the home page uses to paint an AOT-only refusal red.
    func presentNotice(title: String, message: String, severity: SessionNotice.Severity = .warning) {
        let notice = SessionNotice(id: UUID(), title: title, message: message, severity: severity)
        if Thread.isMainThread {
            self.notice = notice
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.notice = notice
            }
        }
        AppLog.log("[3ds2apple] notice: %@ — %@", title, message)
    }

    /// Publishes an AOT-only refusal that arrives from the runtime queue. Call
    /// it on the main queue (startRuntime hops there first).
    func presentNoAOTMessage(_ message: String) {
        currentGame = nil
        aotStatus = .notLoaded
        pendingBackgroundSnapshot = nil
        presentNotice(
            title: L10n.tr("No AOT build for this game"),
            message: message,
            severity: .error
        )
        setPhase(.idle)
    }

    /// Releases the runtime handle and returns to the home page. The game stays
    /// selected so its save data can still be managed from the Save Manager.
    /// `completion` runs on the main queue once the handle is destroyed, so a
    /// caller (the delete-game path) can remove the ROM file safely.
    func unload(completion: (() -> Void)? = nil) {
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        isPaused = false
        // An explicit exit ends the interrupted session too: its recovery
        // snapshot must not be offered again.
        backgroundSuspended = false
        pendingBackgroundSnapshot = nil
        discardBackgroundSnapshot(foregroundReturn: false)
        runtimeQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            self.destroySystem()
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                self.clearScreens()
                self.warmUp = GraphicsWarmUpStatus()
                self.aotStatus = .notLoaded
                CheatRuntime.shared.reset()
                self.setPhase(.idle)
                completion?()
            }
        }
    }

    // MARK: - Cheat codes (0.2.2; runtimeQueue owns the handle)

    /// Installs the in-game Cheats bridge. Main queue (init): both handlers hop
    /// to `runtimeQueue`, because every zk_cheats_* call takes the live handle
    /// and must run on the queue that owns it. The file path is the one the
    /// game load published (Documents/Cheats/<TITLEID>.txt, CheatManager).
    private func configureCheatRuntime() {
        CheatRuntime.shared.reloadHandler = { [weak self] titleID, path, completion in
            guard let self else {
                completion(.none)
                return
            }
            self.runtimeQueue.async { [weak self] in
                guard let self else {
                    DispatchQueue.main.async { completion(.none) }
                    return
                }
                let snapshot = CheatBridge.snapshot(system: self.system,
                                                   titleID: titleID,
                                                   path: path)
                DispatchQueue.main.async { completion(snapshot) }
            }
        }
        CheatRuntime.shared.toggleHandler = { [weak self] titleID, path, index, enabled, completion in
            guard let self else {
                DispatchQueue.main.async { completion(nil, L10n.tr("The game is not running.")) }
                return
            }
            self.runtimeQueue.async { [weak self] in
                guard let self else {
                    DispatchQueue.main.async { completion(nil, L10n.tr("The game is not running.")) }
                    return
                }
                let error = CheatBridge.setEnabled(system: self.system,
                                                  path: path,
                                                  index: index,
                                                  enabled: enabled)
                let snapshot = CheatBridge.snapshot(system: self.system,
                                                   titleID: titleID,
                                                   path: path)
                DispatchQueue.main.async { completion(snapshot, error) }
            }
        }
    }

    /// Pauses the session when the app moves to the background (0.1.4).
    ///
    /// The runtime handle is kept. iOS suspends a backgrounded process in the
    /// normal case, and returning to the active scene continues the same console
    /// where it stopped. The frame loop and the audio engine are stopped right
    /// away so no frame runs while the system suspends the process, and the
    /// suspended wall time is excluded from the frame statistics. A recovery
    /// snapshot is written for the case where the system does jettison the
    /// process (`SaveStateSupport.captureBackgroundSnapshot`).
    func suspendForBackground() {
        guard !backgroundSuspended else { return }
        backgroundSuspended = true
        // Open the pause exactly once. iOS sends .inactive before .background,
        // so the scene pause usually already owns it; a game paused by its own
        // in-game menu keeps that pause (its resume path owns it).
        if !scenePauseActive {
            scenePauseActive = true
            framePauseClock.pause(at: FrameClock.now())
        }
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        switch phase {
        case .loaded:
            AppLog.log("[3ds2apple] scene background: paused (frame loop and audio stopped, runtime kept)")
            requestBackgroundSnapshot()
        case .starting, .preparing:
            AppLog.log("[3ds2apple] scene background: load in progress; the loop starts when the app returns")
        case .idle, .failed, .finished:
            AppLog.log("[3ds2apple] scene background: no running session")
        }
    }

    /// Ends the running graphics warm-up at the next frame. Unreachable since
    /// 0.1.1 (the warm-up option and its overlay were removed); kept with the
    /// warm-up plumbing.
    func skipGraphicsWarmUp() {
        guard case .preparing = phase else { return }
        AppLog.log("[3ds2apple] graphics warm-up: skip requested by the user")
        runtimeQueue.async { [weak self] in
            self?.warmUpRun?.skipRequested = true
        }
    }

    /// Clears the home-page notice or a failure/finished state without
    /// touching a loaded runtime.
    func dismissNotice() {
        if notice != nil {
            notice = nil
            return
        }
        if case .failed = phase {
            setPhase(.idle)
        } else if case .finished = phase {
            setPhase(.idle)
        }
    }

    // MARK: - Input (main queue)

    /// Attaches the hardware-controller bridge. Safe to call repeatedly; only
    /// the first call starts it. The view calls this from `onAppear`.
    func startControllerSupport(deadzone: Double = 0.14,
                                buttonMap: [String: String] = AppSettings.defaultControllerButtonMap,
                                hotkeyMap: [String: [String]] = [:]) {
        guard controllerManager == nil else { return }
        let manager = GameControllerManager(
            input: inputState,
            onHotkey: { [weak self] action in
                self?.onHotkey?(action)
            },
            onConnectionChange: { [weak self] name in
                DispatchQueue.main.async {
                    self?.controllerName = name
                }
            }
        )
        manager.setDeadzone(deadzone)
        manager.setButtonMap(buttonMap)
        manager.setHotkeyMap(hotkeyMap)
        controllerManager = manager
        manager.start()
    }

    /// Gamepad page Deadzone slider (also used by the per-app profile).
    func setControllerDeadzone(_ value: Double) {
        controllerManager?.setDeadzone(value)
    }

    /// Gamepad page physical-button remapping (also used by the per-app profile).
    func setControllerButtonMap(_ map: [String: String]) {
        controllerManager?.setButtonMap(map)
    }

    /// Hotkeys page: physical 2–4 button combinations.
    func setControllerHotkeys(_ map: [String: [String]]) {
        controllerManager?.setHotkeyMap(map)
    }

    /// Hotkey recorder sheet: receives every physical button state while open.
    func beginControllerHotkeyRecording(_ handler: @escaping ([PhysicalControllerButton]) -> Void) {
        controllerManager?.beginRecording(handler)
    }

    func endControllerHotkeyRecording() {
        controllerManager?.endRecording()
    }

    /// On-screen button press/release.
    func setOverlayButton(_ bit: UInt32, pressed: Bool) {
        inputState.setOverlayButton(bit, pressed: pressed)
    }

    /// On-screen Circle Pad vector, -1.0 ... 1.0 (0,0 when released). Analog:
    /// this is what analog movement in 3DS games reads, not the D-pad bits.
    func setOverlayStick(x: Float, y: Float) {
        inputState.setOverlayStick(x: x, y: y)
    }

    /// On-screen New 3DS C-stick vector, -1.0 ... 1.0 (0,0 when released). It
    /// is pushed with zk_set_cstick() immediately before each console frame.
    func setOverlayCStick(x: Float, y: Float) {
        inputState.setOverlayCStick(x: x, y: y)
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
        case .idle, .failed, .finished: return false
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

    /// Records the custom rectangles for the current device direction. Callers
    /// set this before a load so a custom presenter gets its viewports, and on
    /// every custom-layout edit/rotation change while running.
    /// Applies the Swap screens button to the presenter immediately; the
    /// readback fallback swaps the images in GameView.
    func setScreenSwap(_ swapped: Bool) {
        guard swapped != screenSwapped else { return }
        screenSwapped = swapped
        AppLog.log("[3ds2apple] screen swap: %@", swapped ? "on" : "off")
        applyPresentedGeometry()
    }

    func setCustomScreenPlacement(_ placement: CustomScreenPlacement) {
        guard placement != customScreenPlacement else { return }
        customScreenPlacement = placement
        applyPresentedGeometry()
    }

    /// The normalised viewports for a drawable of `size`, or nil while no custom
    /// placement has been recorded.
    private func customPresenterViewports(for size: CGSize) -> (top: CGRect, bottom: CGRect)? {
        guard let placement = customScreenPlacement, size.width >= 1, size.height >= 1 else {
            return nil
        }
        return CustomScreenGeometry.presenterNormalisedViewports(available: size,
                                                                placement: placement)
    }

    /// Configures a presenter already set to layout 8 with the custom rects.
    /// Returns false and logs when no placement/viewports are available.
    @discardableResult
    private func applyCustomPresenterGeometry(_ handle: UnsafeMutableRawPointer,
                                              size: CGSize) -> Bool {
        guard let viewports = customPresenterViewports(for: size) else {
            AppLog.log("[3ds2apple] custom screen layout: no placement for the presenter")
            return false
        }
        let result = zk_presenter_set_custom_viewports(
            handle,
            Float(viewports.top.minX), Float(viewports.top.minY),
            Float(viewports.top.width), Float(viewports.top.height),
            Float(viewports.bottom.minX), Float(viewports.bottom.minY),
            Float(viewports.bottom.width), Float(viewports.bottom.height)
        )
        if result != 1 {
            AppLog.log("[3ds2apple] zk_presenter_set_custom_viewports failed (result %d): %@",
                       result, Self.currentRuntimeError())
            return false
        }
        return true
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
    /// The General page's Run speed limit switch. Off runs guest frames until
    /// the 60 Hz presentation budget is spent instead of clamping at 4×; the
    /// Turbo button has no extra effect in that mode (matching the reference
    /// emulator) and audio stays muted.
    func setRunSpeedLimitEnabled(_ enabled: Bool) {
        runSpeedLimitState.set(enabled ? 1 : 0)
        slowPlaybackSpeedWindows = 0
        if !enabled {
            turboUnlimitedState.set(0)
            audioOutput.resetBuffer()
        }
        refreshUnlimitedState()
        if enabled {
            // Restore the requested speed from Settings after the unlimited run.
            playbackSpeedState.set(requestedPlaybackSpeed)
            effectivePlaybackSpeed = requestedPlaybackSpeed
        }
        AppLog.log("[3ds2apple] run speed limit: %@", enabled ? "on" : "off (unlimited)")
    }

    /// Turbo limit off: while the Turbo button is active, run unlimited guest
    /// frames instead of the configured Turbo speed.
    func setTurboUnlimited(_ unlimited: Bool) {
        turboUnlimitedState.set(unlimited ? 1 : 0)
        if unlimited {
            audioOutput.resetBuffer()
        } else {
            playbackSpeedState.set(requestedPlaybackSpeed)
            effectivePlaybackSpeed = requestedPlaybackSpeed
        }
        refreshUnlimitedState()
        AppLog.log("[3ds2apple] turbo limit: %@", unlimited ? "off (unlimited turbo)" : "on")
    }

    private func refreshUnlimitedState() {
        let active = isUnlimitedSpeed
        playbackSpeedAutoReduced = false
        slowPlaybackSpeedWindows = 0
        isUnlimitedSpeedActive = active
        applyEffectiveAudioMute()
    }

    private var isUnlimitedSpeed: Bool {
        runSpeedLimitState.current == 0 || turboUnlimitedState.current != 0
    }

    func setPlaybackSpeed(_ speed: Int) {
        let clamped = speed >= 4 ? 4 : (speed >= 3 ? 3 : (speed >= 2 ? 2 : 1))
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

    /// Speed shown by the in-game performance overlay: the effective playback
    /// multiplier, or "Max" while the unlimited run-speed mode is active.
    var performanceSpeedText: String {
        if isUnlimitedSpeedActive { return "Max" }
        let percent = max(1, effectivePlaybackSpeed) * 100
        return "\(percent)%"
    }

    /// Whether the automatic Turbo fallback may lower a fast speed (General
    /// page's "Turbo limit"). Off keeps the requested speed even if the device
    /// cannot present it at 20 fps.
    func setTurboLimitEnabled(_ enabled: Bool) {
        turboLimitEnabled = enabled
        if !enabled {
            slowPlaybackSpeedWindows = 0
        }
    }

    // MARK: - System Metal HUD (main queue)

    /// Shows or hides the system Metal Performance HUD on the presented layer.
    /// Applies immediately when the layer exists and is re-applied whenever the
    /// Metal view is (re)used, so the choice survives menu navigation and a
    /// reloads. The readback path has no CAMetalLayer, so the setting only
    /// matters there once a presented load runs.
    func setSystemMetalHUD(_ enabled: Bool) {
        systemMetalHUDEnabled = enabled
        if let view = metalScreenView {
            view.applySystemMetalHUD(enabled: enabled)
        }
        AppLog.log("[3ds2apple] system Metal HUD: %@", enabled ? "on" : "off")
    }

    /// Whether the Settings switch asks for the system Metal HUD (the badge and
    /// the Settings page read this; the layer property is applied when the Metal
    /// view exists).
    var isSystemMetalHUDEnabled: Bool { systemMetalHUDEnabled }

    /// Presented frames per second for the in-game FPS readout, e.g. `59 fps`.
    /// This is the only performance text the game view draws; the AOT state, the
    /// renderer path and the CPU/present/read timings stay in the log and the
    /// diagnostics export.
    var fpsText: String {
        let loaded: Bool
        if case .loaded = phase { loaded = true } else { loaded = false }
        if loaded, frameStats.frames > 0 {
            return String(format: "%.0f fps", frameStats.fps)
        }
        return L10n.tr("fps …")
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

    /// Render resolution factor (1...4). The Metal drawable and the presenter
    /// geometry use the new factor at once; the runtime's internal 3D render
    /// scale is process-wide and only read when a system loads, so a game that is
    /// already loaded keeps its internal resolution until it is reloaded or
    /// restarted (see zk_set_render_scale in ios/ZakuroBridge.h).
    func applyRenderScale(_ scale: CGFloat) {
        let factor = min(max(Int(scale.rounded()), 1), 4)
        requestedRenderScale = CGFloat(factor)
        // A diagnostic profile can ask the internal 3D renderer for another
        // factor than the drawable's (the 2x3x profile draws the 3D at 2x and
        // presents at 3x) to measure how much of the GPU time is fill. A
        // release build has no such variable and uses the setting for both.
        var internalScale = factor
        if let override = MoltenVKTuning.diagnosticRenderScale {
            internalScale = min(max(override, 1), 4)
        }
        // The value is read while a system loads, and loads run on the runtime
        // queue: queue the write there so it can never race a load.
        runtimeQueue.async {
            let result = zk_set_render_scale(UInt32(internalScale))
            if result != 0 {
                AppLog.log("[3ds2apple] zk_set_render_scale(%d) failed: %@",
                      internalScale, Self.currentRuntimeError())
            }
        }
        applyPresentedGeometry()
        AppLog.log(
            "[3ds2apple] render scale: %dx drawable · internal 3D renderer %dx applies on the next load",
            factor, internalScale
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
        let customViewports = layout == 8 ? customPresenterViewports(for: size) : nil
        runtimeQueue.async { [weak self] in
            // Only a system mid-presentation needs the live change; a load that
            // is about to start gets the layout from presenterForLoadOnMain.
            guard let self, self.framePresenter != nil else { return }
            _ = zk_presenter_set_layout(presenter, layout)
            _ = zk_presenter_set_orientation(presenter, rotation)
            _ = zk_presenter_resize(presenter, width, height)
            _ = zk_presenter_set_screen_swap(presenter, screenSwapped ? 1 : 0)
            if layout == 8 {
                _ = zk_presenter_set_custom_rotation(presenter, rotation)
            }
            if let customViewports {
                _ = zk_presenter_set_custom_viewports(
                    presenter,
                    Float(customViewports.top.minX), Float(customViewports.top.minY),
                    Float(customViewports.top.width), Float(customViewports.top.height),
                    Float(customViewports.bottom.minX), Float(customViewports.bottom.minY),
                    Float(customViewports.bottom.width), Float(customViewports.bottom.height)
                )
            }
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
    /// session without re-loading the game.
    func pauseForMenu() {
        guard !isPaused, case .loaded = phase else { return }
        isPaused = true
        inputState.clearAll()
        // The menu can stay open for minutes; record the pause so the frame
        // statistics exclude it (the restart on resume resets every baseline).
        framePauseClock.pause(at: FrameClock.now())
        stopFrameLoop()
        stopAudio()
        AppLog.log("[3ds2apple] runtime paused")
    }

    /// Continues a session paused by `pauseForMenu()`.
    func resumeFromMenu() {
        guard isPaused else { return }
        // Nothing runs while the app is in the background; the menu's resume
        // takes effect on the return to the active scene.
        guard !backgroundSuspended else { return }
        isPaused = false
        // Close the recorded pause before the loop is restarted: the restart
        // resets every timing baseline, so the pause only counts in the
        // diagnostics totals and can never leak into a frame.
        framePauseClock.resume(at: FrameClock.now())
        guard case .loaded = phase, let game = currentGame else { return }
        startFrameLoop(warmUp: nil, romKey: game.titleID)
        startAudio()
        AppLog.log("[3ds2apple] runtime resumed")
    }

    /// Restarts the loaded game. Save data is kept: the same per-title data
    /// directory is passed to the new runtime.
    func resetRuntime() {
        guard case .loaded = phase, let game = currentGame else { return }
        AppLog.log("[3ds2apple] runtime reset requested")
        isPaused = false
        stopFrameLoop()
        stopAudio()
        inputState.clearAll()
        // The restart is a new session: the recovery snapshot belongs to the
        // session being replaced.
        backgroundSuspended = false
        pendingBackgroundSnapshot = nil
        discardBackgroundSnapshot(foregroundReturn: false)
        setPhase(.idle)
        start(game)
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

    /// Title-id namespace used for the save-state folder of the loaded game.
    var saveStateNamespace: String? { currentGame?.saveNamespace }

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
        framePauseClock.pause(at: FrameClock.now())
        stopFrameLoop()
        stopAudio()
        AppLog.log("[3ds2apple] runtime paused for a save-state operation")
        return true
    }

    /// Restarts what `suspendForStateWork()` stopped; a no-op when it stopped
    /// nothing (the caller paused the game separately).
    func resumeAfterStateWork(_ suspended: Bool) {
        guard suspended else { return }
        guard case .loaded = phase, let game = currentGame else { return }
        isPaused = false
        guard !backgroundSuspended else {
            // The app moved to the background while the state was serialized:
            // leave the loop stopped. The return to the active scene resumes it
            // and the open pause clock records the whole pause.
            AppLog.log("[3ds2apple] save-state work finished in the background; the loop restarts on return")
            return
        }
        framePauseClock.resume(at: FrameClock.now())
        startFrameLoop(warmUp: nil, romKey: game.titleID)
        startAudio()
        AppLog.log("[3ds2apple] runtime resumed after the save-state operation")
    }

    // MARK: - Scene transitions (main queue)

    /// Pauses the loop when the scene stops being active (Control Center, the
    /// app switcher, an incoming call, a system alert). The paused wall time is
    /// excluded from the frame rate and the stutter statistics by the pause
    /// clock; returning resumes the same session with its statistics preserved.
    ///
    /// A game already paused by the in-game menu, a save-state operation or the
    /// software keyboard is left alone: its own resume path owns it.
    func pauseForInactiveScene() {
        guard case .loaded = phase, !isPaused, keyboardRequest == nil,
              !scenePauseActive, !backgroundSuspended else { return }
        scenePauseActive = true
        inputState.clearAll()
        framePauseClock.pause(at: FrameClock.now())
        stopFrameLoop()
        stopAudio()
        AppLog.log("[3ds2apple] scene inactive: frame loop paused")
    }

    /// Continues a session paused by `pauseForInactiveScene()`. Unlike the
    /// in-game menu, the loop is only restarted: the session keeps its running
    /// frame statistics, and the pause is excluded from them instead of
    /// resetting them. The same path returns from the background (0.1.4): the
    /// runtime was kept, so the game simply continues here.
    func resumeAfterInactiveScene() {
        let returnedFromBackground = backgroundSuspended
        backgroundSuspended = false
        if returnedFromBackground {
            // The session goes on from here, so a snapshot of the older state is
            // stale: the running console is newer. A pending restore still owns
            // its snapshot file, so that one is kept until it has been applied.
            if pendingBackgroundSnapshot == nil {
                discardBackgroundSnapshot(foregroundReturn: true)
            } else {
                backgroundSnapshotGeneration &+= 1
                backgroundSnapshotInFlight = nil
                backgroundSnapshot = nil
                endBackgroundSnapshotTask()
            }
        }
        guard scenePauseActive else {
            // A load that finished while the app was in the background clears
            // the scene pause on completion: restart the loop here.
            if returnedFromBackground, case .loaded = phase, !isPaused,
               keyboardRequest == nil, let game = currentGame {
                framePauseClock.resume(at: FrameClock.now())
                startLoadedSession(romKey: game.titleID)
                AppLog.log("[3ds2apple] scene active: frame loop resumed after the load completed in the background")
            }
            return
        }
        scenePauseActive = false
        let loadInProgress: Bool
        switch phase {
        case .starting, .preparing:
            loadInProgress = true
        case .idle, .loaded, .failed, .finished:
            loadInProgress = false
        }
        if case .loaded = phase, !isPaused, keyboardRequest == nil, let game = currentGame {
            framePauseClock.resume(at: FrameClock.now())
            if returnedFromBackground, pendingBackgroundSnapshot != nil {
                // The load finished while the app was in the background; the
                // recovery snapshot restore has not run yet.
                startLoadedSession(romKey: game.titleID)
            } else {
                rearmFrameLoop()
                startAudio()
            }
            AppLog.log("[3ds2apple] scene active: frame loop resumed")
        } else if loadInProgress {
            // Close the recorded scene pause; the load completion starts the
            // loop with a reset clock once the runtime is ready.
            framePauseClock.resume(at: FrameClock.now())
            AppLog.log("[3ds2apple] scene active: load still in progress, the loop starts when it completes")
        }
        // A game paused by its in-game menu or the software keyboard keeps its
        // pause: that control resumes it (and nothing runs while backgrounded).
    }

    // MARK: - Background recovery snapshot (main queue)

    /// True between the move to the background and the return to the active
    /// scene (diagnostics).
    var isBackgroundSuspended: Bool { backgroundSuspended }

    /// One-line state of the recovery snapshot for the diagnostics report.
    var backgroundSnapshotDiagnostics: String {
        if let snapshot = backgroundSnapshot {
            return "pending \(snapshot.titleID) \(StorageFormat.size(snapshot.bytes)) captured \(StorageFormat.date(snapshot.capturedAt))"
        }
        if backgroundSnapshotInFlight != nil {
            return "capturing"
        }
        if pendingBackgroundSnapshot != nil {
            return "restoring"
        }
        return "none"
    }

    /// Restores the interrupted session offered on the home page: starts the
    /// game and applies the recovery snapshot once the runtime is loaded.
    func resumeBackgroundSnapshot() {
        guard let snapshot = backgroundSnapshot ?? SaveStateSupport.pendingBackgroundSnapshot() else { return }
        backgroundSnapshot = nil
        guard let entry = GameLibrary.shared.entry(titleID: snapshot.titleID) else {
            SaveStateSupport.discardBackgroundSnapshot()
            presentNotice(
                title: L10n.tr("Could not resume the game"),
                message: L10n.tr("Its game data is no longer in this app."),
                severity: .warning
            )
            return
        }
        pendingBackgroundSnapshot = snapshot
        AppLog.log("[3ds2apple] background snapshot: resuming %@", snapshot.titleID)
        start(entry)
    }

    /// Drops the recovery snapshot offered on the home page: the interrupted
    /// session is abandoned and the card disappears.
    func discardBackgroundSnapshot() {
        pendingBackgroundSnapshot = nil
        discardBackgroundSnapshot(foregroundReturn: false)
    }

    /// Re-reads the recovery snapshot after the library changed (a game was
    /// deleted): the home page calls it so the resume card cannot point at a
    /// game that no longer exists.
    func refreshBackgroundSnapshot() {
        guard !isRuntimeActive, pendingBackgroundSnapshot == nil else { return }
        backgroundSnapshot = SaveStateSupport.pendingBackgroundSnapshot()
    }

    /// Starts the loaded session after a load completes (or after returning to
    /// the foreground while a load finished in the background): restores a
    /// pending recovery snapshot first, then starts the frame loop and audio.
    private func startLoadedSession(romKey: String) {
        if let snapshot = pendingBackgroundSnapshot {
            pendingBackgroundSnapshot = nil
            guard snapshot.titleID == romKey.uppercased() else {
                startLoadedSessionWithoutSnapshot(romKey: romKey)
                return
            }
            AppLog.log(
                "[3ds2apple] background snapshot: restoring %@ (%@)",
                snapshot.titleID,
                StorageFormat.size(snapshot.bytes)
            )
            saveStates.restoreBackgroundSnapshot(snapshot: snapshot) { [weak self] failure in
                guard let self else { return }
                if let failure {
                    AppLog.log("[3ds2apple] background snapshot: %@", failure)
                    self.presentNotice(
                        title: L10n.tr("Could not resume the game"),
                        message: L10n.tr("The recovery snapshot could not be restored, so the game starts from the beginning."),
                        severity: .warning
                    )
                } else {
                    self.discardBufferedAudio()
                }
                self.startLoadedSessionWithoutSnapshot(romKey: romKey)
            }
            return
        }
        startLoadedSessionWithoutSnapshot(romKey: romKey)
    }

    /// Starts the loop and the audio engine of a loaded session, unless the app
    /// is in the background again by now.
    private func startLoadedSessionWithoutSnapshot(romKey: String) {
        guard case .loaded = phase, !backgroundSuspended else { return }
        startFrameLoop(warmUp: nil, romKey: romKey)
        startAudio()
    }

    /// Serializes the console while the app is in the background, so a process
    /// the system jettisons can be resumed after the next cold launch. The
    /// frame loop and the audio engine are already stopped by
    /// `suspendForBackground()`.
    private func requestBackgroundSnapshot() {
        guard case .loaded = phase, let game = currentGame else { return }
        guard backgroundSnapshotInFlight == nil, saveStates.isRuntimeLoaded else { return }
        backgroundSnapshotGeneration &+= 1
        let generation = backgroundSnapshotGeneration
        backgroundSnapshotInFlight = generation
        beginBackgroundSnapshotTask()
        AppLog.log("[3ds2apple] background snapshot: capturing %@", game.titleID)
        saveStates.captureBackgroundSnapshot(titleID: game.titleID, title: game.title) { [weak self] snapshot in
            guard let self else { return }
            self.endBackgroundSnapshotTask()
            guard self.backgroundSnapshotInFlight == generation else {
                // The app came back before the write finished: the running
                // session is newer, so the just-written snapshot is stale.
                SaveStateSupport.discardBackgroundSnapshot()
                return
            }
            self.backgroundSnapshotInFlight = nil
            if snapshot == nil {
                AppLog.log("[3ds2apple] background snapshot: not written")
            }
        }
    }

    /// Drops the recovery snapshot state and its files. `foregroundReturn`
    /// distinguishes the normal return to the active scene (the session
    /// continues and the snapshot is stale) from an explicit unload/reset.
    private func discardBackgroundSnapshot(foregroundReturn: Bool) {
        backgroundSnapshotGeneration &+= 1
        backgroundSnapshotInFlight = nil
        endBackgroundSnapshotTask()
        backgroundSnapshot = nil
        if foregroundReturn {
            AppLog.log("[3ds2apple] background snapshot: discarded (the session continued)")
        }
        SaveStateSupport.discardBackgroundSnapshot()
    }

    /// Gives the snapshot write time to finish after the scene backgrounded;
    /// ended as soon as the write completes or the system takes the time back.
    private func beginBackgroundSnapshotTask() {
        endBackgroundSnapshotTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "3ds2apple.background-snapshot") { [weak self] in
            guard let self else { return }
            AppLog.log("[3ds2apple] background snapshot: the system ended the background time before the snapshot finished")
            self.endBackgroundSnapshotTask()
        }
    }

    private func endBackgroundSnapshotTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
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

    // MARK: - CPU profiler (main queue control, runtimeQueue executes)

    /// Starts the guest-PC sampling profiler on the runtime queue and reports on
    /// the main queue whether sampling is on. Only usable while a game is
    /// loaded: the handle belongs to one load, and a new load starts unsampled.
    /// Sampling costs a branch per guest step and cannot be stopped for the
    /// rest of that load, so this is a diagnostic tool (CPUProfilerView).
    func startCPUProfiler(completion: @escaping (Bool) -> Void) {
        guard isRuntimeLoaded else {
            completion(false)
            return
        }
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            guard let system = self.system else {
                DispatchQueue.main.async { [weak self] in
                    self?.cpuProfilerStarted = false
                    completion(false)
                }
                return
            }
            let started = zk_profiler_start(system) == 0
            DispatchQueue.main.async { [weak self] in
                self?.cpuProfilerStarted = started
                completion(started)
            }
            AppLog.log("[3ds2apple] CPU profiler: %@",
                       started ? "sampling guest PCs" : "zk_profiler_start failed")
        }
    }

    /// Copies the hottest count (1...100) sampled guest PCs as
    /// "thread 0xPC hits" lines, most frequent first. The runtime's pointer is
    /// only valid until its next status call on the runtime queue, so the Swift
    /// String is made inside that queue block and handed to the main queue.
    /// Empty when the profiler has no samples (or is not running).
    func cpuProfilerHotSpots(count: UInt32 = 20, completion: @escaping (String) -> Void) {
        let limit = min(max(count, 1), 100)
        runtimeQueue.async { [weak self] in
            var text = ""
            if let system = self?.system {
                let pointer = zk_profiler_hot_spots(system, limit)
                if let pointer {
                    text = String(cString: pointer)
                }
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    // MARK: - A1 presentation (main queue creates, runtimeQueue presents)

    /// Whether the app tries the CAMetalLayer presentation path. Set this to
    /// `false` for an on-device A/B against the pre-A1 `CGImage` path; the
    /// fallback is automatic when a presenter cannot be made (no MoltenVK in
    /// the app's Frameworks, a GPU that cannot make a Vulkan device, ...).
    private static let preferMetalPresentation = true

    /// True while this device direction's screen layout is a custom layout, which
    /// the presenter cannot draw: a load skips the presenter and uses zk_create +
    /// zk_read_screen. Every preset is a presenter arrangement. Main queue only;
    /// applies from the next load.
    private(set) var readbackPresentationRequired = false

    /// Called from ContentView and GameView when the screen layout preset or the
    /// device orientation changes. A game that is already presenting keeps the
    /// Metal layer until the next load (the Settings footer says so).
    func setReadbackPresentationRequired(_ required: Bool) {
        guard required != readbackPresentationRequired else { return }
        readbackPresentationRequired = required
        AppLog.log(
            "[3ds2apple] readback presentation: %@ (a load now uses the readback path)",
            required ? "on" : "off"
        )
    }

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
    private func beginLoad(_ launch: GameLaunch) {
        // Show "Starting Zakuro…" (and the Metal view, once it exists) while
        // the runtime loads.
        setPhase(.starting(name: launch.entry.title))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let presenter = self.presenterForLoadOnMain()
            let drawableSize = self.presentedDrawableSize
            self.runtimeQueue.async { [weak self] in
                self?.startRuntime(for: launch, presenter: presenter, drawableSize: drawableSize)
            }
        }
    }

    /// Creates the `MetalScreenView` and its presenter the first time a load
    /// asks for them and reuses them afterwards (the layer outlives a single
    /// game). Main queue only.
    ///
    /// Returns `nil` when the Metal path is off or unavailable; the caller then
    /// uses `zk_create` + `zk_read_screen`. A failure is remembered, so later
    /// loads do not retry the same missing/unsupported setup.
    private func presenterForLoadOnMain() -> UnsafeMutableRawPointer? {
        guard Self.preferMetalPresentation else { return nil }
        guard !readbackPresentationRequired else {
            // A custom layout: the presenter cannot place one screen on its own,
            // so the two screens must come from zk_read_screen for exact
            // per-screen placement.
            AppLog.log("[3ds2apple] readback presentation: loading on the readback path")
            return nil
        }

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
        // The custom GPU layout fills the whole game-view stage at native device
        // pixels; every arrangement keeps the presenter's own drawable size.
        if screenLayout == .custom {
            view.setCustomFill(true)
            presentedDrawableSize = view.drawablePixelSize
            return
        }
        view.setCustomFill(false)
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

        _ = zk_presenter_set_screen_swap(handle, screenSwapped ? 1 : 0)
        if layout == 8 {
            // Custom GPU layout: the rects are normalised to the upright canvas
            // and the presenter rotates the two pictures for the screen-rotation
            // setting; there is no layout_size to compare.
            _ = zk_presenter_set_custom_rotation(handle, rotation)
            let size = presentedDrawableSize
            let applied = applyCustomPresenterGeometry(handle, size: size)
            AppLog.log("[3ds2apple] screen layout custom · %@ · drawable %ux%u · custom viewports %@",
                       screenRotation.rawValue,
                       UInt32(max(1, size.width.rounded())),
                       UInt32(max(1, size.height.rounded())),
                       applied ? "ok" : "missing")
            return
        }

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
        let normX = Float(min(max(normalisedX, 0), 1))
        let normY = Float(min(max(normalisedY, 0), 1))
        let onLowerScreen: Int32
        if screenLayout == .custom {
            // The GPU custom path turns each screen's picture inside its own
            // rectangle; pass the displayed point and the rotation so the ABI can
            // undo that turn after finding the lower screen's rectangle.
            if let viewports = customPresenterViewports(for: size) {
                onLowerScreen = zk_present_custom_touch_map(
                    UInt32(size.width.rounded()), UInt32(size.height.rounded()),
                    Float(viewports.top.minX), Float(viewports.top.minY),
                    Float(viewports.top.width), Float(viewports.top.height),
                    Float(viewports.bottom.minX), Float(viewports.bottom.minY),
                    Float(viewports.bottom.width), Float(viewports.bottom.height),
                    normX, normY, UInt32(screenRotation.presenterValue),
                    screenSwapped ? 1 : 0, &x, &y
                )
            } else {
                onLowerScreen = 0
            }
        } else {
            onLowerScreen = zk_present_touch_map(
                UInt32(size.width.rounded()),
                UInt32(size.height.rounded()),
                screenLayout.presenterValue,
                screenRotation.presenterValue,
                screenSwapped ? 1 : 0,
                normX,
                normY,
                &x,
                &y
            )
        }
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
        // A software-keyboard request cannot outlive its console either: the next
        // load starts with no applet open and no pause.
        keyboardRequestPending = false
        keyboardPauseState.set(false)
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
            // A new handle starts with the profiler off.
            self?.cpuProfilerStarted = false
        }
    }

    /// zk_create() for a launch: destroy the old handle, create the new one,
    /// publish state and start the frame loop. Must run on `runtimeQueue`.
    ///
    /// A1: with a non-nil `presenter` the game loads through
    /// `zk_create_presented`, so its screens are shown on the app's
    /// CAMetalLayer. A presented load that fails is retried once with the plain
    /// `zk_create` readback path, so a presenter problem cannot make a game
    /// unplayable.
    ///
    /// AOT-only: after zk_create() the handle must report linked AOT code
    /// (zk_recompiled() == 1). A title the runtime would interpret is stopped
    /// here with the "No AOT build for this game" notice; there is no
    /// interpreter fallback any more.
    private func startRuntime(for launch: GameLaunch,
                              presenter: UnsafeMutableRawPointer?,
                              drawableSize: CGSize) {
        let romURL = launch.cartridgeURL
        let dataDirectory = launch.dataDirectory
        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            publishFailure(L10n.format("Could not create the save-data directory: %@", error.localizedDescription))
            return
        }

        // A full-screen custom layout has no CAMetalLayer presenter, so the
        // load goes through the plain zk_create() readback path. Ask for the
        // GPU renderer explicitly: the 3D still draws on Metal, only the screen
        // copy is read back, instead of falling back to the software PICA200.
        // A presented load forces the same switch on its own.
        zk_set_hardware_renderer(1)
        if presenter == nil {
            AppLog.log("[3ds2apple] readback presentation: asking for the GPU renderer")
        }
        // Replacing a game always releases the previous handle first, and that
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
        // AOT proof for this load. The shell never runs interpreted code: the
        // linked code compiled into the build, the per-handle recompiled flag and
        // the runtime's own status text are logged together so a device log (or
        // the exported diagnostics) cannot leave "is AOT actually active?"
        // ambiguous.
        let linkedProgramID = zk_linked_program_id()
        let linkedCode = zk_linked_code() == 1
        let recompiledFlag = zk_recompiled(handle) == 1
        let recompiledStatus = Self.recompiledStatusText(handle)
        let registeredPack = zk_registered_gamepack_title_id()
        let packPath: String
        if launch.aotStatus == .staticLinked {
            packPath = "static linked (main binary)"
        } else {
            let loaded = AOTPackageLoader.shared.loadedPackages.map(\.path)
            packPath = loaded.joined(separator: ",")
        }
        var aotDiagnostics = AOTDiagnostics(
            linkedCode: linkedCode,
            linkedProgramID: linkedProgramID,
            recompiled: recompiledFlag,
            status: recompiledStatus,
            packPath: packPath,
            registeredTitleID: registeredPack
        )
        if launch.aotStatus == .package, aotDiagnostics.packPath.isEmpty {
            aotDiagnostics.packPath = launch.entry.packFile ?? "unknown (catalog has no packFile)"
        }
        let hardwareStatus = Self.hardwareStatusText(handle)
        AppLog.log("[3ds2apple] AOT: %@", aotDiagnostics.label)
        AppLog.log("[3ds2apple] display: %@", displayPath.label)
        AppLog.log("[3ds2apple] hardware: %@", hardwareStatus)
        // Low-fps triage: a software renderer is the common reason a device build
        // "feels slow" (and it is also why the Metal HUD cannot appear). Log it
        // as its own warning line instead of hiding it among the status output.
        let softwareRenderer = !displayPath.usesMetalLayer
            || hardwareStatus.lowercased().contains("software")
        if softwareRenderer {
            AppLog.log(
                "[3ds2apple] PERFORMANCE WARNING: the 3D draws in software (PICA200 on the CPU)%@. Expect a low frame rate; the GPU path needs Frameworks/MoltenVK.framework and the presented CAMetalLayer. hardware=%@",
                MetalBackend.isMoltenVKEmbedded ? "" : "; this app has no MoltenVK.framework",
                hardwareStatus
            )
        }
        guard recompiledFlag else {
            // No interpreter fallback: a title the runtime would interpret must
            // not run at all. Release the handle again and show a red error that
            // names the actual runtime reason instead of silently interpreting.
            let linkedTitle = String(format: "%016llX", linkedProgramID)
            zk_destroy(handle)
            system = nil
            framePresenter = nil
            presentFailures = 0
            let reason = recompiledStatus.isEmpty ? "-" : recompiledStatus
            let message = L10n.format(
                "No AOT build for this game: “%@” was loaded, but the runtime is not executing AOT code (linked title %@, runtime status: %@). The shell refuses to run interpreted code.",
                launch.entry.title,
                linkedTitle,
                reason
            )
            AppLog.log("[3ds2apple] AOT REFUSED: %@", message)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.aotDiagnostics = aotDiagnostics
                self.presentNoAOTMessage(message)
            }
            return
        }
        let aot: AOTStatus = launch.aotStatus
        AppLog.log("[3ds2apple] zk_create OK after %.1f s: %@ (%@)",
              elapsed, launch.entry.title, romURL.lastPathComponent)

        // Cheat codes: the player's own file for this title
        // (Documents/Cheats/<TITLEID>.txt). The runtime applies the enabled
        // entries from the next frame and a missing file is not an error; the
        // result is published with the loaded game and goes to the log.
        let cheatPath = CheatManager.fileURL(titleID: launch.entry.titleID).path
        let cheatSnapshot = CheatBridge.load(system: handle,
                                            titleID: launch.entry.titleID,
                                            path: cheatPath)
        AppLog.log("[3ds2apple] cheats: %@", cheatSnapshot.diagnosticsLine)

        // The optional first-load warm-up was removed in 0.1.1: a load always
        // reveals the game as soon as zk_create succeeds. The runtime still
        // persists its pipeline cache while the game runs, so later loads start
        // warm; a pipeline first used later compiles on a worker thread.
        AppLog.log("[3ds2apple] graphics warm-up: removed; revealing the game as soon as it loads")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentGame = launch.entry
            self.inputState.clearAll()
            self.clearScreens()
            self.aotStatus = aot
            self.aotDiagnostics = aotDiagnostics
            self.displayPath = displayPath
            self.hardwareStatus = hardwareStatus
            self.pipelineCacheStats = cacheAtLoad
            self.pipelineCacheAtLoad = cacheAtLoad
            self.warmUp = GraphicsWarmUpStatus()
            CheatRuntime.shared.publish(cheatSnapshot,
                                        titleID: launch.entry.titleID,
                                        path: cheatPath)
            self.setPhase(.loaded(name: launch.entry.title))
            if self.backgroundSuspended {
                // The app moved to the background while this load was running:
                // keep the runtime and leave the loop stopped. The return to
                // the active scene starts it (a pending recovery snapshot is
                // restored first).
                AppLog.log("[3ds2apple] scene background: runtime loaded; the frame loop stays stopped until the app returns")
                return
            }
            if self.scenePauseActive {
                self.scenePauseActive = false
                self.framePauseClock.resume(at: FrameClock.now())
            }
            self.startLoadedSession(romKey: launch.entry.titleID)
        }
    }

    /// Whether (and how long) to warm the GPU pipelines for this load.
    ///
    /// Only a renderer drawing on the host GPU compiles Vulkan pipelines; a
    /// software renderer is revealed immediately. A game whose warm-up completed
    /// in this app install, with cache files still on disk, gets the shorter
    /// `warm` plan: its pipelines only need to be loaded from the cache.
    private static func graphicsWarmUpPlan(hardwareStatus: String,
                                           cache: PipelineCacheStats,
                                           romKey: String) -> GraphicsWarmUpPlan? {
        guard hardwareStatus.contains("draws on the host GPU") else { return nil }
        let alreadyWarmed = GraphicsWarmUpMarker.wasCompleted(romKey: romKey)
        return alreadyWarmed && cache.isWarm ? .warm : .cold
    }

    /// Starts the warm-up behind the "Preparing graphics" overlay: publishes the
    /// phase, sets the runtime queue's tracker and starts the frame loop.
    /// Main queue only.
    private func beginGraphicsWarmUp(plan: GraphicsWarmUpPlan, launch: GameLaunch) {
        warmUp = GraphicsWarmUpStatus.starting(plan: plan)
        setPhase(.preparing(name: launch.entry.title))
        AppLog.log("[3ds2apple] graphics warm-up: starting (%@)",
              plan.fromWarmCache ? "cached pipelines, short run" : "cold cache, full run")
        startFrameLoop(warmUp: plan, romKey: launch.entry.titleID)
        startAudio()
    }

    /// Copies `zk_hardware_status()` into a Swift String. The pointer is
    /// library-owned and only valid until the next status call on this thread.
    /// Copies zk_recompiled_status(): whether the loaded system runs AOT code
    /// and, when it does not (or only partly), the runtime's own explanation.
    /// The library-owned pointer is valid only until the next status call on the
    /// calling thread, so it is copied here immediately.
    private static func recompiledStatusText(_ handle: zk_system_t) -> String {
        guard let pointer = zk_recompiled_status(handle) else { return "" }
        return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hardwareStatusText(_ handle: zk_system_t) -> String {
        guard let pointer = zk_hardware_status(handle) else { return "no status" }
        let text = String(cString: pointer)
        return text.isEmpty ? "no status" : text
    }

    /// Copies `zk_last_error()` into a Swift String. Must run on the thread
    /// that just saw `zk_create()` fail (the error slot is thread-local).
    private static func currentRuntimeError() -> String {
        guard let pointer = zk_last_error() else {
            return L10n.tr("The Zakuro runtime could not load this game (no error text was reported).")
        }
        let text = String(cString: pointer)
        return text.isEmpty ? L10n.tr("The Zakuro runtime could not load this game (empty error text).") : text
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
        lastFrameStartTicks = statsWindowStartTicks
        lastPerfLogTicks = statsWindowStartTicks
        didLogScreenReadFailure = false
        // Accumulators are runtimeQueue-owned, but the queue is idle here: no
        // frame loop is running yet, so no frame can race this.
        timingWindow.reset()
        stutterTracker.start(at: statsWindowStartTicks)
        // A new loop starts from a new baseline: a pause from the old loop (the
        // menu pause that led here) is only counted in the session totals.
        framePauseClock.forgetPendingResume()
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

    /// Restarts the configured frame-loop driver without resetting the session's
    /// frame statistics: used by a resume that keeps the running totals (a scene
    /// transition). Main queue only.
    private func rearmFrameLoop() {
        setFrameLoopLabels(isFreeRun: Self.frameLoopDriver == .freeRun, cap: frameRateCap.current)
        switch Self.frameLoopDriver {
        case .freeRun:
            let generation = freeRunState.start()
            scheduleFreeRunFrame(after: 0, generation: generation)
        case .displayLink:
            startDisplayLinkOnMain()
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

        // A software-keyboard request stops the loop until it is answered: the
        // title is waiting on the applet, so further frames would only burn CPU.
        // The answer (answerKeyboard) schedules the next frame on this queue.
        guard !keyboardPauseState.current else { return }

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
        // The title waits on the software keyboard: no frame to run.
        guard !keyboardPauseState.current else { return }
        guard frameGate.wait(timeout: .now()) == .success else { return }
        let gate = frameGate
        runtimeQueue.async { [weak self] in
            self?.renderFrame()
            gate.signal()
        }
    }

    /// Excludes a pause that ended since the previous frame from every timing
    /// baseline. runtimeQueue only: called with the loop idle at the start of the
    /// first frame after a resume.
    ///
    /// A pause is not a frame. Without this rebase the first frame after (for
    /// example) an answered software-keyboard request measured the whole pause
    /// as a start-to-start interval: it was counted as one multi-second stutter
    /// and the FPS window divided a few frames by the paused wall time
    /// (`stutter=… worst 8518.8ms` / `fps=0.5` after a keyboard answer).
    private func applyPendingPauseResume(at frameStartTicks: UInt64) {
        guard let pause = framePauseClock.takePendingResume() else { return }
        lastFrameStartTicks = frameStartTicks
        statsWindowStartTicks = frameStartTicks
        framesSinceStats = 0
        lastPerfLogTicks = frameStartTicks
        stutterTracker.pause(at: pause.startedTicks)
        stutterTracker.resume(at: frameStartTicks)
        AppLog.log(
            "[3ds2apple] frame timing: excluded a %.2f s pause from the fps, stutter and start-to-start baselines",
            FrameClock.seconds(pause.pausedTicks)
        )
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
        // A pause is not a frame: rebase the FPS window and the start-to-start
        // baselines and tell the stutter tracker before this frame is measured.
        applyPendingPauseResume(at: frameStart)
        // Start-to-start interval: what the player sees and the pacing baseline
        // the stutter tracker needs. A gap it cannot explain from the previous
        // frame's work is a scheduling stall, not this frame's cost.
        let intervalTicks = lastFrameStartTicks > 0 && frameStart > lastFrameStartTicks
            ? frameStart - lastFrameStartTicks
            : 0
        lastFrameStartTicks = frameStart
        if intervalTicks > 0 {
            timingWindow.record(.frameInterval, ticks: intervalTicks)
        }
        let unlimited = isUnlimitedSpeed
        let speed = unlimited ? 1 : playbackSpeedState.current

        // The only place that pushes input: same serial queue, immediately
        // before the frame that consumes it. During the graphics warm-up the
        // game is hidden behind the overlay and receives neutral input, so a
        // button touched on the transparent overlay cannot move the title
        // before the player sees it; the merged input state itself is left
        // alone and is forwarded again from the first revealed frame.
        let input = warmUpRun == nil ? inputState.snapshot() : InputSnapshot()

        // Fast-forward: advance the console-only frames first. They produce no
        // visible frame; normal 2×–4× keeps its audio. Unlimited runs as many
        // console frames as fit into the 60 Hz presentation budget instead of
        // stopping at 4× (audio is muted for that mode).
        if unlimited {
            if !runUnlimitedFrames(system: system, input: input, frameStart: frameStart) {
                return false
            }
        } else if speed > 1 {
            var fastForwarded = 1
            while fastForwarded < speed {
                if !runFastForwardFrame(system: system, input: input, frameStart: frameStart) {
                    return false
                }
                fastForwarded += 1
            }
        }

        // The C-stick is separate from zk_set_input() (the older call has no
        // C-stick parameter); it takes effect for the frame below.
        zk_set_cstick(system, input.cStickX, input.cStickY)
        zk_set_input(system, input.buttons, input.circleX, input.circleY,
                     input.touch ? 1 : 0, input.touchX, input.touchY)

        let runStart = FrameClock.now()
        let result = zk_run_frame(system)
        let runTicks = FrameClock.now() - runStart
        // Split `run` into the software GPU's command walk and the emulated
        // CPU/HLE work; `zk_perf` prints the same split per window as
        // `gpu`/`non-gpu`, and the hitch attribution needs it per frame.
        let gpuBusyMicros = zk_last_frame_gpu_busy_micros()
        let gpuTicks = min(
            runTicks,
            FrameClock.ticks(seconds: Double(gpuBusyMicros) / 1_000_000.0)
        )
        timingWindow.record(.runFrame, ticks: runTicks)
        timingWindow.record(.runGPU, ticks: gpuTicks)
        timingWindow.record(.runCPU, ticks: runTicks - gpuTicks)
        framesRendered += 1

        guard result == 0 else {
            timingWindow.record(.renderTotal, ticks: FrameClock.now() - frameStart)
            return finishForRunFrameResult(result)
        }

        // A title that started the software keyboard waits for the text, so
        // publish the request (once) and let the loop stop below.
        pollSoftwareKeyboard(system: system)

        // ZK_FRAME_COMPLETED. Audio first: it does not depend on the display,
        // and in Metal mode a present can wait for a drawable, which must not
        // delay draining the ring buffer. Fast-forward keeps its audio: every
        // console frame (including the extra ones) feeds the same ring buffer,
        // so the sound speeds up with the game instead of being muted.
        let audioStart = FrameClock.now()
        if !unlimited {
            pumpAudio(system: system)
        }
        let audioTicks = FrameClock.now() - audioStart
        timingWindow.record(.audioPump, ticks: audioTicks)

        var top: CGImage?
        var bottom: CGImage?
        // Ticks of this frame's phases, kept for stutter attribution. The CGImage
        // path derives its read time from the two screenImage() calls (total time
        // minus the image creation they report), so no extra clock read per
        // screen is needed.
        var presentTicks: UInt64 = 0
        var readTicks: UInt64 = 0
        var cgImageTicks: UInt64 = 0
        if let presenter = framePresenter {
            // A1: the screens go to the CAMetalLayer (straight from the
            // renderer's GPU images when the device is shared).
            let presentStart = FrameClock.now()
            let presented = zk_present(system, presenter)
            presentTicks = FrameClock.now() - presentStart
            timingWindow.record(.present, ticks: presentTicks)
            if presented <= -2 {
                presentFailed(result: presented)
            } else {
                presentFailures = 0
            }
        } else {
            // Pre-A1 path: copy both screens to the CPU and build CGImages.
            let screenStart = FrameClock.now()
            top = screenImage(system: system, which: 0, cgImageTicks: &cgImageTicks)
            bottom = screenImage(system: system, which: 1, cgImageTicks: &cgImageTicks)
            let screenTicks = FrameClock.now() - screenStart
            readTicks = screenTicks > cgImageTicks ? screenTicks - cgImageTicks : 0
            timingWindow.record(.cgImage, ticks: cgImageTicks)
        }

        let totalTicks = FrameClock.now() - frameStart
        timingWindow.record(.renderTotal, ticks: totalTicks)
        // Two tick comparisons per frame; only a stutter writes to the tracker.
        stutterTracker.record(
            frameStartTicks: frameStart,
            workTicks: totalTicks,
            runTicks: runTicks,
            gpuTicks: gpuTicks,
            presentTicks: presentTicks,
            readTicks: readTicks,
            cgImageTicks: cgImageTicks,
            audioTicks: audioTicks,
            frame: framesRendered
        )
        publishFrame(top: top, bottom: bottom, result: result)
        advanceGraphicsWarmUp(frameMilliseconds: FrameClock.milliseconds(FrameClock.now() - frameStart))
        return true
    }

    /// One extra console frame while fast-forwarding: advances the game without
    /// presenting or reading the screens; its audio is queued like a normal frame.
    /// runtimeQueue only. Returns false when the runtime stopped.
    /// Unlimited-speed inner loop: guest frames until the presentation budget
    /// (one 60 Hz interval) is used, with a hard frame-count guard so a faulty
    /// runtime cannot spin forever.
    private func runUnlimitedFrames(system: zk_system_t,
                                    input: InputSnapshot,
                                    frameStart: UInt64) -> Bool {
        let budget = FrameClock.ticks(seconds: 1.0 / 60.0)
        var frames = 0
        while frames < 4096 {
            if FrameClock.now() - frameStart >= budget { break }
            if !runFastForwardFrame(system: system, input: input, frameStart: frameStart) {
                return false
            }
            frames += 1
        }
        return true
    }

    private func runFastForwardFrame(system: zk_system_t,
                                     input: InputSnapshot,
                                     frameStart: UInt64) -> Bool {
        zk_set_cstick(system, input.cStickX, input.cStickY)
        zk_set_input(system, input.buttons, input.circleX, input.circleY,
                     input.touch ? 1 : 0, input.touchX, input.touchY)
        let runStart = FrameClock.now()
        let result = zk_run_frame(system)
        timingWindow.record(.runFrame, ticks: FrameClock.now() - runStart)
        framesRendered += 1
        // Normal 2×–4× fast-forward is audible; unlimited speed is muted.
        if !isUnlimitedSpeed {
            pumpAudio(system: system)
        }
        guard result == 0 else {
            timingWindow.record(.renderTotal, ticks: FrameClock.now() - frameStart)
            return finishForRunFrameResult(result)
        }
        // A keyboard request starts in any frame, including a fast-forward one.
        pollSoftwareKeyboard(system: system)
        return true
    }

    // MARK: - Software keyboard (3DS library applet)

    /// Polls the software keyboard after a completed frame and publishes a newly
    /// opened request to the main queue. runtimeQueue only.
    ///
    /// The title that starts the applet waits for the text, so once a request is
    /// open the frame loop stops (`runFreeRunFrame` / `displayLinkFired`) and the
    /// game view shows the overlay; answering resumes the loop from the frame the
    /// title was waiting in.
    private func pollSoftwareKeyboard(system: zk_system_t) {
        let pending = zk_keyboard_pending(system) != 0
        guard pending != keyboardRequestPending else { return }
        keyboardRequestPending = pending
        guard pending else {
            keyboardPauseState.set(false)
            DispatchQueue.main.async { [weak self] in
                self?.keyboardRequest = nil
            }
            return
        }

        guard let request = KeyboardRequest.decode(json: Self.keyboardJSON(system: system)) else {
            // A request the app cannot describe would leave the title waiting
            // forever: close it with the leftmost button (the applet's Cancel)
            // instead of freezing the game.
            AppLog.log("[3ds2apple] software keyboard: unreadable request, closing it with button 0")
            keyboardRequestPending = false
            _ = zk_answer_keyboard(system, "", 0)
            return
        }

        keyboardPauseState.set(true)
        AppLog.log("[3ds2apple] software keyboard: the title waits for text (%@)", request.logLine)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Nothing the player held in 3DS terms may stay down while the
            // overlay is up; the engine is stopped like the in-game menu does.
            self.inputState.clearAll()
            // Record the pause before the audio stops: the loop is gated right
            // after the frame that published this request, and that wall time
            // must not become a stutter or an FPS drop in the resumed window.
            self.framePauseClock.pause(at: FrameClock.now())
            self.stopAudio()
            self.keyboardRequest = request
        }
    }

    /// Copies the pending request's JSON. The library-owned pointer is valid only
    /// until the next keyboard call on the same thread, so it is copied here
    /// immediately. runtimeQueue only.
    private static func keyboardJSON(system: zk_system_t) -> String {
        guard let pointer = zk_keyboard_request_json(system) else { return "" }
        return String(cString: pointer)
    }

    /// Answers the open request: the text typed and the button pressed, zero
    /// being the leftmost and the last one confirming. Main queue only; called
    /// by the game view's keyboard overlay.
    func answerKeyboard(text: String, button: Int) {
        guard keyboardRequest != nil else { return }
        let request = keyboardRequest
        // Clear the overlay immediately; the applet call and the resume happen on
        // the runtime queue, which also logs a refused answer.
        keyboardRequest = nil
        inputState.clearAll()
        // The answer crosses the C ABI as a NUL-terminated UTF-8 string, so an
        // embedded NUL (which Swift strings allow) cannot reach the applet.
        let typed = text.replacingOccurrences(of: "\0", with: "")
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.answerKeyboard(text: typed, button: button, request: request)
        }
    }

    /// Answers the applet on the runtime queue; runtimeQueue only.
    private func answerKeyboard(text: String, button: Int, request: KeyboardRequest?) {
        defer {
            keyboardRequestPending = false
            keyboardPauseState.set(false)
            // End the recorded pause on the runtime queue, right where the
            // applet was answered: the next scheduled frame excludes it from
            // the fps/stutter/start-to-start baselines.
            framePauseClock.resume(at: FrameClock.now())
        }
        guard let system else { return }
        let buttonCount = max(1, request?.buttons.count ?? 1)
        let index = UInt32(min(max(button, 0), buttonCount - 1))
        let result = zk_answer_keyboard(system, text, index)
        if result == 0 {
            AppLog.log(
                "[3ds2apple] software keyboard: answered with button %u (%ld characters); resuming the frame loop",
                index,
                KeyboardRequest.utf16Count(text)
            )
        } else {
            AppLog.log("[3ds2apple] software keyboard: the applet refused the answer (result %d)", result)
        }
        // The frame loop owns start/stop on the main queue, so the resume hops
        // there like resumeFromMenu() does.
        DispatchQueue.main.async { [weak self] in
            self?.resumeAfterKeyboardAnswer()
        }
    }

    /// Restarts what the keyboard request stopped: the free-run loop schedules
    /// its next frame, the CADisplayLink keeps ticking by itself (its callback
    /// checks `keyboardPauseState`), and the audio engine comes back. Main queue
    /// only.
    private func resumeAfterKeyboardAnswer() {
        keyboardRequest = nil
        guard isRuntimeActive, !isPaused else { return }
        if Self.frameLoopDriver == .freeRun {
            guard let generation = freeRunState.activeGeneration() else { return }
            scheduleFreeRunFrame(after: 0, generation: generation)
        }
        startAudio()
        AppLog.log("[3ds2apple] software keyboard: request closed, runtime resumed")
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
                self.setPhase(.loaded(name: self.currentGame?.title ?? ""))
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
            snapshot.stutter = stutterTracker.snapshot()
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
        // The Metal path publishes no CGImages and a stats snapshot only every
        // 0.5 s. A frame in between has nothing to hand the main queue: skip the
        // hop (60 no-op blocks a second still wake the main thread and allocate
        // a closure with the captured values on the runtime queue).
        guard top != nil || bottom != nil || stats != nil else { return }
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
        guard !isUnlimitedSpeed else {
            slowPlaybackSpeedWindows = 0
            return
        }
        guard turboLimitEnabled else {
            slowPlaybackSpeedWindows = 0
            return
        }
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
        let reduced = speed >= 3 ? 2 : 1
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
        let stutter = stats.stutter
        let line = String(
            format: "perf: fps=%.1f frames=%llu | total=%.1f/%.1f/%.1f "
                + "run=%.1f/%.1f present=%.2f/%.2f readTop=%.2f/%.2f "
                + "readBottom=%.2f/%.2f image=%.2f/%.2f audio=%.2f/%.2f ms "
                + "| stutter=%ld (%.1f/min, worst %.1fms, %@) "
                + "(avg/max; total avg/max/last)",
            stats.fps,
            stats.frames,
            timing.renderTotal.average, timing.renderTotal.maximum, timing.renderTotal.last,
            timing.runFrame.average, timing.runFrame.maximum,
            timing.present.average, timing.present.maximum,
            timing.topScreenRead.average, timing.topScreenRead.maximum,
            timing.bottomScreenRead.average, timing.bottomScreenRead.maximum,
            timing.cgImage.average, timing.cgImage.maximum,
            timing.audioPump.average, timing.audioPump.maximum,
            stutter.count,
            stutter.perMinute,
            stutter.worstMilliseconds,
            stutter.topPhase.label
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
        let finalStutter = stutterTracker.snapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopFrameLoopOnMain()
            self.stopAudio()
            self.inputState.clearAll()
            self.keyboardRequest = nil
            self.isPaused = false
            self.scenePauseActive = false
            self.framePauseClock.forgetPendingResume()
            if let stoppedWarmUp, case .preparing = self.phase {
                self.warmUp = stoppedWarmUp
                AppLog.log("[3ds2apple] graphics warm-up: %@", stoppedWarmUp.logLine)
            }
            var stats = self.frameStats
            stats.fps = 0
            stats.lastResult = isError ? -1 : 1
            stats.timing = finalTiming
            stats.stutter = finalStutter
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
        scenePauseActive = false
        // The pause totals belong to one loaded session: a load releases the old
        // runtime and a fresh one starts here, an unload/background ends it.
        framePauseClock.resetSession()
        // A software-keyboard overlay cannot outlive the runtime it belongs to.
        keyboardRequest = nil
        keyboardPauseState.set(false)
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
        userAudioMuted = muted
        applyEffectiveAudioMute()
    }

    /// The device mute switch and the unlimited-speed mute are separate: leaving
    /// unlimited speed restores the player's own choice.
    private func applyEffectiveAudioMute() {
        let muted = userAudioMuted || isUnlimitedSpeed
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

    // MARK: - Game storage

    /// The app's Documents folder: 0.1.x cartridges still live under roms/,
    /// the runtime writes battery saves under data/<title id>/.
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    // MARK: - State (main queue)

    /// UI preview only: pretend a game is loaded so `GameView` can be rendered
    /// in the simulator shell. No console exists and no Zakuro call is made.
    func previewSetLoaded(name: String) {
        currentGame = GameEntry(titleID: "0004000000055E00", title: name, aot: true)
        aotStatus = .staticLinked
        setPhase(.loaded(name: name))
        // Solid stand-ins so headless UI snapshots show where each screen lands.
        topScreenImage = previewScreenImage(width: 400, height: 240, red: 0.05, green: 0.18, blue: 0.30)
        bottomScreenImage = previewScreenImage(width: 320, height: 240, red: 0.30, green: 0.12, blue: 0.28)
    }

    /// UI preview only: one solid CGImage standing in for a console screen.
    private func previewScreenImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.12, green: 0.42, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return context.makeImage()
    }

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
        AppLog.log("[3ds2apple] game load failed: %@", message)
        // A failed load cannot apply a pending recovery snapshot either (this
        // may run on the runtime queue, so the main-queue state move is hopped).
        if Thread.isMainThread {
            pendingBackgroundSnapshot = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pendingBackgroundSnapshot = nil
            }
        }
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
/// Unload / background / exit / fault / deinit. The runtime queue
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

    /// The generation of the running loop, nil when it is stopped. Safe from any
    /// thread: the software-keyboard answer uses it to schedule the next frame.
    func activeGeneration() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return active ? generation : nil
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

/// Lock-protected boolean read across the runtime/main queue boundary: the
/// software-keyboard pause is set on the runtime queue and read by the CADisplayLink
/// fallback on the main thread.
private final class LockedFlagState {
    private let lock = NSLock()
    private var value = false

    var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
