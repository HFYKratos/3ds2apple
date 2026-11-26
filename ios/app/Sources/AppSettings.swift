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
    /// Large upper screen with the lower one small at its lower right (the old
    /// round-0 landscape arrangement, kept for compatibility).
    case largeTop
    case upperOnly
    case lowerOnly
    /// Landscape "Large screen": the upper screen 400x240 on the left and the
    /// lower screen scaled by 1/2.25 (142.22x106.67) at the upper right;
    /// arrangement 542.22x240 (presenter layout size 543x240, ABI 5).
    case largeTopRight
    /// Landscape "Hybrid": the upper screen 400x240 on the left and a right
    /// column (177.78 = 320/1.8 wide) with the small upper screen
    /// (177.78x106.67) above the small lower screen (177.78x133.33);
    /// arrangement 577.78x240 (presenter layout size 578x240, ABI 6).
    case hybrid
    /// Portrait "Default" (top full width): the upper screen 400x240 on top and
    /// the lower screen scaled to the same width (400x300) below it;
    /// arrangement 400x540 (presenter layout size, ABI 7). Portrait only.
    case topFullWidth
    /// Round-0.1.6: the user-defined custom rectangles, drawn by the presenter
    /// with two arbitrary normalised viewports (ABI 8; fallback readback when
    /// the screen rotation is not upright or no presenter can be made).
    case custom

    var id: String { rawValue }

    /// The layout number the presenter and `zk_present_layout_size` take.
    ///
    /// The last three ids are the round-3 additions of the presenter patch
    /// (0008): ABI 5 LargeTopRight, 6 Hybrid, 7 TopFullWidth. They are passed as
    /// plain numbers on purpose so the app builds independently of the bridging
    /// header's constant names.
    var presenterValue: UInt32 {
        switch self {
        case .stacked: return UInt32(ZK_LAYOUT_STACKED)
        case .sideBySide: return UInt32(ZK_LAYOUT_SIDE_BY_SIDE)
        case .largeTop: return UInt32(ZK_LAYOUT_LARGE_TOP)
        case .upperOnly: return UInt32(ZK_LAYOUT_TOP_ONLY)
        case .lowerOnly: return UInt32(ZK_LAYOUT_BOTTOM_ONLY)
        case .largeTopRight: return 5
        case .hybrid: return 6
        case .topFullWidth: return 7
        case .custom: return 8
        }
    }
}

/// The landscape screen layout presets (round-2 split: landscape and portrait
/// are independent settings).
///
/// Display order is the case order: Large screen, Single screen, Side by side,
/// Hybrid, Original, Custom layout. Every choice except `custom` is a presenter
/// arrangement (round 3 adds LargeTopRight and Hybrid, presenter ABI 5-6); only
/// `custom` uses the app's own readback placement (see ScreenGeometry.swift and
/// CustomScreenLayout.swift).
///
/// The stored raw values are stable. The round-1 single choice is migrated in
/// `AppSettings.migratedScreenLayouts(fromLegacy:)`.
enum LandscapeScreenLayout: String, CaseIterable, Identifiable {
    /// Large upper screen left, the lower screen small at the top right.
    case large
    /// The upper screen only, maximised and centred.
    case single
    /// Upper screen left, lower screen right, at their native sizes.
    case side
    /// Upper 5:3 screen left, lower 4:3 screen right, both nearly full height.
    case hybrid
    /// Both screens at their native size, stacked as on the console.
    case original
    /// The hand-placed landscape rectangles from the numeric custom page.
    case custom

    /// The choice a fresh install starts on.
    static let defaultLayout: LandscapeScreenLayout = .large

    var id: String { rawValue }

    /// The presenter arrangement for the landscape direction, or nil when the
    /// readback placement draws this choice.
    var presenterLayout: ScreenLayout? {
        switch self {
        case .large: return .largeTopRight
        case .single: return .upperOnly
        case .side: return .sideBySide
        case .hybrid: return .hybrid
        case .original: return .stacked
        case .custom: return .custom
        }
    }

    var title: String {
        switch self {
        case .large: return L10n.tr("Large screen")
        case .single: return L10n.tr("Single screen")
        case .side: return L10n.tr("Side by side")
        case .hybrid: return L10n.tr("Hybrid")
        case .original: return L10n.tr("Original")
        case .custom: return L10n.tr("Custom layout")
        }
    }
}

/// The portrait screen layout presets (round-2 split): the separate portrait
/// setting, default first.
enum PortraitScreenLayout: String, CaseIterable, Identifiable {
    /// Top full width: the upper screen fills the width and the lower screen is
    /// scaled with it; the arrangement is top-aligned.
    case topFullWidth
    /// The native stack, both screens at the console's own pixel sizes.
    case original
    /// The hand-placed portrait rectangles from the numeric custom page.
    case custom

    /// The choice a fresh install starts on.
    static let defaultLayout: PortraitScreenLayout = .topFullWidth

    var id: String { rawValue }

    /// The presenter arrangement for the portrait direction, or nil when the
    /// readback placement draws this choice.
    var presenterLayout: ScreenLayout? {
        switch self {
        case .topFullWidth: return .topFullWidth
        case .original: return .stacked
        case .custom: return .custom
        }
    }

    var title: String {
        switch self {
        case .topFullWidth: return L10n.tr("Default")
        case .original: return L10n.tr("Original")
        case .custom: return L10n.tr("Custom layout")
        }
    }
}

/// The simplified on-screen control layout choice (0.1.3): the shipped default
/// positions, or a hand-edited profile per orientation.
///
/// The stored profiles (`UI.controlLayoutPortrait` / `...Landscape`, versioned
/// Codable data) are unchanged, so a 0.1.2 layout is kept; a 0.1.2 install is
/// treated as `custom` on upgrade so its saved positions keep applying.
enum ControlLayoutMode: String, CaseIterable, Identifiable {
    /// The shipped positions; nothing needs the editor.
    case standard
    /// The user's own positions, one profile per orientation.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return L10n.tr("Default")
        case .custom: return L10n.tr("Custom")
        }
    }

    var detail: String {
        switch self {
        case .standard:
            return L10n.tr("Default uses the shipped positions of every control, so nothing covers the picture in portrait.")
        case .custom:
            return L10n.tr("Custom lets you move and resize each control. Choosing Custom opens the full-screen editor for the direction the device is in now, with the current screen layout drawn behind the controls; each direction keeps its own layout.")
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
/// frame. 1× is normal speed; higher values run extra `zk_run_frame` calls
/// before the frame that is presented, so the game time advances that many
/// times faster (as long as the device keeps up; see the frame loop in
/// ROMSession). 3× was added in 0.1.7-beta5 for the General page's Default and
/// Turbo speed choices.
enum PlaybackSpeed: Int, CaseIterable, Identifiable {
    case normal = 1
    case double = 2
    case triple = 3
    case quadruple = 4

    var id: Int { rawValue }

    /// "1×", "2×", "3×", "4×": the same in both languages.
    var title: String { L10n.speedLabel(rawValue) }

    /// Whether this setting asks the runtime to advance more than one frame per
    /// presented frame.
    var isFastForward: Bool { rawValue > 1 }
}

/// Per-game presentation overrides keyed by title ID (0.2.0 MVP). Every field is
/// optional: nil means "use the global setting". Stored as raw values so the
/// archive stays stable if an enum name changes.
struct PerGameOverrides: Codable, Equatable {
    var screenRotationRaw: String? = nil
    var swapScreens: Bool? = nil
    var integerScale: Bool? = nil
    var screenAspectRaw: String? = nil
    /// Optional per-app Gamepad profile (0.2.0 C).
    var analogDeadzone: Double? = nil
    var controlAppearanceRaw: String? = nil
    var controllerButtonMap: [String: String]? = nil
}

/// The GitHub update channel on the General page: Stable ignores pre-releases,
/// Beta also looks at pre-release builds.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return L10n.tr("Stable")
        case .beta: return L10n.tr("Beta")
        }
    }
}

/// Physical-controller hotkey actions (0.2.0 final). A hotkey is a 2–4 button
/// combination of PhysicalControllerButton values.
enum HotkeyAction: String, CaseIterable, Identifiable, Hashable {
    case toggleTurbo
    case quickSave
    case quickLoad
    case swapScreens
    case rotateScreen
    case openMenu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleTurbo: return L10n.tr("Toggle Turbo")
        case .quickSave: return L10n.tr("Quick save")
        case .quickLoad: return L10n.tr("Quick load")
        case .swapScreens: return L10n.tr("Swap screens")
        case .rotateScreen: return L10n.tr("Rotate screen")
        case .openMenu: return L10n.tr("Open menu")
        }
    }

    var systemImage: String {
        switch self {
        case .toggleTurbo: return "forward.fill"
        case .quickSave: return "square.and.arrow.down"
        case .quickLoad: return "arrow.down.doc"
        case .swapScreens: return "arrow.left.arrow.right"
        case .rotateScreen: return "rotate.right"
        case .openMenu: return "pause.circle"
        }
    }
}

