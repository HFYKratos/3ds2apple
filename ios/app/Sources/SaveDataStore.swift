//
//  SaveDataStore.swift
//  3ds2apple
//
//  The battery save data the Zakuro runtime writes into
//  Documents/data/<game>/: listing it for the Save Manager, and moving it in
//  and out of the app as a ZIP archive or as single files.
//
//  The runtime owns the directory contents; the app only reads it, exports it,
//  and (while no game is running) replaces or removes files the user picked.
//  Instant save slots are separate: they live in Documents/states and are
//  handled by SaveStateSupport.
//

import Foundation

/// One file under a game's battery save-data directory.
struct BatterySaveFile: Identifiable, Equatable {
    /// Path relative to the game's data directory, e.g. "main" or "sdmc/...".
    let relativePath: String
    let bytes: UInt64
    let modified: Date?

    var id: String { relativePath }

    /// File name shown in the Save Manager row.
    var name: String { (relativePath as NSString).lastPathComponent }

    /// Parent folder inside the data directory, empty for a top-level file.
    var folder: String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
}

/// What one archive/file import wrote.
struct SaveDataImportSummary {
    var fileCount = 0
    var bytes: UInt64 = 0
    /// Entries that were skipped on purpose (macOS metadata).
    var skippedEntries = 0
}

/// Errors the Save Manager shows; the message is user-facing.
struct SaveDataError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Filesystem operations on the per-game battery save-data directory.
enum SaveDataStore {
    /// The largest archive or file the importer reads.
    static let maximumImportBytes: UInt64 = 512 * 1024 * 1024

