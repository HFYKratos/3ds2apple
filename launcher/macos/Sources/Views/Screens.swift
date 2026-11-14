//
//  Screens.swift
//  3ds2apple macOS launcher
//
//  The seven screens of the MVP. All pure SwiftUI so the same view tree is used
//  by the app and by the offscreen screenshot renderer.
//

import SwiftUI
import AppKit

private func humanBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "-" }
    return FileProbe.formatBytes(bytes)
}

private func shortHash(_ hash: String?) -> String {
    guard let hash, hash.count >= 12 else { return hash ?? "-" }
    return String(hash.prefix(12)) + "..."
}

@MainActor
private func gameById(_ model: AppModel, _ id: String?) -> GameEntry? {
    guard let id else { return model.selectedGame }
    return model.games.first(where: { $0.titleID == id }) ?? model.selectedGame
}

// MARK: - Import

struct ImportScreen: View {
    @ObservedObject var model: AppModel
    @Environment(\.launcherScreenshotMode) private var screenshotMode

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            addGameCard
            if let rom = model.detectedROM {
                detectedCard(rom)
            } else if let error = model.detectedROMError {
                errorCard(error)
            }
            stepsCard
            if !model.games.isEmpty {
                recentCard
            }
        }
    }

    private var addGameCard: some View {
        Card(title: "Add a game", subtitle: "decrypted .3ds / .cci / .ncch / .cxi") {
            Text("Select a ROM you own. The launcher reads only the NCSD/NCCH header (a few KiB) to detect the title, then queues one AOT package. The ROM is never uploaded and never copied into the shell IPA.")
                .font(.system(size: 12))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if screenshotMode {
                    Text("Choose ROM...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(LauncherTheme.accentDeep))
                } else {
                    Button {
                        chooseROM()
                    } label: {
                        Label("Choose ROM...", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isBusy)
                }
                if let rom = model.detectedROM {
                    Text(rom.path)
                        .font(LauncherTheme.mono(10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No ROM selected yet")
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    private func detectedCard(_ rom: DetectedROM) -> some View {
        Card(
            title: "Detected title",
            trailing: AnyView(Badge(text: "HEADER ONLY", tone: .accent, symbol: "eye"))
        ) {
            VStack(spacing: 6) {
                KeyValueRow(key: "Title ID", value: rom.titleID, mono: true)
                KeyValueRow(key: "Display name", value: rom.displayName)
                KeyValueRow(key: "Product code", value: rom.productCode.isEmpty ? "-" : rom.productCode, mono: true)
                KeyValueRow(key: "Container", value: rom.container.uppercased(), mono: true)
                KeyValueRow(key: "ROM size", value: humanBytes(rom.bytes))
                KeyValueRow(key: "Content size", value: humanBytes(rom.contentBytes))
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.importDetected(includeROM: true) }
                } label: {
                    Label("Queue this game", systemImage: "plus.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)
                Button("Clear") {
                    model.detectedROM = nil
                    model.detectedROMError = nil
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Text("AOT code goes into the signed library IPA; the ROM is staged for the Documents push, never bundled in the IPA.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
            .padding(.top, 4)
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LauncherTheme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text("That file was not recognised")
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
        Card(title: "What happens next") {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Detect", "Header only: title ID, product code, display name.")
                step(2, "Build", "3dsrecomp translates the game; clang builds one GamePack.dylib for arm64.")
                step(3, "Install library", "Build a ROM-free IPA with GamePack-<TITLEID>.dylib + GameCatalog inside, sign it with your own Apple ID, install with devicectl.")
                step(4, "Push game data", "Copy GameRom.cci + GameInfo.json into Documents/Games/TITLEID; the GamePack is already in the signed app.")
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
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
            }
        }
    }

    private var recentCard: some View {
        Card(title: "Recently added") {
            VStack(spacing: 8) {
                ForEach(model.games.prefix(4)) { game in
                    HStack(spacing: 10) {
                        Text(game.titleID)
                            .font(LauncherTheme.mono(11, weight: .semibold))
                            .foregroundStyle(LauncherTheme.accentDeep)
                        Text(game.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        GamePhaseBadge(phase: game.phase)
                        Button("Open") {
                            model.selectedGameID = game.titleID
                            model.screen = .build
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if game.id != model.games.prefix(4).last?.id {
                        Rectangle().fill(LauncherTheme.border).frame(height: 1)
                    }
                }
            }
        }
    }

    private func chooseROM() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["3ds", "cci", "ncch", "cxi", "app"]
        panel.message = "Choose a decrypted 3DS ROM that you own."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.detectROM(at: url.path) }
        }
    }
}

// MARK: - Library

struct LibraryScreen: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            HStack(spacing: 10) {
                Text(String(model.games.count) + " game(s) in the library")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LauncherTheme.mutedText)
                Spacer()
                Button {
                    Task { await model.refreshPackages() }
                } label: {
                    Label("Refresh packages", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
                Button {
                    Task { await model.verifyPackages() }
                } label: {
                    Label("Verify packages", systemImage: "checkmark.shield")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy || model.isMock)
            }
            if model.libraryNeedsRebuild {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LauncherTheme.warning)
                    Text("The installed library IPA does not match the built games. Open Shell + library to rebuild and reinstall it; pushed ROM data is kept.")
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(LauncherTheme.warning.opacity(0.1)))
            }
            if model.games.isEmpty {
                Card(title: "No games yet") {
                    EmptyStateView(
                        symbol: "square.grid.2x2",
                        title: "Import your first ROM",
                        message: "The launcher keeps the library in out/packages. One shell on the phone holds every built game."
                    )
                    Button("Import a ROM") {
                        model.screen = .importROM
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.games) { game in
                        GameCard(game: game, model: model)
                    }
                }
            }
            if let game = model.selectedGame {
                detailCard(game)
            }
        }
    }

    private func detailCard(_ game: GameEntry) -> some View {
        Card(title: "Package details", subtitle: game.displayName) {
            VStack(spacing: 6) {
                KeyValueRow(key: "Title ID", value: game.titleID, mono: true)
                KeyValueRow(key: "Save namespace", value: game.saveNamespace, mono: true)
                KeyValueRow(key: "Build name", value: game.buildSlug, mono: true)
                KeyValueRow(key: "ROM", value: game.romPath.isEmpty ? "-" : game.romPath, mono: true)
                KeyValueRow(key: "ROM size", value: humanBytes(game.romBytes))
                KeyValueRow(key: "GamePack", value: game.packPath ?? "not built", mono: true)
                KeyValueRow(key: "GamePack size", value: humanBytes(game.packBytes))
                KeyValueRow(key: "GamePack sha256", value: shortHash(game.packSha256), mono: true)
                KeyValueRow(key: "In installed library", value: model.settings.libraryInstalledTitles.contains(game.titleID) ? "yes (signed IPA)" : "no - build & install library")
                KeyValueRow(key: "Game data (push)", value: game.romDataPath ?? "not staged")
                if let packed = game.pushedAt {
                    KeyValueRow(key: "Pushed", value: GameInfoWriter.iso8601(packed))
                }
            }
        }
    }
}

private struct GameCard: View {
    let game: GameEntry
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.displayName)
                        .font(LauncherTheme.rounded(14, weight: .semibold))
                        .lineLimit(1)
                    Text(game.titleID)
                        .font(LauncherTheme.mono(10.5, weight: .medium))
                        .foregroundStyle(LauncherTheme.accentDeep)
                }
                Spacer()
                if model.settings.libraryInstalledTitles.contains(game.titleID) {
                    Badge(text: "IN IPA", tone: .accent, symbol: "checkmark.seal.fill")
                }
                GamePhaseBadge(phase: game.phase)
            }
            HStack(spacing: 14) {
                metric("ROM", humanBytes(game.romBytes))
                metric("Pack", humanBytes(game.packBytes))
                metric("Product", game.productCode.isEmpty ? "-" : game.productCode)
            }
            if let error = game.lastError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.danger)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button {
                    model.selectedGameID = game.titleID
                    model.screen = .build
                } label: {
                    Label("Build", systemImage: "hammer")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    model.selectedGameID = game.titleID
                    model.screen = .device
                    Task { _ = await model.preparePush(gameID: game.titleID, quiet: true) }
                } label: {
                    Label("Push", systemImage: "arrow.up.doc.on.clipboard")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(game.phase != .built && game.phase != .pushed)
                .opacity(game.phase == .built || game.phase == .pushed ? 1 : 0.4)
                Spacer()
            }
        }
        .launcherCard()
        .overlay(
            RoundedRectangle(cornerRadius: LauncherTheme.cardRadius, style: .continuous)
                .stroke(model.selectedGameID == game.titleID ? LauncherTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .onTapGesture {
            model.selectedGameID = game.titleID
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(LauncherTheme.mutedText)
            Text(value)
                .font(LauncherTheme.mono(10.5, weight: .medium))
                .lineLimit(1)
        }
    }
}

// MARK: - Build

struct BuildScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    private var game: GameEntry? { gameById(model, model.selectedGameID) }
    private var latestTask: TaskRecord? {
        guard let id = game?.titleID else { return nil }
        return model.tasks.first(where: { $0.titleID == id && $0.kind == .buildAOT })
    }

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            gamePicker
            modeCard
            planCard
            HStack(spacing: 10) {
                Button {
                    if let id = game?.titleID {
                        Task { await model.build(gameID: id) }
                    }
                } label: {
                    Label("Build GamePack", systemImage: "hammer.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy || game == nil)
                Button("Cancel") {
                    model.cancelActiveTask()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.isBusy)
                .opacity(model.isBusy ? 1 : 0.4)
                Spacer()
                if settings.buildMode == .real {
                    Text("Real builds run 3dsrecomp + clang and can take a long time.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
            }
            if let task = latestTask {
                TaskProgressCard(task: task)
            } else {
                Card(title: "Build status") {
                    EmptyStateView(
                        symbol: "hammer",
                        title: "Nothing built yet",
                        message: "A GamePack is the per-game arm64 AOT dylib that the shell loads. Build it here, then push it to the phone."
                    )
                }
            }
            Card(title: "Build log") {
                LogConsole(entries: model.logs.filter { $0.category == "build" || $0.category == "pack" }, maximumLines: 12)
                    .frame(height: 190)
            }
        }
    }

    private var gamePicker: some View {
        Card(title: "Game") {
            if model.games.isEmpty {
                Text("Import a ROM first.")
                    .font(.system(size: 12))
                    .foregroundStyle(LauncherTheme.mutedText)
            } else {
                HStack(spacing: 8) {
                    ForEach(model.games) { item in
                        ChipButton(
                            title: item.displayName,
                            symbol: item.phase == .built ? "checkmark.circle.fill" : "square",
                            selected: item.titleID == game?.titleID
                        ) {
                            model.selectedGameID = item.titleID
                        }
                    }
                    Spacer()
                }
                if let game {
                    KeyValueRow(key: "Package", value: "out/packages/" + game.titleID, mono: true)
                    KeyValueRow(key: "Output", value: "GamePack.dylib + GameInfo.json", mono: true)
                }
            }
        }
    }

    private var modeCard: some View {
        Card(title: "Build mode", subtitle: settings.buildMode.explanation) {
            HStack(spacing: 10) {
                ForEach(BuildMode.allCases, id: \.rawValue) { mode in
                    Button {
                        settings.buildMode = mode
                        settings.save()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(mode.explanation)
                                .font(.system(size: 10))
                                .foregroundStyle(LauncherTheme.mutedText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(settings.buildMode == mode ? LauncherTheme.accent.opacity(0.16) : Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(settings.buildMode == mode ? LauncherTheme.accent.opacity(0.6) : LauncherTheme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var planCard: some View {
        let cli = "3ds2apple-pack --out " + settings.outDir + " build --queued"
            + (settings.buildMode == .dryRun ? "" : (settings.buildMode == .fake ? " --fake" : " --execute"))
            + " --json"
        return Card(title: "Command that will run") {
            Text(cli)
                .font(LauncherTheme.mono(11))
                .foregroundStyle(LauncherTheme.accentDeep)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            Text(settings.buildMode == .real
                 ? "The desktop CLI runs scripts/build-recomp-ios.sh and scripts/build-game-pack.sh on this Mac; both write only inside build/ and out/ (gitignored)."
                 : "Nothing leaves this Mac. Dry run prints the plan; fake preview writes labelled placeholder packs for layout tests.")
                .font(.system(size: 10.5))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shell + library

struct InstallScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    @Environment(\.launcherScreenshotMode) private var screenshotMode

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    private var readiness: AppleReadiness? {
        model.appleReadiness ?? model.envReport?.apple
    }

    private var installTask: TaskRecord? {
        model.tasks.first(where: { $0.kind == .installShell })
    }

    private var builtGames: [GameEntry] { model.builtGames }

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            if model.libraryNeedsRebuild {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LauncherTheme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library out of date")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Adding or removing a game means rebuilding and reinstalling the library IPA. Game data already pushed to Documents is kept.")
                            .font(.system(size: 11))
                            .foregroundStyle(LauncherTheme.mutedText)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 9).fill(LauncherTheme.warning.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(LauncherTheme.warning.opacity(0.3), lineWidth: 1))
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    readinessCard
                    gamesCard
                    teamCard
                    strategyCard
                    deviceCard
                    actions
                    commandPlanCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    installProgressCard
                    progressConsole
                    impactorNote
                    architectureNote
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var readinessCard: some View {
        Card(
            title: "Signing readiness",
            trailing: AnyView(Badge(
                text: readiness?.hasSigningAssets == true ? "READY" : "ACTION NEEDED",
                tone: readiness?.hasSigningAssets == true ? .success : .warning,
                symbol: readiness?.hasSigningAssets == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            ))
        ) {
            VStack(spacing: 8) {
                readinessRow(symbol: "hammer", title: "Xcode", value: readiness?.xcodeVersion ?? "not checked", ok: readiness?.devicectlAvailable ?? false)
                readinessRow(symbol: "iphone.and.arrow.forward", title: "devicectl", value: (readiness?.devicectlAvailable ?? false) ? "available" : "missing", ok: readiness?.devicectlAvailable ?? false)
                readinessRow(symbol: "signature", title: "Signing certificates", value: String(readiness?.signingIdentityCount ?? 0) + " found", ok: (readiness?.signingIdentityCount ?? 0) > 0)
                readinessRow(symbol: "doc.text", title: "Provisioning profiles", value: String(readiness?.provisioningProfileCount ?? 0) + " found", ok: (readiness?.provisioningProfileCount ?? 0) > 0)
                readinessRow(symbol: "doc.on.doc", title: "Shell runtime", value: "libzakuro_ios.a", ok: model.envReport?.tools.first(where: { $0.name.contains("Shell runtime") })?.state == .ok)
            }
            if let readiness, !readiness.hasSigningAssets {
                Text(readiness.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func readinessRow(symbol: String, title: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ok ? LauncherTheme.success : LauncherTheme.warning)
                .frame(width: 14)
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(LauncherTheme.mutedText)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 11.5))
            Spacer()
            Text(value)
                .font(LauncherTheme.mono(10.5))
                .foregroundStyle(LauncherTheme.mutedText)
        }
    }

    private var gamesCard: some View {
        Card(
            title: "Games to embed in the signed app",
            trailing: AnyView(Badge(text: String(builtGames.count) + " AOT READY", tone: builtGames.isEmpty ? .warning : .success))
        ) {
            if builtGames.isEmpty {
                HStack {
                    Text("No GamePack is built yet. Build one on the Build AOT screen.")
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                    Spacer()
                    Button("Build AOT") { model.screen = .build }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(builtGames) { game in
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(LauncherTheme.accentDeep)
                            Text(game.displayName)
                                .font(.system(size: 11.5, weight: .medium))
                            Text(game.titleID)
                                .font(LauncherTheme.mono(10))
                                .foregroundStyle(LauncherTheme.mutedText)
                            Spacer()
                            Text(humanBytes(game.packBytes))
                                .font(LauncherTheme.mono(10))
                                .foregroundStyle(LauncherTheme.mutedText)
                            Badge(
                                text: settings.libraryInstalledTitles.contains(game.titleID) ? "IN IPA" : "PENDING",
                                tone: settings.libraryInstalledTitles.contains(game.titleID) ? .success : .neutral
                            )
                        }
                    }
                }
                Text("These GamePacks are embedded as Frameworks/GamePack-<TITLEID>.dylib plus a bundle GameCatalog.json. The IPA contains no ROM/game data.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var teamCard: some View {
        Card(title: "Apple Developer Team ID") {
            LauncherTextField(label: "Team ID", placeholder: "ABCDE12345", text: $settings.teamID)
            Text("The launcher never asks for your Apple ID or password. Sign in once in Xcode -> Settings -> Accounts; Xcode manages the certificate and profile for your team.")
                .font(.system(size: 10.5))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var strategyCard: some View {
        Card(title: "Sign + install strategy") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(InstallStrategy.allCases, id: \.rawValue) { strategy in
                    Button {
                        settings.installStrategy = strategy
                        settings.save()
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: settings.installStrategy == strategy ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(settings.installStrategy == strategy ? LauncherTheme.accentDeep : LauncherTheme.mutedText)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(strategy.title)
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(strategy.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(LauncherTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var deviceCard: some View {
        Card(title: "Device") {
            if model.devices.isEmpty {
                HStack {
                    Text("No device detected.")
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                    Spacer()
                    Button("Detect devices") {
                        Task { await model.detectDevices() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(model.devices) { device in
                        ChipButton(
                            title: device.name + "  " + device.connectionLabel,
                            symbol: "iphone",
                            selected: model.selectedDeviceUDID == device.udid
                        ) {
                            model.selectedDeviceUDID = device.udid
                        }
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await model.detectDevices() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.refreshEnvironment() }
                } label: {
                    Label("Refresh readiness", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
                Button {
                    Task { await model.buildAndInstallLibrary() }
                } label: {
                    Label("Build and install library IPA", systemImage: "iphone.and.arrow.forward")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy || builtGames.isEmpty)
                Spacer()
            }
            Text(settings.buildMode == .dryRun
                 ? "Build mode Dry run: this prints the packaging plan only."
                 : "Signs with your Apple ID in Xcode, embeds the GamePacks, re-signs the nested dylibs and installs with devicectl.")
                .font(.system(size: 10.5))
                .foregroundStyle(LauncherTheme.mutedText)
        }
    }

    private var commandPlanCard: some View {
        Card(title: "What will run") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(model.libraryCommandPlan, id: \.self) { line in
                    Text(line)
                        .font(LauncherTheme.mono(10))
                        .foregroundStyle(LauncherTheme.accentDeep)
                        .lineLimit(2)
                }
            }
            if let ipa = model.adoptIPAPath {
                HStack {
                    Text("Adopting library .ipa: " + ipa)
                        .font(LauncherTheme.mono(10))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .lineLimit(1)
                    Spacer()
                    Button("Clear") { model.adoptIPAPath = nil }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            if !screenshotMode {
                HStack(spacing: 8) {
                    Button("Adopt library .ipa (Impactor path)...") {
                        if let path = chooseFile(extensions: ["ipa"], directories: false) {
                            model.adoptIPAPath = path
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
            }
        }
    }

    private var installProgressCard: some View {
        Group {
            if let task = installTask {
                TaskProgressCard(task: task)
            } else {
                Card(title: "Library status") {
                    if settings.libraryInstalledTitles.isEmpty {
                        EmptyStateView(
                            symbol: "shippingbox",
                            title: "No library installed yet",
                            message: "The library IPA is the ROM-free shell app with your GamePacks inside. Install it first; game data is pushed afterwards."
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            KeyValueRow(key: "Installed games", value: String(settings.libraryInstalledTitles.count))
                            KeyValueRow(key: "Library IPA", value: settings.libraryIPAPath, mono: true)
                            KeyValueRow(key: "ROM data", value: "Documents (persists across reinstalls)", mono: false)
                        }
                    }
                }
            }
        }
    }

    private var progressConsole: some View {
        Card(title: "Sign + install log") {
            VStack(alignment: .leading, spacing: 3) {
                if model.installProgressLines.isEmpty {
                    Text("No install log yet.")
                        .font(LauncherTheme.mono(10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
                ForEach(Array(model.installProgressLines.suffix(13).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(LauncherTheme.mono(10))
                        .foregroundStyle(line.lowercased().contains("error") ? LauncherTheme.danger : Color.primary.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.72)))
        }
    }

    private var impactorNote: some View {
        Card(title: "Official Impactor (optional)") {
            Text("Impactor is the Windows/macOS manual signing path: the launcher builds the same ROM-free library IPA and opens it in Impactor, where you sign in with your own Apple ID. The launcher never bundles Impactor or handles your password.")
                .font(.system(size: 10.5))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var architectureNote: some View {
        Card(title: "Why rebuild the library?") {
            Text("iOS will not load unsigned code copied into the app container, so every GamePack.dylib must be inside the signed IPA. Adding/removing a game rebuilds the catalog and reinstalls the app; the ROM data already pushed into Documents/Games is kept and can be re-pushed after a clean install.")
                .font(.system(size: 10.5))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFile(extensions: [String], directories: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = extensions
        if panel.runModal() == .OK, let url = panel.url {
            return url.path
        }
        return nil
    }
}


// MARK: - Device push

struct DeviceScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    private var game: GameEntry? { gameById(model, model.selectedGameID) }
    private var plan: PushPlan? {
        guard let id = game?.titleID else { return nil }
        return model.pushPlans[id]
    }

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    deviceCard
                    gameCard
                    planCard
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.pushError {
                        failureCard(error)
                    }
                    if let plan {
                        fileListCard(plan)
                    }
                    Card(title: "Push log") {
                        LogConsole(entries: model.logs.filter { $0.category == "push" || $0.category == "devpush" }, maximumLines: 12)
                            .frame(height: 190)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var deviceCard: some View {
        Card(title: "Target device", trailing: AnyView(ModeBadge(isMock: model.isMock))) {
            if model.devices.isEmpty {
                HStack {
                    Text("No device detected.")
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                    Spacer()
                    Button("Detect") {
                        Task { await model.detectDevices() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(model.devices) { device in
                        ChipButton(
                            title: device.name + "  " + device.connectionLabel,
                            symbol: "iphone",
                            selected: model.selectedDeviceUDID == device.udid
                        ) {
                            model.selectedDeviceUDID = device.udid
                        }
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await model.detectDevices() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            KeyValueRow(key: "Bundle ID", value: settings.deviceBundleID, mono: true)
            KeyValueRow(key: "Remote root", value: "Documents/Games/<TITLEID>/", mono: true)
        }
    }

    private var gameCard: some View {
        Card(title: "Game package") {
            if model.games.isEmpty {
                Text("Build a GamePack first.")
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
            } else {
                HStack(spacing: 8) {
                    ForEach(model.games) { item in
                        ChipButton(
                            title: item.displayName,
                            symbol: item.phase == .pushed ? "iphone" : "square",
                            selected: item.titleID == game?.titleID
                        ) {
                            model.selectedGameID = item.titleID
                            Task { _ = await model.preparePush(gameID: item.titleID, quiet: true) }
                        }
                    }
                    Spacer()
                }
                if let game {
                    KeyValueRow(key: "Title ID", value: game.titleID, mono: true)
                    KeyValueRow(key: "Status", value: game.phase.title)
                    KeyValueRow(
                        key: "In signed library",
                        value: settings.libraryInstalledTitles.contains(game.titleID)
                            ? "yes (GamePack in the app bundle)"
                            : "no - build & install the library IPA first"
                    )
                    KeyValueRow(key: "Game data source", value: game.romDataPath ?? "not staged", mono: true)
                }
            }
        }
    }

    private var planCard: some View {
        Card(title: "Documents push plan", subtitle: "GamePacks stay in the signed IPA; only game data is pushed") {
            if let plan {
                KeyValueRow(key: "Remote folder", value: plan.remoteDirectory, mono: true)
                KeyValueRow(key: "Files", value: String(plan.files.count) + " (" + humanBytes(plan.totalBytes) + ")")
                KeyValueRow(key: "Manifest", value: GameInfoWriter.launcherVersion.isEmpty ? "-" : "schemaVersion " + String(GameInfoWriter.shellSchemaVersion), mono: true)
                if plan.verified {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(LauncherTheme.success)
                        Text("Verified on device")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LauncherTheme.success)
                    }
                }
            } else {
                Text("Press Prepare to build the push plan from out/packages/<TITLEID>/.")
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                if let id = game?.titleID {
                    Task { _ = await model.preparePush(gameID: id) }
                }
            } label: {
                Label("Prepare", systemImage: "list.clipboard")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isBusy || game == nil)
            Button {
                if let id = game?.titleID {
                    Task { await model.pushGame(gameID: id) }
                }
            } label: {
                Label("Push to device", systemImage: "arrow.up.doc.on.clipboard")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isBusy || game == nil)
            Button {
                if let id = game?.titleID {
                    Task { await model.verifyPush(gameID: id) }
                }
            } label: {
                Label("Verify", systemImage: "checkmark.seal")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isBusy || game == nil)
            Spacer()
        }
    }

    private func fileListCard(_ plan: PushPlan) -> some View {
        Card(title: "Files (Documents only)", subtitle: plan.displayName) {
            VStack(spacing: 9) {
                ForEach(plan.files) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: symbol(for: file.name))
                                .font(.system(size: 11))
                                .foregroundStyle(file.state == .succeeded ? LauncherTheme.success : LauncherTheme.accentDeep)
                                .frame(width: 14)
                            Text(file.name)
                                .font(LauncherTheme.mono(11, weight: .medium))
                            Spacer()
                            Text(humanBytes(file.bytes))
                                .font(LauncherTheme.mono(10))
                                .foregroundStyle(LauncherTheme.mutedText)
                            Badge(
                                text: file.state.rawValue.uppercased(),
                                tone: file.state == .succeeded ? .success : (file.state == .failed ? .danger : .accent)
                            )
                        }
                        if file.state == .running || file.progress > 0 {
                            ProgressBar(value: file.progress, height: 4)
                        }
                    }
                }
            }
        }
    }

    private func symbol(for name: String) -> String {
        if name.hasSuffix(".dylib") { return "shippingbox.fill" }
        if name.hasSuffix(".cci") || name.hasSuffix(".3ds") { return "externaldrive.fill" }
        if name == "GameInfo.json" { return "doc.text.fill" }
        return "photo.fill"
    }

    private func failureCard(_ failure: LauncherFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(LauncherTheme.danger)
                Text(failure.message)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Badge(text: failure.code.uppercased(), tone: .danger)
            }
            Text(failure.hint)
                .font(.system(size: 11))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = failure.detail {
                Text(detail)
                    .font(LauncherTheme.mono(9.5))
                    .foregroundStyle(LauncherTheme.mutedText.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .launcherCard()
        .overlay(
            RoundedRectangle(cornerRadius: LauncherTheme.cardRadius, style: .continuous)
                .stroke(LauncherTheme.danger.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Activity

struct ActivityScreen: View {
    @ObservedObject var model: AppModel
    @State private var selectedTaskID: UUID?
    @State private var filter: LogFilter = .all

    private enum LogFilter: String, CaseIterable {
        case all = "All"
        case warnings = "Warnings"
        case errors = "Errors"
    }

    private var selectedTask: TaskRecord? {
        if let selectedTaskID, let task = model.tasks.first(where: { $0.id == selectedTaskID }) {
            return task
        }
        return model.tasks.first
    }

    private var filteredLogs: [LogEntry] {
        switch filter {
        case .all: return model.logs
        case .warnings: return model.logs.filter { $0.level == .warn }
        case .errors: return model.logs.filter { $0.level == .error }
        }
    }

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            HStack(alignment: .top, spacing: 16) {
                Card(title: "Tasks", trailing: AnyView(Badge(text: String(model.tasks.count) + " TOTAL", tone: .neutral))) {
                    if model.tasks.isEmpty {
                        EmptyStateView(symbol: "list.bullet.rectangle", title: "No tasks yet", message: "Import, build, install and push actions appear here with stage progress.")
                    } else {
                        VStack(spacing: 6) {
                            ForEach(model.tasks) { task in
                                Button {
                                    selectedTaskID = task.id
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: task.kind.symbolName)
                                            .font(.system(size: 11))
                                            .foregroundStyle(LauncherTheme.accentDeep)
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(task.title)
                                                .font(.system(size: 11.5, weight: .medium))
                                                .lineLimit(1)
                                            Text(task.startedAt.formatted(date: .omitted, time: .shortened) + "  -  " + String(format: "%.0fs", task.duration))
                                                .font(LauncherTheme.mono(9.5))
                                                .foregroundStyle(LauncherTheme.mutedText)
                                        }
                                        Spacer()
                                        Badge(
                                            text: task.state.title.uppercased(),
                                            tone: task.state == .succeeded ? .success : (task.state == .failed ? .danger : (task.state == .running ? .accent : .neutral))
                                        )
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(selectedTask?.id == task.id ? LauncherTheme.accent.opacity(0.12) : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    if let task = selectedTask {
                        TaskProgressCard(task: task)
                    }
                    Card(
                        title: "Logs",
                        trailing: AnyView(
                            HStack(spacing: 6) {
                                ForEach(LogFilter.allCases, id: \.rawValue) { item in
                                    ChipButton(title: item.rawValue, selected: filter == item) {
                                        filter = item
                                    }
                                }
                                Button("Export") { model.exportLog() }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        )
                    ) {
                        LogConsole(entries: filteredLogs, maximumLines: 16)
                            .frame(height: 230)
                        if let path = model.lastExportPath {
                            Text("Exported: " + path)
                                .font(LauncherTheme.mono(9.5))
                                .foregroundStyle(LauncherTheme.mutedText)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some View {
        ScreenContainer {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
            if let report = model.envReport {
                HStack(spacing: 12) {
                    MetricTile(title: "Checks passed", value: String(report.okCount) + "/" + String(report.tools.count), detail: report.hasBlockingIssue ? "blocking issue found" : "no blocking issue")
                    MetricTile(title: "Xcode", value: report.apple.xcodeVersion, detail: report.apple.devicectlAvailable ? "devicectl available" : "devicectl missing")
                    MetricTile(title: "Signing assets", value: String(report.apple.signingIdentityCount) + " cert / " + String(report.apple.provisioningProfileCount) + " profile", detail: report.apple.hasSigningAssets ? "ready for install" : "sign in to Xcode first")
                    MetricTile(title: "Device bridge", value: report.devpushCapabilities?.mock == true ? "mock" : (report.devpushCapabilities == nil ? "not built" : "ready"), detail: report.devpushCapabilities?.schema ?? "tools/devpush")
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        Card(title: "Toolchain") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(report.tools) { tool in
                                    ToolStatusRow(status: tool)
                                }
                            }
                        }
                        Card(title: "Paths") {
                            VStack(spacing: 5) {
                                KeyValueRow(key: "Checkout", value: report.repoRoot ?? "not found", mono: true)
                                KeyValueRow(key: "Output", value: report.outDir ?? "-", mono: true)
                                KeyValueRow(key: "Pack CLI", value: settings.packCLIPath.isEmpty ? (model.isMock ? "mock backend" : "auto-detected") : settings.packCLIPath, mono: true)
                                KeyValueRow(key: "devpush", value: settings.devpushPath.isEmpty ? (model.isMock ? "mock backend" : "auto-detected / not built") : settings.devpushPath, mono: true)
                                KeyValueRow(key: "Bundle ID", value: settings.deviceBundleID, mono: true)
                                KeyValueRow(key: "Library IPA", value: settings.libraryIPAPath.isEmpty ? "not built" : settings.libraryIPAPath, mono: true)
                                KeyValueRow(key: "Library games", value: String(settings.libraryInstalledTitles.count) + " embedded")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 14) {
                        Card(title: "Apple ID and signing") {
                            Text(report.apple.plainTextState)
                                .font(.system(size: 12, weight: .medium))
                            if !report.apple.hint.isEmpty {
                                Text(report.apple.hint)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(LauncherTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let capabilities = report.devpushCapabilities {
                            Card(title: "Device bridge capabilities") {
                                KeyValueRow(key: "Schema", value: capabilities.schema, mono: true)
                                KeyValueRow(key: "Version", value: capabilities.version, mono: true)
                                KeyValueRow(key: "Mock", value: capabilities.mock ? "yes" : "no")
                                Text(capabilities.commands.joined(separator: "  "))
                                    .font(LauncherTheme.mono(9.5))
                                    .foregroundStyle(LauncherTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !report.notes.isEmpty {
                            Card(title: "Notes") {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(report.notes, id: \.self) { note in
                                        Text("- " + note)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(LauncherTheme.mutedText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                Card(title: "Environment") {
                    EmptyStateView(symbol: "stethoscope", title: "Not probed yet", message: "Press Refresh to inspect the checkout, Xcode signing assets and device bridge.")
                    Button("Refresh environment") {
                        Task { await model.refreshEnvironment() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.refreshEnvironment() }
                } label: {
                    Label("Refresh environment", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
                Button {
                    model.exportLog()
                } label: {
                    Label("Export log", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Text("3ds2apple launcher 0.1.0 - Apache-2.0")
                    .font(LauncherTheme.mono(9.5))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
        }
    }
}
