//
//  StorageInspector.swift
//  3ds2apple
//
//  Filesystem facts for the Storage settings and the Save Manager: how much
//  space the imported ROMs, the runtime save data, the app logs and the
//  regenerable graphics pipeline cache use, and which save files exist.
//
//  Everything stays inside the app container; the app only reads the
//  directories. The one mutation is clearing the pipeline cache, which the
//  runtime rebuilds on the next load and which never contains save data.
//

import Foundation

/// One snapshot of the app container usage. Built off the main queue.
struct StorageSnapshot {
    var documentsPath = ""
    var romBytes: UInt64 = 0
    var romFileCount = 0
    var saveDataBytes: UInt64 = 0
    var saveFileCount = 0
    var logBytes: UInt64 = 0
    var logFileCount = 0
    var cacheBytes: UInt64 = 0
    var cacheFileCount = 0

    static let empty = StorageSnapshot()

    var totalBytes: UInt64 { romBytes + saveDataBytes + logBytes + cacheBytes }

    static func sizeText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
