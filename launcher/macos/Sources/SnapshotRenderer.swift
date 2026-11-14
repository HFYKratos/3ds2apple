//
//  SnapshotRenderer.swift
//  3ds2apple macOS launcher
//
//  Headless screenshots for the build VM and for the docs. The macOS build VM
//  boots to the login window (no Aqua session), so the app cannot show a window
//  there and xcodebuild test cannot reach testmanagerd. SwiftUI ImageRenderer
//  draws our pure-SwiftUI view tree offscreen and writes PNGs, then the caller
//  exits:
//
//     3ds2apple-launcher --screenshot-dir launcher/macos/screenshots --mock
//
//  Only non-game UI is captured: library/task/log mock fixtures show title
//  metadata, never game pixels.
//

import SwiftUI
import AppKit

@MainActor
enum SnapshotRenderer {
    enum Theme: String {
        case dark
        case light
    }

    struct Shot {
        var name: String
        var scenario: MockScenario
        var height: CGFloat
    }

    static let shots: [Shot] = [
        Shot(name: "import", scenario: .importDetected, height: 1_020),
        Shot(name: "library", scenario: .library, height: 1_020),
        Shot(name: "build", scenario: .buildRunning, height: 1_020),
        Shot(name: "install", scenario: .install, height: 1_260),
        Shot(name: "device", scenario: .devicePush, height: 1_020),
        Shot(name: "activity", scenario: .activity, height: 1_040),
        Shot(name: "diagnostics", scenario: .diagnostics, height: 1_040),
    ]

    /// Render every screen into the directory; returns the written files.
    @discardableResult
    static func renderAll(to directory: URL, theme: Theme) -> [URL] {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("[screenshot] cannot create " + directory.path + ": " + error.localizedDescription)
            return []
        }
        var written: [URL] = []
        for shot in shots {
            let model = AppModel.mock(scenario: shot.scenario)
            let content = ScreenshotFrame(model: model, theme: theme, height: shot.height)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let representation = NSBitmapImageRep(data: tiff),
                  let png = representation.representation(using: .png, properties: [:]) else {
                print("[screenshot] failed to render " + shot.name)
                continue
            }
            let url = directory.appendingPathComponent("launcher-" + shot.name + "-" + theme.rawValue + ".png")
            do {
                try png.write(to: url)
                written.append(url)
                print("[screenshot] " + url.path + " (" + String(representation.pixelsWide) + "x" + String(representation.pixelsHigh) + ")")
            } catch {
                print("[screenshot] cannot write " + url.path + ": " + error.localizedDescription)
            }
        }
        return written
    }

    private struct ScreenshotFrame: View {
        let model: AppModel
        let theme: Theme
        var height: CGFloat = 1_020

        var body: some View {
            LauncherShellView(model: model)
                .frame(width: 1_180, height: height)
                .environment(\.colorScheme, theme == .dark ? ColorScheme.dark : ColorScheme.light)
                .environment(\.launcherScreenshotMode, true)
                .background(LauncherTheme.background)
        }
    }
}
