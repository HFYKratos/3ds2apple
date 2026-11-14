//
//  DeviceBridge.swift
//  3ds2apple macOS launcher
//
//  Client for the device-bridge CLI contract v1 published by task-16
//  (tools/devpush, schema "devpush/1"). The launcher drives the bridge with
//  --json NDJSON events and never talks USB/AFC itself.
//
//  Commands used:
//    capabilities, devices, app-attr, mkdir, put, stat, ls
//  Containers: --container app (house_arrest VendContainer), paths relative to
//  the app container, e.g. Documents/Games/<TITLEID>/GamePack.dylib.
//
//  Until tools/devpush is built, the launcher runs in mock/dry-run mode and the
//  Diagnostics screen says so. No credentials, UDIDs or Apple IDs are passed to
//  the bridge by the launcher.
//

import Foundation

struct DevpushFailure: Error, Equatable {
    var code: String
    var message: String
    var hint: String
    var detail: String?
    var exitCode: Int32?
}

enum BridgeCommand: String {
    case capabilities
    case devices
    case appAttr = "app-attr"
    case mkdir
    case put
    case get
    case stat
    case ls
    case install
    case uninstall
}

protocol DeviceBridge: AnyObject {
    var mode: LauncherRunMode { get }
    var displayName: String { get }
    func capabilities() async throws -> BridgeCapabilities
    func devices() async throws -> [DeviceInfo]
    func appAttr(bundleID: String, udid: String?) async throws -> AppAttr
    func mkdir(bundleID: String, path: String, udid: String?) async throws
    func put(
        bundleID: String,
        local: String,
        remote: String,
        udid: String?,
        onProgress: @escaping (Int64, Int64) -> Void
    ) async throws -> PutResult
    func stat(bundleID: String, path: String, udid: String?) async throws -> RemoteEntry?
    func ls(bundleID: String, path: String, udid: String?) async throws -> [RemoteEntry]
}

// MARK: - NDJSON parsing

/// One parsed devpush NDJSON line. The raw dictionary is kept for typed
/// extraction; runtime code uses the small accessors below so the parsing stays
/// unit-checkable.
struct BridgeLine: Equatable {
    var type: String
    var command: String?
    var raw: String
}

enum DevpushNDJSON {
    static func parse(_ line: String) -> BridgeLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if let schema = object["schema"] as? String, schema != "devpush/1" {
            return nil
        }
        return BridgeLine(type: type, command: object["command"] as? String, raw: trimmed)
    }

    static func json(_ line: BridgeLine) -> [String: Any]? {
        guard let data = line.raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// "progress" event -> (bytesSent, bytesTotal, file name).
    static func progress(_ line: BridgeLine) -> (sent: Int64, total: Int64, file: String?)? {
        guard line.type == "progress", let object = json(line) else { return nil }
        let sent = PackJSON.int64(object["bytesSent"])
        let total = PackJSON.int64(object["bytesTotal"])
        let file = object["file"] as? String
        return (sent, total, file)
    }

    /// "error" event -> failure details.
    static func error(_ line: BridgeLine) -> (code: String, message: String, hint: String?)? {
        guard line.type == "error", let object = json(line) else { return nil }
        let error = object["error"] as? [String: Any]
        let code = error?["code"] as? String ?? "bridge_error"
        let message = error?["message"] as? String ?? "The device bridge reported an error."
        return (code, message, error?["hint"] as? String)
    }

    /// "done" event -> payload dictionary.
    static func done(_ line: BridgeLine) -> [String: Any]? {
        guard line.type == "done" else { return nil }
        return json(line)
    }

    static func lines(_ stdout: String) -> [BridgeLine] {
        stdout.split(separator: "\n").compactMap { parse(String($0)) }
    }

    static func firstError(_ stdout: String) -> (code: String, message: String, hint: String?)? {
        for line in lines(stdout) {
            if let error = error(line) { return error }
        }
        return nil
    }

    static func lastDone(_ stdout: String, command: String) -> [String: Any]? {
        for line in lines(stdout).reversed() where line.type == "done" {
            if line.command == nil || line.command == command {
                return done(line)
            }
        }
        return nil
    }
}

