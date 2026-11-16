//
//  Screens.swift
//  3ds2apple macOS launcher
//
//  The two top-level sections from launcher/macos/README.md:
//
//    Library  import/add/list/remove only; SMDH name/publisher/cover are
//             read-only (no name input); no build/install/push buttons.
//    Deploy   select one or several library games -> one-click batch deploy:
//             compile -> compose one ROM-free IPA -> verify -> install -> push
//             -> verify -> Done. Per-step state and logs live on this page.
//
//  Import is a single Library button that opens the file picker and imports the
//  chosen ROM directly (no import sheet). Everything is pure SwiftUI so the
//  offscreen snapshot renderer can draw it on the headless build VM.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Formatting helpers

func humanBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "-" }
    return FileProbe.formatBytes(bytes)
}

// MARK: - Library

struct LibraryScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    let strings: LauncherStrings

    private let columns = [GridItem(.adaptive(minimum: 330), spacing: 14)]

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            header
            if model.games.isEmpty {
                emptyLibrary
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.games) { game in
                        GameCard(game: game, model: model, settings: settings, strings: strings)
                    }
                }
            }
        }
    }

    /// The whole import area is exactly one button: it opens the file picker and
    /// imports the chosen ROM (header read + staging + library entry in one go).
    /// No path field, name override, explanatory card or readiness panel here.
    private var header: some View {
        HStack(spacing: 10) {
            Text(strings.gamesCount(model.games.count))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LauncherTheme.mutedText)
            Spacer()
            Button {
                chooseROM()
            } label: {
                Label(strings.importButton, systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isBusy)
        }
    }

    private var emptyLibrary: some View {
        EmptyStateView(
            symbol: "square.grid.2x2",
            title: strings.emptyLibraryTitle,
            message: ""
        )
    }

    private func chooseROM() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let extensions = ["3ds", "cci", "ncch", "cxi"]
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        panel.message = strings.dropHint
        panel.prompt = strings.choose
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importROM(at: url.path) }
        }
    }
}

private struct GameCard: View {
    let game: GameEntry
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    let strings: LauncherStrings

    @State private var showingRemove = false

    private var isInLibrary: Bool {
        model.isInInstalledLibrary(game.titleID)
    }

    /// The ROM's own SMDH name for the current UI language. There is no editable
    /// name input any more: the pack CLI is the only source of game names.
    private var localizedName: String {
        GameNames.resolve(
            displayNames: game.displayNames,
            displayName: game.displayName,
            uiLanguageTag: strings.language.localeIdentifier
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                GameArtwork(game: game, language: strings.language, size: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(localizedName)
                        .font(LauncherTheme.rounded(14, weight: .semibold))
                        .lineLimit(1)
                    Text(game.productCode.isEmpty ? game.titleID : game.productCode)
                        .font(LauncherTheme.mono(10.5, weight: .medium))
                        .foregroundStyle(LauncherTheme.accentDeep)
                    if !game.publisher.isEmpty {
                        Text(strings.publisher(game.publisher))
                            .font(.system(size: 10))
                            .foregroundStyle(LauncherTheme.mutedText)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        GamePhaseBadge(phase: game.phase, strings: strings)
                        if isInLibrary {
                            Badge(text: strings.inLibraryBadge, tone: .success, symbol: "checkmark.seal.fill")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                metric(strings.romSizeLabel, humanBytes(game.romBytes))
                metric(strings.packSizeLabel, humanBytes(game.packBytes))
                metric(strings.statusLabel, game.romDataPath == nil ? strings.noDataStaged : strings.dataStaged)
            }
            if let error = game.lastError {
                Text(strings.lastErrorLabel + ": " + error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.danger)
                    .lineLimit(2)
            }
            if game.isOnDevice {
                Text(strings.howToPlayStep4)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    Task {
                        await model.refreshLibrary()
                    }
                } label: {
                    Label(strings.refresh, systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
                Spacer(minLength: 0)
                Button {
                    showingRemove = true
                } label: {
                    Text(strings.remove)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
            }
        }
        .launcherCard()
        .alert(strings.removeConfirmTitle, isPresented: $showingRemove) {
            Button(strings.cancel, role: .cancel) {}
            Button(strings.removeConfirmAction, role: .destructive) {
                model.removeGame(titleID: game.titleID)
            }
        } message: {
            Text(strings.removeConfirmMessage)
        }
    }

    private func metric(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(LauncherTheme.mutedText)
            Text(value)
                .font(LauncherTheme.mono(10.5, weight: .medium))
        }
    }
}

// MARK: - Deploy

struct DeployScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    let strings: LauncherStrings

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            if model.games.isEmpty {
                emptyState
            } else {
                deviceCard
                selectionCard
                if let report = model.deployReport {
                    DeployReportCard(report: report, model: model, strings: strings)
                }
                logCard
            }
        }
    }

