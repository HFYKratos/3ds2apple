//
//  AppSettings.swift
//  3ds2apple
//
//  User-facing settings for the shell: display, audio, controls and
//  performance. Values are held as @Published properties so every page updates
//  as soon as a setting changes; the settings UI writes them through the
//  bindings in SettingsView.swift, which also store them in UserDefaults.
//
//  The audio/controls/performance values apply immediately. Display values are
//  applied by the game screen when a game is loaded: the screen arrangement,
//  rotation and render resolution resize the presented layer and tell the
//  presenter (the next frame uses them), while aspect and integer scaling are
//  applied by the game screen itself. The internal 3D render scale behind the
//  render resolution is read by the runtime when a system loads, so a running
//  game keeps it until the next load. Every display change is safe while a game
//  runs.
//
//  Titles and details are localized with L10n.tr() at the point they are read,
//  so they show English or Simplified Chinese with the rest of the UI.
//

import Combine
import Foundation

/// How the upper and lower screen are arranged on screen.
///
/// All layouts are drawn by the CAMetalLayer presenter: the layer's drawable is
/// the arrangement at the 3DS resolutions and the presenter places the screens
/// in it. The readback path is only used when no presenter can be made.
enum ScreenLayout: String, CaseIterable, Identifiable {
    /// Upper screen above the lower one, as on the console (portrait shape).
    case stacked
    /// Upper screen left, lower screen right (wide, for landscape).
    case sideBySide
    /// Large upper screen with the lower one small at its lower right. The
    /// landscape default, the arrangement Manic-style skins use.
    case largeTop
    case upperOnly
    case lowerOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: return L10n.tr("Stacked")
        case .sideBySide: return L10n.tr("Side by side")
        case .largeTop: return L10n.tr("Large top screen")
        case .upperOnly: return L10n.tr("Upper screen only")
        case .lowerOnly: return L10n.tr("Lower screen only")
        }
    }

    var detail: String {
        switch self {
        case .stacked:
            return L10n.tr("Upper screen above the lower one, as on the console. Fits a portrait screen; with 90° rotation it becomes two columns.")
        case .sideBySide:
            return L10n.tr("Both screens in one row: upper on the left, lower on the right. Fits a landscape screen.")
        case .largeTop:
            return L10n.tr("Large upper screen with the lower one small at its lower right. The landscape default.")
        case .upperOnly:
            return L10n.tr("Only the upper (3D) screen. The game's touchscreen is not shown.")
        case .lowerOnly:
            return L10n.tr("Only the lower (touch) screen.")
        }
    }

    /// The layout number the presenter and `zk_present_layout_size` take.
    var presenterValue: UInt32 {
        switch self {
        case .stacked: return UInt32(ZK_LAYOUT_STACKED)
        case .sideBySide: return UInt32(ZK_LAYOUT_SIDE_BY_SIDE)
        case .largeTop: return UInt32(ZK_LAYOUT_LARGE_TOP)
        case .upperOnly: return UInt32(ZK_LAYOUT_TOP_ONLY)
        case .lowerOnly: return UInt32(ZK_LAYOUT_BOTTOM_ONLY)
        }
    }
}

/// How the screens fill their area.
enum ScreenAspect: String, CaseIterable, Identifiable {
    /// Keep the arrangement's own shape and fit it in the available space.
    case fit
    /// Fit the screens inside a 4:3 box, with black bars where the shapes differ.
    case fourThree
    /// Fill the available space, stretching the picture if the shapes differ.
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return L10n.tr("Fit")
        case .fourThree: return L10n.tr("4:3")
        case .stretch: return L10n.tr("Stretch")
        }
    }

    var detail: String {
        switch self {
        case .fit:
            return L10n.tr("Keeps the 3DS picture's own shape. Black bars fill the rest of the screen.")
        case .fourThree:
            return L10n.tr("Fits the picture inside a 4:3 area, the classic TV shape. The extra space becomes black bars.")
        case .stretch:
            return L10n.tr("Fills the whole area, stretching the picture if its shape differs. The 3DS aspect ratio is not kept.")
        }
    }
}

/// Which way the 3DS screens are turned inside their area.
///
/// This is not the device orientation: iOS already turns the app's interface
/// with the device, and the screens stay upright in it. A rotation is for playing
/// with the console held sideways (the stacked screens become two columns) or
/// upside down, like a console lying on a table.
enum ScreenRotation: String, CaseIterable, Identifiable {
    case upright
    case clockwise
    case upsideDown
    case counterClockwise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upright: return L10n.tr("Upright")
        case .clockwise: return L10n.tr("90° clockwise")
        case .upsideDown: return L10n.tr("Upside down")
        case .counterClockwise: return L10n.tr("90° counter-clockwise")
        }
    }

    /// The orientation number the presenter and `zk_present_layout_size` take.
    var presenterValue: UInt32 {
        switch self {
        case .upright: return UInt32(ZK_ORIENTATION_NORTH)
        case .clockwise: return UInt32(ZK_ORIENTATION_EAST)
        case .upsideDown: return UInt32(ZK_ORIENTATION_SOUTH)
        case .counterClockwise: return UInt32(ZK_ORIENTATION_WEST)
        }
    }
}

