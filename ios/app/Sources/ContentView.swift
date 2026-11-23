//
//  ContentView.swift
//  3ds2apple
//
//  Root of the app: shows the home page or the running game for the current
//  session phase, and keeps the runtime in step with the persisted settings.
//
//  Phase-driven navigation: the home page is shown while nothing is loaded;
//  from the moment a game starts loading, the game view owns the screen. Unload /
//  exit returns to the home page.
//
//  The persisted settings are pushed into the session here (a settings change
//  while a game is running is safe: the session applies what can apply live and
//  remembers the rest for the next load).
//

import CoreGraphics
import SwiftUI
import UIKit

struct ContentView: View {
    /// The persisted multi-game library, shared by the whole app.
    @StateObject private var library = GameLibrary.shared
    @StateObject private var model = ROMSession()
    @StateObject private var settings = AppSettings.shared
    /// Rebuilds the view tree when iOS reports a locale change, so the
    /// localized texts and formatters are read again.
    @StateObject private var localization = LocalizationStore.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Headless screenshot hooks for the layout pages; never set in normal use.
    @State private var layoutSheet: LayoutSheet?
    @State private var layoutEditorLaunch: LayoutEditorLaunch?

    /// A screen-layout page a headless launch asked to open: the settings page
    /// (which can present a direction's preset picker itself) or the numeric
    /// custom layout page of one direction.
    private enum LayoutSheet: Identifiable {
        case settings
        case customPage(ControlLayoutOrientation)

        var id: String {
            switch self {
            case .settings: return "layout-settings"
            case .customPage(let orientation): return "custom-\(orientation.rawValue)"
            }
        }
    }

    /// A full-screen layout editor a `-openLayoutEditor` launch opens directly,
    /// for headless screenshots. Every editor opens for one device direction.
    private struct LayoutEditorLaunch: Identifiable {
        enum Kind {
            case screen
            case control
        }

        let id = UUID()
        let kind: Kind
        let orientation: ControlLayoutOrientation
    }

    /// Explicit internal init: the stored properties are private and App.swift
    /// constructs ContentView() from another file.
    init() {}