/// Built-in on-screen control appearance. Standard is the shipped translucent
/// dark style; High contrast uses opaque black/white edges and bigger strokes.
/// No Delta skin import (see TODO).
enum ControlAppearance: String, CaseIterable, Identifiable, Hashable {
    case standard
    case highContrast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return L10n.tr("Standard")
        case .highContrast: return L10n.tr("High contrast")
        }
    }
}

/// A physical controller button that can be remapped on the Gamepad page.
enum PhysicalControllerButton: String, CaseIterable, Identifiable, Hashable {
    case a, b, x, y
    case l, r, zl, zr
    case start, select
    case dpadUp, dpadDown, dpadLeft, dpadRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a: return L10n.tr("A")
        case .b: return L10n.tr("B")
        case .x: return L10n.tr("X")
        case .y: return L10n.tr("Y")
        case .l: return L10n.tr("L")
        case .r: return L10n.tr("R")
        case .zl: return L10n.tr("ZL")
        case .zr: return L10n.tr("ZR")
        case .start: return L10n.tr("Start")
        case .select: return L10n.tr("Select")
        case .dpadUp: return L10n.tr("D-pad Up")
        case .dpadDown: return L10n.tr("D-pad Down")
        case .dpadLeft: return L10n.tr("D-pad Left")
        case .dpadRight: return L10n.tr("D-pad Right")
        }
    }

    /// The controller button's default 3DS target (the stock mapping).
    var defaultAction: GamepadAction {
        switch self {
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .l: return .l
        case .r: return .r
        case .zl: return .zl
        case .zr: return .zr
        case .start: return .start
        case .select: return .select
        case .dpadUp: return .up
        case .dpadDown: return .down
        case .dpadLeft: return .left
        case .dpadRight: return .right
        }
    }
}

/// A 3DS HID button a physical controller button can be remapped to.
enum GamepadAction: String, CaseIterable, Identifiable, Hashable {
    case a, b, x, y
    case l, r, zl, zr
    case start, select
    case up, down, left, right

    var id: String { rawValue }

    var buttonBit: UInt32 {
        switch self {
        case .a: return ZKButton.a
        case .b: return ZKButton.b
        case .x: return ZKButton.x
        case .y: return ZKButton.y
        case .l: return ZKButton.l
        case .r: return ZKButton.r
        case .zl: return ZKButton.zl
        case .zr: return ZKButton.zr
        case .start: return ZKButton.start
        case .select: return ZKButton.select
        case .up: return ZKButton.up
        case .down: return ZKButton.down
        case .left: return ZKButton.left
        case .right: return ZKButton.right
        }
    }

    var title: String {
        switch self {
        case .a: return L10n.tr("A")
        case .b: return L10n.tr("B")
        case .x: return L10n.tr("X")
        case .y: return L10n.tr("Y")
        case .l: return L10n.tr("L")
        case .r: return L10n.tr("R")
        case .zl: return L10n.tr("ZL")
        case .zr: return L10n.tr("ZR")
        case .start: return L10n.tr("Start")
        case .select: return L10n.tr("Select")
        case .up: return L10n.tr("D-pad Up")
        case .down: return L10n.tr("D-pad Down")
        case .left: return L10n.tr("D-pad Left")
        case .right: return L10n.tr("D-pad Right")
        }
    }
}

/// The app-wide appearance choice on the System page. ContentView maps it to a
/// SwiftUI ColorScheme; the default follows the system exactly like before.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.tr("System")
        case .light: return L10n.tr("Light")
        case .dark: return L10n.tr("Dark")
        }
    }
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

/// The GPU backend behind the presented `CAMetalLayer`.
///
/// Zakuro's Vulkan renderer reaches Metal through MoltenVK, which is loaded at
/// run time from `Frameworks/MoltenVK.framework` in the app bundle (the
/// launcher's shell template embeds it; see scripts/package-ipa.sh). Without
/// that framework `zk_presenter_create` cannot make a Vulkan device, every load
/// falls back to the software PICA200 renderer (slow) and there is no Metal
/// layer for the system HUD to attach to. This is the first thing to check when
/// a device build feels slow or the HUD never appears.
enum MetalBackend {
    /// Bundle-relative path the runtime's iOS patch loads by default.
    static let moltenVKRelativePath = "Frameworks/MoltenVK.framework/MoltenVK"

    /// Absolute URL of the embedded MoltenVK binary, nil when absent.
    static var moltenVKURL: URL? {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let url = frameworks.appendingPathComponent("MoltenVK.framework/MoltenVK")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether this app bundle carries MoltenVK at all.
    static var isMoltenVKEmbedded: Bool { moltenVKURL != nil }

    /// Names the embedded framework to the runtime before it creates its first
    /// Vulkan device. The iOS patch already defaults to this path; setting the
    /// override makes the choice explicit in the log and keeps the lookup
    /// working if the patch's default ever changes.
    static func configureForLaunch() {
        if let path = moltenVKURL?.path {
            setenv("ZAKURO_VULKAN_LIBRARY", path, 1)
        } else {
            unsetenv("ZAKURO_VULKAN_LIBRARY")
        }
    }

    /// Stable English line for the device log and diagnostics.
    static var diagnosticsLine: String {
        if isMoltenVKEmbedded {
            return "moltenvk_embedded=1 path=@executable_path/\(moltenVKRelativePath)"
        }
        return "moltenvk_embedded=0 (software PICA200 renderer: the Metal layer/HUD path is unavailable)"
    }
}

/// Where the performance overlay sits over the game picture (0.2.1-beta4).
///
/// The six places are the two corners on each side plus the middle of the top
/// and bottom edges. The place is one stored choice, not one per direction, so
/// the overlay keeps the same place when the device turns; the overlay view
/// aligns itself inside the safe area, so a corner stays clear of the notch and
/// the home indicator in both directions.
enum PerformanceOverlayPosition: String, CaseIterable, Identifiable, Codable {
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    /// The choice name on the Settings page and on its radio selection page.
    var title: String {
        switch self {
        case .topLeft: return L10n.tr("Top left")
        case .topCenter: return L10n.tr("Top center")
        case .topRight: return L10n.tr("Top right")
        case .bottomLeft: return L10n.tr("Bottom left")
        case .bottomCenter: return L10n.tr("Bottom center")
        case .bottomRight: return L10n.tr("Bottom right")
        }
    }
}

/// Persisted shell settings. One shared instance is injected through the view
/// tree; `SettingsView` and its reusable sections are the only writers.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var screenAspect: ScreenAspect
    /// Turn the screens inside their area (see `ScreenRotation`).
    @Published var screenRotation: ScreenRotation
    /// Kept for compatibility with older archives/diagnostics: the display
    /// settings no longer expose aspect or integer scaling (the presets are
    /// presenter arrangements), so the values stay at their defaults.
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
    /// Analog-stick dead zone, 0...0.35, shared by the on-screen sticks and the
    /// physical controller thumbsticks.
    @Published var analogDeadzone: Double
    /// Built-in on-screen control appearance.
    @Published var controlAppearance: ControlAppearance
    /// Physical controller button -> 3DS button mapping (physical raw value ->
    /// GamepadAction raw value). Reset restores the identity mapping.
    @Published var controllerButtonMap: [String: String]
    /// Hotkey action raw value -> [PhysicalControllerButton raw value]. Empty
    /// when the hotkey is disabled. A hotkey is 2–4 buttons.
    @Published var hotkeys: [String: [String]]

    // MARK: In-game virtual control options (round 4)

    /// Rows the user hid from the pause menu's "Toggle controls" sheet, one set
    /// per device direction since 0.1.6-beta2 (the sheet edits the current
    /// direction). Size scales stay global.
    @Published var hiddenControlItemsPortrait: Set<ControlOptionItem>
    @Published var hiddenControlItemsLandscape: Set<ControlOptionItem>
    /// The on-screen Swap screens button: swaps which screen is drawn in the
    /// top/bottom place (persisted, applies to presenter and readback).
    @Published var swapScreens: Bool
    /// Per-row size scale (1.0 = 100%, supported range 0.10...2.0). Global; a
    /// row missing from the dictionary means 100%. Keys are
    /// ControlOptionItem raw values.
    @Published var controlSizeScales: [String: Double]