// MARK: - Bridge failures

enum BridgeExitCodes {
    static func hint(for code: String) -> String {
        switch code {
        case "device_not_found":
            return "Connect the iPhone/iPad with a USB cable, unlock it and tap Trust, then refresh."
        case "device_ambiguous":
            return "More than one device is connected; pick one in the Device popup."
        case "usbmuxd_unavailable":
            return "The device service is not running. Reconnect the cable or restart the Mac."
        case "pairing_required":
            return "This Mac is not paired with the device yet: unlock it, tap Trust, and keep it connected."
        case "device_locked":
            return "Unlock the device and keep the screen on during the transfer."
        case "app_missing":
            return "Install the base shell first (Base shell screen)."
        case "container_unavailable":
            return "The shell must enable file sharing (UIFileSharingEnabled) or be a development-signed install."
        case "stall_timeout":
            return "The transfer stalled for 90 s. Check the cable or Wi-Fi, then retry; already-written files are skipped."
        case "afc_error", "path_not_found", "io_error":
            return "The device file service reported an error. Retry; if it persists, restart the shell app on the phone."
        case "install_failed":
            return "The app could not be installed. Check signing, trust and free space on the device."
        case "unsupported":
            return "This device-bridge build does not support the command; update tools/devpush."
        default:
            return "Check the device connection and try again."
        }
    }

    static func exitHint(for exitCode: Int32) -> String {
        switch exitCode {
        case 3: return hint(for: "device_not_found")
        case 4: return hint(for: "pairing_required")
        case 5: return hint(for: "app_missing")
        case 6: return hint(for: "stall_timeout")
        case 7: return hint(for: "io_error")
        case 8: return hint(for: "install_failed")
        case 9: return hint(for: "unsupported")
        default: return ""
        }
    }
}

// MARK: - Real client

final class DevpushCLI: DeviceBridge {
    let binary: String
    let mockDirectory: String?
    let runner: CommandRunning

    init(binary: String, mockDirectory: String?, runner: CommandRunning = RealCommandRunner()) {
        self.binary = binary
        self.mockDirectory = mockDirectory
        self.runner = runner
    }

    var mode: LauncherRunMode { mockDirectory == nil ? .live : .mock }
    var displayName: String {
        if let mockDirectory { return "devpush (mock dir: " + mockDirectory + ")" }
        return binary
    }

    // MARK: commands

    func capabilities() async throws -> BridgeCapabilities {
        let result = try await run(["capabilities"])
        if let failure = failure(from: result, command: "capabilities", attempt: 0) { throw failure }
        guard let done = DevpushNDJSON.lastDone(result.stdout, command: "capabilities") else {
            throw parseFailure("capabilities", result)
        }
        let features = (done["features"] as? [String: Any] ?? [:]).reduce(into: [String: Bool]()) { partial, pair in
            partial[pair.key] = (pair.value as? Bool) ?? false
        }
        return BridgeCapabilities(
            version: done["version"] as? String ?? "unknown",
            schema: done["schema"] as? String ?? "devpush/1",
            commands: done["commands"] as? [String] ?? [],
            features: features,
            mock: done["mock"] as? Bool ?? (mockDirectory != nil)
        )
    }

    func devices() async throws -> [DeviceInfo] {
        let result = try await run(["devices"])
        if let failure = failure(from: result, command: "devices", attempt: 0) { throw failure }
        guard let done = DevpushNDJSON.lastDone(result.stdout, command: "devices") else {
            throw parseFailure("devices", result)
        }
        let items = done["devices"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let udid = item["udid"] as? String else { return nil }
            return DeviceInfo(
                udid: udid,
                name: item["name"] as? String ?? "Unknown device",
                model: item["model"] as? String ?? "iOS device",
                iosVersion: item["iosVersion"] as? String ?? "?",
                connection: item["connection"] as? String ?? "usb",
                paired: item["paired"] as? Bool ?? true
            )
        }
    }

