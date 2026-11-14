//
//  InstalledGame.swift
//  3ds2apple
//
//  The on-device half of the launcher-first model. The app's AOT code (the
//  per-game GamePack dylibs) is part of the signed IPA and listed in the
//  bundle's GameCatalog.json — iOS will not dlopen an unsigned dylib copied
//  into Documents, so packs cannot be pushed. What the desktop launcher pushes
//  after installing the build is the game data:
//
//    Documents/Games/<TITLEID>/GameInfo.json   launcher manifest
//    Documents/Games/<TITLEID>/GameRom.cci     the user's decrypted game data
//    Documents/Games/<TITLEID>/cover.png       optional
//
//  This file scans that folder and validates what the launcher pushed:
//
//  1. scan() reads GameInfo.json and checks the cheap facts: the folder name is
//     a title ID, the manifest parses and names the same title, and the game
//     data exists as a non-empty regular file inside the game folder with the
//     recorded size.
//  2. verifyHashes() streams the game data through SHA-256 in the background
//     when the manifest recorded a hash. Until that finishes the card says
//     "Checking"; the launch path waits for the result and refuses a mismatch.
//     Hashing a 1.4 GB ROM would block the UI, hence the split.
//
//  A catalog game with no Documents data shows "Data missing" (the launcher
//  rebuild/reinstall carries the AOT pack; the ROM push is the second step).
//

import CryptoKit
import Foundation

/// One reason a pushed game's data cannot be used. Shown on the library card
/// and in the launch notice.
enum GameValidationIssue: Hashable {
    /// The game folder's name is not a 16 hex digit title ID.
    case invalidFolderName(String)
    /// GameInfo.json is not in the game folder.
    case manifestMissing(String)
    /// GameInfo.json could not be read or is not valid JSON.
    case manifestUnreadable(String)
    /// The manifest schema is newer than this shell understands.
    case unsupportedSchema(version: Int, supported: Int)
    /// The manifest's title ID disagrees with the folder name.
    case titleIDMismatch(declared: String, folder: String)
    /// A path in GameInfo.json escapes the game folder.
    case unsafeFilePath(String)
    /// A recorded SHA-256 is not 64 hex digits.
    case invalidDeclaredHash(String)
    case romMissing(String)
    case romEmpty(String)
    case romNotAFile(String)
    case romSizeMismatch(expected: UInt64, actual: UInt64)
    case romHashMismatch(expected: String, actual: String)
    /// The game data could not be read while hashing it.
    case hashUnreadable(String, String)
    /// The launcher has not pushed this catalog game's data yet.
    case gameDataMissing(String)
    /// The game folder disappeared between scans.
    case folderMissing(String)

    /// One localized sentence the UI can show.
    var localizedMessage: String {
        switch self {
        case .invalidFolderName(let folder):
            return L10n.format(
                "“%@” is not named after a 16-digit title ID. The launcher must create one folder per game named <TITLEID>.",
                folder)
        case .manifestMissing(let file):
            return L10n.format(
                "“%@” is missing from this game's data folder. Push the game data with the desktop launcher.", file)
        case .manifestUnreadable(let detail):
            return L10n.format("GameInfo.json could not be read: %@", detail)
        case .unsupportedSchema(let version, let supported):
            return L10n.format(
                "GameInfo.json uses schema version %ld, but this app understands version %ld. Update the app.",
                version, supported)
        case .titleIDMismatch(let declared, let folder):
            return L10n.format(
                "GameInfo.json says this game is %@, but its folder is named %@. Push the game data again with the launcher.",
                declared, folder)
        case .unsafeFilePath(let path):
            return L10n.format(
                "The path “%@” in GameInfo.json points outside the game's data folder. Push the game data again with the launcher.",
                path)
        case .invalidDeclaredHash(let file):
            return L10n.format(
                "GameInfo.json records an invalid SHA-256 for “%@”. Push the game data again with the launcher.", file)
        case .romMissing(let file):
            return L10n.format(
                "The game data “%@” has not been pushed into this app yet. Push the game data with the desktop launcher.", file)
        case .romEmpty(let file):
            return L10n.format("The game data “%@” is empty. Push the game data again with the desktop launcher.", file)
        case .romNotAFile(let file):
            return L10n.format("“%@” is not a file, so the game cannot be loaded.", file)
        case .romSizeMismatch(let expected, let actual):
            return L10n.format(
                "The game data is %ld bytes but GameInfo.json records %ld. Push the game data again with the launcher.",
                actual, expected)
        case .romHashMismatch(let expected, let actual):
            return L10n.format(
                "The game data's SHA-256 does not match the manifest (expected %@, got %@). Push the game data again with the launcher.",
                expected, actual)
        case .hashUnreadable(let file, let detail):
            return L10n.format("Could not read “%@” to check it: %@", file, detail)
        case .gameDataMissing(let titleID):
            return L10n.format(
                "The game data of %@ has not been pushed yet. Install the build from the desktop launcher, then let it push the game's data.",
                titleID)
        case .folderMissing(let folder):
            return L10n.format(
                "The game data folder “%@” is no longer in Documents/Games. Refresh the library.", folder)
        }
    }
}

