//
//  ContentView.swift
//  3ds2apple
//
//  I2-T1: ROM import UI.
//  I2-T2: live frame display — upper screen (400x240) above lower screen
//         (320x240), aspect fit, plus an fps / frames / last-result line.
//  I3-T6: compact performance HUD (per-phase frame timings in ms).
//  I3-T9: the status line shows which frame-loop driver is active (free-run
//         with its fps cap, or the CADisplayLink fallback).
//  A1:    the screens can come from a CAMetalLayer view instead of two
//         CGImages; the HUD then shows a `present` phase instead of the
//         screen-read/CGImage phases, and the system Metal HUD can attach.
//

import CoreGraphics
import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = ROMSession()
    @State private var isPickerPresented = false
    @Environment(\.scenePhase) private var scenePhase
    /// On-screen controls visibility, persisted between launches.
    @AppStorage("I3.showTouchControls") private var showTouchControls = true
    /// Audio mute, persisted between launches.
    @AppStorage("I3.audioMuted") private var audioMuted = false
    /// Diagnostics file currently being shared, if any.
    @State private var diagnosticsFile: DiagnosticsFile?

    /// Screen geometry is read from the linked static library.
    private let topScreen = ZakuroScreen(which: 0)
    private let bottomScreen = ZakuroScreen(which: 1)

    /// Explicit internal init: the synthesized memberwise init would be
    /// file-private because the stored properties are private, and App.swift
    /// constructs ContentView() from another file.
    init() {}

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                romCard
                screenCard
                runtimeCard
                footer
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $isPickerPresented) {
            ROMDocumentPicker { url in
                isPickerPresented = false
                if let url {
                    model.importROM(from: url)
                }
            }
        }
        .sheet(item: $diagnosticsFile) { file in
            ShareSheet(items: [file.url])
        }
        .onAppear {
            model.startControllerSupport()
            model.setAudioMuted(audioMuted)
            logRuntimeProbe()
        }
        .onChange(of: scenePhase) { newPhase in
            // iOS may jettison a backgrounded process; release the runtime.
            if newPhase == .background {
                model.stopForBackground()
            }
        }
        .onChange(of: audioMuted) { muted in
            model.setAudioMuted(muted)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Text("3ds2apple")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .accessibilityIdentifier("app-title")
            Text("Nintendo 3DS, natively on iPhone")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 24)
    }

    private var romCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            romStatus
            romActions
            diagnosticsButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityIdentifier("rom-card")
    }

    @ViewBuilder
    private var romStatus: some View {
        switch model.phase {
        case .idle:
            Label("No ROM loaded", systemImage: "doc.badge.plus")
                .font(.headline)
            Text("Import a decrypted .3ds or .cci ROM from Files. The ROM is copied "
                 + "into this app's Documents folder and stays on the device.")
                .font(.footnote)
                .foregroundColor(.secondary)
        case .importing(let name):
            statusRow(
                title: "Importing \(name)…",
                detail: "Copying the file into the app container. Large ROMs take a while."
            )
        case .starting(let name):
            statusRow(
                title: "Starting Zakuro…",
                detail: "Loading \(name). zk_create() can take several seconds."
            )
        case .loaded(let name):
            Label("Loaded: \(name)", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundColor(.green)
                .accessibilityIdentifier("rom-loaded")
            Text("The frame loop is running. Emulator speed depends on the interpreter.")
                .font(.footnote)
                .foregroundColor(.secondary)
        case .failed(let message):
            Label("Could not load ROM", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.red)
                .accessibilityIdentifier("rom-error")
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        case .finished(let message):
            Label("Runtime stopped", systemImage: "stop.circle")
                .font(.headline)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("runtime-finished")
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var romActions: some View {
        switch model.phase {
        case .idle, .failed, .finished:
            Button {
                isPickerPresented = true
            } label: {
                Label("Import ROM…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("import-rom")

            if let last = model.lastROM {
                Button("Load “\(last.name)”") {
                    model.loadLastROM()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }

            if isShowingNotice {
                Button("Dismiss") {
                    model.dismissNotice()
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }
        case .importing, .starting:
            EmptyView()
        case .loaded:
            Button {
                isPickerPresented = true
            } label: {
                Label("Change ROM…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(showTouchControls ? "Hide controls" : "Show controls") {
                showTouchControls.toggle()
                if !showTouchControls {
                    model.clearOverlayInput()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("toggle-controls")

            Button(audioMuted ? "Unmute audio" : "Mute audio") {
                audioMuted.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("toggle-audio")

            Button(role: .destructive) {
                model.unload()
            } label: {
                Label("Unload ROM", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    /// The screens: one CAMetalLayer view showing both (A1), or the two
    /// CGImages of the readback fallback.
    @ViewBuilder
    private var screenCard: some View {
        if isShowingScreens {
            VStack(spacing: 10) {
                screenSurfaces
                frameStatusLine
                performanceHUD
                audioFailureLine

                if showTouchControls {
                    TouchControlsView { bit, pressed in
                        model.setOverlayButton(bit, pressed: pressed)
                    }
                }

                inputStatusLine
            }
            .padding(12)
            .background(cardBackground)
            .accessibilityIdentifier("screens")
        }
    }

    /// A1: Zakuro's presenter draws the upper and lower screens stacked into
    /// the app's CAMetalLayer, so one view replaces the two CGImages. The
    /// CGImage path stays as the fallback (no MoltenVK, or a presenter that
    /// could not be made).
    @ViewBuilder
    private var screenSurfaces: some View {
        if let metalView = model.metalScreenView,
           model.displayPath.usesMetalLayer || isRuntimeStarting {
            MetalScreenRepresentable(view: metalView)
                .aspectRatio(consoleAspectRatio, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(metalFirstFramePlaceholder)
                .overlay(presentedTouchOverlay)
                .accessibilityIdentifier("metal-screen")
        } else {
            VStack(spacing: 10) {
                screenSurface(
                    image: model.topScreenImage,
                    aspectRatio: aspectRatio(of: topScreen),
                    placeholder: "Waiting for first frame…"
                )
                .accessibilityIdentifier("top-screen")

                screenSurface(
                    image: model.bottomScreenImage,
                    aspectRatio: aspectRatio(of: bottomScreen),
                    placeholder: "Waiting for first frame…"
                )
                .accessibilityIdentifier("bottom-screen")
                .overlay(bottomTouchOverlay)
            }
        }
    }

    /// A single CAMetalLayer holds both screens in the console's 400x480 shape.
    private var consoleAspectRatio: CGFloat { 400.0 / 480.0 }

    @ViewBuilder
    private var metalFirstFramePlaceholder: some View {
        if model.frameStats.frames == 0 {
            Text(isRuntimeStarting ? "Starting Zakuro…" : "Waiting for first frame…")
                .font(.caption)
                .foregroundColor(.white.opacity(0.65))
        }
    }

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

    private func screenSurface(image: CGImage?, aspectRatio: CGFloat, placeholder: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black)
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var frameStatusLine: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Text(String(format: "%.0f fps", model.frameStats.fps))
                Text("\(model.frameStats.frames) frames")
                Text("last: \(frameResultLabel(model.frameStats.lastResult))")
                Text("audio: \(model.audioState.label)")
                    .accessibilityIdentifier("audio-status")
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
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("frame-status")
    }

    /// I3-T6: where each frame's wall time goes, as measured on the runtime
    /// serial queue — average / max (since the loop started) / last frame, in
    /// milliseconds. See ios/app/README.md ("Performance HUD") for reading it.
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
                // A1: one swapchain present replaces the two screen reads and
                // the CGImage conversion.
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

    private func hudRow(_ label: String,
                        _ stats: FramePhaseStats,
                        decimals: Int,
                        identifier: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 60, alignment: .leading)
            hudValue(stats.average, decimals: decimals, available: stats.isAvailable)
            hudValue(stats.maximum, decimals: decimals, available: stats.isAvailable)
            hudValue(stats.last, decimals: decimals, available: stats.isAvailable)
        }
        .accessibilityIdentifier(identifier)
    }

    private func hudValue(_ milliseconds: Double,
                          decimals: Int,
                          available: Bool) -> some View {
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

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Zakuro runtime", systemImage: "cpu")
                .font(.headline)

            HStack {
                Text("Upper screen")
                Spacer()
                Text(topScreen.label)
                    .monospacedDigit()
            }
            HStack {
                Text("Lower screen")
                Spacer()
                Text(bottomScreen.label)
                    .monospacedDigit()
            }
            Text("zk_screen_width(0) = \(topScreen.width)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("zk-screen-width")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var diagnosticsButton: some View {
        Button {
            exportDiagnostics()
        } label: {
            Label("Export diagnostics", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("export-diagnostics")
    }

    private func exportDiagnostics() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "3ds2apple-diagnostics-\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try makeDiagnosticsReport().write(to: url, atomically: true, encoding: .utf8)
            diagnosticsFile = DiagnosticsFile(url: url)
            AppLog.log("diagnostics exported: %@", filename)
        } catch {
            AppLog.log("diagnostics export failed: %@", error.localizedDescription)
        }
    }

    private func makeDiagnosticsReport() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        let screen = UIScreen.main
        let timing = model.frameStats.timing
        let phaseText: String
        switch model.phase {
        case .idle: phaseText = "idle"
        case .importing(let name): phaseText = "importing \(name)"
        case .starting(let name): phaseText = "starting \(name)"
        case .loaded(let name): phaseText = "loaded \(name)"
        case .failed(let message): phaseText = "failed: \(message)"
        case .finished(let message): phaseText = "finished: \(message)"
        }
        var header = """
        3ds2apple diagnostics
        date=\(Date())
        app=\(version) (\(build))
        device=\(device.model) · \(device.systemName) \(device.systemVersion)
        screen=\(Int(screen.bounds.width * screen.scale))x\(Int(screen.bounds.height * screen.scale)) @\(screen.scale)x
        phase=\(phaseText)
        rom=\(model.lastROM?.name ?? "none")
        aot=\(model.aotStatus.label)
        display=\(model.displayPath.label)
        loop=\(model.frameLoopLabel)
        fps=\(String(format: "%.1f", model.frameStats.fps))
        frames=\(model.frameStats.frames)
        speed=\(String(format: "%.1f%%", model.frameStats.fps / 60.0 * 100))
        last_result=\(model.frameStats.lastResult)
        audio=\(model.audioState.label)
        controller=\(model.controllerName ?? "none")
        timing_ms_total=\(String(format: "%.2f/%.2f/%.2f", timing.renderTotal.average, timing.renderTotal.maximum, timing.renderTotal.last))
        timing_ms_run=\(String(format: "%.2f/%.2f/%.2f", timing.runFrame.average, timing.runFrame.maximum, timing.runFrame.last))
        timing_ms_present=\(String(format: "%.2f/%.2f/%.2f", timing.present.average, timing.present.maximum, timing.present.last))
        timing_ms_read_top=\(String(format: "%.2f/%.2f/%.2f", timing.topScreenRead.average, timing.topScreenRead.maximum, timing.topScreenRead.last))
        timing_ms_read_bottom=\(String(format: "%.2f/%.2f/%.2f", timing.bottomScreenRead.average, timing.bottomScreenRead.maximum, timing.bottomScreenRead.last))
        timing_ms_cgimage=\(String(format: "%.2f/%.2f/%.2f", timing.cgImage.average, timing.cgImage.maximum, timing.cgImage.last))
        timing_ms_audio=\(String(format: "%.2f/%.2f/%.2f", timing.audioPump.average, timing.audioPump.maximum, timing.audioPump.last))
        """
        header += "\n\n"
        return AppLog.shared.exportReport(header: header)
    }

    private var footer: some View {
        Text("I3 · input + audio + free-run frame loop + perf HUD · CAMetalLayer presentation (A1) · no JIT")
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func statusRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView()
                Text(title)
                    .font(.headline)
            }
            Text(detail)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Touchscreen

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

    private var isTouchscreenEnabled: Bool {
        if case .loaded = model.phase { return true }
        return false
    }

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

    // MARK: - Derived state

    /// Show the screens from the moment the runtime is loaded (placeholder
    /// until the first frame) and keep the last frame visible afterwards.
    private var isShowingScreens: Bool {
        if model.topScreenImage != nil { return true }
        if case .loaded = model.phase { return true }
        // A1: show the Metal layer while the ROM loads, so SwiftUI lays the
        // view out and the runtime learns its drawable size before the first
        // frame is presented.
        if isRuntimeStarting, model.metalScreenView != nil { return true }
        if model.displayPath.usesMetalLayer, model.metalScreenView != nil { return true }
        return false
    }

    /// True while a ROM is being loaded (zk_create runs in the background).
    private var isRuntimeStarting: Bool {
        if case .starting = model.phase { return true }
        return false
    }

    private var isShowingNotice: Bool {
        if case .failed = model.phase { return true }
        if case .finished = model.phase { return true }
        return false
    }

    private func aspectRatio(of screen: ZakuroScreen) -> CGFloat {
        guard screen.height > 0 else { return 4.0 / 3.0 }
        return CGFloat(Int(screen.width)) / CGFloat(Int(screen.height))
    }

    /// zk_run_frame result codes — see ZK_FRAME_* in ios/ZakuroBridge.h.
    private func frameResultLabel(_ result: Int32) -> String {
        switch result {
        case 0: return "completed"
        case 1: return "exited"
        case -1: return "faulted"
        case -2: return "bad handle"
        default: return "\(result)"
        }
    }

    // MARK: - Diagnostics

    /// One line in `idevicesyslog` that proves the static library was linked
    /// and called on device, plus the ROM state at launch.
    private func logRuntimeProbe() {
        AppLog.log(
            "[3ds2apple] zk_screen_width(0)=%u zk_screen_height(0)=%u "
                + "zk_screen_width(1)=%u zk_screen_height(1)=%u",
            topScreen.width,
            topScreen.height,
            bottomScreen.width,
            bottomScreen.height
        )
        if let last = model.lastROM {
            AppLog.log("[3ds2apple] last imported ROM: %@", last.relativePath)
        } else {
            AppLog.log("[3ds2apple] no ROM imported yet")
        }
    }
}

/// One 3DS screen as reported by the linked static library.
private struct ZakuroScreen {
    let width: UInt32
    let height: UInt32

    init(which: UInt32) {
        self.width = zk_screen_width(which)
        self.height = zk_screen_height(which)
    }

    var label: String { "\(width) × \(height)" }
}


private struct DiagnosticsFile: Identifiable {
    let id = UUID()
    let url: URL
}
