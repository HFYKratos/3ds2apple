//
//  LauncherSettings.swift
//  3ds2apple macOS launcher
//
//  User-adjustable paths and switches. Everything is discoverable from the
//  repository itself; the settings exist so a user can point the launcher at
//  their own checkout, Xcode tooling or device-bridge binary.
//

import Foundation

@MainActor
final class LauncherSettings: ObservableObject {
    @Published var repoRoot: String
    @Published var outDir: String
    @Published var packCLIPath: String
    @Published var devpushPath: String
    @Published var deviceCLIPath: String
    @Published var deviceBundleID: String
    @Published var teamID: String
    @Published var buildMode: BuildMode
    @Published var mockDevice: Bool
    @Published var signPacks: Bool
    @Published var signingIdentity: String
    @Published var installStrategy: InstallStrategy
    /// UI language: follow the macOS system language or override it.
    @Published var language: LauncherLanguage
    /// Titles currently embedded in the installed library IPA (persisted so the
    /// UI can say "rebuild + reinstall to add this game" after a restart).
    @Published var libraryInstalledTitles: [String]
    @Published var libraryIPAPath: String
    @Published var libraryInstalledAt: Date?

    private let defaults: UserDefaults?
    private let persistEnabled: Bool

    init(persist: Bool, defaults: UserDefaults = .standard) {
        self.persistEnabled = persist
        self.defaults = persist ? defaults : nil
        let detectedRepo = SettingsDefaults.detectRepoRoot()
        repoRoot = persist ? defaults.string(forKey: Keys.repoRoot) ?? detectedRepo : detectedRepo
        outDir = persist ? defaults.string(forKey: Keys.outDir) ?? "out" : "out"
        packCLIPath = persist ? defaults.string(forKey: Keys.packCLI) ?? "" : ""
        devpushPath = persist ? defaults.string(forKey: Keys.devpush) ?? "" : ""
        deviceCLIPath = persist ? defaults.string(forKey: Keys.deviceCLI) ?? "" : ""
        deviceBundleID = persist
            ? defaults.string(forKey: Keys.bundleID) ?? SettingsDefaults.defaultBundleID
            : SettingsDefaults.defaultBundleID
        teamID = persist ? defaults.string(forKey: Keys.teamID) ?? "" : ""
        let modeRaw = persist ? defaults.string(forKey: Keys.buildMode) ?? "" : ""
        buildMode = BuildMode(rawValue: modeRaw) ?? .fake
        mockDevice = persist ? defaults.bool(forKey: Keys.mockDevice) : false
        signPacks = persist ? defaults.bool(forKey: Keys.signPacks) : false
        signingIdentity = persist ? defaults.string(forKey: Keys.signingIdentity) ?? "" : ""
        let strategyRaw = persist ? defaults.string(forKey: Keys.installStrategy) ?? "" : ""
        installStrategy = InstallStrategy(rawValue: strategyRaw) ?? .xcodebuild
        let languageRaw = persist ? defaults.string(forKey: Keys.language) ?? "" : ""
        language = LauncherLanguage(rawValue: languageRaw) ?? .system
        libraryInstalledTitles = persist ? defaults.stringArray(forKey: Keys.libraryTitles) ?? [] : []
        libraryIPAPath = persist ? defaults.string(forKey: Keys.libraryIPA) ?? "" : ""
        let installedAt = persist ? defaults.double(forKey: Keys.libraryInstalledAt) : 0
        libraryInstalledAt = installedAt > 0 ? Date(timeIntervalSince1970: installedAt) : nil
    }

    func save() {
        guard persistEnabled, let defaults else { return }
        defaults.set(repoRoot, forKey: Keys.repoRoot)
        defaults.set(outDir, forKey: Keys.outDir)
        defaults.set(packCLIPath, forKey: Keys.packCLI)
        defaults.set(devpushPath, forKey: Keys.devpush)
        defaults.set(deviceCLIPath, forKey: Keys.deviceCLI)
        defaults.set(deviceBundleID, forKey: Keys.bundleID)
        defaults.set(teamID, forKey: Keys.teamID)
        defaults.set(buildMode.rawValue, forKey: Keys.buildMode)
        defaults.set(mockDevice, forKey: Keys.mockDevice)
        defaults.set(signPacks, forKey: Keys.signPacks)
        defaults.set(signingIdentity, forKey: Keys.signingIdentity)
        defaults.set(installStrategy.rawValue, forKey: Keys.installStrategy)
        defaults.set(language.rawValue, forKey: Keys.language)
        defaults.set(libraryInstalledTitles, forKey: Keys.libraryTitles)
        defaults.set(libraryIPAPath, forKey: Keys.libraryIPA)
        defaults.set(libraryInstalledAt?.timeIntervalSince1970 ?? 0, forKey: Keys.libraryInstalledAt)
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
        static let packCLI = "zl.packCLI"
        static let devpush = "zl.devpush"
        static let deviceCLI = "zl.deviceCLI"
        static let bundleID = "zl.bundleID"
        static let teamID = "zl.teamID"
        static let buildMode = "zl.buildMode"
        static let mockDevice = "zl.mockDevice"
        static let signPacks = "zl.signPacks"
        static let signingIdentity = "zl.signingIdentity"
        static let installStrategy = "zl.installStrategy"
        static let language = "zl.language"
        static let libraryTitles = "zl.libraryTitles"
        static let libraryIPA = "zl.libraryIPA"
        static let libraryInstalledAt = "zl.libraryInstalledAt"
    }
}

enum SettingsDefaults {
    static let defaultBundleID = "com.kratos.3ds2apple"

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
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            home + "/3ds2apple",
            home + "/Projects/3ds2apple",
            home + "/repos/3ds2apple",
            "/mnt/f/project/3ds2apple",
        ]
        for candidate in candidates where isRepoRoot(candidate) {
            return candidate
        }
        return home + "/3ds2apple"
    }

    static func isRepoRoot(_ path: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: path + "/scripts/build-game-pack.sh")
            && fileManager.fileExists(atPath: path + "/builder/pack/Cargo.toml")
    }
}
