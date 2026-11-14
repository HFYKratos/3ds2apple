//
//  GameDetailView.swift
//  3ds2apple macOS launcher
//
//  The per-game modal dialog launched from a game card. It carries the actions
//  that used to live on the old Build / Shell+library / Device-push screens so the
//  two-section UI keeps the full backend flow: build AOT, build & install the
//  library IPA, prepare/push/verify game data, and read the per-game log.
//

import SwiftUI

struct GameDetailSheetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    let gameID: String
    @Environment(\.launcherScreenshotMode) private var screenshotMode
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, gameID: String) {
        self.model = model
        self.gameID = gameID
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    private var strings: LauncherStrings {
        LauncherStrings(language: settings.language.resolved())
    }

    private var game: GameEntry? {
        model.game(id: gameID)
    }

    private var plan: PushPlan? {
        model.pushPlans[gameID]
    }

    private var isInLibrary: Bool {
        settings.libraryInstalledTitles.contains(gameID)
    }

    private var relevantTask: TaskRecord? {
        guard model.isBusy, let task = model.activeTask else { return nil }
        if task.titleID == gameID { return task }
        if task.kind == .installShell { return task }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(LauncherTheme.border)
                .frame(height: 1)
            if screenshotMode {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    content
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Rectangle()
                .fill(LauncherTheme.border)
                .frame(height: 1)
            footer
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 560, idealHeight: 720)
        .background(LauncherTheme.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let game {
                GameArtwork(game: game, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(game?.displayName ?? gameID)
                    .font(LauncherTheme.rounded(18, weight: .bold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(gameID)
                        .font(LauncherTheme.mono(10.5, weight: .medium))
                        .foregroundStyle(LauncherTheme.accentDeep)
                    if let game {
                        GamePhaseBadge(phase: game.phase, strings: strings)
                    }
                    if isInLibrary {
                        Badge(text: strings.inLibraryBadge, tone: .success, symbol: "checkmark.seal.fill")
                    }
                }
            }
            Spacer()
            Button {
                model.detailGameID = nil
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(strings.close)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(LauncherTheme.background)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let task = relevantTask {
                TaskProgressCard(task: task, strings: strings)
            }
            packageCard
            pushCard
            if game?.phase == .pushed {
                howToPlayCard
            }
            logsCard
        }
    }

    private var packageCard: some View {
        Card(title: strings.gamePackageTitle) {
            if let game {
                VStack(spacing: 6) {
                    KeyValueRow(key: strings.fieldStatus, value: strings.phase(game.phase))
                    KeyValueRow(key: strings.fieldROM, value: game.romPath.isEmpty ? "-" : game.romPath, mono: true)
                    KeyValueRow(key: strings.fieldROMSize, value: humanBytes(game.romBytes))
                    KeyValueRow(key: strings.fieldSaveNamespace, value: game.saveNamespace, mono: true)
                    KeyValueRow(key: strings.fieldBuildName, value: game.buildSlug, mono: true)
                    KeyValueRow(key: strings.fieldPackPath, value: game.packPath ?? strings.toolsNotBuilt, mono: true)
                    KeyValueRow(key: strings.fieldPackSize, value: humanBytes(game.packBytes))
                    KeyValueRow(key: strings.fieldPackSha, value: shortHash(game.packSha256), mono: true)
                    KeyValueRow(
                        key: strings.fieldInLibrary,
                        value: isInLibrary ? strings.fieldPackInLibraryYes : strings.fieldPackInLibraryNo
                    )
                    KeyValueRow(
                        key: strings.fieldGameDataSource,
                        value: game.romDataPath ?? strings.toolsNotStaged,
                        mono: true
                    )
                    if let pushedAt = game.pushedAt {
                        KeyValueRow(key: strings.fieldPushedAt, value: GameInfoWriter.iso8601(pushedAt))
                    }
                }
            } else {
                Text(strings.gameDetailTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
        }
    }

    private var pushCard: some View {
        Card(title: strings.pushPlanTitle, subtitle: strings.pushPlanSubtitle) {
            if let plan {
                VStack(spacing: 6) {
                    KeyValueRow(key: strings.deviceRemoteRoot, value: plan.remoteDirectory, mono: true)
                    KeyValueRow(key: strings.pushPlanTitle, value: strings.pushPlanFiles(plan.files.count, humanBytes(plan.totalBytes)))
                }
                VStack(alignment: .leading, spacing: 9) {
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
                                Badge(text: fileStateLabel(file.state), tone: file.state == .succeeded ? .success : (file.state == .failed ? .danger : .accent))
                            }
                            if file.state == .running || file.progress > 0 {
                                ProgressBar(value: file.progress, height: 4)
                            }
                        }
                    }
                }
                if plan.verified {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(LauncherTheme.success)
                        Text(strings.pushVerified)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LauncherTheme.success)
                    }
                }
            } else {
                Text(strings.pushPlanNoPlan)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
            HStack(spacing: 10) {
                Button(strings.pushPrepare) {
                    Task { _ = await model.preparePush(gameID: gameID) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
                Button(strings.pushToDevice) {
                    Task {
                        _ = await model.preparePush(gameID: gameID)
                        await model.pushGame(gameID: gameID)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)
                Button(strings.pushVerify) {
                    Task { await model.verifyPush(gameID: gameID) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
                Spacer()
            }
        }
    }

    private var howToPlayCard: some View {
        Card(title: strings.howToPlayTitle) {
            VStack(alignment: .leading, spacing: 8) {
                howToPlayRow(1, strings.howToPlayStep1)
                howToPlayRow(2, strings.howToPlayStep2)
                howToPlayRow(3, strings.howToPlayStep3)
                howToPlayRow(4, strings.howToPlayStep4)
            }
        }
    }

    private func howToPlayRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(number) + ".")
                .font(LauncherTheme.mono(10, weight: .bold))
                .foregroundStyle(LauncherTheme.accentDeep)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var logsCard: some View {
        Card(title: strings.logsTitle) {
            LogConsole(
                entries: model.logs.filter { ["build", "library", "push", "devpush"].contains($0.category) },
                maximumLines: 8,
                showsHeader: false,
                strings: strings
            )
            Text(strings.logsRawNote)
                .font(.system(size: 10))
                .foregroundStyle(LauncherTheme.mutedText)
        }
    }

    // MARK: Footer actions

    private var footer: some View {
        HStack(spacing: 10) {
            if let game {
                switch game.phase {
                case .queued, .failed:
                    Button(strings.primaryBuild) {
                        Task { await model.build(gameID: gameID) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isBusy)
                    Button(strings.buildInstallLibrary) {
                        Task { await model.buildAndInstallLibrary() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isBusy || model.builtGames.isEmpty)
                case .building:
                    Button(strings.primaryBuilding) {}
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(true)
                case .built:
                    if isInLibrary {
                        Button(strings.primaryPush) {
                            Task {
                                _ = await model.preparePush(gameID: gameID)
                                await model.pushGame(gameID: gameID)
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.isBusy)
                    } else {
                        Button(strings.primaryInstall) {
                            Task { await model.buildAndInstallLibrary() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.isBusy || model.builtGames.isEmpty)
                    }
                    Button(strings.secondaryBuildAgain) {
                        Task { await model.build(gameID: gameID) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isBusy)
                case .pushed:
                    Button(strings.secondaryPushAgain) {
                        Task {
                            _ = await model.preparePush(gameID: gameID)
                            await model.pushGame(gameID: gameID)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isBusy)
                    Button(strings.secondaryVerify) {
                        Task { await model.verifyPush(gameID: gameID) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isBusy)
                }
            }
            Spacer()
            Button(strings.done) {
                model.detailGameID = nil
                dismiss()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(LauncherTheme.cardBackground)
    }

    // MARK: helpers

    private func symbol(for name: String) -> String {
        if name.hasSuffix(".dylib") { return "shippingbox.fill" }
        if name.hasSuffix(".cci") || name.hasSuffix(".3ds") { return "externaldrive.fill" }
        if name == "GameInfo.json" { return "doc.text.fill" }
        return "photo.fill"
    }

    private func fileStateLabel(_ state: StageState) -> String {
        switch state {
        case .succeeded: return "OK"
        case .failed: return strings.phaseFailed.uppercased()
        case .running: return "..."
        case .pending: return strings.phaseQueued.uppercased()
        case .skipped: return "-"
        }
    }
}
