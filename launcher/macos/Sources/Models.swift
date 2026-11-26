//
//  Models.swift
//  3ds2apple macOS launcher
//
//  Plain value types shared by the pipeline, the device bridge and the UI. All
//  ROM/game data stays on disk: these structs carry metadata (title IDs, sizes,
//  hashes) only, never game content.
//

import Foundation

// MARK: - Logging

enum LogLevel: String, CaseIterable, Codable {
    case info
    case command
    case success
    case warn
    case error

    var label: String {
        switch self {
        case .info: return "INFO"
        case .command: return "RUN"
        case .success: return "OK"
        case .warn: return "WARN"
        case .error: return "ERR"
        }
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let category: String
    let message: String

    var line: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date) + " [" + level.label + "] " + category + ": " + message
    }
}

// MARK: - Library export format

/// One Library "Export" action, two output formats (chosen in the export dialog).
enum LaunchExportFormat: String, CaseIterable, Identifiable {
    case buildPackage
    case ipa

    var id: String { rawValue }
}

// MARK: - Advanced build settings

/// Deploy -> "Advanced build settings": AOT codegen options applied to the next
/// build. The defaults keep the documented -O2 / no LTO / no fast-math baseline;
/// the same options are part of the Windows launcher's build-cache key.
struct AdvancedBuildOptions: Equatable {
    static let optLevels = ["O1", "O2", "O3", "Oz"]

    var optLevel: String = "O2"
    var lto: Bool = false
    var fastMath: Bool = false

    var isDefault: Bool { optLevel == "O2" && !lto && !fastMath }

    var normalized: AdvancedBuildOptions {
        AdvancedBuildOptions.optLevels.contains(optLevel)
            ? self
            : AdvancedBuildOptions(optLevel: "O2", lto: lto, fastMath: fastMath)
    }

    var cacheMarker: String {
        "opt=" + optLevel + ";lto=" + (lto ? "1" : "0") + ";fastmath=" + (fastMath ? "1" : "0")
    }

    var describe: String {
        "opt=" + optLevel + ", lto=" + (lto ? "on" : "off") + ", fast-math=" + (fastMath ? "on" : "off")
    }
}

// MARK: - Library / games

enum GamePhase: String, Codable, CaseIterable {
    case queued
    case building
    case built
    case pushed
    case failed
}

struct GameEntry: Identifiable, Equatable {
    var id: String { titleID }
    var titleID: String
    var displayName: String
    /// Localized short titles from the ROM SMDH (en, ja, zh-Hans, ...). The
    /// Library shows the one matching the current UI language; the user never
    /// types a game name (Windows launcher 0.2.4 parity).
    var displayNames: [String: String] = [:]
    /// Publisher from the ROM SMDH (empty when the ROM has no SMDH metadata).
    var publisher: String = ""
    /// Absolute path of the pack CLI's extracted SMDH icon (packages/<TITLEID>/
    /// cover.png). The card falls back to a generated placeholder when nil.
    var coverPath: String? = nil
    var productCode: String
    var romPath: String
    var romBytes: Int64
    var container: String
    var aotVersion: Int
    var buildSlug: String
    var phase: GamePhase
    var packPath: String?
    var packBytes: Int64?
    var packSha256: String?
    var packFormat: String?
    var saveNamespace: String
    var pushedAt: Date?
    var lastError: String?
    /// Gitignored launcher copy of the user's ROM used for the Documents push
    /// (out/launcher-roms/<TITLEID>.<ext>). The project package itself stays
    /// ROM-free so the signed library IPA never contains game data.
    var romDataPath: String?
    var romSha256: String?

    var packIsReal: Bool { (packFormat ?? "") == "macho" }
    var isAOTReady: Bool { packIsReal && phase != .failed }
    var isOnDevice: Bool { phase == .pushed || pushedAt != nil }
}

struct DetectedROM: Equatable {
    var path: String
    var titleID: String
    var displayName: String
    /// Localized SMDH titles reported by "rom inspect --json".
    var displayNames: [String: String] = [:]
    /// Publisher reported by "rom inspect --json" (empty when unknown).
    var publisher: String = ""
    var productCode: String
    var container: String
    var bytes: Int64
    var contentBytes: Int64?
    var titleVersion: Int?
}

struct PackFileInfo: Equatable {
    var sha256: String
    var bytes: Int64
    var format: String
}

