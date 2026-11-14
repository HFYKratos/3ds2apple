//
//  InGameMenuView.swift
//  3ds2apple
//
//  The in-game overlay menu: it dims the (paused) game and offers resume, the
//  quick save state, fast toggles (on-screen controls, mute, fast-forward),
//  display settings, the save manager, diagnostics and exit.
//
//  Opening the menu pauses the frame loop and the audio engine in ROMSession,
//  so the game can neither advance nor receive input behind the overlay. The
//  Save State / Load State buttons take and restore instant states through
//  SaveStateSupport on the paused runtime; a successful load resumes the game
//  and drops the audio buffered before it.
//

import SwiftUI

struct InGameMenuView: View {
    let romName: String
    @ObservedObject var settings: AppSettings
    @ObservedObject var saveStates: SaveStateSupport
    let onResume: () -> Void
    let onReset: () -> Void
    let onDisplaySettings: () -> Void
    let onSaveManager: () -> Void
    let onDiagnostics: () -> Void
    let onExit: () -> Void
    /// Called after a state load succeeded: the game view closes the menu and
    /// resumes the restored session.
    let onLoadStateCompleted: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.74)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    header
                    resumeButton
                    saveStateCard
                    quickSettingsCard
                    gameActionsCard
                }
                .padding(20)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            saveStates.refresh()
            saveStates.clearMessages()
        }
        .accessibilityIdentifier("in-game-menu-overlay")
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Paused")
                .font(.title2.weight(.bold))
                .foregroundColor(.white)
            Text(romName)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.bottom, 2)
    }

    // MARK: - Resume

    private var resumeButton: some View {
        Button(action: onResume) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                Text("Resume game")
                Spacer(minLength: 0)
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor)
            )
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .disabled(saveStates.busy)
        .accessibilityIdentifier("menu-resume")
    }

    // MARK: - Quick save state

    private var saveStateCard: some View {
        card {
            Text("Save state")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white.opacity(0.55))
            HStack(spacing: 10) {
                stateButton(
                    "Save state",
                    systemImage: "camera.on.rectangle",
                    enabled: saveStates.canSave,
                    identifier: "menu-save-state"
                ) {
                    saveStates.save(slot: SaveStateSupport.quickSlot)
                }
                stateButton(
                    "Load state",
                    systemImage: "arrow.uturn.backward",
                    enabled: saveStates.canLoad,
                    identifier: "menu-load-state"
                ) {
                    saveStates.load(slot: SaveStateSupport.quickSlot) { result in
                        if case .success = result {
                            onLoadStateCompleted()
                        }
                    }
                }
            }
            saveStateStatus
        }
    }

    @ViewBuilder
    private var saveStateStatus: some View {
        if saveStates.busy {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                Text(saveStates.statusText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
            }
            .accessibilityIdentifier("menu-save-state-progress")
        } else if let error = saveStates.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("menu-save-state-error")
        } else if !saveStates.isRuntimeLoaded {
            Text("Save states are available while a game is running.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
        } else {
            Text(L10n.format("Slot %ld · %@", SaveStateSupport.quickSlot, saveStates.quickSlotInfo.detail))
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
                .accessibilityIdentifier("menu-save-state-detail")
        }
    }

    private func stateButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.footnote.weight(.medium))
            .foregroundColor(.white.opacity(enabled ? 0.95 : 0.45))
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(enabled ? 0.14 : 0.06))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Quick settings

    private var quickSettingsCard: some View {
        card {
            Toggle("On-screen controls", isOn: persistedBinding(settings, \.showTouchControls))
                .tint(.accentColor)
            Toggle("Mute audio", isOn: persistedBinding(settings, \.audioMuted))
                .tint(.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text("Fast-forward")
                    .font(.subheadline)
                Picker("Fast-forward", selection: persistedBinding(settings, \.playbackSpeed)) {
                    ForEach(PlaybackSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
            }
            Text("Fast-forward applies when the game resumes.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundColor(.white)
    }

    // MARK: - Game actions

    private var gameActionsCard: some View {
        card {
            actionRow(
                "Display settings",
                systemImage: "display",
                identifier: "menu-display-settings",
                action: onDisplaySettings
            )
            rowDivider
            actionRow(
                "Save Manager",
                systemImage: "externaldrive.fill",
                identifier: "menu-save-manager",
                action: onSaveManager
            )
            rowDivider
            actionRow(
                "Export logs",
                systemImage: "square.and.arrow.up",
                identifier: "menu-diagnostics",
                action: onDiagnostics
            )
            rowDivider
            actionRow(
                "Reset game",
                systemImage: "arrow.counterclockwise",
                identifier: "menu-reset",
                action: onReset
            )
            rowDivider
            actionRow(
                "Exit to home",
                systemImage: "rectangle.portrait.and.arrow.right",
                destructive: true,
                identifier: "menu-exit",
                action: onExit
            )
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 0.5)
    }

    private func actionRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        destructive: Bool = false,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 24, alignment: .center)
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.35))
            }
            .font(.body)
            .foregroundColor(destructive ? .red : .white)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saveStates.busy)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Card

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
    }
}
