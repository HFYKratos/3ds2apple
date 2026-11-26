//
//  AdvancedGraphics.swift
//  3ds2apple
//
//  The six experimental renderer optimisations Settings -> Graphics exposes
//  (0.2.2). They are the Vulkan/MoltenVK renderer's own A/B switches; each one
//  is read ONCE, while the renderer builds the device for a game load, so
//  App.init has to put the chosen ones into the process environment before the
//  first load and a change in Settings applies on the NEXT APP LAUNCH. Every
//  row in Settings says so (restartRequired).
//
//  All six ship off. They only affect the hardware (Vulkan/MoltenVK) backend:
//  when the app falls back to the software PICA200 renderer the variables are
//  never read, i.e. they are inert (the diagnostics report says so too).
//
//  The whole group is persisted as ONE Codable value under ONE UserDefaults key
//  ("UI.graphics.advanced", see AppSettings.Keys.advancedGraphics), so a reset
//  writes the shipped default atomically and an older install without the key
//  simply reads all-off.
//

import Darwin
import Foundation

/// The persisted choice of the six experimental renderer optimisations.
/// All off by default, also when the stored value is missing or unreadable.
struct AdvancedGraphicsOptions: Codable, Equatable {
    /// `ZAKURO_SAFE_SKIPS`: skip equivalent draws that cannot change a buffer.
    var safeSkips: Bool
    /// `ZAKURO_DEDUPE_CAPTURE`: skip repeated screen captures nothing drew into.
    var dedupeCapture: Bool
    /// `ZAKURO_MERGE_PASSES`: merge depth-less draws into a depth-buffered pass.
    var mergePasses: Bool
    /// `ZAKURO_FAST_CLEARS`: clear full-screen images with the image commands.
    var fastClears: Bool
    /// `ZAKURO_SORT_OPAQUE`: draw opaque draws front to back within a batch.
    var sortOpaque: Bool
    /// `ZAKURO_FAST_BARRIERS`: narrow a target-switch barrier to the attachment stage.
    var fastBarriers: Bool

    init(safeSkips: Bool = false,
         dedupeCapture: Bool = false,
         mergePasses: Bool = false,
         fastClears: Bool = false,
         sortOpaque: Bool = false,
         fastBarriers: Bool = false) {
        self.safeSkips = safeSkips
        self.dedupeCapture = dedupeCapture
        self.mergePasses = mergePasses
        self.fastClears = fastClears
        self.sortOpaque = sortOpaque
        self.fastBarriers = fastBarriers
    }

    enum CodingKeys: String, CodingKey {
        case safeSkips
        case dedupeCapture
        case mergePasses
        case fastClears
        case sortOpaque
        case fastBarriers
    }

    /// Tolerates a partially written value: an absent switch reads as off, so a
    /// future field or a hand-edited key can never turn an optimisation on.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        safeSkips = try container.decodeIfPresent(Bool.self, forKey: .safeSkips) ?? false
        dedupeCapture = try container.decodeIfPresent(Bool.self, forKey: .dedupeCapture) ?? false
        mergePasses = try container.decodeIfPresent(Bool.self, forKey: .mergePasses) ?? false
        fastClears = try container.decodeIfPresent(Bool.self, forKey: .fastClears) ?? false
        sortOpaque = try container.decodeIfPresent(Bool.self, forKey: .sortOpaque) ?? false
        fastBarriers = try container.decodeIfPresent(Bool.self, forKey: .fastBarriers) ?? false
    }

    /// The shipped default: all six off. Also what the section's Reset stores.
    static let none = AdvancedGraphicsOptions()

    /// How many switches are on, for logs and the diagnostics report.
    var enabledCount: Int {
        AdvancedGraphics.Toggle.allCases.filter { $0.isEnabled(in: self) }.count
    }

    var anyEnabled: Bool { enabledCount > 0 }
}

/// The six switches, in the order Settings -> Graphics lists them (low risk
/// first, the narrow-barrier switch last), with the renderer variable each one
/// sets and the Localizable.strings keys its row uses.
enum AdvancedGraphics {
    enum Toggle: String, CaseIterable, Identifiable {
        case safeSkips
        case dedupeCapture
        case mergePasses
        case fastClears
        case sortOpaque
        case fastBarriers