/// Orientation preference for the app's interface. Rotation still follows the
/// device when the system allows it; the app restricts the allowed orientations
/// to this value. The 3DS screens are drawn upright in that interface (see
/// `ScreenRotation` for turning them).
enum OrientationLock: String, CaseIterable, Identifiable {
    case automatic
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.tr("Automatic")
        case .portrait: return L10n.tr("Portrait")
        case .landscape: return L10n.tr("Landscape")
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return L10n.tr("The interface follows the device. The in-game layout adapts to portrait and landscape.")
        case .portrait:
            return L10n.tr("The interface stays portrait.")
        case .landscape:
            return L10n.tr("The interface stays landscape. Side-by-side or a turned console layout uses the width best.")
        }
    }
}

/// Audio latency preference: the IO buffer duration the audio engine requests.
enum AudioBufferSize: String, CaseIterable, Identifiable {
    case low
    case balanced
    case stable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return L10n.tr("Low latency")
        case .balanced: return L10n.tr("Balanced")
        case .stable: return L10n.tr("Stable")
        }
    }

    /// Seconds requested from `AVAudioSession.setPreferredIOBufferDuration`.
    var duration: TimeInterval {
        switch self {
        case .low: return 0.005
        case .balanced: return 0.010
        case .stable: return 0.020
        }
    }

    var detail: String {
        switch self {
        case .low: return L10n.tr("5 ms. Least delay, most sensitive to audio dropouts.")
        case .balanced: return L10n.tr("10 ms. The default.")
        case .stable: return L10n.tr("20 ms. Fewer dropouts, slightly more delay.")
        }
    }
}

/// Free-run frame cap. The loop never starts frames closer together than this;
/// it is an upper bound, not a target, so a slow game still runs below it.
enum FrameRateCap: Int, CaseIterable, Identifiable {
    case sixty = 60
    case thirty = 30

    var id: Int { rawValue }

    var title: String { "\(rawValue) fps" }
}

/// Fast-forward target: how many 3DS frames the runtime advances per presented
/// frame. 1× is normal speed; 2× and 4× run extra `zk_run_frame` calls before
/// the frame that is presented, so the game time advances that many times
/// faster (as long as the device keeps up; see the frame loop in ROMSession).
enum PlaybackSpeed: Int, CaseIterable, Identifiable {
    case normal = 1
    case double = 2
    case quadruple = 4

    var id: Int { rawValue }

    /// "1×", "2×", "4×": the same in both languages.
    var title: String { L10n.speedLabel(rawValue) }

    /// Whether this setting asks the runtime to advance more than one frame per
    /// presented frame.
    var isFastForward: Bool { rawValue > 1 }
}

/// The system Metal Performance HUD (FPS / GPU time / frame interval overlay).
///
/// Apple documents three programmatic ways to enable it, all handled here:
///
/// 1. `MetalHudEnabled` in Info.plist, injected by `scripts/build-ios-app.sh`.
///    The build gate; without it the other switches do nothing.
/// 2. `MetalHUDForceEnabled` in `NSUserDefaults` (value 1), the documented
///    runtime switch that needs no environment and no scheme option. The
///    Settings toggle writes it while it is on, so it is present from the next
///    launch on.
/// 3. `MTL_HUD_ENABLED=1` in the environment. Metal reads it when the process
///    creates its first device (MoltenVK creates that device when the first
///    game loads), so `App.init` sets it from the persisted setting; a device
///    that already exists keeps the state it was created with.
///
/// On top of that, `CAMetalLayer.developerHUDProperties` (see
/// `MetalScreenView`) shows or hides the HUD on the live layer without a
/// relaunch. The per-layer key is "mode": "default" / "main" / "disabled";
/// every `MTL_HUD_*` environment key may also be put in that dictionary.
enum MetalHUD {
    static let environmentKey = "MTL_HUD_ENABLED"
    static let defaultsKey = "MetalHUDForceEnabled"

    /// Whether the process environment currently asks Metal for the HUD.
    static var isEnvironmentEnabled: Bool {
        guard let raw = getenv(environmentKey) else { return false }
        return String(cString: raw) != "0"
    }

    /// Whether the documented NSUserDefaults switch is on. The HUD reads it at
    /// launch, so it has to be on disk before the next launch to take effect.
    static var isDefaultsEnabled: Bool {
        UserDefaults.standard.integer(forKey: defaultsKey) != 0
    }

