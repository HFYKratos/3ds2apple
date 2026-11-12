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

    /// The mask the application delegate reports.
    static func currentMask() -> UIInterfaceOrientationMask {
        mask(for: AppSettings.shared.orientation)
    }

    /// Asks the active window scene to move to the preferred orientation and to
    /// re-evaluate the supported mask. Called when the setting changes.
    static func apply(_ lock: OrientationLock) {
        AppLog.log("[3ds2apple] orientation preference: %@", lock.rawValue)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return
        }
        let preferred = mask(for: lock)
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
}
