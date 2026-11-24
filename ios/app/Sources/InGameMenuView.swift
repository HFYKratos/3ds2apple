//
//  InGameMenuView.swift
//  3ds2apple
//
//  In-game menu (0.1.7-beta3 redesign). A light card slides up from the bottom
//  in portrait; in landscape the same card is centred with all corners rounded.
//  The header carries the MENU title, a white capsule with the power / restart /
//  quick-save / quick-load actions and a white X that resumes the game. Rows are
//  grouped white cards with a leading SF Symbol; rows that open a sub-menu push a
//  secondary page inside the sheet instead of expanding sideways. Every feature
//  of the old menu is kept: save/load state, virtual controls, display settings,
//  the Settings sheet, Save Manager, Export logs, Reset and Exit are still
//  reachable (power = Exit, restart = Reset, X = resume, save/load = quick slot).
//
//  The design follows reference screenshots of another emulator's menu for its
//  layout only; all strings and code here are our own and no GPL code/text is
//  copied.
//

import SwiftUI

struct InGameMenuView: View {
    let romName: String
    /// The device direction the menu opened in (per-direction control visibility).
    let orientation: ControlLayoutOrientation
    @ObservedObject var settings: AppSettings
    @ObservedObject var saveStates: SaveStateSupport
    let onResume: () -> Void
    let onEditControls: () -> Void
    let onReset: () -> Void
    let onDisplaySettings: () -> Void
    let onSettings: () -> Void
    let onSaveManager: () -> Void
    let onDiagnostics: () -> Void
    let onExit: () -> Void
    let onLoadStateCompleted: () -> Void
    var diagnosticsHint: String? = nil

    private enum MenuPage: Hashable {
        case root
        case virtualControls
        case saveState
    }

    @State private var page: MenuPage = .root
    @State private var controlOptionsSheet: ControlOptionsPage?
    @State private var isResetControlsConfirmationPresented = false
    @State private var didHandleDebugOptions = false

