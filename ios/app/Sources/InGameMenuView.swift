//
//  InGameMenuView.swift
//  3ds2apple
//
//  The in-game overlay menu: it dims the (paused) game and offers resume, the
//  quick save state, the round-4 virtual-control options, mute and fast-forward,
//  display settings, the save manager, diagnostics and exit.
//
//  Round 5 unifies the option rows: every row is the same icon-free style (a
//  title plus an optional trailing toggle/chevron/value), the same height and
//  padding. SF Symbol icons are intentionally not used for now.
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
    /// The device direction the menu opened in (per-direction control visibility).
    let orientation: ControlLayoutOrientation
    @ObservedObject var settings: AppSettings
    @ObservedObject var saveStates: SaveStateSupport
    let onResume: () -> Void
    /// Closes the menu and enters the in-game control edit mode (the runtime
    /// stays paused; Done in the editor resumes it).
    let onEditControls: () -> Void
    let onReset: () -> Void
    let onDisplaySettings: () -> Void
    let onSettings: () -> Void
    let onSaveManager: () -> Void
    let onDiagnostics: () -> Void
    let onExit: () -> Void
    /// Called after a state load succeeded: the game view closes the menu and
    /// resumes the restored session.
    let onLoadStateCompleted: () -> Void
    /// Path (relative to Documents) of the diagnostics file the last export
    /// kept, so it can also be pulled from the Files app after sharing.
    var diagnosticsHint: String? = nil

    /// The virtual-control options sheet (round 4) currently open, if any.
    @State private var controlOptionsSheet: ControlOptionsPage?
    @State private var isResetControlsConfirmationPresented = false
    @State private var didHandleDebugOptions = false

    // Unified row metrics (round 5): every option row uses these.
    private let rowVerticalPadding: CGFloat = 12
    private let rowHorizontalPadding: CGFloat = 10

    var body: some View {
        ZStack {
            Color.black.opacity(0.74)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    header
                    resumeRow
                    saveStateCard
                    virtualControlsCard
                    quickSettingsCard
                    gameActionsCard
                }
                .padding(20)
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $controlOptionsSheet) { page in
            switch page {
            case .visibility:
                ControlVisibilitySheet(settings: settings, orientation: orientation)
            case .size:
                ControlSizeSheet(settings: settings)
            case .opacity:
                ControlOpacitySheet(settings: settings)
            }
        }
        .alert(L10n.tr("Reset virtual controls?"), isPresented: $isResetControlsConfirmationPresented) {
            Button(L10n.tr("Reset"), role: .destructive) {
                settings.resetVirtualControls()
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("Restores the default control positions for both orientations, every size to 100% and all controls visible."))
        }
        .onAppear {
            saveStates.refresh()
            saveStates.clearMessages()
            // Headless screenshot hook: open one of the option sheets straight
            // away; inert in normal launches.
            if !didHandleDebugOptions {
                didHandleDebugOptions = true
                if let page = DebugLaunch.requestedControlOptions {
                    controlOptionsSheet = page
                }
            }
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

    private var resumeRow: some View {
        Button(action: onResume) {
            HStack(spacing: 10) {
                Text("Resume game")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 8)
                rowChevron
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, rowVerticalPadding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor)
            )
        }
        .buttonStyle(.plain)
        .disabled(saveStates.busy)
        .accessibilityIdentifier("menu-resume")
    }

    // MARK: - Quick save state

    private var saveStateCard: some View {
        card {
            sectionTitle("Save state")
            actionRow("Save state",
                      enabled: saveStates.canSave,
                      identifier: "menu-save-state") {
                saveStates.save(slot: SaveStateSupport.quickSlot)
            }
            rowDivider
            actionRow("Load state",
                      enabled: saveStates.canLoad,
                      identifier: "menu-load-state") {
                saveStates.load(slot: SaveStateSupport.quickSlot) { result in
                    if case .success = result {
                        onLoadStateCompleted()
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
            .padding(.horizontal, rowHorizontalPadding)
            .accessibilityIdentifier("menu-save-state-progress")
        } else if let error = saveStates.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, rowHorizontalPadding)
                .accessibilityIdentifier("menu-save-state-error")
        } else if !saveStates.isRuntimeLoaded {
            Text("Save states are available while a game is running.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, rowHorizontalPadding)
        } else {
            Text(L10n.format("Slot %ld · %@", SaveStateSupport.quickSlot, saveStates.quickSlotInfo.detail))
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, rowHorizontalPadding)
                .accessibilityIdentifier("menu-save-state-detail")
        }
    }

    // MARK: - Virtual controls

    private var virtualControlsCard: some View {
        card {
            sectionTitle("Virtual controls")
            toggleRow("Show virtual controls",
                      isOn: persistedBinding(settings, \.showTouchControls),
                      identifier: "menu-show-controls")
            toggleRow("Show performance stats",
                      isOn: persistedBinding(settings, \.showFPS),
                      identifier: "menu-show-fps")
            toggleRow("Haptic feedback",
                      isOn: persistedBinding(settings, \.haptics),
                      identifier: "menu-haptics")
            rowDivider
            actionRow("Edit layout", identifier: "menu-edit-controls", action: onEditControls)
            rowDivider
            actionRow("Toggle controls", identifier: "menu-toggle-controls") {
                controlOptionsSheet = .visibility
            }
            rowDivider
            actionRow("Adjust size", identifier: "menu-adjust-size") {
                controlOptionsSheet = .size
            }
            rowDivider
            actionRow("Adjust opacity", identifier: "menu-adjust-opacity") {
                controlOptionsSheet = .opacity
            }
            rowDivider
            actionRow("Reset virtual controls",
                      destructive: true,
                      identifier: "menu-reset-controls") {
                isResetControlsConfirmationPresented = true
            }
        }
    }

    // MARK: - Quick settings

    private var quickSettingsCard: some View {
        card {
            toggleRow("Mute audio",
                      isOn: persistedBinding(settings, \.audioMuted),
                      identifier: "menu-mute")
            rowDivider
            HStack(spacing: 10) {
                rowLabel("Fast-forward")
                Spacer(minLength: 8)
                Picker("Fast-forward", selection: persistedBinding(settings, \.playbackSpeed)) {
                    ForEach(PlaybackSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, rowVerticalPadding)
            Text("Fast-forward applies when the game resumes.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, rowHorizontalPadding)
        }
    }

    // MARK: - Game actions

    private var gameActionsCard: some View {
        card {
            actionRow("Display settings", identifier: "menu-display-settings", action: onDisplaySettings)
            rowDivider
            actionRow("Settings", identifier: "menu-settings", action: onSettings)
            rowDivider
            actionRow("Save Manager", identifier: "menu-save-manager", action: onSaveManager)
            rowDivider
            actionRow("Export logs", identifier: "menu-diagnostics", action: onDiagnostics)
            if let diagnosticsHint {
                Text(diagnosticsHint)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, rowHorizontalPadding)
                    .accessibilityIdentifier("menu-diagnostics-hint")
            }
            rowDivider
            actionRow("Reset game", identifier: "menu-reset", action: onReset)
            rowDivider
            actionRow("Exit to home",
                      destructive: true,
                      identifier: "menu-exit",
                      action: onExit)
        }
    }

    // MARK: - Unified row pieces (round 5: no icons)

    private func rowLabel(_ title: LocalizedStringKey,
                          destructive: Bool = false,
                          enabled: Bool = true) -> some View {
        Text(title)
            .font(.body)
            .foregroundColor(destructive ? .red : .white.opacity(enabled ? 0.95 : 0.45))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var rowChevron: some View {
        Text("›")
            .font(.body.weight(.semibold))
            .foregroundColor(.white.opacity(0.35))
    }

    private func actionRow(_ title: LocalizedStringKey,
                           enabled: Bool = true,
                           destructive: Bool = false,
                           identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                rowLabel(title, destructive: destructive, enabled: enabled)
                Spacer(minLength: 8)
                rowChevron
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, rowVerticalPadding)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    private func toggleRow(_ title: LocalizedStringKey,
                           isOn: Binding<Bool>,
                           identifier: String) -> some View {
        HStack(spacing: 10) {
            rowLabel(title)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, rowVerticalPadding)
        .accessibilityIdentifier(identifier)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.white.opacity(0.55))
            .padding(.horizontal, rowHorizontalPadding)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 0.5)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
    }
}