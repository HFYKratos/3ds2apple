//
//  ControlLayout.swift
//  3ds2apple
//
//  Editable on-screen control layout (user requirement 7).
//
//  The runtime overlay draws one button per `ControlElement` at a position and
//  size stored here. Positions are normalised to the overlay container (0...1,
//  centre of the control), so one profile looks right on every iPhone/iPad; the
//  size is a fraction of the container's shorter side for the same reason.
//
//  Two profiles are kept: portrait and landscape have different container shapes
//  (both are the whole screen; the controls float over the full-bleed picture),
//  so they need different arrangements.
//  A profile is Codable with an explicit version so a future change can migrate
//  old saved layouts instead of dropping them; `withDefaultsFilled(for:)` also
//  heals a profile that a newer build wrote with elements this build does not
//  know (an old app reading a newer profile keeps its known controls).
//  Placements are keyed by `ControlElement.rawValue`, so an element a later
//  build removes (0.2.1-beta3 removed MENU) leaves a stale key behind: the
//  runtime ignores it and the shipped-default migration compares only keys that
//  still have a ControlElement. The stale key is kept on purpose so a downgrade
//  to the older build still finds its MENU placement.
//
//  Everything here is pure data, so the editor and the runtime overlay share the
//  exact same geometry.
//

import Foundation

/// Which overlay container a control layout profile describes.
enum ControlLayoutOrientation: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: return L10n.tr("Portrait")
        case .landscape: return L10n.tr("Landscape")
        }
    }

    /// Where the profile is applied. The container itself is not a fixed
    /// aspect: both orientations use the whole physical screen, because the
    /// controls float over the full-bleed picture (round-1 layout redesign).
    /// Both editors get the real container from `GameViewPreviewGeometry`
    /// (GameViewGeometry.swift), which derives it from the live window scene
    /// with the same rules GameView uses.
}

/// One addressable control. The virtual console has the full New 3DS set: the
/// four D-pad directions, A/B/X/Y, L/R, ZL/ZR, Start/Select, and the two analog
/// sticks (the Circle Pad and the New 3DS C-stick).
enum ControlElement: String, CaseIterable, Codable, Identifiable {
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case buttonL
    case buttonR
    case buttonZL
    case buttonZR
    case buttonStart
    case buttonSelect
    case circlePad
    case cStick
    /// Round 0.1.6 app-only buttons: press-and-hold temporary fast-forward and
    /// tap quick save. They report no 3DS button bit.
    case fastForward
    case quickSave
    case quickLoad
    case swapScreens
    /// 0.2.1 app-only Settings button (user request 2026-11-25). The two Delta
    /// reference skins draw a HOME button; on the overlay that slot becomes our
    /// Settings button, which opens the in-game menu. 0.2.1-beta3 removed the
    /// separate MENU element beta2 had next to it (user feedback: one menu
    /// button is enough, and the HOME slot is the natural place for it). The
    /// button reports no 3DS button bit (the console's HOME is a system button,
    /// not a HID input). The skins' volume buttons are deliberately left out of
    /// the layout.
    case settings

    var id: String { rawValue }

    /// The ZK_BUTTON_* bit reported while this control is pressed; nil for the
    /// two analog sticks, which report a vector instead.
    var buttonBit: UInt32? {
        switch self {
        case .dpadUp: return ZKButton.up
        case .dpadDown: return ZKButton.down
        case .dpadLeft: return ZKButton.left
        case .dpadRight: return ZKButton.right
        case .buttonA: return ZKButton.a
        case .buttonB: return ZKButton.b
        case .buttonX: return ZKButton.x
        case .buttonY: return ZKButton.y
        case .buttonL: return ZKButton.l
        case .buttonR: return ZKButton.r
        case .buttonZL: return ZKButton.zl
        case .buttonZR: return ZKButton.zr
        case .buttonStart: return ZKButton.start
        case .buttonSelect: return ZKButton.select
        case .circlePad, .cStick, .fastForward, .quickSave, .quickLoad, .swapScreens,
             .settings:
            return nil
        }
    }

    var isAnalog: Bool {
        self == .circlePad || self == .cStick
    }

    /// True for the four D-pad directions. The runtime and the editors draw and
    /// drag them as one cross-shaped control since round 7; they stay separate
    /// elements for input bits, visibility and size semantics.
    var isDpadDirection: Bool {
        switch self {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight: return true
        default: return false
        }
    }

    /// Corner-radius factor of an individual button shape. Every individually
    /// drawn button keeps the round 0.42 style; the D-pad is not drawn as four
    /// buttons any more (DpadCrossShape draws it as one plus).
    var shapeCornerFactor: Double { 0.42 }

    /// A shoulder button is a wide capsule; the rest are round or small capsules.
    var isWide: Bool {
        switch self {
        case .buttonL, .buttonR, .buttonZL, .buttonZR: return true
        default: return false
        }
    }

    /// The glyph drawn on the button (letters are the console's own labels).
    var symbol: String {
        switch self {
        case .dpadUp: return "▲"
        case .dpadDown: return "▼"
        case .dpadLeft: return "◀"
        case .dpadRight: return "▶"
        case .buttonA: return "A"
        case .buttonB: return "B"
        case .buttonX: return "X"
        case .buttonY: return "Y"
        case .buttonL: return "L"
        case .buttonR: return "R"
        case .buttonZL: return "ZL"
        case .buttonZR: return "ZR"
        case .buttonStart: return "Start"
        case .buttonSelect: return "Select"
        case .circlePad: return "◉"
        case .cStick: return "◍"
        case .fastForward: return "⏩"
        case .quickSave: return "⤓"
        case .quickLoad: return "⤒"
        case .swapScreens: return "⇄"
        case .settings: return "⚙"
        }
    }

