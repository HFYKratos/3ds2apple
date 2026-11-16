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
        // MoltenVK's MVK_CONFIG_* performance parameters are environment
        // variables read when its first Vulkan instance/device is created.
        // Apply the developer A/B overrides before anything can create one; a
        // normal launch sets no THREEDS2APPLE_MVK_CONFIG and keeps the
        // framework defaults (see MoltenVKTuning.swift and docs/performance.md
        // §5.3).
        MoltenVKTuning.applyFromEnvironment()
        // Metal Performance HUD: the Metal device reads MTL_HUD_ENABLED once,
        // when it is created. The device here is MoltenVK's, created by the
        // first zk_create()/load, so the persisted Settings switch has to
        // become an environment variable before that. The layer-level
        // developerHUDProperties switch in MetalScreenView then shows/hides the
        // HUD on the live layer; flipping it while a game runs does not need a
        // relaunch, but a build whose Metal device was created before the
        // variable was set does (see SettingsView and MetalScreenView).
        MetalHUD.apply(enabled: AppSettings.shared.systemMetalHUD)
        // GPU backend: the Vulkan renderer loads MoltenVK from the app bundle at
        // run time. Point the runtime at the embedded framework before the first
        // device is created (the iOS patch has the same default; setting it here
        // makes the lookup explicit and logged).
        MetalBackend.configureForLaunch()
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
        AppLog.log("[3ds2apple] metal backend: %@", MetalBackend.diagnosticsLine)
        AppLog.log("[3ds2apple] %@", MoltenVKTuning.diagnosticsLine)
        if !MetalBackend.isMoltenVKEmbedded {
            // The single most useful line for a "slow game / no HUD" device log:
            // without MoltenVK the presented GPU path cannot start at all.
            AppLog.log("[3ds2apple] PERFORMANCE WARNING: MoltenVK.framework is not in this app; the 3D draws in software (PICA200 on the CPU), the CAMetalLayer path is unavailable and the Metal HUD cannot appear. Deploy the launcher's 0.2.2+ shell template, which embeds MoltenVK.")
        }
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
