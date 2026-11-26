//
//  DebugLaunch.swift
//  3ds2apple
//
//  Automated launch hooks for the iOS Simulator and for diagnostics.
//
//  The shipping shell starts a game from a library card, which tap-driven
//  automation (simctl) cannot do from the command line. These launch arguments
//  make the whole path exercisable headlessly:
//
//    -openAOTTitleID <TITLEID>
//        Launch one library game right after the home page appears. It calls
//        the same ROMSession.start() a card tap calls, so the Documents scan,
//        the per-game file validation, the GamePack dlopen/registration and
//        zk_create all run exactly as they do for a person. An unknown or
//        invalid title logs why and leaves the home page untouched.
//
//    -openLayoutPage
//        Open the screen layout page (Settings -> Display -> Landscape screen layout)
//        right away, for headless screenshots of the landscape/portrait layout
//        page. Inert in normal launches.
//
//    -openLayoutEditor screen|control[-landscape]
//        Open one of the two full-screen layout editors directly, for headless
//        screenshots. 0.1.3 editors edit the direction the device is in; the
//        `-landscape` variants force that direction for screenshots.
//
//    -previewGameView
//        Show the running-game view without a ROM or game pack: two synthetic
//        screen images (gradient, 1 px grid and a clear TOP / BOTTOM label,
//        400x240 and 320x240) are drawn through the real layout geometry, with
//        the floating FPS/pause controls and the on-screen control overlay. The
//        preview path never touches a session, so it needs no game data.
//
//    -previewScreenLayout <layout>
//        Apply one screen layout choice for this launch only (in memory, never
//        persisted). With -previewLandscape it sets the landscape choice:
//        large | single | side | hybrid | original | custom. Without it, it sets
//        the portrait choice: default | original | custom. A value of the other
//        direction is logged and ignored. Combine it with -previewGameView for
//        the ROM-free screenshots.
//
//    -previewLandscape
//        Force the landscape appearance for headless screenshots (the app asks
//        its window scene to rotate and the game view uses the landscape
//        arrangement even before the rotation lands).
//
//    -openLayoutPicker landscape|portrait
//        Open that direction's screen layout radio picker straight away, for
//        headless screenshots.
//
//    -openCustomLayoutPage landscape|portrait
//        Open the numeric custom layout page for that direction, for headless
//        screenshots.
//
//    -previewPauseMenu
//        Open the in-game pause menu over the preview game view (combine with
//        -previewGameView), for headless screenshots of the control options.
//
//    -previewControlEdit
//        Enter the in-game control edit mode (combine with -previewGameView),
//        for headless screenshots of the draggable controls and Done pill.
//
//    -openControlOptions visibility|size|opacity
//        Open one virtual-control options sheet in that pause menu.
//
//    -gamesRoot <path>
//        Scan this folder instead of Documents/Games. A relative path resolves
//        against Documents (a "Documents/" prefix is accepted); an absolute path
//        must stay inside the app container. The Simulator fixture workflow
//        builds the shell with --game-pack (the AOT pack is inside the app and
//        listed in GameCatalog.json), copies only the game data (GameRom.cci +
//        GameInfo.json) into a folder under the app container and launches with
//
//            xcrun simctl launch <UDID> com.kratos.3ds2apple \
//                -gamesRoot Documents/GamesFixtures \
//                -openAOTTitleID 0004000000055E00
//
//        so a test never has to touch the real Documents/Games library. See
//        ios/app/README.md ("Simulator fixture").
//
//  The arguments are inert in normal launches (a person never passes them).
//

import Foundation