/// SHA-256 verification state of one pushed game's data.
enum GameValidationState: Hashable {
    /// The game data exists and (when recorded) its size and SHA-256 match.
    case valid
    /// The game data exists; the recorded SHA-256 is being verified.
    case checking
    /// The data cannot be used; the issues say why.
    case invalid([GameValidationIssue])

    var issues: [GameValidationIssue] {
        if case .invalid(let issues) = self { return issues }
        return []
    }

    var isValid: Bool { self == .valid }
}

/// One game's data found in Documents/Games.
struct InstalledGame: Hashable {
    /// 16 upper-case hex digits (the folder name when it is valid).
    let titleID: String
    /// The folder name exactly as it is on disk.
    let folderName: String
    /// Documents/Games/<folderName>.
    let directoryURL: URL
    /// Save-data / save-state folder name, defaults to the title ID.
    let saveNamespace: String
    /// The pushed game data, nil when missing or unsafe.
    let romURL: URL?
    let romBytes: UInt64
    let coverURL: URL?
    /// Size and hash the manifest recorded; nil when not recorded.
    let declaredROMSize: UInt64?
    let declaredROMSHA256: String?
    /// The decoded manifest, nil when it was missing or unreadable.
    let manifest: GameInfo?
    /// Scan issues plus the hash-check result.
    var validation: GameValidationState

    var issues: [GameValidationIssue] { validation.issues }
    var hasDeclaredHashes: Bool { declaredROMSHA256 != nil }
    var storageBytes: UInt64 { romBytes }
    var issueSummary: String { issues.map { $0.localizedMessage }.joined(separator: " ") }

    /// Stable key for the background-verification cache: any push that
    /// replaces the data (new path, size or recorded hash) gets a new key.
    var verificationFingerprint: String {
        [
            titleID, folderName, directoryURL.path, romURL?.path ?? "-",
            String(romBytes), declaredROMSHA256 ?? "-", declaredROMSize.map(String.init) ?? "-",
        ].joined(separator: "|")
    }
}

/// Scans and validates Documents/Games; the only code that reads that folder.
enum DocumentsGames {
    /// The folder under Documents the desktop launcher fills with game data.
    static let folderName = "Games"

    /// Documents/Games, or the `-gamesRoot` debug override (simulator fixtures).
    static var rootURL: URL { DebugLaunch.gamesRootOverride ?? StorageInspector.gamesURL }

    struct ScanResult {
        let games: [InstalledGame]
        /// Set when Documents/Games itself cannot be read.
        let directoryProblem: String?
    }

