//
//  LauncherSettings.swift
//  3ds2apple macOS launcher
//
//  The launcher's own persisted state, deliberately small after the v2 flow
//  revision (launcher/macos/README.md): language, detected checkout, the
//  portable data root and the installed-library facts. Build modes, install
//  strategies, tool paths, Team ID, device UDID and bundle-ID overrides are
//  gone from the user-facing UI; tools are auto-detected and the installed
//  bundle ID is read back from the app that was actually installed.
//
//  Since 0.2.4 (Windows launcher 0.2.4 parity) every writable path comes from
//  one portable data root (PortableData.swift): <folder containing the .app>/
//  3ds2apple-data when writable, otherwise ~/Library/Application Support/
//  3ds2apple. The pack workspace, logs, compile staging and composed IPAs all
//  live there instead of in the checkout. The previous <checkout>/out workspace
//  and launcher log are adopted once on first launch with the new root.
//

import Foundation

@MainActor
final class LauncherSettings: ObservableObject {
    @Published var repoRoot: String
    /// Absolute pack-CLI workspace root (<dataRoot>/workspace). Never a
    /// checkout-relative "out" any more; kept as a String for the CLI wrapper.
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
    /// Last composed (Deploy) or exported single-game IPA, re-signable via
    /// "Refresh signing" after the free Apple ID 7-day profile expires.
    @Published var lastInstallableIpaPath: String
    @Published var lastInstallableIpaAt: Date?
    /// Path of the last xcodebuild-signed shell app, reused only for its
    /// entitlements/provisioning profile when re-signing the saved IPA.
    @Published var lastSignedShellAppPath: String
    /// Deploy -> Advanced build settings (persisted; defaults keep -O2/no LTO/no fast-math).
    @Published var advancedAotOptLevel: String
    @Published var advancedAotLto: Bool
    @Published var advancedAotFastMath: Bool
    /// RomPath overrides for games imported from a .32a (persisted): the entry's
    /// RomPath is the imported package path, and the embedded GameRom is resolved
    /// from it for the IPA export and the Documents push.
    @Published var importedRomPaths: [String: String]
    /// Human summary when the previous <checkout>/out workspace was adopted on
    /// this launch (nil when there was nothing to migrate).
    @Published var migrationSummary: String?

    /// Resolved portable data root for this launch (read-only after init).
    let dataRoot: DataRootDecision

    private let defaults: UserDefaults?
    private let persistEnabled: Bool

    init(persist: Bool, defaults: UserDefaults = .standard, dataRootOverride: String? = nil) {
        self.persistEnabled = persist
        self.defaults = persist ? defaults : nil
        self.dataRoot = PortableData.resolve(dataRootOverride: dataRootOverride)
        let detectedRepo = SettingsDefaults.detectRepoRoot()
        if persist, let stored = defaults.string(forKey: Keys.repoRoot), SettingsDefaults.isRepoRoot(stored) {
            repoRoot = stored
        } else {
            repoRoot = detectedRepo
        }
        outDir = self.dataRoot.workspaceRoot
        let languageRaw = persist ? defaults.string(forKey: Keys.language) ?? "" : ""
        language = LauncherLanguage(rawValue: languageRaw) ?? .system
        libraryInstalledTitles = persist ? defaults.stringArray(forKey: Keys.libraryTitles) ?? [] : []
        libraryIPAPath = persist ? defaults.string(forKey: Keys.libraryIPA) ?? "" : ""
        let installedAt = persist ? defaults.double(forKey: Keys.libraryInstalledAt) : 0
        libraryInstalledAt = installedAt > 0 ? Date(timeIntervalSince1970: installedAt) : nil
        installedBundleID = persist ? defaults.string(forKey: Keys.installedBundleID) ?? "" : ""
        lastInstallableIpaPath = persist ? defaults.string(forKey: Keys.lastInstallableIpa) ?? "" : ""
        let installableAt = persist ? defaults.double(forKey: Keys.lastInstallableIpaAt) : 0
        lastInstallableIpaAt = installableAt > 0 ? Date(timeIntervalSince1970: installableAt) : nil
        lastSignedShellAppPath = persist ? defaults.string(forKey: Keys.lastSignedShellApp) ?? "" : ""
        advancedAotOptLevel = persist ? defaults.string(forKey: Keys.aotOptLevel) ?? "O2" : "O2"
        advancedAotLto = persist ? defaults.bool(forKey: Keys.aotLto) : false
        advancedAotFastMath = persist ? defaults.bool(forKey: Keys.aotFastMath) : false
        importedRomPaths = persist
            ? (defaults.dictionary(forKey: Keys.importedRomPaths) as? [String: String] ?? [:])
            : [:]
    }

    /// Recorded .32a path for a game imported from a build package.
    func importedRomPath(for titleID: String) -> String? {
        importedRomPaths[titleID.uppercased()]
    }

    /// Persist the imported .32a path for a game (the card shows it and the
    /// single-game IPA / deploy resolve the embedded GameRom from it).
    func setImportedRomPath(_ path: String, for titleID: String) {
        importedRomPaths[titleID.uppercased()] = path
    }

    /// Current advanced codegen options (normalised to a supported level).
    var advancedBuildOptions: AdvancedBuildOptions {
        AdvancedBuildOptions(optLevel: advancedAotOptLevel, lto: advancedAotLto, fastMath: advancedAotFastMath).normalized
    }

