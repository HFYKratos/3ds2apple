//
//  GameView.swift
//  3ds2apple
//
//  The running game: the two 3DS screens on the CAMetalLayer (or the CGImage
//  readback fallback), the on-screen controls and the in-game overlay menu.
//
//  The view is responsive:
//
//  - portrait: the screens in a card, the on-screen pad below it (scrollable);
//  - landscape: a top bar (Select/Start), the shoulder buttons and the two
//    button clusters in reserved side rails, and the screens in the space
//    between them, so no button covers a screen. The display settings pick the
//    layout (stacked / side by side / single screen), the rotation and how the
//    picture fills its area; the CAMetalLayer presenter draws all of them.
//
//  The "Preparing graphics" overlay from the first-run warm-up stays on top of
//  the screens while the initial GPU pipelines compile. Opening the in-game
//  menu pauses emulation; the runtime and the last frame stay until resume.
//

import CoreGraphics
import Foundation
import SwiftUI
import UIKit

struct GameView: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var settings: AppSettings

    @Environment(\.displayScale) private var displayScale

    @State private var isMenuPresented = false
    @State private var sheet: GameSheet?

    @State private var isConfirmationPresented = false
    @State private var confirmationKind: ConfirmationKind = .reset

    private let topScreen = ZakuroScreen(which: 0)
    private let bottomScreen = ZakuroScreen(which: 1)

    private enum ConfirmationKind {
        case reset
        case exit
    }

    /// One sheet slot for the pages the game view can present.
    private enum GameSheet: Identifiable {
        case quickDisplaySettings
        case saveManager
        case diagnostics(URL)

        var id: String {
            switch self {
            case .quickDisplaySettings: return "quick-display"
            case .saveManager: return "save-manager"
            case .diagnostics(let url): return "diagnostics-\(url.path)"
            }
        }
    }

    private var isLoaded: Bool {
        if case .loaded = model.phase { return true }
        return false
    }

    private var romName: String { model.lastROM?.name ?? L10n.tr("Game") }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            ZStack {
                gameBackground

                if isLandscape {
                    landscapeContent
                } else {
                    portraitContent
                }

                if isMenuPresented {
                    InGameMenuView(
                        romName: romName,
                        settings: settings,
                        saveStates: model.saveStates,
                        onResume: resumeGame,
                        onReset: { requestConfirmation(.reset) },
                        onDisplaySettings: { sheet = .quickDisplaySettings },
                        onSaveManager: { sheet = .saveManager },
                        onDiagnostics: exportDiagnostics,
                        onExit: { requestConfirmation(.exit) },
                        onLoadStateCompleted: resumeAfterStateLoad
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .quickDisplaySettings:
                QuickDisplaySettingsView(settings: settings)
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

    // MARK: - Portrait layout

    private var portraitContent: some View {
        VStack(spacing: 10) {
            if isLoaded {
                portraitTopBar
            }

            if isShowingScreens {
                screenStage
                    .frame(maxHeight: .infinity)
                    .accessibilityIdentifier("screens")

                // Keep the controls in the layout even when hidden, so the
                // picture keeps its position and size.
                TouchControlsView(
                    backgroundOpacity: settings.controlsBackgroundOpacity,
                    haptics: settings.haptics
                ) { bit, pressed in
                    model.setOverlayButton(bit, pressed: pressed)
                }
                .padding(.horizontal, 2)
                .opacity(showsTouchControls ? 1 : 0)
                .allowsHitTesting(showsTouchControls)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Title + pause button above the screens in portrait. Kept on the black
    /// background instead of over the picture, so nothing covers the 3DS image.
    private var portraitTopBar: some View {
        HStack(spacing: 10) {
            Text(romName)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)
            Spacer(minLength: 8)
            pauseButton(size: 36)
        }
        .frame(height: 36)
    }

    /// The picture area: rounded, subtly bordered black stage that centres the
    /// scaled 3DS screens and carries the warm-up cover.
    private var screenStage: some View {
        GeometryReader { geometry in
            screenContent(available: geometry.size)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8)
        .overlay { graphicsWarmUpOverlay }
        .accessibilityIdentifier("screens-area")
    }

    private var gameBackground: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color(red: 0.06, green: 0.10, blue: 0.13), .black],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            .opacity(0.85)
        }
        .ignoresSafeArea()
    }

    // MARK: - Landscape layout

    private var landscapeContent: some View {
        ZStack {
            screenStage
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .accessibilityIdentifier("screens-area")

            // Edge-to-edge controls float over the picture (handheld-skin style)
            // and take no layout space: hiding them never moves the image.
            if isLoaded {
                LandscapeOverlayControls(
                    backgroundOpacity: settings.controlsBackgroundOpacity,
                    haptics: settings.haptics
                ) { bit, pressed in
                    model.setOverlayButton(bit, pressed: pressed)
                }
                .opacity(showsTouchControls ? 1 : 0)
                .allowsHitTesting(showsTouchControls)
            }

            if isLoaded && !isMenuPresented {
                // Bottom centre: the top corners belong to L/R and the top middle
                // to Select/Start, so the pause button stays clear of all of them.
                pauseButton(size: 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
            }
        }
        .ignoresSafeArea(edges: [.horizontal])
        .accessibilityIdentifier("screens")
    }
    // MARK: - Menu

    /// Glass pause button; opens the in-game menu and pauses the runtime.
    private func pauseButton(size: CGFloat) -> some View {
        Button {
            isMenuPresented = true
            model.pauseForMenu()
        } label: {
            Image(systemName: "pause.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 1))
        }
        .accessibilityIdentifier("in-game-menu")
    }
    private func resumeGame() {
        // A save or load is mid-serialization on the runtime queue; let it
        // finish (the menu disables Resume meanwhile, this is the guard).
        guard !model.saveStates.busy else { return }
        isMenuPresented = false
        model.resumeFromMenu()
    }

    /// A state load succeeded: close the menu/sheet and continue the restored
    /// console. The game view keeps the last frame on screen until the next
    /// frame draws, and SaveStateSupport already dropped the audio buffered
    /// before the load.
    private func resumeAfterStateLoad() {
        sheet = nil
        isMenuPresented = false
        model.resumeFromMenu()
    }

    private func requestConfirmation(_ kind: ConfirmationKind) {
        confirmationKind = kind
        isConfirmationPresented = true
    }

    private func performConfirmedAction() {
        guard !model.saveStates.busy else { return }
        isMenuPresented = false
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
            return L10n.tr("The game restarts from the beginning with the current ROM. Battery saves are kept.")
        case .exit:
            return L10n.tr("The runtime is released and the game closes. Imported ROMs and save data stay on the device.")
        }
    }

    // MARK: - Screens

    /// True while the screens should come from the CAMetalLayer: a presented
    /// load is running, or one is about to and the Metal view already exists.
    private var usesPresentedSurface: Bool {
        model.displayPath.usesMetalLayer
            || (isRuntimeStarting && model.metalScreenView != nil)
    }

    /// The screens inside `available`: the picture's box comes from the display
    /// settings (layout, rotation, aspect, integer scaling), centred in the
    /// available space. The CAMetalLayer draws every layout; the two screen
    /// images are the fallback when no presenter could be made.
    @ViewBuilder
    private func screenContent(available: CGSize) -> some View {
        if available.width >= 1, available.height >= 1 {
            let box = contentSize(in: available)
            ZStack {
                if usesPresentedSurface, let metalView = model.metalScreenView {
                    presentedSurface(view: metalView, size: box)
                } else {
                    readbackArrangement(in: available)
                }
            }
            .frame(width: available.width, height: available.height)
        } else {
            Color.black
        }
    }

    /// A1: Zakuro's presenter draws the chosen arrangement into the app's
    /// CAMetalLayer; SwiftUI centres the layer and CoreAnimation scales it into
    /// the box. Touch is mapped to 3DS touchscreen pixels by the runtime with the
    /// same layout the presenter uses.
    private func presentedSurface(view: MetalScreenView, size: CGSize) -> some View {
        MetalScreenRepresentable(view: view)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { metalFirstFramePlaceholder }
            .overlay { presentedTouchOverlay }
            .accessibilityIdentifier("metal-screen")
    }

    /// Readback path: the two screens as separate images, placed like the
    /// presenter places them (same layout, rotation, fit and centring). Only
    /// used when no presenter can be made. Stretch scales the placed
    /// arrangement to fill the area, which is what CoreAnimation does to the
    /// presented layer.
    private func readbackArrangement(in area: CGSize) -> some View {
        let stretch = settings.screenAspect == .stretch
        let arrangementAspect = ScreenGeometry.contentAspect(
            layout: settings.screenLayout,
            rotation: settings.screenRotation
        )
        // Fit/4:3 and integer scaling: the content box from the settings, which
        // keeps the arrangement's aspect and may be snapped to whole pixels.
        // Stretch places the arrangement first and scales it to the area after.
        let layoutBox = stretch
            ? ScreenGeometry.fittedSize(aspect: arrangementAspect, in: area)
            : contentSize(in: area)
        let viewports = ScreenGeometry.layoutViewports(
            available: layoutBox,
            layout: settings.screenLayout,
            rotation: settings.screenRotation
        )
        let stretchX = layoutBox.width > 0 ? area.width / layoutBox.width : 1
        let stretchY = layoutBox.height > 0 ? area.height / layoutBox.height : 1
        return ZStack(alignment: .topLeading) {
            Color.clear
            if let top = viewports.top {
                readbackScreen(
                    image: model.topScreenImage,
                    screen: topScreen,
                    identifier: "top-screen",
                    isTouchscreen: false
                )
                .frame(width: top.width, height: top.height)
                .offset(x: top.minX, y: top.minY)
            }
            if let bottom = viewports.bottom {
                readbackScreen(
                    image: model.bottomScreenImage,
                    screen: bottomScreen,
                    identifier: "bottom-screen",
                    isTouchscreen: true
                )
                .frame(width: bottom.width, height: bottom.height)
                .offset(x: bottom.minX, y: bottom.minY)
            }
        }
        .frame(width: layoutBox.width, height: layoutBox.height, alignment: .topLeading)
        .scaleEffect(x: stretchX, y: stretchY)
        .frame(width: area.width, height: area.height)
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
        let rotation = settings.screenRotation
        return ZStack {
            Color.black
            if let image {
                rotatedScreenImage(image, rotation: rotation)
            } else {
                Text(isRuntimeStarting ? L10n.tr("Starting Zakuro…") : L10n.tr("Waiting for first frame…"))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.65))
            }
            if isTouchscreen {
                bottomTouchOverlay(rotation: rotation)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    @ViewBuilder
    private var metalFirstFramePlaceholder: some View {
        if model.frameStats.frames == 0 {
            Text(isRuntimeStarting ? L10n.tr("Starting Zakuro…") : L10n.tr("Waiting for first frame…"))
                .font(.caption)
                .foregroundColor(.white.opacity(0.65))
        }
    }

    /// Opaque cover over the screens while the first GPU pipelines compile, so
    /// the boot-time compiles happen on a loading screen instead of a visible
    /// freeze. It disappears when the app reveals the game (phase `.loaded`).
    @ViewBuilder
    private var graphicsWarmUpOverlay: some View {
        if isPreparingGraphics {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.94))
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Preparing graphics…")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(model.warmUp.progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.75))
                    Text("The first frames compile and cache the GPU pipelines so gameplay starts smooth. This optional step is skipped on later loads when the cache is warm.")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button("Skip") {
                        model.skipGraphicsWarmUp()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                    .accessibilityIdentifier("warmup-skip")
                }
                .padding()
            }
            .accessibilityIdentifier("preparing-graphics")
        }
    }

    // MARK: - Screen geometry

    /// Aspect of the area the screens occupy in portrait. Fit keeps the
    /// arrangement's own shape; 4:3 and Stretch use a 4:3 box (Stretch fills it).
    private var screenFrameAspect: CGFloat {
        switch settings.screenAspect {
        case .fit:
            return ScreenGeometry.contentAspect(
                layout: settings.screenLayout,
                rotation: settings.screenRotation
            )
        case .fourThree, .stretch:
            return 4.0 / 3.0
        }
    }

    /// The picture's box inside `available`, from the display settings.
    private func contentSize(in available: CGSize) -> CGSize {
        ScreenGeometry.contentSize(
            available: available,
            layout: settings.screenLayout,
            rotation: settings.screenRotation,
            aspect: settings.screenAspect,
            integerScale: settings.integerScale,
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
        settings.showTouchControls && !isPreparingGraphics && !model.isPaused
    }

    /// Show the screens from the moment the runtime is loaded (placeholder
    /// until the first frame) and keep the last frame visible afterwards.
    private var isShowingScreens: Bool {
        if model.topScreenImage != nil { return true }
        if isLoaded { return true }
        if isPreparingGraphics { return true }
        if isRuntimeStarting { return true }
        if model.displayPath.usesMetalLayer, model.metalScreenView != nil { return true }
        return false
    }

    /// True while a ROM is being loaded: zk_create runs, or the first frames
    /// run behind the "Preparing graphics" overlay.
    private var isRuntimeStarting: Bool {
        if case .starting = model.phase { return true }
        if case .preparing = model.phase { return true }
        return false
    }

    /// True while the graphics warm-up overlay covers the screens.
    private var isPreparingGraphics: Bool {
        if case .preparing = model.phase { return true }
        return false
    }

    // MARK: - Diagnostics

    private func exportDiagnostics() {
        if let url = DiagnosticsExporter.write(model: model, settings: settings) {
            sheet = .diagnostics(url)
        }
    }
}
