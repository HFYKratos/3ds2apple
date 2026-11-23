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
        case .circlePad, .cStick, .fastForward, .quickSave: return nil
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
        }
    }

    /// The SF Symbol the app-only buttons draw with (nil for every console
    /// control, which uses `symbol`).
    var systemImage: String? {
        switch self {
        case .fastForward: return "forward.fill"
        case .quickSave: return "square.and.arrow.down"
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
    /// Returns the healed profile; `orientation` picks the defaults.
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

    // MARK: - Shipped defaults (ModernCenteredX2 reference skin, round 6)

    /// Round 6: the shipped default layout follows the ModernCenteredX2 Delta
    /// skin numbers (round 5) with device-feedback changes:
    /// - portrait controls are moved into the free black band below the portrait
    ///   game picture. The final screenshot revision puts the shoulder row
    ///   (ZL/L/Select/Start/R/ZR) on one line at y=0.755 just under the picture
    ///   (bottom ~0.73), the main set at y=0.87 and the C-stick at
    ///   (0.92, 0.935) with size 0.08;
    /// - the D-pad keeps four directional placements whose centres form the
    ///   cross arms (portrait 103 pt -> size 0.12440, landscape 105 pt ->
    ///   0.12681), but round 7 renders and drags them as ONE cross-shaped
    ///   control (DpadCrossShape). The four placements remain the input,
    ///   visibility and size semantics, and old profiles need no migration.
    ///
    /// Opacity is 0.85 everywhere. The skin is a read-only reference: only its
    /// numeric frames are converted (centre / mapping size, diameter / 414);
    /// ZL/ZR and the C-stick are not in the skin and follow the design note.
    private static func rawDefaultPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [(ControlElement, ControlPlacement)] {
        switch orientation {
        case .landscape:
            // mappingSize 896 x 414 pt; D-pad centre (0.34989, 0.82246),
            // diameter 0.12681 (52.5 pt), offsets dx 0.02930 / dy 0.06341.
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
                // Not in the skin: one step above L/R.
                (.buttonZL, ControlPlacement(x: 0.75502, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.91574, y: 0.48792, size: 0.065, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.54688, y: 0.90097, size: 0.08213, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.45201, y: 0.90097, size: 0.08213, opacity: 0.85)),
                // Not in the skin: above/right of the A-B-X-Y cluster.
                (.cStick, ControlPlacement(x: 0.84821, y: 0.48309, size: 0.10, opacity: 0.85)),
                // Round 0.1.6 app buttons, in the free centre area.
                (.fastForward, ControlPlacement(x: 0.50, y: 0.70, size: 0.08, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.50, y: 0.82, size: 0.08, opacity: 0.85))
            ]
        case .portrait:
            // mappingSize 414 x 896 pt. Round-6 screenshot revision: the shoulder
            // row (ZL/L/Select/Start/R/ZR) becomes one row at y=0.755 just below
            // the picture (bottom ~0.73 on a modern phone), and the main set sits
            // at y=0.87 in the empty band; the D-pad cross centre is
            // (0.44565, 0.87), diameter 0.12440 (51.5 pt), offsets
            // dx 0.06220 / dy 0.02874.
            return [
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
                // Not in the skin: one step above L/R.
                (.buttonZL, ControlPlacement(x: 0.10, y: 0.755, size: 0.065, opacity: 0.85)),
                (.buttonZR, ControlPlacement(x: 0.90, y: 0.755, size: 0.065, opacity: 0.85)),
                (.buttonStart, ControlPlacement(x: 0.60, y: 0.755, size: 0.07971, opacity: 0.85)),
                (.buttonSelect, ControlPlacement(x: 0.40, y: 0.755, size: 0.07971, opacity: 0.85)),
                // Moved to the free bottom-right corner (round-6 screenshot
                // revision: further clear of A/B and smaller).
                (.cStick, ControlPlacement(x: 0.92, y: 0.935, size: 0.08, opacity: 0.85)),
                // Round 0.1.6 app buttons: the free band between the shoulder row
                // and the main set (the D-pad cross starts around y=0.84).
                (.fastForward, ControlPlacement(x: 0.50, y: 0.80, size: 0.07, opacity: 0.85)),
                (.quickSave, ControlPlacement(x: 0.62, y: 0.80, size: 0.07, opacity: 0.85))
            ]
        }
    }

    // MARK: - Legacy shipped defaults (migration sources)

    /// The beta3 (round-5) shipped defaults, kept only to recognise an untouched
    /// stored profile during the round-6 migration.
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

    /// The hand-tuned defaults shipped before round 5 (kept so a beta2 or older
    /// untouched profile still migrates cleanly).
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

    /// All legacy shipped defaults, newest first.
    private static func legacyShippedPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [[String: ControlPlacement]] {
        [beta3ShippedPlacements(for: orientation),
         roundFourShippedPlacements(for: orientation)]
    }

    /// True when a stored profile is still exactly one of the legacy shipped
    /// defaults (within a small tolerance). A profile the user moved does not
    /// match and is kept.
    static func isPreviousShippedDefault(
        _ profile: ControlLayoutProfile,
        for orientation: ControlLayoutOrientation
    ) -> Bool {
        for expected in legacyShippedPlacements(for: orientation) {
            guard profile.placements.count == expected.count else { continue }
            var matches = true
            for (key, value) in expected {
                guard let stored = profile.placements[key] else { matches = false; break }
                if abs(stored.x - value.x) > 0.005
                    || abs(stored.y - value.y) > 0.005
                    || abs(stored.size - value.size) > 0.005
                    || abs(stored.opacity - value.opacity) > 0.01 {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    /// Round-6 migration: an untouched legacy shipped profile (beta3 round-5 or
    /// earlier) becomes the new cross-shaped default; a customised profile is
    /// returned unchanged.
    static func migratingPreviousShippedDefault(
        _ profile: ControlLayoutProfile,
        for orientation: ControlLayoutOrientation
    ) -> ControlLayoutProfile {
        isPreviousShippedDefault(profile, for: orientation) ? .standard(for: orientation) : profile
    }
}