//
//  GameView.swift
//  3ds2apple
//
//  The running game: the two 3DS screens on the CAMetalLayer (or the CGImage
//  readback fallback), the on-screen controls and the in-game overlay menu.
//
//  Round-1 layout redesign: the picture fills the whole game view (safe-area
//  aware, plain black around it) with no title bar, no rounded card and no
//  reserved control pad. The on-screen controls float over the picture as a
//  full-screen overlay from the user's layout profile. Round 4 adds the pause
//  menu's virtual-control options (per-row visibility and size) and the in-game
//  edit mode: the menu closes, the game stays paused, the HUD is hidden and the
//  controls are dragged directly over the frozen picture until the centered Done
//  pill saves the current direction and resumes the game. The FPS counter and the
//  pause/menu button are translucent floating controls: FPS in the top-trailing
//  safe-area corner in both orientations, pause next to it in portrait and
//  bottom-centre in landscape.
//
//  The screen arrangement comes from the split Settings choices: the landscape
//  preset (large / single / side / hybrid / original / custom) and the separate
//  portrait preset (default / original / custom). Every preset is a presenter
//  arrangement (round 3 adds LargeTopRight / Hybrid / TopFullWidth, ABI 5-7); only
//  the custom-layout rectangles are drawn by the app's readback path, which needs
//  the session to skip the presenter for the next load. The no-presenter
//  emergency fallback mirrors every arrangement in SwiftUI (hybrid draws the
//  upper screen twice).
//
//  Opening the in-game menu pauses emulation; the runtime and the last frame stay
//  until resume. When a title starts the 3DS software keyboard, the session stops
//  its frame loop and publishes the request; this view shows the keyboard overlay
//  on top of everything. Answering it resumes the game.
//
//  Debug launch hooks (`-previewGameView`, `-previewScreenLayout <layout>`,
//  `-previewLandscape`, see DebugLaunch.swift) render the same view without a
//  ROM: two synthetic test images (GameViewPreview.swift) go through the real
//  layout geometry, and the normal game path is untouched.
//

import CoreGraphics
import Foundation
import SwiftUI
import UIKit

