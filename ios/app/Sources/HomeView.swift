//
//  HomeView.swift
//  3ds2apple
//
//  Landing page: the game library and one import action, plus the settings
//  entry. The library is a grid of cards, one per imported ROM: a
//  cover placeholder tinted from the title id, the title, when it was last
//  played and whether this build links AOT code for it.
//
//  Importing only copies a ROM into the app and adds it to the library; tapping
//  a card starts that game. A game without linked AOT code is started after one
//  confirmation, because it runs in the interpreter.
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

    @State private var sheet: HomeSheet?
    @State private var alert: HomeAlert?

    /// One sheet slot for the pages the home page can present.
    private enum HomeSheet: Identifiable {
        case filesPicker

        var id: String { "files-picker" }
    }

    /// One confirmation/error alert; a single alert slot keeps the destructive
    /// delete and the interpreter warning from overwriting each other.
    private enum HomeAlert: Identifiable {
        case interpreter(GameEntry)
        case delete(GameEntry)
        case error(String)

        var id: String {
            switch self {
            case .interpreter(let entry): return "interpreter-\(entry.id.uuidString)"
            case .delete(let entry): return "delete-\(entry.id.uuidString)"
            case .error(let message): return "error-\(message.hashValue)"
            }
        }
    }

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
        .sheet(item: $sheet) { _ in
            ROMDocumentPicker { urls in
                self.sheet = nil
                model.importROMs(from: urls)
            }
        }
        .alert(item: $alert) { alert in
            alertView(for: alert)
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
            HStack(alignment: .firstTextBaseline) {
                Text("Library")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    sheet = .filesPicker
                } label: {
                    Label("Import", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityIdentifier("import-rom")
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

            phaseStatus
        }
    }

    /// Two columns on an iPhone, three on an iPad: every card keeps a readable
    /// width without the grid turning into a wall of tiny covers.
    private var gridColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    private func gameCard(_ entry: GameEntry) -> some View {
        let linked = GameCatalog.bundled.isAOTPlayable(titleID: entry.titleID)
        return Button {
            requestStart(entry)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(for: entry, linked: linked)
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
        .disabled(isBusy)
        .accessibilityIdentifier("game-card")
        .contextMenu {
            Button(role: .destructive) {
                alert = .delete(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No games yet")
                .font(.headline)
            Text("Import one or more decrypted ROMs (.3ds, .cci or .cia) from the Files app. They are copied into this app and stay on the device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                sheet = .filesPicker
            } label: {
                Label("Import game", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
            .accessibilityIdentifier("import-rom")
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    // MARK: - Card contents

    /// Cover placeholder: deterministic gradient keyed by the title id (or the
    /// file name while the header is unknown) plus a controller glyph.
    private func cover(for entry: GameEntry, linked: Bool) -> some View {
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
                aotBadge(linked: linked)
                    .padding(6)
            }
            .accessibilityHidden(true)
    }

    private func coverColors(for entry: GameEntry) -> [Color] {
        let seed = entry.titleID ?? entry.fileName
        var hash: UInt64 = 14695981039346656037
        for byte in seed.utf8 {
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

    private func aotBadge(linked: Bool) -> some View {
        Text(L10n.tr(linked ? "AOT" : "Interpreter"))
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(linked ? Color.green : Color.secondary)
            .background(
                Capsule().fill(linked ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
            )
            .accessibilityLabel(L10n.tr(linked ? "AOT code linked" : "Interpreter only"))
    }

    // MARK: - Status

    @ViewBuilder
    private var phaseStatus: some View {
        switch model.phase {
        case .importing(let name):
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.format("Importing %@…", name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .accessibilityIdentifier("import-status")
        case .failed(let message):
            notice(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "Something went wrong",
                message: message
            )
            .accessibilityIdentifier("rom-error")
        case .finished(let message):
            notice(
                icon: "stop.circle",
                tint: .secondary,
                title: "Runtime stopped",
                message: message
            )
            .accessibilityIdentifier("runtime-finished")
        case .idle, .starting, .preparing, .loaded:
            EmptyView()
        }
    }

    private func notice(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        message: String
    ) -> some View {
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
    }

    // MARK: - Actions

    private func requestStart(_ entry: GameEntry) {
        if GameCatalog.bundled.isAOTPlayable(titleID: entry.titleID) {
            model.start(entry)
        } else {
            alert = .interpreter(entry)
        }
    }

    private func delete(_ entry: GameEntry) {
        do {
            try library.remove(id: entry.id)
        } catch {
            alert = .error(error.localizedDescription)
        }
    }

    private func alertView(for alert: HomeAlert) -> Alert {
        switch alert {
        case .interpreter(let entry):
            return Alert(
                title: Text("Run without AOT code?"),
                message: Text("This game has no linked AOT code in this build. It will run in the interpreter and may be slow."),
                primaryButton: .default(Text("Start Anyway"), action: {
                    model.start(entry)
                }),
                secondaryButton: .cancel()
            )
        case .delete(let entry):
            return Alert(
                title: Text(L10n.format("Delete “%@”?", entry.title)),
                message: Text("The imported ROM is removed from this app. Save data and save states stay on the device."),
                primaryButton: .destructive(Text("Delete"), action: {
                    delete(entry)
                }),
                secondaryButton: .cancel()
            )
        case .error(let message):
            return Alert(
                title: Text("Could not delete the game"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
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

    private var isBusy: Bool {
        model.isImporting
    }
}