    /// Directory name for a ROM: the `Documents/data/<name>` folder the runtime
    /// receives as its data directory, and the folder save states use under
    /// `Documents/states`. Sanitised so a ROM name cannot escape the directory.
    static func gameDirectoryName(for romName: String) -> String {
        let stem = (romName as NSString).deletingPathExtension
        let sanitized = stem.map { character -> Character in
            if character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." {
                return character
            }
            return "_"
        }
        return sanitized.isEmpty ? "rom" : String(sanitized)
    }

    /// `Documents/data/<game>` for `romName`.
    static func batterySaveDirectory(forROMName romName: String) -> URL {
        StorageInspector.dataURL.appendingPathComponent(
            gameDirectoryName(for: romName),
            isDirectory: true
        )
    }

    /// Every regular file under the game's data directory, newest first.
    static func batterySaveFiles(forROMName romName: String) -> [BatterySaveFile] {
        let directory = batterySaveDirectory(forROMName: romName)
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let basePath = directory.standardizedFileURL.path
        var files: [BatterySaveFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(basePath + "/") else { continue }
            let relativePath = String(path.dropFirst(basePath.count + 1))
            files.append(
                BatterySaveFile(
                    relativePath: relativePath,
                    bytes: UInt64(max(values.fileSize ?? 0, 0)),
                    modified: values.contentModificationDate
                )
            )
        }
        files.sort { lhs, rhs in
            (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast)
        }
        return files
    }

    /// Absolute URL of one row from `batterySaveFiles(forROMName:)`.
    static func batterySaveURL(for file: BatterySaveFile, forROMName romName: String) -> URL {
        batterySaveDirectory(forROMName: romName)
            .appendingPathComponent(file.relativePath, isDirectory: false)
    }

    /// Total size of a list of save files.
    static func totalBytes(of files: [BatterySaveFile]) -> UInt64 {
        files.reduce(0) { $0 + $1.bytes }
    }

    /// Removes one battery save file. The runtime must not have it open, so the
    /// Save Manager only offers this while no game is running.
    static func remove(_ file: BatterySaveFile, forROMName romName: String) throws {
        let directory = batterySaveDirectory(forROMName: romName)
        let url = directory.appendingPathComponent(file.relativePath, isDirectory: false)
        let basePath = directory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(basePath + "/") else {
            throw SaveDataError(message: "That file is not inside the game's save-data folder.")
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SaveDataError(
                message: "Could not delete “\(file.name)”: \(error.localizedDescription)"
            )
        }
        AppLog.log("[3ds2apple] save data: deleted %@", file.relativePath)
    }

    /// Packs the game's battery save data into a temporary ZIP archive and
    /// returns its URL, ready for the share sheet. The archive stores paths
    /// relative to the game's data directory, so importing it restores the same
    /// layout.
    static func exportArchive(forROMName romName: String) throws -> URL {
        let files = batterySaveFiles(forROMName: romName)
        guard !files.isEmpty else {
            throw SaveDataError(
                message: "There is no battery save data to export yet. Save in the game's own menu first."
            )
        }
        let directory = batterySaveDirectory(forROMName: romName)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = "\(gameDirectoryName(for: romName))-save-\(formatter.string(from: Date()))"
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName).zip", isDirectory: false)
        let writer: ZipArchiveWriter
        do {
            writer = try ZipArchiveWriter(url: archiveURL)
        } catch {
            throw SaveDataError(
                message: "Could not prepare the ZIP archive: \(error.localizedDescription)"
            )
        }
        do {
            for file in files {
                let fileURL = directory.appendingPathComponent(file.relativePath, isDirectory: false)
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                try writer.addFile(name: file.relativePath, contents: data)
            }
            try writer.close()
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            if let zipError = error as? ZipArchiveError {
                throw SaveDataError(message: zipError.message)
            }
            throw SaveDataError(
                message: "Could not export the battery save data: \(error.localizedDescription)"
            )
        }
        AppLog.log("[3ds2apple] save data: exported %d files to %@", files.count, archiveURL.lastPathComponent)
        return archiveURL
    }

    /// Imports a battery save backup: a ZIP archive (the app's own export, or a
    /// folder compressed elsewhere) or a single save file. Files are merged into
    /// the game's data directory; existing files are replaced only once the new
    /// contents are complete.
    ///
    /// The runtime must not be running when this is called: it may hold save
    /// files open, and replacing them underneath it could corrupt a save.
    static func importSaveData(from source: URL, forROMName romName: String) throws -> SaveDataImportSummary {
        let directory = batterySaveDirectory(forROMName: romName)
        let fileManager = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
        let attributes = try? fileManager.attributesOfItem(atPath: source.path)
        let size = UInt64((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        guard size > 0 else {
            throw SaveDataError(message: "The selected file is empty.")
        }
        guard size <= maximumImportBytes else {
            throw SaveDataError(message: "The selected file is too large to import.")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SaveDataError(
                message: "Could not create the game's save-data folder: \(error.localizedDescription)"
            )
        }

        if isZipArchive(source) {
            let summary: ZipExtractionSummary
            do {
                summary = try ZipArchiveReader.extract(
                    from: source,
                    into: directory,
                    strippingWrapperNamed: gameDirectoryName(for: romName)
                )
            } catch let zipError as ZipArchiveError {
                throw SaveDataError(message: zipError.message)
            } catch {
                throw SaveDataError(
                    message: "Could not import the archive: \(error.localizedDescription)"
                )
            }
            AppLog.log("[3ds2apple] save data: imported %d files from %@", summary.fileCount, source.lastPathComponent)
            return SaveDataImportSummary(
                fileCount: summary.fileCount,
                bytes: summary.bytes,
                skippedEntries: summary.skippedEntries
            )
        }

        // A single save file: keep its name and copy it in next to the others.
        guard let name = sanitizedImportFileName(source.lastPathComponent) else {
            throw SaveDataError(
                message: "“\(source.lastPathComponent)” is not a save file this app can import."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: source, options: [.mappedIfSafe])
        } catch {
            throw SaveDataError(
                message: "Could not read “\(source.lastPathComponent)”: \(error.localizedDescription)"
            )
        }
        guard UInt64(data.count) <= maximumImportBytes else {
            throw SaveDataError(message: "The selected file is too large to import.")
        }
        do {
            try AtomicFileWriter.write(data, to: directory.appendingPathComponent(name, isDirectory: false))
        } catch {
            throw SaveDataError(
                message: "Could not import “\(name)”: \(error.localizedDescription)"
            )
        }
        AppLog.log("[3ds2apple] save data: imported %@", name)
        return SaveDataImportSummary(fileCount: 1, bytes: UInt64(data.count), skippedEntries: 0)
    }

    // MARK: - Private

    private static func isZipArchive(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        // Local file header, or an empty archive's end record.
        return magic == Data([0x50, 0x4B, 0x03, 0x04])
            || magic == Data([0x50, 0x4B, 0x05, 0x06])
    }

    private static func sanitizedImportFileName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.hasPrefix("__MACOSX") else {
            return nil
        }
        return trimmed
    }
}