struct GameView: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var settings: AppSettings

    @Environment(\.displayScale) private var displayScale
    /// Scene phase for the multi-tasking privacy cover: while the app is not
    /// active (app switcher, lock screen, Control Center) the game is covered so
    /// its picture never appears in a system snapshot.
    @Environment(\.scenePhase) private var scenePhase

    @State private var isMenuPresented = false
    /// Round-4 in-game control editing: the pause menu closes, the runtime stays
    /// paused and the on-screen controls are dragged over the frozen picture.
    @State private var isEditingControls = false
    @State private var controlDraft: ControlLayoutProfile?
    /// The direction whose profile is being edited (fixed when edit mode opens).
    @State private var editingOrientation: ControlLayoutOrientation = .portrait
    @State private var sheet: GameSheet?
    /// Kept copy of the last diagnostics export (relative to Documents).
    @State private var diagnosticsHint: String?

    @State private var isConfirmationPresented = false
    @State private var confirmationKind: ConfirmationKind = .reset

    /// Round 0.1.6 app buttons: FF is a toggle (2x / the menu's normal speed)
    /// and the toast reports quick save/load results.
    @State private var fastForwardToggled = false
    @State private var quickSaveToast: String?

    private let topScreen = ZakuroScreen(which: 0)
    private let bottomScreen = ZakuroScreen(which: 1)

    /// ROM-free preview launch (`-previewGameView`); never set in normal use.
    private let isPreviewingGame = DebugLaunch.previewGameView
    /// `-previewLandscape` forces the landscape arrangement for screenshots.
    private let forcedLandscape = DebugLaunch.previewLandscape

    private enum ConfirmationKind {
        case reset
        case exit
    }

    /// One sheet slot for the pages the game view can present.
    private enum GameSheet: Identifiable {
        case quickDisplaySettings
        case settings
        case saveManager
        case diagnostics(URL)

        var id: String {
            switch self {
            case .quickDisplaySettings: return "quick-display"
            case .settings: return "settings"
            case .saveManager: return "save-manager"
            case .diagnostics(let url): return "diagnostics-\(url.path)"
            }
        }
    }

    private var isLoaded: Bool {
        if case .loaded = model.phase { return true }
        return false
    }

    private var romName: String { model.currentGame?.title ?? L10n.tr("Game") }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = forcedLandscape || geometry.size.width > geometry.size.height
            ZStack {
                gameBackground

                gameContent(isLandscape: isLandscape)

                if isMenuPresented {
                    InGameMenuView(
                        romName: romName,
                        titleID: model.currentGame?.titleID,
                        orientation: isLandscape ? .landscape : .portrait,
                        settings: settings,
                        saveStates: model.saveStates,
                        onResume: resumeGame,
                        onEditControls: { beginControlEditing(isLandscape: isLandscape) },
                        onReset: { requestConfirmation(.reset) },
                        onSettings: { sheet = .settings },
                        onExit: { requestConfirmation(.exit) },
                        onLoadStateCompleted: resumeAfterStateLoad
                    )
                    .transition(isLandscape
                                ? .scale(scale: 0.96).combined(with: .opacity)
                                : .move(edge: .bottom))
                    .zIndex(1)
                }

                // The 3DS software keyboard: the title waits on the applet and
                // the session has stopped the frame loop, so this overlay is the
                // only interactive surface. It covers the on-screen controls and
                // the pause button on purpose.
                if let request = model.keyboardRequest {
                    KeyboardOverlayView(request: request) { text, button in
                        model.answerKeyboard(text: text, button: button)
                    }
                    .zIndex(10)
                }

                // Multi-tasking privacy: the app switcher's snapshot and the
                // lock screen must not show the game. The opaque cover sits
                // above the menu and the keyboard overlay and disappears when
                // the scene is active again.
                if scenePhase != .active {
                    privacyCover
                        .zIndex(20)
                }
            }
            .onAppear {
                model.onHotkey = { action in
                    handleHotkey(action)
                }
                syncPresentedLayout(isLandscape)
                // Headless screenshot hooks; inert in normal launches.
                if DebugLaunch.previewPauseMenu {
                    isMenuPresented = true
                }
                if DebugLaunch.previewControlEdit {
                    beginControlEditing(isLandscape: isLandscape)
                }
            }
            .onChange(of: isLandscape) { newValue in
                syncPresentedLayout(newValue)
            }
            .onChange(of: model.currentGame?.titleID) { _ in
                syncPresentedLayout(isLandscape)
            }
            .onChange(of: settings.landscapeScreenLayout) { _ in
                syncPresentedLayout(isLandscape)
            }
            .onChange(of: settings.portraitScreenLayout) { _ in
                syncPresentedLayout(isLandscape)
            }
            .onChange(of: settings.playbackSpeed) { _ in
                // The menu's default speed overrides an active Turbo toggle.
                fastForwardToggled = false
                model.setTurboUnlimited(false)
                model.setPlaybackSpeed(settings.playbackSpeedValue)
            }
            .onChange(of: settings.turboSpeed) { _ in
                if fastForwardToggled {
                    if settings.turboLimit {
                        model.setTurboUnlimited(false)
                        model.setPlaybackSpeed(settings.turboSpeedValue)
                    } else {
                        model.setTurboUnlimited(true)
                    }
                }
            }
            .onChange(of: settings.turboLimit) { enabled in
                guard fastForwardToggled else { return }
                if enabled {
                    model.setTurboUnlimited(false)
                    model.setPlaybackSpeed(settings.turboSpeedValue)
                } else {
                    model.setTurboUnlimited(true)
                }
            }
            .onChange(of: settings.runSpeedLimit) { enabled in
                if !enabled {
                    fastForwardToggled = false
                    model.setTurboUnlimited(false)
                }
                model.setRunSpeedLimitEnabled(enabled)
            }
            .onChange(of: model.phase) { phase in
                switch phase {
                case .idle, .failed, .finished: fastForwardToggled = false
                default: break
                }
            }
            .onDisappear {
                model.onHotkey = nil
            }
        }
        .sheet(item: $sheet) { presentedSheet in
            switch presentedSheet {
            case .quickDisplaySettings:
                QuickDisplaySettingsView(settings: settings)
            case .settings:
                NavigationStack {
                    SettingsView(settings: settings, model: model)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { sheet = nil }
                            }
                        }
                }
            case .saveManager:
                NavigationStack {
                    SaveManagerView(
                        model: model,
                        saveStates: model.saveStates,
                        onLoadStateCompleted: resumeAfterStateLoad
                    )
                }
            case .diagnostics(let url):
                ShareSheet(items: [url])
            }
        }
        .alert(confirmationTitle, isPresented: $isConfirmationPresented) {
            Button(confirmationButtonTitle, role: .destructive) {
                performConfirmedAction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - Full-bleed layout

    /// The picture and the floating controls over it. Both orientations are the
    /// same ZStack: the screens fill the game view and everything else floats.
    private func gameContent(isLandscape: Bool) -> some View {
        ZStack {
            screenStage(isLandscape: isLandscape)

            if isEditingControls, let controlDraft {
                InGameControlEditOverlay(
                    profile: controlDraft,
                    isVisible: {
                        settings.isControlVisible($0, orientation: editingOrientation)
                    },
                    sizeScale: { settings.controlSizeScale(for: $0) },
                    opacityScale: settings.controlsBackgroundOpacity,
                    haptics: settings.haptics,
                    onMove: { element, point in moveControl(element, to: point) },
                    onDone: { finishControlEditing() }
                )
            } else if isLoaded || isRuntimeStarting || isPreviewingGame {
                controlsOverlay(isLandscape: isLandscape)
            }

            // The pause/FPS HUD is hidden while the controls are edited.
            if !isEditingControls {
                floatingHUD(isLandscape: isLandscape)
            }

            // Round 0.1.6 quick-save confirmation toast (never intercepts input).
            if let quickSaveToast, !isEditingControls {
                Text(quickSaveToast)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 76)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("quick-save-toast")
            }
        }
        .accessibilityIdentifier("screens")
    }

    /// The picture area: the whole game view, plain black, with no card styling.
    private func screenStage(isLandscape: Bool) -> some View {
        GeometryReader { geometry in
            screenContent(available: geometry.size, isLandscape: isLandscape)
        }
        .background(Color.black)
        .accessibilityIdentifier("screens-area")
    }

    /// The full-screen floating on-screen controls. They take no layout space, so
    /// hiding them never moves the picture.
    private func controlsOverlay(isLandscape: Bool) -> some View {
        VirtualControlsView(
            profile: settings.controlLayout(for: isLandscape ? .landscape : .portrait),
            opacityScale: settings.controlsBackgroundOpacity,
            deadzone: settings.effectiveAnalogDeadzone(titleID: presentationTitleID),
            highContrast: settings.effectiveControlAppearance(titleID: presentationTitleID) == .highContrast,
            haptics: settings.haptics,
            onButton: { bit, pressed in model.setOverlayButton(bit, pressed: pressed) },
            onCirclePad: { x, y in model.setOverlayStick(x: x, y: y) },
            onCStick: { x, y in model.setOverlayCStick(x: x, y: y) },
            isVisible: {
                settings.isControlVisible($0, orientation: isLandscape ? .landscape : .portrait)
            },
            sizeScale: { settings.controlSizeScale(for: $0) },
            onFastForward: { _ in toggleFastForward() },
            onQuickSave: { performQuickSave() },
            onQuickLoad: { performQuickLoad() },
            onSwapScreens: { performSwapScreens() },
            fastForwardActive: fastForwardToggled
        )
        .ignoresSafeArea()
        .opacity(showsTouchControls ? 1 : 0)
        .allowsHitTesting(showsTouchControls)
        .accessibilityIdentifier("touch-controls-overlay")
    }

    /// The floating FPS counter and pause button. Portrait keeps both in the
    /// top-trailing safe-area corner; landscape keeps the pause button at the
    /// bottom centre (the top corners belong to L/R).
    @ViewBuilder
    private func floatingHUD(isLandscape: Bool) -> some View {
        if isLoaded || isPreviewingGame {
            if isLandscape {
                if settings.showFPS {
                    fpsPill
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.horizontal, GameViewLayout.floatingHUDHorizontalPadding)
                        .padding(.top, GameViewLayout.floatingHUDTopPadding)
                }
                if !isMenuPresented {
                    pauseButton(size: GameViewLayout.floatingPauseSize)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, GameViewLayout.landscapePauseBottomPadding)
                }
            } else {
                HStack(spacing: GameViewLayout.floatingHUDSpacing) {
                    if settings.showFPS {
                        fpsPill
                    }
                    pauseButton(size: GameViewLayout.floatingPauseSize)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.horizontal, GameViewLayout.floatingHUDHorizontalPadding)
                .padding(.top, GameViewLayout.floatingHUDTopPadding)
            }
        }
    }

    private var gameBackground: some View {
        Color.black.ignoresSafeArea()
    }

    /// Records the arrangement of this device direction in the session: the
    /// presenter arrangement, or the requirement to skip the presenter and draw
    /// the picture through the readback path.
    /// The running game's title ID and its effective (per-game override or
    /// global) presentation values. 0.2.0 MVP overrides are keyed by title ID.
    private var presentationTitleID: String? { model.currentGame?.titleID }
    private var presentedScreenRotation: ScreenRotation {
        settings.effectiveScreenRotation(titleID: presentationTitleID)
    }
    private var presentedIntegerScale: Bool {
        settings.effectiveIntegerScale(titleID: presentationTitleID)
    }
    private var presentedSwapScreens: Bool {
        settings.effectiveSwapScreens(titleID: presentationTitleID)
    }
    private var presentedScreenAspect: ScreenAspect {
        settings.effectiveScreenAspect(titleID: presentationTitleID)
    }

    private func syncPresentedLayout(_ isLandscape: Bool) {
        let layout = settings.effectiveScreenLayout(isLandscape: isLandscape)
        if model.screenLayout != layout {
            model.setScreenLayout(layout)
        }
        model.setReadbackPresentationRequired(
            settings.usesReadbackPresentation(isLandscape: isLandscape)
        )
        model.setScreenSwap(presentedSwapScreens)
        model.setScreenRotation(presentedScreenRotation)
        model.setIntegerScaling(presentedIntegerScale)
        // The GPU custom layout needs the current direction's rectangles; every
        // other preset ignores this.
        model.setCustomScreenPlacement(
            settings.customScreenLayout.placement(for: isLandscape ? .landscape : .portrait)
        )
    }

    // MARK: - Menu

    /// Glass pause button; opens the in-game menu and pauses the runtime.
    private func pauseButton(size: CGFloat) -> some View {
        Button {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                isMenuPresented = true
            }
            // The preview has no runtime to pause.
            if !isPreviewingGame {
                model.pauseForMenu()
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.38)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        }
        .accessibilityIdentifier("in-game-menu")
    }

    // MARK: - In-game control editing (round 4)

    /// Opens the in-game control edit mode. The pause menu already paused the
    /// runtime, so this only closes the menu and keeps that pause in place.
    private func beginControlEditing(isLandscape: Bool) {
        let orientation: ControlLayoutOrientation = isLandscape ? .landscape : .portrait
        editingOrientation = orientation
        controlDraft = settings.controlLayout(for: orientation)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            isMenuPresented = false
        }
        isEditingControls = true
    }

    /// One control was dragged: update the draft placement (normalised to the
    /// overlay container).
    private func moveControl(_ element: ControlElement, to point: CGPoint) {
        guard let draft = controlDraft else { return }
        if element.isDpadDirection {
            // The D-pad is one cross: drag any of its arms and the four
            // directional placements translate together.
            controlDraft = draft.movingDpadGroupNormalized(to: point)
            return
        }
        var next = draft
        var placement = next.placement(for: element)
        placement.x = Double(min(max(point.x, 0), 1))
        placement.y = Double(min(max(point.y, 0), 1))
        next.setPlacement(placement, for: element)
        controlDraft = next
    }

    /// Done: save the edited profile as the Custom layout for the direction,
    /// leave edit mode and resume the game directly (it stayed paused since the
    /// menu opened it, so there is no extra pause/resume).
    private func finishControlEditing() {
        guard isEditingControls else { return }
        if let draft = controlDraft {
            settings.setControlLayout(draft, for: editingOrientation)
            settings.controlLayoutMode = .custom
            settings.persist()
        }
        controlDraft = nil
        isEditingControls = false
        if !isPreviewingGame {
            model.resumeFromMenu()
        }
    }

    // MARK: - Physical controller hotkeys

    /// Executes a physical 2–4 button hotkey. The GameControllerManager has
    /// already suppressed the combination from the guest while it is held.
    private func handleHotkey(_ action: HotkeyAction) {
        switch action {
        case .toggleTurbo:
            toggleFastForward()
        case .quickSave:
            performQuickSave()
        case .quickLoad:
            performQuickLoad()
        case .swapScreens:
            performSwapScreens()
        case .rotateScreen:
            rotateScreensClockwise()
        case .openMenu:
            guard !isMenuPresented, !isEditingControls else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                isMenuPresented = true
            }
            if !isPreviewingGame {
                model.pauseForMenu()
            }
        }
    }

    /// Rotate the screen in 90° steps, updating a per-app override when one is
    /// active (same rule as the in-game menu's Rotate clockwise row).
    private func rotateScreensClockwise() {
        let current = settings.effectiveScreenRotation(titleID: presentationTitleID)
        let next: ScreenRotation
        switch current {
        case .upright: next = .clockwise
        case .clockwise: next = .upsideDown
        case .upsideDown: next = .counterClockwise
        case .counterClockwise: next = .upright
        }
        if let titleID = presentationTitleID,
           var overrides = settings.overrides(for: titleID) {
            overrides.screenRotationRaw = next.rawValue
            settings.setPerGameOverrides(overrides, for: titleID)
        } else {
            settings.screenRotation = next
            settings.persist()
        }
    }

    /// Round 0.1.6-beta2 Turbo button: one tap switches the runtime to the
    /// configured Turbo speed (or unlimited guest frames when Turbo limit is
    /// off), the next tap restores the menu's Default speed. With Run speed
    /// limit off the runtime is already unlimited, so the button does nothing.
    private func toggleFastForward() {
        guard settings.runSpeedLimit else { return }
        fastForwardToggled.toggle()
        if fastForwardToggled {
            if settings.turboLimit {
                model.setTurboUnlimited(false)
                model.setPlaybackSpeed(settings.turboSpeedValue)
            } else {
                model.setTurboUnlimited(true)
            }
        } else {
            model.setTurboUnlimited(false)
            model.setPlaybackSpeed(settings.playbackSpeedValue)
        }
        if settings.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// A quick load of the quick slot, with a short toast on success.
    private func performQuickLoad() {
        guard model.saveStates.canLoad else { return }
        model.saveStates.load(slot: SaveStateSupport.quickSlot) { result in
            guard case .success = result else { return }
            if settings.haptics {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            showToast(L10n.tr("Quick loaded"))
        }
    }

    /// Swap screens: toggles the persisted setting; the session applies it to
    /// the GPU presenter immediately (the readback fallback swaps the images).
    private func performSwapScreens() {
        let current = settings.effectiveSwapScreens(titleID: presentationTitleID)
        if var overrides = settings.overrides(for: presentationTitleID) {
            overrides.swapScreens = !current
            settings.setPerGameOverrides(overrides, for: presentationTitleID ?? "")
        } else {
            settings.swapScreens = !current
            settings.persist()
        }
        model.setScreenSwap(!current)
        if settings.haptics {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.12)) {
            quickSaveToast = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeIn(duration: 0.18)) {
                quickSaveToast = nil
            }
        }
    }

    /// Round 0.1.6 Quick-save button: save to the existing quick slot and show a
    /// short toast; an unavailable save is a silent no-op.
    private func performQuickSave() {
        guard model.saveStates.canSave else { return }
        model.saveStates.save(slot: SaveStateSupport.quickSlot)
        if settings.haptics {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        showToast(L10n.tr("Quick saved"))
    }

    private func resumeGame() {
        // A save or load is mid-serialization on the runtime queue; let it
        // finish (the menu disables Resume meanwhile, this is the guard).
        guard !model.saveStates.busy else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            isMenuPresented = false
        }
        model.resumeFromMenu()
    }

    /// A state load succeeded: close the menu/sheet and continue the restored
    /// console. The game view keeps the last frame on screen until the next
    /// frame draws, and SaveStateSupport already dropped the audio buffered
    /// before the load.
    private func resumeAfterStateLoad() {
        sheet = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            isMenuPresented = false
        }
        model.resumeFromMenu()
    }

    private func requestConfirmation(_ kind: ConfirmationKind) {
        confirmationKind = kind
        isConfirmationPresented = true
    }

    private func performConfirmedAction() {
        guard !model.saveStates.busy else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            isMenuPresented = false
        }
        switch confirmationKind {
        case .reset:
            model.resetRuntime()
        case .exit:
            model.unload()
        }
    }

    private var confirmationTitle: String {
        switch confirmationKind {
        case .reset: return L10n.tr("Reset the game?")
        case .exit: return L10n.tr("Exit to home?")
        }
    }

    private var confirmationButtonTitle: String {
        switch confirmationKind {
        case .reset: return L10n.tr("Reset")
        case .exit: return L10n.tr("Exit")
        }
    }

    private var confirmationMessage: String {
        switch confirmationKind {
        case .reset:
            return L10n.tr("The game restarts from the beginning. Battery saves are kept.")
        case .exit:
            return L10n.tr("The runtime is released and the game closes. Save data stays on the device.")
        }
    }

    // MARK: - Multi-tasking privacy

    /// Opaque cover shown while the scene is not active: the app switcher's
    /// snapshot and the lock screen show this instead of the game.
    private var privacyCover: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(L10n.tr("Paused"))
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .accessibilityIdentifier("background-privacy-cover")
    }

    // MARK: - Screens

    /// True while the screens should come from the CAMetalLayer: a presented
    /// load is running, or one is about to and the Metal view already exists.
    private var usesPresentedSurface: Bool {
        model.displayPath.usesMetalLayer
            || (isRuntimeStarting && model.metalScreenView != nil)
    }

    /// The screens inside `available`: the presented layer for the presenter
    /// arrangements, and the app's own placement for the custom layouts or the
    /// preview/emergency-fallback path.
    @ViewBuilder
    private func screenContent(available: CGSize, isLandscape: Bool) -> some View {
        if available.width >= 1, available.height >= 1 {
            if usesPresentedSurface, let metalView = model.metalScreenView {
                // A1: the presenter draws the chosen arrangement into the app's
                // CAMetalLayer; SwiftUI centres the layer and CoreAnimation
                // scales it into the box.
                let layout = settings.effectiveScreenLayout(isLandscape: isLandscape)
                // A custom GPU layout fills the whole game-view stage (the
                // presenter draws the two screens at their user rectangles); the
                // arrangements keep their fitted box.
                let box = layout == .custom ? available : contentSize(in: available, layout: layout)
                ZStack {
                    presentedSurface(view: metalView, size: box)
                }
                // Portrait arrangements are top-aligned under the safe area (the
                // original portrait layout shows the console stack at the top);
                // landscape arrangements and the full-stage custom layout are
                // centred.
                .frame(width: available.width,
                       height: available.height,
                       alignment: isLandscape || layout == .custom ? .center : .top)
            } else {
                readbackArrangement(in: available, isLandscape: isLandscape)
            }
        } else {
            Color.black
        }
    }

    private func presentedSurface(view: MetalScreenView, size: CGSize) -> some View {
        MetalScreenRepresentable(view: view)
            .frame(width: size.width, height: size.height)
            .overlay { metalFirstFramePlaceholder }
            .overlay { presentedTouchOverlay }
            .accessibilityIdentifier("metal-screen")
    }

    /// Readback path: the screen images placed by the same geometry the layout
    /// editors preview. A custom layout uses the whole game view as its
    /// placement stage; the emergency/preview path mirrors the presenter
    /// arrangement (fit/stretch, rotation, centring and, for hybrid, the second
    /// copy of the upper screen).
    @ViewBuilder
    private func readbackArrangement(in area: CGSize, isLandscape: Bool) -> some View {
        let orientation: ControlLayoutOrientation = isLandscape ? .landscape : .portrait
        if let viewports = PresetScreenGeometry.readbackViewports(
            settings: settings,
            orientation: orientation,
            stage: area,
            rotation: presentedScreenRotation,
            displayScale: displayScale,
            integerScale: presentedIntegerScale
        ) {
            readbackScreens(viewports, layoutBox: area, area: area,
                            stretches: false, alignTop: false)
        } else {
            let layout = settings.effectiveScreenLayout(isLandscape: isLandscape)
            let stretch = presentedScreenAspect == .stretch
            let arrangementAspect = ScreenGeometry.contentAspect(
                layout: layout,
                rotation: presentedScreenRotation
            )
            // Fit/4:3 and integer scaling: the content box from the settings,
            // which keeps the arrangement's aspect and may be snapped to whole
            // pixels. Stretch places the arrangement first and scales it to the
            // area after (CoreAnimation does the same to the presented layer).
            let layoutBox: CGSize = stretch
                ? ScreenGeometry.fittedSize(aspect: arrangementAspect, in: area)
                : contentSize(in: area, layout: layout)
            let viewports = ScreenGeometry.layoutViewports(
                available: layoutBox,
                layout: layout,
                rotation: presentedScreenRotation
            )
            // Portrait arrangements are top-aligned under the safe area, like
            // the presented layer; a stretched arrangement always fills the area.
            readbackScreens(viewports, layoutBox: layoutBox, area: area,
                            stretches: stretch, alignTop: !isLandscape)
        }
    }

    /// Draws the screen images at their viewports. The hybrid arrangement draws
    /// the upper screen twice (the large one and the small one in the right
    /// column); every other arrangement has one upper and one lower viewport.
    /// The presenter-mirror path passes `stretches: true` only for the Stretch
    /// aspect setting (the arrangement is fitted first and then fills the area,
    /// like CoreAnimation scaling the presented layer); every other mode shows
    /// the fitted box centred in the area with black around it.
    private func readbackScreens(_ viewports: (top: CGRect?, bottom: CGRect?, topSmall: CGRect?),
                                 layoutBox: CGSize,
                                 area: CGSize,
                                 stretches: Bool,
                                 alignTop: Bool) -> some View {
        let stretchX = stretches && layoutBox.width > 0 ? area.width / layoutBox.width : 1
        let stretchY = stretches && layoutBox.height > 0 ? area.height / layoutBox.height : 1
        return ZStack(alignment: .topLeading) {
            Color.clear
            let swapped = presentedSwapScreens
            if let top = viewports.top {
                readbackScreen(
                    image: screenImage(isUpper: !swapped),
                    screen: swapped ? bottomScreen : topScreen,
                    identifier: "top-screen",
                    isTouchscreen: swapped
                )
                .frame(width: top.width, height: top.height)
                .offset(x: top.minX, y: top.minY)
            }
            // Hybrid draws the upper screen a second time as the small top
            // screen above the small bottom screen in the right column.
            if let topSmall = viewports.topSmall {
                readbackScreen(
                    image: screenImage(isUpper: !swapped),
                    screen: swapped ? bottomScreen : topScreen,
                    identifier: "top-small-screen",
                    isTouchscreen: false
                )
                .frame(width: topSmall.width, height: topSmall.height)
                .offset(x: topSmall.minX, y: topSmall.minY)
            }
            if let bottom = viewports.bottom {
                readbackScreen(
                    image: screenImage(isUpper: swapped),
                    screen: swapped ? topScreen : bottomScreen,
                    identifier: "bottom-screen",
                    isTouchscreen: !swapped
                )
                .frame(width: bottom.width, height: bottom.height)
                .offset(x: bottom.minX, y: bottom.minY)
            }
        }
        .frame(width: layoutBox.width, height: layoutBox.height, alignment: .topLeading)
        .scaleEffect(x: stretchX, y: stretchY)
        .frame(width: area.width, height: area.height,
               alignment: alignTop ? .top : .center)
    }

    /// The frame the readback path (and the preview) shows for one screen.
    private func screenImage(isUpper: Bool) -> CGImage? {
        if isPreviewingGame {
            return isUpper ? DebugPreviewScreens.upper : DebugPreviewScreens.lower
        }
        return isUpper ? model.topScreenImage : model.bottomScreenImage
    }

    /// One screen's image in its viewport, turned with the screen rotation
    /// setting. The gesture on the lower screen is attached inside the turn, so
    /// the touch position is reported in the 3DS screen's own upright pixels.
    private func readbackScreen(
        image: CGImage?,
        screen: ZakuroScreen,
        identifier: String,
        isTouchscreen: Bool
    ) -> some View {
        let rotation = presentedScreenRotation
        return ZStack {
            Color.black
            if let image {
                rotatedScreenImage(image, rotation: rotation)
            }
            if isTouchscreen {
                bottomTouchOverlay(rotation: rotation)
            }
        }
        .accessibilityIdentifier(identifier)
    }

    /// The screen picture turned by `rotation`. The inner frame uses the
    /// unrotated shape, so a quarter turn fills the (swapped) viewport.
    private func rotatedScreenImage(_ image: CGImage, rotation: ScreenRotation) -> some View {
        GeometryReader { geometry in
            let quarterTurn = rotation == .clockwise || rotation == .counterClockwise
            let innerWidth = quarterTurn ? geometry.size.height : geometry.size.width
            let innerHeight = quarterTurn ? geometry.size.width : geometry.size.height
            Image(decorative: image, scale: 1.0)
                .resizable()
                .scaledToFit()
                .frame(width: innerWidth, height: innerHeight)
                .rotationEffect(.degrees(rotationDegrees(rotation)))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
    }

    private func rotationDegrees(_ rotation: ScreenRotation) -> Double {
        switch rotation {
        case .upright: return 0
        case .clockwise: return 90
        case .upsideDown: return 180
        case .counterClockwise: return -90
        }
    }

    /// No placeholder text is drawn while the first frame is pending
    /// (0.1.6-beta3 removed the last startup placeholder label).
    private var metalFirstFramePlaceholder: some View {
        EmptyView()
    }

    // MARK: - Screen geometry

    /// The picture's box inside `available`, from the display settings (used for
    /// the presenter arrangements; the custom layouts place their screens
    /// explicitly in the whole game view).
    private func contentSize(in available: CGSize, layout: ScreenLayout) -> CGSize {
        ScreenGeometry.contentSize(
            available: available,
            layout: layout,
            rotation: presentedScreenRotation,
            aspect: presentedScreenAspect,
            integerScale: presentedIntegerScale,
            displayScale: displayScale
        )
    }

    // MARK: - Touchscreen

    /// A1: touch on the presented layer. The layer shows the whole arrangement
    /// the display settings chose; the runtime maps the normalised point with the
    /// same layout/rotation and ignores touches that are not on the lower screen.
    private var presentedTouchOverlay: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isTouchscreenEnabled else { return }
                            let width = max(geometry.size.width, 1)
                            let height = max(geometry.size.height, 1)
                            model.setPresentedTouch(
                                normalisedX: value.location.x / width,
                                normalisedY: value.location.y / height
                            )
                        }
                        .onEnded { _ in
                            model.setTouchPoint(x: nil, y: nil)
                        }
                )
        }
    }

    /// Drag/tap on a readback lower-screen image sends 3DS touchscreen
    /// coordinates in lower-screen pixels while a runtime is loaded. `rotation`
    /// is the screen's display turn: the touch is mapped back into the screen's
    /// own upright pixels, like the presented path does in the runtime.
    private func bottomTouchOverlay(rotation: ScreenRotation) -> some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isTouchscreenEnabled else { return }
                            let point = bottomScreenPoint(
                                value.location,
                                in: geometry.size,
                                rotation: rotation
                            )
                            model.setTouchPoint(x: point.x, y: point.y)
                        }
                        .onEnded { _ in
                            model.setTouchPoint(x: nil, y: nil)
                        }
                )
        }
    }

    private var isTouchscreenEnabled: Bool { isLoaded }

    private func bottomScreenPoint(
        _ location: CGPoint,
        in size: CGSize,
        rotation: ScreenRotation
    ) -> (x: UInt16, y: UInt16) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let shownX = min(max(location.x / width, 0), 1)
        let shownY = min(max(location.y / height, 0), 1)
        // Undo the display turn: the same mapping the presenter uses for a
        // rotated screen, so a touch lands where the picture shows it.
        let normalisedX: CGFloat
        let normalisedY: CGFloat
        switch rotation {
        case .upright:
            normalisedX = shownX
            normalisedY = shownY
        case .clockwise:
            normalisedX = shownY
            normalisedY = 1 - shownX
        case .upsideDown:
            normalisedX = 1 - shownX
            normalisedY = 1 - shownY
        case .counterClockwise:
            normalisedX = 1 - shownY
            normalisedY = shownX
        }
        let pixelsX = normalisedX * CGFloat(Int(bottomScreen.width))
        let pixelsY = normalisedY * CGFloat(Int(bottomScreen.height))
        return (
            UInt16(clamping: Int(pixelsX.rounded())),
            UInt16(clamping: Int(pixelsY.rounded()))
        )
    }

    // MARK: - Derived state

    /// Whether the on-screen controls are visible right now.
    private var showsTouchControls: Bool {
        settings.showTouchControls && !model.isPaused
    }

    /// True while a ROM is being loaded: zk_create runs, or the first frames
    /// arrive. The legacy `.preparing` phase is accepted too (unreachable since
    /// the warm-up option was removed in 0.1.1).
    private var isRuntimeStarting: Bool {
        if case .starting = model.phase { return true }
        if case .preparing = model.phase { return true }
        return false
    }

    // MARK: - FPS (the only in-game HUD)

    /// Presented frames per second, e.g. `59 fps`. The only performance readout
    /// the game view draws: a translucent floating pill in the top-trailing
    /// safe-area corner. The AOT state, renderer path and the CPU/present/read
    /// timing breakdown stay in the log and the diagnostics export.
    private var fpsPill: some View {
        Text(fpsText)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.42)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("fps-hud")
            .accessibilityLabel(L10n.format("Frames per second: %@", fpsText))
    }

    private var fpsText: String {
        // The preview has no runtime; a representative value keeps the pill
        // looking like the real thing in a screenshot.
        isPreviewingGame ? "60 fps" : model.fpsText
    }

    // MARK: - Diagnostics

    private func exportDiagnostics() {
        guard let export = DiagnosticsExporter.write(model: model, settings: settings) else { return }
        // The share sheet keeps working exactly as before; the same file is also
        // kept in Documents/Diagnostics and its path is shown in the paused menu
        // (and the app log) so it can be fetched later from the Files app.
        diagnosticsHint = export.documentsPath.map { "Saved to Documents/\($0)" }
        sheet = .diagnostics(export.shareURL)
    }
}