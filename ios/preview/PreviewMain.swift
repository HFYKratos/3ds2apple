//
//  PreviewMain.swift
//  3ds2apple (UI preview harness)
//
//  A second, simulator-only @main app that shows one real screen of the shell
//  without starting a console. ios/preview/project.yml compiles the same
//  ios/app/Sources into the 3ds2apple-preview target (minus App.swift) and
//  links ios/preview/generated/ZakuroStub.c instead of libzakuro_ios.a, so the
//  UI can be built and screenshotted in the iOS Simulator on the Intel macOS
//  build VM.
//
//  The screen is chosen with the ZKPREVIEW_SCREEN environment variable:
//
//      home (default)   HomeView(model:settings:library:), catalog-seeded
//      settings         NavigationStack { SettingsView(settings:model:) }
//      quick            QuickDisplaySettingsView(settings:)
//      ingame           InGameMenuView(romName:settings:saveStates:callbacks:)
//      savemanager      NavigationStack { SaveManagerView(model:saveStates:) }
//      about            NavigationStack { AboutView(model:) }
//      home-empty       HomeView with an empty library
//      home-no-aot      HomeView after tapping a game the build did not compile
//
//  ZKPREVIEW_DARK=1 forces the dark appearance. The app never calls zk_create()
//  or any other runtime function that would start a console: the zk_* names the
//  shell sources reference resolve to the empty stubs.
//
//  scripts/ios-ui-preview.sh builds this target and screenshots every screen;
//  the headless Catalyst path is the one used on this VM.
//

import SwiftUI

@main
struct PreviewApp: App {
    /// The same shared singletons the shell uses. GameLibrary.load() runs in its
    /// initializer; the preview app carries no GameCatalog.json, so
    /// SnapshotRenderer installs a synthetic catalog before the library shots.
    @StateObject private var library = GameLibrary.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var model: ROMSession
    @StateObject private var saveStates: SaveStateSupport

    init() {
        // Headless screenshot mode: the build VM has no GUI session, so draw the
        // real views offscreen and exit instead of waiting for a scene.
        if let directory = ProcessInfo.processInfo.environment["ZKPREVIEW_SHOT_DIR"],
           !directory.isEmpty {
            // Let UIApplication finish launching first: the UIWindow variant needs
            // a live application even though there is no signed-in GUI session.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let written = SnapshotRenderer.renderAll(
                    to: URL(fileURLWithPath: directory, isDirectory: true)
                )
                print("[ui-shot] wrote \(written.count) file(s)")
                exit(written.isEmpty ? 1 : 0)
            }
        }
        // ROMSession() is inert: it restores the last-played name and builds
        // empty stats, but no console is created and zk_create() is not called.
        let session = ROMSession()
        _model = StateObject(wrappedValue: session)
        _saveStates = StateObject(wrappedValue: SaveStateSupport(runtime: session))
    }

    var body: some Scene {
        WindowGroup {
            PreviewRoot(
                model: model,
                settings: settings,
                library: library,
                saveStates: saveStates
            )
        }
    }
}

/// Values of the environment variables the screenshot script sets.
private enum PreviewEnvironment {
    /// ZKPREVIEW_SCREEN; the default matches the first screenshot.
    static var screen: String {
        let raw = ProcessInfo.processInfo.environment["ZKPREVIEW_SCREEN"] ?? "home"
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// ZKPREVIEW_DARK=1 forces dark mode; anything else keeps the simulator
    /// appearance (light by default).
    static var darkMode: Bool {
        ProcessInfo.processInfo.environment["ZKPREVIEW_DARK"] == "1"
    }
}

/// One real screen of the shell, chosen by ZKPREVIEW_SCREEN. Every branch uses
/// the production view with no-op callbacks, so no game is ever started.
private struct PreviewRoot: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: GameLibrary
    @ObservedObject var saveStates: SaveStateSupport

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
            // Catalyst runs in a resizable macOS window; pin the content to an
            // iPhone-sized frame so the screenshot shows the real iPhone layout.
            content
                .frame(width: 402, height: 780)
            #else
            content
            #endif
        }
        .preferredColorScheme(forceDark ? .dark : nil)
    }

    /// The in-game overlay is always dark; ZKPREVIEW_DARK forces dark elsewhere.
    private var forceDark: Bool {
        PreviewEnvironment.darkMode || PreviewEnvironment.screen == "ingame"
    }

    @ViewBuilder
    private var content: some View {
        switch PreviewEnvironment.screen {
        case "settings":
            NavigationStack {
                SettingsView(settings: settings, model: model)
            }
        case "quick":
            QuickDisplaySettingsView(settings: settings)
        case "ingame":
            ZStack {
                Color.black.ignoresSafeArea()
                InGameMenuView(
                    romName: "Pokémon Y",
                    settings: settings,
                    saveStates: saveStates,
                    onResume: {},
                    onReset: {},
                    onDisplaySettings: {},
                    onSaveManager: {},
                    onDiagnostics: {},
                    onExit: {},
                    onLoadStateCompleted: {}
                )
            }
        case "savemanager":
            NavigationStack {
                SaveManagerView(model: model, saveStates: saveStates)
            }
        case "about":
            NavigationStack {
                AboutView(model: model)
            }
        default:
            // "home" and any unknown value: show the home screen instead of a
            // blank app, so a typo in ZKPREVIEW_SCREEN is still visible in the
            // screenshot (the script validates the names it passes).
            HomeView(model: model, settings: settings, library: library)
        }
    }
}
