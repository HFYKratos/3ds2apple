//
//  DebugLaunch.swift
//  3ds2apple
//
//  Automated launch hook for the iOS Simulator and for diagnostics.
//
//  The shipping shell starts a game from a library card, which tap-driven
//  automation (simctl) cannot do from the command line. `-openAOTTitleID
//  <TITLEID>` makes the shell launch one catalog game right after the home
//  page appears, so the whole path -- bundled GameCatalog -> GamePack dylib ->
//  packaged ROM -> zk_create -> AOT code -- can be exercised headlessly:
//
//      xcrun simctl launch <UDID> com.kratos.3ds2apple \
//          -openAOTTitleID 0004000000055E00
//
//  The argument is inert in normal launches (a person never passes it) and it
//  can only start a game the catalog already marks AOT-available: an unknown or
//  non-AOT title logs why and leaves the home page untouched. It calls the same
//  ROMSession.start() a library card calls, not a separate launch path.
//
//  See docs/build-simulator.md section 9.
//

import Foundation

enum DebugLaunch {
    /// Launch argument: `-openAOTTitleID <16 hex digit title id>`.
    static let titleIDArgument = "-openAOTTitleID"

    /// Set once a launch request was handled, so a re-appearing view cannot
    /// start the same game twice.
    private static var handled = false

    /// The title ID requested on the command line, if any. Accepts both
    /// `-openAOTTitleID <ID>` (what simctl passes) and `-openAOTTitleID=<ID>`.
    static func requestedTitleID(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        let prefix = titleIDArgument + "="
        for (index, argument) in arguments.enumerated() {
            if argument == titleIDArgument {
                guard index + 1 < arguments.count else { return nil }
                let candidate = arguments[index + 1]
                return candidate.hasPrefix("-") ? nil : candidate
            }
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Starts the requested catalog game through the normal launch path. Called
    /// on the main queue from ContentView.onAppear.
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
                "[3ds2apple] %@: %@ is not in this build's GameCatalog; ignored",
                titleIDArgument,
                titleID
            )
            return
        }
        guard library.aotAvailability(for: entry).isAvailable else {
            AppLog.log(
                "[3ds2apple] %@: %@ is not AOT-available in this build; ignored",
                titleIDArgument,
                titleID
            )
            return
        }
        AppLog.log(
            "[3ds2apple] %@: starting %@ (%@) from the command line",
            titleIDArgument,
            entry.title,
            entry.titleID
        )
        // One run-loop hop: let the home view finish its first layout so the
        // phase change and the first frames are what the screenshot shows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            model.start(entry)
        }
    }
}
