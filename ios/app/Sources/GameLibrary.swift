//
//  GameLibrary.swift
//  3ds2apple
//
//  The app's game library: a read-only view of the build-time GameCatalog plus
//  the local play history.
//
//  The shell never imports, copies or scans game files any more. The library
//  has exactly the games the desktop build put into GameCatalog.json; the only
//  thing that changes on the device is when each game was last played:
//
//  - Documents/Library/playHistory.json keeps title id -> last played time
//    across launches (written atomically, never keyed by file name);
//  - an app updated from the 0.1.x ROM library seeds that history from the old
//    library.json the first time it runs (LegacyGameData).
//
//  The catalog entry itself (AOT package path, aot flags, ...) comes from
//  GameCatalog.swift. Starting a game and the "No AOT build" refusal live in
//  ROMSession and AOTPackageLoader.
//

import Combine
import Foundation

/// One game on the home page: one entry of the build-time GameCatalog.
struct GameEntry: Identifiable, Hashable {
    /// 16 upper-case hex digits of the 3DS program id.
    let titleID: String
    /// Name shown on the library card.
    let title: String
    /// 3DS product code ("CTR-P-EK2A"), nil when the build did not record it.
    let productCode: String?
    /// Whether the desktop build allocated AOT code for this game.
    let aot: Bool
    /// Version of the AOT artifact (informational).
    let aotVersion: Int?
    /// Bundle-relative AOT package dylib, nil for a statically linked build.
    let packFile: String?
    /// Bundle-relative game data (the packaged ROM), nil when not bundled.
    let romFile: String?
    /// GamePack ABI version recorded by the desktop build (informational).
    let packABIVersion: Int?
    /// Optional registration symbol override for the GamePack loader.
    let registrationSymbol: String?
    /// Optional bundle-relative cover image.
    let coverFile: String?
    /// Free-form note from the desktop build.
    let notes: String?
    /// When this game was last started on this device, nil for never.
    var lastPlayedAt: Date?

    var id: String { titleID }

    init(game: GameCatalogGame, lastPlayedAt: Date?) {
        titleID = game.titleID
        title = game.displayName
        productCode = game.productCode
        aot = game.aot
        aotVersion = game.aotVersion
        packFile = game.packFile
        romFile = game.romFile
        packABIVersion = game.packABIVersion
        registrationSymbol = game.registrationSymbol
        coverFile = game.coverFile
        notes = game.notes
        self.lastPlayedAt = lastPlayedAt
    }

    /// UI preview only (ios/preview/SnapshotRenderer.swift): an entry without a
    /// generated catalog file. The shipping app builds entries from the catalog.
    init(titleID: String,
         title: String,
         aot: Bool,
         packFile: String? = nil,
         romFile: String? = nil,
         lastPlayedAt: Date? = nil) {
        self.titleID = titleID.uppercased()
        self.title = title
        productCode = nil
        self.aot = aot
        aotVersion = aot ? 1 : nil
        self.packFile = packFile
        self.romFile = romFile
        packABIVersion = packFile == nil ? nil : 1
        registrationSymbol = nil
        coverFile = nil
        notes = nil
        self.lastPlayedAt = lastPlayedAt
    }
}

/// Documents/Library/playHistory.json: the only library state the device keeps.
struct PlayHistory: Codable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    /// Last-played time per title ID (ISO 8601 on disk).
    var lastPlayed: [String: Date]

    init(schemaVersion: Int = PlayHistory.supportedSchemaVersion,
         lastPlayed: [String: Date] = [:]) {
        self.schemaVersion = schemaVersion
        self.lastPlayed = lastPlayed
    }
}