    private var emptyState: some View {
        Card {
            EmptyStateView(
                symbol: "iphone.and.arrow.forward",
                title: strings.deployNoGames,
                message: ""
            )
            Button(strings.openLibrary) {
                model.screen = .library
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var deviceCard: some View {
        Card(title: strings.deployDeviceTitle) {
            HStack(spacing: 12) {
                if let device = model.selectedDevice {
                    Image(systemName: "iphone")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LauncherTheme.accentDeep)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(device.model + " · iOS " + device.iosVersion + " · " + device.connectionLabel)
                            .font(LauncherTheme.mono(10.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                    }
                } else {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LauncherTheme.warning)
                    Text(strings.deployDeviceNone)
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await model.detectDevices() }
                } label: {
                    Label(strings.deployDetectDevice, systemImage: "cable.connector")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
            }
            HStack(spacing: 12) {
                KeyValueRow(
                    key: strings.deployInstalledBundle,
                    value: settings.installedBundleID.isEmpty ? strings.deployNotInstalledBundle : settings.installedBundleID,
                    mono: true
                )
            }
        }
    }

    private var selectionCard: some View {
        Card(
            title: strings.deploySelectionTitle,
            subtitle: strings.deploySelected(model.selectedForDeploy.count),
            trailing: AnyView(
                HStack(spacing: 8) {
                    Button(strings.deploySelectAll) { model.selectAllDeploy() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isBusy)
                    Button(strings.deployClearSelection) { model.clearDeploySelection() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isBusy)
                }
            )
        ) {
            VStack(spacing: 8) {
                ForEach(model.games) { game in
                    DeployGameRow(
                        game: game,
                        model: model,
                        strings: strings,
                        selected: model.selectedForDeploy.contains(game.titleID)
                    )
                }
            }
            HStack(spacing: 12) {
                Text(strings.deploySelected(model.selectedForDeploy.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LauncherTheme.mutedText)
                Spacer()
                Button {
                    Task { await model.deploySelected() }
                } label: {
                    Label(strings.deployButton(model.selectedForDeploy.count), systemImage: "bolt.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy || model.selectedForDeploy.isEmpty)
            }
            .padding(.top, 4)
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LauncherTheme.mutedText)
                Text(strings.hardwareLine(model.hardware))
                    .font(LauncherTheme.mono(9.5, weight: .medium))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .help(model.hardware.describe)
            Text(strings.deployNoteROMFree)
                .font(.system(size: 10.5))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var logCard: some View {
        Card(title: strings.deployLogTitle) {
            LogConsole(
                entries: model.logs.filter { ["deploy", "build", "library", "install", "push", "devpush"].contains($0.category) },
                maximumLines: 12,
                strings: strings
            )
        }
    }
}

private struct DeployGameRow: View {
    let game: GameEntry
    @ObservedObject var model: AppModel
    let strings: LauncherStrings
    let selected: Bool

    private var plan: PushPlan? { model.pushPlans[game.titleID] }

    var body: some View {
        Button {
            model.toggleDeploySelection(game.titleID)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? LauncherTheme.accentDeep : LauncherTheme.mutedText)
                GameArtwork(game: game, language: strings.language, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(GameNames.resolve(
                            displayNames: game.displayNames,
                            displayName: game.displayName,
                            uiLanguageTag: strings.language.localeIdentifier
                        ))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        GamePhaseBadge(phase: game.phase, strings: strings)
                        if model.isInInstalledLibrary(game.titleID) {
                            Badge(text: strings.inLibraryBadge, tone: .success, symbol: "checkmark.seal.fill")
                        } else if plan?.verified == true {
                            Badge(text: strings.deployPushed(1), tone: .accent, symbol: "arrow.up.circle.fill")
                        }
                    }
                    Text(game.productCode.isEmpty ? game.titleID : game.productCode)
                        .font(LauncherTheme.mono(10))
                        .foregroundStyle(LauncherTheme.accentDeep)
                    Text(game.isAOTReady ? strings.deployEligible : strings.deployNeedsBuild)
                        .font(.system(size: 10))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(humanBytes(game.romBytes))
                        .font(LauncherTheme.mono(10.5, weight: .medium))
                    Text(humanBytes(game.packBytes))
                        .font(LauncherTheme.mono(9.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? LauncherTheme.accent.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
    }
}

struct DeployReportCard: View {
    let report: DeployReport
    @ObservedObject var model: AppModel
    let strings: LauncherStrings

    private var title: String {
        switch report.state {
        case .succeeded: return strings.deployDoneTitle
        case .failed, .cancelled: return strings.deployFailedTitle
        default: return strings.deployStepsTitle
        }
    }

    private var tone: BadgeTone {
        switch report.state {
        case .succeeded: return .success
        case .failed: return .danger
        case .cancelled: return .warning
        default: return .accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: report.state == .succeeded ? "checkmark.seal.fill" : "iphone.and.arrow.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tone.foreground)
                Text(title)
                    .font(LauncherTheme.rounded(14, weight: .semibold))
                Spacer()
                Badge(text: strings.taskState(report.state), tone: tone)
                if let bundleID = report.installedBundleID, !bundleID.isEmpty {
                    Text(bundleID)
                        .font(LauncherTheme.mono(10))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
            }
            ProgressBar(value: report.progress, tint: report.state == .failed ? LauncherTheme.danger : LauncherTheme.accent)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.steps) { stage in
                    StageRow(stage: stage)
                }
            }
            if report.state == .succeeded {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LauncherTheme.success)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strings.deployDoneMessage)
                            .font(.system(size: 13, weight: .semibold))
                        Text(strings.deployPushed(report.pushedTitles.count) + " · " + (report.inspection.map { strings.deployIPAVerified($0.packCount) } ?? ""))
                            .font(.system(size: 10.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                        Text(strings.howToPlayStep4)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(LauncherTheme.success.opacity(0.10)))
            }
            if report.state == .failed || report.state == .cancelled {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.failureMessage ?? strings.deployFailedTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LauncherTheme.danger)
                    if let hint = report.failureHint, !hint.isEmpty {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(LauncherTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(LauncherTheme.danger.opacity(0.08)))
                HStack {
                    Spacer()
                    Button(strings.deployRetry) {
                        Task { await model.deploySelected() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isBusy)
                }
            }
        }
        .launcherCard()
    }
}
