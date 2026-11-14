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
        case gameDetail
    }

    struct Shot {
        var name: String
        var surface: Surface
        var themes: [Theme]
        var languages: [ResolvedLanguage]
        var height: CGFloat
        var prepare: (AppModel) -> Void = { _ in }
    }

    /// The non-game UI evidence set. Heights are chosen so the offscreen layout
    /// fits without a ScrollView (ImageRenderer needs an explicit frame).
    static let shots: [Shot] = [
        Shot(
            name: "library-empty",
            surface: .shell(.library),
            themes: [.dark, .light],
            languages: [.english],
            height: 700,
            prepare: { model in
                model.games = []
                model.settings.libraryInstalledTitles = []
                model.settings.libraryIPAPath = ""
                model.settings.libraryInstalledAt = nil
            }
        ),
        Shot(
            name: "library",
            surface: .shell(.library),
            themes: [.dark, .light],
            languages: [.english, .chinese],
            height: 900
        ),
        Shot(
            name: "import",
            surface: .shell(.importDetected),
            themes: [.dark, .light],
            languages: [.english, .chinese],
            height: 940
        ),
        Shot(
            name: "build-running",
            surface: .shell(.buildRunning),
            themes: [.dark],
            languages: [.english],
            height: 1_040
        ),
        Shot(
            name: "game-detail",
            surface: .gameDetail,
            themes: [.dark],
            languages: [.english],
            height: 1_120
        ),
        Shot(
            name: "settings",
            surface: .settings,
            themes: [.dark, .light],
            languages: [.english, .chinese],
            height: 1_320
        ),
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
        case .settings: return .diagnostics
        case .gameDetail: return .devicePush
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
            case .gameDetail:
                if let id = model.detailGameID {
                    GameDetailSheetView(model: model, gameID: id)
                } else {
                    Text("game detail")
                }
            }
        }

        private var snapshotWidth: CGFloat {
            switch surface {
            case .shell: return 1_180
            case .settings: return 1_180
            case .gameDetail: return 900
            }
        }
    }
}
