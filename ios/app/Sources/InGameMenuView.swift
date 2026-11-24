//
//  InGameMenuView.swift
//  3ds2apple
//
//  In-game menu (0.2.0). iOS-grouped light/dark card, bottom sheet in portrait
//  and centred card in landscape; tapping the dimmed area resumes the game.
//  Header: game cover + title; top-right power / restart / quick-save /
//  quick-load and X. Rows follow the reference emulator's in-game menu: Save
//  state, Virtual controls, Screen layout, Swap screens, Rotate screen
//  clockwise, Global Settings, Per-Application Settings (per-game overrides
//  keyed by title ID) and Close game. Save Manager / Export / Fast-forward /
//  Sound intentionally stay in Settings/Debug instead of this menu; Amiibo,
//  Cheats and Multiplayer are recorded in TODO.md, not shown as fake rows.
//
//  Layout ideas only were taken from reference screenshots; all text/code here
//  is ours and no GPL code/text is copied.
//

import SwiftUI
import UIKit

struct InGameMenuView: View {
    let romName: String
    /// The running game's title ID (per-application overrides).
    let titleID: String?
    let orientation: ControlLayoutOrientation
    @ObservedObject var settings: AppSettings
    @ObservedObject var saveStates: SaveStateSupport
    let onResume: () -> Void
    let onEditControls: () -> Void
    let onReset: () -> Void
    let onSettings: () -> Void
    let onExit: () -> Void
    let onLoadStateCompleted: () -> Void

    private enum MenuPage: Hashable {
        case root
        case virtualControls
        case saveState
        case screenLayout
        case perApplication
    }

    @State private var page: MenuPage = .root
    @State private var controlOptionsSheet: ControlOptionsPage?
    @State private var isResetControlsConfirmationPresented = false
    @State private var didHandleDebugOptions = false

