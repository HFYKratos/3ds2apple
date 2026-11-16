//
//  LauncherSettings.swift
//  3ds2apple macOS launcher
//
//  The launcher's own persisted state, deliberately small after the v2 flow
//  revision (docs/launcher-flow-v2.md): language, detected checkout/out paths
//  and the installed-library facts. Build modes, install strategies, tool paths,
//  Team ID, device UDID and bundle-ID overrides are gone from the user-facing UI;
//  tools are auto-detected and the installed bundle ID is read back from the app
//  that was actually installed.
//

import Foundation

@MainActor
final class LauncherSettings: ObservableObject {
    @Published var repoRoot: String
    @Published var outDir: String
    /// UI language: follow the macOS system language or override it.
    @Published var language: LauncherLanguage
    /// Titles currently embedded in the installed library IPA (persisted so the
    /// Deploy page can show what is already on the phone after a restart).
    @Published var libraryInstalledTitles: [String]
    @Published var libraryIPAPath: String
    @Published var libraryInstalledAt: Date?
    /// The bundle identifier of the app that was actually installed (read back
    /// from the signed app, or confirmed through the device bridge). The
    /// Documents push always uses this value, never a template default.
    @Published var installedBundleID: String

    private let defaults: UserDefaults?
    private let persistEnabled: Bool

    init(persist: Bool, defaults: UserDefaults = .standard) {
        self.persistEnabled = persist
        self.defaults = persist ? defaults : nil
        let detectedRepo = SettingsDefaults.detectRepoRoot()
        repoRoot = persist ? defaults.string(forKey: Keys.repoRoot) ?? detectedRepo : detectedRepo
        outDir = persist ? defaults.string(forKey: Keys.outDir) ?? "out" : "out"
        let languageRaw = persist ? defaults.string(forKey: Keys.language) ?? "" : ""
        language = LauncherLanguage(rawValue: languageRaw) ?? .system
        libraryInstalledTitles = persist ? defaults.stringArray(forKey: Keys.libraryTitles) ?? [] : []
        libraryIPAPath = persist ? defaults.string(forKey: Keys.libraryIPA) ?? "" : ""
        let installedAt = persist ? defaults.double(forKey: Keys.libraryInstalledAt) : 0
        libraryInstalledAt = installedAt > 0 ? Date(timeIntervalSince1970: installedAt) : nil
        installedBundleID = persist ? defaults.string(forKey: Keys.installedBundleID) ?? "" : ""
    }

    func save() {
        guard persistEnabled, let defaults else { return }
        defaults.set(repoRoot, forKey: Keys.repoRoot)
        defaults.set(outDir, forKey: Keys.outDir)
        defaults.set(language.rawValue, forKey: Keys.language)
        defaults.set(libraryInstalledTitles, forKey: Keys.libraryTitles)
        defaults.set(libraryIPAPath, forKey: Keys.libraryIPA)
        defaults.set(libraryInstalledAt?.timeIntervalSince1970 ?? 0, forKey: Keys.libraryInstalledAt)
        defaults.set(installedBundleID, forKey: Keys.installedBundleID)
    }

    /// Absolute path of the package output tree.
    var outRootURL: URL {
        let url = URL(fileURLWithPath: outDir)
        if outDir.hasPrefix("/") { return url }
        return URL(fileURLWithPath: repoRoot, isDirectory: true).appendingPathComponent(outDir)
    }

    var repoRootURL: URL { URL(fileURLWithPath: repoRoot, isDirectory: true) }

    private enum Keys {
        static let repoRoot = "zl.repoRoot"
        static let outDir = "zl.outDir"
        static let language = "zl.language"
        static let libraryTitles = "zl.libraryTitles"
        static let libraryIPA = "zl.libraryIPA"
        static let libraryInstalledAt = "zl.libraryInstalledAt"
        static let installedBundleID = "zl.installedBundleID"
    }
}

enum SettingsDefaults {
    /// The application bundle identifier the iOS shell project builds with. It
    /// is only a template hint: the Deploy flow reads the real value from the
    /// built/installed app and persists it as LauncherSettings.installedBundleID.
    static let shellTemplateBundleID = "com.kratos.3ds2apple"

    /// Pick a repository root without guessing wildly:
    ///   1. THREEDS2APPLE_ROOT environment variable,
    ///   2. walk up from the running executable (covers a build inside the repo),
    ///   3. common checkout locations.
    static func detectRepoRoot() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["THREEDS2APPLE_ROOT"], !explicit.isEmpty {
            return explicit
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var directory = executable.deletingLastPathComponent()
            for _ in 0..<8 {
                if isRepoRoot(directory.path) { return directory.path }
                directory = directory.deletingLastPathComponent()
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/3ds2apple", home + "/Projects/3ds2apple", home + "/repos/3ds2apple"]
        for candidate in candidates where isRepoRoot(candidate) {
            return candidate
        }
        return home + "/3ds2apple"
    }

    static func isRepoRoot(_ path: String) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path + "/ios/app") else { return false }
        return manager.fileExists(atPath: path + "/scripts") || manager.fileExists(atPath: path + "/builder")
    }
}
