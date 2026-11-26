//
//  CheatManager.swift
//  3ds2apple
//
//  Cheat codes are the player's own text file, not something the app ships:
//  Documents/Cheats/<TITLEID>.txt in the Citra/Azahar format, the same text the
//  desktop tools use. This file owns that file's model (parse, serialize,
//  validate, read, write); the runtime half is CheatBridge.swift.
//
//  The format, as the runtime parses it:
//
//    [Cheat name]
//    *citra_enabled
//    *by someone
//    00123456 00000063
//    0012345A 00000001
//
//  A section starts with "[name]"; a line after a "*" is a note, except the
//  exact "*citra_enabled" marker that turns the cheat on for the next frame.
//  Every other non-empty line is kept as written; only "XXXXXXXX YYYYYYYY"
//  (8 hex digits, a separator, 8 hex digits) runs. A section with no other line
//  defines no cheat, exactly like the runtime.
//
//  Limits mirror the runtime ABI (ios/ZakuroBridge.h + ios/zakuro-ios/src/cheats.rs):
//  file <= 256 KiB, <= 128 cheats, <= 1024 lines per cheat. A load past those is
//  refused by the runtime, so the app refuses to save such a file too and says
//  which limit was hit.
//
//  Nothing here downloads or bundles codes; the Files-app import and the text
//  editor are the only ways a file appears.
//

import Foundation

// MARK: - Text model

/// One cheat section of the file. `lines` is every non-note line of the section
/// as written (codes and lines the runtime keeps but does not run); `notes` is
/// the text after a "*" that is not the enable marker.
struct CheatEntry: Identifiable, Equatable {
    /// Stable per parse; the runtime identifies entries by list order instead.
    let id = UUID()
    var name: String
    var enabled: Bool
    var notes: [String]
    var lines: [String]

    var codeLineCount: Int { lines.reduce(0) { $0 + (CheatDocument.isCodeLine($1) ? 1 : 0) } }
    var invalidLineCount: Int { lines.count - codeLineCount }
}

/// One reason a file cannot be loaded/saved: the runtime ABI's limits.
enum CheatLimitIssue: Equatable {
    case fileTooLarge(bytes: Int)
    case tooManyCheats(count: Int)
    case tooManyLines(name: String, count: Int)

    var localizedMessage: String {
        switch self {
        case .fileTooLarge(let bytes):
            return L10n.format(
                "The cheat file is %ld bytes; this build reads at most %ld KiB.",
                bytes,
                CheatDocument.maxFileBytes / 1024
            )
        case .tooManyCheats(let count):
            return L10n.format(
                "This file defines %ld cheats; this build reads at most %ld.",
                count,
                CheatDocument.maxCheats
            )
        case .tooManyLines(let name, let count):
            return L10n.format(
                "The cheat “%@” has %ld lines; this build reads at most %ld.",
                name,
                count,
                CheatDocument.maxLinesPerCheat
            )
        }
    }
}

/// A whole cheat file. Parses and writes the Citra/Azahar text the runtime reads.
struct CheatDocument: Equatable {
    /// 256 KiB, the runtime ABI's largest file (ZK_CHEATS_MAX_FILE_BYTES).
    static let maxFileBytes = 256 * 1024
    /// 128, the runtime ABI's most cheats in one file (ZK_CHEATS_MAX_CHEATS).
    static let maxCheats = 128
    /// 1024, the runtime ABI's longest line list for one cheat (ZK_CHEATS_MAX_LINES).
    static let maxLinesPerCheat = 1024

    var entries: [CheatEntry]

    init(entries: [CheatEntry] = []) {
        self.entries = entries
    }

