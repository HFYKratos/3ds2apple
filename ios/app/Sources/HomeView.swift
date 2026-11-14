//
//  HomeView.swift
//  3ds2apple
//
//  Landing page: the game library and the settings entry. A game has two
//  halves: its AOT pack is part of the signed app and listed in the bundle
//  GameCatalog.json, while its game data (the user's ROM) is pushed by the
//  desktop launcher into Documents/Games/<TITLEID>/. Each card shows the title,
//  when it was last played and the state: AOT (ready), Checking (verifying the
//  pushed ROM hash), Data missing (launcher push not done yet) or Error (a
//  broken push). Tapping a card starts it or explains exactly what is wrong.
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    librarySection
                    footer
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .refreshable { library.refresh() }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { _ in
                SettingsView(settings: settings, model: model)
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
            Button {
                library.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.background, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isRuntimeActive)
            .accessibilityLabel(L10n.tr("Refresh library"))
            .accessibilityIdentifier("library-refresh")
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
                if library.entries.contains(where: { $0.hasPushedData }) {
                    Text("Each game's AOT code is part of this app; its game data is pushed into this app's Documents/Games folder by the desktop launcher.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    private func gameCard(_ entry: GameEntry) -> some View {
        let state = cardState(entry)
        return Button {
            model.start(entry)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(for: entry, state: state)
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Text(lastPlayedText(for: entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.isLegacyBundled {
                    Text(L10n.tr("From the previous build"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isRuntimeActive)
        .accessibilityIdentifier("game-card")
    }

    /// What the badge says and its colour: green AOT means the game can start;
    /// orange Data missing means the launcher has not pushed the game data yet;
    /// red Error means the push is broken; Checking means the ROM SHA-256 check
    /// is running. The tap always explains the exact state.
    private func cardState(_ entry: GameEntry) -> (label: String, tint: Color) {
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
            if library.aotAvailability(for: entry).isAvailable {
                return (L10n.tr("AOT"), .green)
            }
            return (L10n.tr("No AOT"), .secondary)
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
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .accessibilityIdentifier("empty-library")
    }

    // MARK: - Card contents

    /// Cover placeholder: deterministic gradient keyed by the title id plus a
    /// controller glyph and the state badge. No game art ships in the app.
    private func cover(for entry: GameEntry, state: (label: String, tint: Color)) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: coverColors(for: entry),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            )
            .overlay(alignment: .topTrailing) {
                badge(label: state.label, tint: state.tint)
                    .padding(6)
            }
            .accessibilityHidden(true)
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

    private func lastPlayedText(for entry: GameEntry) -> String {
        guard let lastPlayed = entry.lastPlayedAt else {
            return L10n.tr("Never played")
        }
        return L10n.format("Last played %@", StorageFormat.relativeDate(lastPlayed))
    }

    private func badge(label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.16)))
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
        if let notice = model.notice {
            noticeCard(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: notice.title,
                message: notice.message,
                dismiss: { model.dismissNotice() }
            )
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
