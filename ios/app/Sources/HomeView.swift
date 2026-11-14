//
//  HomeView.swift
//  3ds2apple
//
//  Landing page: the game library and the settings entry. The library is the
//  build-time GameCatalog and nothing else: the app has no import action and
//  never copies game data. Each card shows the title, when it was last played
//  and whether this build can actually start it (AOT code available or not).
//
//  Tapping a card starts the game through ROMSession. A game this build cannot
//  start shows the "No AOT build for this game" notice instead of launching.
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
            Text("Library")
                .font(.title3.weight(.semibold))

            if library.entries.isEmpty {
                emptyLibrary
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                    ForEach(library.entries) { entry in
                        gameCard(entry)
                    }
                }
            }

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
        let aotAvailable = library.aotAvailability(for: entry).isAvailable
        return Button {
            model.start(entry)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(for: entry, aotAvailable: aotAvailable)
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
            }
            .padding(10)
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.isRuntimeActive)
        .accessibilityIdentifier("game-card")
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No games in this build")
                .font(.headline)
            Text("Games are added on your computer: build an AOT package for a game you own and reinstall this app. Built games appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    /// controller glyph and the AOT badge. No game art ships in the app.
    private func cover(for entry: GameEntry, aotAvailable: Bool) -> some View {
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
                aotBadge(available: aotAvailable)
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

    /// "AOT" when this build can start the game, "No AOT" when it cannot. The
    /// badge reports the build, so a catalog entry whose package is missing or
    /// whose title is not the linked one is shown as unavailable honestly.
    private func aotBadge(available: Bool) -> some View {
        Text(L10n.tr(available ? "AOT" : "No AOT"))
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(available ? Color.green : Color.secondary)
            .background(
                Capsule().fill(available ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
            )
            .accessibilityLabel(L10n.tr(available ? "AOT code available" : "No AOT build for this game"))
    }

    // MARK: - Status

    @ViewBuilder
    private var statusMessages: some View {
        if let notice = model.notice {
            noticeCard(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: notice.title,
                message: notice.message
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
                message: message
            )
            .accessibilityIdentifier("rom-error")
        case .finished(let message):
            noticeCard(
                icon: "stop.circle",
                tint: .secondary,
                title: L10n.tr("Runtime stopped"),
                message: message
            )
            .accessibilityIdentifier("runtime-finished")
        case .idle, .starting, .preparing, .loaded:
            EmptyView()
        }
    }

    private func noticeCard(icon: String,
                            tint: Color,
                            title: String,
                            message: String) -> some View {
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
            Button("Dismiss") {
                model.dismissNotice()
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
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
