//
//  GameLibrary.swift
//  3ds2apple
//
//  The app's game library. A game has two halves:
//
//  - the AOT code (FrameWorks/GamePack-<TITLEID>.dylib) and its catalog entry
//    are part of the signed IPA, written by the desktop launcher when it builds
//    the app (adding a game = rebuild + reinstall the shell);
//  - the game data (the user's decrypted ROM + GameInfo.json) is pushed into
//    Documents/Games/<TITLEID>/ after the install and stays there across app
//    updates.
//
//  This type reads the bundle's GameCatalog.json for the game list, joins each
//  entry with the pushed game data found by InstalledGame.swift, and publishes
//  one card per game: AOT (ready), Checking (verifying the ROM hash), Data
//  missing (launcher push not done yet) or Error (broken push). A fresh shell
//  with an empty catalog simply shows the launcher empty state.
//
//  The device state is Documents/Library/playHistory.json (title id -> last
//  played time), Documents/Library/removedGames.json (titles the user deleted
//  in the app) and the pushed game data, all written atomically.
//

import Combine
import Foundation

/// One game on the home page: one bundle catalog entry, joined with whatever
/// game data the launcher pushed into Documents/Games/<titleID>/.
struct GameEntry: Identifiable, Hashable {
    /// 16 upper-case hex digits of the 3DS program id.
    let titleID: String
    /// Name shown on the library card. The pushed GameInfo.json is authoritative
    /// when present; otherwise the catalog's display name.
    let title: String
    /// 3DS product code ("CTR-P-EK2A"), nil when neither side recorded it.
    let productCode: String?
    /// Publisher from the pushed SMDH metadata, nil when unknown.
    let publisher: String?
    /// Size of the pushed game data in bytes, nil until the launcher pushes it.
    let romBytes: UInt64?
    /// Cover image for the card: the launcher-pushed `cover.png` first, then
    /// the build's bundle cover; nil draws the deterministic placeholder.
    let coverURL: URL?
    /// Whether the build has AOT code for this game.
    let aot: Bool
    /// Version of the AOT artifact (informational).
    let aotVersion: Int?
    /// Bundle-relative AOT dylib, e.g. "Frameworks/GamePack-<titleID>.dylib".
    let packFile: String?
    /// Bundle-relative game data of the previous self-contained build (legacy
    /// fallback only; the launcher-first build leaves this empty).
    let romFile: String?
    /// GamePack ABI version recorded by the build (informational).
    let packABIVersion: Int?
    /// Optional registration symbol override for the GamePack loader.
    let registrationSymbol: String?
    /// Legacy bundle-relative cover image.
    let coverFile: String?
    /// Free-form note from the build/launcher.
    let notes: String?
    /// The game data pushed into Documents/Games/<titleID>/, nil until pushed.
    var pushedData: InstalledGame?
    /// Validation state of the pushed data (or "data missing").
    var validation: GameValidationState
    /// True when this is an app updated from the previous self-contained build
    /// and the game still launches from its bundled ROM.
    var isLegacyBundled: Bool
    /// When this game was last started on this device, nil for never.
    var lastPlayedAt: Date?

    var id: String { titleID }