enum DebugLaunch {
    /// Launch argument: `-openAOTTitleID <16 hex digit title id>`.
    static let titleIDArgument = "-openAOTTitleID"
    /// Launch argument: `-gamesRoot <path>` (relative to Documents, or an
    /// absolute path inside the app container).
    static let gamesRootArgument = "-gamesRoot"
    /// Launch argument: `-openSettings` opens the new Settings main page, and
    /// `-openSettingsCategory <rawValue>` pushes one category (e.g. `general`),
    /// for headless screenshots of the redesigned settings.
    static let openSettingsArgument = "-openSettings"
    static let openSettingsCategoryArgument = "-openSettingsCategory"
    /// Launch argument: `-openLayoutPage` opens the screen layout page
    /// (Settings -> Display -> Landscape screen layout) straight away, for headless
    /// screenshots.
    static let layoutPageArgument = "-openLayoutPage"
    /// Launch argument: `-openLayoutEditor screen|control` opens one of the
    /// full-screen layout editors directly, for headless screenshots.
    static let layoutEditorArgument = "-openLayoutEditor"
    /// True when the launch asks for the Settings pages (screenshots only).
    static var openSettings: Bool {
        ProcessInfo.processInfo.arguments.contains(openSettingsArgument)
    }

    /// The optional Settings category raw value from `-openSettingsCategory`.
    static var openSettingsCategory: SettingsCategory? {
        guard let raw = argumentValue(for: openSettingsCategoryArgument) else { return nil }
        return SettingsCategory(rawValue: raw)
    }

    /// Launch argument: `-previewGameView` shows the running-game view without a
    /// ROM, for headless screenshots of the full-bleed layout.
    static let previewGameViewArgument = "-previewGameView"
    /// Launch argument: `-previewScreenLayout <preset>` applies one screen
    /// layout preset for this launch only (in memory, not persisted).
    static let previewScreenLayoutArgument = "-previewScreenLayout"
    /// Launch argument: `-previewLandscape` forces the landscape appearance.
    static let previewLandscapeArgument = "-previewLandscape"
    /// Launch argument: `-openLayoutPicker landscape|portrait` opens that
    /// direction's screen layout radio picker, for headless screenshots.
    static let layoutPickerArgument = "-openLayoutPicker"
    /// Launch argument: `-openCustomLayoutPage landscape|portrait` opens the
    /// numeric custom layout page for that direction, for headless screenshots.
    static let customLayoutPageArgument = "-openCustomLayoutPage"
    /// Launch argument: `-previewPauseMenu` opens the in-game pause menu (with
    /// -previewGameView) for headless screenshots of the round-4 control options.
    static let previewPauseMenuArgument = "-previewPauseMenu"
    /// Launch argument: `-previewControlEdit` enters the in-game control edit
    /// mode (with -previewGameView), for headless screenshots of the Done overlay.
    static let previewControlEditArgument = "-previewControlEdit"
    /// Launch argument: `-openControlOptions visibility|size|opacity` opens one
    /// virtual-control options sheet in the pause menu, for screenshots.
    static let controlOptionsArgument = "-openControlOptions"

    /// A layout page a headless launch asked to open.
    enum LayoutPage: String {
        case screenLayout
        case controlEditorPortrait = "control"
        case controlEditorLandscape = "control-landscape"
        case screenEditorPortrait = "screen"
        case screenEditorLandscape = "screen-landscape"
    }

    /// Which layout page to open right away, for headless screenshots; nil in
    /// normal launches. `-openLayoutPage` opens the screen layout page,
    /// `-openLayoutEditor control` or `-openLayoutEditor screen` opens an
    /// editor directly.
    static var requestedLayoutPage: LayoutPage? {
        if let raw = argumentValue(for: layoutEditorArgument) {
            switch raw.lowercased() {
            case "control", "controls", "buttons": return .controlEditorPortrait
            case "control-landscape", "landscape-controls": return .controlEditorLandscape
            case "screen", "screens": return .screenEditorPortrait
            case "screen-landscape", "landscape-screens": return .screenEditorLandscape
            default: break
            }
        }
        return opensLayoutPage ? .screenLayout : nil
    }

    /// Whether the launch asked for the Layout page (screenshot automation).
    static var opensLayoutPage: Bool {
        ProcessInfo.processInfo.arguments.contains(layoutPageArgument)
    }

    /// Whether the launch asks for the ROM-free running-game preview.
    static var previewGameView: Bool {
        ProcessInfo.processInfo.arguments.contains(previewGameViewArgument)
    }

