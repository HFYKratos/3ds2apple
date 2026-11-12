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
//  applied by the game screen when a game is loaded; the screen layout is read
//  when the next game load starts, because it decides which presentation path
//  the load uses.
//

import Combine
import Foundation

/// How the upper and lower screen are arranged on screen.
///
/// The CAMetalLayer presentation draws the console layout (upper above lower)
/// in one drawable, so a different arrangement is shown from the two screen
/// images instead (the screen-readback path, slower than direct presentation).
enum ScreenLayout: String, CaseIterable, Identifiable {
    case stacked
    case sideBySide
    case upperOnly
    case lowerOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: return "Stacked (console)"
        case .sideBySide: return "Side by side"
        case .upperOnly: return "Upper screen only"
        case .lowerOnly: return "Lower screen only"
        }
    }

    var detail: String {
        switch self {
        case .stacked: return "Upper screen above the lower one, as on the console. Uses the fast presented path."
        case .sideBySide: return "Both screens in one row, for landscape. Uses the screen-readback path."
        case .upperOnly: return "Only the upper (3D) screen. Uses the screen-readback path."
        case .lowerOnly: return "Only the lower (touch) screen. Uses the screen-readback path."
        }
    }

    /// The CAMetalLayer presenter always draws the console layout; other
    /// layouts are loaded through `zk_create` + `zk_read_screen`.
    var usesPresentedPath: Bool {
        switch self {
        case .stacked: return true
        case .sideBySide, .upperOnly, .lowerOnly: return false
        }
    }
}

/// How the screens fill their area.
enum ScreenAspect: String, CaseIterable, Identifiable {
    /// Keep the console's own aspect (upper 400x240, lower 320x240).
    case native
    /// Stretch the console image to a 4:3 area. Distorts the picture.
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "Native (console)"
        case .stretch: return "Stretch to 4:3"
        }
    }
}

/// Orientation preference. Rotation still follows the device when the system
/// allows it; the app restricts the allowed orientations to this value.
enum OrientationLock: String, CaseIterable, Identifiable {
    case automatic
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
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
        case .low: return "Low latency"
        case .balanced: return "Balanced"
        case .stable: return "Stable"
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
        case .low: return "5 ms. Least delay, most sensitive to audio dropouts."
        case .balanced: return "10 ms. The default."
        case .stable: return "20 ms. Fewer dropouts, slightly more delay."
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

/// Persisted shell settings. One shared instance is injected through the view
/// tree; `SettingsView` and its reusable sections are the only writers.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var screenLayout: ScreenLayout
    @Published var screenAspect: ScreenAspect
    @Published var integerScale: Bool
    /// 1 = native 400x480 drawable, 2 = 800x960 drawable.
    @Published var renderScale: Int
    @Published var orientation: OrientationLock

    @Published var audioVolume: Double
    @Published var audioMuted: Bool
    @Published var audioBuffer: AudioBufferSize

    @Published var showTouchControls: Bool
    @Published var controlsOpacity: Double
    @Published var haptics: Bool

    @Published var showCustomHUD: Bool
    @Published var frameCap: FrameRateCap

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        screenLayout = ScreenLayout(
            rawValue: defaults.string(forKey: Keys.screenLayout) ?? ""
        ) ?? .stacked
        screenAspect = ScreenAspect(
            rawValue: defaults.string(forKey: Keys.screenAspect) ?? ""
        ) ?? .native
        integerScale = Self.bool(defaults, Keys.integerScale, fallback: false)
        renderScale = Self.bool(defaults, Keys.renderScaleDoubleX, fallback: false) ? 2 : 1
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

        showCustomHUD = Self.bool(defaults, Keys.showCustomHUD, fallback: true)
        frameCap = FrameRateCap(
            rawValue: defaults.integer(forKey: Keys.frameCap)
        ) ?? .sixty
    }

    /// Stores the current values. Called by the settings UI after a change.
    func persist() {
        defaults.set(screenLayout.rawValue, forKey: Keys.screenLayout)
        defaults.set(screenAspect.rawValue, forKey: Keys.screenAspect)
        defaults.set(integerScale, forKey: Keys.integerScale)
        defaults.set(renderScale >= 2, forKey: Keys.renderScaleDoubleX)
        defaults.set(orientation.rawValue, forKey: Keys.orientation)
        defaults.set(audioVolume, forKey: Keys.audioVolume)
        defaults.set(audioMuted, forKey: Keys.audioMuted)
        defaults.set(audioBuffer.rawValue, forKey: Keys.audioBuffer)
        defaults.set(showTouchControls, forKey: Keys.showTouchControls)
        defaults.set(controlsOpacity, forKey: Keys.controlsOpacity)
        defaults.set(haptics, forKey: Keys.haptics)
        defaults.set(showCustomHUD, forKey: Keys.showCustomHUD)
        defaults.set(frameCap.rawValue, forKey: Keys.frameCap)
    }

    // MARK: - Derived values

    /// Render scale as a factor the Metal view can use.
    var renderScaleFactor: Double { renderScale >= 2 ? 2 : 1 }

    var audioVolumeFloat: Float { Float(audioVolume) }

    var controlsBackgroundOpacity: Double { Self.clampOpacity(controlsOpacity) }

    // MARK: - Keys

    private enum Keys {
        static let screenLayout = "UI.screenLayout"
        static let screenAspect = "UI.screenAspect"
        static let integerScale = "UI.integerScale"
        static let renderScaleDoubleX = "UI.renderScaleDoubleX"
        static let orientation = "UI.orientation"
        static let audioVolume = "UI.audioVolume"
        static let audioBuffer = "UI.audioBuffer"
        static let showCustomHUD = "UI.showCustomHUD"
        static let controlsOpacity = "UI.controlsOpacity"
        static let haptics = "UI.haptics"
        static let frameCap = "UI.frameCap"
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

    private static func clampVolume(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private static func clampOpacity(_ value: Double) -> Double {
        min(max(value, 0.15), 1.0)
    }
}
