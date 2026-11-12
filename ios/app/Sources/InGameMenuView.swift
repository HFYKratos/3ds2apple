//
//  InGameMenuView.swift
//  3ds2apple
//
//  The in-game overlay menu: it dims the (paused) game and offers resume, save
//  states, reset, display settings, the save manager, diagnostics and exit.
//
//  Opening the menu pauses the frame loop and the audio engine in ROMSession,
//  so the game can neither advance nor receive input behind the overlay.
//

import SwiftUI

struct InGameMenuView: View {
    let romName: String
    @ObservedObject var settings: AppSettings
    let onResume: () -> Void
    let onReset: () -> Void
    let onDisplaySettings: () -> Void
    let onSaveManager: () -> Void
    let onDiagnostics: () -> Void
    let onExit: () -> Void

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
                        action: onResume
                    )
                    .accessibilityIdentifier("menu-resume")

                    quickToggles

                    saveStateControls

                    actionButton(
                        "Reset game",
                        systemImage: "arrow.counterclockwise",
                        action: onReset
                    )
                    .accessibilityIdentifier("menu-reset")

                    actionButton(
                        "Display settings",
                        systemImage: "display",
                        action: onDisplaySettings
                    )
                    .accessibilityIdentifier("menu-display-settings")

                    actionButton(
                        "Save Manager",
                        systemImage: "externaldrive.fill",
                        action: onSaveManager
                    )
                    .accessibilityIdentifier("menu-save-manager")

                    actionButton(
                        "Export diagnostics",
                        systemImage: "square.and.arrow.up",
                        action: onDiagnostics
                    )
                    .accessibilityIdentifier("menu-diagnostics")

                    actionButton(
                        "Exit to home",
                        systemImage: "xmark.circle",
                        destructive: true,
                        action: onExit
                    )
                    .accessibilityIdentifier("menu-exit")
                }
                .padding(20)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
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

    private var saveStateControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                disabledButton("Save state", systemImage: "camera.on.rectangle")
                disabledButton("Load state", systemImage: "arrow.uturn.backward")
            }
            Text(SaveStateSupport.unavailableReason)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 4)
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        prominent: Bool = false,
        destructive: Bool = false,
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
    }

    private func disabledButton(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.footnote.weight(.medium))
        .foregroundColor(.white.opacity(0.55))
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}