    /// The SF Symbol the app-only buttons draw with (nil for every console
    /// control, which uses `symbol`).
    var systemImage: String? {
        switch self {
        case .fastForward: return "forward.fill"
        case .quickSave: return "square.and.arrow.down"
        case .quickLoad: return "arrow.clockwise"
        case .swapScreens: return "arrow.left.arrow.right"
        case .settings: return "gearshape.fill"
        default: return nil
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .dpadUp: return L10n.tr("D-pad up")
        case .dpadDown: return L10n.tr("D-pad down")
        case .dpadLeft: return L10n.tr("D-pad left")
        case .dpadRight: return L10n.tr("D-pad right")
        case .buttonA: return L10n.tr("Button A")
        case .buttonB: return L10n.tr("Button B")
        case .buttonX: return L10n.tr("Button X")
        case .buttonY: return L10n.tr("Button Y")
        case .buttonL: return L10n.tr("Left shoulder (L)")
        case .buttonR: return L10n.tr("Right shoulder (R)")
        case .buttonZL: return L10n.tr("Left trigger (ZL)")
        case .buttonZR: return L10n.tr("Right trigger (ZR)")
        case .buttonStart: return L10n.tr("Start button")
        case .buttonSelect: return L10n.tr("Select button")
        case .circlePad: return L10n.tr("Circle Pad")
        case .cStick: return L10n.tr("C-stick")
        case .fastForward: return L10n.tr("Fast-forward")
        case .quickSave: return L10n.tr("Quick save")
        case .quickLoad: return L10n.tr("Quick load")
        case .swapScreens: return L10n.tr("Swap screens")
        case .settings: return L10n.tr("Settings")
        }
    }

    /// The controls in the order the editor lists them.
    static var editorOrder: [ControlElement] { allCases }
}

/// One row of the in-game virtual-control options (round 4). A row is usually
/// one control, but the D-pad's four directions are toggled and scaled as one
/// group so the pause menu stays short (reference-layout-app style).
enum ControlOptionItem: String, CaseIterable, Identifiable {
    case buttonA
    case buttonB
    case buttonX
    case buttonY
    case buttonL
    case buttonR
    case buttonZL
    case buttonZR
    case buttonStart
    case buttonSelect
    case dpad
    case circlePad
    case cStick
    case fastForward
    case quickSave
    case quickLoad
    case swapScreens
    /// 0.2.1 app-only Settings row (the skins' HOME slot is our single menu
    /// button). It ships visible in both directions; the visibility and size
    /// sheets list it with the other rows. (0.2.1-beta3 removed beta2's separate
    /// MENU row, so it no longer turns up in those sheets.)
    case settings

    var id: String { rawValue }

    /// The runtime controls this row covers (the D-pad row covers all four
    /// directions).
    var elements: [ControlElement] {
        switch self {
        case .buttonA: return [.buttonA]
        case .buttonB: return [.buttonB]
        case .buttonX: return [.buttonX]
        case .buttonY: return [.buttonY]
        case .buttonL: return [.buttonL]
        case .buttonR: return [.buttonR]
        case .buttonZL: return [.buttonZL]
        case .buttonZR: return [.buttonZR]
        case .buttonStart: return [.buttonStart]
        case .buttonSelect: return [.buttonSelect]
        case .dpad: return [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]
        case .circlePad: return [.circlePad]
        case .cStick: return [.cStick]
        case .fastForward: return [.fastForward]
        case .quickSave: return [.quickSave]
        case .quickLoad: return [.quickLoad]
        case .swapScreens: return [.swapScreens]
        case .settings: return [.settings]
        }
    }

    /// The option row a control belongs to.
    static func item(containing element: ControlElement) -> ControlOptionItem {
        switch element {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight: return .dpad
        case .buttonA: return .buttonA
        case .buttonB: return .buttonB
        case .buttonX: return .buttonX
        case .buttonY: return .buttonY
        case .buttonL: return .buttonL
        case .buttonR: return .buttonR
        case .buttonZL: return .buttonZL
        case .buttonZR: return .buttonZR
        case .buttonStart: return .buttonStart
        case .buttonSelect: return .buttonSelect
        case .circlePad: return .circlePad
        case .cStick: return .cStick
        case .fastForward: return .fastForward
        case .quickSave: return .quickSave
        case .quickLoad: return .quickLoad
        case .swapScreens: return .swapScreens
        case .settings: return .settings
        }
    }

    var title: String {
        switch self {
        case .buttonA: return L10n.tr("Button A")
        case .buttonB: return L10n.tr("Button B")
        case .buttonX: return L10n.tr("Button X")
        case .buttonY: return L10n.tr("Button Y")
        case .buttonL: return L10n.tr("Button L")
        case .buttonR: return L10n.tr("Button R")
        case .buttonZL: return L10n.tr("Button ZL")
        case .buttonZR: return L10n.tr("Button ZR")
        case .buttonStart: return L10n.tr("Start")
        case .buttonSelect: return L10n.tr("Select")
        case .dpad: return L10n.tr("D-pad")
        case .circlePad: return L10n.tr("Circle Pad")
        case .cStick: return L10n.tr("C-stick")
        case .fastForward: return L10n.tr("Fast-forward")
        case .quickSave: return L10n.tr("Quick save")
        case .quickLoad: return L10n.tr("Quick load")
        case .swapScreens: return L10n.tr("Swap screens")
        case .settings: return L10n.tr("Settings")
        }
    }
}

/// Where one control sits and how big it is.
struct ControlPlacement: Codable, Equatable {
    /// Centre X in the container, 0...1.
    var x: Double
    /// Centre Y in the container, 0...1.
    var y: Double
    /// Diameter as a fraction of the container's shorter side.
    var size: Double
    /// Opacity of this control on its own, 0.2...1 (the Settings opacity slider
    /// scales it further).
    var opacity: Double

    init(x: Double, y: Double, size: Double, opacity: Double = 0.9) {
        self.x = x
        self.y = y
        self.size = size
        self.opacity = opacity
    }

    /// Keeps a placement inside the container and the supported size/opacity
    /// range, so a malformed saved profile or a fast drag cannot push a control
    /// off the screen or make it invisible.
    func clamped() -> ControlPlacement {
        var result = self
        result.x = min(max(x, 0.0), 1.0)
        result.y = min(max(y, 0.0), 1.0)
        result.size = min(max(size, 0.05), 0.60)
        result.opacity = min(max(opacity, 0.20), 1.0)
        return result
    }

