//
//  Screens.swift
//  3ds2apple macOS launcher
//
//  The two top-level sections from docs/launcher-ui.md:
//
//    Library  game cards, one status line, one primary action per game, plus the
//             on-device library status and the essential install/push actions.
//    Import   drag-and-drop or file picker, detected header, one primary button.
//
//  Everything else (signing setup, build mode, tools, logs, diagnostics, about)
//  lives in the Settings panel; the per-game secondary actions live in the game
//  detail dialog. Pure SwiftUI so the offscreen snapshot renderer can draw it.
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

private func stepRow(_ number: Int, _ title: String, _ detail: String) -> some View {
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
            if let task = busyTask {
                TaskProgressCard(task: task, strings: strings)
            }
            if model.libraryNeedsRebuild {
                rebuildWarning
            }
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

    private var busyTask: TaskRecord? {
        guard model.isBusy else { return nil }
        return model.activeTask
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(strings.gamesCount(model.games.count))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LauncherTheme.mutedText)
            Spacer()
            deviceChip
            Button {
                Task { await model.verifyPackages() }
            } label: {
                Label(strings.verifyPackages, systemImage: "checkmark.shield")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isBusy || model.isMock || model.games.isEmpty)
        }
    }

    @ViewBuilder
    private var deviceChip: some View {
        if let device = model.selectedDevice {
            HStack(spacing: 6) {
                Image(systemName: "iphone")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LauncherTheme.accentDeep)
                Text(strings.deviceSelected(device.name))
                    .font(.system(size: 11, weight: .medium))
                Button {
                    Task { await model.detectDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LauncherTheme.mutedText)
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(LauncherTheme.success.opacity(0.12)))
        } else {
            Button {
                Task { await model.detectDevices() }
            } label: {
                Label(strings.noDevice, systemImage: "iphone.slash")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isBusy)
        }
    }

    private var rebuildWarning: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LauncherTheme.warning)
            Text(strings.libraryNeedsRebuild)
                .font(.system(size: 11))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(strings.rebuildInstallLibrary) {
                Task { await model.buildAndInstallLibrary() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isBusy || model.builtGames.isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(LauncherTheme.warning.opacity(0.1)))
    }

    private var emptyLibrary: some View {
        Card {
            EmptyStateView(
                symbol: "square.grid.2x2",
                title: strings.emptyLibraryTitle,
                message: strings.emptyLibraryMessage
            )
            Button(strings.importFirstGame) {
                model.screen = .importROM
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var libraryStatusCard: some View {
        Card(title: strings.libraryStatusTitle) {
            if settings.libraryInstalledTitles.isEmpty {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strings.libraryNotInstalled)
                            .font(.system(size: 12, weight: .semibold))
                        Text(strings.romDataNote)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(strings.buildInstallLibrary) {
                        Task { await model.buildAndInstallLibrary() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isBusy || model.games.isEmpty)
                }
            } else {
                VStack(spacing: 6) {
                    KeyValueRow(key: strings.toolsInstalledTitles, value: strings.installedGames(settings.libraryInstalledTitles.count))
                    KeyValueRow(key: strings.libraryIPALabel, value: settings.libraryIPAPath.isEmpty ? "-" : settings.libraryIPAPath, mono: true)
                }
                if model.libraryNeedsRebuild {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(LauncherTheme.warning)
                        Text(strings.libraryNeedsRebuild)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(LauncherTheme.success)
                        Text(strings.libraryUpToDate)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                        Spacer(minLength: 0)
                    }
                }
                Text(strings.romDataNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct GameCard: View {
    let game: GameEntry
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    let strings: LauncherStrings

    private var isInLibrary: Bool {
        settings.libraryInstalledTitles.contains(game.titleID)
    }

    private var isBusy: Bool { model.isBusy }

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
                metric(strings.fieldROMSize, humanBytes(game.romBytes))
                metric(strings.fieldPackSize, humanBytes(game.packBytes))
            }
            if let error = game.lastError {
                Text(strings.lastError + ": " + error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.danger)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                primaryAction
                Spacer(minLength: 0)
                Button {
                    model.detailGameID = game.titleID
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(strings.secondaryDetails)
            }
        }
        .launcherCard()
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch game.phase {
        case .queued, .failed:
            Button(strings.primaryBuild) {
                Task { await model.build(gameID: game.titleID) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isBusy)
        case .building:
            Button(strings.primaryBuilding) {}
                .buttonStyle(SecondaryButtonStyle())
                .disabled(true)
        case .built:
            if !isInLibrary {
                Button(strings.primaryInstall) {
                    Task { await model.buildAndInstallLibrary() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isBusy || model.builtGames.isEmpty)
            } else {
                Button(strings.primaryPush) {
                    Task {
                        _ = await model.preparePush(gameID: game.titleID)
                        await model.pushGame(gameID: game.titleID)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isBusy)
            }
        case .pushed:
            Button(strings.primaryHowToPlay) {
                model.detailGameID = game.titleID
            }
            .buttonStyle(PrimaryButtonStyle())
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

/// File drop is a live-app feature only; the offscreen snapshot renderer draws the
/// same tree without the AppKit drag-destination registration.
private struct FileDropModifier: ViewModifier {
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

// MARK: - Import

struct ImportScreen: View {
    @ObservedObject var model: AppModel
    let strings: LauncherStrings
    @Environment(\.launcherScreenshotMode) private var screenshotMode
    @State private var isDropTarget = false
    @State private var rejection: String?

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            dropCard
            if let rom = model.detectedROM {
                detectedCard(rom)
            } else if let error = model.detectedROMError {
                errorCard(error)
            }
            if model.isBusy, let task = model.activeTask,
               task.kind == .importROM || task.kind == .detect {
                TaskProgressCard(task: task, strings: strings)
                Card(title: strings.importLogsTitle) {
                    LogConsole(
                        entries: model.logs.filter { ["rom", "pack", "import"].contains($0.category) },
                        maximumLines: 8,
                        strings: strings
                    )
                }
            }
            stepsCard
        }
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
            .modifier(FileDropModifier(enabled: !screenshotMode, isTargeted: $isDropTarget, onDrop: handleDrop))
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
                    Task { await model.importDetected(includeROM: false) }
                } label: {
                    Label(strings.queueGame, systemImage: "plus.circle.fill")
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
        Card(title: strings.stepsTitle) {
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
