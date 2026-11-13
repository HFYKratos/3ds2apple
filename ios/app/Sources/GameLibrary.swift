//
//  GameLibrary.swift
//  3ds2apple
//
//  The persisted game library: one GameEntry per ROM copied into Documents/roms.
//  The home page shows them as a grid; tapping a card starts that game through
//  ROMSession. The library never touches the runtime: it owns the ROM files in
//  the app container and the list that survives launches.
//
//  Storage:
//  - ROM files live in Documents/roms (the folder the single-ROM shell already
//    used, so old imports and their save folders keep working).
//  - The list is written atomically to Documents/Library/library.json.
//  - Save data and save states are named from the ROM file name
//    (SaveDataStore.gameDirectoryName), so the library keeps exactly one ROM
//    per sanitised file name: an import whose name would share another game's
//    save folder is renamed, and a re-import of a deleted copy goes back to the
//    old file name so the old saves are found again.
//  - When library.json does not exist yet (an app updated from the single-ROM
//    shell), every supported ROM already in Documents/roms is added: the title
//    is the file name and the header is read for the title id.
//
//  Importing (makeEntry(importing:)) runs off the main thread. It copies the
//  security-scoped file into Documents/roms under a collision-free name (an
//  identical file already there is reused instead of duplicated) and then reads
//  the ROM header:
//  - .3ds / .cci are NCSD images (or a plain NCCH): the NCSD partition table at
//    0x120 lists up to 8 partitions in 0x200-byte media units; the first NCCH
//    header's program id (NCCH + 0x118) is the title id and the product code
//    (NCCH + 0x150) its serial, e.g. "CTR-P-EK2A".
//  - .cia has no title id in its own header: the first NCCH content header is
//    located by its "NCCH" magic and parsed the same way.
//  A header that cannot be read is not an import failure: the entry is added
//  without a title id, so its card shows the file name and the interpreter badge.
//

import Combine
import Foundation

/// One imported game in the library.
struct GameEntry: Codable, Identifiable, Hashable {
    /// Stable identity of the row. Kept when the same game is imported again;
    /// the ROM file it points at can be replaced.
    let id: UUID
    /// Display title: the catalog's name when this build knows the game, else
    /// the file name without its extension.
    var title: String
    /// File name inside Documents/roms, e.g. "Pokemon Y.cci".
    var fileName: String
    /// Path relative to the app's Documents directory, e.g. "roms/Pokemon Y.cci".
    /// Persisted instead of an absolute path because the app container path
    /// changes between installs and updates.
    var relativePath: String
    /// 16 upper-case hex digits of the 3DS program id, nil when unreadable.
    var titleID: String?
    /// 3DS product code ("CTR-P-EK2A"), nil when unknown.
    var productCode: String?
    /// Optional cover image under Documents. Reserved: the current UI draws a
    /// placeholder, no cover is generated yet.
    var coverRelativePath: String?
    var importedAt: Date
    var lastPlayedAt: Date?
    var sizeBytes: Int64
}

/// An import/removal failure whose message is shown to the user as-is.
struct GameLibraryError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Title id / product code read from a ROM header.
struct ROMHeaderInfo {
    let titleID: String?
    let productCode: String?

    static let unknown = ROMHeaderInfo(titleID: nil, productCode: nil)
}