        var id: String { rawValue }

        /// The renderer variable. Verified against
        /// `MoltenVKTuning.supportedRendererKeys`; the renderer treats any value
        /// other than "0" as on, so the app writes exactly "1".
        var environmentVariable: String {
            switch self {
            case .safeSkips: return "ZAKURO_SAFE_SKIPS"
            case .dedupeCapture: return "ZAKURO_DEDUPE_CAPTURE"
            case .mergePasses: return "ZAKURO_MERGE_PASSES"
            case .fastClears: return "ZAKURO_FAST_CLEARS"
            case .sortOpaque: return "ZAKURO_SORT_OPAQUE"
            case .fastBarriers: return "ZAKURO_FAST_BARRIERS"
            }
        }

        /// Localizable.strings key of the row title.
        var titleKey: String {
            switch self {
            case .safeSkips: return "Equivalent draw skipping"
            case .dedupeCapture: return "Duplicate capture skipping"
            case .mergePasses: return "Render pass merging"
            case .fastClears: return "Fast image clears"
            case .sortOpaque: return "Opaque draw sorting"
            case .fastBarriers: return "Narrow render barriers"
            }
        }

        /// Localizable.strings key of the row's footnote (it starts with
        /// "Experimental:" because the group is experimental, not a default).
        var descriptionKey: String {
            switch self {
            case .safeSkips:
                return "Experimental: skip equivalent draws that cannot change either buffer."
            case .dedupeCapture:
                return "Experimental: skip repeated screen captures that nothing drew into."
            case .mergePasses:
                return "Experimental: merge depth-less draws into a pass that already has a depth buffer."
            case .fastClears:
                return "Experimental: clear full-screen images with the image clear commands."
            case .sortOpaque:
                return "Experimental: draw the opaque draws front to back within a batch."
            case .fastBarriers:
                return "Experimental: narrow the barrier after a target switch to the attachment stage."
            }
        }

        /// The switch's accessibility identifier (UI tests and diagnostics).
        var accessibilityIdentifier: String { "settings-graphics-advanced-\(rawValue)" }

        func isEnabled(in options: AdvancedGraphicsOptions) -> Bool {
            switch self {
            case .safeSkips: return options.safeSkips
            case .dedupeCapture: return options.dedupeCapture
            case .mergePasses: return options.mergePasses
            case .fastClears: return options.fastClears
            case .sortOpaque: return options.sortOpaque
            case .fastBarriers: return options.fastBarriers
            }
        }

        func setEnabled(_ enabled: Bool, in options: inout AdvancedGraphicsOptions) {
            switch self {
            case .safeSkips: options.safeSkips = enabled
            case .dedupeCapture: options.dedupeCapture = enabled
            case .mergePasses: options.mergePasses = enabled
            case .fastClears: options.fastClears = enabled
            case .sortOpaque: options.sortOpaque = enabled
            case .fastBarriers: options.fastBarriers = enabled
            }
        }
    }

    /// "NAME=value" pairs for the enabled switches, in the UI's order.
    static func environmentPairs(for options: AdvancedGraphicsOptions) -> [String] {
        Toggle.allCases
            .filter { $0.isEnabled(in: options) }
            .map { "\($0.environmentVariable)=1" }
    }

    /// The pairs App.init actually wrote into this process's environment, for
    /// the device log and the diagnostics report. Empty when all six are off.
    /// Main thread only (App.init, then read by the diagnostics export).
    private(set) static var appliedEnvironment: [String] = []

    /// App.init: put every enabled switch into the process environment. Must run
    /// before the renderer builds its first Vulkan/MoltenVK device (i.e. before
    /// the first game load) and before
    /// `MoltenVKTuning.noteSettingsEnvironment`, so the pairs become part of
    /// that launch snapshot and can be reported. Returns the accepted pairs.
    @discardableResult
    static func apply(_ options: AdvancedGraphicsOptions) -> [String] {
        var pairs: [String] = []
        for toggle in Toggle.allCases where toggle.isEnabled(in: options) {
            if setenv(toggle.environmentVariable, "1", 1) == 0 {
                pairs.append("\(toggle.environmentVariable)=1")
            }
        }
        appliedEnvironment = pairs
        return pairs
    }
}
