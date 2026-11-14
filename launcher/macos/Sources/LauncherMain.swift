//
//  LauncherMain.swift
//  3ds2apple macOS launcher
//
//  Entry point for three modes:
//
//    (no arguments)                              normal SwiftUI app
//    --selfcheck                                 headless logic self-checks, exit 0/1
//    --screenshot-dir DIR [--theme dark|light] [--lang all|en|zh] [--mock]
//                                                render the non-game UI to PNGs
//                                                offscreen (no GUI session needed)
//
//  The screenshot and self-check modes exist because the macOS build VM boots to
//  the login window: there is no Aqua session to show a window in, but an
//  offscreen SwiftUI ImageRenderer works. See docs/macos-launcher.md.
//

import Foundation
import SwiftUI
import AppKit

enum LauncherMode {
    case app
    case selfCheck
    case screenshots(directory: String, theme: String, language: String)
}

enum LauncherCLI {
    static func parse(arguments: [String], environment: [String: String]) -> LauncherMode {
        if environment["ZL_SELFCHECK"] == "1" {
            return .selfCheck
        }
        var screenshotDir = environment["ZL_SCREENSHOT_DIR"] ?? ""
        var theme = environment["ZL_SCREENSHOT_THEME"] ?? "dark"
        var language = environment["ZL_SCREENSHOT_LANG"] ?? "all"
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--selfcheck":
                return .selfCheck
            case "--screenshot-dir":
                if index + 1 < arguments.count {
                    screenshotDir = arguments[index + 1]
                    index += 1
                }
            case "--theme":
                if index + 1 < arguments.count {
                    theme = arguments[index + 1]
                    index += 1
                }
            case "--lang":
                if index + 1 < arguments.count {
                    language = arguments[index + 1]
                    index += 1
                }
            case "--mock":
                // Screenshot rendering is always seeded from the mock backends;
                // the flag is accepted for symmetry with the app.
                break
            default:
                break
            }
            index += 1
        }
        if !screenshotDir.isEmpty {
            return .screenshots(directory: screenshotDir, theme: theme, language: language)
        }
        return .app
    }
}

@main
struct LauncherMain {
    static func main() {
        let mode = LauncherCLI.parse(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        switch mode {
        case .selfCheck:
            MainActor.assumeIsolated {
                SelfCheck.runHeadless()
            }
        case .screenshots(let directory, let theme, let language):
            MainActor.assumeIsolated {
                let written = SnapshotRenderer.renderAll(
                    to: URL(fileURLWithPath: directory, isDirectory: true),
                    theme: SnapshotRenderer.Theme(rawValue: theme) ?? .dark,
                    language: language
                )
                FileHandle.standardOutput.write(
                    "[screenshot] wrote \(written.count) image(s) to \(directory)\n".data(using: .utf8)!
                )
                for url in written {
                    FileHandle.standardOutput.write("  \(url.lastPathComponent)\n".data(using: .utf8)!)
                }
                exit(written.isEmpty ? 1 : 0)
            }
        case .app:
            LauncherApp.main()
        }
    }
}

struct LauncherApp: App {
    @StateObject private var model: AppModel

    init() {
        Self.installApplicationIcon()
        let settings = LauncherSettings(persist: true)
        _model = StateObject(wrappedValue: AppModel(settings: settings, kind: .live))
    }

    private static func installApplicationIcon() {
        guard let icon = LauncherAsset.appIcon() else { return }
        NSApplication.shared.applicationIconImage = icon
    }

    var body: some Scene {
        WindowGroup(LauncherInfo.displayName) {
            LauncherShellView(model: model)
                .frame(minWidth: 1_020, minHeight: 680)
                .preferredColorScheme(nil)
        }
        .defaultSize(width: 1_180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
