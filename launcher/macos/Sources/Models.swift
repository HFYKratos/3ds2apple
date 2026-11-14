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

// MARK: - Library / games

enum GamePhase: String, Codable {
    case queued
    case building
    case built
    case pushed
    case failed

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .building: return "Building"
        case .built: return "Built"
        case .pushed: return "Installed on device"
        case .failed: return "Failed"
        }
    }
}

struct GameEntry: Identifiable, Equatable {
    var id: String { titleID }
    var titleID: String
    var displayName: String
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
}

struct DetectedROM: Equatable {
    var path: String
    var titleID: String
    var displayName: String
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
    case buildAOT
    case verifyPackages
    case buildShell
    case installShell
    case detectDevice
    case pushGame
    case verifyPush

    var title: String {
        switch self {
        case .detect: return "Detect ROM"
        case .importROM: return "Import ROM"
        case .buildAOT: return "Build GamePack"
        case .verifyPackages: return "Verify packages"
        case .buildShell: return "Build base shell"
        case .installShell: return "Install base shell"
        case .detectDevice: return "Detect device"
        case .pushGame: return "Push game files"
        case .verifyPush: return "Verify on device"
        }
    }

    var symbolName: String {
        switch self {
        case .detect: return "magnifyingglass"
        case .importROM: return "square.and.arrow.down"
        case .buildAOT: return "hammer"
        case .verifyPackages: return "checkmark.shield"
        case .buildShell: return "shippingbox"
        case .installShell: return "iphone.and.arrow.forward"
        case .detectDevice: return "cable.connector"
        case .pushGame: return "arrow.up.doc.on.clipboard"
        case .verifyPush: return "checkmark.seal"
        }
    }
}

enum TaskState: String, Codable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
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

enum BuildMode: String, Codable, CaseIterable {
    case dryRun
    case fake
    case real

    var title: String {
        switch self {
        case .dryRun: return "Dry run"
        case .fake: return "Fake preview pack"
        case .real: return "Real AOT build"
        }
    }

    var explanation: String {
        switch self {
        case .dryRun: return "Prints the exact commands; compiles and writes nothing."
        case .fake: return "Writes labelled placeholder packs for UI and layout tests; not installable."
        case .real: return "Runs 3dsrecomp and the Xcode pack link on this Mac (slow)."
        }
    }
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
    var teamID: String
    var checkedAt: Date

    var hasSigningAssets: Bool { signingIdentityCount > 0 || provisioningProfileCount > 0 }

    var plainTextState: String {
        if signingIdentityCount == 0 && provisioningProfileCount == 0 {
            return "No Apple ID signing assets found on this Mac."
        }
        if teamID.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Signing certificate found; set your Apple Developer Team ID."
        }
        return "Signing assets and Team ID are ready."
    }

    var hint: String {
        if signingIdentityCount == 0 && provisioningProfileCount == 0 {
            return "Open Xcode -> Settings -> Accounts, sign in with your own Apple ID, then let Xcode manage signing once. The launcher never asks for or stores your password."
        }
        if teamID.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter the 10-character Team ID from developer.apple.com (Membership) or Xcode -> Settings -> Accounts."
        }
        return ""
    }
}

struct EnvironmentReport: Equatable {
    var generatedAt: Date
    var repoRoot: String?
    var outDir: String?
    var tools: [ToolStatus]
    var apple: AppleReadiness
    var devpushCapabilities: BridgeCapabilities?
    var notes: [String]

    var okCount: Int { tools.filter { $0.state == .ok }.count }
    var hasBlockingIssue: Bool { tools.contains { $0.state == .missing } }
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

enum InstallStrategy: String, CaseIterable, Codable {
    case xcodebuild
    case deviceCLI
    case impactor
    case mock

    var title: String {
        switch self {
        case .xcodebuild: return "Xcode build + devicectl"
        case .deviceCLI: return "device_cli sign/install wrapper"
        case .impactor: return "Official Impactor (manual)"
        case .mock: return "Mock (dry run)"
        }
    }

    var detail: String {
        switch self {
        case .xcodebuild: return "Signs the ROM-free shell with your Apple ID in Xcode and installs it with devicectl."
        case .deviceCLI: return "Uses builder/device/device_cli.py when the device-bridge task publishes it."
        case .impactor: return "Opens the official Impactor with the unsigned IPA; sign in and install there."
        case .mock: return "Simulates readiness, build and install without touching a device."
        }
    }
}

struct InstallOptions: Equatable {
    var strategy: InstallStrategy
    var teamID: String
    var bundleID: String
    var deviceUDID: String?
    var allowProvisioningUpdates: Bool
    var adoptAppPath: String?
    var adoptIPAPath: String?
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
    var verifiedBundleID: String?
    var duration: TimeInterval
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

// MARK: - Selection

enum LauncherScreen: String, CaseIterable, Identifiable {
    case importROM = "import"
    case library = "library"
    case build = "build"
    case install = "install"
    case device = "device"
    case activity = "activity"
    case diagnostics = "diagnostics"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importROM: return "Import ROM"
        case .library: return "Games"
        case .build: return "Build AOT"
        case .install: return "Shell + library"
        case .device: return "Device push"
        case .activity: return "Activity"
        case .diagnostics: return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .importROM: return "Add your own decrypted .3ds / .cci files"
        case .library: return "One shell, many per-game AOT packages"
        case .build: return "Compile a GamePack on this Mac"
        case .install: return "Sign and install the shell with the current AOT GamePacks"
        case .device: return "Copy Documents/Games files over the device bridge"
        case .activity: return "Task history, progress and logs"
        case .diagnostics: return "Toolchain, Apple ID and device bridge status"
        }
    }

    var symbolName: String {
        switch self {
        case .importROM: return "square.and.arrow.down"
        case .library: return "square.grid.2x2"
        case .build: return "hammer"
        case .install: return "iphone.and.arrow.forward"
        case .device: return "arrow.up.doc.on.clipboard"
        case .activity: return "list.bullet.rectangle"
        case .diagnostics: return "stethoscope"
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
