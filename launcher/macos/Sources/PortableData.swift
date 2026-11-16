//
//  PortableData.swift
//  3ds2apple macOS launcher
//
//  Portable data root (Windows launcher 0.2.4 parity). Writable launcher data
//  prefers a folder BESIDE the .app (<folder containing the .app>/
//  3ds2apple-data); a read-only or translocated app folder falls back to
//  ~/Library/Application Support/3ds2apple. Logs, the pack workspace, compile
//  staging, the launcher's ROM copies and the composed library IPAs all derive
//  from that one root, so a launcher kept on a USB stick/portable folder keeps
//  its data with it.
//
//  On first launch with the new root the previous <checkout>/out workspace and
//  the old launcher log are adopted ONCE: hardlink first (same APFS volume),
//  then copy small files, then a migration.json marker. The legacy tree is left
//  untouched, so a failed migration can never lose data.
//
//  Nothing here touches ROMs, game data or the network; every input can be
//  supplied so the headless self-check can test the policy on a temporary tree.
//

import Foundation

/// Where the launcher keeps its writable data for this run.
enum DataRootKind: String, Codable {
    /// Explicit path from THREEDS2APPLE_DATA_DIR (QA/test override).
    case explicit
    /// <folder containing the .app>/3ds2apple-data - the preferred portable spot.
    case portable
    /// ~/Library/Application Support/3ds2apple - fallback when the app folder is
    /// read-only or macOS translocated it (Gatekeeper/quarantine runs).
    case applicationSupport
    /// Last-resort temporary folder when both above are unusable.
    case tempFallback

    var shortLabel: String {
        switch self {
        case .explicit: return "explicit"
        case .portable: return "portable"
        case .applicationSupport: return "application-support"
        case .tempFallback: return "temporary"
        }
    }
}

/// The resolved data root plus every directory the launcher derives from it.
struct DataRootDecision: Equatable {
    var dataRoot: String
    var workspaceRoot: String
    var logsRoot: String
    var buildRoot: String
    var stagingRoot: String
    var ipaRoot: String
    var romsRoot: String
    var kind: DataRootKind
    var reason: String
    var bundleDirectory: String
    var portableCandidate: String
    var applicationSupportRoot: String

    var isPortable: Bool { kind == .portable }

    /// One-line engineering summary (shown in the log / Settings tooltip).
    func summary() -> String {
        return "data root: " + dataRoot + " [" + kind.rawValue + "] - " + reason
    }
}

/// Outcome of adopting data from the previous checkout/out layout.
struct DataMigrationResult: Equatable {
    var attempted: Bool = false
    var filesCopied: Int = 0
    var filesSkipped: Int = 0
    var warning: String? = nil
    var markerPath: String = ""

    var migrated: Bool { attempted && filesCopied > 0 }
}

/// Portable layout policy: pure enough for the headless self-check to drive with
/// injected directories and a fake writability probe.
enum PortableData {
    static let dataDirectoryName = "3ds2apple-data"
    static let workspaceDirectoryName = "workspace"
    static let logsDirectoryName = "logs"
    static let buildDirectoryName = "build"
    static let stagingDirectoryName = "staging"
    static let ipaDirectoryName = "ipa"
    static let romsDirectoryName = "launcher-roms"
    static let migrationMarkerFileName = "migration.json"

    /// Optional QA override for the whole data root (the test/self-check hook).
    static let dataRootEnvironmentVariable = "THREEDS2APPLE_DATA_DIR"
    /// Test hook: force the Application Support fallback on a writable host.
    static let forceFallbackEnvironmentVariable = "THREEDS2APPLE_FORCE_APP_SUPPORT"

    /// Old layout, relative to the checkout: the pack CLI output tree + staged
    /// ROM copies used to live in <checkout>/out.
    static let legacyWorkspaceDirectoryName = "out"
    /// Old log folder under Application Support (pre-0.2.4 launcher).
    static let legacyLogDirectoryName = "3ds2apple-launcher"
    /// Launcher-version-independent folder name under Application Support.
    static let legacyDataDirectoryName = "3ds2apple"