struct DetectedPackage: Equatable {
    var titleID: String
    var displayName: String
    var productCode: String
    /// Localized SMDH titles (packages add/list --json "displayNames").
    var displayNames: [String: String] = [:]
    /// Publisher (packages add/list --json "publisher"; empty when unknown).
    var publisher: String = ""
    /// Absolute path of the package's SMDH cover.png ("coverPath"), nil when absent.
    var coverPath: String? = nil
    var aotVersion: Int
    var state: String
    var pack: PackFileInfo?
    var issues: [String]

    var isBuilt: Bool { state == "built" }
}

/// One package manifest read back from out/packages/TITLEID/GameInfo.json.
struct PackageManifest: Equatable {
    var schemaVersion: Int
    var titleID: String
    var displayName: String
    var productCode: String
    var aotVersion: Int
    var saveNamespace: String
    var packFile: String?
    var packSha256: String?
    var packBytes: Int64?
    var packFormat: String?
    var romFile: String?
    var romSha256: String?
    var romBytes: Int64?
    // MARK: ROM SMDH metadata (additive; packs from older CLIs omit it)
    var displayNames: [String: String] = [:]
    var publisher: String = ""
    /// Region codes from the ROM SMDH region lockout (`EU`, `US`, `EU+AU`,
    /// `region-free`; empty when the CLI/ROM has none). Additive optional field.
    var region: String = ""
    /// Package-relative "cover.png" recorded in GameInfo.json (resolved against
    /// out/<workspace>/packages/<TITLEID>/ before use).
    var coverPath: String? = nil
    /// Original ROM path recorded by the pack CLI ("rom.path"); used to restore
    /// the library from the portable workspace after a restart.
    var romPath: String? = nil
}

// MARK: - Tasks

enum StageState: String, Codable {
    case pending
    case running
    case succeeded
    case failed
    case skipped

    var symbolName: String {
        switch self {
        case .pending: return "circle"
        case .running: return "circle.dotted"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }
}

struct PipelineStage: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var state: StageState
}

enum TaskKind: String, Codable {
    case detect
    case importROM
    case detectDevice
    case deploy
    case verifyPackages

    var symbolName: String {
        switch self {
        case .detect: return "magnifyingglass"
        case .importROM: return "square.and.arrow.down"
        case .detectDevice: return "cable.connector"
        case .deploy: return "iphone.and.arrow.forward"
        case .verifyPackages: return "checkmark.shield"
        }
    }
}

enum TaskState: String, Codable, CaseIterable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

struct TaskRecord: Identifiable, Equatable {
    let id = UUID()
    var kind: TaskKind
    var title: String
    var titleID: String?
    var state: TaskState
    var stages: [PipelineStage]
    var startedAt: Date
    var endedAt: Date?
    var errorMessage: String?
    var errorHint: String?
    var detail: String

    var progress: Double {
        guard !stages.isEmpty else { return state == .succeeded ? 1 : 0 }
        let finished = stages.filter { $0.state == .succeeded || $0.state == .skipped }.count
        let running = stages.contains { $0.state == .running } ? 0.5 : 0
        return min(1, (Double(finished) + running) / Double(stages.count))
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

// MARK: - Build

/// Kept as a backend-level switch: the Deploy flow always uses a real local AOT
/// build in the live app and the labelled fake packs in mock/self-check mode.
/// It is not user-visible any more (launcher/macos/README.md).
enum BuildMode: String, Codable, CaseIterable {
    case dryRun
    case fake
    case real
}

// MARK: - App readiness

enum ToolState: String, Codable {
    case ok
    case warning
    case missing
}

struct ToolStatus: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var state: ToolState
    var detail: String
    var hint: String
}

struct AppleReadiness: Equatable {
    var xcodePath: String
    var xcodeVersion: String
    var devicectlAvailable: Bool
    var signingIdentityCount: Int
    var provisioningProfileCount: Int
    /// Team ID detected from the local provisioning profiles / certificate
    /// subject. The launcher never asks the user to type it: Xcode owns the
    /// account and this is read-only (launcher/macos/README.md §Settings).
    var teamID: String
    var checkedAt: Date

    var hasSigningAssets: Bool { signingIdentityCount > 0 || provisioningProfileCount > 0 }