    /// Writes all programmatic switches for the next launch. Main queue only.
    static func apply(enabled: Bool) {
        let defaults = UserDefaults.standard
        if enabled {
            setenv(environmentKey, "1", 1)
            defaults.set(1, forKey: defaultsKey)
        } else {
            unsetenv(environmentKey)
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// The Info.plist build gate injected by scripts/build-ios-app.sh.
    static var buildGateEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MetalHudEnabled") as? Bool ?? false
    }

    /// One line for the device log and the diagnostics report. Reading
    /// `AppSettings.shared` here is safe: the settings object is created before
    /// any of this is asked for.
    static var diagnosticsLine: String {
        "setting=\(AppSettings.shared.systemMetalHUD ? 1 : 0)"
            + " env=\(isEnvironmentEnabled ? 1 : 0)"
            + " defaults=\(isDefaultsEnabled ? 1 : 0)"
            + " plist=\(buildGateEnabled ? 1 : 0)"
    }
}
/// Persisted shell settings. One shared instance is injected through the view
/// tree; `SettingsView` and its reusable sections are the only writers.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var screenLayout: ScreenLayout
    @Published var screenAspect: ScreenAspect
    /// Turn the screens inside their area (see `ScreenRotation`).
    @Published var screenRotation: ScreenRotation
    @Published var integerScale: Bool
    /// 1 = the layout's own drawable (400x480 for the stacked console) through
    /// 4 = four times that (1600x1920). The presenter's drawable is resized at
    /// once; the runtime's internal 3D renderer reads the factor when a system
    /// loads, so an already loaded game keeps its internal scale.
    @Published var renderScale: Int
    @Published var orientation: OrientationLock

    @Published var audioVolume: Double
    @Published var audioMuted: Bool
    @Published var audioBuffer: AudioBufferSize

    @Published var showTouchControls: Bool
    @Published var controlsOpacity: Double
    @Published var haptics: Bool

    @Published var frameCap: FrameRateCap

    /// Show the system Metal Performance HUD (FPS / GPU time / memory) over the
    /// presented CAMetalLayer. Off by default; applied to the layer at run time
    /// and remembered across loads.
    @Published var systemMetalHUD: Bool
    /// Optional first-load graphics warm-up behind the "Preparing graphics"
    /// overlay. Off by default: the pipeline cache is still written, so a later
    /// per-scene compile can hitch anyway, and the overlay was judged not worth
    /// the wait. The runtime's pipeline-cache persistence is not affected.
    @Published var graphicsWarmUpEnabled: Bool
    /// Fast-forward target: 1×, 2× or 4× (see `PlaybackSpeed`).
    @Published var playbackSpeed: PlaybackSpeed

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        screenLayout = ScreenLayout(
            rawValue: defaults.string(forKey: Keys.screenLayout) ?? ""
        ) ?? .stacked
        // Earlier builds stored "native" for the default aspect; it is "fit"
        // now that 4:3 is a separate choice.
        let storedAspect = defaults.string(forKey: Keys.screenAspect) ?? ""
        screenAspect = ScreenAspect(rawValue: storedAspect == "native" ? "fit" : storedAspect) ?? .fit
        screenRotation = ScreenRotation(
            rawValue: defaults.string(forKey: Keys.screenRotation) ?? ""
        ) ?? .upright
        integerScale = Self.bool(defaults, Keys.integerScale, fallback: false)
        // Render resolution is 1...4 (UI.renderScale). Earlier builds stored
        // only a "double resolution" switch (UI.renderScaleDoubleX): migrate it
        // to 2x, or 1x when it was off or absent.
        if defaults.object(forKey: Keys.renderScale) != nil {
            renderScale = Self.clampRenderScale(defaults.integer(forKey: Keys.renderScale))
        } else if defaults.object(forKey: Keys.legacyRenderScaleDoubleX) != nil {
            renderScale = defaults.bool(forKey: Keys.legacyRenderScaleDoubleX) ? 2 : 1
        } else {
            renderScale = 1
        }
        orientation = OrientationLock(
            rawValue: defaults.string(forKey: Keys.orientation) ?? ""
        ) ?? .automatic

        if defaults.object(forKey: Keys.audioVolume) != nil {
            audioVolume = Self.clampVolume(defaults.double(forKey: Keys.audioVolume))
        } else {
            audioVolume = 1.0
        }
        audioMuted = Self.bool(defaults, Keys.audioMuted, fallback: false)
        audioBuffer = AudioBufferSize(
            rawValue: defaults.string(forKey: Keys.audioBuffer) ?? ""
        ) ?? .balanced