    /// Whether the launch asks for the landscape appearance.
    static var previewLandscape: Bool {
        ProcessInfo.processInfo.arguments.contains(previewLandscapeArgument)
    }

    /// The direction whose preset picker a headless launch asked to open.
    static var requestedLayoutPicker: ControlLayoutOrientation? {
        orientationArgument(for: layoutPickerArgument)
    }

    /// The direction whose numeric custom layout page a headless launch asked to
    /// open.
    static var requestedCustomLayoutPage: ControlLayoutOrientation? {
        orientationArgument(for: customLayoutPageArgument)
    }

    /// Whether the launch asked for the in-game pause menu (screenshots).
    static var previewPauseMenu: Bool {
        ProcessInfo.processInfo.arguments.contains(previewPauseMenuArgument)
    }

    /// Whether the launch asked for the in-game control edit mode (screenshots).
    static var previewControlEdit: Bool {
        ProcessInfo.processInfo.arguments.contains(previewControlEditArgument)
    }

    /// The virtual-control options sheet a headless launch asked to open.
    static var requestedControlOptions: ControlOptionsPage? {
        guard let raw = argumentValue(for: controlOptionsArgument) else { return nil }
        switch raw.lowercased() {
        case "visibility", "toggle", "toggle-controls":
            return .visibility
        case "size", "adjust-size":
            return .size
        case "opacity", "adjust-opacity":
            return .opacity
        default:
            AppLog.log("[3ds2apple] %@: '%@' is not visibility, size or opacity; ignored",
                       controlOptionsArgument, raw)
            return nil
        }
    }

    /// Applies the preview-only display values for this launch. The values are
    /// written to the shared settings object but never persisted, so the next
    /// normal launch keeps whatever the user chose. Called once from
    /// ContentView.onAppear; a normal launch does nothing.
    static func applyPreviewSettings(to settings: AppSettings) {
        let rawLayout = argumentValue(for: previewScreenLayoutArgument)
        guard previewGameView || previewLandscape || rawLayout != nil else { return }
        if let rawLayout {
            if previewLandscape {
                if let layout = LandscapeScreenLayout(rawValue: rawLayout.lowercased()) {
                    settings.landscapeScreenLayout = layout
                } else {
                    AppLog.log(
                        "[3ds2apple] %@: '%@' is not a landscape layout (%@); ignored",
                        previewScreenLayoutArgument,
                        rawLayout,
                        LandscapeScreenLayout.allCases.map(\.rawValue).joined(separator: ", ")
                    )
                }
            } else if let layout = portraitLayoutArgument(rawLayout) {
                settings.portraitScreenLayout = layout
            } else {
                AppLog.log(
                    "[3ds2apple] %@: '%@' is not a portrait layout (%@); ignored",
                    previewScreenLayoutArgument,
                    rawLayout,
                    PortraitScreenLayout.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
        }
        if previewLandscape {
            settings.orientation = .landscape
            AppOrientation.apply(.landscape)
        }
        AppLog.log(
            "[3ds2apple] preview launch: game_view=%@ landscape=%@ landscape_layout=%@ portrait_layout=%@",
            previewGameView ? "on" : "off",
            previewLandscape ? "on" : "off",
            settings.landscapeScreenLayout.rawValue,
            settings.portraitScreenLayout.rawValue
        )
    }

    /// Maps a portrait layout argument; accepts the user-facing "default" for
    /// the stored topFullWidth value.
    private static func portraitLayoutArgument(_ raw: String) -> PortraitScreenLayout? {
        switch raw.lowercased() {
        case "default", "topfullwidth", "top-full-width", "full-width":
            return .topFullWidth
        default:
            return PortraitScreenLayout(rawValue: raw.lowercased())
        }
    }

    /// Maps a landscape|portrait launch argument to a device direction.
    private static func orientationArgument(for flag: String) -> ControlLayoutOrientation? {
        guard let raw = argumentValue(for: flag) else { return nil }
        switch raw.lowercased() {
        case "landscape", "land", "horizontal":
            return .landscape
        case "portrait", "port", "vertical":
            return .portrait
        default:
            AppLog.log("[3ds2apple] %@: '%@' is not landscape or portrait; ignored", flag, raw)
            return nil
        }
    }

    /// Set once a launch request was handled, so a re-appearing view cannot
    /// start the same game twice.
    private static var handled = false

    /// The title ID requested on the command line, if any. Accepts both
    /// `-openAOTTitleID <ID>` (what simctl passes) and `-openAOTTitleID=<ID>`.
    static func requestedTitleID(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        argumentValue(for: titleIDArgument, in: arguments)
    }

    /// Whether this launch passes `-openAOTTitleID` (QA/diagnostic fixtures).
    /// The single-game auto launch leaves an explicit hook alone.
    static var hasRequestedStart: Bool { requestedTitleID() != nil }

    /// Folder to scan instead of Documents/Games; nil in normal launches.
    ///
    /// A relative path resolves against Documents, and the "Documents/" prefix
    /// is accepted for convenience (a container path minus the long UUID). So
    /// both `-gamesRoot GamesFixtures` and
    /// `-gamesRoot Documents/GamesFixtures` scan <container>/Documents/GamesFixtures.
    static var gamesRootOverride: URL? {
        guard let raw = argumentValue(for: gamesRootArgument) else { return nil }
        let documents = StorageInspector.documentsURL
        let url: URL
        if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw, isDirectory: true)
        } else if raw == "Documents" {
            url = documents
        } else if raw.hasPrefix("Documents/") {
            let relative = String(raw.dropFirst("Documents/".count))
            url = documents.appendingPathComponent(relative, isDirectory: true)
        } else {
            url = documents.appendingPathComponent(raw, isDirectory: true)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory())
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolved.path.hasPrefix(home.path + "/") else {
            AppLog.log(
                "[3ds2apple] %@: '%@' is outside the app container; ignored",
                gamesRootArgument,
                raw
            )
            return nil
        }
        AppLog.log(
            "[3ds2apple] %@: scanning %@ instead of Documents/Games",
            gamesRootArgument,
            resolved.path
        )
        return resolved
    }