    var ready: Bool {
        hasSigningAssets && !teamID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var plainTextState: String {
        if signingIdentityCount == 0 && provisioningProfileCount == 0 {
            return "No Apple ID signing assets found on this Mac."
        }
        if teamID.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Signing certificate found, but no Team ID could be detected."
        }
        return "Signing assets and Team ID are ready."
    }

    var hint: String {
        if signingIdentityCount == 0 && provisioningProfileCount == 0 {
            return "Open Xcode -> Settings -> Accounts, sign in with your own Apple ID, then let Xcode manage signing once. The launcher never asks for or stores your password."
        }
        if teamID.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Sign in to Xcode -> Settings -> Accounts and create a development certificate/provisioning profile for your team."
        }
        return ""
    }
}

struct EnvironmentReport: Equatable {
    var generatedAt: Date
    var repoRoot: String?
    var outDir: String?
    /// Portable data root resolved for this launch (logs/workspace/build/ipa).
    var dataRoot: String? = nil
    var tools: [ToolStatus]
    var apple: AppleReadiness
    var devpushCapabilities: BridgeCapabilities?
    var notes: [String]

    var okCount: Int { tools.filter { $0.state == .ok }.count }
    var hasBlockingIssue: Bool { tools.contains { $0.state == .missing } }
}

// MARK: - Launcher readiness (automatic startup check)

/// Result of the automatic startup readiness probe. The top bar keeps this as a
/// persistent green/red light: green means the local build + Apple-ID signing
/// environment is ready to deploy, red means something actionable is missing.
/// Details go to the tooltip and the log, never to a wall of text in the UI.
enum ReadinessStatus: Equatable {
    case checking
    case ready(detail: String)
    case notReady(detail: String)

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Raw engineering detail (missing tools, Apple ID state) for tooltips/logs.
    var detail: String {
        switch self {
        case .checking: return ""
        case .ready(let detail), .notReady(let detail): return detail
        }
    }
}

extension EnvironmentReport {
    /// Green when every probed component is present and Xcode has signing assets
    /// for a detected team; red otherwise. Warnings are kept in the detail text
    /// but do not block (they are actionable-but-optional).
    var readinessStatus: ReadinessStatus {
        var blockers: [String] = []
        var notes: [String] = []
        for tool in tools {
            switch tool.state {
            case .ok:
                continue
            case .missing:
                blockers.append(tool.name + " is missing" + (tool.detail.isEmpty ? "" : " — " + tool.detail))
            case .warning:
                notes.append(tool.name + ": " + tool.detail)
            }
        }
        if !apple.ready {
            blockers.append("Apple ID signing — " + apple.plainTextState)
        }
        if blockers.isEmpty {
            var detail = "All " + String(tools.count) + " checks passed; Apple ID signing ready"
            if !notes.isEmpty {
                detail += ". Warnings: " + notes.joined(separator: "; ")
            }
            return .ready(detail: detail + ".")
        }
        return .notReady(detail: blockers.joined(separator: "\n"))
    }
}

// MARK: - Devices and install

struct DeviceInfo: Identifiable, Equatable, Codable {
    var id: String { udid }
    var udid: String
    var name: String
    var model: String
    var iosVersion: String
    var connection: String
    var paired: Bool

    var connectionLabel: String { connection == "network" ? "Wi-Fi" : "USB" }
}

struct InstallOptions: Equatable {
    var teamID: String
    var deviceUDID: String?
    var allowProvisioningUpdates: Bool
}

struct InstallProgress: Equatable {
    var stage: String
    var fraction: Double?
    var line: String
}

struct InstallResult: Equatable {
    var appPath: String
    var signed: Bool
    var installed: Bool
    /// The bundle identifier of the app that was actually staged/installed,
    /// read back from the built app's Info.plist (not a template value). The
    /// Documents push must use this value.
    var verifiedBundleID: String?
    var packFiles: [String]
    var catalogTitleIDs: [String]
    var duration: TimeInterval
}

/// Read-only facts about a composed ROM-free library IPA, used to prove the
/// selected real GamePacks and the schema-2 GameCatalog are inside the signed
/// payload before anything is installed (launcher/macos/README.md).
struct IPAInspection: Equatable {
    var ipaPath: String
    var appPath: String
    var bundleID: String
    var packFiles: [String]
    var catalogSchemaVersion: Int
    var catalogTitleIDs: [String]
    var containsBundledROM: Bool
    /// True when the composed shell carries Frameworks/MoltenVK.framework. The
    /// shell needs it for the hardware PICA200/Metal layer (and the system Metal
    /// HUD); without it the runtime silently falls back to software rendering.
    var hasMoltenVK: Bool = false
    var bytes: Int64

