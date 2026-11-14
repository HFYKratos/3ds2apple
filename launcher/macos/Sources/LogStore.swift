//
//  LogStore.swift
//  3ds2apple macOS launcher
//
//  In-memory activity log with an optional on-disk export. Log lines never
//  include Apple ID passwords, device UDIDs chosen outside mock mode, or key
//  material: see redact(_:) and docs/macos-launcher.md (privacy).
//

import Foundation

final class LogStore {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let maximumEntries = 4_000
    private let logFileURL: URL?

    init(logFileURL: URL?) {
        self.logFileURL = logFileURL
        if let logFileURL {
            try? FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    func append(level: LogLevel, category: String, message: String) -> LogEntry {
        let entry = LogEntry(date: Date(), level: level, category: category, message: LogStore.redact(message))
        lock.lock()
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        lock.unlock()
        if let logFileURL,
           let data = (entry.line + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFileURL)
            }
        }
        return entry
    }

    func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func exportText() -> String {
        snapshot().map { $0.line }.joined(separator: "\n") + "\n"
    }

    /// Remove values that must never be written to a shared log:
    /// device UDIDs, 40-char hex SHA-1 values and e-mail-shaped Apple ID addresses.
    static func redact(_ message: String) -> String {
        var result = message
        let patterns = [
            "([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})",
            "([0-9A-Fa-f]{40})",
            "([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,})",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<redacted>")
            }
        }
        return result
    }
}
