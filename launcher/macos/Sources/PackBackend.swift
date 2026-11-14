//
//  PackBackend.swift
//  3ds2apple macOS launcher
//
//  The import/build half of the pipeline: a typed wrapper over the existing
//  desktop CLI (builder/pack -> 3ds2apple-pack) plus the package manifest reader.
//  The Rust CLI stays the single writer of GameInfo.json / GameCatalog.json; the
//  launcher only reads its JSON and never invents package metadata.
//

import Foundation

/// Result of allocating built GamePacks into the ROM-free shell IPA
/// (Frameworks/GamePack-<TITLEID>.dylib + bundle GameCatalog.json).
struct LibraryIPAResult: Equatable {
    var ipaPath: String?
    var titles: [String]
    var executed: Bool
    var command: [String]
    var summary: String?
}

protocol PackBackend: AnyObject {
    var mode: LauncherRunMode { get }
    var outRoot: URL { get }
    var repoRoot: URL { get }

    func inspectROM(_ path: String) async throws -> DetectedROM
    func importROM(_ path: String, displayName: String?, includeROM: Bool) async throws -> DetectedPackage
    func listPackages() async throws -> [DetectedPackage]
    func build(titleIDs: [String], mode: BuildMode, onLine: @escaping (LogLevel, String) -> Void) async throws -> [DetectedPackage]
    func verify() async throws -> [String]
    func readManifest(titleID: String) async throws -> PackageManifest
    /// Allocate the selected built GamePacks into one shell app/IPA. The app is
    /// ROM-free by construction (packages hold no bundled GameRom); the IPA only
    /// carries Frameworks/GamePack-<TITLEID>.dylib + GameCatalog.json.
    func buildLibraryIPA(
        titleIDs: [String],
        baseAppPath: String,
        ipaOutDir: String,
        ipaName: String,
        dryRun: Bool,
        onLine: @escaping (LogLevel, String) -> Void
    ) async throws -> LibraryIPAResult
}

// MARK: - JSON parsing (kept as static functions so the self-checks can drive them)

enum PackJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parseROMs(_ data: Data) -> (roms: [DetectedROM], errors: [String]) {
        guard let root = object(data) else { return ([], ["Could not parse the ROM inspector output."]) }
        var roms: [DetectedROM] = []
        for item in root["roms"] as? [[String: Any]] ?? [] {
            roms.append(DetectedROM(
                path: item["path"] as? String ?? "",
                titleID: item["titleID"] as? String ?? "",
                displayName: item["displayName"] as? String ?? "",
                productCode: item["productCode"] as? String ?? "",
                container: item["container"] as? String ?? "unknown",
                bytes: int64(item["bytes"]),
                contentBytes: item["contentBytes"].map { int64($0) },
                titleVersion: item["titleVersion"] as? Int
            ))
        }
        let errors = (root["errors"] as? [[String: Any]] ?? []).compactMap { $0["error"] as? String }
        return (roms, errors)
    }

    static func parsePackages(_ data: Data) -> (packages: [DetectedPackage], errors: [String]) {
        guard let root = object(data) else { return ([], ["Could not parse the package list output."]) }
        var packages: [DetectedPackage] = []
        for item in root["packages"] as? [[String: Any]] ?? [] {
            var pack: PackFileInfo?
            if let packObject = item["pack"] as? [String: Any] {
                pack = PackFileInfo(
                    sha256: packObject["sha256"] as? String ?? "",
                    bytes: int64(packObject["bytes"]),
                    format: packObject["format"] as? String ?? ""
                )
            }
            packages.append(DetectedPackage(
                titleID: item["titleID"] as? String ?? "",
                displayName: item["displayName"] as? String ?? "",
                productCode: item["productCode"] as? String ?? "",
                aotVersion: item["aotVersion"] as? Int ?? 1,
                state: item["state"] as? String ?? "queued",
                pack: pack,
                issues: item["issues"] as? [String] ?? []
            ))
        }
        let errors = (root["errors"] as? [[String: Any]] ?? []).compactMap { $0["error"] as? String }
        return (packages, errors)
    }

    static func parseManifest(_ data: Data, fallbackTitleID: String) -> PackageManifest? {
        guard let root = object(data) else { return nil }
        var packSha: String?
        var packBytes: Int64?
        var packFormat: String?
        if let pack = root["pack"] as? [String: Any] {
            packSha = pack["sha256"] as? String
            if let bytes = pack["bytes"] { packBytes = int64(bytes) }
            packFormat = pack["format"] as? String
        }
        var romSha: String?
        var romBytes: Int64?
        if let rom = root["rom"] as? [String: Any], rom["bytes"] != nil {
            romBytes = int64(rom["bytes"])
            romSha = rom["sha256"] as? String
        }
        if let bytes = root["romBytes"] { romBytes = int64(bytes) }
        if let sha = root["romSha256"] as? String { romSha = sha }
        return PackageManifest(
            schemaVersion: root["schemaVersion"] as? Int ?? 1,
            titleID: root["titleID"] as? String ?? fallbackTitleID,
            displayName: root["displayName"] as? String ?? fallbackTitleID,
            productCode: root["productCode"] as? String ?? "",
            aotVersion: root["aotVersion"] as? Int ?? 1,
            saveNamespace: root["saveNamespace"] as? String ?? fallbackTitleID,
            packFile: root["packFile"] as? String,
            packSha256: packSha,
            packBytes: packBytes,
            packFormat: packFormat,
            romFile: root["romFile"] as? String,
            romSha256: romSha,
            romBytes: romBytes
        )
    }

    static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) ?? 0 }
        return 0
    }
}

