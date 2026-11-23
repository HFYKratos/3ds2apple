//
//  ApplicationDelegate.swift
//  3ds2apple
//
//  Minimal UIKit application delegate for the SwiftUI lifecycle. It exists so
//  the orientation preference in Settings can restrict which orientations the
//  app supports; everything else stays in the SwiftUI views.
//

import SwiftUI
import UIKit

/// Applies the orientation preference.
enum AppOrientation {
    /// Supported orientations for a preference.
    static func mask(for lock: OrientationLock) -> UIInterfaceOrientationMask {
        switch lock {
        case .automatic: return .all
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }

    /// A temporary mask set by an editor (for example a landscape custom
    /// screen layout editor forcing landscape), or nil for the Settings mask.
    private static var overrideMask: UIInterfaceOrientationMask?

    /// The mask the application delegate reports.
    static func currentMask() -> UIInterfaceOrientationMask {
        overrideMask ?? mask(for: AppSettings.shared.orientation)
    }

    /// Forces one mask while an editor is presented (round 0.1.6).
    static func beginOverride(_ mask: UIInterfaceOrientationMask) {
        overrideMask = mask
        request(mask)
    }

    /// Drops the override and returns to the Settings orientation mask.
    static func endOverride() {
        overrideMask = nil
        request(mask(for: AppSettings.shared.orientation))
    }

    /// Asks the active window scene to move to the preferred orientation and to
    /// re-evaluate the supported mask. Called when the setting changes.
    static func apply(_ lock: OrientationLock) {
        AppLog.log("[3ds2apple] orientation preference: %@", lock.rawValue)
        request(mask(for: lock))
    }

    private static func request(_ preferred: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: preferred))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// Application delegate handed to SwiftUI through `UIApplicationDelegateAdaptor`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientation.currentMask()
    }

    /// iOS warns before memory pressure turns into a termination. The runtime
    /// owns the large allocations (FCRAM, the software renderer, the GPU
    /// resources), so the shell cannot free much here; it records the warning so
    /// a device log and the exported diagnostics say whether a session ran
    /// through memory pressure.
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppMemoryPressure.shared.noteWarning()
        AppLog.log(
            "[3ds2apple] memory warning: the system is low on memory (warning %ld of this app run)",
            AppMemoryPressure.shared.count
        )
    }
}

/// Memory-pressure warnings observed during this app run. Diagnostics only: the
/// runtime owns the memory, the shell can only report what the system did.
final class AppMemoryPressure {
    static let shared = AppMemoryPressure()
    /// Number of `applicationDidReceiveMemoryWarning` callbacks this run.
    private(set) var count = 0

    func noteWarning() {
        count += 1
    }
}