    // Keeping the whole control inside the container needs the container's
    // point size, because the same normalised distance is much shorter on the
    // container's short side. That clamp lives in ControlFrame.clampedCenter
    // (GameViewGeometry.swift), which both the runtime geometry and the editor
    // use. The old blanket clamp here (0.8 x size in both axes) made the edges
    // of the container unreachable - the main reason the old editor was hard to
    // use.

}

/// A complete control layout for one orientation.
struct ControlLayoutProfile: Codable, Equatable {
    /// Bumped when the stored shape changes; `withDefaultsFilled` migrates older
    /// versions by filling in controls they did not know.
    static let currentVersion = 1

    var version: Int
    /// Keyed by `ControlElement.rawValue` so the Codable form is a plain object
    /// (a dictionary with an enum key would encode as an alternating array).
    var placements: [String: ControlPlacement]

    init(version: Int = ControlLayoutProfile.currentVersion,
         placements: [String: ControlPlacement]) {
        self.version = version
        self.placements = placements
    }

    /// The placement of one control; a profile that has no entry (an old save,
    /// or a control added in a later build) falls back to the shipped default.
    func placement(for element: ControlElement) -> ControlPlacement {
        placements[element.rawValue] ?? ControlLayoutProfile.defaultPlacement(for: element)
    }

    mutating func setPlacement(_ placement: ControlPlacement, for element: ControlElement) {
        placements[element.rawValue] = placement.clamped()
    }

    /// Fills every missing control with its default and clamps what is there.
    /// Returns the healed profile; `orientation` picks the defaults. Keys with
    /// no current ControlElement (a placement for an element a later build
    /// removed, such as beta2's MENU) are preserved untouched: the runtime never
    /// reads them and keeping them lets a downgrade restore that control.
    func withDefaultsFilled(for orientation: ControlLayoutOrientation) -> ControlLayoutProfile {
        var healed = placements
        for element in ControlElement.allCases where healed[element.rawValue] == nil {
            healed[element.rawValue] = Self.defaultPlacement(for: element, orientation: orientation)
        }
        var profile = ControlLayoutProfile(version: Self.currentVersion, placements: healed)
        for element in ControlElement.allCases {
            if let placement = profile.placements[element.rawValue] {
                profile.placements[element.rawValue] = placement.clamped()
            }
        }
        return profile
    }

    /// The shipped default profile for an orientation.
    static func standard(for orientation: ControlLayoutOrientation) -> ControlLayoutProfile {
        ControlLayoutProfile(
            version: currentVersion,
            placements: defaultPlacements(for: orientation)
        )
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data, orientation: ControlLayoutOrientation) -> ControlLayoutProfile? {
        guard let decoded = try? JSONDecoder().decode(ControlLayoutProfile.self, from: data) else {
            return nil
        }
        // An unknown (newer) version still has the known controls in its
        // dictionary; only the shape of future elements would be missing, and
        // withDefaultsFilled adds those.
        return decoded.withDefaultsFilled(for: orientation)
    }

    // MARK: - Shipped defaults

    /// The default placement of one control for an orientation, used by both the
    /// default profiles and by the fallback above.
    static func defaultPlacement(for element: ControlElement,
                                 orientation: ControlLayoutOrientation = .landscape) -> ControlPlacement {
        defaultPlacements(for: orientation)[element.rawValue] ?? ControlPlacement(x: 0.5, y: 0.5, size: 0.12)
    }

    static func defaultPlacements(for orientation: ControlLayoutOrientation) -> [String: ControlPlacement] {
        var result: [String: ControlPlacement] = [:]
        for (element, placement) in rawDefaultPlacements(for: orientation) {
            result[element.rawValue] = placement
        }
        return result
    }

    // MARK: - Shipped defaults (0.2.1-beta3: Delta skins + fill-in row)

