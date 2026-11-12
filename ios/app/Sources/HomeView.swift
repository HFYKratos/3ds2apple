//
//  HomeView.swift
//  3ds2apple
//
//  Landing page: the current game card with Play / Import actions, and the
//  entry points to Settings, the Save Manager, diagnostics export and About.
//

import Foundation
import SwiftUI
import UIKit

/// Pages pushed from the home page.
private enum HomeRoute: Hashable {
    case settings
    case saveManager
    case about
}

struct HomeView: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var settings: AppSettings

    @State private var sheet: HomeSheet?

    /// One sheet slot for the two sheets the home page can present (the system
    /// Files picker and the diagnostics share sheet).
    private enum HomeSheet: Identifiable {
        case filesPicker
        case diagnostics(URL)

        var id: String {
            switch self {
            case .filesPicker: return "files-picker"
            case .diagnostics(let url): return "diagnostics-\(url.path)"
            }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    gameCard
                    quickActions
                    footer
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView(settings: settings, model: model)
                case .saveManager:
                    SaveManagerView(model: model)
                case .about:
                    AboutView(model: model)
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .filesPicker:
                ROMDocumentPicker { url in
                    self.sheet = nil
                    if let url {
                        model.importROM(from: url)
                    }
                }
            case .diagnostics(let url):
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("3ds2apple")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .accessibilityIdentifier("app-title")
                Spacer(minLength: 8)
                Text(versionLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Text("Nintendo 3DS, natively on iPhone and iPad")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Current game

    private var gameCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                coverPlaceholder
                VStack(alignment: .leading, spacing: 6) {
                    Text(gameTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .accessibilityIdentifier("game-title")
                    Text(gameSubtitle)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            phaseDetail
            gameActions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityIdentifier("rom-card")
    }

    private var gameTitle: String {
        model.lastROM?.name ?? "No game imported"
    }

    private var gameSubtitle: String {
        if let rom = model.lastROM {
            return "Imported game · \(rom.relativePath)"
        }
        return "Import a decrypted .3ds or .cci from the Files app. "
            + "The file is copied into this app's Documents folder and stays on the device."
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.9), Color(uiColor: .systemIndigo)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 64, height: 78)
            .overlay(
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var phaseDetail: some View {
        switch model.phase {
        case .idle:
            Text(model.lastROM == nil
                 ? "No game imported yet."
                 : "Ready to load the imported game.")
                .font(.footnote)
                .foregroundColor(.secondary)
        case .importing(let name):
            HStack(spacing: 8) {
                ProgressView()
                Text("Importing \(name)…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .starting(let name):
            HStack(spacing: 8) {
                ProgressView()
                Text("Starting \(name)…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        case .preparing(let name):
            Text("Preparing graphics for \(name)…")
                .font(.footnote)
                .foregroundColor(.secondary)
        case .loaded(let name):
            Label("Loaded: \(name)", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundColor(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Could not load the game", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.red)
                    .accessibilityIdentifier("rom-error")
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        case .finished(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Runtime stopped", systemImage: "stop.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("runtime-finished")
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var gameActions: some View {
        if model.lastROM != nil {
            Button {
                model.loadLastROM()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
            .accessibilityIdentifier("load-last-rom")

            Button {
                sheet = .filesPicker
            } label: {
                Label("Import / Change ROM…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isBusy)
            .accessibilityIdentifier("import-rom")
        } else {
            Button {
                sheet = .filesPicker
            } label: {
                Label("Import ROM…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy)
            .accessibilityIdentifier("import-rom")
        }

        if isShowingNotice {
            Button("Dismiss") {
                model.dismissNotice()
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
    }

    private var isBusy: Bool {
        if case .importing = model.phase { return true }
        return false
    }

    private var isShowingNotice: Bool {
        if case .failed = model.phase { return true }
        if case .finished = model.phase { return true }
        return false
    }

    // MARK: - Tools

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools")
                .font(.headline)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                NavigationLink(value: HomeRoute.settings) {
                    actionTile(
                        title: "Settings",
                        systemImage: "gearshape.fill",
                        detail: "Display, audio, controls, performance, storage",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-link")

                NavigationLink(value: HomeRoute.saveManager) {
                    actionTile(
                        title: "Save Manager",
                        systemImage: "externaldrive.fill",
                        detail: "Battery saves written by the game",
                        tint: .green
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("save-manager-link")

                Button {
                    exportDiagnostics()
                } label: {
                    actionTile(
                        title: "Diagnostics",
                        systemImage: "square.and.arrow.up",
                        detail: "Export a report and the session log",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("export-diagnostics")

                NavigationLink(value: HomeRoute.about) {
                    actionTile(
                        title: "About",
                        systemImage: "info.circle.fill",
                        detail: "Version, runtime and acknowledgements",
                        tint: .purple
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-link")
            }
        }
    }

    private func actionTile(
        title: String,
        systemImage: String,
        detail: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Games run as native ARM64 code (AOT) — no CPU JIT. "
                 + "Your ROM and save data stay on this device.")
            Text("3ds2apple is not affiliated with Nintendo. Use only game dumps you made from your own console.")
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func exportDiagnostics() {
        if let url = DiagnosticsExporter.write(model: model, settings: settings) {
            sheet = .diagnostics(url)
        }
    }
}