    /// A cover image inside the signed app bundle (`GameCatalog.json`
    /// `coverFile`), validated as a bundle-relative path and only used when the
    /// file really exists; the shell never trusts an absolute path here.
    static func bundleCoverURL(coverFile: String?) -> URL? {
        guard let coverFile, AOTPackageLoader.isValidRelativePath(coverFile) else { return nil }
        let url = Bundle.main.bundleURL.appendingPathComponent(coverFile, isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Save-data / save-state folder name: the manifest's namespace, else the
    /// title ID. Two games can never share a folder.
    var saveNamespace: String { pushedData?.saveNamespace ?? titleID }

    /// Whether the launcher-pushed game data is present.
    var hasPushedData: Bool { pushedData != nil }

    /// Where this game's two halves live, for diagnostics.
    var sourceDescription: String {
        if hasPushedData { return "app bundle pack + Documents/Games/\(titleID)" }
        if isLegacyBundled { return "app bundle (previous build)" }
        if packFile != nil { return "app bundle pack (game data missing)" }
        return "preview"
    }

    init(titleID: String,
         title: String,
         productCode: String? = nil,
         publisher: String? = nil,
         romBytes: UInt64? = nil,
         coverURL: URL? = nil,
         aot: Bool,
         aotVersion: Int? = nil,
         packFile: String? = nil,
         romFile: String? = nil,
         packABIVersion: Int? = nil,
         registrationSymbol: String? = nil,
         coverFile: String? = nil,
         notes: String? = nil,
         pushedData: InstalledGame? = nil,
         validation: GameValidationState = .valid,
         isLegacyBundled: Bool = false,
         lastPlayedAt: Date? = nil) {
        self.titleID = titleID.uppercased()
        self.title = title
        self.productCode = productCode
        self.publisher = publisher
        self.romBytes = romBytes
        self.coverURL = coverURL
        self.aot = aot
        self.aotVersion = aotVersion
        self.packFile = packFile
        self.romFile = romFile
        self.packABIVersion = packABIVersion
        self.registrationSymbol = registrationSymbol
        self.coverFile = coverFile
        self.notes = notes
        self.pushedData = pushedData
        self.validation = validation
        self.isLegacyBundled = isLegacyBundled
        self.lastPlayedAt = lastPlayedAt
    }

    /// Joins one bundle catalog entry with its pushed Documents game data.
    init(game: GameCatalogGame, pushedData: InstalledGame?, lastPlayedAt: Date?) {
        let manifest = pushedData?.manifest
        let validation: GameValidationState
        if let pushedData {
            validation = pushedData.validation
        } else if game.romFile != nil {
            // App updated from the previous self-contained build: its ROM is
            // still inside the bundle and stays playable until the launcher
            // reinstalls with the AOT pack and pushes the data.
            validation = .valid
        } else {
            validation = .invalid([.gameDataMissing(game.titleID)])
        }
        self.init(
            titleID: game.titleID,
            // The pushed manifest is authoritative; `preferredDisplayName`
            // picks the SMDH name for this app's language. Without a push the
            // catalog's displayName is the graceful fallback.
            title: pushedData?.localizedDisplayName
                ?? manifest?.trimmedDisplayName
                ?? game.displayName,
            productCode: manifest?.productCode ?? game.productCode,
            publisher: pushedData?.publisher,
            // Prefer the size the launcher recorded in GameInfo.json
            // (`rom.size`, already validated against the file on scan); fall
            // back to the real file size of the push.
            romBytes: pushedData?.declaredROMSize ?? pushedData?.romBytes,
            coverURL: pushedData?.coverURL ?? GameEntry.bundleCoverURL(coverFile: game.coverFile),
            aot: game.aot,
            aotVersion: game.aotVersion,
            packFile: game.packFile,
            romFile: game.romFile,
            packABIVersion: game.packABIVersion,
            registrationSymbol: game.registrationSymbol,
            coverFile: game.coverFile,
            notes: game.notes ?? manifest?.notes,
            pushedData: pushedData,
            validation: validation,
            isLegacyBundled: pushedData == nil && game.romFile != nil,
            lastPlayedAt: lastPlayedAt
        )
    }

    /// UI preview only (UI test fixture): an entry without a
    /// launcher-written manifest or catalog file. The shipping app builds
    /// entries from the bundle catalog.
    init(titleID: String,
         title: String,
         aot: Bool,
         packFile: String? = nil,
         romFile: String? = nil,
         lastPlayedAt: Date? = nil) {
        self.init(titleID: titleID,
                  title: title,
                  aot: aot,
                  aotVersion: aot ? 1 : nil,
                  packFile: packFile,
                  romFile: romFile,
                  packABIVersion: packFile == nil ? nil : 1,
                  pushedData: nil,
                  validation: .valid,
                  isLegacyBundled: false,
                  lastPlayedAt: lastPlayedAt)
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

/// Documents/Library/removedGames.json: games the user deleted on this device.
///
/// A game's AOT pack is compiled into the signed app bundle and listed in the
/// bundle's GameCatalog.json, so deleting cannot remove it at run time. Deleting
/// a game removes everything the app owns instead (ROM, GameInfo.json, pushed
/// cover, battery saves, instant save states, play history, per-game settings)
/// and records the title id here so the bundled catalog entry stays hidden.
/// Pushing the game's data again with the desktop launcher brings it back.
struct RemovedGames: Codable {
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    /// Removal time per title ID (ISO 8601 on disk).
    var removed: [String: Date]

    init(schemaVersion: Int = RemovedGames.supportedSchemaVersion,
         removed: [String: Date] = [:]) {
        self.schemaVersion = schemaVersion
        self.removed = removed
    }
}

/// What one game deletion removed; the home page shows the result.
struct GameDeletionSummary {
    /// Display title of the deleted game, for the confirmation banner.
    let title: String
    /// Bytes removed from Documents/Games (ROM, GameInfo.json, pushed cover).
    let gameDataBytes: UInt64
    /// Bytes removed from the game's battery-save folder.
    let saveDataBytes: UInt64
    /// Bytes removed from the game's instant save-state folder.
    let saveStateBytes: UInt64
    /// Files that could not be removed although the game itself was deleted.
    let warnings: [String]
}

/// Errors from the delete-game path.
enum GameDeletionError: LocalizedError {
    /// The title id is not in the library any more.
    case unknownGame(String)
    /// The pushed game data (the folder in Documents/Games) could not be
    /// removed; the game stays in the library and the deletion can be retried.
    case gameDataNotRemoved(String)

    var errorDescription: String? {
        switch self {
        case .unknownGame:
            return L10n.tr("That game is not in the library any more.")
        case .gameDataNotRemoved(let detail):
            return L10n.format("Could not delete the game's data: %@", detail)
        }
    }
}

/// A one-line library banner (unreadable Documents/Games folder). Per-game
/// problems live on the cards.
struct LibraryNotice: Identifiable, Equatable {
    let id: UUID
    let message: String

    init(message: String) {
        self.id = UUID()
        self.message = message
    }
}

/// The app's game library, shared by the whole app.
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    /// Every game in this build, most recently played first, then by title.
    @Published private(set) var entries: [GameEntry] = []
    /// A banner about the library itself (unreadable Documents/Games folder).
    @Published private(set) var notice: LibraryNotice?
    /// Catalog games hidden because the user deleted them on this device.
    @Published private(set) var hiddenGameCount = 0

    private var history = PlayHistory()
    /// Games deleted in the app; persisted in Documents/Library/removedGames.json.
    private var removed = RemovedGames()
    private let fileManager = FileManager.default
    /// SHA-256 results already computed this app run, keyed by title id.
    private var verificationCache: [String: (fingerprint: String, state: GameValidationState)] = [:]
    /// Games whose background hash check is running right now.
    private var verificationInFlight: Set<String> = []
    /// Callers waiting for one game's hash check (the launch path).
    private var verificationWaiters: [String: [(GameValidationState) -> Void]] = [:]

    private init() {
        load()
    }

    // MARK: - Paths

    static var documentsDirectory: URL { StorageInspector.documentsURL }

    /// Folder of playHistory.json, kept out of the Files-visible game folders.
    static var libraryDirectory: URL {
        documentsDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    static var playHistoryURL: URL {
        libraryDirectory.appendingPathComponent("playHistory.json", isDirectory: false)
    }

    /// Documents/Library/removedGames.json: the local record of deleted games.
    static var removedGamesURL: URL {
        libraryDirectory.appendingPathComponent("removedGames.json", isDirectory: false)
    }

    // MARK: - Queries

    func entry(titleID: String) -> GameEntry? {
        let normalized = titleID.uppercased()
        return entries.first { $0.titleID == normalized }
    }

    func contains(titleID: String) -> Bool {
        entry(titleID: titleID) != nil
    }

    /// The most recently played entry, nil before the first game was started.
    var mostRecentlyPlayed: GameEntry? {
        entries.first { $0.lastPlayedAt != nil }
    }

    /// Where the AOT code for this game comes from (the launch gate and the
    /// diagnostics/log share it; the home card shows no AOT badge).
    func aotAvailability(for entry: GameEntry) -> AOTAvailability {
        AOTPackageLoader.shared.availability(for: entry)
    }

    // MARK: - Mutations (main queue)

    /// Rescans Documents/Games. Called at launch, when the app returns to the
    /// foreground and from the home page's pull-to-refresh, because the desktop
    /// launcher can push game data while the app is not in front.
    func refresh() {
        if Thread.isMainThread {
            reloadEntries()
        } else {
            DispatchQueue.main.async { [weak self] in self?.reloadEntries() }
        }
    }

    func dismissNotice() {
        notice = nil
    }

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

    /// Waits for a game's background hash check. Calls back on the main queue
    /// with the final state; an entry that is not being checked calls back
    /// immediately. The launch path uses this so a tap during the check still
    /// starts the game once the data is proven good (or shows the error).
    func ensureVerified(titleID: String, completion: @escaping (GameValidationState) -> Void) {
        let normalized = titleID.uppercased()
        guard let entry = entry(titleID: normalized) else {
            completion(.invalid([.folderMissing(normalized)]))
            return
        }
        if entry.validation != .checking {
            completion(entry.validation)
            return
        }
        verificationWaiters[normalized, default: []].append(completion)
    }

    // MARK: - Deletion (main queue)

    /// Deletes one game from this device.
    ///
    /// Removes the pushed game data (ROM, GameInfo.json, pushed cover), the
    /// battery saves and instant save states of the game's save namespace, the
    /// play history and the per-game state (graphics warm-up marker, cover).
    /// The AOT pack is part of the signed app, so the title is recorded in
    /// Documents/Library/removedGames.json and hidden from the library instead;
    /// the launcher pushing the data again brings it back.
    ///
    /// Filesystem work runs on a background queue; the completion (and the
    /// library update) runs on the main queue. The caller must release a running
    /// runtime first: the home page only offers deletion while no game is
    /// loaded, and stops one that is somehow still active before calling this.
    func deleteGame(titleID: String, completion: @escaping (Result<GameDeletionSummary, Error>) -> Void) {
        let normalized = titleID.uppercased()
        guard let entry = entry(titleID: normalized) else {
            completion(.failure(GameDeletionError.unknownGame(normalized)))
            return
        }
        let title = entry.title
        let namespace = entry.saveNamespace
        let pushedDirectory = entry.pushedData?.directoryURL
        let folderName = entry.pushedData?.folderName ?? normalized
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.removeFiles(title: title,
                                          titleID: normalized,
                                          namespace: namespace,
                                          pushedDirectory: pushedDirectory,
                                          folderName: folderName)
            DispatchQueue.main.async {
                switch outcome {
                case .failure(let error):
                    AppLog.log(
                        "[3ds2apple] library: could not delete %@: %@",
                        normalized,
                        error.localizedDescription
                    )
                    completion(.failure(error))
                case .success(let summary):
                    self.forgetGame(titleID: normalized)
                    AppLog.log(
                        "[3ds2apple] library: deleted %@ (%@): game data %llu B, saves %llu B, save states %llu B",
                        summary.title,
                        normalized,
                        summary.gameDataBytes,
                        summary.saveDataBytes,
                        summary.saveStateBytes
                    )
                    for warning in summary.warnings {
                        AppLog.log("[3ds2apple] library: delete warning for %@: %@", normalized, warning)
                    }
                    completion(.success(summary))
                }
            }
        }
    }

    /// Removes the files a game owns. Every path is checked to be a direct child
    /// of its root before anything is removed, so a hand-made manifest or a
    /// crashed state can never delete another game's files.
    private func removeFiles(title: String,
                             titleID: String,
                             namespace: String,
                             pushedDirectory: URL?,
                             folderName: String) -> Result<GameDeletionSummary, Error> {
        var warnings: [String] = []

        // 1) Pushed game data: Documents/Games/<TITLEID>/ (ROM, GameInfo, cover).
        let gamesRoot = DocumentsGames.rootURL
        let gameDirectory = pushedDirectory
            ?? gamesRoot.appendingPathComponent(folderName, isDirectory: true)
        let isGamesChild = gameDirectory.standardizedFileURL
            .deletingLastPathComponent().standardizedFileURL.path
            == gamesRoot.standardizedFileURL.path
        guard isGamesChild,
              GameCatalog.normalizedTitleID(gameDirectory.lastPathComponent) != nil else {
            return .failure(GameDeletionError.gameDataNotRemoved(
                L10n.format("the folder “%@” is not inside Documents/Games.",
                            gameDirectory.lastPathComponent)
            ))
        }
        var gameDataBytes: UInt64 = 0
        if fileManager.fileExists(atPath: gameDirectory.path) {
            gameDataBytes = Self.directorySize(gameDirectory)
            do {
                try fileManager.removeItem(at: gameDirectory)
            } catch {
                return .failure(GameDeletionError.gameDataNotRemoved(error.localizedDescription))
            }
        }

        // 2) Battery saves: Documents/data/<save namespace>/.
        let saveDataBytes = removeTree(SaveDataStore.batterySaveDirectory(namespace: namespace),
                                       inside: StorageInspector.dataURL,
                                       warnings: &warnings)
        // 3) Instant save states: Documents/states/<save namespace>/.
        let saveStateBytes = removeTree(SaveStateSupport.statesDirectory(namespace: namespace),
                                        inside: SaveStateSupport.statesRootURL,
                                        warnings: &warnings)
        // 4) Per-game settings: the graphics warm-up marker of this ROM.
        GraphicsWarmUpMarker.clear(romKey: titleID)

        return .success(GameDeletionSummary(
            title: title,
            gameDataBytes: gameDataBytes,
            saveDataBytes: saveDataBytes,
            saveStateBytes: saveStateBytes,
            warnings: warnings
        ))
    }

    /// Removes one game folder that must be a direct child of `root`; a path
    /// outside it is never touched (it may belong to another game).
    private func removeTree(_ url: URL,
                            inside root: URL,
                            warnings: inout [String]) -> UInt64 {
        let standardized = url.standardizedFileURL
        let isChild = standardized.deletingLastPathComponent().standardizedFileURL.path
            == root.standardizedFileURL.path
        guard isChild else {
            warnings.append(L10n.format("“%@” is outside its expected folder; not deleted.",
                                        url.lastPathComponent))
            return 0
        }
        guard fileManager.fileExists(atPath: standardized.path) else { return 0 }
        let bytes = Self.directorySize(standardized)
        do {
            try fileManager.removeItem(at: standardized)
            return bytes
        } catch {
            warnings.append(L10n.format("Could not delete “%@”: %@",
                                        url.lastPathComponent,
                                        error.localizedDescription))
            return 0
        }
    }

    /// Applies the in-memory half of a successful deletion on the main queue:
    /// hides the entry, drops the play history and persists both records.
    private func forgetGame(titleID: String) {
        notifyWaiters(titleID: titleID, state: .invalid([.folderMissing(titleID)]))
        verificationCache.removeValue(forKey: titleID)
        verificationInFlight.remove(titleID)
        removed.removed[titleID] = Date()
        hiddenGameCount += 1
        persist(removed: removed)
        history.lastPlayed.removeValue(forKey: titleID)
        persistHistory()
        entries.removeAll { $0.titleID == titleID }
    }

    /// Recursive size of one directory, used for the deletion log and banner.
    private static func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var bytes: UInt64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            bytes += UInt64(max(values.fileSize ?? 0, 0))
        }
        return bytes
    }

    // MARK: - Preview

    /// UI preview only (UI test fixture): illustrates the
    /// library states with an in-memory catalog, without a generated
    /// GameCatalog.json or pushed game data.
    func installPreviewLibrary(_ catalog: GameCatalog, playTimes: [String: Date] = [:]) {
        history = PlayHistory(schemaVersion: PlayHistory.supportedSchemaVersion, lastPlayed: playTimes)
        notice = nil
        hiddenGameCount = 0
        entries = catalog.games.map { game in
            GameEntry(titleID: game.titleID,
                      title: game.displayName,
                      productCode: game.productCode,
                      aot: game.aot,
                      aotVersion: game.aotVersion,
                      packFile: game.packFile,
                      romFile: game.romFile,
                      packABIVersion: game.packABIVersion,
                      registrationSymbol: game.registrationSymbol,
                      coverFile: game.coverFile,
                      notes: game.notes,
                      pushedData: nil,
                      validation: .valid,
                      isLegacyBundled: false,
                      lastPlayedAt: history.lastPlayed[game.titleID])
        }
        sortEntries()
        AppLog.log("[3ds2apple] library: preview catalog with %ld game(s)", entries.count)
    }

    // MARK: - Loading

    private func load() {
        removed = readRemovedGames() ?? RemovedGames()
        var loadedHistory = readPlayHistory()
        if loadedHistory == nil {
            // First launch after an older shell: keep the play dates the user
            // already saw. The old library.json never decides the games any
            // more; the bundle catalog does.
            let migrated = LegacyGameData.playTimes()
            loadedHistory = PlayHistory(schemaVersion: PlayHistory.supportedSchemaVersion,
                                        lastPlayed: migrated)
            if !migrated.isEmpty {
                persist(history: loadedHistory ?? PlayHistory())
            }
        }
        history = loadedHistory ?? PlayHistory()
        reloadEntries()
    }

    /// Rebuilds entries from the bundle catalog joined with the pushed
    /// Documents/Games data, then starts the background ROM hash checks.
    private func reloadEntries() {
        let catalog = GameCatalog.bundled
        let scan = DocumentsGames.scan()

        var dataByTitle: [String: InstalledGame] = [:]
        for game in scan.games {
            let normalized = GameCatalog.normalizedTitleID(game.titleID)
            guard normalized != nil, normalized == game.titleID else {
                AppLog.log(
                    "[3ds2apple] library: ignoring Documents/Games/%@ (folder is not a title id)",
                    game.folderName
                )
                continue
            }
            if dataByTitle[game.titleID] != nil {
                AppLog.log(
                    "[3ds2apple] library: duplicate game data for %@; keeping the first folder",
                    game.titleID
                )
                continue
            }
            dataByTitle[game.titleID] = game
        }

        // A title the user deleted in the app stays hidden while the signed
        // catalog still lists its AOT pack. Pushing the game's data again is how
        // it comes back: an existing push clears the local removal record.
        let restored = catalog.games.filter {
            dataByTitle[$0.titleID] != nil && removed.removed[$0.titleID] != nil
        }
        for game in restored {
            removed.removed.removeValue(forKey: game.titleID)
            AppLog.log(
                "[3ds2apple] library: %@ was pushed again; showing it in the library again",
                game.titleID
            )
        }
        if !restored.isEmpty {
            persist(removed: removed)
        }
        let visibleGames = catalog.games.filter { game in
            dataByTitle[game.titleID] != nil || removed.removed[game.titleID] == nil
        }
        let hiddenCount = catalog.games.count - visibleGames.count
        hiddenGameCount = hiddenCount

        if visibleGames.isEmpty {
            entries = []
            if hiddenCount > 0 {
                AppLog.log(
                    "[3ds2apple] library: every catalog game (%ld) is deleted on this device",
                    hiddenCount
                )
            } else {
                AppLog.log(
                    "[3ds2apple] library: the app bundle has no GameCatalog.json entries (base shell with no games)"
                )
            }
        } else {
            entries = visibleGames.map { game in
                GameEntry(game: game,
                          pushedData: dataByTitle[game.titleID],
                          lastPlayedAt: history.lastPlayed[game.titleID])
            }
            let known = Set(visibleGames.map { $0.titleID })
            for titleID in dataByTitle.keys where !known.contains(titleID) {
                AppLog.log(
                    "[3ds2apple] library: Documents/Games has data for %@ but this build has no AOT pack for it; ignored",
                    titleID
                )
            }
        }

        if let problem = scan.directoryProblem {
            let message = L10n.format("Could not read the Documents/Games folder: %@", problem)
            if notice?.message != message {
                notice = LibraryNotice(message: message)
                AppLog.log("[3ds2apple] library notice: %@", message)
            }
        } else {
            notice = nil
        }

        sortEntries()
        startVerification()
        AppLog.log(
            "[3ds2apple] library: %ld catalog game(s); %ld with pushed game data, %ld missing data, %ld checking, %ld invalid",
            entries.count,
            entries.filter { $0.hasPushedData }.count,
            entries.filter { entry in
                entry.validation.issues.contains { issue in
                    if case .gameDataMissing = issue { return true }
                    return false
                }
            }.count,
            entries.filter { $0.validation == .checking }.count,
            entries.filter { !$0.validation.issues.isEmpty && $0.validation != .checking }.count
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

    // MARK: - Background verification

    private func startVerification() {
        for entry in entries {
            guard let data = entry.pushedData, data.validation == .checking else { continue }
            let titleID = entry.titleID
            if verificationInFlight.contains(titleID) { continue }
            let fingerprint = data.verificationFingerprint
            if let cached = verificationCache[titleID], cached.fingerprint == fingerprint {
                applyValidation(titleID: titleID, state: cached.state)
                continue
            }
            verificationInFlight.insert(titleID)
            AppLog.log("[3ds2apple] library: verifying the pushed game data of %@ (SHA-256)", titleID)
            DocumentsGames.verifyHashes(of: data) { [weak self] issues in
                guard let self else { return }
                let state: GameValidationState = issues.isEmpty ? .valid : .invalid(issues)
                self.verificationCache[titleID] = (fingerprint, state)
                self.verificationInFlight.remove(titleID)
                self.applyValidation(titleID: titleID, state: state)
            }
        }
    }

    private func applyValidation(titleID: String, state: GameValidationState) {
        defer { notifyWaiters(titleID: titleID, state: state) }
        guard let index = entries.firstIndex(where: { $0.titleID == titleID }),
              entries[index].validation == .checking else { return }
        entries[index].pushedData?.validation = state
        entries[index].validation = state
        if case .invalid(let issues) = state, let first = issues.first {
            AppLog.log("[3ds2apple] library: %@ failed verification: %@", titleID, first.localizedMessage)
        } else {
            AppLog.log("[3ds2apple] library: %@ game data verified", titleID)
        }
    }

    private func notifyWaiters(titleID: String, state: GameValidationState) {
        guard let waiters = verificationWaiters.removeValue(forKey: titleID) else { return }
        for waiter in waiters { waiter(state) }
    }

    // MARK: - Removed-game persistence

    private func persist(removed: RemovedGames) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(removed)
            try AtomicFileWriter.write(data, to: Self.removedGamesURL)
        } catch {
            AppLog.log("[3ds2apple] library: could not save removedGames.json: %@", error.localizedDescription)
        }
    }

    private func readRemovedGames() -> RemovedGames? {
        let url = Self.removedGamesURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var loaded = try decoder.decode(RemovedGames.self, from: data)
            loaded.removed = loaded.removed.filter { GameCatalog.normalizedTitleID($0.key) != nil }
            return loaded
        } catch {
            AppLog.log("[3ds2apple] library: could not read removedGames.json: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Play history persistence

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
            AppLog.log("[3ds2apple] library: could not save playHistory.json: %@", error.localizedDescription)
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
            loaded.lastPlayed = loaded.lastPlayed.filter { GameCatalog.normalizedTitleID($0.key) != nil }
            AppLog.log("[3ds2apple] library: loaded play history for %ld game(s)", loaded.lastPlayed.count)
            return loaded
        } catch {
            AppLog.log("[3ds2apple] library: could not read playHistory.json: %@", error.localizedDescription)
            return nil
        }
    }
}