/// The app's game library, shared by the whole app.
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    /// ROM file types the importer accepts.
    static let supportedExtensions = ["3ds", "cci", "cia"]

    /// Every imported game, most recently played first, then by title.
    @Published private(set) var entries: [GameEntry] = []

    private let fileManager = FileManager.default

    private init() {
        load()
    }

    // MARK: - Paths

    static var documentsDirectory: URL { StorageInspector.documentsURL }

    static var romsDirectory: URL { StorageInspector.romsURL }

    /// Folder of library.json, kept out of the Files-visible ROM folder.
    static var libraryDirectory: URL {
        documentsDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    static var libraryFileURL: URL {
        libraryDirectory.appendingPathComponent("library.json", isDirectory: false)
    }

    /// Absolute URL of an entry's ROM file.
    static func fileURL(for entry: GameEntry) -> URL {
        documentsDirectory.appendingPathComponent(entry.relativePath, isDirectory: false)
    }

    /// Whether the importer accepts a file name.
    static func isSupportedROM(_ fileName: String) -> Bool {
        supportedExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    // MARK: - Queries

    func entry(id: UUID) -> GameEntry? {
        entries.first { $0.id == id }
    }

    /// Whether a game with this title id is already in the library.
    func contains(titleID: String) -> Bool {
        let normalized = titleID.uppercased()
        return entries.contains { $0.titleID == normalized }
    }

    /// The most recently played entry, nil before the first game was started.
    var mostRecentlyPlayed: GameEntry? {
        entries.first { $0.lastPlayedAt != nil }
    }

    // MARK: - Mutations (main queue)

    /// Adds or updates an entry. A row for the same file path, or for the same
    /// title id, is updated instead of duplicated.
    func add(_ entry: GameEntry) {
        if let index = entries.firstIndex(where: { $0.relativePath == entry.relativePath }) {
            var updated = entries[index]
            updated.title = entry.title
            updated.fileName = entry.fileName
            updated.titleID = entry.titleID
            updated.productCode = entry.productCode
            updated.sizeBytes = entry.sizeBytes
            entries[index] = updated
            resortAndPersist()
            return
        }

        if let titleID = entry.titleID,
           let index = entries.firstIndex(where: { $0.titleID == titleID }) {
            var updated = entries[index]
            updated.title = entry.title
            updated.titleID = titleID
            updated.productCode = entry.productCode ?? updated.productCode
            if fileManager.fileExists(atPath: Self.fileURL(for: updated).path) {
                // The library already points at a working copy of this game:
                // keep it (its save data and save states are named after that
                // file) and drop the duplicate copy the import just made.
                entries[index] = updated
                if entry.relativePath != updated.relativePath {
                    removeImportedCopy(entry)
                }
            } else {
                // The old copy is gone: move the new file back under the old
                // name when possible, so its save data and save states are
                // found again.
                let adopted = adoptOldFileName(entry, oldFileName: updated.fileName)
                updated.fileName = adopted.fileName
                updated.relativePath = adopted.relativePath
                updated.sizeBytes = adopted.sizeBytes
                entries[index] = updated
            }
            resortAndPersist()
            return
        }

        entries.append(avoidSaveDirectoryCollision(entry, excluding: nil))
        resortAndPersist()
    }

    /// Removes the row and the ROM copy it owns. Save data and save states stay
    /// on the device; the Save Manager deletes those.
    func remove(id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        let documentsPath = Self.documentsDirectory.standardizedFileURL.path
        for relativePath in [entry.relativePath, entry.coverRelativePath].compactMap({ $0 }) {
            let url = Self.documentsDirectory
                .appendingPathComponent(relativePath, isDirectory: false)
                .standardizedFileURL
            guard url.path.hasPrefix(documentsPath + "/") else { continue }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw GameLibraryError(
                    message: L10n.format(
                        "Could not delete “%@”: %@",
                        entry.title,
                        error.localizedDescription
                    )
                )
            }
        }
        entries.remove(at: index)
        persist()
        AppLog.log("[3ds2apple] library: removed %@", entry.fileName)
    }

    /// Marks the entry as just played and re-sorts the library.
    func markPlayed(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastPlayedAt = Date()
        resortAndPersist()
    }

    // MARK: - Import

    /// Copies the picked file (security-scoped, from Files) into Documents/roms,
    /// reads its header and returns the entry to add. Runs off the main thread
    /// (the copy of a multi-GB ROM must not block the UI) and throws a
    /// user-readable GameLibraryError on failure.
    static func makeEntry(importing url: URL) throws -> GameEntry {
        let fileName = url.lastPathComponent
        guard isSupportedROM(fileName) else {
            throw GameLibraryError(message: L10n.format(
                "Unsupported file “%@”. Choose a decrypted .3ds, .cci or .cia ROM.",
                fileName
            ))
        }
        let fileManager = FileManager.default

        // Files picked in Files/iCloud Drive are security-scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        let sourceAttributes = try? fileManager.attributesOfItem(atPath: url.path)
        let sourceSize = (sourceAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceSize > 0 else {
            throw GameLibraryError(message: L10n.format("“%@” is empty.", fileName))
        }

        do {
            try fileManager.createDirectory(at: romsDirectory, withIntermediateDirectories: true)
        } catch {
            throw GameLibraryError(
                message: L10n.format("Could not create Documents/roms: %@", error.localizedDescription)
            )
        }

        let destination = destinationURL(forFileName: fileName, sourceSize: sourceSize)
        if destination.reused {
            AppLog.log("[3ds2apple] reusing imported ROM: %@", destination.url.lastPathComponent)
        } else {
            // Copy through a temporary file so an interrupted import cannot leave
            // a truncated ROM behind under the final name.
            let temporary = romsDirectory.appendingPathComponent(
                ".incoming-\(UUID().uuidString).tmp",
                isDirectory: false
            )
            do {
                try fileManager.copyItem(at: url, to: temporary)
                try fileManager.moveItem(at: temporary, to: destination.url)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw GameLibraryError(message: L10n.format(
                    "Could not store “%@” in Documents: %@",
                    fileName,
                    error.localizedDescription
                ))
            }
            AppLog.log("[3ds2apple] imported ROM: %@", destination.url.lastPathComponent)
        }

        let header = parseROMHeader(at: destination.url)
        let values = try? destination.url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values?.fileSize ?? Int(sourceSize))
        return GameEntry(
            id: UUID(),
            title: preferredTitle(forFileName: destination.url.lastPathComponent, titleID: header.titleID),
            fileName: destination.url.lastPathComponent,
            relativePath: relativePath(of: destination.url),
            titleID: header.titleID,
            productCode: header.productCode,
            coverRelativePath: nil,
            importedAt: Date(),
            lastPlayedAt: nil,
            sizeBytes: size
        )
    }

    /// A collision-free destination for an imported file. An existing file with
    /// the same name and the same size is reused (importing the same ROM twice
    /// does not duplicate it); otherwise a numbered name is picked.
    private static func destinationURL(
        forFileName fileName: String,
        sourceSize: Int64
    ) -> (url: URL, reused: Bool) {
        let fileManager = FileManager.default
        let stem = (fileName as NSString).deletingPathExtension
        let pathExtension = (fileName as NSString).pathExtension
        var index = 1
        while index < 1000 {
            let candidateName: String
            if index == 1 {
                candidateName = fileName
            } else if pathExtension.isEmpty {
                candidateName = "\(stem)-\(index)"
            } else {
                candidateName = "\(stem)-\(index).\(pathExtension)"
            }
            let candidate = romsDirectory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return (candidate, false)
            }
            let existingSize = ((try? fileManager.attributesOfItem(atPath: candidate.path))?[.size]
                as? NSNumber)?.int64Value ?? -1
            if existingSize == sourceSize {
                return (candidate, true)
            }
            index += 1
        }
        let unique = romsDirectory.appendingPathComponent(
            "\(stem)-\(UUID().uuidString).\(pathExtension)",
            isDirectory: false
        )
        return (unique, false)
    }

    /// Deletes a freshly copied duplicate of a game the library already has.
    /// Only files inside Documents/roms are touched.
    private func removeImportedCopy(_ entry: GameEntry) {
        let url = Self.fileURL(for: entry).standardizedFileURL
        let romsPath = Self.romsDirectory.standardizedFileURL.path
        guard url.path.hasPrefix(romsPath + "/"),
              fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
            AppLog.log("[3ds2apple] library: removed duplicate import %@", entry.fileName)
        } catch {
            AppLog.log(
                "[3ds2apple] library: could not remove duplicate import %@: %@",
                entry.fileName,
                error.localizedDescription
            )
        }
    }

    /// Move a re-imported game's file back to the file name the library already
    /// knows, when that name is free. The runtime names the save-data and
    /// save-state folders after the ROM file, so this keeps the old saves
    /// reachable after the user deletes the ROM and imports it again.
    private func adoptOldFileName(_ entry: GameEntry, oldFileName: String) -> GameEntry {
        let destination = Self.romsDirectory.appendingPathComponent(oldFileName, isDirectory: false)
        guard !fileManager.fileExists(atPath: destination.path) else { return entry }
        let source = Self.fileURL(for: entry).standardizedFileURL
        let romsPath = Self.romsDirectory.standardizedFileURL.path
        guard source.path.hasPrefix(romsPath + "/") else { return entry }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            AppLog.log(
                "[3ds2apple] library: could not restore the old file name %@: %@",
                oldFileName,
                error.localizedDescription
            )
            return entry
        }
        var adopted = entry
        adopted.fileName = oldFileName
        adopted.relativePath = Self.relativePath(of: destination)
        AppLog.log("[3ds2apple] library: restored the old file name %@", oldFileName)
        return adopted
    }

    /// Keep one save-data / save-state folder per ROM.
    ///
    /// Save data and save states live under a directory named from the ROM file
    /// name (SaveDataStore.gameDirectoryName). Two different ROMs whose names
    /// sanitise to the same folder ("Pokemon Y.cci" and "Pokemon-Y.cci" both
    /// become "Pokemon_Y") would share saves, so the incoming copy is renamed to
    /// a free, distinguishable file name. The rename happens inside
    /// Documents/roms and is a no-op when there is no collision.
    private func avoidSaveDirectoryCollision(_ entry: GameEntry, excluding excludedID: UUID?) -> GameEntry {
        let key = SaveDataStore.gameDirectoryName(for: entry.fileName)
        let collides = entries.contains { item in
            item.id != entry.id
                && item.id != excludedID
                && SaveDataStore.gameDirectoryName(for: item.fileName) == key
        }
        guard collides else { return entry }
        let reserved = Set(
            entries
                .filter { $0.id != excludedID }
                .map { SaveDataStore.gameDirectoryName(for: $0.fileName) }
        )
        guard let replacement = Self.collidingNameReplacement(for: entry.fileName, reserved: reserved) else {
            return entry
        }
        let source = Self.fileURL(for: entry).standardizedFileURL
        let romsPath = Self.romsDirectory.standardizedFileURL.path
        guard source.path.hasPrefix(romsPath + "/") else { return entry }
        let destination = Self.romsDirectory.appendingPathComponent(replacement, isDirectory: false)
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            AppLog.log(
                "[3ds2apple] library: could not rename %@ to keep its save folder separate: %@",
                entry.fileName,
                error.localizedDescription
            )
            return entry
        }
        var renamed = entry
        renamed.fileName = replacement
        renamed.relativePath = Self.relativePath(of: destination)
        AppLog.log(
            "[3ds2apple] library: renamed %@ to %@ to keep its save folder separate",
            entry.fileName,
            replacement
        )
        return renamed
    }

    /// A file name whose sanitised save-directory name is not in `reserved` and
    /// that does not exist under Documents/roms, or nil when none can be made.
    private static func collidingNameReplacement(
        for fileName: String,
        reserved: Set<String>
    ) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        let pathExtension = (fileName as NSString).pathExtension
        let fileManager = FileManager.default
        var index = 2
        while index < 1000 {
            let candidate = pathExtension.isEmpty
                ? "\(stem)-\(index)"
                : "\(stem)-\(index).\(pathExtension)"
            if !reserved.contains(SaveDataStore.gameDirectoryName(for: candidate)),
               !fileManager.fileExists(atPath: romsDirectory.appendingPathComponent(candidate).path) {
                return candidate
            }
            index += 1
        }
        return nil
    }

    /// Display title of an imported file: the catalog name when this build knows
    /// the game, otherwise the file name without its extension.
    private static func preferredTitle(forFileName fileName: String, titleID: String?) -> String {
        if let titleID,
           let game = GameCatalog.bundled.linkedGame(titleID: titleID),
           !game.displayName.isEmpty {
            return game.displayName
        }
        return title(fromFileName: fileName)
    }

    // MARK: - ROM header parsing

    /// Title id / product code of the file, both nil when the header is
    /// unreadable (or the content is encrypted). Importing never fails because
    /// of this.
    static func parseROMHeader(at url: URL) -> ROMHeaderInfo {
        switch (url.pathExtension.lowercased()) {
        case "3ds", "cci":
            return parseNCSDHeader(at: url)
        case "cia":
            return parseCIAHeader(at: url)
        default:
            return .unknown
        }
    }

    /// NCSD (cartridge image): partition table at 0x120, first NCCH partition's
    /// header is parsed. A raw NCCH file is parsed directly.
    private static func parseNCSDHeader(at url: URL) -> ROMHeaderInfo {
        guard let header = readData(at: url, offset: 0, length: 0x200),
              header.count == 0x200 else {
            return .unknown
        }
        if header[0x100..<0x104] == Data("NCCH".utf8) {
            return parseNCCHHeader(header) ?? .unknown
        }
        guard header[0x100..<0x104] == Data("NCSD".utf8) else { return .unknown }

        // Partition table: 8 entries of (offset, size), both in 0x200-byte units.
        var offsets: [UInt64] = []
        for index in 0..<8 {
            let units = readUInt32LE(header, offset: 0x120 + index * 8)
            if units > 0 {
                offsets.append(UInt64(units) * 0x200)
            }
        }
        for partitionOffset in offsets {
            guard let ncch = readData(at: url, offset: partitionOffset, length: 0x200),
                  ncch.count == 0x200 else { continue }
            if let info = parseNCCHHeader(ncch) {
                return info
            }
        }
        return .unknown
    }

    /// CIA: the archive header has no title id, so locate the first NCCH content
    /// header (its "NCCH" magic at +0x100) in the leading part of the file. The
    /// section offsets depend on the tool that produced the CIA, but the content
    /// header itself carries the program id and product code.
    private static func parseCIAHeader(at url: URL) -> ROMHeaderInfo {
        guard let head = readData(at: url, offset: 0, length: 0x40000),
              head.count >= 0x200 else {
            return .unknown
        }
        let magic = Data("NCCH".utf8)
        var searchRange = head.startIndex..<head.endIndex
        while let range = head.range(of: magic, in: searchRange) {
            let headerStart = head.distance(from: head.startIndex, to: range.lowerBound) - 0x100
            if headerStart >= 0, headerStart + 0x200 <= head.count {
                let ncch = head.subdata(in: headerStart..<(headerStart + 0x200))
                if let info = parseNCCHHeader(ncch) {
                    return info
                }
            }
            searchRange = head.index(after: range.lowerBound)..<head.endIndex
        }
        return .unknown
    }

    /// One NCCH header: program id at +0x118, product code at +0x150.
    private static func parseNCCHHeader(_ header: Data) -> ROMHeaderInfo? {
        guard header.count >= 0x160 else { return nil }
        guard header[0x100..<0x104] == Data("NCCH".utf8) else { return nil }
        let programID = readUInt64LE(header, offset: 0x118)
        guard isPlausibleProgramID(programID) else { return nil }
        return ROMHeaderInfo(
            titleID: String(format: "%016llX", programID),
            productCode: productCode(in: header, offset: 0x150)
        )
    }

    /// 3DS title ids start with 0x0004; this rejects a stray "NCCH" match in a
    /// non-header region.
    private static func isPlausibleProgramID(_ programID: UInt64) -> Bool {
        programID != 0 && (programID >> 48) == 0x0004
    }

    /// 16-byte ASCII product code, up to the first NUL.
    private static func productCode(in header: Data, offset: Int) -> String? {
        guard header.count >= offset + 0x10 else { return nil }
        var bytes: [UInt8] = []
        for index in offset..<(offset + 0x10) {
            let byte = header[index]
            if byte == 0 { break }
            guard byte >= 0x20, byte < 0x7F else { return nil }
            bytes.append(byte)
        }
        guard !bytes.isEmpty, let code = String(bytes: bytes, encoding: .ascii) else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readData(at url: URL, offset: UInt64, length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            return nil
        }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, data.count >= offset + 4 else { return 0 }
        var value: UInt32 = 0
        for byte in 0..<4 {
            value |= UInt32(data[offset + byte]) << (8 * UInt32(byte))
        }
        return value
    }

    private static func readUInt64LE(_ data: Data, offset: Int) -> UInt64 {
        guard offset >= 0, data.count >= offset + 8 else { return 0 }
        var value: UInt64 = 0
        for byte in 0..<8 {
            value |= UInt64(data[offset + byte]) << (8 * UInt64(byte))
        }
        return value
    }

    // MARK: - Naming

    /// Display title of a file name: "Pokemon Y.cci" -> "Pokemon Y".
    static func title(fromFileName fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fileName : trimmed
    }

    /// Path relative to the app's Documents directory.
    static func relativePath(of url: URL) -> String {
        let documentsPath = documentsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(documentsPath + "/") {
            return String(path.dropFirst(documentsPath.count + 1))
        }
        return url.lastPathComponent
    }

    // MARK: - Persistence

    private func resortAndPersist() {
        sortEntries()
        persist()
    }

    private func sortEntries() {
        entries.sort { lhs, rhs in
            let left = lhs.lastPlayedAt ?? .distantPast
            let right = rhs.lastPlayedAt ?? .distantPast
            if left != right { return left > right }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order == .orderedSame {
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
            return order == .orderedAscending
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try AtomicFileWriter.write(data, to: Self.libraryFileURL)
        } catch {
            AppLog.log(
                "[3ds2apple] library: could not save library.json: %@",
                error.localizedDescription
            )
        }
    }

    private func load() {
        let url = Self.libraryFileURL
        if fileManager.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                entries = try decoder.decode([GameEntry].self, from: data)
                sortEntries()
                AppLog.log("[3ds2apple] library: loaded %ld game(s)", entries.count)
                return
            } catch {
                AppLog.log(
                    "[3ds2apple] library: could not read library.json: %@",
                    error.localizedDescription
                )
                // Keep the unreadable file out of the way (it may come from a
                // newer build) and rebuild the list from the ROMs on disk.
                let backup = Self.libraryFileURL.deletingLastPathComponent()
                    .appendingPathComponent("library.unreadable.json", isDirectory: false)
                try? fileManager.removeItem(at: backup)
                try? fileManager.moveItem(at: url, to: backup)
            }
        }
        entries = Self.migrateLegacyROMs()
        sortEntries()
        if !entries.isEmpty {
            AppLog.log("[3ds2apple] library: migrated %ld ROM(s) from Documents/roms", entries.count)
            persist()
        }
    }

    /// Every supported ROM already in Documents/roms, as library entries (used
    /// when the app is updated from the single-ROM shell).
    private static func migrateLegacyROMs() -> [GameEntry] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: romsDirectory.path)) ?? []
        var migrated: [GameEntry] = []
        var usedSaveKeys: Set<String> = []
        for name in names.sorted() {
            guard !name.hasPrefix("."), isSupportedROM(name) else { continue }
            var fileName = name
            var url = romsDirectory.appendingPathComponent(fileName, isDirectory: false)
            var saveKey = SaveDataStore.gameDirectoryName(for: fileName)
            // One save-data folder per ROM: rename a legacy ROM whose name
            // sanitises to a folder an earlier ROM already uses.
            if usedSaveKeys.contains(saveKey),
               let replacement = collidingNameReplacement(for: fileName, reserved: usedSaveKeys) {
                let destination = romsDirectory.appendingPathComponent(replacement, isDirectory: false)
                do {
                    try fileManager.moveItem(at: url, to: destination)
                    AppLog.log(
                        "[3ds2apple] library: renamed legacy ROM %@ to %@ to keep its save folder separate",
                        fileName,
                        replacement
                    )
                    fileName = replacement
                    url = destination
                    saveKey = SaveDataStore.gameDirectoryName(for: replacement)
                } catch {
                    AppLog.log(
                        "[3ds2apple] library: could not rename legacy ROM %@: %@",
                        fileName,
                        error.localizedDescription
                    )
                }
            }
            usedSaveKeys.insert(saveKey)
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            guard size > 0 else { continue }
            let header = parseROMHeader(at: url)
            migrated.append(GameEntry(
                id: UUID(),
                title: title(fromFileName: fileName),
                fileName: fileName,
                relativePath: relativePath(of: url),
                titleID: header.titleID,
                productCode: header.productCode,
                coverRelativePath: nil,
                importedAt: values?.creationDate ?? values?.contentModificationDate ?? Date(),
                lastPlayedAt: nil,
                sizeBytes: size
            ))
        }
        return migrated
    }
}
