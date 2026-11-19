//
//  HomeView.swift
//  3ds2apple
//
//  Landing page: the game library and the settings entry. A game has two
//  halves: its AOT pack is part of the signed app and listed in the bundle
//  GameCatalog.json, while its game data (the user's ROM) is pushed by the
//  desktop launcher into Documents/Games/<TITLEID>/. Each card is the game's
//  SMDH icon in a square art area — the exported icon is 48×48, so the art
//  keeps its native 1:1 aspect — followed by the title, publisher and the
//  pushed game-data size · last-played line. A ready game has no corner badge:
//  the app only runs AOT code, so an "AOT" badge said nothing, and the AOT
//  state stays in the log and the diagnostics export. A badge is kept only for
//  states that need attention: Checking (verifying the pushed ROM hash), Data
//  missing (launcher push not done yet) and Error (a broken push). Tapping a
//  card starts it or explains exactly what is wrong. There is no explanatory
//  paragraph under the grid.
//
//  Long-pressing a card opens a context menu. Its "Delete Game" action asks a
//  second time and then deletes the game: the pushed game data (ROM,
//  GameInfo.json, cover), the battery saves, the instant save states, the play
//  history and the per-game settings are removed, and the title is hidden from
//  the library until the desktop launcher pushes its data again. The AOT pack
//  itself is inside the signed app and cannot be removed at run time.
//
//  The library rescans Documents/Games at launch, whenever the app returns to
//  the foreground and on pull-to-refresh; there is no refresh button.
//
//  A fresh shell with an empty catalog shows the empty state: the AOT packs and
//  the game data both come from the 3ds2apple desktop launcher, not from
//  anything the app downloads or imports.
//
//  No developer telemetry on this screen.
//

import Foundation
import SwiftUI
import UIKit

/// Pages pushed from the home page.
private enum HomeRoute: Hashable {
    case settings
}

