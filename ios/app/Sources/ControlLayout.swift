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
        case .circlePad, .cStick: return nil
        }
    }

    var isAnalog: Bool {
        self == .circlePad || self == .cStick
    }

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
        }
    }

    /// The controls in the order the editor lists them.
    static var editorOrder: [ControlElement] { allCases }
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

    private static func rawDefaultPlacements(
        for orientation: ControlLayoutOrientation
    ) -> [(ControlElement, ControlPlacement)] {
        switch orientation {
        case .landscape:
            return [
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
            return [
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
    }
}