/// The app's game library, shared by the whole app.
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    /// Every game in this build, most recently played first, then by title.
    @Published private(set) var entries: [GameEntry] = []

    private var history = PlayHistory()
    private let fileManager = FileManager.default

    private init() {
        load()
    }

    // MARK: - Paths

    static var documentsDirectory: URL { StorageInspector.documentsURL }

    /// Folder of playHistory.json, kept out of the Files-visible folders.
    static var libraryDirectory: URL {
        documentsDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    static var playHistoryURL: URL {
        libraryDirectory.appendingPathComponent("playHistory.json", isDirectory: false)
    }

    // MARK: - Queries

    func entry(titleID: String) -> GameEntry? {
        let normalized = titleID.uppercased()
        return entries.first { $0.titleID == normalized }
    }

    /// Whether this build lists a game with this title ID.
    func contains(titleID: String) -> Bool {
        entry(titleID: titleID) != nil
    }

    /// The most recently played entry, nil before the first game was started.
    var mostRecentlyPlayed: GameEntry? {
        entries.first { $0.lastPlayedAt != nil }
    }

    /// Where the AOT code for this game comes from in this build (the home-page
    /// badge and the launch gate share it).
    func aotAvailability(for entry: GameEntry) -> AOTAvailability {
        AOTPackageLoader.shared.availability(for: entry)
    }

    // MARK: - Mutations (main queue)

    /// Marks the game as just played and re-sorts/persists the play history.
    func markPlayed(titleID: String) {
        let normalized = titleID.uppercased()
        guard let index = entries.firstIndex(where: { $0.titleID == normalized }) else { return }
        let now = Date()
        entries[index].lastPlayedAt = now
        history.lastPlayed[normalized] = now
        sortEntries()
        persistHistory()
        AppLog.log("[3ds2apple] library: marked %@ as played", normalized)
    }

    // MARK: - Preview

    /// UI preview only (ios/preview/SnapshotRenderer.swift): replaces the
    /// current entries with a catalog built in memory, so the Catalyst harness
    /// can render library states without a generated GameCatalog.json. It never
    /// writes the catalog to the app bundle.
    func installPreviewLibrary(_ catalog: GameCatalog, playTimes: [String: Date] = [:]) {
        history = PlayHistory(schemaVersion: PlayHistory.supportedSchemaVersion, lastPlayed: playTimes)
        entries = catalog.games.map { GameEntry(game: $0, lastPlayedAt: history.lastPlayed[$0.titleID]) }
        sortEntries()
        AppLog.log("[3ds2apple] library: preview catalog with %ld game(s)", entries.count)
    }

    // MARK: - Persistence

    private func load() {
        let catalog = GameCatalog.bundled
        var loadedHistory = readPlayHistory()
        if loadedHistory == nil {
            // First AOT-only launch after 0.1.x: keep the dates the user saw.
            let migrated = LegacyGameData.playTimes()
            loadedHistory = PlayHistory(schemaVersion: PlayHistory.supportedSchemaVersion,
                                        lastPlayed: migrated)
            if !migrated.isEmpty {
                persist(history: loadedHistory ?? PlayHistory())
            }
        }
        history = loadedHistory ?? PlayHistory()
        entries = catalog.games.map { game in
            GameEntry(game: game, lastPlayedAt: history.lastPlayed[game.titleID])
        }
        sortEntries()
        AppLog.log(
            "[3ds2apple] library: %ld game(s) from GameCatalog.json (schemaVersion %ld)",
            entries.count,
            catalog.schemaVersion
        )
    }

    private func sortEntries() {
        entries.sort { lhs, rhs in
            let left = lhs.lastPlayedAt ?? .distantPast
            let right = rhs.lastPlayedAt ?? .distantPast
            if left != right { return left > right }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order == .orderedSame { return lhs.titleID < rhs.titleID }
            return order == .orderedAscending
        }
    }

    private func persistHistory() {
        persist(history: history)
    }

    private func persist(history: PlayHistory) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            try AtomicFileWriter.write(data, to: Self.playHistoryURL)
        } catch {
            AppLog.log(
                "[3ds2apple] library: could not save playHistory.json: %@",
                error.localizedDescription
            )
        }
    }

    private func readPlayHistory() -> PlayHistory? {
        let url = Self.playHistoryURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode(PlayHistory.self, from: data)
            // Only keep canonical title ids; a hand-edited file cannot invent
            // library entries, the catalog alone decides which games exist.
            loaded.lastPlayed = loaded.lastPlayed.filter { GameCatalog.normalizedTitleID($0.key) != nil }
            AppLog.log("[3ds2apple] library: loaded play history for %ld game(s)", loaded.lastPlayed.count)
            return loaded
        } catch {
            AppLog.log(
                "[3ds2apple] library: could not read playHistory.json: %@",
                error.localizedDescription
            )
            return nil
        }
    }
}
