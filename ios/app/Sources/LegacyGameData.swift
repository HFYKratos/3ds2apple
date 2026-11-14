//
//  LegacyGameData.swift
//  3ds2apple
//
//  Compatibility with the ROM library of the 0.1.x shell, used only by today's
//  statically linked single-game builds:
//
//  - the cartridge file a static build needs at runtime is still where the old
//    shell copied it (Documents/roms), and the old Documents/Library/library.json
//    maps its title id to that file;
//  - the runtime save data (Documents/data/<game>) and the instant save slots
//    (Documents/states/<game>) were named after the ROM file. The AOT-only shell
//    namespaces both by title id instead, so the old folders are renamed once
//    when such a build starts.
//
//  Nothing here is part of the catalog library: a build with game packages never
//  reads the old library. A build that has no legacy library.json and exactly
//  one cartridge in Documents/roms (the pre-library single-ROM shell) still gets
//  its cartridge found.
//

import Foundation

/// Read-only access to the 0.1.x ROM library, for the static-link fallback.
enum LegacyGameData {
    /// One record of the old Documents/Library/library.json (the fields the
    /// migration needs; unknown fields are ignored).
    struct LibraryEntry: Decodable {
        let title: String?
        let fileName: String?
        let relativePath: String?
        let titleID: String?
        let importedAt: Date?
        let lastPlayedAt: Date?
    }

    static var documentsURL: URL { StorageInspector.documentsURL }
    static var romsURL: URL { StorageInspector.romsURL }

    static var legacyLibraryURL: URL {
        documentsURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }

    /// The old library, decoded once at launch. Empty when the app never had
    /// one (a fresh AOT-first install) or when it cannot be read.
    static let legacyEntries: [LibraryEntry] = loadLegacyEntries()

    // MARK: - Play history

    /// Last-played times of the old library, keyed by title ID, so the new
    /// play history starts with the dates the user already saw.
    static func playTimes() -> [String: Date] {
        var times: [String: Date] = [:]
        for entry in legacyEntries {
            guard let titleID = GameCatalog.normalizedTitleID(entry.titleID),
                  let lastPlayed = entry.lastPlayedAt else { continue }
            times[titleID] = lastPlayed
        }
        return times
    }

    // MARK: - Cartridge lookup

    /// The cartridge file a statically linked title loads at runtime, or nil
    /// when this install has no data for it.
    static func cartridgeURL(forTitleID titleID: String) -> URL? {
        guard let normalized = GameCatalog.normalizedTitleID(titleID) else { return nil }
        let fileManager = FileManager.default

        for entry in legacyEntries where GameCatalog.normalizedTitleID(entry.titleID) == normalized {
            guard let relativePath = entry.relativePath, !relativePath.isEmpty else { continue }
            let url = documentsURL
                .appendingPathComponent(relativePath, isDirectory: false)
                .standardizedFileURL
            guard url.path.hasPrefix(documentsURL.standardizedFileURL.path + "/") else { continue }
            if fileManager.fileExists(atPath: url.path) {
                AppLog.log("[3ds2apple] legacy cartridge for %@: %@", normalized, relativePath)
                return url
            }
        }

        // No legacy library (the pre-library single-ROM shell): only accept an
        // unambiguous cartridge so the wrong game can never be started.
        let candidates = romFiles()
        if candidates.count == 1 {
            AppLog.log(
                "[3ds2apple] legacy cartridge for %@: %@ (only cartridge in Documents/roms)",
                normalized,
                candidates[0].lastPathComponent
            )
            return candidates[0]
        }
        if candidates.count > 1 {
            AppLog.log(
                "[3ds2apple] legacy cartridge lookup for %@: %ld cartridges in Documents/roms and no library.json to choose from",
                normalized,
                candidates.count
            )
        }
        return nil
    }

    // MARK: - Save namespaces

    /// Renames the runtime save data and instant save slots of a ROM-named
    /// install to the title-id namespace the AOT-only shell uses. A no-op when
    /// the old folder does not exist or the new one already does.
    static func migrateSaveDirectories(titleID: String, legacyFileName: String) {
        guard let normalized = GameCatalog.normalizedTitleID(titleID) else { return }
        let legacyName = directoryName(forROMFileName: legacyFileName)
        guard !legacyName.isEmpty, legacyName != normalized else { return }
        let fileManager = FileManager.default

        for rootName in ["data", "states"] {
            let root = documentsURL.appendingPathComponent(rootName, isDirectory: true)
            let old = root.appendingPathComponent(legacyName, isDirectory: true)
            let new = root.appendingPathComponent(normalized, isDirectory: true)
            guard fileManager.fileExists(atPath: old.path) else { continue }
            if fileManager.fileExists(atPath: new.path) {
                AppLog.log(
                    "[3ds2apple] save data: both %@/%@ and %@/%@ exist; keeping the title-id folder",
                    rootName,
                    legacyName,
                    rootName,
                    normalized
                )
                continue
            }
            do {
                try fileManager.moveItem(at: old, to: new)
                AppLog.log(
                    "[3ds2apple] save data: moved %@/%@ to the title-id namespace %@",
                    rootName,
                    legacyName,
                    normalized
                )
            } catch {
                AppLog.log(
                    "[3ds2apple] save data: could not rename %@/%@: %@",
                    rootName,
                    legacyName,
                    error.localizedDescription
                )
            }
        }
    }

    /// The folder name the 0.1.x shell derived from a ROM file name. Kept in
    /// sync with the old SaveDataStore.gameDirectoryName(for:) sanitiser.
    static func directoryName(forROMFileName fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let sanitized = stem.map { character -> Character in
            if character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." {
                return character
            }
            return "_"
        }
        return sanitized.isEmpty ? "rom" : String(sanitized)
    }

    // MARK: - Private

    private static func loadLegacyEntries() -> [LibraryEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyLibraryURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: legacyLibraryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let entries = try decoder.decode([LibraryEntry].self, from: data)
            AppLog.log("[3ds2apple] legacy library: %ld record(s) from the 0.1.x shell", entries.count)
            return entries
        } catch {
            AppLog.log(
                "[3ds2apple] legacy library: could not read library.json: %@",
                error.localizedDescription
            )
            return []
        }
    }

    /// Supported ROM files currently in Documents/roms, sorted by name.
    private static func romFiles() -> [URL] {
        let extensions: Set<String> = ["3ds", "cci", "cia"]
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: romsURL.path) else {
            return []
        }
        var files: [URL] = []
        for name in names.sorted() {
            guard !name.hasPrefix("."),
                  extensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let url = romsURL.appendingPathComponent(name, isDirectory: false)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else { continue }
            files.append(url)
        }
        return files
    }
}