    /// Remember the last IPA that can be re-signed later (Deploy compose or
    /// single-game export). The signed shell app is stored for entitlements/profile.
    func recordInstallableIpa(_ ipaPath: String, signedShellApp: String? = nil) {
        guard !ipaPath.isEmpty else { return }
        lastInstallableIpaPath = ipaPath
        lastInstallableIpaAt = Date()
        if let signedShellApp, !signedShellApp.isEmpty {
            lastSignedShellAppPath = signedShellApp
        }
        save()
    }

    /// Persist one advanced-options change (applies to the next build; the same
    /// options are part of the Windows launcher's build-cache key).
    func setAdvancedBuildOptions(_ options: AdvancedBuildOptions) {
        let normalized = options.normalized
        advancedAotOptLevel = normalized.optLevel
        advancedAotLto = normalized.lto
        advancedAotFastMath = normalized.fastMath
        save()
    }

    /// Reset the advanced build settings to the documented defaults.
    func resetAdvancedBuildOptions() {
        setAdvancedBuildOptions(AdvancedBuildOptions())
    }

    func save() {
        guard persistEnabled, let defaults else { return }
        defaults.set(repoRoot, forKey: Keys.repoRoot)
        defaults.set(language.rawValue, forKey: Keys.language)
        defaults.set(libraryInstalledTitles, forKey: Keys.libraryTitles)
        defaults.set(libraryIPAPath, forKey: Keys.libraryIPA)
        defaults.set(libraryInstalledAt?.timeIntervalSince1970 ?? 0, forKey: Keys.libraryInstalledAt)
        defaults.set(installedBundleID, forKey: Keys.installedBundleID)
        defaults.set(lastInstallableIpaPath, forKey: Keys.lastInstallableIpa)
        defaults.set(lastInstallableIpaAt?.timeIntervalSince1970 ?? 0, forKey: Keys.lastInstallableIpaAt)
        defaults.set(lastSignedShellAppPath, forKey: Keys.lastSignedShellApp)
        defaults.set(advancedAotOptLevel, forKey: Keys.aotOptLevel)
        defaults.set(advancedAotLto, forKey: Keys.aotLto)
        defaults.set(advancedAotFastMath, forKey: Keys.aotFastMath)
        defaults.set(importedRomPaths, forKey: Keys.importedRomPaths)
    }

    // MARK: - Portable data root paths

    var dataRootPath: String { dataRoot.dataRoot }

    /// Absolute path of the package/workspace output tree.
    var outRootURL: URL { URL(fileURLWithPath: dataRoot.workspaceRoot, isDirectory: true) }
    var logsRootURL: URL { URL(fileURLWithPath: dataRoot.logsRoot, isDirectory: true) }
    var stagingRootURL: URL { URL(fileURLWithPath: dataRoot.stagingRoot, isDirectory: true) }
    var buildRootURL: URL { URL(fileURLWithPath: dataRoot.buildRoot, isDirectory: true) }
    var ipaRootURL: URL { URL(fileURLWithPath: dataRoot.ipaRoot, isDirectory: true) }
    var repoRootURL: URL { URL(fileURLWithPath: repoRoot, isDirectory: true) }

    /// Engineering label for the resolved data-root kind (raw, not translated;
    /// the UI shows the localized description separately).
    var dataRootKindLabel: String { dataRoot.kind.rawValue }

    /// Create the data folders and adopt the previous <checkout>/out workspace
    /// (and pre-0.2.4 launcher log) exactly once. Returns log lines; never
    /// throws: a data-root problem must not stop the launcher.
    func prepareDataRoot() -> [String] {
        var lines: [String] = []
        do {
            try PortableData.ensureDirectories(dataRoot)
        } catch {
            lines.append("could not create the portable data folders: " + error.localizedDescription)
        }
        lines.append(dataRoot.summary())
        guard persistEnabled else { return lines }

        let legacyWorkspace = repoRoot + "/" + PortableData.legacyWorkspaceDirectoryName
        if legacyWorkspace != dataRoot.workspaceRoot {
            let migration = PortableData.migrateWorkspaceIfNeeded(
                workspaceRoot: dataRoot.workspaceRoot,
                legacyWorkspaceRoot: legacyWorkspace
            )
            if migration.migrated {
                let summary = "adopted " + String(migration.filesCopied) + " file(s) from the previous workspace "
                    + legacyWorkspace + " into the portable data folder"
                migrationSummary = summary
                lines.append(summary)
            } else if migration.attempted, let warning = migration.warning {
                lines.append("workspace migration warning: " + warning)
            }
        }
        let adoptedLogs = PortableData.migrateLegacyLogs(
            logsRoot: dataRoot.logsRoot,
            legacyLogDirectories: PortableData.legacyLogDirectories(
                applicationSupportRoot: dataRoot.applicationSupportRoot
            )
        )
        if adoptedLogs > 0 {
            lines.append("adopted " + String(adoptedLogs) + " previous launcher log file(s)")
        }
        return lines
    }

    private enum Keys {
        static let repoRoot = "zl.repoRoot"
        static let language = "zl.language"
        static let libraryTitles = "zl.libraryTitles"
        static let libraryIPA = "zl.libraryIPA"
        static let libraryInstalledAt = "zl.libraryInstalledAt"
        static let installedBundleID = "zl.installedBundleID"
    static let lastInstallableIpa = "zl.lastInstallableIpa"
    static let lastInstallableIpaAt = "zl.lastInstallableIpaAt"
    static let lastSignedShellApp = "zl.lastSignedShellApp"
        static let aotOptLevel = "zl.aotOptLevel"
        static let aotLto = "zl.aotLto"
        static let aotFastMath = "zl.aotFastMath"
    static let importedRomPaths = "zl.libraryImportedRomPaths"
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