    // iOS grouped palette: system semantic colours, so the menu follows the
    // system light/dark appearance like the rest of the app (0.1.7-beta4).
    private var sheetBackground: Color { Color(.systemGroupedBackground) }
    private var rowBackground: Color { Color(.secondarySystemGroupedBackground) }
    private var primaryText: Color { Color.primary }
    private var secondaryText: Color { Color.secondary }
    private var accentRed: Color { Color(.systemRed) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Tapping the dimmed area above/beside the card resumes the game
                // (0.1.7-beta4); the card itself stays interactive.
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onResume() }
                    .transition(.opacity)
                if orientation == .portrait {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)
                        sheet(height: min(geometry.size.height * 0.68,
                                            geometry.size.height - 60),
                              width: geometry.size.width,
                              topCornersOnly: true)
                            .transition(.move(edge: .bottom))
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    sheet(height: min(geometry.size.height * 0.88, 820),
                          width: min(560, geometry.size.width * 0.62),
                          topCornersOnly: false)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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
            if !didHandleDebugOptions {
                didHandleDebugOptions = true
                if let requested = DebugLaunch.requestedControlOptions {
                    controlOptionsSheet = requested
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("in-game-menu-overlay")
    }

    // MARK: - Sheet shell

    private func sheet(height: CGFloat, width: CGFloat, topCornersOnly: Bool) -> some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                content
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: width, height: max(height, 320))
        .background(sheetBackground)
        .clipShape(MenuSheetShape(radius: 28, topCornersOnly: topCornersOnly))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 8)
    }

    private var header: some View {
        VStack(spacing: 8) {
            if orientation == .portrait {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 38, height: 5)
                    .padding(.top, 8)
            }
            HStack(spacing: 10) {
                if page != .root {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { page = .root }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(primaryText)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(rowBackground))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("menu-back")
                }
                Text(pageTitle)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(primaryText)
                Spacer(minLength: 8)
                topButtons
            }
            .padding(.horizontal, 18)
            .padding(.top, orientation == .portrait ? 2 : 16)
            .padding(.bottom, 10)
        }
    }

    private var pageTitle: String {
        switch page {
        case .root: return L10n.tr("MENU")
        case .virtualControls: return L10n.tr("Virtual controls")
        case .saveState: return L10n.tr("Save state")
        }
    }

    private var topButtons: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                topIcon("power", color: accentRed, identifier: "menu-exit", action: onExit)
                topIcon("arrow.clockwise", identifier: "menu-reset", action: onReset)
                topIcon("square.and.arrow.down",
                        identifier: "menu-save-state",
                        enabled: saveStates.canSave) {
                    saveStates.save(slot: SaveStateSupport.quickSlot)
                }
                topIcon("arrow.down.doc",
                        identifier: "menu-load-state",
                        enabled: saveStates.canLoad) {
                    saveStates.load(slot: SaveStateSupport.quickSlot) { result in
                        if case .success = result { onLoadStateCompleted() }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(Capsule().fill(rowBackground))
            Button(action: onResume) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(primaryText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(rowBackground))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-resume")
        }
    }

    private func topIcon(_ systemImage: String,
                         color: Color? = nil,
                         identifier: String,
                         enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color ?? primaryText)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .root: rootContent
        case .virtualControls: virtualControlsContent
        case .saveState: saveStateContent
        }
    }

    private var rootContent: some View {
        VStack(spacing: 14) {
            singleRowCard(title: L10n.tr("Virtual controls"),
                          systemImage: "gamecontroller",
                          identifier: "menu-virtual-controls") {
                withAnimation(.easeInOut(duration: 0.18)) { page = .virtualControls }
            }
            singleRowCard(title: L10n.tr("Save state"),
                          systemImage: "archivebox",
                          identifier: "menu-save-state-page") {
                withAnimation(.easeInOut(duration: 0.18)) { page = .saveState }
            }
            rowGroup {
                actionRow(L10n.tr("Display settings"),
                          systemImage: "display",
                          identifier: "menu-display-settings",
                          action: onDisplaySettings)
                rowDivider
                actionRow(L10n.tr("Settings"),
                          systemImage: "gearshape",
                          identifier: "menu-settings",
                          action: onSettings)
                rowDivider
                actionRow(L10n.tr("Save Manager"),
                          systemImage: "folder",
                          identifier: "menu-save-manager",
                          action: onSaveManager)
                rowDivider
                actionRow(L10n.tr("Export logs"),
                          systemImage: "doc.text",
                          identifier: "menu-diagnostics",
                          action: onDiagnostics)
            }
            rowGroup {
                valueRow(title: L10n.tr("Fast-forward"),
                         systemImage: "forward.fill",
                         identifier: "menu-fast-forward") {
                    Picker("Fast-forward", selection: persistedBinding(settings, \.playbackSpeed)) {
                        ForEach(PlaybackSpeed.allCases) { speed in
                            Text(speed.title).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(accentRed)
                }
                rowDivider
                valueRow(title: L10n.tr("Sound"),
                         systemImage: "speaker.wave.2",
                         identifier: "menu-mute") {
                    Toggle("", isOn: persistedBinding(settings, \.audioMuted))
                        .labelsHidden()
                        .tint(accentRed)
                }
            }
            if let diagnosticsHint {
                Text(diagnosticsHint)
                    .font(.caption2)
                    .foregroundColor(secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            rowGroup {
                actionRow(L10n.tr("Reset game"),
                          systemImage: "arrow.counterclockwise",
                          identifier: "menu-reset-row",
                          destructive: true,
                          action: onReset)
                rowDivider
                actionRow(L10n.tr("Exit to home"),
                          systemImage: "power",
                          identifier: "menu-exit-row",
                          destructive: true,
                          action: onExit)
            }
        }
    }

    private var virtualControlsContent: some View {
        VStack(spacing: 14) {
            rowGroup {
                valueRow(title: L10n.tr("Show virtual controls"),
                         systemImage: "gamecontroller",
                         identifier: "menu-show-controls") {
                    Toggle("", isOn: persistedBinding(settings, \.showTouchControls))
                        .labelsHidden()
                        .tint(accentRed)
                }
                rowDivider
                valueRow(title: L10n.tr("Show performance stats"),
                         systemImage: "speedometer",
                         identifier: "menu-show-fps") {
                    Toggle("", isOn: persistedBinding(settings, \.showFPS))
                        .labelsHidden()
                        .tint(accentRed)
                }
                rowDivider
                valueRow(title: L10n.tr("Haptic feedback"),
                         systemImage: "hand.tap",
                         identifier: "menu-haptics") {
                    Toggle("", isOn: persistedBinding(settings, \.haptics))
                        .labelsHidden()
                        .tint(accentRed)
                }
            }
            rowGroup {
                actionRow(L10n.tr("Edit layout"),
                          systemImage: "slider.horizontal.3",
                          identifier: "menu-edit-controls",
                          action: onEditControls)
                rowDivider
                actionRow(L10n.tr("Toggle controls"),
                          systemImage: "checkmark.circle",
                          identifier: "menu-toggle-controls") {
                    controlOptionsSheet = .visibility
                }
                rowDivider
                actionRow(L10n.tr("Adjust size"),
                          systemImage: "arrow.up.left.and.arrow.down.right",
                          identifier: "menu-adjust-size") {
                    controlOptionsSheet = .size
                }
                rowDivider
                actionRow(L10n.tr("Adjust opacity"),
                          systemImage: "circle.lefthalf.filled",
                          identifier: "menu-adjust-opacity") {
                    controlOptionsSheet = .opacity
                }
                rowDivider
                actionRow(L10n.tr("Reset virtual controls"),
                          systemImage: "arrow.counterclockwise",
                          identifier: "menu-reset-controls",
                          destructive: true) {
                    isResetControlsConfirmationPresented = true
                }
            }
        }
    }

    private var saveStateContent: some View {
        VStack(spacing: 14) {
            saveStateStatus
            rowGroup {
                actionRow(L10n.tr("Save state"),
                          systemImage: "square.and.arrow.down",
                          identifier: "menu-save-state-row",
                          enabled: saveStates.canSave) {
                    saveStates.save(slot: SaveStateSupport.quickSlot)
                }
                rowDivider
                actionRow(L10n.tr("Load state"),
                          systemImage: "arrow.down.doc",
                          identifier: "menu-load-state-row",
                          enabled: saveStates.canLoad) {
                    saveStates.load(slot: SaveStateSupport.quickSlot) { result in
                        if case .success = result { onLoadStateCompleted() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var saveStateStatus: some View {
        if saveStates.busy {
            HStack(spacing: 8) {
                ProgressView().tint(primaryText)
                Text(saveStates.statusText)
                    .font(.caption)
                    .foregroundColor(secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(rowBackground))
            .accessibilityIdentifier("menu-save-state-progress")
        } else if let error = saveStates.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundColor(accentRed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(rowBackground))
                .accessibilityIdentifier("menu-save-state-error")
        } else if !saveStates.isRuntimeLoaded {
            Text(L10n.tr("Save states are available while a game is running."))
                .font(.caption)
                .foregroundColor(secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(rowBackground))
        } else {
            Text(L10n.format("Slot %ld · %@", SaveStateSupport.quickSlot,
                            saveStates.quickSlotInfo.detail))
                .font(.caption)
                .foregroundColor(secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(rowBackground))
                .accessibilityIdentifier("menu-save-state-detail")
        }
    }

    // MARK: - Row pieces

    private func singleRowCard(title: String,
                               systemImage: String,
                               identifier: String,
                               action: @escaping () -> Void) -> some View {
        rowGroup {
            actionRow(title,
                      systemImage: systemImage,
                      identifier: identifier,
                      action: action)
        }
    }

    private func rowGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(rowBackground))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 0.7)
            .padding(.leading, 56)
    }

    private func actionRow(_ title: String,
                           systemImage: String,
                           identifier: String,
                           enabled: Bool = true,
                           destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundColor(destructive ? accentRed : primaryText)
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 17))
                    .foregroundColor(destructive ? accentRed : primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(secondaryText.opacity(0.7))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(identifier)
    }

    private func valueRow<Trailing: View>(title: String,
                                          systemImage: String,
                                          identifier: String,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .regular))
                .foregroundColor(primaryText)
                .frame(width: 26)
            Text(title)
                .font(.system(size: 17))
                .foregroundColor(primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(identifier)
    }
}

/// The light menu sheet's card shape: all corners, or only the top two for the
/// portrait bottom sheet (its bottom edge sits on the screen edge).
private struct MenuSheetShape: Shape {
    let radius: CGFloat
    let topCornersOnly: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        if topCornersOnly {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}