    /// Scans every subfolder of Documents/Games. Never throws: an unreadable
    /// game becomes an entry with an invalid state so the user sees why.
    static func scan() -> ScanResult {
        let fileManager = FileManager.default
        let root = rootURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            // A fresh install has no pushed game data yet: not an error. The
            // home page explains how the launcher fills it.
            return ScanResult(games: [], directoryProblem: nil)
        }
        guard isDirectory.boolValue else {
            return ScanResult(games: [], directoryProblem: L10n.format("“%@” is not a folder.", root.path))
        }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: root.path)
        } catch {
            return ScanResult(games: [], directoryProblem: error.localizedDescription)
        }
        var games: [InstalledGame] = []
        for name in names.sorted() {
            if name.hasPrefix(".") { continue }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &childIsDirectory),
                  childIsDirectory.boolValue else { continue }
            games.append(scanGame(folderName: name, directory: directory))
        }
        return ScanResult(games: games, directoryProblem: nil)
    }

    /// Streams one game's data through SHA-256 and compares it with the
    /// manifest. Runs on a background queue; calls completion on the main
    /// queue. Empty issues means the recorded hash matches (or none recorded).
    static func verifyHashes(of game: InstalledGame,
                            completion: @escaping ([GameValidationIssue]) -> Void) {
        guard game.hasDeclaredHashes, let expected = game.declaredROMSHA256, let url = game.romURL else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var issues: [GameValidationIssue] = []
            do {
                let actual = try sha256(of: url)
                if actual != expected {
                    issues.append(.romHashMismatch(expected: expected, actual: actual))
                }
            } catch {
                issues.append(.hashUnreadable(url.lastPathComponent, error.localizedDescription))
            }
            DispatchQueue.main.async { completion(issues) }
        }
    }

    // MARK: - Scanning

    private struct FileCheck {
        var url: URL?
        var bytes: UInt64 = 0
        var declaredSize: UInt64?
        var declaredSHA256: String?
        var issues: [GameValidationIssue] = []
    }

    private static func scanGame(folderName: String, directory: URL) -> InstalledGame {
        let fileManager = FileManager.default
        var issues: [GameValidationIssue] = []

        let normalizedFolder = GameCatalog.normalizedTitleID(folderName)
        if normalizedFolder == nil {
            issues.append(.invalidFolderName(folderName))
        }
        let titleID = normalizedFolder ?? folderName.uppercased()

        // --- GameInfo.json -------------------------------------------------
        let manifestURL = directory.appendingPathComponent(GameInfo.manifestFileName,
                                                          isDirectory: false)
        var manifest: GameInfo?
        if fileManager.fileExists(atPath: manifestURL.path) {
            do {
                manifest = try GameInfo.load(from: manifestURL)
            } catch {
                issues.append(.manifestUnreadable(error.localizedDescription))
            }
        } else {
            // The launcher writes GameInfo.json LAST, so a folder without one
            // is a partial/stale push: show it as an error, never as a game.
            issues.append(.manifestMissing(GameInfo.manifestFileName))
        }

        if let version = manifest?.schemaVersion, version > GameInfo.supportedSchemaVersion {
            issues.append(.unsupportedSchema(version: version,
                                             supported: GameInfo.supportedSchemaVersion))
        }
        if let declaredTitle = manifest?.titleID {
            if let normalizedDeclared = GameCatalog.normalizedTitleID(declaredTitle) {
                if let normalizedFolder, normalizedDeclared != normalizedFolder {
                    issues.append(.titleIDMismatch(declared: normalizedDeclared, folder: folderName))
                }
            } else {
                issues.append(.titleIDMismatch(declared: declaredTitle, folder: folderName))
            }
        }

        // --- game data (the only file the launcher pushes here) -------------
        let romRecording = manifest?.rom
        var romName = trimmed(romRecording?.file)
        if romName == nil {
            romName = GameInfo.defaultROMFileNames.first {
                fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
            } ?? GameInfo.defaultROMFileNames[0]
        }
        let rom = checkROM(romName ?? GameInfo.defaultROMFileNames[0],
                           recording: romRecording,
                           in: directory)
        issues.append(contentsOf: rom.issues)

        // --- cover (optional, display only) --------------------------------
        var coverURL: URL?
        if let coverName = trimmed(manifest?.cover), AOTPackageLoader.isValidRelativePath(coverName) {
            let base = directory.resolvingSymlinksInPath().standardizedFileURL
            let candidate = base.appendingPathComponent(coverName, isDirectory: false)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if candidate.path.hasPrefix(base.path + "/"),
               fileManager.fileExists(atPath: candidate.path) {
                coverURL = candidate
            }
        }

        // --- save namespace ------------------------------------------------
        let rawNamespace = trimmed(manifest?.saveNamespace) ?? titleID

        let declaredROMSize = rom.declaredSize
        let declaredROMSHA256 = rom.declaredSHA256
        let validation: GameValidationState
        if !issues.isEmpty {
            validation = .invalid(issues)
        } else if declaredROMSHA256 != nil {
            validation = .checking
        } else {
            validation = .valid
        }

        return InstalledGame(
            titleID: titleID,
            folderName: folderName,
            directoryURL: directory,
            saveNamespace: rawNamespace,
            romURL: rom.url,
            romBytes: rom.bytes,
            coverURL: coverURL,
            declaredROMSize: declaredROMSize,
            declaredROMSHA256: declaredROMSHA256,
            manifest: manifest,
            validation: validation
        )
    }

    /// Validates the pushed game data file and returns its facts.
    private static func checkROM(_ rawName: String,
                                 recording: GameFileInfo?,
                                 in directory: URL) -> FileCheck {
        var result = FileCheck()
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AOTPackageLoader.isValidRelativePath(name) else {
            result.issues.append(.unsafeFilePath(name))
            return result
        }
        let fileManager = FileManager.default
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(name, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // A symlink inside the game folder may point elsewhere on the device;
        // only files that resolve inside the game's own folder are trusted.
        guard url.path.hasPrefix(base.path + "/") else {
            result.issues.append(.unsafeFilePath(name))
            return result
        }
        guard fileManager.fileExists(atPath: url.path) else {
            result.issues.append(.romMissing(name))
            return result
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            result.issues.append(.romNotAFile(name))
            return result
        }
        let bytes = UInt64(max(values?.fileSize ?? 0, 0))
        result.url = url
        result.bytes = bytes
        if bytes == 0 {
            result.issues.append(.romEmpty(name))
            return result
        }
        if let declared = recording?.size {
            result.declaredSize = declared
            if declared != bytes {
                result.issues.append(.romSizeMismatch(expected: declared, actual: bytes))
            }
        }
        if let rawHash = trimmed(recording?.sha256) {
            if rawHash.count == 64, rawHash.allSatisfy({ $0.isHexDigit }) {
                result.declaredSHA256 = rawHash.lowercased()
            } else {
                result.issues.append(.invalidDeclaredHash(name))
            }
        }
        return result
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Hashing

    /// Lower-case hex SHA-256 of a file, streamed in 4 MiB blocks so a 1.4 GB
    /// game data file never sits in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
