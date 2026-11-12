//
//  InGameMenuView.swift
//  3ds2apple
//
//  The in-game overlay menu: it dims the (paused) game and offers resume, save
//  states, reset, display settings, the save manager, diagnostics and exit.
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
                    actionButton(
                        "Resume game",
                        systemImage: "play.fill",
                        prominent: true,
                        enabled: !saveStates.busy,
                        action: onResume
                    )
                    .accessibilityIdentifier("menu-resume")

                    quickToggles

                    saveStateControls

                    actionButton(
                        "Reset game",
                        systemImage: "arrow.counterclockwise",
                        enabled: !saveStates.busy,
                        action: onReset
                    )
                    .accessibilityIdentifier("menu-reset")

                    actionButton(
                        "Display settings",
                        systemImage: "display",
                        enabled: !saveStates.busy,
                        action: onDisplaySettings
                    )
                    .accessibilityIdentifier("menu-display-settings")

                    actionButton(
                        "Save Manager",
                        systemImage: "externaldrive.fill",
                        enabled: !saveStates.busy,
                        action: onSaveManager
                    )
                    .accessibilityIdentifier("menu-save-manager")

                    actionButton(
                        "Export diagnostics",
                        systemImage: "square.and.arrow.up",
                        enabled: !saveStates.busy,
                        action: onDiagnostics
                    )
                    .accessibilityIdentifier("menu-diagnostics")

                    actionButton(
                        "Exit to home",
                        systemImage: "xmark.circle",
                        destructive: true,
                        enabled: !saveStates.busy,
                        action: onExit
                    )
                    .accessibilityIdentifier("menu-exit")
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
        .padding(.bottom, 4)
    }

    /// Behaviours that are useful to change without leaving the game.
    private var quickToggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                "On-screen controls",
                isOn: persistedBinding(settings, \.showTouchControls)
            )
            .tint(.accentColor)
            Toggle(
                "Mute audio",
                isOn: persistedBinding(settings, \.audioMuted)
            )
            .tint(.accentColor)
        }
        .font(.subheadline)
        .foregroundColor(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    /// Instant save states: the quick buttons act on slot 1; the Save Manager
    /// page lists and manages all slots.
    private var saveStateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
            }
            .padding(.horizontal, 4)
            .accessibilityIdentifier("menu-save-state-progress")
        } else if let error = saveStates.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("menu-save-state-error")
        } else if !saveStates.isRuntimeLoaded {
            Text("Save states are available while a game is running.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 4)
        } else {
            Text("Slot \(SaveStateSupport.quickSlot) · \(saveStates.quickSlotInfo.detail)")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 4)
                .accessibilityIdentifier("menu-save-state-detail")
        }
    }

    private func stateButton(
        _ title: String,
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
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(enabled ? 0.14 : 0.06))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        prominent: Bool = false,
        destructive: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(prominent ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.12))
            )
            .foregroundColor(destructive ? Color.red : Color.white)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