// MARK: - Real implementation

final class PackCLI: PackBackend {
    let runner: CommandRunning
    let binary: String
    let repoRoot: URL
    let outRoot: URL
    let outArgument: String
    let mode: LauncherRunMode = .live

    init(runner: CommandRunning, binary: String, repoRoot: URL, outRoot: URL, outArgument: String) {
        self.runner = runner
        self.binary = binary
        self.repoRoot = repoRoot
        self.outRoot = outRoot
        self.outArgument = outArgument
    }

    func inspectROM(_ path: String) async throws -> DetectedROM {
        let result = try await run(["rom", "inspect", path, "--json"])
        let parsed = PackJSON.parseROMs(Data(result.stdout.utf8))
        if let rom = parsed.roms.first { return rom }
        throw LauncherFailure(
            code: "rom_inspect_failed",
            message: "Could not read the ROM header.",
            hint: parsed.errors.first ?? "The file is not a decrypted .3ds/.cci/.ncch image accepted by the desktop pipeline.",
            detail: result.combined,
            exitCode: result.exitCode
        )
    }

    func importROM(_ path: String, displayName: String?, includeROM: Bool) async throws -> DetectedPackage {
        var arguments = ["packages", "add", "--roms", path, "--json"]
        if let displayName, !displayName.isEmpty {
            arguments.append(contentsOf: ["--display-name", displayName])
        }
        if includeROM { arguments.append("--include-rom") }
        let result = try await run(arguments)
        let parsed = PackJSON.parsePackages(Data(result.stdout.utf8))
        guard let package = parsed.packages.first else {
            throw LauncherFailure(
                code: "rom_import_failed",
                message: "The desktop CLI did not queue this ROM.",
                hint: parsed.errors.first ?? "Check that the ROM is a decrypted .3ds/.cci file that you own.",
                detail: result.combined,
                exitCode: result.exitCode
            )
        }
        return package
    }

    func listPackages() async throws -> [DetectedPackage] {
        let result = try await run(["packages", "list", "--json"])
        return PackJSON.parsePackages(Data(result.stdout.utf8)).packages
    }

    func build(titleIDs: [String], mode: BuildMode, onLine: @escaping (LogLevel, String) -> Void) async throws -> [DetectedPackage] {
        var arguments = ["build", "--queued"]
        switch mode {
        case .dryRun: break
        case .fake: arguments.append("--fake")
        case .real: arguments.append("--execute")
        }
        arguments.append("--json")
        let result = try await run(arguments, onLine: onLine)
        if !result.succeeded {
            throw LauncherFailure(
                code: "build_failed",
                message: "The GamePack build failed.",
                hint: tailHint(result),
                detail: result.combined,
                exitCode: result.exitCode
            )
        }
        let built = PackJSON.parsePackages(Data(result.stdout.utf8)).packages
        if mode == .dryRun { return [] }
        return built
    }

