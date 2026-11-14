//
//  StorageInspector.swift
//  3ds2apple
//
//  Filesystem facts for the Storage settings and the Save Manager: how much
//  space the legacy game files, the runtime save data, the app logs and the
//  regenerable graphics pipeline cache use, and which save files exist.
//
//  Everything stays inside the app container. The inspector itself only reads
//  the directories and clears the pipeline cache (which the runtime rebuilds on
//  the next load and which never contains save data); the save files it lists
//  are written by the runtime and by the Save Manager through
//  `AtomicFileWriter`.
//

import Foundation

/// One snapshot of the app container usage. Built off the main queue.
struct StorageSnapshot {
    var documentsPath = ""
    /// Documents/Games: the game data the desktop launcher pushed (the AOT
    /// packs themselves are inside the app bundle).
    var gamesBytes: UInt64 = 0
    var gamesFileCount = 0
    /// Documents/roms: cartridges of the 0.1.x shell (legacy only).
    var romBytes: UInt64 = 0
    var romFileCount = 0
    var saveDataBytes: UInt64 = 0
    var saveFileCount = 0
    var logBytes: UInt64 = 0
    var logFileCount = 0
    var cacheBytes: UInt64 = 0
    var cacheFileCount = 0

    static let empty = StorageSnapshot()

    var totalBytes: UInt64 { gamesBytes + romBytes + saveDataBytes + logBytes + cacheBytes }

    static func sizeText(_ bytes: UInt64) -> String {
        // ByteCountFormatter renders 0 as "Zero KB", which reads like a bug.
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var totalText: String { Self.sizeText(totalBytes) }
}

/// One save-data file written by the runtime.
struct SaveDataEntry: Identifiable {
    /// Path relative to the data directory, unique per file.
    let id: String
    /// File name shown in the Save Manager row.
    let name: String
    /// Per-game directory (the runtime's data directory name).
    let game: String
    let bytes: UInt64
    let modified: Date?
}

enum StorageInspector {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static var dataURL: URL {
        documentsURL.appendingPathComponent("data", isDirectory: true)
    }

    /// Documents/Games: one folder per launcher-pushed game's data (ROM and
    /// GameInfo.json; the AOT pack is inside the app bundle).
    static var gamesURL: URL {
        documentsURL.appendingPathComponent(DocumentsGames.folderName, isDirectory: true)
    }

    /// Documents/roms: the 0.1.x shell's cartridges (legacy builds only).
    static var romsURL: URL {
        documentsURL.appendingPathComponent("roms", isDirectory: true)
    }

    static var logsURL: URL {
        documentsURL.appendingPathComponent("logs", isDirectory: true)
    }

    /// Reads the directory sizes. Small directories; a multi-GB ROM is measured
    /// from its metadata, not by reading it.
    static func snapshot() -> StorageSnapshot {
        var snapshot = StorageSnapshot.empty
        snapshot.documentsPath = documentsURL.path

        let games = directorySize(gamesURL)
        snapshot.gamesBytes = games.bytes
        snapshot.gamesFileCount = games.files

        let roms = directorySize(romsURL)
        snapshot.romBytes = roms.bytes
        snapshot.romFileCount = roms.files

        let data = directorySize(dataURL)
        snapshot.saveDataBytes = data.bytes
        snapshot.saveFileCount = data.files

        let logs = directorySize(logsURL)
        snapshot.logBytes = logs.bytes
        snapshot.logFileCount = logs.files

        if let cacheURL = PipelineCacheStats.directoryURL {
            let cache = directorySize(cacheURL)
            snapshot.cacheBytes = cache.bytes
            snapshot.cacheFileCount = cache.files
        }
        return snapshot
    }

    /// Save files under Documents/data, newest first. The runtime writes battery
    /// saves here; save states are not part of this directory.
    static func saveDataEntries() -> [SaveDataEntry] {
        let fileManager = FileManager.default
        guard let games = try? fileManager.contentsOfDirectory(
            at: dataURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [SaveDataEntry] = []
        for game in games {
            let gameName = game.lastPathComponent
            let isDirectory = (try? game.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else {
                entries.append(makeEntry(url: game, game: "", fallbackName: gameName))
                continue
            }
            guard let subpaths = try? fileManager.subpathsOfDirectory(atPath: game.path) else { continue }
            for subpath in subpaths {
                let url = game.appendingPathComponent(subpath)
                entries.append(makeEntry(url: url, game: gameName, fallbackName: subpath))
            }
        }
        entries.sort { lhs, rhs in
            (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast)
        }
        return entries
    }

    /// Deletes the cached graphics pipelines. The cache is regenerated on the
    /// next load; no save data is touched. Returns false only when the deletion
    /// itself fails.
    @discardableResult
    static func clearPipelineCache() -> Bool {
        guard let url = PipelineCacheStats.directoryURL else { return false }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            AppLog.log("[3ds2apple] cleared the graphics pipeline cache")
            return true
        } catch {
            AppLog.log("[3ds2apple] could not clear the pipeline cache: %@", error.localizedDescription)
            return false
        }
    }

    // MARK: - Helpers

    private static func makeEntry(url: URL, game: String, fallbackName: String) -> SaveDataEntry {
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        )
        let name = url.lastPathComponent.isEmpty ? fallbackName : url.lastPathComponent
        let id = game.isEmpty ? name : "\(game)/\(name)"
        return SaveDataEntry(
            id: id,
            name: name,
            game: game,
            bytes: UInt64(max(values?.fileSize ?? 0, 0)),
            modified: values?.contentModificationDate
        )
    }

    private static func directorySize(_ url: URL) -> (bytes: UInt64, files: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }
        var bytes: UInt64 = 0
        var files = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            bytes += UInt64(max(values.fileSize ?? 0, 0))
            files += 1
        }
        return (bytes, files)
    }
}

/// Formats a byte count for the settings rows and the save manager.
enum StorageFormat {
    static func size(_ bytes: UInt64) -> String {
        // ByteCountFormatter renders 0 as "Zero KB", which reads like a bug in
        // the save manager rows; show a plain 0 KB instead.
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Short relative time for library cards: "2 days ago" / "2天前" within a
    /// week, then a short date.
    static func relativeDate(_ date: Date) -> String {
        if abs(Date().timeIntervalSince(date)) < 7 * 24 * 60 * 60 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            formatter.locale = displayLocale
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return Self.date(date)
    }

    /// The app language, not the device locale: the UI follows the bundle
    /// language pick, so dates must not fall back to the system locale.
    private static var displayLocale: Locale {
        Locale(identifier: L10n.currentLanguage == .simplifiedChinese ? "zh_Hans" : "en_US")
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        formatter.locale = displayLocale
        return formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

/// File writes that must not leave a half-written file behind.
///
/// The Save Manager and the instant save slots replace files the game will read
/// back later, so each write goes to a temporary file in the same directory and
/// is renamed into place only when complete: a crash, a full disk or a killed
/// app can then leave the old file or the new one, never half of either.
enum AtomicFileWriter {
    /// Writes `data` to `url` through a temporary file and then renames it over
    /// the destination. Creates the parent directory when needed.
    static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: [])
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