    /// The shipped default layout follows the two Delta `.deltaskin` skins the
    /// user pointed at for 0.2.1 (read-only geometry references; no skin assets,
    /// artwork or skin text are copied into the repo):
    /// - portrait: **ModernFS** (`com.stars33k.3ds.modernfs`);
    /// - landscape: **ModernHybrid** (`com.stars33k.3ds.modernhybrid`).
    /// 0.2.1-beta3 keeps every skin item where the skins draw it and only
    /// reshuffles the items the skins do not draw (see "Not in the skins"
    /// below): the beta2 MENU element is gone, the app-only fill-ins move to one
    /// row at the top centre, and portrait SAVE/LOAD move up under the notch.
    ///
    /// Both are DeltaSkin-compatible zips: `info.json` plus PDF/PNG artwork. The
    /// geometry is `representations.iphone.edgeToEdge.<orientation>`:
    /// `mappingSize` is the point space (portrait **414 x 896**, landscape
    /// **896 x 414**) and every `items[].frame` is an absolute point rect in it.
    ///
    /// Normalisation (unchanged since round 5; the tables below are the result):
    /// - centre: x = (frame.x + frame.width / 2) / mappingWidth,
    ///           y = (frame.y + frame.height / 2) / mappingHeight;
    /// - size:   frame.width / min(mappingWidth, mappingHeight) (= / 414), except
    ///           the wide L/R capsules, whose frame height is used; the A/B/X/Y
    ///           cluster rides on one size (the skins' X item is 1 pt smaller);
    /// - opacity 0.85 (the shipped value; the Settings opacity slider scales it).
    ///
    /// Skin item -> ControlElement (both orientations; the numbers in brackets are
    /// the skin frame sizes in points):
    ///   circlePad (100 x 100 portrait, 115 x 113 landscape) -> .circlePad
    ///   dpad (one item, 102 x 102 portrait / 105 x 97 landscape) -> the four
    ///       .dpadUp/.dpadDown/.dpadLeft/.dpadRight arms. The arm centres are the
    ///       item centre +/- half an arm and `dpadGroup(in:)` recovers the item
    ///       centre and the arm thickness; the cross span is 2 x arm = the item
    ///       width (round 7).
    ///   A / B / X / Y (54-55 portrait, 63 landscape) -> .buttonA/B/X/Y
    ///   L / R (wide pills, 130 x 32 / 128 x 32 portrait, 57 x 31 landscape) ->
    ///       .buttonL/.buttonR (sized by the frame height, drawn 1.65 x wide)
    ///   select / start (34 x 34 portrait, 34 x 34 landscape) ->
    ///       .buttonSelect/.buttonStart
    ///   homeMenu (34 x 34) -> **.settings**. The console HOME slot is our single
    ///       app-menu button: it opens the in-game menu (0.2.1-beta3; beta2 also
    ///       had a separate MENU element there, which user feedback removed).
    ///   quickLoad / quickSave (chips, 31 x 18 portrait, 46 x 28 landscape) ->
    ///       .quickLoad/.quickSave, in the skin's notch-side chips: portrait top
    ///       corners under the sensor housing (LOAD left, SAVE right; moved up in
    ///       0.2.1-beta3), landscape left strip (SAVE above LOAD).
    ///
    /// The skins' volume buttons are deliberately **not** part of the layout: the
    /// user does not want on-screen volume keys.
    ///
    /// App chips are wide pills in the skin while the overlay draws every app
    /// button as a rounded square (`isWide == false`), so an app chip's placement
    /// size is its skin height raised to a tappable square: 0.07 (~29 pt) for
    /// quickSave/quickLoad in both directions; the square 34 x 34 homeMenu keeps
    /// its own 0.08213.
    ///
    /// Landscape normalised table (mapping 896 x 414; ModernHybrid; both skins
    /// have identical landscape items):
    ///   circlePad (0.185826, 0.807971) 0.277778 (115 x 113 pt)
    ///   dpad      group centre (0.349888, 0.822464), item 105 x 97 pt ->
    ///             arm size 0.126812 (52.5 pt), arms dx 0.029297 / dy 0.063406:
    ///             up (0.349888, 0.759058) down (0.349888, 0.885870)
    ///             left (0.320591, 0.822464) right (0.379185, 0.822464)
    ///   A (0.896763, 0.766908) B (0.835379, 0.899758)
    ///   X (0.835379, 0.631643) Y (0.773438, 0.766908) size 0.152174 (63 pt)
    ///   L (0.755022, 0.595411) R (0.915737, 0.592995) size 0.074879 (31 pt)
    ///   Start (0.546875, 0.900966) Select (0.452009, 0.900966) 0.082126 (34 pt)
    ///   settings HOME slot (0.498884, 0.900966) 0.082126 (34 x 34 pt)
    ///   quickSave (0.029018, 0.164251) quickLoad (0.029018, 0.241546) 0.07
    ///
    /// Portrait normalised table (mapping 414 x 896; ModernFS):
    ///   circlePad (0.164251, 0.825893) 0.241546 (100 x 100 pt)
    ///   dpad      group centre (0.446860, 0.857143), item 102 x 102 pt ->
    ///             arm size 0.123188 (51 pt), arms dx 0.061594 / dy 0.028460:
    ///             up (0.446860, 0.828683) down (0.446860, 0.885603)
    ///             left (0.385266, 0.857143) right (0.508454, 0.857143)
    ///   A (0.915459, 0.825893) B (0.789855, 0.882812)
    ///   X (0.791063, 0.768415) Y (0.666667, 0.825893) size 0.130435 (54 pt)
    ///   L (0.169082, 0.716518) R (0.830918, 0.716518) size 0.077295 (32 pt)
    ///   Start (0.608696, 0.716518) Select (0.393720, 0.716518) 0.082126 (34 pt)
    ///   settings HOME slot (0.502420, 0.716518) 0.082126 (34 x 34 pt)
    ///   quickLoad (0.25, 0.045) quickSave (0.75, 0.045) 0.07
    ///
    /// Not in the skins (design fill-ins; all five ship hidden by default):
    /// - ZL/ZR, the C-stick and the app-only fastForward / swapScreens: neither
    ///   skin draws a C-stick, the two triggers or the fast-forward / swap
    ///   buttons (the user's beta2 feedback: the skins have none of these, so
    ///   they should not cover the picture or sit where a skin item lives).
    ///   Since 0.2.1-beta3 they share one starting row in the top-centre of the
    ///   game area: y 0.13, x 0.28 (ZL) / 0.39 (fastForward) / 0.50 (C-stick) /
    ///   0.61 (swapScreens) / 0.72 (ZR), sizes 0.065 / 0.07 / 0.08-0.10 /
    ///   0.07 / 0.065. The row keeps the wide ZL/ZR capsules clear of their
    ///   neighbours and stays clear of every skin item and of the portrait
    ///   SAVE/LOAD chips. It is a design fill-in, not a skin position: because
    ///   the five controls are hidden by default (see
    ///   AppSettings.defaultHiddenItems), the user finds them at the top of the
    ///   game after enabling them in Toggle controls and drags them anywhere
    ///   with the controls editor.
    ///
    /// The floating in-game HUD is drawn by GameView above this layout: portrait
    /// keeps the FPS pill + pause button in the top-right corner (clear of the
    /// SAVE chip on a 430 pt-wide screen; on narrower phones the non-interactive
    /// FPS pill can touch it) and landscape keeps the pause button bottom-centre.
    /// Since 0.2.1-beta3 the Settings button in the skin HOME slot is the only
    /// menu button, so GameView draws the floating pause button only when that
    /// control is hidden. GameView owns that HUD (out of this file's scope).
    ///
    /// Migration: the 0.2.1-beta2 default (the same skins plus the extra MENU
    /// key, beta2's SAVE/LOAD corners and FF/swap bands) is kept verbatim in
    /// `betaTwoShippedPlacements`; an untouched beta2 profile migrates once to
    /// this layout (see `migratingPreviousShippedDefault`).
    ///
    /// The D-pad stays four directional placements whose centres are the cross
    /// arms (round 7 draws and drags them as one cross-shaped control): the arm
    /// centres are the skin item centre +/- half an arm, so `dpadGroup(in:)`
    /// recovers the item centre and half its width as the arm thickness (the
    /// cross span equals the skin item width).
    private static func rawDefaultPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [(ControlElement, ControlPlacement)] {
        switch orientation {
        case .landscape:
            // ModernHybrid landscape, mapping 896 x 414; see the table above.
            return [
                (.circlePad, ControlPlacement(x: 0.18583, y: 0.80797, size: 0.27778, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.34989, y: 0.75905, size: 0.12681, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.34989, y: 0.88587, size: 0.12681, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.32059, y: 0.82246, size: 0.12681, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.37919, y: 0.82246, size: 0.12681, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.89676, y: 0.76691, size: 0.15217, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.83538, y: 0.89976, size: 0.15217, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.83538, y: 0.63164, size: 0.15217, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.77344, y: 0.76812, size: 0.15217, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.75502, y: 0.59541, size: 0.07488, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.91574, y: 0.59299, size: 0.07488, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.45201, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.54688, y: 0.90097, size: 0.08213, opacity: 0.85)),
                // The skin's HOME slot: our only app-menu button (opens the
                // in-game menu; beta2's separate MENU element was removed).
                (.settings, ControlPlacement(x: 0.49888, y: 0.90097, size: 0.08213, opacity: 0.85)),
                // The skin's SAVE / LOAD chips in the notch-side strip, SAVE
                // above LOAD.
                (.quickSave, ControlPlacement(x: 0.02902, y: 0.16425, size: 0.07, opacity: 0.85)),
                (.quickLoad, ControlPlacement(x: 0.02902, y: 0.24155, size: 0.07, opacity: 0.85)),
                // Design fill-ins for the five controls neither skin draws
                // (C-stick, ZL/ZR, fastForward, swapScreens): one row in the
                // top-centre of the game area. They ship hidden by default
                // (AppSettings.defaultHiddenItems) and are dragged wherever the
                // user wants after enabling them, so this is a findable starting
                // point, not a skin position.
                (.buttonZL, ControlPlacement(x: 0.28, y: 0.13, size: 0.065, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.50, y: 0.13, size: 0.10, opacity: 0.85)),
                (.fastForward, ControlPlacement(x: 0.39, y: 0.13, size: 0.07, opacity: 0.85)),
                (.swapScreens, ControlPlacement(x: 0.61, y: 0.13, size: 0.07, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.72, y: 0.13, size: 0.065, opacity: 0.85))
            ]
        case .portrait:
            // ModernFS portrait, mapping 414 x 896; see the table above.
            return [
                (.circlePad, ControlPlacement(x: 0.16425, y: 0.82589, size: 0.24155, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.44686, y: 0.82868, size: 0.12319, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.44686, y: 0.88560, size: 0.12319, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.38527, y: 0.85714, size: 0.12319, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.50845, y: 0.85714, size: 0.12319, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.91546, y: 0.82589, size: 0.13043, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.78986, y: 0.88281, size: 0.13043, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.79106, y: 0.76842, size: 0.13043, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.66667, y: 0.82589, size: 0.13043, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.16908, y: 0.71652, size: 0.07729, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.83092, y: 0.71652, size: 0.07729, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.39372, y: 0.71652, size: 0.08213, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.60870, y: 0.71652, size: 0.08213, opacity: 0.85)),
                // The skin's HOME slot: our only app-menu button (opens the
                // in-game menu; beta2's separate MENU element was removed).
                (.settings, ControlPlacement(x: 0.50242, y: 0.71652, size: 0.08213, opacity: 0.85)),
                // The skin's SAVE / LOAD chips in the notch-side top corners,
                // right under the sensor housing (0.2.1-beta3 moved them up from
                // beta2 and the portrait status bar is hidden): LOAD left, SAVE
                // right. x .25 / .75 keep clear of the notch centre and y .045
                // keeps the 0.07 square fully on screen.
                (.quickLoad, ControlPlacement(x: 0.25, y: 0.045, size: 0.07, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.75, y: 0.045, size: 0.07, opacity: 0.85)),
                // Design fill-ins for the five controls neither skin draws
                // (C-stick, ZL/ZR, fastForward, swapScreens): one row in the
                // top-centre of the game area. They ship hidden by default
                // (AppSettings.defaultHiddenItems) and are dragged wherever the
                // user wants after enabling them, so this is a findable starting
                // point, not a skin position.
                (.buttonZL, ControlPlacement(x: 0.28, y: 0.13, size: 0.065, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.50, y: 0.13, size: 0.08, opacity: 0.85)),
                (.fastForward, ControlPlacement(x: 0.39, y: 0.13, size: 0.07, opacity: 0.85)),
                (.swapScreens, ControlPlacement(x: 0.61, y: 0.13, size: 0.07, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.72, y: 0.13, size: 0.065, opacity: 0.85))
            ]
        }
    }