    // MARK: Editable layouts (requirements 7 + 8)

    /// The landscape screen layout preset (see `LandscapeScreenLayout`;
    /// default `.large`). Split from the portrait choice in round 2.
    @Published var landscapeScreenLayout: LandscapeScreenLayout
    /// The portrait screen layout preset (see `PortraitScreenLayout`; default
    /// `.topFullWidth`).
    @Published var portraitScreenLayout: PortraitScreenLayout
    /// Default / Custom for the on-screen controls (see `ControlLayoutMode`).
    @Published var controlLayoutMode: ControlLayoutMode
    /// The on-screen control layout, one profile per container shape.
    @Published var controlLayoutPortrait: ControlLayoutProfile
    @Published var controlLayoutLandscape: ControlLayoutProfile
    /// The hand-placed per-screen layout, one placement per orientation (only
    /// used by `.custom`). Archive version 2; see CustomScreenLayout.swift.
    @Published var customScreenLayout: CustomScreenLayout

    @Published var frameCap: FrameRateCap

    /// Show the system Metal Performance HUD (FPS / GPU time / memory) over the
    /// presented CAMetalLayer. ON by default since 0.1.0; applied to the layer
    /// at run time and remembered across launches. The Settings switch can turn
    /// it off, and a pre-0.1.0 install is migrated to on once (see init).
    @Published var systemMetalHUD: Bool

    // MARK: Performance overlay (0.2.1-beta4; opt-in since 0.2.2-beta3)

    /// The performance overlay drawn over the running game. It replaces the old
    /// FPS pill: one overlay that shows the frame rate, the frame generation
    /// time, the emulation speed, the memory the app is using and the memory
    /// still free, each line on its own. `GameView`
    /// draws it; these values only decide what it shows and where.
    /// OFF by default since 0.2.2-beta3 (it used to ship on): the overlay is
    /// opt-in, and turning it on shows the frame rate only. OFF hides the whole
    /// overlay.
    @Published var performanceOverlayEnabled: Bool
    /// Draw a translucent background behind the overlay text so it stays
    /// readable over bright game scenes. OFF by default.
    @Published var performanceOverlayBackground: Bool
    /// Which place over the game picture the overlay uses (see
    /// `PerformanceOverlayPosition`; top left by default).
    @Published var performanceOverlayPosition: PerformanceOverlayPosition
    /// The overlay's information lines. The shipped defaults since 0.2.2-beta3:
    /// only the frame rate on; frame generation time, speed, the app's memory
    /// use and the available memory off. An install still on the old default
    /// combination (0.2.1-beta4..0.2.2-beta2: enabled, frame rate + frame time
    /// + app memory on) is migrated once (see init).
    @Published var performanceOverlayShowFPS: Bool
    @Published var performanceOverlayShowFrameTime: Bool
    @Published var performanceOverlayShowSpeed: Bool
    @Published var performanceOverlayShowProcessMemory: Bool
    @Published var performanceOverlayShowAvailableMemory: Bool

    /// The old FPS pill switch, kept for compatibility (0.2.1-beta4). It is a
    /// mirror of `performanceOverlayEnabled`: the Settings page no longer shows
    /// it, the stored "UI.showFPS" key is still written on every save and by
    /// the 0.2.2-beta3 default migrations, so older builds and the diagnostics
    /// report keep reading a meaningful value, and the in-game pause menu's
    /// performance-stats row keeps working as the overlay's master switch.
    var showFPS: Bool {
        get { performanceOverlayEnabled }
        set { performanceOverlayEnabled = newValue }
    }

    /// Default speed target: 1×, 2×, 3× or 4× (see `PlaybackSpeed`).
    @Published var playbackSpeed: PlaybackSpeed
    /// The speed the on-screen Turbo (fast-forward) button uses: 2×, 3× or 4×.
    @Published var turboSpeed: PlaybackSpeed
    /// When on, the runtime may lower a Turbo speed automatically if the
    /// presented frame rate stays below the minimum (the "turbo limit").
    @Published var turboLimit: Bool
    /// When off, every presented frame advances guest frames until the hardware
    /// time budget is used, instead of stopping at the 4× speed clamp. Off also
    /// mutes audio and warns about heat/battery in Settings.
    @Published var runSpeedLimit: Bool
    /// Light/dark/system appearance for the whole app (System page).
    @Published var appearance: AppAppearance
    /// Check GitHub for a newer release when the General page appears (the
    /// switch does not run a background poller; the page does the lookup).
    @Published var checkForUpdates: Bool
    /// Stable or Beta GitHub release channel for the update check.
    @Published var updateChannel: UpdateChannel
    /// Per-game presentation overrides by upper-case title ID (0.2.0 MVP).
    @Published var perGameOverrides: [String: PerGameOverrides]

    // MARK: Experimental renderer options (Debug page; next app launch)