    func verify() async throws -> [String] {
        let result = try await run(["packages", "verify", "--json"])
        let parsed = PackJSON.parsePackages(Data(result.stdout.utf8))
        var issues = parsed.packages.flatMap { $0.issues }
        issues.append(contentsOf: parsed.errors)
        if !result.succeeded && issues.isEmpty {
            issues.append(tailHint(result))
        }
        return issues
    }

    func buildLibraryIPA(
        titleIDs: [String],
        baseAppPath: String,
        ipaOutDir: String,
        ipaName: String,
        dryRun: Bool,
        onLine: @escaping (LogLevel, String) -> Void
    ) async throws -> LibraryIPAResult {
        var arguments = ["pack"]
        if titleIDs.isEmpty {
            arguments.append("--all")
        } else {
            for titleID in titleIDs {
                arguments.append(contentsOf: ["--title-id", titleID])
            }
        }
        arguments.append(contentsOf: [
            "--base-app", baseAppPath,
            "--ipa-out", ipaOutDir,
            "--ipa-name", ipaName,
        ])
        if !dryRun {
            arguments.append("--execute")
        }
        arguments.append("--json")
        let result = try await run(arguments, onLine: onLine)
        if !result.succeeded {
            throw LauncherFailure(
                code: "library_ipa_failed",
                message: "Could not allocate the GamePacks into the library IPA.",
                hint: tailHint(result),
                detail: result.combined,
                exitCode: result.exitCode
            )
        }
        let root = PackJSON.object(Data(result.stdout.utf8)) ?? [:]
        let executed = root["executed"] as? Bool ?? false
        let command = root["command"] as? [String] ?? []
        let summary = root["summary"] as? String
        guard executed, !dryRun else {
            return LibraryIPAResult(ipaPath: nil, titles: titleIDs, executed: false, command: command, summary: summary)
        }
        let ipaPath = (ipaOutDir as NSString).appendingPathComponent(ipaName + ".ipa")
        guard FileProbe.exists(ipaPath) else {
            throw LauncherFailure(
                code: "library_ipa_missing",
                message: "The packaging script finished but the library IPA is missing.",
                hint: "Check that scripts/build-multi-game-ipa.sh and scripts/package-ipa.sh can run on this Mac.",
                detail: ipaPath,
                exitCode: nil
            )
        }
        return LibraryIPAResult(ipaPath: ipaPath, titles: titleIDs, executed: true, command: command, summary: summary)
    }

    func readManifest(titleID: String) async throws -> PackageManifest {
        let url = outRoot.appendingPathComponent("packages/\(titleID)/GameInfo.json")
        guard let data = try? Data(contentsOf: url) else {
            throw LauncherFailure(
                code: "manifest_missing",
                message: "GameInfo.json is missing for " + titleID + ".",
                hint: "Import the ROM first; the desktop CLI writes the manifest.",
                detail: url.path,
                exitCode: nil
            )
        }
        guard let manifest = PackJSON.parseManifest(data, fallbackTitleID: titleID) else {
            throw LauncherFailure(
                code: "manifest_invalid",
                message: "GameInfo.json could not be parsed for " + titleID + ".",
                hint: "Re-run the import; if it persists, run packages verify.",
                detail: url.path,
                exitCode: nil
            )
        }
        return manifest
    }

    // MARK: internals

    private func run(
        _ arguments: [String],
        onLine: ((LogLevel, String) -> Void)? = nil
    ) async throws -> CommandResult {
        let spec = CommandSpec(
            executable: binary,
            arguments: ["--out", outArgument] + arguments,
            workingDirectory: repoRoot.path
        )
        return try await runner.run(spec, onLine: onLine)
    }

    private func tailHint(_ result: CommandResult) -> String {
        let lines = result.combined
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(2).joined(separator: " ")
    }
}