    // MARK: - Legacy shipped defaults (migration sources)

    /// The 0.2.0 shipped defaults (round 6/7: the ModernCenteredX2-derived
    /// portrait band layout, the landscape frames from the same reference and
    /// the round-0.1.6 app buttons). Kept only to recognise an untouched stored
    /// profile during the 0.2.1 migration.
    private static func zeroTwoShippedPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [String: ControlPlacement] {
        let entries: [(ControlElement, ControlPlacement)]
        switch orientation {
        case .landscape:
            entries = [
                (.circlePad, ControlPlacement(x: 0.18583, y: 0.80797, size: 0.27778, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.34989, y: 0.75905, size: 0.12681, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.34989, y: 0.88587, size: 0.12681, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.32059, y: 0.82246, size: 0.12681, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.37919, y: 0.82246, size: 0.12681, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.89676, y: 0.76691, size: 0.15217, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.83538, y: 0.89976, size: 0.15217, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.83538, y: 0.63164, size: 0.15217, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.77344, y: 0.76812, size: 0.15217, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.75502, y: 0.59541, size: 0.07488, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.91574, y: 0.59299, size: 0.07488, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.75502, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.91574, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.54688, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.45201, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.84821, y: 0.48309, size: 0.10, opacity: 0.85)),
                (.fastForward, ControlPlacement(x: 0.48, y: 0.70, size: 0.08, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.48, y: 0.82, size: 0.08, opacity: 0.85)),
                (.quickLoad, ControlPlacement(x: 0.56, y: 0.70, size: 0.08, opacity: 0.85)),
                (.swapScreens, ControlPlacement(x: 0.56, y: 0.82, size: 0.08, opacity: 0.85))
            ]
        case .portrait:
            entries = [
                (.circlePad, ControlPlacement(x: 0.16546, y: 0.87, size: 0.24396, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.44565, y: 0.84126, size: 0.12440, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.44565, y: 0.89874, size: 0.12440, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.38345, y: 0.87, size: 0.12440, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.50785, y: 0.87, size: 0.12440, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.91425, y: 0.87, size: 0.13285, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.78865, y: 0.9269, size: 0.13285, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.78865, y: 0.8131, size: 0.13285, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.66304, y: 0.87, size: 0.13285, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.24, y: 0.755, size: 0.07729, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.76, y: 0.755, size: 0.07729, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.10, y: 0.755, size: 0.065, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.90, y: 0.755, size: 0.065, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.60, y: 0.755, size: 0.07971, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.40, y: 0.755, size: 0.07971, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.92, y: 0.935, size: 0.08, opacity: 0.85)),
                (.fastForward, ControlPlacement(x: 0.50, y: 0.80, size: 0.07, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.62, y: 0.80, size: 0.07, opacity: 0.85)),
                (.quickLoad, ControlPlacement(x: 0.56, y: 0.80, size: 0.07, opacity: 0.85)),
                (.swapScreens, ControlPlacement(x: 0.56, y: 0.875, size: 0.07, opacity: 0.85))
            ]
        }
        var result: [String: ControlPlacement] = [:]
        for (element, placement) in entries {
            result[element.rawValue] = placement
        }
        return result
    }