    /// Build scratch that is regenerable and never migrated.
    static let migrationSkippedDirectories: Set<String> = ["work", "staging", "build", "ipa", "IPA", "logs", "tmp"]

    /// Cross-volume copies above this size are skipped (a same-volume hardlink
    /// is always attempted first, so a normal APFS Mac migrates instantly and
    /// without extra space even for multi-GB ROM copies).
    static let migrationCopyLimitBytes: Int64 = 64 * 1024 * 1024

    // MARK: - Locations

    /// The folder that contains the running .app (not Contents/MacOS).
    static func appBundleDirectory(bundleURL: URL = Bundle.main.bundleURL) -> String {
        let path = bundleURL.standardizedFileURL.path
        if path.hasSuffix(".app") {
            return trimTrailingSlash((path as NSString).deletingLastPathComponent)
        }
        return trimTrailingSlash(path)
    }

    /// ~/Library/Application Support (never throws).
    static func applicationSupportDirectory() -> String {
        let candidate = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return trimTrailingSlash(candidate.path)
    }

    /// True when macOS is running the app from a random read-only translation
    /// (Gatekeeper/quarantine): a portable folder beside it would be transient.
    static func isTranslocated(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        return bundlePath.contains("/AppTranslocation/")
    }

    /// Legacy launcher log folders, newest first.
    static func legacyLogDirectories(applicationSupportRoot: String? = nil) -> [String] {
        let support = trimTrailingSlash(applicationSupportRoot ?? applicationSupportDirectory())
        return [
            support + "/" + legacyLogDirectoryName,
            support + "/" + legacyDataDirectoryName + "/" + logsDirectoryName,
        ]
    }

    // MARK: - Resolve

    /// Resolve the writable data root. Pure enough for tests: the bundle folder,
    /// Application Support root, override, translocation flag and writability
    /// probe can all be supplied.
    static func resolve(
        bundleDirectory: String? = nil,
        applicationSupportRoot: String? = nil,
        dataRootOverride: String? = nil,
        forceFallback: Bool? = nil,
        translocated: Bool? = nil,
        isWritable: ((String) -> Bool)? = nil
    ) -> DataRootDecision {
        let bundleDir = trimTrailingSlash(bundleDirectory ?? appBundleDirectory())
        let support = trimTrailingSlash(applicationSupportRoot ?? applicationSupportDirectory())
        let writable = isWritable ?? probeWritable
        let portableCandidate = bundleDir + "/" + dataDirectoryName
        let legacyDataRoot = support + "/" + legacyDataDirectoryName

        // nil = consult the environment override; "" = explicitly no override
        // (the headless self-check uses "" to stay deterministic on the VM).
        var explicit = dataRootOverride
        if explicit == nil {
            explicit = ProcessInfo.processInfo.environment[dataRootEnvironmentVariable]
        }
        if let explicit, !explicit.isEmpty {
            return makeDecision(
                root: trimTrailingSlash(explicit),
                kind: .explicit,
                reason: "explicit override (" + dataRootEnvironmentVariable + ")",
                bundleDirectory: bundleDir,
                portableCandidate: portableCandidate,
                applicationSupportRoot: support
            )
        }

        let environmentForce = isTruthy(ProcessInfo.processInfo.environment[forceFallbackEnvironmentVariable] ?? "")
        let force = forceFallback ?? environmentForce
        let isTranslated = translocated ?? isTranslocated()

        var fallbackReasons: [String] = []
        if force { fallbackReasons.append("forced Application Support fallback (" + forceFallbackEnvironmentVariable + ")") }
        if isTranslated { fallbackReasons.append("macOS runs the app from a read-only AppTranslocation path") }
        if fallbackReasons.isEmpty && writable(portableCandidate) {
            return makeDecision(
                root: portableCandidate,
                kind: .portable,
                reason: "portable beside the launcher (its folder is writable)",
                bundleDirectory: bundleDir,
                portableCandidate: portableCandidate,
                applicationSupportRoot: support
            )
        }
        if fallbackReasons.isEmpty {
            fallbackReasons.append("the folder containing the .app is read-only (" + bundleDir + ")")
        }
        if writable(legacyDataRoot) {
            return makeDecision(
                root: legacyDataRoot,
                kind: .applicationSupport,
                reason: "fallback: " + fallbackReasons.joined(separator: "; "),
                bundleDirectory: bundleDir,
                portableCandidate: portableCandidate,
                applicationSupportRoot: support
            )
        }
        let temporary = NSTemporaryDirectory() + "3ds2apple/launcher-data-" + String(ProcessInfo.processInfo.processIdentifier)
        return makeDecision(
            root: trimTrailingSlash(temporary),
            kind: .tempFallback,
            reason: "fallback: both the .app folder and Application Support are read-only; using a temporary folder",
            bundleDirectory: bundleDir,
            portableCandidate: portableCandidate,
            applicationSupportRoot: support
        )
    }