    /// Starts the requested library game through the normal launch path.
    /// Called on the main queue from ContentView.onAppear.
    static func startIfRequested(model: ROMSession, library: GameLibrary) {
        guard !handled else { return }
        guard let raw = requestedTitleID() else { return }
        handled = true
        guard let titleID = GameCatalog.normalizedTitleID(raw) else {
            AppLog.log(
                "[3ds2apple] %@: '%@' is not a 16 hex digit title ID; ignored",
                titleIDArgument,
                raw
            )
            return
        }
        guard let entry = library.entry(titleID: titleID) else {
            AppLog.log(
                "[3ds2apple] %@: %@ is not in the library (%ld entries); ignored",
                titleIDArgument,
                titleID,
                library.entries.count
            )
            return
        }
        let availability = library.aotAvailability(for: entry)
        AppLog.log(
            "[3ds2apple] %@: starting %@ (%@); files from %@, AOT %@",
            titleIDArgument,
            entry.title,
            entry.titleID,
            entry.sourceDescription,
            availability.isAvailable ? "available" : "unavailable"
        )
        // One run-loop hop: let the home view finish its first layout so the
        // phase change and the first frames are what the screenshot shows.
        // start() runs the same validation/AOT gate as a card tap, so a broken
        // fixture shows its per-game error instead of being silently ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            model.start(entry)
        }
    }

    // MARK: - Argument parsing

    /// Value of `-flag value` or `-flag=value`, nil when absent or empty.
    private static func argumentValue(
        for flag: String,
        in arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        let prefix = flag + "="
        for (index, argument) in arguments.enumerated() {
            if argument == flag {
                guard index + 1 < arguments.count else { return nil }
                let candidate = arguments[index + 1]
                guard !candidate.hasPrefix("-"), !candidate.isEmpty else { return nil }
                return candidate
            }
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}