    /// The beta3 (round-5) shipped defaults, kept only to recognise an untouched
    /// stored profile during the shipped-default migrations.
    private static func beta3ShippedPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [String: ControlPlacement] {
        let entries: [(ControlElement, ControlPlacement)]
        switch orientation {
        case .landscape:
            entries = [
                (.circlePad, ControlPlacement(x: 0.18583, y: 0.80797, size: 0.27778, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.34989, y: 0.74891, size: 0.09130, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.34989, y: 0.89601, size: 0.09130, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.31590, y: 0.82246, size: 0.09130, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.38387, y: 0.82246, size: 0.09130, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.89676, y: 0.76691, size: 0.15217, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.83538, y: 0.89976, size: 0.15217, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.83538, y: 0.63164, size: 0.15217, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.77344, y: 0.76812, size: 0.15217, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.75502, y: 0.59541, size: 0.07488, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.91574, y: 0.59299, size: 0.07488, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.75502, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.91574, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.54688, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.45201, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.84821, y: 0.48309, size: 0.10, opacity: 0.85))
            ]
        case .portrait:
            entries = [
                (.circlePad, ControlPlacement(x: 0.16546, y: 0.47266, size: 0.24396, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.44565, y: 0.47949, size: 0.08957, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.44565, y: 0.54617, size: 0.08957, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.37350, y: 0.51283, size: 0.08957, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.51780, y: 0.51283, size: 0.08957, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.91425, y: 0.48158, size: 0.13285, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.78865, y: 0.53850, size: 0.13285, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.78865, y: 0.42467, size: 0.13285, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.66304, y: 0.48158, size: 0.13285, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.16787, y: 0.37277, size: 0.07729, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.83213, y: 0.37277, size: 0.07729, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.16787, y: 0.33036, size: 0.065, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.83213, y: 0.33036, size: 0.065, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.60990, y: 0.37221, size: 0.07971, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.39251, y: 0.37221, size: 0.07971, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.93237, y: 0.42188, size: 0.13285, opacity: 0.85))
            ]
        }
        var result: [String: ControlPlacement] = [:]
        for (element, placement) in entries {
            result[element.rawValue] = placement
        }
        return result
    }

    /// The hand-tuned defaults shipped before round 5 (kept so an untouched
    /// older profile still migrates cleanly).
    private static func roundFourShippedPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [String: ControlPlacement] {
        let entries: [(ControlElement, ControlPlacement)]
        switch orientation {
        case .landscape:
            entries = [
                (.buttonL, ControlPlacement(x: 0.085, y: 0.105, size: 0.085, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.186, y: 0.105, size: 0.075, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.440, y: 0.100, size: 0.060, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.520, y: 0.100, size: 0.060, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.915, y: 0.105, size: 0.085, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.814, y: 0.105, size: 0.075, opacity: 0.85)),
                (.circlePad, ControlPlacement(x: 0.100, y: 0.340, size: 0.200, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.105, y: 0.600, size: 0.100, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.055, y: 0.680, size: 0.100, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.155, y: 0.680, size: 0.100, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.105, y: 0.760, size: 0.100, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.800, y: 0.300, size: 0.100, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.885, y: 0.620, size: 0.105, opacity: 0.90)),
                (.buttonY, ControlPlacement(x: 0.815, y: 0.700, size: 0.105, opacity: 0.90)),
                (.buttonA, ControlPlacement(x: 0.955, y: 0.700, size: 0.105, opacity: 0.90)),
                (.buttonB, ControlPlacement(x: 0.885, y: 0.780, size: 0.105, opacity: 0.90))
            ]
        case .portrait:
            entries = [
                (.buttonL, ControlPlacement(x: 0.075, y: 0.100, size: 0.120, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.176, y: 0.100, size: 0.100, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.420, y: 0.100, size: 0.090, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.530, y: 0.100, size: 0.090, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.824, y: 0.100, size: 0.100, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.925, y: 0.100, size: 0.120, opacity: 0.85)),
                (.circlePad, ControlPlacement(x: 0.140, y: 0.330, size: 0.320, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.135, y: 0.600, size: 0.160, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.082, y: 0.695, size: 0.160, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.188, y: 0.695, size: 0.160, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.135, y: 0.790, size: 0.160, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.720, y: 0.300, size: 0.130, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.875, y: 0.550, size: 0.170, opacity: 0.90)),
                (.buttonY, ControlPlacement(x: 0.795, y: 0.645, size: 0.170, opacity: 0.90)),
                (.buttonA, ControlPlacement(x: 0.940, y: 0.645, size: 0.170, opacity: 0.90)),
                (.buttonB, ControlPlacement(x: 0.875, y: 0.740, size: 0.170, opacity: 0.90))
            ]
        }
        var result: [String: ControlPlacement] = [:]
        for (element, placement) in entries {
            result[element.rawValue] = placement
        }
        return result
    }

