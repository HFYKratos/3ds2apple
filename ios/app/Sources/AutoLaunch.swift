//
//  AutoLaunch.swift
//  3ds2apple
//
//  Single-game IPA auto launch.
//
//  An IPA exported by the desktop launcher for one game carries that game's
//  AOT pack and one GameCatalog.json entry, and writes "autoLaunch": true at
//  the root of the catalog. Opening such an app should go straight into the
//  game instead of showing a library with one card.
//
//  The launch is deliberately conservative:
//
//  - only when the catalog asks for it AND the library has exactly one game; a
//    normal multi-game shell is untouched because its catalog has no
//    autoLaunch flag;
//  - only after the Documents scan and the ROM SHA-256 check have finished; a
//    game whose data is missing or fails validation stays on the home page and
//    the reason goes to the log and the diagnostics report;
//  - exactly once per process: leaving the game later returns to the home page
//    and the session is not started again.
//

import Foundation

enum AutoLaunch {
    /// What the last launch attempt did, for the diagnostics report
    /// (`auto_launch=`). Main thread only: the library, the session and the
    /// diagnostics export all live there.
    private(set) static var diagnosticsLine =
        "not requested (GameCatalog.json has no autoLaunch flag)"

    /// Set once an autoLaunch attempt was handled (it started the game, or it
    /// explained why it did not), so a re-appearing view or a foreground return
    /// cannot start the game again in the same process.
    private static var handled = false

    /// Launches the catalog's single game when the build asks for it. Called
    /// once from ContentView.onAppear after `library.refresh()`; a normal
    /// launcher build (no autoLaunch flag) does nothing here.
    static func startIfRequested(model: ROMSession, library: GameLibrary) {
        guard !handled else { return }
        // A QA/diagnostic `-openAOTTitleID` launch explicitly picks its own
        // game; autoLaunch must not fight it for the same session.
        guard !DebugLaunch.hasRequestedStart else {
            diagnosticsLine = "skipped (debug launch hook)"
            return
        }
        guard GameCatalog.bundled.autoLaunch else { return }
        handled = true

        guard !model.isRuntimeActive else {
            diagnosticsLine = "home (a session is already active)"
            AppLog.log("[3ds2apple] auto launch: a session is already active; staying on the home page")
            return
        }
        guard library.entries.count == 1, let entry = library.entries.first else {
            let reason = "the catalog requests autoLaunch but the library has \(library.entries.count) game(s)"
            diagnosticsLine = "home (\(reason))"
            AppLog.log("[3ds2apple] auto launch: %@; staying on the home page", reason)
            return
        }

        switch entry.validation {
        case .valid:
            start(entry, model: model)
        case .checking:
            // The launcher recorded a SHA-256 and the background check is still
            // running: wait for its result before deciding (the user's game data
            // can be more than a gigabyte).
            AppLog.log(
                "[3ds2apple] auto launch: waiting for the game-data check of %@ (%@) before starting",
                entry.title,
                entry.titleID
            )
            library.ensureVerified(titleID: entry.titleID) { state in
                switch state {
                case .valid:
                    let current = GameLibrary.shared.entry(titleID: entry.titleID) ?? entry
                    start(current, model: model)
                case .invalid(let issues):
                    stayOnHomePage(entry: entry, issues: issues, model: model)
                case .checking:
                    diagnosticsLine = "home (the game-data check did not finish)"
                    AppLog.log(
                        "[3ds2apple] auto launch: the game-data check of %@ did not finish; staying on the home page",
                        entry.titleID
                    )
                }
            }
        case .invalid(let issues):
            stayOnHomePage(entry: entry, issues: issues, model: model)
        }
    }

    /// Starts the validated game through the normal card-tap path (the same AOT
    /// gate, validation and diagnostics), one run-loop hop later so the home
    /// page finishes its first layout.
    private static func start(_ entry: GameEntry, model: ROMSession) {
        let availability = AOTPackageLoader.shared.availability(for: entry)
        if availability.isAvailable {
            diagnosticsLine = "started \(entry.titleID)"
        } else {
            diagnosticsLine = "home (no runnable AOT code for \(entry.titleID))"
        }
        AppLog.log(
            "[3ds2apple] auto launch: starting %@ (%@); AOT %@, game data from %@",
            entry.title,
            entry.titleID,
            availability.isAvailable ? "available" : "unavailable",
            entry.sourceDescription
        )
        DispatchQueue.main.async {
            model.start(entry)
        }
    }

    /// A game whose data is missing or broken stays on the home page: the
    /// normal launch gate shows the same per-game notice a card tap would, and
    /// the exact validation issues go to the log and the report.
    private static func stayOnHomePage(entry: GameEntry,
                                       issues: [GameValidationIssue],
                                       model: ROMSession) {
        let detail = issues.map { $0.localizedMessage }.joined(separator: " ")
        diagnosticsLine = "home (\(entry.titleID): \(detail))"
        AppLog.log(
            "[3ds2apple] auto launch: %@ (%@) cannot start from a cold launch; staying on the home page",
            entry.title,
            entry.titleID
        )
        for issue in issues {
            AppLog.log(
                "[3ds2apple] auto launch: %@ (%@): %@",
                entry.title,
                entry.titleID,
                issue.localizedMessage
            )
        }
        model.presentInstallationProblem(for: entry, issues: issues)
    }
}
