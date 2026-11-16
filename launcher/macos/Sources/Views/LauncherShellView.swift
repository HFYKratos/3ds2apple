//
//  LauncherShellView.swift
//  3ds2apple macOS launcher
//
//  The whole window for the two-section launcher UI (docs/launcher-flow-v2.md):
//
//      Library | Deploy (导入手机)          gear -> minimal Settings panel
//
//  Import is a sheet of the Library; Settings is a modal panel. Pure SwiftUI (no
//  NavigationSplitView) so the same view tree is drawn offscreen by
//  SnapshotRenderer on the headless build VM.
//

import SwiftUI

struct LauncherShellView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings

    init(model: AppModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: model.settings)
    }

    private var strings: LauncherStrings {
        LauncherStrings(language: settings.language.resolved())
    }

    var body: some View {
        HStack(spacing: 0) {
            LauncherSidebar(model: model, settings: settings, strings: strings)
            Rectangle()
                .fill(LauncherTheme.border)
                .frame(width: 1)
            VStack(spacing: 0) {
                LauncherTopBar(model: model, strings: strings)
                Rectangle()
                    .fill(LauncherTheme.border)
                    .frame(height: 1)
                content
                if model.isBusy {
                    LauncherBusyBar(model: model, strings: strings)
                }
            }
            .background(LauncherTheme.background)
        }
        .background(LauncherTheme.background)
        .sheet(isPresented: $model.settingsPresented) {
            SettingsSheetView(model: model)
        }
        .sheet(isPresented: $model.importPresented) {
            ImportSheetView(model: model)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.screen {
            case .library:
                LibraryScreen(model: model, settings: settings, strings: strings)
            case .deploy:
                DeployScreen(model: model, settings: settings, strings: strings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Sidebar

private struct LauncherSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: LauncherSettings
    let strings: LauncherStrings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppIconBadge(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("3ds2apple")
                        .font(LauncherTheme.rounded(16, weight: .bold))
                    Text(strings.appTagline)
                        .font(.system(size: 10))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 18)

            VStack(spacing: 3) {
                ForEach(LauncherScreen.allCases) { screen in
                    Button {
                        model.screen = screen
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: screen.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 16)
                            Text(title(for: screen))
                                .font(.system(size: 12.5, weight: model.screen == screen ? .semibold : .regular))
                            Spacer(minLength: 0)
                            if screen == .library && !model.games.isEmpty {
                                Text(String(model.games.count))
                                    .font(LauncherTheme.mono(10, weight: .semibold))
                                    .foregroundStyle(LauncherTheme.mutedText)
                            }
                            if screen == .deploy && !model.selectedForDeploy.isEmpty {
                                Text(String(model.selectedForDeploy.count))
                                    .font(LauncherTheme.mono(10, weight: .semibold))
                                    .foregroundStyle(LauncherTheme.accentDeep)
                            }
                        }
                        .foregroundStyle(model.screen == screen ? Color.primary : Color.primary.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(model.screen == screen ? LauncherTheme.accent.opacity(0.16) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                Rectangle()
                    .fill(LauncherTheme.border)
                    .frame(height: 1)
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LauncherTheme.mutedText)
                    Text(deviceLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .lineLimit(1)
                }
                Button {
                    model.settingsPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: .semibold))
                        Text(strings.settings)
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.8))
                HStack {
                    ModeBadge(isMock: model.isMock, strings: strings)
                    Spacer()
                }
                Text(strings.versionLabel + " " + LauncherInfo.shortVersion)
                    .font(LauncherTheme.mono(9.5))
                    .foregroundStyle(LauncherTheme.mutedText.opacity(0.8))
            }
            .padding(14)
        }
        .frame(width: LauncherTheme.sidebarWidth)
        .background(LauncherTheme.sidebarBackground)
    }

    private func title(for screen: LauncherScreen) -> String {
        switch screen {
        case .library: return strings.navLibrary
        case .deploy: return strings.navDeploy
        }
    }

    private var deviceLine: String {
        if let device = model.selectedDevice {
            return device.name
        }
        return strings.deployDeviceNone
    }
}

// MARK: - Top bar

private struct LauncherTopBar: View {
    @ObservedObject var model: AppModel
    let strings: LauncherStrings

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LauncherTheme.rounded(19, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
            Spacer()
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            switch model.screen {
            case .library:
                Button {
                    model.importPresented = true
                } label: {
                    Label(strings.importGame, systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)
            case .deploy:
                if !model.games.isEmpty {
                    Button {
                        Task { await model.deploySelected() }
                    } label: {
                        Label(strings.deployButton(model.deployCandidates.isEmpty ? 0 : model.deployCandidates.count), systemImage: "iphone.and.arrow.forward")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isBusy || model.deployCandidates.isEmpty)
                }
            }
            Button {
                Task {
                    await model.refreshEnvironment()
                    await model.refreshLibrary()
                    await model.detectDevices()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(strings.refresh)
            .disabled(model.isBusy)
            Button {
                model.settingsPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(SecondaryButtonStyle())
            .help(strings.settings)
            ModeBadge(isMock: model.isMock, strings: strings)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(LauncherTheme.background)
    }

    private var title: String {
        switch model.screen {
        case .library: return strings.navLibrary
        case .deploy: return strings.navDeploy
        }
    }

    private var subtitle: String {
        switch model.screen {
        case .library: return strings.librarySubtitle
        case .deploy: return strings.deploySubtitle
        }
    }
}

// MARK: - Busy bar

private struct LauncherBusyBar: View {
    @ObservedObject var model: AppModel
    let strings: LauncherStrings

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LauncherTheme.border)
                .frame(height: 1)
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                if let report = model.deployReport, report.state == .running {
                    Text(strings.deployRunningFor(report.selectedTitles.count))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(report.steps.first(where: { $0.state == .running })?.detail ?? "")
                        .font(LauncherTheme.mono(10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .lineLimit(1)
                    Spacer()
                    ProgressBar(value: report.progress)
                        .frame(width: 160)
                } else if let task = model.activeTask {
                    Text(task.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(task.stages.first(where: { $0.state == .running })?.detail ?? "")
                        .font(LauncherTheme.mono(10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .lineLimit(1)
                    Spacer()
                    ProgressBar(value: task.progress)
                        .frame(width: 160)
                } else {
                    Text(strings.busyWorking)
                        .font(.system(size: 11))
                    Spacer()
                }
                Button(strings.cancel) {
                    model.cancelActiveTask()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(LauncherTheme.cardBackground)
        }
    }
}
