//
//  SettingsView.swift
//  3ds2apple macOS launcher
//
//  The Settings modal panel (gear icon, not a top-level tab). It keeps every
//  advanced control from the old MVP screens: Apple ID/Team ID and signing
//  explanation, device state and bundle ID, build mode, sign/install strategy,
//  tool paths, logs and diagnostics, language override and About.
//

import SwiftUI

struct SettingsSheetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    @Environment(\.launcherScreenshotMode) private var screenshotMode
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    private var strings: LauncherStrings {
        LauncherStrings(language: settings.language.resolved())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(LauncherTheme.border)
                .frame(height: 1)
            if screenshotMode {
                // Offscreen evidence uses two columns so every Settings section
                // fits a single PNG (the live sheet scrolls a single column).
                screenshotContent
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    verticalContent
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 620, idealHeight: 780)
        .background(LauncherTheme.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: "gearshape", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.settings)
                    .font(LauncherTheme.rounded(19, weight: .bold))
                Text(strings.settingsSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
            Spacer()
            ModeBadge(isMock: model.isMock, strings: strings)
            Button(strings.done) {
                model.settingsPresented = false
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(LauncherTheme.background)
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            languageCard
            signingCard
            deviceCard
            buildModeCard
            installStrategyCard
            toolsCard
            diagnosticsCard
            logsCard
            aboutCard
        }
    }

    private var screenshotContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                languageCard
                signingCard
                deviceCard
                buildModeCard
                toolsCard
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 14) {
                installStrategyCard
                diagnosticsCard
                logsCard
                aboutCard
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Language

    private var languageCard: some View {
        Card(title: strings.languageTitle) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(LauncherLanguage.allCases) { language in
                    RadioOptionRow(
                        title: strings.languageTitle(language),
                        detail: strings.languageDetail(language),
                        selected: settings.language == language
                    ) {
                        settings.language = language
                        settings.save()
                    }
                }
                Text(strings.languageHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(strings.languageDetected(systemLanguageLabel) + "  " + strings.languageAppliesHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
        }
    }

    private var systemLanguageLabel: String {
        Locale.preferredLanguages.first ?? Locale.current.identifier
    }

    // MARK: Apple ID / signing

    private var signingCard: some View {
        Card(title: strings.signingTitle) {
            LauncherTextField(
                label: strings.signingTeamID,
                placeholder: strings.signingTeamIDPlaceholder,
                text: Binding(
                    get: { settings.teamID },
                    set: { settings.teamID = $0; settings.save() }
                )
            )
            Text(strings.signingExplanation)
                .font(.system(size: 10.5))
                .foregroundStyle(LauncherTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Device

    private var deviceCard: some View {
        Card(title: strings.deviceTitle) {
            if model.devices.isEmpty {
                HStack(spacing: 10) {
                    Text(strings.deviceNone)
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(strings.deviceRefresh) {
                        Task { await model.detectDevices() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isBusy)
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
                    Spacer(minLength: 0)
                    Button(strings.deviceRefresh) {
                        Task { await model.detectDevices() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isBusy)
                }
            }
            VStack(spacing: 6) {
                KeyValueRow(key: strings.deviceBundleID, value: settings.deviceBundleID, mono: true)
                KeyValueRow(key: strings.deviceRemoteRoot, value: strings.deviceRemoteRootValue, mono: true)
            }
        }
    }

    // MARK: Build mode

    private var buildModeCard: some View {
        Card(title: strings.buildModeTitle) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(BuildMode.allCases, id: \.rawValue) { mode in
                    RadioOptionRow(
                        title: strings.buildModeTitle(mode),
                        detail: strings.buildModeDetail(mode),
                        selected: settings.buildMode == mode
                    ) {
                        settings.buildMode = mode
                        settings.save()
                    }
                }
            }
        }
    }

    private var installStrategyCard: some View {
        Card(title: strings.installStrategyTitle) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(InstallStrategy.allCases, id: \.rawValue) { strategy in
                    RadioOptionRow(
                        title: strings.installStrategyTitle(strategy),
                        detail: strings.installStrategyDetail(strategy),
                        selected: settings.installStrategy == strategy
                    ) {
                        settings.installStrategy = strategy
                        settings.save()
                    }
                }
            }
        }
    }

    // MARK: Tools

    private var toolsCard: some View {
        Card(title: strings.toolsTitle) {
            VStack(alignment: .leading, spacing: 10) {
                LauncherTextField(
                    label: strings.toolsRepoRoot,
                    placeholder: "/Users/you/3ds2apple",
                    text: Binding(get: { settings.repoRoot }, set: { settings.repoRoot = $0; settings.save() })
                )
                LauncherTextField(
                    label: strings.toolsOutDir,
                    placeholder: "out",
                    text: Binding(get: { settings.outDir }, set: { settings.outDir = $0; settings.save() })
                )
                LauncherTextField(
                    label: strings.toolsPackCLI,
                    placeholder: strings.toolsAutoDetected,
                    text: Binding(get: { settings.packCLIPath }, set: { settings.packCLIPath = $0; settings.save() })
                )
                LauncherTextField(
                    label: strings.toolsDevpush,
                    placeholder: strings.toolsAutoDetected,
                    text: Binding(get: { settings.devpushPath }, set: { settings.devpushPath = $0; settings.save() })
                )
                LauncherTextField(
                    label: strings.toolsDeviceCLI,
                    placeholder: strings.toolsNotSet,
                    text: Binding(get: { settings.deviceCLIPath }, set: { settings.deviceCLIPath = $0; settings.save() })
                )
                VStack(spacing: 6) {
                    KeyValueRow(key: strings.toolsBundleID, value: settings.deviceBundleID, mono: true)
                    KeyValueRow(key: strings.toolsLibraryIPA, value: settings.libraryIPAPath.isEmpty ? strings.toolsNotBuilt : settings.libraryIPAPath, mono: true)
                    KeyValueRow(key: strings.toolsInstalledTitles, value: strings.installedGames(settings.libraryInstalledTitles.count))
                }
            }
        }
    }

    // MARK: Diagnostics

    private var diagnosticsCard: some View {
        Card(title: strings.diagnosticsTitle) {
            if let report = model.envReport {
                if screenshotMode {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        diagnosticTiles(report)
                    }
                } else {
                    HStack(spacing: 12) {
                        diagnosticTiles(report)
                    }
                    Text(strings.diagnosticsToolchainTitle)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LauncherTheme.mutedText)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(report.tools) { tool in
                            ToolStatusRow(status: tool)
                        }
                    }
                    if !report.notes.isEmpty {
                        Text(strings.diagnosticsNotesTitle)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(LauncherTheme.mutedText)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(report.notes, id: \.self) { note in
                                Text("- " + note)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(LauncherTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else {
                HStack {
                    Text(strings.diagnosticsTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.mutedText)
                    Spacer()
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { await model.refreshEnvironment() }
                } label: {
                    Label(strings.diagnosticsRefresh, systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func diagnosticTiles(_ report: EnvironmentReport) -> some View {
        MetricTile(
            title: strings.diagnosticsTitle,
            value: strings.diagnosticsChecks(report.okCount, report.tools.count),
            detail: report.hasBlockingIssue ? strings.lastError : ""
        )
        MetricTile(
            title: strings.diagnosticsXcode,
            value: report.apple.xcodeVersion,
            detail: report.apple.devicectlAvailable ? "devicectl" : "devicectl missing"
        )
        MetricTile(
            title: strings.installStrategyTitle(.xcodebuild),
            value: strings.signingAssets(report.apple.signingIdentityCount, report.apple.provisioningProfileCount),
            detail: report.apple.hasSigningAssets ? strings.pushVerified : strings.libraryNotInstalled
        )
        MetricTile(
            title: strings.diagnosticsDevpush,
            value: report.devpushCapabilities?.mock == true ? strings.modeMock : (report.devpushCapabilities == nil ? strings.toolsNotBuilt : "devpush/1"),
            detail: report.devpushCapabilities?.schema ?? ""
        )
    }

    // MARK: Logs

    private var logsCard: some View {
        Card(title: strings.logsTitle) {
            LogConsole(entries: model.logs, maximumLines: 10, showsHeader: false, strings: strings)
            Text(strings.logsRawNote)
                .font(.system(size: 10))
                .foregroundStyle(LauncherTheme.mutedText)
            HStack(spacing: 10) {
                Button(strings.logsExport) { model.exportLog() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(strings.logsClear) { model.clearLogs() }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                if let path = model.lastExportPath {
                    Text(strings.logsExported(path))
                        .font(LauncherTheme.mono(9.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: About

    private var aboutCard: some View {
        Card(title: strings.aboutTitle) {
            HStack(alignment: .top, spacing: 14) {
                AppIconBadge(size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text("3ds2apple")
                        .font(LauncherTheme.rounded(15, weight: .bold))
                    Text(strings.aboutVersion(LauncherInfo.version, LauncherInfo.build))
                        .font(LauncherTheme.mono(10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                    Text(strings.aboutBody(LauncherInfo.version))
                        .font(.system(size: 10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(strings.aboutLicense)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                    Text(strings.aboutIconCaption)
                        .font(.system(size: 10))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