        showTouchControls = Self.bool(defaults, Keys.showTouchControls, fallback: true)
        if defaults.object(forKey: Keys.controlsOpacity) != nil {
            controlsOpacity = Self.clampOpacity(defaults.double(forKey: Keys.controlsOpacity))
        } else {
            controlsOpacity = 0.55
        }
        haptics = Self.bool(defaults, Keys.haptics, fallback: false)

        // The performance page no longer offers a frame cap: the console
        // timeline runs at its native 60 Hz and Fast-forward is the only
        // speed control, so an old stored 30 fps value is ignored on purpose.
        frameCap = .sixty

        systemMetalHUD = Self.bool(defaults, Keys.systemMetalHUD, fallback: false)
        graphicsWarmUpEnabled = Self.bool(defaults, Keys.graphicsWarmUpEnabled, fallback: false)
        playbackSpeed = PlaybackSpeed(
            rawValue: defaults.integer(forKey: Keys.playbackSpeed)
        ) ?? .normal
    }

    /// Stores the current values. Called by the settings UI after a change.
    func persist() {
        defaults.set(screenLayout.rawValue, forKey: Keys.screenLayout)
        defaults.set(screenAspect.rawValue, forKey: Keys.screenAspect)
        defaults.set(screenRotation.rawValue, forKey: Keys.screenRotation)
        defaults.set(integerScale, forKey: Keys.integerScale)
        defaults.set(renderScale, forKey: Keys.renderScale)
        defaults.set(orientation.rawValue, forKey: Keys.orientation)
        defaults.set(audioVolume, forKey: Keys.audioVolume)
        defaults.set(audioMuted, forKey: Keys.audioMuted)
        defaults.set(audioBuffer.rawValue, forKey: Keys.audioBuffer)
        defaults.set(showTouchControls, forKey: Keys.showTouchControls)
        defaults.set(controlsOpacity, forKey: Keys.controlsOpacity)
        defaults.set(haptics, forKey: Keys.haptics)
        defaults.set(frameCap.rawValue, forKey: Keys.frameCap)
        defaults.set(systemMetalHUD, forKey: Keys.systemMetalHUD)
        // Keep MTL_HUD_ENABLED in step with the switch: it is read when a
        // Metal device is created, so a change without a relaunch still applies
        // to the next device (the layer property switches the live layer).
        MetalHUD.apply(enabled: systemMetalHUD)
        defaults.set(graphicsWarmUpEnabled, forKey: Keys.graphicsWarmUpEnabled)
        defaults.set(playbackSpeed.rawValue, forKey: Keys.playbackSpeed)
    }

    // MARK: - Derived values

    /// Render scale clamped to the 1...4 the Metal view and the runtime accept.
    var clampedRenderScale: Int { Self.clampRenderScale(renderScale) }

    /// Render scale as a factor the Metal view can use.
    var renderScaleFactor: Double { Double(clampedRenderScale) }

    var audioVolumeFloat: Float { Float(audioVolume) }

    var controlsBackgroundOpacity: Double { Self.clampOpacity(controlsOpacity) }

    /// Fast-forward target as a plain number for the session and diagnostics.
    var playbackSpeedValue: Int { playbackSpeed.rawValue }

    // MARK: - Keys

    private enum Keys {
        static let screenLayout = "UI.screenLayout"
        static let screenAspect = "UI.screenAspect"
        static let screenRotation = "UI.screenRotation"
        static let integerScale = "UI.integerScale"
        static let renderScale = "UI.renderScale"
        // Earlier builds stored only this "double resolution" switch; read it
        // once to migrate it to renderScale.
        static let legacyRenderScaleDoubleX = "UI.renderScaleDoubleX"
        static let orientation = "UI.orientation"
        static let audioVolume = "UI.audioVolume"
        static let audioBuffer = "UI.audioBuffer"
        static let controlsOpacity = "UI.controlsOpacity"
        static let haptics = "UI.haptics"
        static let frameCap = "UI.frameCap"
        static let systemMetalHUD = "UI.systemMetalHUD"
        static let graphicsWarmUpEnabled = "UI.graphicsWarmUpEnabled"
        static let playbackSpeed = "UI.playbackSpeed"
        // Keys already used by earlier builds; kept so existing installs keep
        // their preference.
        static let showTouchControls = "I3.showTouchControls"
        static let audioMuted = "I3.audioMuted"
    }

    // MARK: - Helpers

    private static func bool(_ defaults: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    /// Clamps a render scale to the 1...4 both the drawable and the runtime's
    /// internal 3D renderer accept.
    static func clampRenderScale(_ value: Int) -> Int {
        min(max(value, 1), 4)
    }

    private static func clampVolume(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private static func clampOpacity(_ value: Double) -> Double {
        min(max(value, 0.15), 1.0)
    }
}