    /// The 0.2.1-beta1 shipped defaults: the same two skins, before the
    /// 0.2.1-beta2/beta3 reshuffles (no menu/settings elements; quickSave/quickLoad
    /// sit in the app-button band instead of the skins' notch-side chips). Kept
    /// verbatim only to recognise an untouched stored profile during the
    /// shipped-default migrations.
    private static func betaOneShippedPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [String: ControlPlacement] {
        let entries: [(ControlElement, ControlPlacement)]
        switch orientation {
        case .landscape:
            entries = [
                (.circlePad, ControlPlacement(x: 0.18583, y: 0.80797, size: 0.27778, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.34989, y: 0.75905, size: 0.12681, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.34989, y: 0.88587, size: 0.12681, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.32059, y: 0.82246, size: 0.12681, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.37919, y: 0.82246, size: 0.12681, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.89676, y: 0.76691, size: 0.15217, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.83538, y: 0.89976, size: 0.15217, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.83538, y: 0.63164, size: 0.15217, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.77344, y: 0.76812, size: 0.15217, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.75502, y: 0.59541, size: 0.07488, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.91574, y: 0.59299, size: 0.07488, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.75502, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.91574, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.54688, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.45201, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.84821, y: 0.48309, size: 0.10, opacity: 0.85)),
                (.fastForward, ControlPlacement(x: 0.60, y: 0.945, size: 0.06, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.66, y: 0.945, size: 0.06, opacity: 0.85)),
                (.quickLoad, ControlPlacement(x: 0.72, y: 0.945, size: 0.06, opacity: 0.85)),
                (.swapScreens, ControlPlacement(x: 0.78, y: 0.945, size: 0.06, opacity: 0.85))
            ]
        case .portrait:
            entries = [
                (.circlePad, ControlPlacement(x: 0.16425, y: 0.82589, size: 0.24155, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.44686, y: 0.82868, size: 0.12319, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.44686, y: 0.88560, size: 0.12319, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.38527, y: 0.85714, size: 0.12319, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.50845, y: 0.85714, size: 0.12319, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.91546, y: 0.82589, size: 0.13043, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.78986, y: 0.88281, size: 0.13043, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.79106, y: 0.76841, size: 0.13043, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.66667, y: 0.82589, size: 0.13043, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.16908, y: 0.71652, size: 0.07729, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.83092, y: 0.71652, size: 0.07729, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.058, y: 0.71652, size: 0.055, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.942, y: 0.71652, size: 0.055, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.60870, y: 0.71652, size: 0.08213, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.39372, y: 0.71652, size: 0.08213, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.92, y: 0.885, size: 0.08, opacity: 0.85)),
                (.fastForward, ControlPlacement(x: 0.126, y: 0.94, size: 0.07, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.257, y: 0.94, size: 0.07, opacity: 0.85)),
                (.quickLoad, ControlPlacement(x: 0.743, y: 0.94, size: 0.07, opacity: 0.85)),
                (.swapScreens, ControlPlacement(x: 0.874, y: 0.94, size: 0.07, opacity: 0.85))
            ]
        }
        var result: [String: ControlPlacement] = [:]
        for (element, placement) in entries {
            result[element.rawValue] = placement
        }
        return result
    }

