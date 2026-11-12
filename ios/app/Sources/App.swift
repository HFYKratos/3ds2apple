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
    init() {
        // Zakuro stores its Vulkan pipeline cache under XDG_CACHE_HOME (or
        // ~/.cache). On iOS the sandbox home's .cache is not writable, which
        // made every launch recompile pipelines and stutter on first use.
        // Point it at the app's Caches directory before the runtime loads.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            setenv("XDG_CACHE_HOME", caches.path, 1)
        }
        // Redirect stderr and start the in-app log before the runtime loads.
        AppLog.shared.start()
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            AppLog.log("pipeline cache dir: %@", caches.appendingPathComponent("zakuro/pipelines").path)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
