//
//  SingleGameLaunchView.swift
//  3ds2apple
//
//  Root view of a single-game IPA (GameCatalog.json "autoLaunch": true).
//
//  Such a build carries the user's one game and its AOT pack; the launcher
//  expects the app to open straight into it. There is no home page or library
//  to fall back to, so while the game loads and whenever the launch gate stops
//  (missing/broken game data, no runnable AOT code, a runtime that stopped)
//  ContentView renders this screen instead of HomeView. Settings stay reachable
//  from the in-game menu once the game runs; before that, this screen offers a
//  retry and the diagnostics export so a failed launch can still be diagnosed.
//

import SwiftUI
import UIKit

struct SingleGameLaunchView: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: GameLibrary
    @ObservedObject var autoLaunch: AutoLaunchState

    @State private var shareItem: SingleGameDiagnosticsShare?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if let gameTitle {
                    Text(gameTitle)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .accessibilityIdentifier("single-game-launch-title")
                }
                if let failureTitle {
                    Text(failureTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("single-game-launch-error-title")
                }
                if let failureDetail {
                    Text(failureDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("single-game-launch-error-detail")
                }
                if isLaunching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(L10n.tr("Starting the game…"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("single-game-launch-progress")
                }
                VStack(spacing: 10) {
                    if !isLaunching {
                        Button {
                            AutoLaunch.retry(model: model, library: library)
                        } label: {
                            Text(L10n.tr("Try again"))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("single-game-launch-retry")
                    }
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label(L10n.tr("Export logs"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("single-game-launch-export-logs")
                }
                .frame(maxWidth: 320)
            }
            .padding(28)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .accessibilityIdentifier("single-game-launch")
    }

    // MARK: - State

    /// The player's own game name from the bundle catalog/library; nil when even
    /// the catalog entry could not be read.
    private var gameTitle: String? {
        library.entries.first?.title ?? GameCatalog.bundled.games.first?.displayName
    }

    /// A failure is shown when the launch gate stopped on a notice, the session
    /// failed/finished, or the launch attempt could not even start.
    private var failureTitle: String? {
        if let notice = model.notice { return notice.title }
        switch model.phase {
        case .failed:
            return L10n.tr("Something went wrong")
        case .finished:
            return L10n.tr("Runtime stopped")
        case .idle:
            if autoLaunch.didAttempt, autoLaunch.lastFailure != nil {
                return L10n.tr("This game cannot be started")
            }
            return nil
        case .starting, .preparing, .loaded:
            return nil
        }
    }

    private var failureDetail: String? {
        if let notice = model.notice { return notice.message }
        switch model.phase {
        case .failed(let message), .finished(let message):
            return message
        case .idle, .starting, .preparing, .loaded:
            if let failure = autoLaunch.lastFailure { return failure }
            if autoLaunch.didAttempt && !autoLaunch.didLaunched {
                return AutoLaunch.diagnosticsLine
            }
            if autoLaunch.didLaunched {
                // The game ran and the session is back to idle (the player
                // exited through the in-game menu's power button).
                return L10n.tr("The game is not running.")
            }
            return nil
        }
    }

    /// True while the launch attempt is still (about to be) running and no
    /// failure was reported yet. Once the game actually launched (didLaunched)
    /// and the session returned to idle, the launch screen offers Try again
    /// instead of a spinner.
    private var isLaunching: Bool {
        failureTitle == nil && failureDetail == nil && !autoLaunch.didLaunched
    }

    // MARK: - Actions

    /// The same report the Debug page exports: before a game (and therefore the
    /// in-game menu and Settings) can open, this is the only diagnostics entry
    /// a failed single-game launch has.
    private func exportDiagnostics() {
        guard let export = DiagnosticsExporter.write(model: model, settings: settings) else { return }
        shareItem = SingleGameDiagnosticsShare(url: export.shareURL)
    }
}

/// Share-sheet payload for the launch screen's diagnostics export.
private struct SingleGameDiagnosticsShare: Identifiable {
    let id = UUID()
    let url: URL
}
