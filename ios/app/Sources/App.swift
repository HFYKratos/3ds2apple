//
//  App.swift
//  3ds2apple
//
//  I1 shell skeleton: SwiftUI entry point.
//
//  The Zakuro C ABI is imported implicitly through the Objective-C bridging
//  header (SWIFT_OBJC_BRIDGING_HEADER in project.yml -> ios/ZakuroBridge.h),
//  so `zk_*` symbols are visible to every Swift file in this target.
//

import Darwin
import SwiftUI

@main
struct ThreeDS2AppleApp: App {
    /// Only used for the orientation preference in Settings; the UI lives in
    /// the SwiftUI views.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Metal Performance HUD: the Metal device reads MTL_HUD_ENABLED once,
        // when it is created. The device here is MoltenVK's, created by the
        // first zk_create()/load, so the persisted Settings switch has to
        // become an environment variable before that. The layer-level
        // developerHUDProperties switch in MetalScreenView then shows/hides the
        // HUD on the live layer; flipping it while a game runs does not need a
        // relaunch, but a build whose Metal device was created before the
        // variable was set does (see SettingsView and MetalScreenView).
        MetalHUD.apply(enabled: AppSettings.shared.systemMetalHUD)
        // Zakuro stores its Vulkan pipeline cache under XDG_CACHE_HOME (or
        // ~/.cache). On iOS the sandbox home's .cache is not writable, which
        // made every launch recompile pipelines and stutter on first use.
        // Point it at the app's Caches directory before the runtime loads; the
        // same directory is what the app reports in its diagnostics.
        if let caches = PipelineCacheStats.cacheRootURL {
            setenv("XDG_CACHE_HOME", caches.path, 1)
        }
        // Redirect stderr and start the in-app log before the runtime loads.
        AppLog.shared.start()
        // One line that answers "why is the HUD not showing?" on device:
        // setting, environment variable and the Info.plist build gate.
        AppLog.log("[3ds2apple] metal hud: %@", MetalHUD.diagnosticsLine)
        if let directory = PipelineCacheStats.directoryURL {
            AppLog.log("pipeline cache dir: %@", directory.path)
        }
        // The previous session's log is part of the exported diagnostics, so
        // this line shows a cold first run and a warmed later run side by side.
        AppLog.log("pipeline cache at launch: %@", PipelineCacheStats.read().summary)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
