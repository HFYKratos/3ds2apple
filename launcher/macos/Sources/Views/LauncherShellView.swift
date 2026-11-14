//
//  LauncherShellView.swift
//  3ds2apple macOS launcher
//
//  The whole window: sidebar navigation, a title bar with the run-mode badge and
//  the active screen. Pure SwiftUI, no NavigationSplitView, so ImageRenderer can
//  draw the exact same tree offscreen on the headless build VM.
//

import SwiftUI

struct LauncherShellView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            LauncherSidebar(model: model)
            Rectangle()
                .fill(LauncherTheme.border)
                .frame(width: 1)
            VStack(spacing: 0) {
                LauncherTopBar(model: model)
                Rectangle()
                    .fill(LauncherTheme.border)
                    .frame(height: 1)
                content
                if model.isBusy {
                    busyBar
                }
            }
            .background(LauncherTheme.background)
        }
        .background(LauncherTheme.background)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch model.screen {
            case .importROM:
                ImportScreen(model: model)
            case .library:
                LibraryScreen(model: model)
            case .build:
                BuildScreen(model: model)
            case .install:
                InstallScreen(model: model)
            case .device:
                DeviceScreen(model: model)
            case .activity:
                ActivityScreen(model: model)
            case .diagnostics:
                DiagnosticsScreen(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var busyBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LauncherTheme.border)
                .frame(height: 1)
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                if let task = model.activeTask {
                    Text(task.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(task.stages.first(where: { $0.state == .running })?.detail ?? "")
                        .font(LauncherTheme.mono(10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .lineLimit(1)
                    Spacer()
                    ProgressBar(value: task.progress)
                        .frame(width: 160)
                    Button("Cancel") {
                        model.cancelActiveTask()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Text("Working...")
                        .font(.system(size: 11))
                    Spacer()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(LauncherTheme.cardBackground)
        }
    }
}

// MARK: - Sidebar

private struct LauncherSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LauncherTheme.accentDeep)
                        .frame(width: 30, height: 30)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("3ds2apple")
                        .font(LauncherTheme.rounded(16, weight: .bold))
                    Text("macOS launcher")
                        .font(.system(size: 10))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            VStack(spacing: 2) {
                ForEach(LauncherScreen.allCases) { screen in
                    Button {
                        model.screen = screen
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: screen.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 16)
                            Text(screen.title)
                                .font(.system(size: 12, weight: model.screen == screen ? .semibold : .regular))
                            Spacer(minLength: 0)
                            if screen == .library && !model.games.isEmpty {
                                Text(String(model.games.count))
                                    .font(LauncherTheme.mono(10, weight: .semibold))
                                    .foregroundStyle(LauncherTheme.mutedText)
                            }
                            if screen == .activity && model.isBusy {
                                Circle()
                                    .fill(LauncherTheme.accent)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .foregroundStyle(model.screen == screen ? Color.primary : Color.primary.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
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
                HStack {
                    ModeBadge(isMock: model.isMock)
                    Spacer()
                }
                Text(model.isMock
                     ? "No ROM, device or Apple ID is touched."
                     : "Uses your own ROM, Apple ID and device.")
                    .font(.system(size: 10))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("v0.1.0 MVP")
                    .font(LauncherTheme.mono(9.5))
                    .foregroundStyle(LauncherTheme.mutedText.opacity(0.8))
            }
            .padding(14)
        }
        .frame(width: LauncherTheme.sidebarWidth)
        .background(LauncherTheme.sidebarBackground)
    }
}

// MARK: - Top bar

private struct LauncherTopBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.screen.title)
                    .font(LauncherTheme.rounded(19, weight: .bold))
                Text(model.screen.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
            Spacer()
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task {
                    await model.refreshEnvironment()
                    await model.detectDevices()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isBusy)
            ModeBadge(isMock: model.isMock)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(LauncherTheme.background)
    }
}