    func appAttr(bundleID: String, udid: String?) async throws -> AppAttr {
        let result = try await run(["app-attr", "--bundle-id", bundleID] + udidArguments(udid))
        if let error = DevpushNDJSON.firstError(result.stdout), error.code == "app_missing" {
            return AppAttr(installed: false, dataContainer: nil, appBundleVersion: nil, fileSharingEnabled: nil)
        }
        if let failure = failure(from: result, command: "app-attr", attempt: 0) { throw failure }
        let done = DevpushNDJSON.lastDone(result.stdout, command: "app-attr") ?? [:]
        return AppAttr(
            installed: done["installed"] as? Bool ?? true,
            dataContainer: done["dataContainer"] as? String,
            appBundleVersion: done["appBundleVersion"] as? String,
            fileSharingEnabled: done["fileSharingEnabled"] as? Bool
        )
    }

    func mkdir(bundleID: String, path: String, udid: String?) async throws {
        let result = try await run(["mkdir", "--bundle-id", bundleID, "--path", path] + udidArguments(udid))
        if result.succeeded { return }
        if let error = DevpushNDJSON.firstError(result.stdout) {
            if error.code == "already_exists" || error.code == "path_exists" { return }
            throw failure(from: result, command: "mkdir", attempt: 0) ?? parseFailure("mkdir", result)
        }
        throw parseFailure("mkdir", result)
    }

    func put(
        bundleID: String,
        local: String,
        remote: String,
        udid: String?,
        onProgress: @escaping (Int64, Int64) -> Void
    ) async throws -> PutResult {
        let started = Date()
        let result = try await run(
            ["put", "--bundle-id", bundleID, "--local", local, "--remote", remote] + udidArguments(udid),
            onLine: { _, line in
                if let parsed = DevpushNDJSON.parse(line), let progress = DevpushNDJSON.progress(parsed) {
                    onProgress(progress.sent, progress.total)
                }
            }
        )
        if let failure = failure(from: result, command: "put", attempt: 0) { throw failure }
        guard let done = DevpushNDJSON.lastDone(result.stdout, command: "put") else {
            throw parseFailure("put", result)
        }
        return PutResult(
            remotePath: done["remotePath"] as? String ?? remote,
            bytes: done["bytes"] as? Int64 ?? PackJSON.int64(done["bytes"]),
            sha256: done["sha256"] as? String ?? "",
            elapsed: Date().timeIntervalSince(started)
        )
    }

    func stat(bundleID: String, path: String, udid: String?) async throws -> RemoteEntry? {
        let result = try await run(["stat", "--bundle-id", bundleID, "--path", path] + udidArguments(udid))
        if result.succeeded, let done = DevpushNDJSON.lastDone(result.stdout, command: "stat") {
            return RemoteEntry(
                name: (done["path"] as? String ?? path).split(separator: "/").last.map(String.init) ?? path,
                isDirectory: done["isDir"] as? Bool ?? false,
                size: done["size"].map { PackJSON.int64($0) },
                modifiedAt: done["mtime"].map { String(describing: $0) }
            )
        }
        if let error = DevpushNDJSON.firstError(result.stdout), error.code == "path_not_found" {
            return nil
        }
        if result.succeeded { return nil }
        throw failure(from: result, command: "stat", attempt: 0) ?? parseFailure("stat", result)
    }

    func ls(bundleID: String, path: String, udid: String?) async throws -> [RemoteEntry] {
        let result = try await run(["ls", "--bundle-id", bundleID, "--path", path] + udidArguments(udid))
        if let failure = failure(from: result, command: "ls", attempt: 0) { throw failure }
        guard let done = DevpushNDJSON.lastDone(result.stdout, command: "ls") else {
            throw parseFailure("ls", result)
        }
        return (done["entries"] as? [[String: Any]] ?? []).map { item in
            RemoteEntry(
                name: item["name"] as? String ?? "",
                isDirectory: item["isDir"] as? Bool ?? false,
                size: item["size"].map { PackJSON.int64($0) },
                modifiedAt: item["mtime"].map { String(describing: $0) }
            )
        }
    }