    /// Parses the text exactly the way the runtime does.
    init(text: String) {
        var parsed: [CheatEntry] = []
        var name = ""
        var notes: [String] = []
        var lines: [String] = []
        var enabled = false
        func finish() {
            // The runtime only keeps a section that has at least one line after
            // its notes; a header with nothing under it defines no cheat.
            if !lines.isEmpty {
                parsed.append(CheatEntry(name: name, enabled: enabled, notes: notes, lines: lines))
            }
            notes = []
            lines = []
            enabled = false
        }
        // NUL bytes are ignored (the runtime strips them before trimming).
        let cleaned = text.replacingOccurrences(of: "\0", with: "")
        for rawLine in cleaned.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.count >= 2, line.hasPrefix("[") {
                finish()
                // Mirrors the runtime: everything between the first and last
                // character of the header line is the name.
                name = String(line.dropFirst().dropLast())
            } else if line.hasPrefix("*") {
                if line == "*citra_enabled" {
                    enabled = true
                } else {
                    notes.append(String(line.dropFirst()))
                }
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        finish()
        entries = parsed
    }

    /// The file text in the runtime's format: header, enable marker, notes, then
    /// the lines as written, with one blank line between cheats.
    var text: String {
        var out = ""
        for entry in entries {
            out += "[" + entry.name + "]\n"
            if entry.enabled {
                out += "*citra_enabled\n"
            }
            for note in entry.notes {
                out += "*" + note + "\n"
            }
            for line in entry.lines {
                out += line + "\n"
            }
            out += "\n"
        }
        return out
    }

    var utf8ByteCount: Int { text.utf8.count }
    var enabledCount: Int { entries.filter { $0.enabled }.count }
    var invalidLineCount: Int { entries.reduce(0) { $0 + $1.invalidLineCount } }

    /// The runtime ABI's limits this document breaks, empty when it is savable.
    func limitIssues(fileBytes: Int? = nil) -> [CheatLimitIssue] {
        var issues: [CheatLimitIssue] = []
        let bytes = fileBytes ?? utf8ByteCount
        if bytes > Self.maxFileBytes {
            issues.append(.fileTooLarge(bytes: bytes))
        }
        if entries.count > Self.maxCheats {
            issues.append(.tooManyCheats(count: entries.count))
        }
        for entry in entries where entry.lines.count > Self.maxLinesPerCheat {
            issues.append(.tooManyLines(name: entry.name, count: entry.lines.count))
        }
        return issues
    }

    /// One line of "XXXXXXXX YYYYYYYY": 8 hex digits, any separator, 8 hex
    /// digits. Mirrors the runtime's parser, so the app's count of the lines
    /// that run matches the runtime's `lines`/`invalidLines` JSON.
    static func isCodeLine(_ line: String) -> Bool {
        guard line.count == 17, line.allSatisfy({ $0.isASCII }) else { return false }
        let characters = Array(line)
        let first = characters[0..<8]
        let last = characters[9..<17]
        return first.allSatisfy { $0.isHexDigit } && last.allSatisfy { $0.isHexDigit }
    }
}

// MARK: - Storage

/// What a title's cheat file looks like right now, for the settings list and the
/// game's detail page.
struct CheatFileSnapshot {
    let titleID: String
    let url: URL
    let exists: Bool
    let bytes: Int
    /// The text the file holds, nil when it is missing or not readable as UTF-8.
    let text: String?
    let document: CheatDocument?
    let readError: String?
    let limitIssues: [CheatLimitIssue]

    var fileName: String { url.lastPathComponent }
    var entries: [CheatEntry] { document?.entries ?? [] }
}

/// The app's authority for cheat files: Documents/Cheats/<TITLEID>.txt.
///
/// The folder is inside the app's Documents, so the Files app and the share
/// sheet can import/export a file; it is outside Documents/data, so the Save
/// Manager's archive of a game's data does not sweep the codes in.
enum CheatManager {
    /// Documents/Cheats.
    static let folderName = "Cheats"