    var packCount: Int { packFiles.count }
    var catalogIsSchema2: Bool { catalogSchemaVersion == 2 }

    /// Everything the Deploy flow must prove before sign/install. An empty
    /// result means the IPA is a valid ROM-free multi-game library payload.
    func problems(expectedTitles: [String]) -> [String] {
        var issues: [String] = []
        if ipaPath.isEmpty { issues.append("IPA path is empty") }
        if bundleID.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("the composed app has no CFBundleIdentifier")
        }
        if !hasMoltenVK {
            issues.append("the composed shell has no Frameworks/MoltenVK.framework (hardware rendering + Metal HUD unavailable)")
        }
        if catalogSchemaVersion != 2 {
            issues.append("GameCatalog.json is not schema 2 (found " + String(catalogSchemaVersion) + ")")
        }
        if catalogTitleIDs.isEmpty {
            issues.append("GameCatalog.json lists no games")
        }
        let normalized = catalogTitleIDs.map { $0.uppercased() }
        for title in expectedTitles.map({ $0.uppercased() }) where !normalized.contains(title) {
            issues.append("GameCatalog.json is missing " + title)
        }
        let expectedPacks = expectedTitles.map { "Frameworks/GamePack-" + $0.uppercased() + ".dylib" }
        let actualPacks = Set(packFiles.map { $0 })
        for pack in expectedPacks where !actualPacks.contains(pack) {
            issues.append("Frameworks/GamePack-" + (pack.split(separator: "-").last.map(String.init) ?? "") + " is missing")
        }
        if containsBundledROM {
            issues.append("the IPA contains bundled ROM/game data (Roms/ or romFile) but the deploy must be ROM-free")
        }
        return issues
    }
}

// MARK: - Deploy run

/// State of the one-click Deploy batch action: compile -> compose one ROM-free
/// IPA -> verify -> sign/install -> push each ROM+GameInfo -> done.
struct DeployReport: Identifiable, Equatable {
    let id = UUID()
    var state: TaskState
    var steps: [PipelineStage]
    var selectedTitles: [String]
    var builtTitles: [String]
    var ipaPath: String?
    var inspection: IPAInspection?
    var installedBundleID: String?
    var pushedTitles: [String]
    var failedStepIndex: Int?
    var failureMessage: String?
    var failureHint: String?
    var startedAt: Date
    var endedAt: Date?

    var isDone: Bool { state == .succeeded }
    var progress: Double {
        guard !steps.isEmpty else { return state == .succeeded ? 1 : 0 }
        let finished = steps.filter { $0.state == .succeeded || $0.state == .skipped }.count
        let running = steps.contains { $0.state == .running } ? 0.5 : 0
        return min(1, (Double(finished) + running) / Double(steps.count))
    }

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

// MARK: - Device bridge (devpush contract v1)

struct BridgeCapabilities: Equatable {
    var version: String
    var schema: String
    var commands: [String]
    var features: [String: Bool]
    var mock: Bool
}

struct AppAttr: Equatable {
    var installed: Bool
    var dataContainer: String?
    var appBundleVersion: String?
    var fileSharingEnabled: Bool?
}

struct RemoteEntry: Equatable {
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var modifiedAt: String?
}

struct PutResult: Equatable {
    var remotePath: String
    var bytes: Int64
    var sha256: String
    var elapsed: TimeInterval
}

struct PushFile: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var localPath: String
    var remotePath: String
    var bytes: Int64
    var sha256: String
    var state: StageState
    var progress: Double
}

struct PushPlan: Identifiable, Equatable {
    var id: String { titleID }
    var titleID: String
    var displayName: String
    var bundleID: String
    var deviceUDID: String?
    var deviceName: String
    var remoteDirectory: String
    var files: [PushFile]
    var verified: Bool
    var verifiedAt: Date?

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var finishedFiles: Int { files.filter { $0.state == .succeeded }.count }
}

// MARK: - Errors

struct LauncherFailure: Error, Equatable {
    var code: String
    var message: String
    var hint: String
    var detail: String?
    var exitCode: Int32?

    static func missingTool(_ name: String, hint: String) -> LauncherFailure {
        LauncherFailure(code: "tool_missing", message: name + " was not found.", hint: hint, detail: nil, exitCode: nil)
    }