    /// The 0.2.1-beta2 shipped defaults, kept verbatim (22 placements per
    /// direction, including the MENU element) only to recognise an untouched
    /// stored profile during the 0.2.1-beta3 migration. The MENU element was
    /// removed in beta3, so its placement is stored under the raw "menu" key at
    /// the end instead of a ControlElement case; `isPreviousShippedDefault`
    /// ignores keys this build no longer knows.
    private static func betaTwoShippedPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [String: ControlPlacement] {
        let entries: [(ControlElement, ControlPlacement)]
        switch orientation {
        case .landscape:
            entries = [
                (.circlePad, ControlPlacement(x: 0.18583, y: 0.80797, size: 0.27778, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.34989, y: 0.75905, size: 0.12681, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.34989, y: 0.88587, size: 0.12681, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.32059, y: 0.82246, size: 0.12681, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.37919, y: 0.82246, size: 0.12681, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.89676, y: 0.76691, size: 0.15217, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.83538, y: 0.89976, size: 0.15217, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.83538, y: 0.63164, size: 0.15217, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.77344, y: 0.76812, size: 0.15217, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.75502, y: 0.59541, size: 0.07488, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.91574, y: 0.59299, size: 0.07488, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.75502, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.91574, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.45201, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.54688, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.settings, ControlPlacement(x: 0.49888, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.02902, y: 0.16425, size: 0.07, opacity: 0.85)),
                (.quickLoad, ControlPlacement(x: 0.02902, y: 0.24155, size: 0.07, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.84821, y: 0.48309, size: 0.10, opacity: 0.85)),
                (.fastForward, ControlPlacement(x: 0.70, y: 0.945, size: 0.07, opacity: 0.85)),
                (.swapScreens, ControlPlacement(x: 0.77, y: 0.945, size: 0.07, opacity: 0.85))
            ]
        case .portrait:
            entries = [
                (.circlePad, ControlPlacement(x: 0.16425, y: 0.82589, size: 0.24155, opacity: 0.85)),
                (.dpadUp, ControlPlacement(x: 0.44686, y: 0.82868, size: 0.12319, opacity: 0.85)),
                (.dpadDown, ControlPlacement(x: 0.44686, y: 0.88560, size: 0.12319, opacity: 0.85)),
                (.dpadLeft, ControlPlacement(x: 0.38527, y: 0.85714, size: 0.12319, opacity: 0.85)),
                (.dpadRight, ControlPlacement(x: 0.50845, y: 0.85714, size: 0.12319, opacity: 0.85)),
                (.buttonA, ControlPlacement(x: 0.91546, y: 0.82589, size: 0.13043, opacity: 0.85)),
                (.buttonB, ControlPlacement(x: 0.78986, y: 0.88281, size: 0.13043, opacity: 0.85)),
                (.buttonX, ControlPlacement(x: 0.79106, y: 0.76842, size: 0.13043, opacity: 0.85)),
                (.buttonY, ControlPlacement(x: 0.66667, y: 0.82589, size: 0.13043, opacity: 0.85)),
                (.buttonL, ControlPlacement(x: 0.16908, y: 0.71652, size: 0.07729, opacity: 0.85)),
                (.buttonR, ControlPlacement(x: 0.83092, y: 0.71652, size: 0.07729, opacity: 0.85)),
                (.buttonZL, ControlPlacement(x: 0.058, y: 0.71652, size: 0.055, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.942, y: 0.71652, size: 0.055, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.39372, y: 0.71652, size: 0.08213, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.60870, y: 0.71652, size: 0.08213, opacity: 0.85)),
                (.settings, ControlPlacement(x: 0.50242, y: 0.71652, size: 0.08213, opacity: 0.85)),
                (.quickLoad, ControlPlacement(x: 0.25725, y: 0.06138, size: 0.07, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.74275, y: 0.06138, size: 0.07, opacity: 0.85)),
                (.cStick, ControlPlacement(x: 0.92, y: 0.885, size: 0.08, opacity: 0.85)),
                (.fastForward, ControlPlacement(x: 0.79, y: 0.94, size: 0.07, opacity: 0.85)),
                (.swapScreens, ControlPlacement(x: 0.875, y: 0.94, size: 0.07, opacity: 0.85))
            ]
        }
        var result: [String: ControlPlacement] = [:]
        for (element, placement) in entries {
            result[element.rawValue] = placement
        }
        // The removed MENU element: the skins' menu chip in the landscape left
        // strip / portrait bottom-left corner.
        switch orientation {
        case .landscape:
            result["menu"] = ControlPlacement(x: 0.02902, y: 0.76570, size: 0.07, opacity: 0.85)
        case .portrait:
            result["menu"] = ControlPlacement(x: 0.12560, y: 0.93583, size: 0.07729, opacity: 0.85)
        }
        return result
    }

    /// All legacy shipped defaults, newest first: 0.2.0 (round 6/7), the
    /// 0.2.1-beta1 skin layout, the 0.2.1-beta2 skin layout with its MENU key,
    /// beta3 (round 5) and round 4.
    private static func legacyShippedPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [[String: ControlPlacement]] {
        [zeroTwoShippedPlacements(for: orientation),
         betaOneShippedPlacements(for: orientation),
         betaTwoShippedPlacements(for: orientation),
         beta3ShippedPlacements(for: orientation),
         roundFourShippedPlacements(for: orientation)]
    }

    /// True when a stored profile is still exactly one of the legacy shipped
    /// defaults (within a small tolerance). A profile the user moved does not
    /// match and is kept.
    ///
    /// Three details matter since the element set changes:
    /// - only the elements a legacy default knew are compared: an old profile
    ///   never stored the controls added later, so the dictionaries have
    ///   different sizes;
    /// - every control a legacy default did not know (healed in by
    ///   `withDefaultsFilled` from the current defaults) must still sit on the
    ///   current shipped placement, so a profile where the user only moved a
    ///   newly added control is not migrated away;
    /// - the element set can also shrink: 0.2.1-beta3 removed the MENU element,
    ///   so `betaTwoShippedPlacements` still names "menu" and a beta2 profile
    ///   still stores that key. Both loops ignore keys with no current
    ///   ControlElement (the legacy set's MENU key and the stored profile's MENU
    ///   key) instead of rejecting an otherwise untouched profile.
    static func isPreviousShippedDefault(
        _ profile: ControlLayoutProfile,
        for orientation: ControlLayoutOrientation
    ) -> Bool {
        let current = defaultPlacements(for: orientation)
        for expected in legacyShippedPlacements(for: orientation) {
            var matches = true
            for (key, value) in expected {
                // A legacy default may name an element this build removed (the
                // 0.2.1-beta2 MENU). There is nothing to compare against, so
                // ignore it instead of rejecting the whole legacy set.
                guard current[key] != nil else { continue }
                guard let stored = profile.placements[key],
                      Self.isClose(stored, to: value) else {
                    matches = false
                    break
                }
            }
            guard matches else { continue }
            for (key, stored) in profile.placements where expected[key] == nil {
                // A stored profile can still carry an element this build
                // removed; ignore it for the same reason.
                guard let shipped = current[key] else { continue }
                guard Self.isClose(stored, to: shipped) else {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    /// Tolerance used to recognise a stored shipped default: the profiles are
    /// written from the same literals, so only rounding drift can occur.
    private static func isClose(_ stored: ControlPlacement,
                                to expected: ControlPlacement) -> Bool {
        abs(stored.x - expected.x) <= 0.005
            && abs(stored.y - expected.y) <= 0.005
            && abs(stored.size - expected.size) <= 0.005
            && abs(stored.opacity - expected.opacity) <= 0.01
    }

    /// The shipped-default migration: an untouched stored profile from an older
    /// shipped default (0.2.0 round 6/7, the 0.2.1-beta1 skin layout, the
    /// 0.2.1-beta2 layout with its MENU key, beta3 round 5 or earlier round 4)
    /// becomes the current 0.2.1-beta3 default; a customised profile is returned
    /// unchanged. A beta2 profile still carries the removed MENU placement and a
    /// pre-beta2 profile has no Settings placement; `withDefaultsFilled` already
    /// healed the current elements, and `isPreviousShippedDefault` ignores the
    /// removed MENU key, so an untouched upgraded user always lands on the
    /// current default. It runs in memory on every load and is idempotent: once
    /// the stored profile is the current default it no longer matches a legacy
    /// set.
    static func migratingPreviousShippedDefault(
        _ profile: ControlLayoutProfile,
        for orientation: ControlLayoutOrientation
    ) -> ControlLayoutProfile {
        isPreviousShippedDefault(profile, for: orientation) ? .standard(for: orientation) : profile
    }
}