//
//  InGameMenuView.swift
//  3ds2apple
//
//  In-game menu (0.2.1-beta2). The menu now speaks the same iOS-native grouped
//  language as the 0.2.1 Settings redesign: inset-grouped cards on a
//  system-grouped page, one 29 pt coloured rounded-square SF Symbol tile per row
//  with a white glyph, body-weight regular row titles, footnote secondary
//  explanations, secondary trailing values and the system chevron / Toggle /
//  menu picker / segmented control instead of hand-drawn look-alikes. Every
//  colour is semantic (systemGroupedBackground, secondarySystemGroupedBackground,
//  label, secondaryLabel, the system fills), so light and dark follow the system.
//
//  Presentation is unchanged: portrait shows a bottom sheet, landscape a centred
//  card, tapping the dimmed area resumes the game, the header keeps the running
//  game's name and the power / restart / close buttons, and every sub-page is a
//  NavigationStack push with the system pop animation.
//
//  0.2.1-beta2 animation fix: the landscape card could stutter for one frame when
//  it popped up because the insertion transaction animated two transitions at
//  once (GameView's container transition plus the sheet's own scale/opacity
//  transition), the dimmed backdrop faded on its own, and the onAppear save-state
//  refresh published new observable state in the middle of the spring. The menu
//  now keeps exactly one transition of its own (the portrait card's bottom-edge
//  move; the landscape container spring belongs to GameView), adds no implicit
//  animation around the content, and applies the appearance state update in a
//  transaction that disables animation, so row layout can never animate during
//  the pop. Push/pop keeps the NavigationStack's system animation.
//
//  Rows follow the reference emulator's in-game menu option set: Save state,
//  Virtual controls, Screen layout, Swap screens, Rotate screen clockwise,
//  Global Settings, Per-Application Settings (per-game overrides keyed by title
//  ID) and Close game. Save Manager / Export / Fast-forward / Sound intentionally
//  stay in Settings/Debug instead of this menu; Amiibo, Cheats and Multiplayer are
//  recorded in TODO.md, not shown as fake rows.
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

    /// NavigationStack path: [] = root, one element = a sub-page. Native
    /// push/pop animations replace the old ScrollView transition.
    @State private var pagePath: [MenuPage] = []

    private var currentPage: MenuPage { pagePath.last ?? .root }
    @State private var controlOptionsSheet: ControlOptionsPage?
    @State private var isResetControlsConfirmationPresented = false
    @State private var didHandleDebugOptions = false

    // MARK: - Grouped style

    /// Page background of the card (the system Settings page colour).
    private var sheetBackground: Color { Color(.systemGroupedBackground) }
    /// Background of one inset-grouped card (the system Settings card colour).
    private var rowBackground: Color { Color(.secondarySystemGroupedBackground) }
    private var primaryText: Color { Color.primary }
    private var secondaryText: Color { Color.secondary }
    private var dividerColor: Color { Color(.separator) }
    private var chevronColor: Color { Color(.tertiaryLabel) }
    private var controlFill: Color { Color(.tertiarySystemFill) }
    private var accentRed: Color { Color(.systemRed) }

    /// System Settings colours for the row icon tiles. They are all semantic, so
    /// the tiles keep their contrast in dark mode.
    private var tintBlue: Color { Color(.systemBlue) }
    private var tintGreen: Color { Color(.systemGreen) }
    private var tintIndigo: Color { Color(.systemIndigo) }
    private var tintOrange: Color { Color(.systemOrange) }
    private var tintPink: Color { Color(.systemPink) }
    private var tintPurple: Color { Color(.systemPurple) }
    private var tintTeal: Color { Color(.systemTeal) }
    private var tintGray: Color { Color(.systemGray) }

    private let cardCornerRadius: CGFloat = 10
    private let iconTileSize: CGFloat = 29
    private let iconCornerRadius: CGFloat = 7
    private let rowHorizontalPadding: CGFloat = 16
    private let iconTitleSpacing: CGFloat = 12
    private let cardSpacing: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Tap-outside resume. The dim has no transition of its own: it
                // fades with the single container animation (GameView's
                // presentation transition) instead of running a second, parallel
                // opacity animation inside this view.
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onResume() }
                if orientation == .portrait {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)
                        sheet(height: min(geometry.size.height * 0.68,
                                          geometry.size.height - 60),
                              width: geometry.size.width,
                              topCornersOnly: true)
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    // The landscape card has no transition here on purpose: the
                    // one opacity + scale spring is applied by GameView to the
                    // whole overlay container, so the card cannot animate twice.
                    sheet(height: min(geometry.size.height * 0.90, 820),
                          width: min(580, geometry.size.width * 0.64),
                          topCornersOnly: false)
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
            // The slot refresh publishes new @Published state. Doing it inside
            // the presentation transaction made the rows lay out again in the
            // middle of the pop-up spring; disabling animation for this update
            // keeps the card still while it animates in.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                saveStates.refresh()
                saveStates.clearMessages()
            }
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
            NavigationStack(path: $pagePath) {
                scrollable(rootContent)
                    .navigationDestination(for: MenuPage.self) { destination in
                        scrollable(content(for: destination))
                            .navigationBarBackButtonHidden(true)
                            .toolbar(.hidden, for: .navigationBar)
                    }
            }
            .background(sheetBackground)
            .toolbar(.hidden, for: .navigationBar)
        }
        .frame(width: width, height: max(height, 340))
        .background(sheetBackground)
        .clipShape(MenuSheetShape(radius: cardCornerRadius, topCornersOnly: topCornersOnly))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
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
                if currentPage == .root {
                    Text(romName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                } else {
                    Button {
                        popPage()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("menu-back")
                    Text(pageTitle(for: currentPage))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                topButtons
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.top, orientation == .portrait ? 2 : 14)
            .padding(.bottom, 10)
        }
    }

    private func pageTitle(for page: MenuPage) -> String {
        switch page {
        case .root: return romName
        case .virtualControls: return L10n.tr("Virtual controls")
        case .saveState: return L10n.tr("Save state")
        case .screenLayout: return L10n.tr("Screen layout")
        case .perApplication: return L10n.tr("Per-Application Settings")
        }
    }

    private func pushPage(_ page: MenuPage) {
        // The NavigationStack runs its native push/pop transition; the path change
        // only needs the transaction that lets the stack animate it (same curve as
        // before, no custom page transition is layered on top).
        withAnimation(.easeInOut(duration: 0.28)) {
            pagePath.append(page)
        }
    }

    private func popPage() {
        guard !pagePath.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            pagePath.removeLast()
        }
    }

    private func scrollable<Content: View>(_ content: Content) -> some View {
        ScrollView(showsIndicators: false) {
            content
                .padding(.horizontal, rowHorizontalPadding)
                .padding(.top, 4)
                .padding(.bottom, 28)
        }
    }

    /// Only power (exit), restart (reset) and X (resume) live in the header;
    /// quick save/load are in the Save state sub-page.
    private var topButtons: some View {
        HStack(spacing: 8) {
            topIcon("power", color: accentRed, identifier: "menu-exit", action: onExit)
            topIcon("arrow.clockwise", identifier: "menu-reset", action: onReset)
            Button(action: onResume) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(primaryText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(controlFill))
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
                .foregroundStyle(color ?? primaryText)
                .frame(width: 34, height: 34)
                .background(Circle().fill(controlFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Pages

    @ViewBuilder
    private func content(for page: MenuPage) -> some View {
        switch page {
        case .root: rootContent
        case .virtualControls: virtualControlsContent
        case .saveState: saveStateContent
        case .screenLayout: screenLayoutContent
        case .perApplication: perApplicationContent
        }
    }

    private var rootContent: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            rowGroup {
                actionRow(L10n.tr("Save state"),
                          systemImage: "archivebox",
                          tint: tintBlue,
                          identifier: "menu-save-state-page") {
                    pushPage(.saveState)
                }
                rowDivider
                actionRow(L10n.tr("Virtual controls"),
                          systemImage: "gamecontroller",
                          tint: tintPurple,
                          identifier: "menu-virtual-controls") {
                    pushPage(.virtualControls)
                }
            }
            rowGroup {
                actionRow(L10n.tr("Screen layout"),
                          systemImage: "rectangle.split.2x1",
                          tint: tintIndigo,
                          identifier: "menu-screen-layout") {
                    pushPage(.screenLayout)
                }
                rowDivider
                toggleRow(L10n.tr("Swap screens"),
                          systemImage: "arrow.left.arrow.right",
                          tint: tintTeal,
                          identifier: "menu-swap-screens",
                          isOn: swapScreensBinding)
                rowDivider
                actionRow(L10n.tr("Rotate screen clockwise"),
                          systemImage: "rotate.right",
                          tint: tintOrange,
                          identifier: "menu-rotate-screen") {
                    rotateScreenClockwise()
                }
            }
            rowGroup {
                actionRow(L10n.tr("Global Settings"),
                          systemImage: "gearshape",
                          tint: tintGray,
                          identifier: "menu-global-settings",
                          action: onSettings)
                rowDivider
                actionRow(L10n.tr("Per-Application Settings"),
                          systemImage: "app.badge",
                          tint: tintGreen,
                          identifier: "menu-per-application") {
                    pushPage(.perApplication)
                }
            }
            rowGroup {
                actionRow(L10n.tr("Close game"),
                          systemImage: "power",
                          tint: accentRed,
                          identifier: "menu-close-game",
                          destructive: true,
                          action: onExit)
            }
        }
    }

    private var virtualControlsContent: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            rowGroup {
                toggleRow(L10n.tr("Show virtual controls"),
                          systemImage: "gamecontroller",
                          tint: tintBlue,
                          identifier: "menu-show-controls",
                          isOn: persistedBinding(settings, \.showTouchControls))
                rowDivider
                toggleRow(L10n.tr("Show performance stats"),
                          systemImage: "speedometer",
                          tint: tintGreen,
                          identifier: "menu-show-fps",
                          isOn: persistedBinding(settings, \.showFPS))
                rowDivider
                toggleRow(L10n.tr("Haptic feedback"),
                          systemImage: "hand.tap",
                          tint: tintPink,
                          identifier: "menu-haptics",
                          isOn: persistedBinding(settings, \.haptics))
            }
            rowGroup {
                actionRow(L10n.tr("Edit layout"),
                          systemImage: "slider.horizontal.3",
                          tint: tintIndigo,
                          identifier: "menu-edit-controls",
                          action: onEditControls)
                rowDivider
                actionRow(L10n.tr("Toggle controls"),
                          systemImage: "checkmark.circle",
                          tint: tintTeal,
                          identifier: "menu-toggle-controls") { controlOptionsSheet = .visibility }
                rowDivider
                actionRow(L10n.tr("Adjust size"),
                          systemImage: "arrow.up.left.and.arrow.down.right",
                          tint: tintOrange,
                          identifier: "menu-adjust-size") { controlOptionsSheet = .size }
                rowDivider
                actionRow(L10n.tr("Adjust opacity"),
                          systemImage: "circle.lefthalf.filled",
                          tint: tintPurple,
                          identifier: "menu-adjust-opacity") { controlOptionsSheet = .opacity }
                rowDivider
                actionRow(L10n.tr("Reset virtual controls"),
                          systemImage: "arrow.counterclockwise",
                          tint: accentRed,
                          identifier: "menu-reset-controls",
                          destructive: true) {
                    isResetControlsConfirmationPresented = true
                }
            }
        }
    }

    private var saveStateContent: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            saveStateStatus
            rowGroup {
                actionRow(L10n.tr("Save state"),
                          systemImage: "square.and.arrow.down",
                          tint: tintBlue,
                          identifier: "menu-save-state-row",
                          enabled: saveStates.canSave) {
                    saveStates.save(slot: SaveStateSupport.quickSlot)
                }
                rowDivider
                actionRow(L10n.tr("Load state"),
                          systemImage: "arrow.down.doc",
                          tint: tintGreen,
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
        VStack(alignment: .leading, spacing: cardSpacing) {
            rowGroup {
                pickerRow(title: L10n.tr("Landscape screen layout"),
                          systemImage: "rectangle.split.2x1",
                          tint: tintIndigo,
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
                          tint: tintBlue,
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
                          tint: tintOrange,
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
            }
            // The resolution row uses the system segmented control, the same
            // control the 0.2.1 Settings redesign uses for this setting.
            rowGroup {
                resolutionRow
            }
        }
    }

    private var resolutionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: iconTitleSpacing) {
                iconTile("square.resize", tint: tintTeal)
                Text(L10n.tr("Resolution"))
                    .font(.body)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
            }
            Picker("Resolution", selection: persistedBinding(settings, \.renderScale)) {
                Text("1x").tag(1)
                Text("2x").tag(2)
                Text("3x").tag(3)
                Text("4x").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("menu-resolution")
    }

    private var perApplicationContent: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(romName)
                    .font(.body)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(titleID.map { L10n.format("Title ID %@", $0) }
                     ?? L10n.tr("No running game data"))
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let titleID {
                rowGroup {
                    pickerRow(title: L10n.tr("Screen rotation"),
                              systemImage: "rotate.right",
                              tint: tintOrange,
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
                              tint: tintTeal,
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
                              tint: tintBlue,
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
                              tint: tintPurple,
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
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(L10n.tr("Gamepad profile"))
                    rowGroup {
                        pickerRow(title: L10n.tr("Deadzone"),
                                  systemImage: "circle.dashed",
                                  tint: tintTeal,
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
                                  tint: tintIndigo,
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
                                  tint: tintGreen,
                                  identifier: "per-app-button-mapping") {
                            Picker("Button mapping", selection: buttonMapOverrideBinding) {
                                Text(L10n.tr("Use global")).tag("")
                                Text(L10n.tr("Custom (copy current mapping)")).tag("custom")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }
                }
                rowGroup {
                    actionRow(L10n.tr("Clear per-application overrides"),
                              systemImage: "arrow.counterclockwise",
                              tint: accentRed,
                              identifier: "per-app-clear",
                              destructive: true) {
                        settings.setPerGameOverrides(nil, for: titleID)
                    }
                }
                Text(L10n.tr("These overrides apply only to this game and fall back to the global settings for anything left on Use global."))
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(L10n.tr("Per-application settings are available while a game is running."))
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .fill(rowBackground))
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
                ProgressView()
                Text(saveStates.statusText)
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("menu-save-state-progress")
        } else if let error = saveStates.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(accentRed)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("menu-save-state-error")
        } else if !saveStates.isRuntimeLoaded {
            Text(L10n.tr("Save states are available while a game is running."))
                .font(.footnote)
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(L10n.format("Slot %ld · %@", SaveStateSupport.quickSlot,
                            saveStates.quickSlotInfo.detail))
                .font(.footnote)
                .foregroundStyle(secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("menu-save-state-detail")
        }
    }

    // MARK: - Grouped card pieces

    /// One inset-grouped card: system Settings background, 10 pt continuous
    /// corners, rows divided by a hairline inset to the row titles.
    private func rowGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(rowBackground))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 0.5)
            .padding(.leading, rowHorizontalPadding + iconTileSize + iconTitleSpacing)
    }

    /// Footnote uppercase section header, like the system grouped-list section.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(secondaryText)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The 29 pt coloured rounded-square icon tile of a Settings row: a tile
    /// filled with a system colour and a white SF Symbol glyph.
    private func iconTile(_ systemImage: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
            .fill(tint)
            .frame(width: iconTileSize, height: iconTileSize)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private func actionRow(_ title: String,
                           systemImage: String,
                           tint: Color,
                           identifier: String,
                           enabled: Bool = true,
                           destructive: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: iconTitleSpacing) {
                iconTile(systemImage, tint: tint)
                Text(title)
                    .font(.body)
                    .foregroundStyle(destructive ? accentRed : primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(chevronColor)
            }
            .padding(.horizontal, rowHorizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(identifier)
    }

    private func toggleRow(_ title: String,
                           systemImage: String,
                           tint: Color,
                           identifier: String,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: iconTitleSpacing) {
            iconTile(systemImage, tint: tint)
            Text(title)
                .font(.body)
                .foregroundStyle(primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle(isOn: isOn) { EmptyView() }
                .labelsHidden()
                .accessibilityLabel(Text(title))
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(identifier)
    }

    private func valueRow<Trailing: View>(title: String,
                                          systemImage: String,
                                          tint: Color,
                                          identifier: String,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: iconTitleSpacing) {
            iconTile(systemImage, tint: tint)
            Text(title)
                .font(.body)
                .foregroundStyle(primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(identifier)
    }

    private func pickerRow<Trailing: View>(title: String,
                                           systemImage: String,
                                           tint: Color,
                                           identifier: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        valueRow(title: title,
                 systemImage: systemImage,
                 tint: tint,
                 identifier: identifier,
                 trailing: trailing)
    }
}

/// The menu card's shape: all corners, or only the top two for the portrait
/// bottom sheet.
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
