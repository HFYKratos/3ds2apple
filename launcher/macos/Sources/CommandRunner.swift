//
//  CommandRunner.swift
//  3ds2apple macOS launcher
//
//  Thin async wrapper around Foundation.Process: streamed lines, exit status and
//  cancellation. A protocol plus a mock implementation keep the pipeline and the
//  dry-run mode testable without spawning anything.
//

import Foundation
import CryptoKit

struct CommandSpec: Equatable {
    var executable: String
    var arguments: [String]
    var workingDirectory: String?
    var environment: [String: String] = [:]

    var displayText: String {
        ([executable] + arguments)
            .map { $0.contains(" ") ? "\"" + $0 + "\"" : $0 }
            .joined(separator: " ")
    }
}

struct CommandResult: Equatable {
    var command: CommandSpec
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: TimeInterval
    var cancelled: Bool = false

    var succeeded: Bool { exitCode == 0 && !cancelled }
    var combined: String {
        var text = stdout
        if !stderr.isEmpty {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += stderr
        }
        return text
    }
}

protocol CommandRunning: AnyObject {
    @discardableResult
    func run(
        _ spec: CommandSpec,
        onLine: ((_ level: LogLevel, _ line: String) -> Void)?
    ) async throws -> CommandResult
    func terminateAll()
}

/// Collector shared by the two pipes; thread-safe and line-oriented.
private final class OutputCollector {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutLineBuffer = ""
    private var stderrLineBuffer = ""
    private let onLine: ((LogLevel, String) -> Void)?

    init(onLine: ((LogLevel, String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isError { stderr.append(data) } else { stdout.append(data) }
        var text = String(decoding: data, as: UTF8.self)
        lock.unlock()
        while let newlineIndex = text.firstIndex(of: "\n") {
            let line = String(text[..<newlineIndex])
            text = String(text[text.index(after: newlineIndex)...])
            deliver(line, isError: isError)
        }
        if !text.isEmpty {
            lock.lock()
            if isError { stderrLineBuffer += text } else { stdoutLineBuffer += text }
            lock.unlock()
            deliver(text, isError: isError, partial: true)
        }
    }

    private func deliver(_ line: String, isError: Bool, partial: Bool = false) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let onLine else { return }
        let level: LogLevel = isError ? .warn : .info
        DispatchQueue.main.async { onLine(level, trimmed) }
    }

    func snapshot() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self)
        )
    }
}

final class RealCommandRunner: CommandRunning {
    private let lock = NSLock()
    private var running: [Int32: Process] = [:]

    @discardableResult
    func run(
        _ spec: CommandSpec,
        onLine: ((LogLevel, String) -> Void)?
    ) async throws -> CommandResult {
        let started = Date()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: spec.executable)
                process.arguments = spec.arguments
                if let workingDirectory = spec.workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                }
                if !spec.environment.isEmpty {
                    var environment = ProcessInfo.processInfo.environment
                    for (key, value) in spec.environment { environment[key] = value }
                    process.environment = environment
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                let collector = OutputCollector(onLine: onLine)
                let resumed = LockedFlag()

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        collector.append(data, isError: false)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        collector.append(data, isError: true)
                    }
                }

                process.terminationHandler = { finished in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingOut.isEmpty { collector.append(remainingOut, isError: false) }
                    if !remainingErr.isEmpty { collector.append(remainingErr, isError: true) }
                    self.lock.lock()
                    self.running.removeValue(forKey: finished.processIdentifier)
                    self.lock.unlock()
                    let output = collector.snapshot()
                    let result = CommandResult(
                        command: spec,
                        exitCode: finished.terminationStatus,
                        stdout: output.stdout,
                        stderr: output.stderr,
                        duration: Date().timeIntervalSince(started),
                        cancelled: finished.terminationReason == .uncaughtSignal
                    )
                    if resumed.setIfUnset() {
                        continuation.resume(returning: result)
                    }
                }

                do {
                    try process.run()
                } catch {
                    if resumed.setIfUnset() {
                        continuation.resume(throwing: LauncherFailure(
                            code: "command_launch_failed",
                            message: "Could not start " + spec.executable + ".",
                            hint: "Check the path in Settings and that the tool is executable.",
                            detail: error.localizedDescription,
                            exitCode: nil
                        ))
                    }
                    return
                }
                self.lock.lock()
                self.running[process.processIdentifier] = process
                self.lock.unlock()
            }
        }
    }

    func terminateAll() {
        lock.lock()
        let processes = running.values
        running.removeAll()
        lock.unlock()
        for process in processes where process.isRunning {
            process.terminate()
        }
    }
}

private final class LockedFlag {
    private let lock = NSLock()
    private var value = false

    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// Deterministic runner for mock/dry-run mode. It never spawns a process.
final class MockCommandRunner: CommandRunning {
    private let lock = NSLock()
    private(set) var recorded: [CommandSpec] = []
    var handler: ((CommandSpec) async throws -> CommandResult)?
    var artificialDelay: TimeInterval = 0.02

    func run(
        _ spec: CommandSpec,
        onLine: ((LogLevel, String) -> Void)?
    ) async throws -> CommandResult {
        lock.lock()
        recorded.append(spec)
        lock.unlock()
        if artificialDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(artificialDelay * 1_000_000_000))
        }
        if let handler {
            return try await handler(spec)
        }
        return CommandResult(
            command: spec,
            exitCode: 0,
            stdout: "",
            stderr: "",
            duration: artificialDelay
        )
    }

    func terminateAll() {}
}

// MARK: - Small file helpers

enum FileProbe {
    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    static func size(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.int64Value
    }

    static func sha256(ofFile path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return String(bytes) + " B" }
        return String(format: "%.1f %@", value, units[unit])
    }
}
