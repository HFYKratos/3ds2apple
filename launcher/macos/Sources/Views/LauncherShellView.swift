//
//  LauncherShellView.swift
//  3ds2apple macOS launcher
//
//  The whole window for the two-section launcher UI (launcher/macos/README.md):
//
//      [3ds2apple]        游戏库  部署 (centered)        (ready) (gear)
//
//  Import stays a single button on the Library page; Settings is a modal panel.
//  The readiness light is filled by the automatic startup probe and stays visible
//  on every screen (green 已完成准备 / red 未完成准备, details in tooltip + log).
//  Pure SwiftUI (no NavigationSplitView) so the same view tree is drawn offscreen
//  by SnapshotRenderer on the headless build VM.
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
        .sheet(isPresented: $model.settingsPresented) {
            SettingsSheetView(model: model)
        }
        .task {
            // Automatic on every live launch; the mock/screenshot model seeds a
            // deterministic readiness result and must not probe the real machine.
            if model.kind == .live {
                await model.runStartupReadinessCheck()
            }
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

// MARK: - Top bar

/// App identity on the left, the two primary sections centered in the window,
/// readiness + mode + gear on the right. No sidebar: the v2 navigation is exactly
/// two tabs plus a gear, mirroring the Windows launcher polish.
private struct LauncherTopBar: View {
    @ObservedObject var model: AppModel
    let strings: LauncherStrings

    var body: some View {
        ZStack {
            HStack(spacing: 26) {
                ForEach(LauncherScreen.allCases) { screen in
                    navButton(screen)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    AppIconBadge(size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("3ds2apple")
                            .font(LauncherTheme.rounded(14, weight: .bold))
                        Text(strings.appTagline)
                            .font(.system(size: 9.5))
                            .foregroundStyle(LauncherTheme.mutedText)
                    }
                }
                Spacer(minLength: 0)
                ReadinessLight(status: model.readiness, strings: strings)
                ModeBadge(isMock: model.isMock, strings: strings)
                Button {
                    model.settingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help(strings.settings)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(LauncherTheme.background)
    }

    private func navButton(_ screen: LauncherScreen) -> some View {
        let selected = model.screen == screen
        return Button {
            model.screen = screen
        } label: {
            VStack(spacing: 5) {
                Text(title(for: screen))
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.62))
                Capsule()
                    .fill(selected ? LauncherTheme.accentDeep : Color.clear)
                    .frame(width: 30, height: 2.5)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title(for: screen))
    }

    private func title(for screen: LauncherScreen) -> String {
        switch screen {
        case .library: return strings.navLibrary
        case .deploy: return strings.navDeploy
        }
    }
}

// MARK: - Readiness light

/// Persistent readiness indicator filled by the automatic startup check. The
/// detail string is raw engineering output (tool names, Apple ID state), shown on
/// hover and written to the log; the visible label stays localized and short.
struct ReadinessLight: View {
    let status: ReadinessStatus
    let strings: LauncherStrings

    private var color: Color {
        switch status {
        case .checking: return LauncherTheme.warning
        case .ready: return LauncherTheme.success
        case .notReady: return LauncherTheme.danger
        }
    }

    private var label: String {
        switch status {
        case .checking: return strings.readinessChecking
        case .ready: return strings.readinessReady
        case .notReady: return strings.readinessNotReady
        }
    }

    private var help: String {
        let base: String
        switch status {
        case .checking: base = strings.readinessHelpChecking
        case .ready: base = strings.readinessHelpReady
        case .notReady: base = strings.readinessHelpNotReady
        }
        let detail = status.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? base : base + "\n\n" + detail
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.32), lineWidth: 1))
        .help(help)
        .accessibilityLabel(label)
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