    var plainText: String { hint.isEmpty ? message : message + " " + hint }
}

extension Error {
    func launcherFailure() -> LauncherFailure {
        if let failure = self as? LauncherFailure { return failure }
        if let devpush = self as? DevpushFailure {
            return LauncherFailure(
                code: devpush.code,
                message: devpush.message,
                hint: devpush.hint,
                detail: devpush.detail,
                exitCode: devpush.exitCode
            )
        }
        return LauncherFailure(code: "error", message: localizedDescription, hint: "", detail: nil, exitCode: nil)
    }
}

// MARK: - Navigation

/// The launcher has exactly two top-level sections (launcher/macos/README.md):
/// Library (import/add/list/remove) and Deploy (select games -> one-click batch
/// deploy). Import is a sheet of the Library; Settings is a modal panel.
enum LauncherScreen: String, CaseIterable, Identifiable {
    case library = "library"
    case deploy = "deploy"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .deploy: return "iphone.and.arrow.forward"
        }
    }
}

struct Banner: Identifiable, Equatable {
    enum Kind: String { case info, success, warning, error }
    let id = UUID()
    var kind: Kind
    var title: String
    var message: String
}

// MARK: - Run mode

enum LauncherRunMode: String {
    case live
    case mock

    var isMock: Bool { self == .mock }
}

// MARK: - SMDH display metadata (Windows launcher 0.2.4 parity)

/// Picks the display name, publisher and cover image supplied by the pack CLI
/// from the ROM's SMDH: the Library follows the app language instead of asking
/// the user to type a name. Semantics mirror the Windows launcher (GameNames.cs):
/// exact UI language, then English, then the default displayName, then any
/// non-empty entry; zh-Hant falls back to English because only en/zh-Hans ship.
enum GameNames {
    /// BCP-47 spellings the CLI/SMDH may use for Simplified Chinese.
    static let chineseKeys = ["zh-Hans", "zh-CN", "zh-SG", "zh"]
    /// BCP-47 spellings the CLI/SMDH may use for English.
    static let englishKeys = ["en", "en-US", "en-GB"]

    /// Normalize a UI language tag to the two languages the launcher ships.
    static func normalizeTag(_ uiLanguageTag: String?) -> String {
        guard let raw = uiLanguageTag?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "en"
        }
        let tag = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        if tag.hasPrefix("zh") {
            if tag.contains("hant") || tag.contains("-tw") || tag.contains("-hk") || tag.contains("-mo") {
                return "en"
            }
            return "zh-Hans"
        }
        return "en"
    }

    /// Pick the best available name for the current UI language.
    static func resolve(displayNames: [String: String]?, displayName: String, uiLanguageTag: String?) -> String {
        let fallback = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let names = displayNames, !names.isEmpty else { return fallback }
        let preferred = normalizeTag(uiLanguageTag) == "zh-Hans" ? chineseKeys : englishKeys
        for key in preferred {
            if let value = lookup(names, key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !fallback.isEmpty { return fallback }
        for key in names.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            if let value = names[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return fallback
    }

    /// Trim a publisher string; empty when unknown.
    static func resolvePublisher(_ publisher: String?) -> String {
        guard let publisher else { return "" }
        return publisher.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve the package's cover.png: an absolute CLI value is used as-is, a
    /// relative value is package-relative, nil falls back to <package>/cover.png.
    static func resolveCoverPath(packageDirectory: String?, coverPath: String?) -> String? {
        guard let packageDirectory, !packageDirectory.isEmpty else {
            guard let coverPath, !coverPath.isEmpty, (coverPath as NSString).isAbsolutePath else { return nil }
            return FileProbe.exists(coverPath) ? coverPath : nil
        }
        if let coverPath, !coverPath.isEmpty {
            let candidate = (coverPath as NSString).isAbsolutePath
                ? coverPath
                : (packageDirectory as NSString).appendingPathComponent(coverPath)
            return FileProbe.exists(candidate) ? candidate : nil
        }
        let conventional = (packageDirectory as NSString).appendingPathComponent("cover.png")
        return FileProbe.exists(conventional) ? conventional : nil
    }

    private static func lookup(_ names: [String: String], _ wanted: String) -> String? {
        if let direct = names[wanted] { return direct }
        for pair in names where pair.key.lowercased() == wanted.lowercased() {
            return pair.value
        }
        return nil
    }
}