    /// Shade vertices on the GPU ("ZAKURO_GPU_SHADERS=1") instead of on the CPU.
    /// Experimental: App.init puts the switch into the environment and the
    /// runtime reads it while it makes the device for a game load, so a change
    /// here applies on the NEXT APP LAUNCH (the Debug page says so). OFF ships
    /// the renderer's own default.
    @Published var gpuVertexShaders: Bool
    /// Build the fragment shader with the release fast-math build (OFF) or with
    /// exact rounding (ON sets "ZAKURO_FRAG_FAST_MATH=0"). Experimental: it also
    /// applies on the NEXT APP LAUNCH for the same reason as
    /// gpuVertexShaders.
    @Published var preciseShading: Bool
    /// The six experimental renderer optimisations Settings -> Graphics exposes
    /// (0.2.2). One Codable value persisted in a single key
    /// ("UI.graphics.advanced"), all off by default; App.init puts the enabled
    /// ones into the environment, so a change applies on the NEXT APP LAUNCH.
    @Published var advancedGraphics: AdvancedGraphicsOptions

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

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
        let deadzone = defaults.object(forKey: Keys.analogDeadzone) as? Double ?? 0.14
        analogDeadzone = min(max(deadzone, 0), 0.35)
        controlAppearance = ControlAppearance(
            rawValue: defaults.string(forKey: Keys.controlAppearance) ?? ""
        ) ?? .standard
        if let data = defaults.data(forKey: Keys.controllerButtonMap),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            controllerButtonMap = decoded
        } else {
            controllerButtonMap = Self.defaultControllerButtonMap
        }
        if let data = defaults.data(forKey: Keys.hotkeys),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            hotkeys = decoded
        } else {
            hotkeys = [:]
        }

        // Layouts: every stored value is versioned Codable data. A missing or
        // unreadable entry falls back to the shipped default, so an install that
        // predates this feature keeps a usable layout and an older app reading a
        // newer profile does not crash.
        // Screen layouts (round 2): landscape and portrait are independent
        // settings with their own stored keys. The round-1 single choice is
        // migrated once (see migratedScreenLayouts(fromLegacy:)); a fresh or
        // unreadable install starts on the shipped defaults.
        let storedLandscape = defaults.string(forKey: Keys.landscapeScreenLayout)
        let storedPortrait = defaults.string(forKey: Keys.portraitScreenLayout)
        let migrated = Self.migratedScreenLayouts(
            fromLegacy: defaults.string(forKey: Keys.legacyScreenLayoutMode)
        )
        landscapeScreenLayout = LandscapeScreenLayout(
            rawValue: storedLandscape ?? ""
        ) ?? migrated.landscape
        portraitScreenLayout = PortraitScreenLayout(
            rawValue: storedPortrait ?? ""
        ) ?? migrated.portrait
        // Decode the control profiles into locals first: comparing them with
        // the shipped defaults must not touch `self` before every stored
        // property is initialised.
        let decodedControlPortrait = Self.decodeControlLayout(
            defaults, Keys.controlLayoutPortrait, orientation: .portrait
        )
        let decodedControlLandscape = Self.decodeControlLayout(
            defaults, Keys.controlLayoutLandscape, orientation: .landscape
        )
        // Shipped-default migration: a stored profile that is still an
        // untouched shipped default (0.2.0, the 0.2.1-beta1 skin layout, the
        // 0.2.1-beta2 layout with its MENU key, the 0.2.1-beta3 layout, or the
        // older round-5 beta3 / round 4 arrangements) moves to the current
        // 0.2.1-beta4 layout; a profile the user moved is kept unchanged. A
        // profile written before 0.2.1-beta3 may still carry the MENU placement
        // or lack the Settings placement; the decode above heals the current
        // elements and the migration ignores the removed MENU key, so an
        // untouched upgraded user lands on the current default.
        let storedControlPortrait = ControlLayoutProfile.migratingPreviousShippedDefault(
            decodedControlPortrait, for: .portrait
        )
        let storedControlLandscape = ControlLayoutProfile.migratingPreviousShippedDefault(
            decodedControlLandscape, for: .landscape
        )
        controlLayoutPortrait = storedControlPortrait
        controlLayoutLandscape = storedControlLandscape
        customScreenLayout = Self.decodeCustomScreenLayout(defaults, Keys.customScreenLayout)
        // Control layout: a 0.1.2 install always wrote its layout profiles (it
        // had no Default/Custom flag). On upgrade a profile that differs from
        // the shipped default means the user positioned controls, so the mode
        // becomes Custom and those positions keep applying; untouched defaults
        // (and a fresh install) start on Default.
        if let storedMode = defaults.string(forKey: Keys.controlLayoutMode),
           let mode = ControlLayoutMode(rawValue: storedMode) {
            controlLayoutMode = mode
        } else if storedControlPortrait != .standard(for: .portrait)
                    || storedControlLandscape != .standard(for: .landscape) {
            controlLayoutMode = .custom
        } else {
            controlLayoutMode = .standard
        }
        // In-game virtual-control options: the hidden rows became per direction
        // in 0.1.6-beta2. Migrate the old global set once: an empty/absent old
        // set gets the current shipped defaults (see
        // defaultHiddenItems(for:)); a customised old set is copied to both
        // directions unchanged.
        let storedHidden = defaults.stringArray(forKey: Keys.hiddenControlItems)
            .map { Set($0.compactMap(ControlOptionItem.init(rawValue:))) }
        if defaults.object(forKey: Keys.hiddenControlItemsMigrated) == nil {
            let old = storedHidden ?? []
            let portraitSet: Set<ControlOptionItem>
            let landscapeSet: Set<ControlOptionItem>
            if old.isEmpty {
                portraitSet = Self.defaultHiddenItems(for: .portrait)
                landscapeSet = Self.defaultHiddenItems(for: .landscape)
            } else {
                portraitSet = old
                landscapeSet = old
            }
            hiddenControlItemsPortrait = portraitSet
            hiddenControlItemsLandscape = landscapeSet
            // Persist the migrated sets now: the marker below makes this branch run
            // once, and a later launch reads the per-direction keys. Without this
            // write the shipped defaults lived only in this process.
            defaults.set(portraitSet.map(\.rawValue).sorted(),
                         forKey: Keys.hiddenControlItemsPortraitKey)
            defaults.set(landscapeSet.map(\.rawValue).sorted(),
                         forKey: Keys.hiddenControlItemsLandscapeKey)
            defaults.set(true, forKey: Keys.hiddenControlItemsMigrated)
            AppLog.log("[3ds2apple] virtual controls: hidden rows migrated to per-direction defaults (%@)",
                       old.isEmpty ? "shipped defaults" : "custom set copied")
        } else {
            let portrait = defaults.stringArray(forKey: Keys.hiddenControlItemsPortraitKey)
            let landscape = defaults.stringArray(forKey: Keys.hiddenControlItemsLandscapeKey)
            hiddenControlItemsPortrait = Set((portrait ?? []).compactMap(ControlOptionItem.init(rawValue:)))
            hiddenControlItemsLandscape = Set((landscape ?? []).compactMap(ControlOptionItem.init(rawValue:)))
        }
        // 0.2.1: the shipped default layouts now follow the ModernFS (portrait) /
        // ModernHybrid (landscape) reference skins, which draw neither ZL/ZR nor
        // a C-stick and do draw the portrait D-pad. An untouched 0.2.0 shipped
        // hidden set (see legacyDefaultHiddenItems(for:)) becomes the new shipped
        // set once; a customised set is kept. The marker makes this run once, and
        // the sets are written back because a later launch reads the per-direction
        // keys instead of these defaults.
        if defaults.object(forKey: Keys.hiddenControlItemsSkinDefaultsMigrated) == nil {
            // Read the sets back from UserDefaults: the block above either wrote
            // the migrated 0.1.5 sets or just loaded the per-direction keys, and
            // reading the @Published properties here would touch `self` before
            // every stored property is initialised.
            var portrait = Set((defaults.stringArray(forKey: Keys.hiddenControlItemsPortraitKey) ?? [])
                .compactMap(ControlOptionItem.init(rawValue:)))
            var landscape = Set((defaults.stringArray(forKey: Keys.hiddenControlItemsLandscapeKey) ?? [])
                .compactMap(ControlOptionItem.init(rawValue:)))
            if portrait == Self.legacyDefaultHiddenItems(for: .portrait) {
                portrait = Self.defaultHiddenItems(for: .portrait)
            }
            if landscape == Self.legacyDefaultHiddenItems(for: .landscape) {
                landscape = Self.defaultHiddenItems(for: .landscape)
            }
            hiddenControlItemsPortrait = portrait
            hiddenControlItemsLandscape = landscape
            defaults.set(portrait.map(\.rawValue).sorted(),
                         forKey: Keys.hiddenControlItemsPortraitKey)
            defaults.set(landscape.map(\.rawValue).sorted(),
                         forKey: Keys.hiddenControlItemsLandscapeKey)
            defaults.set(true, forKey: Keys.hiddenControlItemsSkinDefaultsMigrated)
            AppLog.log("[3ds2apple] virtual controls: hidden rows migrated to the 0.2.1 skin defaults (%@ / %@)",
                       portrait.map(\.rawValue).sorted().joined(separator: ","),
                       landscape.map(\.rawValue).sorted().joined(separator: ","))
        }
        // 0.2.1-beta3: fastForward / swapScreens join the shipped hidden rows
        // (the reference skins draw neither, and beta2 showed them in the app
        // bands). An untouched beta1/beta2 shipped set (see
        // betaTwoDefaultHiddenItems(for:)) becomes the new shipped set once; a
        // set the user changed is kept. The marker makes this run once, and the
        // sets are written back because a later launch reads the per-direction
        // keys instead of these defaults.
        if defaults.object(forKey: Keys.hiddenControlItemsBetaTwoDefaultsMigrated) == nil {
            var portrait = Set((defaults.stringArray(forKey: Keys.hiddenControlItemsPortraitKey) ?? [])
                .compactMap(ControlOptionItem.init(rawValue:)))
            var landscape = Set((defaults.stringArray(forKey: Keys.hiddenControlItemsLandscapeKey) ?? [])
                .compactMap(ControlOptionItem.init(rawValue:)))
            if portrait == Self.betaTwoDefaultHiddenItems(for: .portrait) {
                portrait = Self.defaultHiddenItems(for: .portrait)
            }
            if landscape == Self.betaTwoDefaultHiddenItems(for: .landscape) {
                landscape = Self.defaultHiddenItems(for: .landscape)
            }
            hiddenControlItemsPortrait = portrait
            hiddenControlItemsLandscape = landscape
            defaults.set(portrait.map(\.rawValue).sorted(),
                         forKey: Keys.hiddenControlItemsPortraitKey)
            defaults.set(landscape.map(\.rawValue).sorted(),
                         forKey: Keys.hiddenControlItemsLandscapeKey)
            defaults.set(true, forKey: Keys.hiddenControlItemsBetaTwoDefaultsMigrated)
            AppLog.log("[3ds2apple] virtual controls: hidden rows migrated to the 0.2.1-beta3 defaults (%@ / %@)",
                       portrait.map(\.rawValue).sorted().joined(separator: ","),
                       landscape.map(\.rawValue).sorted().joined(separator: ","))
        }
        // 0.2.1-beta5: the Settings button can never be hidden (it is the only
        // in-game entry into Settings since beta3 removed the MENU row). Builds
        // up to beta4 offered it in Toggle controls, so drop it from both stored
        // sets on load and write the cleaned sets back. Read them from
        // UserDefaults for the same reason as the migrations above: touching the
        // @Published properties here would access `self` before every stored
        // property is initialised.
        let storedPortraitHidden = Set((defaults.stringArray(forKey: Keys.hiddenControlItemsPortraitKey) ?? [])
            .compactMap(ControlOptionItem.init(rawValue:)))
        let storedLandscapeHidden = Set((defaults.stringArray(forKey: Keys.hiddenControlItemsLandscapeKey) ?? [])
            .compactMap(ControlOptionItem.init(rawValue:)))
        let portraitHidden = Self.sanitizedHiddenItems(storedPortraitHidden)
        let landscapeHidden = Self.sanitizedHiddenItems(storedLandscapeHidden)
        hiddenControlItemsPortrait = portraitHidden
        hiddenControlItemsLandscape = landscapeHidden
        if portraitHidden != storedPortraitHidden {
            defaults.set(portraitHidden.map(\.rawValue).sorted(),
                         forKey: Keys.hiddenControlItemsPortraitKey)
        }
        if landscapeHidden != storedLandscapeHidden {
            defaults.set(landscapeHidden.map(\.rawValue).sorted(),
                         forKey: Keys.hiddenControlItemsLandscapeKey)
        }
        if portraitHidden != storedPortraitHidden || landscapeHidden != storedLandscapeHidden {
            AppLog.log("[3ds2apple] virtual controls: the Settings button was restored from the hidden rows")
        }
        if let data = defaults.data(forKey: Keys.controlSizeScales),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            controlSizeScales = decoded
        } else {
            controlSizeScales = [:]
        }
        swapScreens = defaults.bool(forKey: Keys.swapScreens)

        // The performance page no longer offers a frame cap: the console
        // timeline runs at its native 60 Hz and Fast-forward is the only
        // speed control, so an old stored 30 fps value is ignored on purpose.
        frameCap = .sixty

        // System Metal HUD: OFF by default since 0.1.6-beta3, including a
        // one-time migration that turns it off for every existing install. The
        // migration marker makes it run exactly once; afterwards the user's
        // Settings toggle (on or off) is the stored value and wins.
        if defaults.object(forKey: Keys.systemMetalHUDDefaultOffMigrated) == nil {
            systemMetalHUD = false
            defaults.set(false, forKey: Keys.systemMetalHUD)
            defaults.set(true, forKey: Keys.systemMetalHUDDefaultOffMigrated)
            AppLog.log("[3ds2apple] system Metal HUD: disabled by the 0.1.6 default migration")
        } else if defaults.object(forKey: Keys.systemMetalHUD) != nil {
            systemMetalHUD = defaults.bool(forKey: Keys.systemMetalHUD)
        } else {
            systemMetalHUD = false
        }
        // Performance overlay (0.2.1-beta4; OFF by default since 0.2.2-beta3).
        // The overlay replaces the FPS pill, but the shipped default is now off
        // with only the frame-rate line on. Both migrations below work on local
        // copies: reading the @Published properties this early would touch
        // `self` before every stored property is initialised.
        let overlayMigrated = defaults.object(forKey: Keys.performanceOverlayMigrated) != nil
        var overlayEnabled = false
        var overlayBackground = false
        var overlayPosition = PerformanceOverlayPosition.topLeft
        var overlayShowFPS = true
        var overlayShowFrameTime = false
        var overlayShowSpeed = false
        var overlayShowProcessMemory = false
        var overlayShowAvailableMemory = false
        if !overlayMigrated {
            // An install that predates the overlay has only the FPS pill's
            // "UI.showFPS" key. The pill was on by default, but the overlay is
            // off by default now, so an untouched upgrade lands on the new
            // default: master switch off, only the frame-rate line on. The
            // marker makes this run exactly once, and the user's later choices
            // (including turning the overlay on) win from then on.
            defaults.set(false, forKey: Keys.performanceOverlayEnabled)
            defaults.set(false, forKey: Keys.showFPS)
            defaults.set(false, forKey: Keys.performanceOverlayBackground)
            defaults.set(PerformanceOverlayPosition.topLeft.rawValue,
                         forKey: Keys.performanceOverlayPosition)
            defaults.set(true, forKey: Keys.performanceOverlayShowFPS)
            defaults.set(false, forKey: Keys.performanceOverlayShowFrameTime)
            defaults.set(false, forKey: Keys.performanceOverlayShowSpeed)
            defaults.set(false, forKey: Keys.performanceOverlayShowProcessMemory)
            defaults.set(false, forKey: Keys.performanceOverlayShowAvailableMemory)
            defaults.set(true, forKey: Keys.performanceOverlayMigrated)
            AppLog.log("[3ds2apple] performance overlay: moved from the FPS pill to the 0.2.2-beta3 default (off, frame rate only)")
        } else {
            overlayEnabled = Self.bool(
                defaults, Keys.performanceOverlayEnabled, fallback: false)
            overlayBackground = Self.bool(
                defaults, Keys.performanceOverlayBackground, fallback: false)
            overlayPosition = PerformanceOverlayPosition(
                rawValue: defaults.string(forKey: Keys.performanceOverlayPosition) ?? ""
            ) ?? .topLeft
            overlayShowFPS = Self.bool(
                defaults, Keys.performanceOverlayShowFPS, fallback: true)
            overlayShowFrameTime = Self.bool(
                defaults, Keys.performanceOverlayShowFrameTime, fallback: false)
            overlayShowSpeed = Self.bool(
                defaults, Keys.performanceOverlayShowSpeed, fallback: false)
            overlayShowProcessMemory = Self.bool(
                defaults, Keys.performanceOverlayShowProcessMemory, fallback: false)
            overlayShowAvailableMemory = Self.bool(
                defaults, Keys.performanceOverlayShowAvailableMemory, fallback: false)
        }
        // 0.2.2-beta3 default migration: the overlay used to ship enabled with
        // the frame rate, the frame time and the app-memory lines on (background
        // off, speed/available memory off, top left). An install still on
        // exactly that combination moves to the new default (off; only the frame
        // rate line on); any other combination was chosen by the user and is
        // kept unchanged. The marker makes this run exactly once, and the old
        // FPS-pill mirror "UI.showFPS" is written along with the master switch.
        if defaults.object(forKey: Keys.performanceOverlayBeta3DefaultsMigrated) == nil {
            let onOldDefaultCombination = overlayEnabled
                && overlayShowFPS
                && overlayShowFrameTime
                && overlayShowProcessMemory
                && !overlayShowSpeed
                && !overlayShowAvailableMemory
                && !overlayBackground
                && overlayPosition == .topLeft
            if onOldDefaultCombination {
                overlayEnabled = false
                overlayShowFrameTime = false
                overlayShowProcessMemory = false
                defaults.set(false, forKey: Keys.performanceOverlayEnabled)
                defaults.set(false, forKey: Keys.showFPS)
                defaults.set(false, forKey: Keys.performanceOverlayShowFrameTime)
                defaults.set(false, forKey: Keys.performanceOverlayShowProcessMemory)
                AppLog.log("[3ds2apple] performance overlay: moved the old default combination to the 0.2.2-beta3 default (off, frame rate only)")
            }
            defaults.set(true, forKey: Keys.performanceOverlayBeta3DefaultsMigrated)
        }
        performanceOverlayEnabled = overlayEnabled
        performanceOverlayBackground = overlayBackground
        performanceOverlayPosition = overlayPosition
        performanceOverlayShowFPS = overlayShowFPS
        performanceOverlayShowFrameTime = overlayShowFrameTime
        performanceOverlayShowSpeed = overlayShowSpeed
        performanceOverlayShowProcessMemory = overlayShowProcessMemory
        performanceOverlayShowAvailableMemory = overlayShowAvailableMemory
        playbackSpeed = PlaybackSpeed(
            rawValue: defaults.integer(forKey: Keys.playbackSpeed)
        ) ?? .normal
        let storedTurbo = defaults.integer(forKey: Keys.turboSpeed)
        turboSpeed = (storedTurbo == 2 || storedTurbo == 3 || storedTurbo == 4)
            ? (PlaybackSpeed(rawValue: storedTurbo) ?? .double)
            : .double
        turboLimit = Self.bool(defaults, Keys.turboLimit, fallback: true)
        runSpeedLimit = Self.bool(defaults, Keys.runSpeedLimit, fallback: true)
        updateChannel = UpdateChannel(
            rawValue: defaults.string(forKey: Keys.updateChannel) ?? ""
        ) ?? .stable
        appearance = AppAppearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
        checkForUpdates = Self.bool(defaults, Keys.checkForUpdates, fallback: true)
        if let data = defaults.data(forKey: Keys.perGameOverrides),
           let decoded = try? JSONDecoder().decode([String: PerGameOverrides].self, from: data) {
            perGameOverrides = decoded
        } else {
            perGameOverrides = [:]
        }
        // Debug page's experimental renderer options, both OFF by default: the
        // values are read by App.init and only take effect on the next app launch.
        gpuVertexShaders = Self.bool(defaults, Keys.gpuVertexShaders, fallback: false)
        preciseShading = Self.bool(defaults, Keys.preciseShading, fallback: false)
        // Six experimental renderer optimisations (Settings -> Graphics): one
        // Codable value under one key, all off when the key is missing or not
        // readable (every build before 0.2.2 has no such key).
        if let data = defaults.data(forKey: Keys.advancedGraphics),
           let decoded = try? JSONDecoder().decode(AdvancedGraphicsOptions.self, from: data) {
            advancedGraphics = decoded
        } else {
            advancedGraphics = .none
        }
    }

    /// Stores the current values. Called by the settings UI after a change.
    func persist() {
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
        defaults.set(analogDeadzone, forKey: Keys.analogDeadzone)
        defaults.set(controlAppearance.rawValue, forKey: Keys.controlAppearance)
        if let data = try? JSONEncoder().encode(controllerButtonMap) {
            defaults.set(data, forKey: Keys.controllerButtonMap)
        }
        if let data = try? JSONEncoder().encode(hotkeys) {
            defaults.set(data, forKey: Keys.hotkeys)
        }
        defaults.set(frameCap.rawValue, forKey: Keys.frameCap)
        defaults.set(systemMetalHUD, forKey: Keys.systemMetalHUD)
        // Keep MTL_HUD_ENABLED in step with the switch: it is read when a
        // Metal device is created, so a change without a relaunch still applies
        // to the next device (the layer property switches the live layer).
        MetalHUD.apply(enabled: systemMetalHUD)
        // The old "UI.showFPS" key stays in sync with the overlay's master switch
        // (off by default since 0.2.2-beta3) so pre-0.2.1-beta4 builds and the
        // diagnostics report keep reading a meaningful value; the overlay's own
        // keys follow.
        defaults.set(showFPS, forKey: Keys.showFPS)
        defaults.set(performanceOverlayEnabled, forKey: Keys.performanceOverlayEnabled)
        defaults.set(performanceOverlayBackground, forKey: Keys.performanceOverlayBackground)
        defaults.set(performanceOverlayPosition.rawValue, forKey: Keys.performanceOverlayPosition)
        defaults.set(performanceOverlayShowFPS, forKey: Keys.performanceOverlayShowFPS)
        defaults.set(performanceOverlayShowFrameTime, forKey: Keys.performanceOverlayShowFrameTime)
        defaults.set(performanceOverlayShowSpeed, forKey: Keys.performanceOverlayShowSpeed)
        defaults.set(performanceOverlayShowProcessMemory, forKey: Keys.performanceOverlayShowProcessMemory)
        defaults.set(performanceOverlayShowAvailableMemory, forKey: Keys.performanceOverlayShowAvailableMemory)
        defaults.set(playbackSpeed.rawValue, forKey: Keys.playbackSpeed)
        defaults.set(turboSpeed.rawValue, forKey: Keys.turboSpeed)
        defaults.set(turboLimit, forKey: Keys.turboLimit)
        defaults.set(runSpeedLimit, forKey: Keys.runSpeedLimit)
        defaults.set(updateChannel.rawValue, forKey: Keys.updateChannel)
        defaults.set(appearance.rawValue, forKey: Keys.appearance)
        defaults.set(checkForUpdates, forKey: Keys.checkForUpdates)
        if let data = try? JSONEncoder().encode(perGameOverrides) {
            defaults.set(data, forKey: Keys.perGameOverrides)
        }
        // Experimental renderer options: App.init reads them on the next launch.
        defaults.set(gpuVertexShaders, forKey: Keys.gpuVertexShaders)
        defaults.set(preciseShading, forKey: Keys.preciseShading)
        // The six experimental renderer optimisations: one Codable value under
        // one key, so the group is written atomically (not eight loose defaults).
        if let data = try? JSONEncoder().encode(advancedGraphics) {
            defaults.set(data, forKey: Keys.advancedGraphics)
        } else {
            defaults.removeObject(forKey: Keys.advancedGraphics)
        }
        // Editable layouts (versioned Codable data; see the init).
        defaults.set(landscapeScreenLayout.rawValue, forKey: Keys.landscapeScreenLayout)
        defaults.set(portraitScreenLayout.rawValue, forKey: Keys.portraitScreenLayout)
        defaults.set(controlLayoutMode.rawValue, forKey: Keys.controlLayoutMode)
        if let data = controlLayoutPortrait.withDefaultsFilled(for: .portrait).encoded() {
            defaults.set(data, forKey: Keys.controlLayoutPortrait)
        }
        if let data = controlLayoutLandscape.withDefaultsFilled(for: .landscape).encoded() {
            defaults.set(data, forKey: Keys.controlLayoutLandscape)
        }
        if let data = customScreenLayout.encoded() {
            defaults.set(data, forKey: Keys.customScreenLayout)
        }
        // In-game virtual-control options (per-direction hidden rows since
        // 0.1.6-beta2, global size scales).
        defaults.set(hiddenControlItemsPortrait.map(\.rawValue).sorted(),
                     forKey: Keys.hiddenControlItemsPortraitKey)
        defaults.set(hiddenControlItemsLandscape.map(\.rawValue).sorted(),
                     forKey: Keys.hiddenControlItemsLandscapeKey)
        defaults.set(swapScreens, forKey: Keys.swapScreens)
        if let data = try? JSONEncoder().encode(controlSizeScales) {
            defaults.set(data, forKey: Keys.controlSizeScales)
        }
    }

    // MARK: - Derived values

    /// Render scale clamped to the 1...4 the Metal view and the runtime accept.
    var clampedRenderScale: Int { Self.clampRenderScale(renderScale) }

    /// Render scale as a factor the Metal view can use.
    var renderScaleFactor: Double { Double(clampedRenderScale) }

    var audioVolumeFloat: Float { Float(audioVolume) }

    var controlsBackgroundOpacity: Double { Self.clampOpacity(controlsOpacity) }

    /// The presenter arrangement for a direction. Choices the presenter cannot
    /// draw return a sensible fallback; those directions use the readback path
    /// instead (see `usesReadbackPresentation(isLandscape:)`).
    func effectiveScreenLayout(isLandscape: Bool) -> ScreenLayout {
        if isLandscape {
            return landscapeScreenLayout.presenterLayout ?? .largeTop
        }
        return portraitScreenLayout.presenterLayout ?? .stacked
    }

    /// Whether this direction's picture is drawn by the app's own readback
    /// placement instead of the presenter. Every preset is a presenter
    /// arrangement; the custom layout is a GPU presenter arrangement too since
    /// 0.1.6, except while the screen rotation is not upright (the v1 custom
    /// presenter ABI only handles the upright orientation, so that case keeps
    /// the readback placement).
    func usesReadbackPresentation(isLandscape: Bool) -> Bool {
        // 0.1.6-beta2: every custom rotation is a GPU presenter layout. Only a
        // device where no presenter can be made keeps the readback fallback,
        // which is decided at runtime by ROMSession.
        false
    }

    /// The title of the active choice for one direction (the Settings rows).
    func screenLayoutTitle(isLandscape: Bool) -> String {
        isLandscape ? landscapeScreenLayout.title : portraitScreenLayout.title
    }

    /// The stored raw value of the active choice for one direction
    /// (diagnostics).
    func screenLayoutRawValue(isLandscape: Bool) -> String {
        isLandscape ? landscapeScreenLayout.rawValue : portraitScreenLayout.rawValue
    }

    /// Selects the custom-layout choice for one direction. The numeric custom
    /// page and the drag editor call this so editing a custom layout also makes
    /// it the active choice.
    func selectCustomScreenLayout(for orientation: ControlLayoutOrientation) {
        switch orientation {
        case .landscape: landscapeScreenLayout = .custom
        case .portrait: portraitScreenLayout = .custom
        }
    }

    /// Whether the active choice for one direction is the custom layout.
    func usesCustomLayout(for orientation: ControlLayoutOrientation) -> Bool {
        switch orientation {
        case .landscape: return landscapeScreenLayout == .custom
        case .portrait: return portraitScreenLayout == .custom
        }
    }

    /// The control profile the runtime should draw: the shipped default in
    /// Default mode, the stored (possibly edited) profile in Custom mode.
    func controlLayout(for orientation: ControlLayoutOrientation) -> ControlLayoutProfile {
        controlLayoutMode == .custom ? storedControlLayout(for: orientation) : .standard(for: orientation)
    }

    /// The stored profile, regardless of the Default/Custom choice. The editor
    /// starts from the effective profile and writes the edited one here.
    func storedControlLayout(for orientation: ControlLayoutOrientation) -> ControlLayoutProfile {
        switch orientation {
        case .portrait: return controlLayoutPortrait
        case .landscape: return controlLayoutLandscape
        }
    }

    func setControlLayout(_ profile: ControlLayoutProfile,
                          for orientation: ControlLayoutOrientation) {
        switch orientation {
        case .portrait: controlLayoutPortrait = profile.withDefaultsFilled(for: .portrait)
        case .landscape: controlLayoutLandscape = profile.withDefaultsFilled(for: .landscape)
        }
    }

    // MARK: - In-game virtual control options (round 4)

    /// Supported per-row size scale range (10%-200%).
    static let controlSizeScaleRange: ClosedRange<Double> = 0.10...2.0

    static func clampControlSizeScale(_ value: Double) -> Double {
        min(max(value, controlSizeScaleRange.lowerBound), controlSizeScaleRange.upperBound)
    }

    /// The shipped hidden rows (0.2.1-beta3): both reference skins draw neither
    /// ZL/ZR nor a C-stick, and they draw no fast-forward / swap-screens item
    /// either, so those five stay hidden in both directions (the layout still
    /// places them as design fill-ins in the top-centre row so the user can find
    /// and move them after enabling them); every control the skins do draw is
    /// visible, including the portrait D-pad, which the ModernFS skin places in
    /// the band below the picture (0.1.6-0.2.0 additionally hid it in portrait).
    /// The app-only Settings button added in 0.2.1-beta2 ships visible in both
    /// directions and can never be hidden (its MENU sibling was removed in
    /// beta3); the default set below therefore never contains it.
    static func defaultHiddenItems(
        for orientation: ControlLayoutOrientation
    ) -> Set<ControlOptionItem> {
        switch orientation {
        case .portrait, .landscape:
            return [.cStick, .buttonZL, .buttonZR, .fastForward, .swapScreens]
        }
    }

    /// The 0.1.6-0.2.0 shipped hidden rows, kept only to recognise an untouched
    /// stored default during the 0.2.1 migration: both directions hid the
    /// C-stick and the two triggers, portrait also hid the D-pad.
    static func legacyDefaultHiddenItems(
        for orientation: ControlLayoutOrientation
    ) -> Set<ControlOptionItem> {
        var items: Set<ControlOptionItem> = [.cStick, .buttonZL, .buttonZR]
        if orientation == .portrait { items.insert(.dpad) }
        return items
    }

    /// The 0.2.1-beta1/beta2 shipped hidden rows, kept only to recognise an
    /// untouched stored default during the one-time 0.2.1-beta3 migration: both
    /// directions hid the C-stick and the two triggers; fastForward and
    /// swapScreens still shipped visible back then.
    static func betaTwoDefaultHiddenItems(
        for orientation: ControlLayoutOrientation
    ) -> Set<ControlOptionItem> {
        switch orientation {
        case .portrait, .landscape:
            return [.cStick, .buttonZL, .buttonZR]
        }
    }

    /// Drops rows that cannot be hidden from a stored or migrated hidden set.
    /// Only the Settings button is in that group (see
    /// `ControlOptionItem.canToggleVisibility`): older builds could hide it, so
    /// every load sanitises both directions and the UI can no longer write it.
    static func sanitizedHiddenItems(_ items: Set<ControlOptionItem>) -> Set<ControlOptionItem> {
        Set(items.filter { $0.canToggleVisibility })
    }

    private func hiddenItems(for orientation: ControlLayoutOrientation) -> Set<ControlOptionItem> {
        orientation == .landscape ? hiddenControlItemsLandscape : hiddenControlItemsPortrait
    }

    /// Whether one control element is drawn and hit-testable right now. A row
    /// that cannot be toggled (the Settings button) is always visible.
    func isControlVisible(_ element: ControlElement,
                          orientation: ControlLayoutOrientation) -> Bool {
        let item = ControlOptionItem.item(containing: element)
        guard item.canToggleVisibility else { return true }
        return !hiddenItems(for: orientation).contains(item)
    }

    /// Whether one option row (control or D-pad group) is visible in a direction.
    /// The Settings row is always visible: it is no longer offered in Toggle
    /// controls, and the guard also covers a stale stored set.
    func isControlItemVisible(_ item: ControlOptionItem,
                              orientation: ControlLayoutOrientation) -> Bool {
        guard item.canToggleVisibility else { return true }
        return !hiddenItems(for: orientation).contains(item)
    }

    func setControlItem(_ item: ControlOptionItem,
                        visible: Bool,
                        orientation: ControlLayoutOrientation) {
        // The Settings button cannot be hidden: Toggle controls no longer lists
        // it, and this guard stops any other caller from storing it.
        guard item.canToggleVisibility else { return }
        if orientation == .landscape {
            if visible { hiddenControlItemsLandscape.remove(item) }
            else { hiddenControlItemsLandscape.insert(item) }
        } else {
            if visible { hiddenControlItemsPortrait.remove(item) }
            else { hiddenControlItemsPortrait.insert(item) }
        }
    }

    /// The size multiplier of one control element (1.0 = the profile size).
    func controlSizeScale(for element: ControlElement) -> Double {
        controlSizeScale(for: ControlOptionItem.item(containing: element))
    }

    /// The size multiplier of one option row (controls and the D-pad group).
    func controlSizeScale(for item: ControlOptionItem) -> Double {
        Self.clampControlSizeScale(controlSizeScales[item.rawValue] ?? 1.0)
    }

    func setControlSizeScale(_ scale: Double, for item: ControlOptionItem) {
        controlSizeScales[item.rawValue] = Self.clampControlSizeScale(scale)
    }

    /// Restores the shipped placements for both orientations, every row to
    /// 100% and the shipped hidden rows (the pause menu's Reset action).
    func resetVirtualControls() {
        controlLayoutMode = .standard
        controlLayoutPortrait = .standard(for: .portrait)
        controlLayoutLandscape = .standard(for: .landscape)
        hiddenControlItemsPortrait = Self.defaultHiddenItems(for: .portrait)
        hiddenControlItemsLandscape = Self.defaultHiddenItems(for: .landscape)
        controlSizeScales = [:]
        persist()
    }

    /// Default-speed target as a plain number for the session and diagnostics.
    var playbackSpeedValue: Int { playbackSpeed.rawValue }

    /// Turbo speed as a plain number for the on-screen Turbo button.
    var turboSpeedValue: Int { turboSpeed.rawValue }

    // MARK: - Per-game presentation overrides (0.2.0 MVP)

    /// The overrides stored for a game, or nil when it follows the globals.
    func overrides(for titleID: String?) -> PerGameOverrides? {
        guard let titleID, !titleID.isEmpty else { return nil }
        return perGameOverrides[titleID.uppercased()]
    }

    func effectiveScreenRotation(titleID: String?) -> ScreenRotation {
        if let raw = overrides(for: titleID)?.screenRotationRaw,
           let value = ScreenRotation(rawValue: raw) {
            return value
        }
        return screenRotation
    }

    func effectiveSwapScreens(titleID: String?) -> Bool {
        overrides(for: titleID)?.swapScreens ?? swapScreens
    }

    func effectiveIntegerScale(titleID: String?) -> Bool {
        overrides(for: titleID)?.integerScale ?? integerScale
    }

    func effectiveScreenAspect(titleID: String?) -> ScreenAspect {
        if let raw = overrides(for: titleID)?.screenAspectRaw,
           let value = ScreenAspect(rawValue: raw) {
            return value
        }
        return screenAspect
    }

    /// The stock physical-controller mapping (every button to the same 3DS
    /// button).
    static var defaultControllerButtonMap: [String: String] {
        var map: [String: String] = [:]
        for button in PhysicalControllerButton.allCases {
            map[button.rawValue] = button.defaultAction.rawValue
        }
        return map
    }

    func controllerAction(for button: PhysicalControllerButton) -> GamepadAction {
        if let raw = controllerButtonMap[button.rawValue],
           let action = GamepadAction(rawValue: raw) {
            return action
        }
        return button.defaultAction
    }

    func setControllerAction(_ action: GamepadAction, for button: PhysicalControllerButton) {
        controllerButtonMap[button.rawValue] = action.rawValue
        persist()
    }

    func resetControllerButtonMap() {
        controllerButtonMap = Self.defaultControllerButtonMap
        persist()
    }

    /// The buttons assigned to a hotkey, in their physical order.
    func hotkeyButtons(for action: HotkeyAction) -> [PhysicalControllerButton] {
        hotkeys[action.rawValue]?.compactMap(PhysicalControllerButton.init(rawValue:)) ?? []
    }

    /// Replaces one hotkey's 2–4 button combination; an empty list disables it.
    func setHotkey(_ buttons: [PhysicalControllerButton], for action: HotkeyAction) {
        let unique = Array(Set(buttons.map { $0.rawValue })).sorted()
        if unique.count >= 2 && unique.count <= 4 {
            hotkeys[action.rawValue] = unique
        } else {
            hotkeys.removeValue(forKey: action.rawValue)
        }
        persist()
    }

    func clearHotkey(for action: HotkeyAction) {
        hotkeys.removeValue(forKey: action.rawValue)
        persist()
    }

    func resetHotkeys() {
        hotkeys = [:]
        persist()
    }

    /// Effective analog dead zone for a running game (per-app override or global).
    func effectiveAnalogDeadzone(titleID: String?) -> Double {
        overrides(for: titleID)?.analogDeadzone ?? analogDeadzone
    }

    /// Effective control appearance for a running game.
    func effectiveControlAppearance(titleID: String?) -> ControlAppearance {
        if let raw = overrides(for: titleID)?.controlAppearanceRaw,
           let value = ControlAppearance(rawValue: raw) {
            return value
        }
        return controlAppearance
    }

    /// Effective physical button mapping for a running game.
    func effectiveControllerButtonMap(titleID: String?) -> [String: String] {
        overrides(for: titleID)?.controllerButtonMap ?? controllerButtonMap
    }

    /// Replaces (or clears, with nil) one game's overrides and persists.
    func setPerGameOverrides(_ overrides: PerGameOverrides?, for titleID: String) {
        let key = titleID.uppercased()
        if let overrides {
            perGameOverrides[key] = overrides
        } else {
            perGameOverrides.removeValue(forKey: key)
        }
        persist()
    }

    // MARK: - Keys

    private enum Keys {
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
        static let analogDeadzone = "UI.analogDeadzone"
        static let controlAppearance = "UI.controlAppearance"
        static let controllerButtonMap = "UI.controllerButtonMap"
        static let hotkeys = "UI.hotkeys"
        static let frameCap = "UI.frameCap"
        static let systemMetalHUD = "UI.systemMetalHUD"
        /// One-time marker: the 0.1.0 default switched the Metal HUD to on.
        static let systemMetalHUDDefaultMigrated = "UI.systemMetalHUDDefaultMigrated"
        /// One-time 0.1.6-beta3 migration that turns the HUD off everywhere.
        static let systemMetalHUDDefaultOffMigrated = "UI.systemMetalHUDDefaultOffMigrated"
        /// The removed first-load graphics warm-up wrote
        /// "UI.graphicsWarmUpEnabled"; old values are ignored on purpose.
        static let showFPS = "UI.showFPS"
        // Performance overlay (0.2.1-beta4; off by default since 0.2.2-beta3).
        // "UI.showFPS" above stays as a mirror of the master switch; these keys
        // hold the overlay's own choices. performanceOverlayMigrated is the
        // one-time move from the old FPS pill, and
        // performanceOverlayBeta3DefaultsMigrated the one-time move from the old
        // "enabled, frame rate + frame time + app memory" default combination.
        static let performanceOverlayEnabled = "UI.performanceOverlayEnabled"
        static let performanceOverlayBackground = "UI.performanceOverlayBackground"
        static let performanceOverlayPosition = "UI.performanceOverlayPosition"
        static let performanceOverlayShowFPS = "UI.performanceOverlayShowFPS"
        static let performanceOverlayShowFrameTime = "UI.performanceOverlayShowFrameTime"
        static let performanceOverlayShowSpeed = "UI.performanceOverlayShowSpeed"
        static let performanceOverlayShowProcessMemory = "UI.performanceOverlayShowProcessMemory"
        static let performanceOverlayShowAvailableMemory = "UI.performanceOverlayShowAvailableMemory"
        static let performanceOverlayMigrated = "UI.performanceOverlayMigrated"
        /// One-time 0.2.2-beta3 migration: the old default combination (enabled,
        /// frame rate + frame time + app memory on) becomes the new default
        /// (off, frame rate only).
        static let performanceOverlayBeta3DefaultsMigrated = "UI.performanceOverlayBeta3DefaultsMigrated"
        static let playbackSpeed = "UI.playbackSpeed"
        static let turboSpeed = "UI.turboSpeed"
        static let turboLimit = "UI.turboLimit"
        static let runSpeedLimit = "UI.runSpeedLimit"
        static let updateChannel = "UI.updateChannel"
        static let appearance = "UI.appearance"
        static let checkForUpdates = "UI.checkForUpdates"
        static let perGameOverrides = "UI.perGameOverrides"
        /// Debug page's experimental renderer options: read once by App.init,
        /// applied on the next app launch.
        static let gpuVertexShaders = "UI.experimental.gpuVertexShaders"
        static let preciseShading = "UI.experimental.preciseShading"
        /// Settings -> Graphics: the six experimental renderer optimisations,
        /// one JSON value under one key; read once by App.init and applied on
        /// the next app launch.
        static let advancedGraphics = "UI.graphics.advanced"
        /// Round-2 landscape / portrait screen layout choices (independent).
        static let landscapeScreenLayout = "UI.landscapeScreenLayout"
        static let portraitScreenLayout = "UI.portraitScreenLayout"
        /// The round-1 single screen layout choice; read once to migrate it to
        /// the two round-2 settings.
        static let legacyScreenLayoutMode = "UI.screenLayoutMode"
        /// 0.1.3 Default/Custom choice for the on-screen controls.
        static let controlLayoutMode = "UI.controlLayoutMode"
        /// Round-4 in-game virtual-control options; the pre-beta2 key held one
        /// global set and is only read for the one-time migration.
        static let hiddenControlItems = "UI.hiddenControlItems"
        static let hiddenControlItemsPortraitKey = "UI.hiddenControlItemsPortrait"
        static let hiddenControlItemsLandscapeKey = "UI.hiddenControlItemsLandscape"
        static let hiddenControlItemsMigrated = "UI.hiddenControlItemsMigrated"
        /// One-time 0.2.1 migration to the hidden rows that match the new
        /// ModernFS/ModernHybrid default layouts.
        static let hiddenControlItemsSkinDefaultsMigrated = "UI.hiddenControlItemsSkinDefaultsMigrated"
        /// One-time 0.2.1-beta3 migration: fastForward/swapScreens join the
        /// shipped hidden rows of the beta1/beta2 default set.
        static let hiddenControlItemsBetaTwoDefaultsMigrated = "UI.hiddenControlItemsBetaTwoDefaultsMigrated"
        static let controlSizeScales = "UI.controlSizeScales"
        static let swapScreens = "UI.swapScreens"
        static let controlLayoutPortrait = "UI.controlLayoutPortrait"
        static let controlLayoutLandscape = "UI.controlLayoutLandscape"
        static let customScreenLayout = "UI.customScreenLayout"
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

    // MARK: Layout decoding

    /// The round-2 migration of the round-1 single screen layout choice. The
    /// round-1 `UI.screenLayoutMode` held one of the six round-1 presets (or the
    /// older Default/Custom values); it becomes one landscape and one portrait
    /// choice:
    /// - original -> landscape original + portrait original;
    /// - single / side / hybrid -> that landscape choice, portrait default;
    /// - large (and the older automatic / standard modes) -> landscape large,
    ///   portrait default;
    /// - custom (and the removed freeform) -> custom in both directions.
    private static func migratedScreenLayouts(
        fromLegacy raw: String?
    ) -> (landscape: LandscapeScreenLayout, portrait: PortraitScreenLayout) {
        switch raw ?? "" {
        case "original":
            return (.original, .original)
        case "single":
            return (.single, .topFullWidth)
        case "side":
            return (.side, .topFullWidth)
        case "hybrid":
            return (.hybrid, .topFullWidth)
        case "custom", "freeform":
            return (.custom, .custom)
        default:
            return (.large, .topFullWidth)
        }
    }

    private static func decodeControlLayout(_ defaults: UserDefaults,
                                            _ key: String,
                                            orientation: ControlLayoutOrientation) -> ControlLayoutProfile {
        guard let data = defaults.data(forKey: key),
              let decoded = ControlLayoutProfile.decode(data, orientation: orientation) else {
            return .standard(for: orientation)
        }
        return decoded
    }

    private static func decodeCustomScreenLayout(_ defaults: UserDefaults,
                                                 _ key: String) -> CustomScreenLayout {
        guard let data = defaults.data(forKey: key),
              let decoded = CustomScreenLayout.decode(data) else {
            return .standard()
        }
        return decoded
    }

    private static func clampVolume(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private static func clampOpacity(_ value: Double) -> Double {
        min(max(value, 0.15), 1.0)
    }
}