    /// Documents/Cheats, created on the first save.
    static var folderURL: URL {
        StorageInspector.documentsURL.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Documents/Cheats/<TITLEID>.txt, the one authority for a title's codes.
    static func fileURL(titleID: String) -> URL {
        folderURL.appendingPathComponent(normalizedTitleID(titleID) + ".txt", isDirectory: false)
    }

    /// Upper-case 16 hex digits when possible, else the raw name upper-cased (a
    /// title id the app cannot normalise never gets a path outside the folder).
    static func normalizedTitleID(_ raw: String) -> String {
        GameCatalog.normalizedTitleID(raw) ?? raw.uppercased()
    }

    /// Reads and parses one title's file. Missing is not an error (it means the
    /// player has no codes for that title yet); an unreadable/non-UTF-8 file is
    /// reported so the UI can offer to replace it.
    static func snapshot(titleID: String) -> CheatFileSnapshot {
        let url = fileURL(titleID: titleID)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return CheatFileSnapshot(
                titleID: titleID,
                url: url,
                exists: false,
                bytes: 0,
                text: nil,
                document: nil,
                readError: nil,
                limitIssues: []
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return CheatFileSnapshot(
                titleID: titleID,
                url: url,
                exists: true,
                bytes: 0,
                text: nil,
                document: nil,
                readError: L10n.format("Could not read the selected file: %@", error.localizedDescription),
                limitIssues: []
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            var issues: [CheatLimitIssue] = []
            if data.count > CheatDocument.maxFileBytes {
                issues.append(.fileTooLarge(bytes: data.count))
            }
            return CheatFileSnapshot(
                titleID: titleID,
                url: url,
                exists: true,
                bytes: data.count,
                text: nil,
                document: nil,
                readError: L10n.tr("The selected file is not UTF-8 text."),
                limitIssues: issues
            )
        }
        let document = CheatDocument(text: text)
        return CheatFileSnapshot(
            titleID: titleID,
            url: url,
            exists: true,
            bytes: data.count,
            text: text,
            document: document,
            readError: nil,
            limitIssues: document.limitIssues(fileBytes: data.count)
        )
    }

    /// Writes a parsed document. Refuses a document past the runtime limits and
    /// writes atomically (temporary file + rename), so an interrupted save
    /// leaves the previous file whole.
    static func write(_ document: CheatDocument, titleID: String) throws {
        let issues = document.limitIssues()
        guard issues.isEmpty else {
            throw CheatFileError.limit(issues.map(\.localizedMessage).joined(separator: " "))
        }
        try writeText(document.text, titleID: titleID)
    }

    /// Writes text the caller already validated (the import/text-editor paths
    /// parse it first). Creates Documents/Cheats on the first save.
    static func writeText(_ text: String, titleID: String) throws {
        guard let data = text.data(using: .utf8) else {
            throw CheatFileError.notUTF8
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try AtomicFileWriter.write(data, to: fileURL(titleID: titleID))
        } catch {
            throw CheatFileError.writeFailed(error.localizedDescription)
        }
    }

    /// One line for the library list: the file's cheat/enable counts, or why it
    /// cannot be read.
    static func summaryLine(titleID: String) -> String {
        let snapshot = snapshot(titleID: titleID)
        if let error = snapshot.readError {
            return error
        }
        guard snapshot.exists, let document = snapshot.document else {
            return L10n.tr("No cheat file")
        }
        var summary = L10n.format("%ld cheats · %ld on", document.entries.count, document.enabledCount)
        if document.invalidLineCount > 0 {
            summary += L10n.format(" · %ld lines not run", document.invalidLineCount)
        }
        return summary
    }

    /// The diagnostics report's `cheats_file=`: the file's state and the number
    /// of entries/enabled cheats, or "no game loaded"/"absent".
    static func diagnosticsLine(titleID: String?) -> String {
        guard let titleID, !titleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "no game loaded (Documents/Cheats keeps one file per title)"
        }
        let snapshot = snapshot(titleID: titleID)
        var parts = [
            "file=Documents/\(folderName)/\(snapshot.fileName)",
            "exists=\(snapshot.exists ? 1 : 0)",
            "bytes=\(snapshot.bytes)",
        ]
        if let document = snapshot.document {
            parts.append("entries=\(document.entries.count)")
            parts.append("enabled=\(document.enabledCount)")
            parts.append("invalid_lines=\(document.invalidLineCount)")
        }
        if let error = snapshot.readError {
            parts.append("error=\(error)")
        }
        if !snapshot.limitIssues.isEmpty {
            parts.append("limits=\(snapshot.limitIssues.map(\.localizedMessage).joined(separator: " "))")
        }
        return parts.joined(separator: " ")
    }
}

/// Errors from the file side of the Cheats UI.
enum CheatFileError: LocalizedError {
    case notUTF8
    case limit(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notUTF8:
            return L10n.tr("The selected file is not UTF-8 text.")
        case .limit(let detail):
            return detail
        case .writeFailed(let detail):
            return L10n.format("Could not write the cheat file: %@", detail)
        }
    }
}