    private var sheetBackground: Color { Color(.systemGroupedBackground) }
    private var rowBackground: Color { Color(.secondarySystemGroupedBackground) }
    private var primaryText: Color { Color.primary }
    private var secondaryText: Color { Color.secondary }
    private var accentRed: Color { Color(.systemRed) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
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

    // MARK: - Sheet

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
        .frame(width: width, height: max(height, 340))
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
                if page == .root {
                    Text(L10n.tr("MENU"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(primaryText)
                } else {
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
                    Text(pageTitle)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(primaryText)
                }
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
        case .screenLayout: return L10n.tr("Screen layout")
        case .perApplication: return L10n.tr("Per-Application Settings")
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
        case .screenLayout: screenLayoutContent
        case .perApplication: perApplicationContent
        }
    }

    private var rootContent: some View {
        VStack(spacing: 14) {
            rowGroup {
                actionRow(L10n.tr("Save state"),
                          systemImage: "archivebox",
                          identifier: "menu-save-state-page") {
                    withAnimation(.easeInOut(duration: 0.18)) { page = .saveState }
                }
                rowDivider
                actionRow(L10n.tr("Virtual controls"),
                          systemImage: "gamecontroller",
                          identifier: "menu-virtual-controls") {
                    withAnimation(.easeInOut(duration: 0.18)) { page = .virtualControls }
                }
            }
            rowGroup {
                actionRow(L10n.tr("Screen layout"),
                          systemImage: "rectangle.split.2x1",
                          identifier: "menu-screen-layout") {
                    withAnimation(.easeInOut(duration: 0.18)) { page = .screenLayout }
                }
                rowDivider
                valueRow(title: L10n.tr("Swap screens"),
                         systemImage: "arrow.left.arrow.right",
                         identifier: "menu-swap-screens") {
                    Toggle("", isOn: swapScreensBinding)
                        .labelsHidden()
                        .tint(.accentColor)
                }
                rowDivider
                actionRow(L10n.tr("Rotate screen clockwise"),
                          systemImage: "rotate.right",
                          identifier: "menu-rotate-screen") {
                    rotateScreenClockwise()
                }
            }
            rowGroup {
                actionRow(L10n.tr("Global Settings"),
                          systemImage: "gearshape",
                          identifier: "menu-global-settings",
                          action: onSettings)
                rowDivider
                actionRow(L10n.tr("Per-Application Settings"),
                          systemImage: "app.badge",
                          identifier: "menu-per-application") {
                    withAnimation(.easeInOut(duration: 0.18)) { page = .perApplication }
                }
            }
            rowGroup {
                actionRow(L10n.tr("Close game"),
                          systemImage: "power",
                          identifier: "menu-close-game",
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
                        .tint(.accentColor)
                }
                rowDivider
                valueRow(title: L10n.tr("Show performance stats"),
                         systemImage: "speedometer",
                         identifier: "menu-show-fps") {
                    Toggle("", isOn: persistedBinding(settings, \.showFPS))
                        .labelsHidden()
                        .tint(.accentColor)
                }
                rowDivider
                valueRow(title: L10n.tr("Haptic feedback"),
                         systemImage: "hand.tap",
                         identifier: "menu-haptics") {
                    Toggle("", isOn: persistedBinding(settings, \.haptics))
                        .labelsHidden()
                        .tint(.accentColor)
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
                          identifier: "menu-toggle-controls") { controlOptionsSheet = .visibility }
                rowDivider
                actionRow(L10n.tr("Adjust size"),
                          systemImage: "arrow.up.left.and.arrow.down.right",
                          identifier: "menu-adjust-size") { controlOptionsSheet = .size }
                rowDivider
                actionRow(L10n.tr("Adjust opacity"),
                          systemImage: "circle.lefthalf.filled",
                          identifier: "menu-adjust-opacity") { controlOptionsSheet = .opacity }
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

    private var screenLayoutContent: some View {
        VStack(spacing: 14) {
            rowGroup {
                pickerRow(title: L10n.tr("Landscape screen layout"),
                          systemImage: "rectangle.split.2x1",
                          identifier: "menu-landscape-layout") {
                    Picker("Landscape screen layout",
                           selection: persistedBinding(settings, \.landscapeScreenLayout)) {
                        ForEach(LandscapeScreenLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                rowDivider
                pickerRow(title: L10n.tr("Portrait screen layout"),
                          systemImage: "rectangle.portrait",
                          identifier: "menu-portrait-layout") {
                    Picker("Portrait screen layout",
                           selection: persistedBinding(settings, \.portraitScreenLayout)) {
                        ForEach(PortraitScreenLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                rowDivider
                pickerRow(title: L10n.tr("Screen rotation"),
                          systemImage: "rotate.right",
                          identifier: "menu-screen-rotation") {
                    Picker("Screen rotation",
                           selection: persistedBinding(settings, \.screenRotation)) {
                        ForEach(ScreenRotation.allCases) { rotation in
                            Text(rotation.title).tag(rotation)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                rowDivider
                pickerRow(title: L10n.tr("Resolution"),
                          systemImage: "square.resize",
                          identifier: "menu-resolution") {
                    Picker("Resolution", selection: persistedBinding(settings, \.renderScale)) {
                        Text("1x").tag(1)
                        Text("2x").tag(2)
                        Text("3x").tag(3)
                        Text("4x").tag(4)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var perApplicationContent: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(romName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(primaryText)
                Text(titleID.map { L10n.format("Title ID %@", $0) }
                     ?? L10n.tr("No running game data"))
                    .font(.system(size: 13))
                    .foregroundColor(secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            if let titleID {
                rowGroup {
                    pickerRow(title: L10n.tr("Screen rotation"),
                              systemImage: "rotate.right",
                              identifier: "per-app-rotation") {
                        Picker("Screen rotation", selection: rotationOverrideBinding) {
                            Text(L10n.tr("Use global")).tag("")
                            ForEach(ScreenRotation.allCases) { rotation in
                                Text(rotation.title).tag(rotation.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    rowDivider
                    pickerRow(title: L10n.tr("Swap screens"),
                              systemImage: "arrow.left.arrow.right",
                              identifier: "per-app-swap") {
                        Picker("Swap screens", selection: swapOverrideBinding) {
                            Text(L10n.tr("Use global")).tag("")
                            Text(L10n.tr("On")).tag("on")
                            Text(L10n.tr("Off")).tag("off")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    rowDivider
                    pickerRow(title: L10n.tr("Integer scaling"),
                              systemImage: "square.grid.2x2",
                              identifier: "per-app-integer-scaling") {
                        Picker("Integer scaling", selection: integerOverrideBinding) {
                            Text(L10n.tr("Use global")).tag("")
                            Text(L10n.tr("On")).tag("on")
                            Text(L10n.tr("Off")).tag("off")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    rowDivider
                    pickerRow(title: L10n.tr("Screen aspect"),
                              systemImage: "aspectratio",
                              identifier: "per-app-screen-aspect") {
                        Picker("Screen aspect", selection: aspectOverrideBinding) {
                            Text(L10n.tr("Use global")).tag("")
                            ForEach(ScreenAspect.allCases) { aspect in
                                Text(aspect.title).tag(aspect.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                Text(L10n.tr("Gamepad profile"))
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundColor(secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                rowGroup {
                    pickerRow(title: L10n.tr("Deadzone"),
                              systemImage: "circle.dashed",
                              identifier: "per-app-deadzone") {
                        Picker("Deadzone", selection: deadzoneOverrideBinding) {
                            Text(L10n.tr("Use global")).tag("")
                            ForEach(["0", "5", "10", "15", "20", "25", "30"], id: \.self) { percent in
                                Text("\(percent)%").tag(percent)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    rowDivider
                    pickerRow(title: L10n.tr("Control appearance"),
                              systemImage: "circle.lefthalf.filled",
                              identifier: "per-app-control-appearance") {
                        Picker("Control appearance", selection: appearanceOverrideBinding) {
                            Text(L10n.tr("Use global")).tag("")
                            ForEach(ControlAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    rowDivider
                    pickerRow(title: L10n.tr("Button mapping"),
                              systemImage: "gamecontroller",
                              identifier: "per-app-button-mapping") {
                        Picker("Button mapping", selection: buttonMapOverrideBinding) {
                            Text(L10n.tr("Use global")).tag("")
                            Text(L10n.tr("Custom (copy current mapping)")).tag("custom")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                rowGroup {
                    actionRow(L10n.tr("Clear per-application overrides"),
                              systemImage: "arrow.counterclockwise",
                              identifier: "per-app-clear",
                              destructive: true) {
                        settings.setPerGameOverrides(nil, for: titleID)
                    }
                }
                Text(L10n.tr("These overrides apply only to this game and fall back to the global settings for anything left on Use global."))
                    .font(.caption)
                    .foregroundColor(secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else {
                Text(L10n.tr("Per-application settings are available while a game is running."))
                    .font(.caption)
                    .foregroundColor(secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(rowBackground))
            }
        }
    }

    // MARK: - Per-application override bindings

    private var currentOverrides: PerGameOverrides {
        settings.overrides(for: titleID) ?? PerGameOverrides(
            screenRotationRaw: nil, swapScreens: nil,
            integerScale: nil, screenAspectRaw: nil
        )
    }

    private func mutateOverrides(_ mutate: (inout PerGameOverrides) -> Void) {
        guard let titleID else { return }
        var overrides = currentOverrides
        mutate(&overrides)
        let empty = overrides.screenRotationRaw == nil && overrides.swapScreens == nil
            && overrides.integerScale == nil && overrides.screenAspectRaw == nil
            && overrides.analogDeadzone == nil && overrides.controlAppearanceRaw == nil
            && overrides.controllerButtonMap == nil
        settings.setPerGameOverrides(empty ? nil : overrides, for: titleID)
    }

    private var rotationOverrideBinding: Binding<String> {
        Binding(get: { currentOverrides.screenRotationRaw ?? "" },
                set: { newValue in
                    mutateOverrides {
                        $0.screenRotationRaw = newValue.isEmpty ? nil : newValue
                    }
                })
    }

    private var swapOverrideBinding: Binding<String> {
        Binding(get: {
            guard let value = currentOverrides.swapScreens else { return "" }
            return value ? "on" : "off"
        }, set: { newValue in
            mutateOverrides {
                $0.swapScreens = newValue.isEmpty ? nil : (newValue == "on")
            }
        })
    }

    private var integerOverrideBinding: Binding<String> {
        Binding(get: {
            guard let value = currentOverrides.integerScale else { return "" }
            return value ? "on" : "off"
        }, set: { newValue in
            mutateOverrides {
                $0.integerScale = newValue.isEmpty ? nil : (newValue == "on")
            }
        })
    }

    private var aspectOverrideBinding: Binding<String> {
        Binding(get: { currentOverrides.screenAspectRaw ?? "" },
                set: { newValue in
                    mutateOverrides { $0.screenAspectRaw = newValue.isEmpty ? nil : newValue }
                })
    }

    private var deadzoneOverrideBinding: Binding<String> {
        Binding(
            get: {
                guard let value = currentOverrides.analogDeadzone else { return "" }
                return String(Int((value * 100).rounded()))
            },
            set: { newValue in
                mutateOverrides {
                    $0.analogDeadzone = newValue.isEmpty
                        ? nil
                        : (Double(newValue) ?? 15) / 100
                }
            }
        )
    }

    private var appearanceOverrideBinding: Binding<String> {
        Binding(
            get: { currentOverrides.controlAppearanceRaw ?? "" },
            set: { newValue in
                mutateOverrides {
                    $0.controlAppearanceRaw = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    private var buttonMapOverrideBinding: Binding<String> {
        Binding(
            get: { currentOverrides.controllerButtonMap == nil ? "" : "custom" },
            set: { newValue in
                mutateOverrides {
                    $0.controllerButtonMap = newValue.isEmpty
                        ? nil
                        : settings.controllerButtonMap
                }
            }
        )
    }

    private var swapScreensBinding: Binding<Bool> {
        Binding(
            get: { settings.effectiveSwapScreens(titleID: titleID) },
            set: { newValue in
                if let titleID, var overrides = settings.overrides(for: titleID) {
                    overrides.swapScreens = newValue
                    settings.setPerGameOverrides(overrides, for: titleID)
                } else {
                    settings.swapScreens = newValue
                    settings.persist()
                }
            }
        )
    }

    private func rotateScreenClockwise() {
        let current = settings.effectiveScreenRotation(titleID: titleID)
        let next: ScreenRotation
        switch current {
        case .upright: next = .clockwise
        case .clockwise: next = .upsideDown
        case .upsideDown: next = .counterClockwise
        case .counterClockwise: next = .upright
        }
        if let titleID, var overrides = settings.overrides(for: titleID) {
            overrides.screenRotationRaw = next.rawValue
            settings.setPerGameOverrides(overrides, for: titleID)
        } else {
            settings.screenRotation = next
            settings.persist()
        }
    }

    // MARK: - Save state status

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

    private func pickerRow<Trailing: View>(title: String,
                                           systemImage: String,
                                           identifier: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        valueRow(title: title, systemImage: systemImage, identifier: identifier, trailing: trailing)
    }
}

/// The light menu sheet's card shape: all corners, or only the top two for the
/// portrait bottom sheet.
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