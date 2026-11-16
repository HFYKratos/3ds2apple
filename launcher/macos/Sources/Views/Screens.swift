//
//  Screens.swift
//  3ds2apple macOS launcher
//
//  The two top-level sections from docs/launcher-flow-v2.md:
//
//    Library  import/add/list/remove/rename only; no build/install/push buttons.
//    Deploy   select one or several library games -> one-click batch deploy:
//             compile -> compose one ROM-free IPA -> verify -> install -> push
//             -> verify -> Done. Per-step state and logs live on this page.
//
//  Import is a sheet launched from the Library. Everything is pure SwiftUI so
//  the offscreen snapshot renderer can draw it on the headless build VM.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Formatting helpers

func humanBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "-" }
    return FileProbe.formatBytes(bytes)
}

func shortHash(_ hash: String?) -> String {
    guard let hash, hash.count >= 12 else { return hash ?? "-" }
    return String(hash.prefix(12)) + "..."
}

func stepRow(_ number: Int, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Text(String(number))
            .font(LauncherTheme.mono(10, weight: .bold))
            .foregroundStyle(LauncherTheme.accentDeep)
            .frame(width: 18, height: 18)
            .background(Circle().fill(LauncherTheme.accent.opacity(0.2)))
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
    }
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
            libraryStatusCard
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(strings.gamesCount(model.games.count))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LauncherTheme.mutedText)
            Spacer()
            deviceChip
            Button {
                model.importPresented = true
            } label: {
                Label(strings.importGame, systemImage: "plus")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isBusy)
        }
    }

    @ViewBuilder
    private var deviceChip: some View {
        if let device = model.selectedDevice {
            HStack(spacing: 6) {
                Image(systemName: "iphone")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LauncherTheme.accentDeep)
                Text(device.name)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(LauncherTheme.success.opacity(0.12)))
        } else {
            Button {
                Task { await model.detectDevices() }
            } label: {
                Label(strings.deployDeviceNone, systemImage: "iphone.slash")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isBusy)
        }
    }

    private var emptyLibrary: some View {
        Card {
            EmptyStateView(
                symbol: "square.grid.2x2",
                title: strings.emptyLibraryTitle,
                message: strings.emptyLibraryMessage
            )
            Button(strings.addFirstGame) {
                model.importPresented = true
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var libraryStatusCard: some View {
        Card(title: strings.deployInstalledBundle) {
            VStack(alignment: .leading, spacing: 6) {
                if settings.libraryInstalledTitles.isEmpty {
                    Text(strings.deployNotInstalledBundle)
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                } else {
                    KeyValueRow(key: strings.statusLabel, value: strings.deployPushed(settings.libraryInstalledTitles.count))
                    KeyValueRow(key: strings.deployInstalledBundle, value: settings.installedBundleID.isEmpty ? strings.deviceBundleIDNone : settings.installedBundleID, mono: true)
                    KeyValueRow(key: strings.libraryIPALabel, value: settings.libraryIPAPath.isEmpty ? "-" : settings.libraryIPAPath, mono: true)
                    if model.libraryNeedsRebuild {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(LauncherTheme.warning)
                            Text(strings.deployNeedsBuild)
                                .font(.system(size: 10.5))
                                .foregroundStyle(LauncherTheme.mutedText)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Text(strings.deployNoteROMFree)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GameCard: View {
    let game: GameEntry
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    let strings: LauncherStrings

    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingRemove = false

    private var isInLibrary: Bool {
        model.isInInstalledLibrary(game.titleID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                GameArtwork(game: game, size: 50)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.displayName)
                        .font(LauncherTheme.rounded(14, weight: .semibold))
                        .lineLimit(1)
                    Text(game.productCode.isEmpty ? game.titleID : game.productCode)
                        .font(LauncherTheme.mono(10.5, weight: .medium))
                        .foregroundStyle(LauncherTheme.accentDeep)
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
                    renameText = game.displayName
                    showingRename = true
                } label: {
                    Text(strings.rename)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
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
        .alert(strings.renameTitle, isPresented: $showingRename) {
            TextField(strings.fieldDisplayName, text: $renameText)
            Button(strings.cancel, role: .cancel) {}
            Button(strings.renameSave) {
                model.renameGame(titleID: game.titleID, newName: renameText)
            }
        } message: {
            Text(game.titleID)
        }
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
                message: strings.emptyLibraryMessage
            )
            Button(strings.addFirstGame) {
                model.importPresented = true
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
                GameArtwork(game: game, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(game.displayName)
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

// MARK: - Import sheet

/// File drop is a live-app feature only; the offscreen snapshot renderer draws the
/// same tree without the AppKit drag-destination registration.
private struct SheetFileDropModifier: ViewModifier {
    let enabled: Bool
    @Binding var isTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted, perform: onDrop)
        } else {
            content
        }
    }
}

struct ImportSheetView: View {
    @ObservedObject var model: AppModel
    @Environment(\.launcherScreenshotMode) private var screenshotMode
    @State private var isDropTarget = false
    @State private var rejection: String?

    private var strings: LauncherStrings { model.strings }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(LauncherTheme.border)
                .frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    dropCard
                    if let rom = model.detectedROM {
                        detectedCard(rom)
                    } else if let error = model.detectedROMError {
                        errorCard(error)
                    }
                    stepsCard
                    if model.isBusy {
                        Card(title: strings.importLogsTitle) {
                            LogConsole(
                                entries: model.logs.filter { ["rom", "pack", "import"].contains($0.category) },
                                maximumLines: 8,
                                strings: strings
                            )
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 620, idealHeight: 700)
        .background(LauncherTheme.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: "square.and.arrow.down.on.square", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.importTitle)
                    .font(LauncherTheme.rounded(19, weight: .bold))
                Text(strings.importSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
            Spacer()
            ModeBadge(isMock: model.isMock, strings: strings)
            Button(strings.close) {
                model.importPresented = false
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(LauncherTheme.background)
    }

    private var dropCard: some View {
        Card(title: strings.dropTitle) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LauncherTheme.accent.opacity(0.14))
                        .frame(width: 66, height: 66)
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(LauncherTheme.accentDeep)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(strings.dropMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(strings.dropHint)
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText.opacity(0.85))
                    if let rejection {
                        Text(rejection)
                            .font(.system(size: 11))
                            .foregroundStyle(LauncherTheme.danger)
                    }
                }
                Spacer(minLength: 8)
                if screenshotMode {
                    Text(strings.dropChoose)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(LauncherTheme.accentDeep))
                } else {
                    Button {
                        chooseROM()
                    } label: {
                        Label(strings.dropChoose, systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isBusy)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isDropTarget ? LauncherTheme.accent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isDropTarget ? LauncherTheme.accent : LauncherTheme.border,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .modifier(SheetFileDropModifier(enabled: !screenshotMode, isTargeted: $isDropTarget, onDrop: handleDrop))
        }
    }

    private func detectedCard(_ rom: DetectedROM) -> some View {
        Card(
            title: strings.detectedTitle,
            trailing: AnyView(Badge(text: strings.detectedBadge, tone: .accent, symbol: "eye"))
        ) {
            VStack(spacing: 6) {
                KeyValueRow(key: strings.fieldTitleID, value: rom.titleID, mono: true)
                KeyValueRow(key: strings.fieldDisplayName, value: rom.displayName)
                KeyValueRow(key: strings.fieldProductCode, value: rom.productCode.isEmpty ? "-" : rom.productCode, mono: true)
                KeyValueRow(key: strings.fieldContainer, value: rom.container.uppercased(), mono: true)
                KeyValueRow(key: strings.fieldROMSize, value: humanBytes(rom.bytes))
                KeyValueRow(key: strings.fieldContentSize, value: humanBytes(rom.contentBytes))
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.importDetected() }
                } label: {
                    Label(strings.addGame, systemImage: "plus.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)
                Button(strings.clearSelection) {
                    model.detectedROM = nil
                    model.detectedROMError = nil
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LauncherTheme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text(strings.unrecognisedTitle)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(LauncherTheme.danger.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(LauncherTheme.danger.opacity(0.3), lineWidth: 1))
    }

    private var stepsCard: some View {
        Card(title: strings.importStepsTitle) {
            VStack(alignment: .leading, spacing: 9) {
                stepRow(1, strings.step1Title, strings.step1Detail)
                stepRow(2, strings.step2Title, strings.step2Detail)
                stepRow(3, strings.step3Title, strings.step3Detail)
                stepRow(4, strings.step4Title, strings.step4Detail)
            }
        }
    }

    // MARK: file picking

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
            rejection = nil
            Task { await model.detectROM(at: url.path) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                }
                guard let url else { return }
                let allowed = ["3ds", "cci", "ncch", "cxi"]
                guard allowed.contains(url.pathExtension.lowercased()) else {
                    DispatchQueue.main.async { rejection = strings.dropUnsupported }
                    return
                }
                DispatchQueue.main.async {
                    rejection = nil
                    Task { await model.detectROM(at: url.path) }
                }
            }
        }
        return accepted
    }
}
