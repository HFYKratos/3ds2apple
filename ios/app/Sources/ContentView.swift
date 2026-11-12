//
//  ContentView.swift
//  3ds2apple
//
//  Root of the app: shows the home page or the running game for the current
//  session phase, and keeps the runtime in step with the persisted settings.
//
//  Phase-driven navigation: the home page is shown while nothing is loaded;
//  from the moment a ROM starts loading, the game view owns the screen (it
//  shows the warm-up overlay until the game is revealed). Unload / exit
//  returns to the home page.
//

import CoreGraphics
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = ROMSession()
    @StateObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Explicit internal init: the stored properties are private and App.swift
    /// constructs ContentView() from another file.
    init() {}

    var body: some View {
        ZStack {
            if showsGame {
                GameView(model: model, settings: settings)
            } else {
                HomeView(model: model, settings: settings)
            }
        }
        .onAppear {
            model.startControllerSupport()
            applySettings()
            logRuntimeProbe()
        }
        .onChange(of: scenePhase) { newPhase in
            // iOS may jettison a backgrounded process; release the runtime.
            if newPhase == .background {
                model.stopForBackground()
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
        .onChange(of: settings.renderScale) { scale in
            model.applyRenderScale(CGFloat(scale))
        }
        .onChange(of: settings.screenLayout) { layout in
            model.setScreenLayout(layout)
        }
        .onChange(of: settings.orientation) { orientation in
            AppOrientation.apply(orientation)
        }
    }

    // MARK: - State

    private var showsGame: Bool {
        switch model.phase {
        case .starting, .preparing, .loaded:
            return true
        case .idle, .importing, .failed, .finished:
            return false
        }
    }

    /// Pushes every persisted setting into the session once at launch.
    private func applySettings() {
        model.setAudioMuted(settings.audioMuted)
        model.setAudioVolume(Float(settings.audioVolume))
        model.setAudioBufferDuration(settings.audioBuffer.duration)
        model.setFrameRateCap(settings.frameCap.rawValue)
        model.setScreenLayout(settings.screenLayout)
        model.applyRenderScale(CGFloat(settings.renderScale))
    }

    // MARK: - Diagnostics

    /// One line in `idevicesyslog` that proves the static library was linked and
    /// called on device, plus the ROM state at launch.
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
        if let last = model.lastROM {
            AppLog.log("[3ds2apple] last imported ROM: %@", last.relativePath)
        } else {
            AppLog.log("[3ds2apple] no ROM imported yet")
        }
    }
}