struct HomeView: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: GameLibrary

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The game the delete confirmation is about; nil while the alert is closed.
    @State private var pendingDeletion: GameEntry?
    @State private var isDeleteConfirmationPresented = false
    /// Result of the last deletion (a dismissible banner above the library).
    @State private var deletionStatus: String?
    @State private var deletionError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    backgroundResume
                    librarySection
                    footer
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            // Pull-to-refresh is a gesture, not a button: the library also
            // rescans by itself at launch and when the app returns to the
            // foreground (ContentView's onAppear / scenePhase hooks).
            .refreshable { library.refresh() }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { _ in
                SettingsView(settings: settings, model: model)
            }
            .alert(deleteConfirmationTitle, isPresented: $isDeleteConfirmationPresented) {
                Button(L10n.tr("Delete"), role: .destructive) {
                    if let entry = pendingDeletion { delete(entry) }
                }
                Button(L10n.tr("Cancel"), role: .cancel) { pendingDeletion = nil }
            } message: {
                Text(deleteConfirmationMessage)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("3ds2apple")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("app-title")
                Text("Nintendo 3DS, natively")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            NavigationLink(value: HomeRoute.settings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.background, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings-link")
        }
    }

    // MARK: - Background resume

    /// A session the system ended while the app was in the background. The
    /// runtime writes a recovery snapshot when the app moves to the background
    /// (0.1.4); if the process was jettisoned, this card continues that session
    /// instead of starting the game from the beginning.
    @ViewBuilder
    private var backgroundResume: some View {
        if let snapshot = model.backgroundSnapshot {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                    Text("Game paused in the background")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.blue)
                Text(L10n.format("%@ was interrupted when the app left the foreground.", snapshot.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button(L10n.tr("Resume")) {
                        model.resumeBackgroundSnapshot()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("background-resume-continue")
                    Button(L10n.tr("Discard"), role: .destructive) {
                        model.discardBackgroundSnapshot()
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("background-resume-discard")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .accessibilityIdentifier("background-resume")
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Library")
                    .font(.title3.weight(.semibold))
                Spacer()
                if !library.entries.isEmpty {
                    Text(library.entries.count == 1
                         ? L10n.tr("1 game")
                         : L10n.format("%ld games", library.entries.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("library-count")
                }
            }

            if library.entries.isEmpty {
                emptyLibrary
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                    ForEach(library.entries) { entry in
                        gameCard(entry)
                    }
                }
            }

            libraryNotice
            statusMessages
        }
    }

    /// Two columns on an iPhone, three on an iPad: every card keeps a readable
    /// width without the grid turning into a wall of tiny covers.
    private var gridColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    /// One library card: the cover and info block start the game; long-pressing
    /// the card (the game icon) opens its context menu, whose "Delete Game"
    /// action asks a second time and deletes it. There is no visible "..." menu
    /// button on the card any more.
    private func gameCard(_ entry: GameEntry) -> some View {
        let state = cardState(entry)
        return Button {
            model.start(entry)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                cover(for: entry, state: state)
                // The info block is one tight leading-aligned stack under the
                // square art: title (two lines reserved so a longer title cannot
                // push the publisher/size rows around), publisher, size and
                // last-played. Every row truncates instead of widening the card.
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    if let publisher = entry.publisher {
                        Text(publisher)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityIdentifier("game-card-publisher")
                    }
                    Text(cardMetaText(for: entry))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("game-card-meta")
                    if entry.isLegacyBundled {
                        Text(L10n.tr("From the previous build"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        // The card is disabled while a game runs (the home page is normally not
        // visible then); the context menu and its accessibility action stay
        // outside that disabled scope, exactly like the old visible menu.
        .disabled(model.isRuntimeActive)
        .accessibilityIdentifier("game-card")
        .contextMenu {
            Button(role: .destructive) {
                requestDeletion(entry)
            } label: {
                Label(L10n.tr("Delete Game"), systemImage: "trash")
            }
            .accessibilityIdentifier("game-delete-action")
        }
        // VoiceOver can reach the same deletion without a long press.
        .accessibilityAction(named: Text(L10n.tr("Delete Game"))) {
            requestDeletion(entry)
        }
    }

    /// Second confirmation title: the exact game name, so the user can see that
    /// the confirmation belongs to the card they picked.
    private var deleteConfirmationTitle: String {
        guard let entry = pendingDeletion else { return L10n.tr("Delete this game?") }
        return L10n.format("Delete “%@”?", entry.title)
    }

    /// The full delete semantics, in the dialog: data, saves and settings go,
    /// the packed AOT code stays inside the signed app.
    private var deleteConfirmationMessage: String {
        guard let entry = pendingDeletion else { return "" }
        return L10n.format(
            "The game data of “%@” is removed from this device, together with its battery saves, instant save states, play history and per-game settings. This cannot be undone. The AOT pack is part of the installed app, so the game stays hidden from the library; the desktop launcher pushing its data again makes it appear again.",
            entry.title
        )
    }

    private func requestDeletion(_ entry: GameEntry) {
        pendingDeletion = entry
        isDeleteConfirmationPresented = true
    }

    /// Runs after the second confirmation. A runtime that still owns the game is
    /// released first (the home page normally shows only while nothing is
    /// loaded), so the ROM file cannot be read while it is unlinked.
    private func delete(_ entry: GameEntry) {
        pendingDeletion = nil
        deletionStatus = nil
        deletionError = nil
        guard !model.isRuntimeActive else {
            model.unload { self.performDeletion(entry) }
            return
        }
        performDeletion(entry)
    }

    private func performDeletion(_ entry: GameEntry) {
        library.deleteGame(titleID: entry.titleID) { result in
            switch result {
            case .success(let summary):
                var message = L10n.format("“%@” was deleted from this device.", summary.title)
                if !summary.warnings.isEmpty {
                    message += " " + L10n.format(
                        "Some of the game's files could not be deleted: %@",
                        summary.warnings.joined(separator: " ")
                    )
                }
                deletionStatus = message
                // A deleted game cannot be resumed: refresh the card.
                model.refreshBackgroundSnapshot()
            case .failure(let error):
                deletionError = error.localizedDescription
            }
        }
    }

    /// What the corner badge says and its colour, or nil when the game needs no
    /// badge. A ready game shows nothing: the shell only runs AOT code, so the
    /// old green "AOT" (and grey "No AOT") label was noise on every card, and
    /// the AOT state is kept in the log and the diagnostics export instead. The
    /// badge stays for the states that need attention: Checking (the ROM
    /// SHA-256 check is running), Data missing (the launcher has not pushed the
    /// game data yet) and Error (the push is broken). The tap always explains
    /// the exact state.
    private func cardState(_ entry: GameEntry) -> (label: String, tint: Color)? {
        switch entry.validation {
        case .invalid(let issues):
            let dataMissing = issues.contains { issue in
                if case .gameDataMissing = issue { return true }
                return false
            }
            return dataMissing
                ? (L10n.tr("Data missing"), .orange)
                : (L10n.tr("Error"), .red)
        case .checking:
            return (L10n.tr("Checking"), .orange)
        case .valid:
            return nil
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No games in this build yet")
                .font(.headline)
            Text("Games are added with the 3ds2apple desktop launcher: it builds a version of this app that contains the game's AOT pack and installs it, then pushes the game's data into this app. Games appear here once the data push completes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pushed game data lives in Documents/Games/<TITLEID>/ and stays across app updates. The same folder is visible in the Files app under On My iPhone → 3ds2apple.")
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if library.hiddenGameCount > 0 {
                Text("Deleted games stay hidden until the desktop launcher pushes their game data again.")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .accessibilityIdentifier("empty-library")
    }

    // MARK: - Card contents

    /// Card art: the launcher-pushed SMDH icon (`cover.png`, 48×48 and square),
    /// else the build's bundle cover, else the deterministic gradient
    /// placeholder with a controller glyph. The art area is square for the same
    /// reason: the only artwork a game exports is its 1:1 SMDH icon, so a 16:9
    /// banner would letterbox it. The gradient is still the placeholder and the
    /// No frame around the icon: the cover art fills the square card area, and
    /// the gradient is only the placeholder when a game has no readable cover.
    /// No game art ships in the app.
    private func cover(for entry: GameEntry, state: (label: String, tint: Color)?) -> some View {
        ZStack {
            LinearGradient(
                colors: coverColors(for: entry),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            coverArt(for: entry)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let state = state {
                badge(label: state.label, tint: state.tint)
                    .padding(6)
            }
        }
        .accessibilityHidden(true)
    }

    /// The icon fills the square art area edge to edge (`scaledToFill` + clip):
    /// an SMDH cover is 1:1 so nothing is cropped, and there is no inset border
    /// around it. A missing or unreadable cover keeps the gradient placeholder,
    /// so a push without `cover.png` still renders a usable card.
    @ViewBuilder
    private func coverArt(for entry: GameEntry) -> some View {
        if let url = entry.coverURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func coverColors(for entry: GameEntry) -> [Color] {
        var hash: UInt64 = 14695981039346656037
        for byte in entry.titleID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let hue = Double(hash % 360) / 360.0
        let secondHue = (hue + 0.12).truncatingRemainder(dividingBy: 1)
        return [
            Color(hue: hue, saturation: 0.55, brightness: 0.85),
            Color(hue: secondHue, saturation: 0.75, brightness: 0.45),
        ]
    }

    /// Card meta line: the pushed game-data size (GameInfo `rom.size`, else
    /// the real file size) and the last-played date. Missing data is omitted
    /// rather than replaced with "0 KB".
    private func cardMetaText(for entry: GameEntry) -> String {
        var parts: [String] = []
        if let bytes = entry.romBytes, bytes > 0 {
            parts.append(StorageFormat.size(bytes))
        }
        parts.append(lastPlayedText(for: entry))
        return parts.joined(separator: " · ")
    }

    private func lastPlayedText(for entry: GameEntry) -> String {
        guard let lastPlayed = entry.lastPlayedAt else {
            return L10n.tr("Never played")
        }
        return L10n.format("Last played %@", StorageFormat.relativeDate(lastPlayed))
    }

    /// Corner state badge for the states that need attention (Checking / Data
    /// missing / Error); a ready game has none. The art area is the icon itself
    /// rather than a gradient banner, so the badge sits on a material capsule
    /// to stay legible on top of bright cover art; it still stays inside a
    /// fixed-size capsule.
    private func badge(label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .accessibilityLabel(label)
    }

    // MARK: - Library banner and status

    @ViewBuilder
    private var libraryNotice: some View {
        if let notice = library.notice {
            noticeCard(
                icon: "info.circle.fill",
                tint: .blue,
                title: L10n.tr("Library"),
                message: notice.message,
                dismiss: { library.dismissNotice() }
            )
            .accessibilityIdentifier("library-notice")
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let deletionStatus {
            noticeCard(
                icon: "trash",
                tint: .secondary,
                title: L10n.tr("Game deleted"),
                message: deletionStatus,
                dismiss: { self.deletionStatus = nil }
            )
            .accessibilityIdentifier("game-deleted")
        }
        if let deletionError {
            noticeCard(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: L10n.tr("Could not delete the game"),
                message: deletionError,
                dismiss: { self.deletionError = nil }
            )
            .accessibilityIdentifier("game-delete-error")
        }
        if let notice = model.notice {
            // An AOT-only refusal is an error (the game did not run): red octagon.
            // A fixable hint (data not pushed yet, ...) stays an orange warning.
            let isError = notice.severity == .error
            noticeCard(
                icon: isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                tint: isError ? .red : .orange,
                title: notice.title,
                message: notice.message,
                dismiss: { model.dismissNotice() }
            )
            .accessibilityIdentifier(isError ? "game-error" : "game-notice")
        }
        phaseStatus
    }

    @ViewBuilder
    private var phaseStatus: some View {
        switch model.phase {
        case .failed(let message):
            noticeCard(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: L10n.tr("Something went wrong"),
                message: message,
                dismiss: nil
            )
            .accessibilityIdentifier("rom-error")
        case .finished(let message):
            noticeCard(
                icon: "stop.circle",
                tint: .secondary,
                title: L10n.tr("Runtime stopped"),
                message: message,
                dismiss: nil
            )
            .accessibilityIdentifier("runtime-finished")
        case .idle, .starting, .preparing, .loaded:
            EmptyView()
        }
    }

    private func noticeCard(icon: String,
                            tint: Color,
                            title: String,
                            message: String,
                            dismiss: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let dismiss {
                Button("Dismiss") { dismiss() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityIdentifier("game-notice")
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Not affiliated with Nintendo Co., Ltd. Use only your own game dumps.")
            .font(.caption2)
            .foregroundStyle(Color.secondary.opacity(0.7))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
