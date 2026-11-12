//
//  GameView.swift
//  3ds2apple
//
//  The running game: the two 3DS screens on the CAMetalLayer (or the CGImage
//  readback fallback), the performance HUD, the on-screen controls and the
//  in-game overlay menu.
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
                Color.black.ignoresSafeArea()

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
            .overlay(alignment: .topTrailing) {
                if isLoaded && !isMenuPresented && !isLandscape {
                    menuButton
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
        ScrollView {
            VStack(spacing: 10) {
                screenCard
                frameStatusLine
                if settings.showCustomHUD {
                    performanceHUD
                }
            }
            .padding(12)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var screenCard: some View {
        if isShowingScreens {
            VStack(spacing: 8) {
                portraitScreenArea
                    .overlay { graphicsWarmUpOverlay }

                audioFailureLine

                if showsTouchControls {
                    TouchControlsView(
                        backgroundOpacity: settings.controlsBackgroundOpacity,
                        haptics: settings.haptics
                    ) { bit, pressed in
                        model.setOverlayButton(bit, pressed: pressed)
                    }
                }

                inputStatusLine
            }
            .accessibilityIdentifier("screens")
        }
    }

    /// The screens in portrait: an area whose shape follows the aspect setting
    /// (the picture's own shape for Fit, 4:3 for 4:3 and Stretch), with the
    /// picture fitted/stretched and integer-scaled inside it.
    private var portraitScreenArea: some View {
        GeometryReader { geometry in
            screenContent(available: geometry.size)
        }
        .aspectRatio(screenFrameAspect, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("screens-area")
    }

    // MARK: - Landscape layout

    private var landscapeContent: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .trailing) {
                if showsTouchControls {
                    LandscapeControlsTopBar(
                        backgroundOpacity: settings.controlsBackgroundOpacity,
                        haptics: settings.haptics
                    ) { bit, pressed in
                        model.setOverlayButton(bit, pressed: pressed)
                    }
                } else {
                    Color.clear
                }
                if isLoaded && !isMenuPresented {
                    landscapeMenuButton
                        .padding(.trailing, 8)
                }
            }
            .frame(height: LandscapeControlsLayout.topBarHeight)

            HStack(alignment: .center, spacing: 8) {
                if showsTouchControls {
                    LandscapeControlsLeftRail(
                        backgroundOpacity: settings.controlsBackgroundOpacity,
                        haptics: settings.haptics
                    ) { bit, pressed in
                        model.setOverlayButton(bit, pressed: pressed)
                    }
                    .frame(width: LandscapeControlsLayout.railWidth)
                }

                GeometryReader { geometry in
                    screenContent(available: geometry.size)
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { graphicsWarmUpOverlay }
                .accessibilityIdentifier("screens-area")

                if showsTouchControls {
                    LandscapeControlsRightRail(
                        backgroundOpacity: settings.controlsBackgroundOpacity,
                        haptics: settings.haptics
                    ) { bit, pressed in
                        model.setOverlayButton(bit, pressed: pressed)
                    }
                    .frame(width: LandscapeControlsLayout.railWidth)
                }
            }
            .frame(maxHeight: .infinity)

            landscapeStatus
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityIdentifier("screens")
    }

    /// The compact status line in landscape: the same frame line plus a
    /// single-row performance HUD, so the screens keep the height.
    private var landscapeStatus: some View {
        VStack(spacing: 1) {
            frameStatusLine
            if settings.showCustomHUD {
                compactPerformanceHUD
            }
        }
    }

    // MARK: - Menu

    private var menuButton: some View {
        Button {
            isMenuPresented = true
            model.pauseForMenu()
        } label: {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.white.opacity(0.9))
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 40, height: 40)
                )
        }
        .padding(.top, 8)
        .padding(.trailing, 14)
        .accessibilityIdentifier("in-game-menu")
    }

    /// The same pause button, sized for the landscape top bar (the portrait
    /// overlay sits over the screens, which would cover them here).
    private var landscapeMenuButton: some View {
        Button {
            isMenuPresented = true
            model.pauseForMenu()
        } label: {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 26))
                .foregroundColor(.white.opacity(0.9))
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 36, height: 36)
                )
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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

    // MARK: - Status / HUD

    private var frameStatusLine: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Text(L10n.format("%.0f fps", model.frameStats.fps))
                Text(L10n.frameCount(model.frameStats.frames))
                Text(L10n.format("last: %@", DiagnosticsExporter.frameResultLabel(model.frameStats.lastResult)))
                Text(L10n.format("audio: %@", model.audioState.title))
                    .accessibilityIdentifier("audio-status")
                if model.isPaused {
                    Text("paused")
                        .foregroundColor(.yellow)
                        .accessibilityIdentifier("paused-status")
                }
            }
            HStack(spacing: 10) {
                Text(L10n.format("AOT: %@", model.aotStatus.title))
                    .accessibilityIdentifier("aot-status")
                Text(L10n.format("speed: %.0f%% of 60 Hz", speedPercent))
                    .accessibilityIdentifier("speed-status")
                if model.effectivePlaybackSpeed > 1 {
                    Text(fastForwardStatus)
                        .foregroundColor(.yellow)
                        .accessibilityIdentifier("playback-speed-status")
                }
            }
            HStack(spacing: 10) {
                Text(L10n.format("loop: %@", model.frameLoopDisplayLabel))
                    .accessibilityIdentifier("loop-status")
                Text(L10n.format("display: %@", model.displayPath.title))
                    .accessibilityIdentifier("display-path")
            }
            // First-run graphics warm-up result (why the loading screen was
            // there, how long, and whether frames were still spiking). Exported
            // in diagnostics so a device run proves the hitch moved off-screen.
            if let warmUpSummary = model.warmUp.summary {
                Text(warmUpSummary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("warmup-summary")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("frame-status")
    }

    /// Emulation speed as a percentage of the 3DS 60 Hz timeline, including
    /// the fast-forward multiplier (presented frames × frames per presented
    /// frame).
    private var speedPercent: Double {
        model.frameStats.fps * Double(model.effectivePlaybackSpeed) / 60.0 * 100
    }

    /// "fast-forward: 2×" (with "(auto)" when the automatic fallback lowered
    /// the speed).
    private var fastForwardStatus: String {
        let label = L10n.speedLabel(model.effectivePlaybackSpeed)
        if model.playbackSpeedAutoReduced {
            return L10n.format("fast-forward: %@ (auto)", label)
        }
        return L10n.format("fast-forward: %@", label)
    }

    /// Per-phase frame timing: average / max (since the loop started) / last
    /// frame, in milliseconds. Toggled by the custom HUD setting.
    private var performanceHUD: some View {
        let timing = model.frameStats.timing
        return VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text("ms")
                    .frame(width: 60, alignment: .leading)
                Text("avg")
                    .frame(width: 46, alignment: .trailing)
                Text("max")
                    .frame(width: 46, alignment: .trailing)
                Text("last")
                    .frame(width: 46, alignment: .trailing)
            }
            .foregroundColor(.secondary.opacity(0.75))

            hudRow("total", timing.renderTotal, decimals: 1, identifier: "perf-total")
            hudRow("run", timing.runFrame, decimals: 1, identifier: "perf-run")
            if model.displayPath.usesMetalLayer {
                hudRow("present", timing.present, decimals: 2, identifier: "perf-present")
            } else {
                hudRow("read top", timing.topScreenRead, decimals: 2, identifier: "perf-read-top")
                hudRow("read bottom", timing.bottomScreenRead, decimals: 2, identifier: "perf-read-bottom")
                hudRow("CGImage", timing.cgImage, decimals: 2, identifier: "perf-cgimage")
            }
            hudRow("audio", timing.audioPump, decimals: 2, identifier: "perf-audio")
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("perf-hud")
    }

    /// Single-row HUD for landscape, where three columns of rows would take the
    /// screens' height. Same phases and averages as the portrait HUD.
    private var compactPerformanceHUD: some View {
        let timing = model.frameStats.timing
        return HStack(spacing: 10) {
            compactHudItem("total", timing.renderTotal, decimals: 1)
            compactHudItem("run", timing.runFrame, decimals: 1)
            if model.displayPath.usesMetalLayer {
                compactHudItem("present", timing.present, decimals: 2)
            } else {
                compactHudItem("read top", timing.topScreenRead, decimals: 2)
                compactHudItem("read bottom", timing.bottomScreenRead, decimals: 2)
                compactHudItem("CGImage", timing.cgImage, decimals: 2)
            }
            compactHudItem("audio", timing.audioPump, decimals: 2)
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundColor(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("perf-hud")
    }

    private func compactHudItem(
        _ label: LocalizedStringKey,
        _ stats: FramePhaseStats,
        decimals: Int
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
            Text(stats.isAvailable ? String(format: "%.\(decimals)f", stats.average) : "—")
        }
    }

    private func hudRow(
        _ label: LocalizedStringKey,
        _ stats: FramePhaseStats,
        decimals: Int,
        identifier: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 60, alignment: .leading)
            hudValue(stats.average, decimals: decimals, available: stats.isAvailable)
            hudValue(stats.maximum, decimals: decimals, available: stats.isAvailable)
            hudValue(stats.last, decimals: decimals, available: stats.isAvailable)
        }
        .accessibilityIdentifier(identifier)
    }

    private func hudValue(_ milliseconds: Double, decimals: Int, available: Bool) -> some View {
        Text(available ? String(format: "%.\(decimals)f", milliseconds) : "—")
            .frame(width: 46, alignment: .trailing)
    }

    @ViewBuilder
    private var audioFailureLine: some View {
        if let failure = model.audioState.failureMessage {
            Text(L10n.format("Audio: %@", failure))
                .font(.caption2)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("audio-error")
        }
    }

    @ViewBuilder
    private var inputStatusLine: some View {
        if let controllerName = model.controllerName {
            Text(L10n.format("Controller: %@", controllerName))
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("controller-status")
        } else {
            Text("No controller connected — use the on-screen controls")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
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