    private static func makeDecision(
        root: String,
        kind: DataRootKind,
        reason: String,
        bundleDirectory: String,
        portableCandidate: String,
        applicationSupportRoot: String
    ) -> DataRootDecision {
        return DataRootDecision(
            dataRoot: root,
            workspaceRoot: root + "/" + workspaceDirectoryName,
            logsRoot: root + "/" + logsDirectoryName,
            buildRoot: root + "/" + buildDirectoryName,
            stagingRoot: root + "/" + stagingDirectoryName,
            ipaRoot: root + "/" + ipaDirectoryName,
            romsRoot: root + "/" + workspaceDirectoryName + "/" + romsDirectoryName,
            kind: kind,
            reason: reason,
            bundleDirectory: bundleDirectory,
            portableCandidate: portableCandidate,
            applicationSupportRoot: applicationSupportRoot
        )
    }

    /// Create the directory and write a probe file into it; false instead of throwing.
    static func probeWritable(_ directory: String) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let probe = directory + "/.write-probe-" + String(UUID().uuidString.prefix(8)) + ".tmp"
            defer { try? manager.removeItem(atPath: probe) }
            guard manager.createFile(atPath: probe, contents: Data([0])) else { return false }
            return true
        } catch {
            return false
        }
    }

    /// Create every directory derived from the decision (idempotent).
    static func ensureDirectories(_ decision: DataRootDecision) throws {
        let manager = FileManager.default
        for directory in [
            decision.dataRoot,
            decision.workspaceRoot,
            decision.logsRoot,
            decision.buildRoot,
            decision.stagingRoot,
            decision.ipaRoot,
            decision.romsRoot,
        ] {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - One-time migration from <checkout>/out

    /// Adopt the previous workspace once. Hardlinks are preferred so an APFS Mac
    /// migrates multi-GB packs/ROM copies instantly and without extra space; a
    /// cross-volume copy is limited to small metadata files. Build scratch
    /// (work/, staging/, build/, ipa/, logs/) is skipped and regenerated.
    static func migrateWorkspaceIfNeeded(
        workspaceRoot: String,
        legacyWorkspaceRoot: String,
        markerPath: String? = nil,
        log: ((String) -> Void)? = nil
    ) -> DataMigrationResult {
        let manager = FileManager.default
        let marker = markerPath ?? workspaceRoot + "/" + migrationMarkerFileName
        var result = DataMigrationResult(markerPath: marker)
        let legacy = trimTrailingSlash(legacyWorkspaceRoot)
        guard manager.fileExists(atPath: legacy) else { return result }

        // Never overwrite a workspace that already adopted data.
        let packages = workspaceRoot + "/packages"
        if let entries = try? manager.contentsOfDirectory(atPath: packages), !entries.isEmpty {
            return result
        }
        result.attempted = true
        do {
            try manager.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        } catch {
            result.warning = "could not create " + workspaceRoot + ": " + error.localizedDescription
            return result
        }

        var warnings: [String] = []
        let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: legacy),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            let relative = relativePath(of: url.path, under: legacy)
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { migrationSkippedDirectories.contains($0) }) {
                enumerator?.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }
            let destination = workspaceRoot + "/" + relative
            guard !manager.fileExists(atPath: destination) else {
                result.filesSkipped += 1
                continue
            }
            do {
                try manager.createDirectory(
                    atPath: (destination as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                // Same-volume hardlink: instant, no extra disk space.
                do {
                    try manager.linkItem(atPath: url.path, toPath: destination)
                    result.filesCopied += 1
                    continue
                } catch {
                    // fall through to the size-limited copy below
                }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                let bytes: Int64
                if let fileSize = values?.fileSize {
                    bytes = Int64(fileSize)
                } else {
                    bytes = 0
                }
                if bytes > migrationCopyLimitBytes {
                    result.filesSkipped += 1
                    continue
                }
                try manager.copyItem(atPath: url.path, toPath: destination)
                result.filesCopied += 1
            } catch {
                result.filesSkipped += 1
                if warnings.count < 8 {
                    warnings.append(relative + ": " + error.localizedDescription)
                }
            }
        }
        if let warning = writeMigrationMarker(
            markerPath: marker,
            source: legacy,
            filesCopied: result.filesCopied,
            filesSkipped: result.filesSkipped,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "; ")
        ) {
            result.warning = warning
        }
        log?("workspace migration: " + String(result.filesCopied) + " file(s) adopted, "
            + String(result.filesSkipped) + " skipped from " + legacy)
        return result
    }

    /// Copy the previous launcher log into the new data root (only when the new
    /// log is still empty). Returns the number of adopted files.
    static func migrateLegacyLogs(logsRoot: String, legacyLogDirectories: [String], log: ((String) -> Void)? = nil) -> Int {
        let manager = FileManager.default
        let destination = logsRoot + "/launcher.log"
        guard !manager.fileExists(atPath: destination) else { return 0 }
        var copied = 0
        for directory in legacyLogDirectories {
            let source = directory + "/launcher.log"
            guard manager.fileExists(atPath: source) else { continue }
            do {
                try manager.createDirectory(atPath: logsRoot, withIntermediateDirectories: true)
                try manager.copyItem(atPath: source, toPath: destination)
                copied += 1
                log?("adopted the previous launcher log from " + source)
            } catch {
                log?("could not adopt the previous launcher log from " + source + ": " + error.localizedDescription)
            }
            break
        }
        return copied
    }

    private static func writeMigrationMarker(
        markerPath: String,
        source: String,
        filesCopied: Int,
        filesSkipped: Int,
        warning: String?
    ) -> String? {
        let document: [String: Any] = [
            "schemaVersion": 1,
            "source": source,
            "migratedAt": ISO8601DateFormatter().string(from: Date()),
            "filesCopied": filesCopied,
            "filesSkipped": filesSkipped,
            "warning": warning ?? "",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(
                atPath: (markerPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: markerPath))
            return nil
        } catch {
            return "could not write " + markerPath + ": " + error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Relative path of an enumerated item under the legacy root. Both sides are
    /// symlink-resolved first: macOS reports /private/var/... for /var/... and a
    /// plain prefix check would flatten the tree into the workspace root.
    static func relativePath(of path: String, under root: String) -> String {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        if resolvedPath.hasPrefix(prefix) { return String(resolvedPath.dropFirst(prefix.count)) }
        return (resolvedPath as NSString).lastPathComponent
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        var value = path
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func isTruthy(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered == "1" || lowered == "true" || lowered == "yes"
    }
}
