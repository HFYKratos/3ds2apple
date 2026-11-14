//
//  DebugLaunch.swift
//  3ds2apple
//
//  Automated launch hooks for the iOS Simulator and for diagnostics.
//
//  The shipping shell starts a game from a library card, which tap-driven
//  automation (simctl) cannot do from the command line. Two launch arguments
//  make the whole path exercisable headlessly:
//
//    -openAOTTitleID <TITLEID>
//        Launch one library game right after the home page appears. It calls
//        the same ROMSession.start() a card tap calls, so the Documents scan,
//        the per-game file validation, the GamePack dlopen/registration and
//        zk_create all run exactly as they do for a person. An unknown or
//        invalid title logs why and leaves the home page untouched.
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
//        ios/app/README.md ("Simulator fixture") and docs/build-simulator.md.
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
