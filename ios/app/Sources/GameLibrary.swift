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
//  The only device state is Documents/Library/playHistory.json (title id ->
//  last played time, written atomically) plus the pushed game data.
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
            title: manifest?.trimmedDisplayName ?? game.displayName,
            productCode: manifest?.productCode ?? game.productCode,
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

    /// UI preview only (ios/preview/SnapshotRenderer.swift): an entry without a
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

    private var history = PlayHistory()
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

    /// Where the AOT code for this game comes from (home-page badge and launch
    /// gate share it).
    func aotAvailability(for entry: GameEntry) -> AOTAvailability {
        AOTPackageLoader.shared.availability(for: entry)
    }

    // MARK: - Mutations (main queue)

    /// Rescans Documents/Games. Called at launch, when the app returns to the
    /// foreground and from the home page's refresh control, because the desktop
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

    // MARK: - Preview

    /// UI preview only (ios/preview/SnapshotRenderer.swift): illustrates the
    /// library states with an in-memory catalog, without a generated
    /// GameCatalog.json or pushed game data.
    func installPreviewLibrary(_ catalog: GameCatalog, playTimes: [String: Date] = [:]) {
        history = PlayHistory(schemaVersion: PlayHistory.supportedSchemaVersion, lastPlayed: playTimes)
        notice = nil
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

        if catalog.games.isEmpty {
            entries = []
            AppLog.log(
                "[3ds2apple] library: the app bundle has no GameCatalog.json entries (base shell with no games)"
            )
        } else {
            entries = catalog.games.map { game in
                GameEntry(game: game,
                          pushedData: dataByTitle[game.titleID],
                          lastPlayedAt: history.lastPlayed[game.titleID])
            }
            let known = Set(catalog.games.map { $0.titleID })
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
