//
//  SettingsView.swift
//  3ds2apple macOS launcher
//
//  The minimal Settings panel (gear icon, launcher/macos/README.md): language,
//  Apple ID / Xcode signing status, device status, logs and About. Build modes,
//  install strategies, tool paths, Team ID input, device UDID and bundle-ID
//  overrides are deliberately GONE: tools are auto-detected, the Team ID is read
//  from Xcode's local provisioning state and the installed bundle ID is read back
//  from the app that was actually installed.
//

import SwiftUI
import AppKit

struct SettingsSheetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    @Environment(\.launcherScreenshotMode) private var screenshotMode

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
        .frame(minWidth: 700, idealWidth: 780, minHeight: 560, idealHeight: 700)
        .background(LauncherTheme.background)
        .onAppear {
            if model.envReport == nil {
                Task { await model.refreshEnvironment() }
            }
        }
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
            advancedBuildCard
            logsCard
            aboutCard
        }
    }

    private var screenshotContent: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                languageCard
                signingCard
                advancedBuildCard
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 14) {
                deviceCard
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
                Text(strings.languageDetected(Locale.preferredLanguages.first ?? Locale.current.identifier) + "  " + strings.languageAppliesHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
        }
    }

    // MARK: Apple ID / signing status (read-only, auto-detected)

    private var signingCard: some View {
        Card(title: strings.signingTitle) {
            if let apple = model.appleReadiness ?? model.envReport?.apple {
                HStack(spacing: 8) {
                    Image(systemName: apple.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(apple.ready ? LauncherTheme.success : LauncherTheme.warning)
                    Text(apple.ready ? strings.signingStatusReady : strings.signingStatusMissing)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Badge(text: strings.statusLabel + ": " + (apple.ready ? strings.statusReady : strings.statusNeedsAttention), tone: apple.ready ? .success : .warning)
                }
                VStack(spacing: 6) {
                    KeyValueRow(key: "Xcode", value: apple.xcodeVersion, mono: true)
                    KeyValueRow(key: "Apple ID", value: strings.signingAssets(apple.signingIdentityCount, apple.provisioningProfileCount))
                    KeyValueRow(key: "Team ID", value: apple.teamID.isEmpty ? strings.signingTeamMissing : strings.signingTeam(apple.teamID), mono: true)
                    if !apple.ready {
                        Text(apple.hint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        openXcode()
                    } label: {
                        Label(strings.signingOpenXcode, systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
                Text(strings.signingExplanation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(strings.signingStatusMissing)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func openXcode() {
        let url = URL(fileURLWithPath: "/Applications/Xcode.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: Device

    private var deviceCard: some View {
        Card(title: strings.deviceTitle) {
            if let device = model.selectedDevice {
                HStack(spacing: 8) {
                    Image(systemName: "iphone")
                        .foregroundStyle(LauncherTheme.accentDeep)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text(device.model + " · iOS " + device.iosVersion + " · " + device.connectionLabel)
                            .font(LauncherTheme.mono(10.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                    }
                    Spacer()
                }
            } else {
                Text(strings.deviceNone)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                KeyValueRow(
                    key: strings.deviceBundleID,
                    value: settings.installedBundleID.isEmpty ? strings.deviceBundleIDNone : settings.installedBundleID,
                    mono: true
                )
            }
            HStack {
                Button {
                    Task { await model.detectDevices() }
                } label: {
                    Label(strings.deviceRefresh, systemImage: "cable.connector")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
                Spacer()
            }
        }
    }

    // MARK: Logs

    // MARK: Advanced build settings

    /// AOT codegen options for the next build. Defaults keep the shipped behaviour
    /// (O2 / LTO off / fast-math off); every row states its build/runtime effect.
    private var advancedBuildCard: some View {
        Card(title: strings.advancedBuildTitle) {
            VStack(alignment: .leading, spacing: 10) {
                Text(strings.advancedBuildBody)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(strings.advancedBuildOptLevel)
                        .font(.system(size: 11.5))
                    Picker("", selection: Binding(
                        get: { settings.advancedBuildOptions.optLevel },
                        set: { level in
                            settings.setAdvancedBuildOptions(AdvancedBuildOptions(
                                optLevel: level,
                                lto: settings.advancedAotLto,
                                fastMath: settings.advancedAotFastMath
                            ))
                        }
                    )) {
                        ForEach(AdvancedBuildOptions.optLevels, id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                Text(strings.advancedBuildOptLevelHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(strings.advancedBuildLto, isOn: Binding(
                    get: { settings.advancedAotLto },
                    set: { value in
                        settings.setAdvancedBuildOptions(AdvancedBuildOptions(
                            optLevel: settings.advancedAotOptLevel,
                            lto: value,
                            fastMath: settings.advancedAotFastMath
                        ))
                    }
                ))
                .toggleStyle(.switch)
                Text(strings.advancedBuildLtoHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(strings.advancedBuildFastMath, isOn: Binding(
                    get: { settings.advancedAotFastMath },
                    set: { value in
                        settings.setAdvancedBuildOptions(AdvancedBuildOptions(
                            optLevel: settings.advancedAotOptLevel,
                            lto: settings.advancedAotLto,
                            fastMath: value
                        ))
                    }
                ))
                .toggleStyle(.switch)
                Text(strings.advancedBuildFastMathHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(strings.advancedBuildSummary(settings.advancedBuildOptions.describe))
                    .font(.system(size: 10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                Button(strings.advancedBuildReset) {
                    settings.resetAdvancedBuildOptions()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
            }
        }
    }

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
                    KeyValueRow(
                        key: strings.dataRootLabel,
                        value: model.settings.dataRootPath + " (" + strings.dataRootKind(model.settings.dataRoot.kind) + ")",
                        mono: true
                    )
                    if let migration = model.settings.migrationSummary {
                        Text(migration)
                            .font(.system(size: 9.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    KeyValueRow(key: strings.hardwareLabel, value: strings.hardwareLine(model.hardware), mono: true)
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
