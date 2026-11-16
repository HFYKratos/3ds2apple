//
//  SnapshotRenderer.swift
//  3ds2apple macOS launcher
//
//  Headless screenshots for the build VM and the docs. The macOS build VM boots
//  to the login window (no Aqua session), so the app cannot show a window there
//  and xcodebuild test cannot reach testmanagerd. SwiftUI ImageRenderer draws our
//  pure-SwiftUI view tree offscreen and writes PNGs, then the caller exits:
//
//     3ds2apple-launcher --screenshot-dir screenshots --mock
//
//  Only non-game UI is captured: mock fixtures show title metadata and text
//  placeholders, never game pixels. Every shot is rendered in English and/or
//  Simplified Chinese so the localization evidence is in the package.
//

import SwiftUI
import AppKit

@MainActor
enum SnapshotRenderer {
    enum Theme: String, CaseIterable {
        case dark
        case light
    }

    enum Surface {
        case shell(MockScenario)
        case settings
    }

    struct Shot {
        var name: String
        var surface: Surface
        var themes: [Theme]
        var languages: [ResolvedLanguage]
        var height: CGFloat
        var prepare: (AppModel) -> Void = { _ in }
    }

    /// The non-game UI evidence set for the v2 Library -> Deploy flow. Heights
    /// are chosen so the offscreen layout fits without a ScrollView.
    static let shots: [Shot] = [
        Shot(name: "library-empty", surface: .shell(.library), themes: [.dark, .light], languages: [.english], height: 620,
             prepare: { model in
                 model.games = []
                 model.settings.libraryInstalledTitles = []
                 model.settings.installedBundleID = ""
                 model.settings.libraryIPAPath = ""
             }),
        Shot(name: "library", surface: .shell(.library), themes: [.dark, .light], languages: [.english, .chinese], height: 860),
        Shot(name: "library-not-ready", surface: .shell(.library), themes: [.dark], languages: [.english, .chinese], height: 860,
             prepare: { model in
                 var report = MockFixtures.readyEnvironment()
                 report.tools[0].state = .missing
                 report.tools[0].detail = "not found in the app bundle, the checkout or PATH"
                 report.apple.signingIdentityCount = 0
                 report.apple.provisioningProfileCount = 0
                 report.apple.teamID = ""
                 model.envReport = report
                 model.appleReadiness = report.apple
                 model.readiness = report.readinessStatus
             }),
        Shot(name: "deploy-selected", surface: .shell(.deploySelection), themes: [.dark], languages: [.english, .chinese], height: 1_120),
        Shot(name: "deploy-running", surface: .shell(.deployRunning), themes: [.dark], languages: [.english], height: 1_520),
        Shot(name: "deploy-done", surface: .shell(.deployDone), themes: [.dark], languages: [.english, .chinese], height: 1_580),
        Shot(name: "deploy-failed", surface: .shell(.deployFailed), themes: [.dark], languages: [.english], height: 1_420),
        Shot(name: "settings", surface: .settings, themes: [.dark, .light], languages: [.english, .chinese], height: 980),
    ]

    /// Render the selected theme/language set into the directory; returns files.
    @discardableResult
    static func renderAll(to directory: URL, theme: Theme, language: String) -> [URL] {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("[screenshot] cannot create " + directory.path + ": " + error.localizedDescription)
            return []
        }
        let wantedLanguages: [ResolvedLanguage]
        switch language.lowercased() {
        case "en", "english": wantedLanguages = [.english]
        case "zh", "zh-hans", "chinese": wantedLanguages = [.chinese]
        default: wantedLanguages = [.english, .chinese]
        }

        var written: [URL] = []
        for shot in shots where shot.themes.contains(theme) {
            for resolved in wantedLanguages where shot.languages.contains(resolved) {
                let model = AppModel.mock(scenario: scenario(for: shot.surface))
                model.settings.language = resolved == .chinese ? .chinese : .english
                shot.prepare(model)
                let strings = LauncherStrings(language: resolved)
                let content = ScreenshotFrame(
                    model: model,
                    strings: strings,
                    surface: shot.surface,
                    theme: theme,
                    height: shot.height
                )
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let representation = NSBitmapImageRep(data: tiff),
                      let png = representation.representation(using: .png, properties: [:]) else {
                    print("[screenshot] failed to render " + shot.name + " (" + resolved.rawValue + ")")
                    continue
                }
                let languageTag = resolved == .chinese ? "zh" : "en"
                let url = directory.appendingPathComponent("launcher-" + shot.name + "-" + theme.rawValue + "-" + languageTag + ".png")
                do {
                    try png.write(to: url)
                    written.append(url)
                    print("[screenshot] " + url.path + " (" + String(representation.pixelsWide) + "x" + String(representation.pixelsHigh) + ")")
                } catch {
                    print("[screenshot] cannot write " + url.path + ": " + error.localizedDescription)
                }
            }
        }
        return written
    }

    private static func scenario(for surface: Surface) -> MockScenario {
        switch surface {
        case .shell(let scenario): return scenario
        case .settings: return .settings
        }
    }

    private struct ScreenshotFrame: View {
        let model: AppModel
        let strings: LauncherStrings
        let surface: Surface
        let theme: Theme
        var height: CGFloat

        var body: some View {
            content
                .frame(width: snapshotWidth, height: height)
                .environment(\.colorScheme, theme == .dark ? ColorScheme.dark : ColorScheme.light)
                .environment(\.launcherScreenshotMode, true)
                .background(LauncherTheme.background)
        }

        @ViewBuilder
        private var content: some View {
            switch surface {
            case .shell:
                LauncherShellView(model: model)
            case .settings:
                SettingsSheetView(model: model)
            }
        }

        private var snapshotWidth: CGFloat { 1_180 }
    }
}