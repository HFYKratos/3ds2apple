//
//  AutoLaunch.swift
//  3ds2apple
//
//  Single-game IPA auto launch.
//
//  An IPA exported by the desktop launcher for one game carries that game's
//  AOT pack and one GameCatalog.json entry, and writes "autoLaunch": true at
//  the root of the catalog. Such a build has no home page: ContentView renders
//  the single-game launch/error screen instead of the library and this file
//  starts the one game.
//
//  The launch is deliberately conservative:
//
//  - only when the catalog asks for it AND the library has exactly one game; a
//    normal multi-game shell is untouched because its catalog has no
//    autoLaunch flag;
//  - only after the Documents scan and the ROM SHA-256 check have finished; a
//    game whose data is missing or fails validation stops on the single-game
//    launch screen with the normal per-game notice, and the reason also goes
//    to the log and the diagnostics report;
//  - exactly once per process: leaving the game later keeps the launch screen
//    and the session is not started again until the user presses Try again
//    (AutoLaunch.retry).
//

import Combine
import Foundation

/// Observable one-shot state of the auto launch, for the single-game root view.
///
/// Main queue only: the launch runs from ContentView.onAppear, the view reads
/// it, and the diagnostics export runs on the main queue.
final class AutoLaunchState: ObservableObject {
    static let shared = AutoLaunchState()

    /// True once a launch attempt ran (it started the game, or it explained
    /// why it could not).
    @Published private(set) var didAttempt = false
    /// True once the launch actually handed the game to the session. After the
    /// session returns to idle (the player exited through the menu's power
    /// button) the launch screen must offer Try again instead of a spinner.
    @Published private(set) var didLaunched = false
    /// Why the attempt stopped before the game started; nil on success and
    /// before the first attempt.
    @Published private(set) var lastFailure: String?

    private init() {}

    func markAttempted() {
        didAttempt = true
        lastFailure = nil
    }

    func markFailed(_ reason: String) {
        lastFailure = reason
    }

    func markLaunched() {
        didLaunched = true
    }

    func reset() {
        didAttempt = false
        didLaunched = false
        lastFailure = nil
    }
}

enum AutoLaunch {
    /// What the last launch attempt did, for the diagnostics report
    /// (`auto_launch=`). Main thread only: the library, the session and the
    /// diagnostics export all live there.
    private(set) static var diagnosticsLine =
        "not requested (GameCatalog.json has no autoLaunch flag)"

    /// Set once an autoLaunch attempt was handled (it started the game, or it
    /// explained why it did not), so a re-appearing view or a foreground return
    /// cannot start the game again in the same process. AutoLaunch.retry()
    /// clears it for the user's explicit retry on the single-game launch screen.
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
        AutoLaunchState.shared.markAttempted()

        guard !model.isRuntimeActive else {
            diagnosticsLine = "failed (a session is already active)"
            AutoLaunchState.shared.markFailed(L10n.tr("This game cannot be started"))
            AppLog.log("[3ds2apple] auto launch: a session is already active; staying on the single-game launch screen")
            return
        }
        guard library.entries.count == 1, let entry = library.entries.first else {
            let reason = "the catalog requests autoLaunch but the library has \(library.entries.count) game(s)"
            diagnosticsLine = "failed (\(reason))"
            AutoLaunchState.shared.markFailed(reason)
            AppLog.log("[3ds2apple] auto launch: %@; staying on the single-game launch screen", reason)
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
                    presentLaunchFailure(entry: entry, issues: issues, model: model)
                case .checking:
                    diagnosticsLine = "failed (the game-data check did not finish)"
                    AutoLaunchState.shared.markFailed(L10n.tr("This game cannot be started"))
                    AppLog.log(
                        "[3ds2apple] auto launch: the game-data check of %@ did not finish; staying on the single-game launch screen",
                        entry.titleID
                    )
                }
            }
        case .invalid(let issues):
            presentLaunchFailure(entry: entry, issues: issues, model: model)
        }
    }

    /// Starts the validated game through the normal card-tap path (the same AOT
    /// gate, validation and diagnostics), one run-loop hop later so the
    /// single-game launch screen finishes its first layout.
    private static func start(_ entry: GameEntry, model: ROMSession) {
        let availability = AOTPackageLoader.shared.availability(for: entry)
        switch availability {
        case .available:
            diagnosticsLine = "started \(entry.titleID)"
        case .unavailable(let reason):
            diagnosticsLine = "failed (no runnable AOT code for \(entry.titleID))"
            AutoLaunchState.shared.markFailed(reason.localizedMessage)
        }
        AppLog.log(
            "[3ds2apple] auto launch: starting %@ (%@); AOT %@, game data from %@",
            entry.title,
            entry.titleID,
            availability.isAvailable ? "available" : "unavailable",
            entry.sourceDescription
        )
        DispatchQueue.main.async {
            AutoLaunchState.shared.markLaunched()
            model.start(entry)
        }
    }

    /// A game whose data is missing or broken stops on the single-game launch
    /// screen: the normal launch gate shows the same per-game notice a card tap
    /// would (prompt semantics unchanged), and the exact validation issues go to
    /// the log and the report.
    private static func presentLaunchFailure(entry: GameEntry,
                                             issues: [GameValidationIssue],
                                             model: ROMSession) {
        let detail = issues.map { $0.localizedMessage }.joined(separator: " ")
        diagnosticsLine = "failed (\(entry.titleID): \(detail))"
        AutoLaunchState.shared.markFailed(detail.isEmpty ? L10n.tr("This game cannot be started") : detail)
        AppLog.log(
            "[3ds2apple] auto launch: %@ (%@) cannot start from a cold launch; staying on the single-game launch screen",
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

    /// The single-game launch screen's Try again: clears the one-shot guard and
    /// the last failure, rescans Documents/Games and runs the same launch
    /// attempt again. The normal validation and AOT gate still decide the
    /// outcome, so this does not weaken them. Main queue only.
    static func retry(model: ROMSession, library: GameLibrary) {
        AutoLaunchState.shared.reset()
        handled = false
        model.dismissNotice()
        library.refresh()
        startIfRequested(model: model, library: library)
    }
}