    // MARK: internals

    private func spec(_ arguments: [String]) -> CommandSpec {
        var finalArguments = ["--json"]
        if let mockDirectory {
            finalArguments.append(contentsOf: ["--mock-dir", mockDirectory])
        }
        finalArguments.append(contentsOf: arguments)
        return CommandSpec(executable: binary, arguments: finalArguments)
    }

    private func run(
        _ arguments: [String],
        onLine: ((LogLevel, String) -> Void)? = nil
    ) async throws -> CommandResult {
        do {
            return try await runner.run(spec(arguments), onLine: onLine)
        } catch {
            let failure = LauncherFailure(
                code: "bridge_launch_failed",
                message: "Could not start the device bridge.",
                hint: "Build tools/devpush with cargo build --release, or set DEVPUSH_EXE.",
                detail: error.localizedDescription,
                exitCode: nil
            )
            throw failure
        }
    }

    private func udidArguments(_ udid: String?) -> [String] {
        guard let udid, !udid.isEmpty else { return [] }
        return ["--udid", udid]
    }

    private func failure(from result: CommandResult, command: String, attempt: Int) -> DevpushFailure? {
        guard !result.succeeded else { return nil }
        if let error = DevpushNDJSON.firstError(result.stdout) {
            return DevpushFailure(
                code: error.code,
                message: error.message,
                hint: error.hint ?? BridgeExitCodes.hint(for: error.code),
                detail: tail(result.combined),
                exitCode: result.exitCode
            )
        }
        let fallbackCode = "exit_\(result.exitCode)"
        return DevpushFailure(
            code: fallbackCode,
            message: "The device bridge failed (" + command + ", exit " + String(result.exitCode) + ").",
            hint: BridgeExitCodes.exitHint(for: result.exitCode) + " " + (tail(result.combined) ?? ""),
            detail: tail(result.combined),
            exitCode: result.exitCode
        )
    }

    private func parseFailure(_ command: String, _ result: CommandResult) -> DevpushFailure {
        DevpushFailure(
            code: "bridge_output",
            message: "The device bridge returned no machine-readable result for " + command + ".",
            hint: "Update tools/devpush (contract devpush/1) or run the command manually to see the error.",
            detail: tail(result.combined),
            exitCode: result.exitCode
        )
    }

    private func tail(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(3).joined(separator: " | ")
    }
}

/// Bridge used when tools/devpush is not built: every operation fails with the
/// same actionable message so the UI can stay honest instead of silently faking
/// a push in live mode.
final class UnavailableDeviceBridge: DeviceBridge {
    let mode: LauncherRunMode = .live
    var displayName: String { "devpush (not built)" }

    private func unavailable() -> DevpushFailure {
        DevpushFailure(
            code: "bridge_missing",
            message: "The device bridge (tools/devpush) is not built.",
            hint: "Build it with cargo build --release --manifest-path tools/devpush/Cargo.toml, or use dry-run/mock mode.",
            detail: nil,
            exitCode: nil
        )
    }

    func capabilities() async throws -> BridgeCapabilities { throw unavailable() }
    func devices() async throws -> [DeviceInfo] { throw unavailable() }
    func appAttr(bundleID: String, udid: String?) async throws -> AppAttr { throw unavailable() }
    func mkdir(bundleID: String, path: String, udid: String?) async throws { throw unavailable() }
    func put(bundleID: String, local: String, remote: String, udid: String?, onProgress: @escaping (Int64, Int64) -> Void) async throws -> PutResult { throw unavailable() }
    func stat(bundleID: String, path: String, udid: String?) async throws -> RemoteEntry? { throw unavailable() }
    func ls(bundleID: String, path: String, udid: String?) async throws -> [RemoteEntry] { throw unavailable() }
}
