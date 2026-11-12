//
//  AppLog.swift
//  3ds2apple
//
//  In-app log capture and diagnostics export.
//
//  The Rust runtime writes to stderr; redirecting stderr into a pipe lets the
//  app keep those lines without changing the C ABI. Swift call sites use
//  `AppLog.log` instead of `NSLog`, so both sides end up in one ring buffer and
//  one on-disk file that the user can export from the UI.
//

import Darwin
import Foundation

final class AppLog {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "com.kratos.3ds2apple.log")
    private let maxLines = 8000
    private let maxFileBytes: UInt64 = 2 * 1024 * 1024

    private var lines: [String] = []
    private var started = false
    private var fileHandle: FileHandle?
    private var fileBytes: UInt64 = 0
    private var pipe: Pipe?
    private var latestURL: URL?
    private var previousURL: URL?
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {}

    /// Call once, as early as possible (App.init), before any Rust/UI logging.
    func start() {
        queue.sync {
            guard !started else { return }
            started = true
            setUpFile()
        }
        redirectStandardStreams()
        append("app", "3ds2apple log started; \(deviceSummary())")
    }

    /// NSLog-compatible formatting; safe from any thread.
    static func log(_ format: String, _ arguments: CVarArg...) {
        let message = String(format: format, arguments: arguments)
        shared.append("app", message)
    }

    func append(_ source: String, _ message: String) {
        let text = message.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let stamp = self.timestampFormatter.string(from: Date())
            let block = "\(stamp) [\(source)] \(text)"
            self.lines.append(block)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
            self.writeToFile(block)
        }
    }

    /// Current process log, newest last.
    func snapshot() -> String {
        queue.sync { lines.joined(separator: "\n") }
    }

    /// Full report used by the export button: header, previous session, current
    /// session. File writes happen on the log queue; call from the main queue.
    func exportReport(header: String) -> String {
        let previous = queue.sync { () -> String in
            guard let previousURL else { return "" }
            return (try? String(contentsOf: previousURL, encoding: .utf8)) ?? ""
        }
        let current = snapshot()
        var report = header
        report += "\n\n=== previous session log ===\n"
        report += previous.isEmpty ? "(none)\n" : previous
        report += "\n=== current session log ===\n"
        report += current.isEmpty ? "(none)\n" : current
        report += "\n"
        return report
    }

    // MARK: - Files

    private func setUpFile() {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let logs = documents.appendingPathComponent("logs", isDirectory: true)
        try? fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        let latest = logs.appendingPathComponent("latest.log")
        let previous = logs.appendingPathComponent("previous.log")
        if fileManager.fileExists(atPath: latest.path) {
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: latest, to: previous)
        }
        fileManager.createFile(atPath: latest.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: latest)
        latestURL = latest
        previousURL = previous
        fileBytes = 0
    }

    private func writeToFile(_ block: String) {
        guard let fileHandle, let data = (block + "\n").data(using: .utf8) else { return }
        if fileBytes + UInt64(data.count) > maxFileBytes {
            // Keep the current session bounded; the previous session file holds
            // the earlier part when it was rotated at launch.
            try? fileHandle.truncate(atOffset: 0)
            try? fileHandle.seek(toOffset: 0)
            fileBytes = 0
        }
        do {
            try fileHandle.write(contentsOf: data)
            fileBytes += UInt64(data.count)
        } catch {
            // Logging must never break the runtime.
        }
    }

    // MARK: - Standard error/stdout capture

    private func redirectStandardStreams() {
        let pipe = Pipe()
        self.pipe = pipe
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                self?.append("runtime", text)
            }
        }
    }

    // MARK: - Report helpers

    private func deviceSummary() -> String {
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion) · \(device.model) · \(device.name)"
    }
}
