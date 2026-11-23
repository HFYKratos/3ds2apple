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

    // MARK: In-game virtual control options (round 4)

    /// Rows the user hid from the pause menu's "Toggle controls" sheet. Global,
    /// not per orientation; an empty set means every control is visible.
    @Published var hiddenControlItems: Set<ControlOptionItem>
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
    /// Show the presented frames per second in the game view. ON by default.
    /// The FPS counter is the only in-game HUD; the diagnostic details (AOT
    /// state, renderer path, CPU/present/read timings) stay in the log and the
    /// diagnostics export.
    @Published var showFPS: Bool
    /// Fast-forward target: 1×, 2× or 4× (see `PlaybackSpeed`).
    @Published var playbackSpeed: PlaybackSpeed

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
        // Round 6: a stored profile that is still an untouched beta3 (round-5)
        // or older shipped default moves to the new cross-shaped default; a
        // profile the user moved is kept unchanged.
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
        // In-game virtual-control options (round 4): hidden rows and per-row
        // size scales. Both are global (not per orientation); an unreadable
        // value falls back to "all visible / 100%".
        let storedHidden = defaults.stringArray(forKey: Keys.hiddenControlItems) ?? []
        hiddenControlItems = Set(storedHidden.compactMap(ControlOptionItem.init(rawValue:)))
        if let data = defaults.data(forKey: Keys.controlSizeScales),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            controlSizeScales = decoded
        } else {
            controlSizeScales = [:]
        }

        // The performance page no longer offers a frame cap: the console
        // timeline runs at its native 60 Hz and Fast-forward is the only
        // speed control, so an old stored 30 fps value is ignored on purpose.
        frameCap = .sixty

        // System Metal HUD: ON for every new install and for an install that
        // predates the migration marker. Before 0.1.0 the fallback was off, and
        // any Settings change wrote that false to disk, so an old install cannot
        // be told apart from a user who deliberately chose off. The migration
        // below enables it exactly once per install; after the marker exists the
        // stored choice (including an explicit off) wins.
        if defaults.object(forKey: Keys.systemMetalHUDDefaultMigrated) == nil {
            systemMetalHUD = true
            defaults.set(true, forKey: Keys.systemMetalHUD)
            defaults.set(true, forKey: Keys.systemMetalHUDDefaultMigrated)
            AppLog.log("[3ds2apple] system Metal HUD: enabled by the 0.1.0 default migration")
        } else if defaults.object(forKey: Keys.systemMetalHUD) != nil {
            systemMetalHUD = defaults.bool(forKey: Keys.systemMetalHUD)
        } else {
            systemMetalHUD = true
        }
        showFPS = Self.bool(defaults, Keys.showFPS, fallback: true)
        playbackSpeed = PlaybackSpeed(
            rawValue: defaults.integer(forKey: Keys.playbackSpeed)
        ) ?? .normal
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
        defaults.set(frameCap.rawValue, forKey: Keys.frameCap)
        defaults.set(systemMetalHUD, forKey: Keys.systemMetalHUD)
        // Keep MTL_HUD_ENABLED in step with the switch: it is read when a
        // Metal device is created, so a change without a relaunch still applies
        // to the next device (the layer property switches the live layer).
        MetalHUD.apply(enabled: systemMetalHUD)
        defaults.set(showFPS, forKey: Keys.showFPS)
        defaults.set(playbackSpeed.rawValue, forKey: Keys.playbackSpeed)
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
        // Round-4 in-game virtual-control options.
        defaults.set(hiddenControlItems.map(\.rawValue).sorted(),
                     forKey: Keys.hiddenControlItems)
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
        let custom = isLandscape
            ? landscapeScreenLayout == .custom
            : portraitScreenLayout == .custom
        return custom && screenRotation != .upright
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

    /// Whether one control element is drawn and hit-testable right now.
    func isControlVisible(_ element: ControlElement) -> Bool {
        !hiddenControlItems.contains(ControlOptionItem.item(containing: element))
    }

    /// Whether one option row (control or D-pad group) is visible.
    func isControlItemVisible(_ item: ControlOptionItem) -> Bool {
        !hiddenControlItems.contains(item)
    }

    func setControlItem(_ item: ControlOptionItem, visible: Bool) {
        if visible {
            hiddenControlItems.remove(item)
        } else {
            hiddenControlItems.insert(item)
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
    /// 100% and all controls visible (the pause menu's Reset action).
    func resetVirtualControls() {
        controlLayoutMode = .standard
        controlLayoutPortrait = .standard(for: .portrait)
        controlLayoutLandscape = .standard(for: .landscape)
        hiddenControlItems = []
        controlSizeScales = [:]
        persist()
    }

    /// Fast-forward target as a plain number for the session and diagnostics.
    var playbackSpeedValue: Int { playbackSpeed.rawValue }

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
        static let frameCap = "UI.frameCap"
        static let systemMetalHUD = "UI.systemMetalHUD"
        /// One-time marker: the 0.1.0 default switched the Metal HUD to on.
        static let systemMetalHUDDefaultMigrated = "UI.systemMetalHUDDefaultMigrated"
        /// The removed first-load graphics warm-up wrote
        /// "UI.graphicsWarmUpEnabled"; old values are ignored on purpose.
        static let showFPS = "UI.showFPS"
        static let playbackSpeed = "UI.playbackSpeed"
        /// Round-2 landscape / portrait screen layout choices (independent).
        static let landscapeScreenLayout = "UI.landscapeScreenLayout"
        static let portraitScreenLayout = "UI.portraitScreenLayout"
        /// The round-1 single screen layout choice; read once to migrate it to
        /// the two round-2 settings.
        static let legacyScreenLayoutMode = "UI.screenLayoutMode"
        /// 0.1.3 Default/Custom choice for the on-screen controls.
        static let controlLayoutMode = "UI.controlLayoutMode"
        /// Round-4 in-game virtual-control options (global).
        static let hiddenControlItems = "UI.hiddenControlItems"
        static let controlSizeScales = "UI.controlSizeScales"
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