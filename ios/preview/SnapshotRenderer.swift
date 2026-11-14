//
//  SnapshotRenderer.swift
//  3ds2apple UI preview
//
//  Headless UI snapshots for the Mac Catalyst preview app. The build VM boots to
//  the login window (no Aqua session), so the app cannot show a window and
//  xcodebuild test cannot reach testmanagerd. This renderer draws the real
//  SwiftUI views offscreen with UIHostingController + layer.render and writes
//  PNGs, then the caller exits:
//
//      ZKPREVIEW_SHOT_DIR=/tmp/3ds2apple-ui-shots 3ds2apple-preview.app/Contents/MacOS/3ds2apple-preview
//
//  It is compiled into the preview app and the preview test target only.
//

import SwiftUI
import UIKit

@MainActor
enum SnapshotRenderer {
    /// Default portrait content size; ZKPREVIEW_SIZE=844x390 renders landscape.
    static let size: CGSize = {
        let raw = ProcessInfo.processInfo.environment["ZKPREVIEW_SIZE"] ?? ""
        let parts = raw.lowercased().split(separator: "x")
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 1, h > 1 {
            return CGSize(width: w, height: h)
        }
        return CGSize(width: 402, height: 780)
    }()

    /// Renders every shell screen into `directory`; returns the written files.
    @discardableResult
    static func renderAll(to directory: URL) -> [URL] {
        var written: [URL] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("[ui-shot] cannot create \(directory.path): \(error)")
            return written
        }

        let settings = AppSettings.shared
        if ProcessInfo.processInfo.environment["ZKPREVIEW_HIDE_CONTROLS"] == "1" {
            settings.showTouchControls = false
        }
        let model = ROMSession()
        let saveStates = SaveStateSupport(runtime: model)
        let library = GameLibrary.shared

        // Optional subset for quick, low-risk single-screen renders:
        // ZKPREVIEW_SHOT_ONLY=home,settings
        let only = ProcessInfo.processInfo.environment["ZKPREVIEW_SHOT_ONLY"]
            .map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }

        func shot(_ name: String, _ view: AnyView) {
            if let only, !only.contains(name) { return }
            if let url = render(name, view, to: directory) {
                written.append(url)
            }
        }

        // Empty library first: a shell built without any game catalog.
        shot("home-empty", AnyView(HomeView(model: model, settings: settings, library: library)))

        // Catalog-seeded library. The preview app carries no generated
        // GameCatalog.json, so the catalog is installed in memory; one entry is
        // statically linked for the screenshot (the real build's zk_linked_code()
        // is a C stub here) and one is deliberately not built by the desktop
        // step. Built games get the green AOT badge.
        let previewCatalog = GameCatalog(games: [
            GameCatalogGame(
                titleID: "0004000000055E00",
                displayName: "Pokémon Y",
                productCode: "CTR-P-EK2A",
                aot: true,
                aotVersion: 1
            ),
            GameCatalogGame(
                titleID: "0004000000086400",
                displayName: "Animal Crossing: New Leaf",
                productCode: "CTR-P-ECJE",
                aot: true,
                aotVersion: 1,
                packFile: "Frameworks/GamePack-0004000000086400.dylib"
            ),
            GameCatalogGame(
                titleID: "0004000000030600",
                displayName: "Super Mario 3D Land",
                productCode: "CTR-P-AREJ",
                aot: false
            ),
        ])
        library.installPreviewLibrary(previewCatalog, playTimes: [
            "0004000000055E00": Date().addingTimeInterval(-2 * 86_400),
            "0004000000086400": Date().addingTimeInterval(-6 * 86_400),
        ])
        AOTPackageLoader.shared.previewStaticTitleIDs = ["0004000000055E00"]
        shot("home", AnyView(HomeView(model: model, settings: settings, library: library)))

        // "No AOT build for this game": tapping the entry the desktop build did
        // not compile publishes the same notice the shipping app shows.
        if let notBuilt = library.entries.first(where: { !$0.aot }) {
            model.start(notBuilt)
        }
        shot("home-no-aot", AnyView(HomeView(model: model, settings: settings, library: library)))
        shot("settings", AnyView(NavigationStack { SettingsView(settings: settings, model: model) }))
        shot("quick", AnyView(QuickDisplaySettingsView(settings: settings)))
        shot("ingame", AnyView(ZStack {
            Color.black.ignoresSafeArea()
            InGameMenuView(
                romName: "Pokemon Y",
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
        }))
        shot("savemanager", AnyView(NavigationStack {
            SaveManagerView(model: model, saveStates: saveStates)
        }))
        shot("about", AnyView(NavigationStack { AboutView(model: model) }))
        // Game screen chrome with a fake loaded session (no console is created).
        model.previewSetLoaded(name: "Pokemon Y")
        shot("game", AnyView(GameView(model: model, settings: settings)))
        return written
    }

    private static func render(_ name: String, _ view: AnyView, to directory: URL) -> URL? {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.backgroundColor = .clear
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Variant A: SwiftUI ImageRenderer (purely offscreen; may skip lazy
        // containers such as Form/List depending on the OS build).
        if let data = imageRendererPNG(view) {
            let urlA = directory.appendingPathComponent("\(name)-renderer.png")
            try? data.write(to: urlA)
        }

        // Variant C: UIHostingController inside an offscreen UIWindow. UIKit
        // containers (Form/List/NavigationStack) only build their display list
        // once attached to a window, which ImageRenderer cannot do.
        if let data = windowLayerPNG(view) {
            let urlC = directory.appendingPathComponent("\(name)-window.png")
            try? data.write(to: urlC)
        }

        // Variant B: UIHostingController hierarchy drawn into a bitmap.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            host.view.layer.render(in: context.cgContext)
        }
        guard let data = image.pngData() else {
            print("[ui-shot] \(name): cannot encode PNG")
            return nil
        }
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            print("[ui-shot] \(url.path)")
            return url
        } catch {
            print("[ui-shot] \(name): \(error)")
            return nil
        }
    }
    private static func imageRendererPNG(_ view: AnyView) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        guard let image = renderer.uiImage else { return nil }
        return image.pngData()
    }
    private static func windowLayerPNG(_ view: AnyView) -> Data? {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        return image.pngData()
    }
}