    var body: some View {
        ZStack {
            if showsGame {
                GameView(model: model, settings: settings)
            } else {
                HomeView(model: model, settings: settings, library: library)
            }
        }
        // A locale change while the app runs re-reads the localized texts.
        .id(localization.revision)
        .sheet(item: $layoutSheet) { sheet in
            switch sheet {
            case .settings:
                NavigationStack {
                    ScreenLayoutSettingsView(settings: settings)
                }
            case .customPage(let orientation):
                NavigationStack {
                    CustomScreenLayoutValuesView(settings: settings, orientation: orientation)
                }
            }
        }
        .fullScreenCover(item: $layoutEditorLaunch) { launch in
            switch launch.kind {
            case .screen:
                ScreenLayoutEditorView(settings: settings, orientation: launch.orientation)
            case .control:
                ControlLayoutEditorView(settings: settings, orientation: launch.orientation)
            }
        }
        .onAppear {
            // Preview-only display values (`-previewGameView`,
            // `-previewScreenLayout <preset>`, `-previewLandscape`): written to the
            // in-memory settings, never persisted. Inert in normal launches.
            DebugLaunch.applyPreviewSettings(to: settings)
            model.startControllerSupport()
            applySettings()
            // Rescan Documents/Games before the home page is measured: the
            // desktop launcher can add or replace games while the app is not
            // running.
            library.refresh()
            logRuntimeProbe()
            // Automated launch for the Simulator / diagnostics
            // (`-openAOTTitleID <TITLEID>`); inert in normal use.
            DebugLaunch.startIfRequested(model: model, library: library)
            // Headless screenshot of the layout pages; inert otherwise.
            switch DebugLaunch.requestedLayoutPage {
            case .screenLayout:
                layoutSheet = .settings
            case .controlEditorPortrait:
                layoutEditorLaunch = LayoutEditorLaunch(kind: .control, orientation: .portrait)
            case .controlEditorLandscape:
                layoutEditorLaunch = LayoutEditorLaunch(kind: .control, orientation: .landscape)
            case .screenEditorPortrait:
                layoutEditorLaunch = LayoutEditorLaunch(kind: .screen, orientation: .portrait)
            case .screenEditorLandscape:
                layoutEditorLaunch = LayoutEditorLaunch(kind: .screen, orientation: .landscape)
            case nil:
                break
            }
            // The picker hook opens the layout settings page; the page itself
            // presents the requested direction's picker. Inert otherwise.
            if DebugLaunch.requestedLayoutPicker != nil, layoutSheet == nil {
                layoutSheet = .settings
            }
            if let orientation = DebugLaunch.requestedCustomLayoutPage {
                layoutSheet = .customPage(orientation)
            }
        }
        .onChange(of: settings.renderScale) { scale in
            model.applyRenderScale(CGFloat(scale))
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                // 0.1.4: keep the runtime and pause. Returning to the foreground
                // continues the same game; the session writes a recovery
                // snapshot in case iOS jettisons the process while it is
                // backgrounded.
                model.suspendForBackground()
            case .inactive:
                // Control Center, the app switcher, an incoming call or a system
                // alert: pause the loop so the inactive time is excluded from
                // fps/stutter (ROMSession.applyPendingPauseResume).
                model.pauseForInactiveScene()
            case .active:
                // Returned from a scene transition or from the background:
                // continue the same session with its running statistics kept.
                model.resumeAfterInactiveScene()
                // The launcher (or the Files app) can add or replace games while
                // the app is not in front: rescan Documents/Games on return.
                library.refresh()
                // A recovery snapshot may have appeared or been dropped while
                // the app was in the background.
                model.refreshBackgroundSnapshot()
            @unknown default:
                break
            }
        }
        .onChange(of: settings.audioMuted) { muted in
            model.setAudioMuted(muted)
        }
        .onChange(of: settings.audioVolume) { volume in
            model.setAudioVolume(Float(volume))
        }
        .onChange(of: settings.audioBuffer) { buffer in
            model.setAudioBufferDuration(buffer.duration)
        }
        .onChange(of: settings.frameCap) { cap in
            model.setFrameRateCap(cap.rawValue)
        }
        .onChange(of: settings.screenRotation) { rotation in
            model.setScreenRotation(rotation)
        }
        .onChange(of: settings.landscapeScreenLayout) { _ in
            let isLandscape = GameViewDeviceMetrics.currentLayoutOrientation == .landscape
            model.setReadbackPresentationRequired(
                settings.usesReadbackPresentation(isLandscape: isLandscape)
            )
            model.setCustomScreenPlacement(
                settings.customScreenLayout.placement(for: isLandscape ? .landscape : .portrait)
            )
        }
        .onChange(of: settings.portraitScreenLayout) { _ in
            let isLandscape = GameViewDeviceMetrics.currentLayoutOrientation == .landscape
            model.setReadbackPresentationRequired(
                settings.usesReadbackPresentation(isLandscape: isLandscape)
            )
            model.setCustomScreenPlacement(
                settings.customScreenLayout.placement(for: isLandscape ? .landscape : .portrait)
            )
        }
        .onChange(of: settings.customScreenLayout) { _ in
            let isLandscape = GameViewDeviceMetrics.currentLayoutOrientation == .landscape
            model.setCustomScreenPlacement(
                settings.customScreenLayout.placement(for: isLandscape ? .landscape : .portrait)
            )
        }
        .onChange(of: settings.integerScale) { enabled in
            model.setIntegerScaling(enabled)
        }
        .onChange(of: settings.orientation) { orientation in
            AppOrientation.apply(orientation)
        }
        .onChange(of: settings.playbackSpeed) { speed in
            model.setPlaybackSpeed(speed.rawValue)
        }
        .onChange(of: settings.swapScreens) { swapped in
            model.setScreenSwap(swapped)
        }
        .onChange(of: settings.systemMetalHUD) { enabled in
            model.setSystemMetalHUD(enabled)
        }
    }

    // MARK: - State

    private var showsGame: Bool {
        // The debug preview shows the running-game view without a session
        // (`-previewGameView`); inert in normal launches.
        if DebugLaunch.previewGameView { return true }
        switch model.phase {
        case .starting, .preparing, .loaded:
            return true
        case .idle, .failed, .finished:
            return false
        }
    }

    /// Pushes every persisted setting into the session once at launch.
    private func applySettings() {
        model.setAudioMuted(settings.audioMuted)
        model.setAudioVolume(Float(settings.audioVolume))
        model.setAudioBufferDuration(settings.audioBuffer.duration)
        model.setFrameRateCap(settings.frameCap.rawValue)
        model.setScreenLayout(settings.effectiveScreenLayout(isLandscape: false))
        model.setCustomScreenPlacement(
            settings.customScreenLayout.placement(
                for: GameViewDeviceMetrics.currentLayoutOrientation == .landscape
                    ? .landscape : .portrait
            )
        )
        model.setScreenRotation(settings.screenRotation)
        model.setScreenSwap(settings.swapScreens)
        model.setIntegerScaling(settings.integerScale)
        model.applyRenderScale(CGFloat(settings.renderScale))
        model.setPlaybackSpeed(settings.playbackSpeed.rawValue)
        model.setSystemMetalHUD(settings.systemMetalHUD)
        model.setReadbackPresentationRequired(
            settings.usesReadbackPresentation(
                isLandscape: GameViewDeviceMetrics.currentLayoutOrientation == .landscape
            )
        )
    }

    // MARK: - Diagnostics

    /// One line in `idevicesyslog` that proves the static library was linked and
    /// called on device, plus the catalog/library state at launch.
    private func logRuntimeProbe() {
        let top = ZakuroScreen(which: 0)
        let bottom = ZakuroScreen(which: 1)
        AppLog.log(
            "[3ds2apple] zk_screen_width(0)=%u zk_screen_height(0)=%u "
                + "zk_screen_width(1)=%u zk_screen_height(1)=%u",
            top.width,
            top.height,
            bottom.width,
            bottom.height
        )
        AppLog.log("[3ds2apple] language: %@", L10n.diagnosticsLine)
        AppLog.log("[3ds2apple] documents: %@", StorageInspector.documentsURL.path)
        AppLog.log("[3ds2apple] library: %ld catalog game(s) (%ld with pushed game data, %ld from the previous build, %ld checking)",
                   library.entries.count,
                   library.entries.filter { $0.hasPushedData }.count,
                   library.entries.filter { $0.isLegacyBundled }.count,
                   library.entries.filter { $0.validation == .checking }.count)
        for entry in library.entries {
            AppLog.log("[3ds2apple] library entry: %@ (%@) from %@", entry.title, entry.titleID, entry.sourceDescription)
            for issue in entry.validation.issues {
                AppLog.log("[3ds2apple] library entry %@: %@", entry.titleID, issue.localizedMessage)
            }
        }
        if let game = model.currentGame {
            AppLog.log("[3ds2apple] current game: %@ (%@)", game.title, game.titleID)
        } else {
            AppLog.log("[3ds2apple] no game loaded yet")
        }
    }
}