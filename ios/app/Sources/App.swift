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

import SwiftUI

@main
struct ThreeDS2AppleApp: App {
    init() {
        // Redirect stderr and start the in-app log before the runtime loads.
        AppLog.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
