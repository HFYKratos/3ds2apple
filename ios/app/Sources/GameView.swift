//
//  GameView.swift
//  3ds2apple
//
//  The running game: the two 3DS screens on the CAMetalLayer (or the CGImage
//  readback path used by the alternate screen layouts), the performance HUD,
//  the on-screen controls and the in-game overlay menu.
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

    private var romName: String { model.lastROM?.name ?? "Game" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
            if isLoaded && !isMenuPresented {
                menuButton
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
        case .reset: return "Reset the game?"
        case .exit: return "Exit to home?"
        }
    }

    private var confirmationButtonTitle: String {
        switch confirmationKind {
        case .reset: return "Reset"
        case .exit: return "Exit"
        }
    }

    private var confirmationMessage: String {
        switch confirmationKind {
        case .reset:
            return "The game restarts from the beginning with the current ROM. Battery saves are kept."
        case .exit:
            return "The runtime is released and the game closes. Imported ROMs and save data stay on the device."
        }
    }

    // MARK: - Screens

    @ViewBuilder
    private var screenCard: some View {
        if isShowingScreens {
            VStack(spacing: 8) {
                screenSurfaces
                    .overlay { graphicsWarmUpOverlay }

                audioFailureLine

                if settings.showTouchControls && !isPreparingGraphics && !model.isPaused {
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

    /// True while the screens should come from the CAMetalLayer: either a
    /// presented load is running, or one is about to and the console layout was
    /// chosen (the layer must be laid out before the first frame).
    private var usesPresentedSurface: Bool {
        model.displayPath.usesMetalLayer
            || (isRuntimeStarting && model.screenLayout.usesPresentedPath)
    }

    @ViewBuilder
    private var screenSurfaces: some View {
        if let metalView = model.metalScreenView, usesPresentedSurface {
            presentedScreenSurface(view: metalView)
        } else {
            readbackScreens
        }
    }

    /// A1: Zakuro's presenter draws the upper and lower screens stacked into the
    /// app's CAMetalLayer. The container keeps the console aspect; integer
    /// scaling and the stretch aspect fit the content inside it.
    private func presentedScreenSurface(view: MetalScreenView) -> some View {
        GeometryReader { geometry in
            let size = consoleSize(in: geometry.size)
            MetalScreenRepresentable(view: view)
                .frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(consoleAspect, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(metalFirstFramePlaceholder)
        .overlay(presentedTouchOverlay)
        .accessibilityIdentifier("metal-screen")
    }

    /// Readback path: the two screens as separate images, arranged according to
    /// the screen layout setting.
    @ViewBuilder
    private var readbackScreens: some View {
        switch settings.screenLayout {
        case .stacked:
            VStack(spacing: 8) {
                readbackScreen(
                    image: model.topScreenImage,
                    screen: topScreen,
                    identifier: "top-screen"
                )
                readbackScreen(
                    image: model.bottomScreenImage,
                    screen: bottomScreen,
                    identifier: "bottom-screen",
                    isTouchscreen: true
                )
            }
        case .sideBySide:
            HStack(spacing: 8) {
                readbackScreen(
                    image: model.topScreenImage,
                    screen: topScreen,
                    identifier: "top-screen"
                )
                readbackScreen(
                    image: model.bottomScreenImage,
                    screen: bottomScreen,
                    identifier: "bottom-screen",
                    isTouchscreen: true
                )
            }
        case .upperOnly:
            readbackScreen(
                image: model.topScreenImage,
                screen: topScreen,
                identifier: "top-screen"
            )
        case .lowerOnly:
            readbackScreen(
                image: model.bottomScreenImage,
                screen: bottomScreen,
                identifier: "bottom-screen",
                isTouchscreen: true
            )
        }
    }

    private func readbackScreen(
        image: CGImage?,
        screen: ZakuroScreen,
        identifier: String,
        isTouchscreen: Bool = false
    ) -> some View {
        let nativeRatio = screen.aspectRatio
        let ratio: CGFloat = settings.screenAspect == .native ? nativeRatio : 4.0 / 3.0
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black)
            if let image {
                if settings.screenAspect == .native {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                } else {
                    // Stretch mode: fill the 4:3 area (the user chose to distort).
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                }
            } else {
                Text(isRuntimeStarting ? "Starting Zakuro…" : "Waiting for first frame…")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isTouchscreen {
                bottomTouchOverlay
            }
        }
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var metalFirstFramePlaceholder: some View {
        if model.frameStats.frames == 0 {
            Text(isRuntimeStarting ? "Starting Zakuro…" : "Waiting for first frame…")
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
                    Text("The first frames compile and cache the GPU pipelines so "
                         + "gameplay starts smooth. This one-time step is skipped on later loads.")
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

    /// Aspect of the area the screens occupy. Native keeps the console's
    /// 400x480 shape; stretch uses a 4:3 box.
    private var consoleAspect: CGFloat {
        settings.screenAspect == .native ? 400.0 / 480.0 : 4.0 / 3.0
    }

    /// Size of the presented console image inside `available`. Integer scaling
    /// snaps it to whole screen pixels (native aspect only).
    private func consoleSize(in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0 else { return .zero }
        let aspect = consoleAspect
        let fitWidth: CGFloat
        let fitHeight: CGFloat
        if available.width / available.height > aspect {
            fitHeight = available.height
            fitWidth = fitHeight * aspect
        } else {
            fitWidth = available.width
            fitHeight = fitWidth / aspect
        }
        guard settings.integerScale, settings.screenAspect == .native else {
            return CGSize(width: fitWidth, height: fitHeight)
        }
        let scale = displayScale > 0 ? displayScale : 2
        let pixelWidth = fitWidth * scale
        let pixelHeight = fitHeight * scale
        let multiple = max(1, floor(min(pixelWidth / 400, pixelHeight / 480)))
        return CGSize(width: 400 * multiple / scale, height: 480 * multiple / scale)
    }

    // MARK: - Touchscreen

    /// A1: touch on the presented layer. It shows the upper screen over the
    /// lower one, so the runtime maps the point and ignores anything that is
    /// not the lower screen.
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

    /// Drag/tap on the lower screen sends 3DS touchscreen coordinates in
    /// bottom-screen pixels while a runtime is loaded.
    private var bottomTouchOverlay: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isTouchscreenEnabled else { return }
                            let point = bottomScreenPoint(value.location, in: geometry.size)
                            model.setTouchPoint(x: point.x, y: point.y)
                        }
                        .onEnded { _ in
                            model.setTouchPoint(x: nil, y: nil)
                        }
                )
        }
    }

    private var isTouchscreenEnabled: Bool { isLoaded }

    private func bottomScreenPoint(_ location: CGPoint, in size: CGSize) -> (x: UInt16, y: UInt16) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let normalisedX = min(max(location.x / width, 0), 1)
        let normalisedY = min(max(location.y / height, 0), 1)
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
                Text(String(format: "%.0f fps", model.frameStats.fps))
                Text("\(model.frameStats.frames) frames")
                Text("last: \(DiagnosticsExporter.frameResultLabel(model.frameStats.lastResult))")
                Text("audio: \(model.audioState.label)")
                    .accessibilityIdentifier("audio-status")
                if model.isPaused {
                    Text("paused")
                        .foregroundColor(.yellow)
                        .accessibilityIdentifier("paused-status")
                }
            }
            HStack(spacing: 10) {
                Text("AOT: \(model.aotStatus.label)")
                    .accessibilityIdentifier("aot-status")
                Text(String(format: "speed: %.0f%% of 60 Hz", model.frameStats.fps / 60.0 * 100))
                    .accessibilityIdentifier("speed-status")
            }
            HStack(spacing: 10) {
                Text("loop: \(model.frameLoopLabel)")
                    .accessibilityIdentifier("loop-status")
                Text("display: \(model.displayPath.label)")
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

    private func hudRow(
        _ label: String,
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
            Text("Audio: \(failure)")
                .font(.caption2)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("audio-error")
        }
    }

    @ViewBuilder
    private var inputStatusLine: some View {
        if let controllerName = model.controllerName {
            Text("Controller: \(controllerName)")
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
