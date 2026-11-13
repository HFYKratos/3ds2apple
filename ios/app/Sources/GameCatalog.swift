//
//  GameCatalog.swift
//  3ds2apple
//
//  The games this build carries linked AOT code for. The desktop build scripts
//  write Resources/GameCatalog.json into the app bundle (fixed schema below);
//  the shell only reads it, to badge a library card as AOT and to skip the
//  interpreter confirmation when a game matches.
//
//  Schema:
//  {
//    "schemaVersion": 1,
//    "games": [
//      { "titleID": "0004000000055E00", "displayName": "Pokémon Y",
//        "productCode": "CTR-P-EK2A", "aot": true, "aotVersion": 1, "notes": "" }
//    ]
//  }
//
//  A missing or unreadable GameCatalog.json is not an error: a plain shell
//  build has no linked game, so the catalog is empty and every game is shown
//  as interpreter-only.
//

import Foundation

/// One game the build may carry linked AOT code for.
struct GameCatalogGame: Codable, Hashable, Identifiable {
    /// 16 upper-case hex digits, e.g. "0004000000055E00".
    let titleID: String
    /// Name shown on the library card, e.g. "Pokémon Y".
    let displayName: String
    /// 3DS product code, e.g. "CTR-P-EK2A".
    let productCode: String?
    /// Whether the static library linked into this build has AOT code for it.
    let aot: Bool
    /// Version of the linked AOT artifact (informational).
    let aotVersion: Int?
    /// Free-form note from the build scripts (informational).
    let notes: String?

    var id: String { titleID }

    enum CodingKeys: String, CodingKey {
        case titleID
        case displayName
        case productCode
        case aot
        case aotVersion
        case notes
    }

    init(
        titleID: String,
        displayName: String,
        productCode: String? = nil,
        aot: Bool,
        aotVersion: Int? = nil,
        notes: String? = nil
    ) {
        self.titleID = titleID.uppercased()
        self.displayName = displayName
        self.productCode = productCode
        self.aot = aot
        self.aotVersion = aotVersion
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitleID = try container.decodeIfPresent(String.self, forKey: .titleID) ?? ""
        titleID = rawTitleID.uppercased()
        let rawName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        displayName = rawName.isEmpty ? titleID : rawName
        productCode = try container.decodeIfPresent(String.self, forKey: .productCode)
        aot = try container.decodeIfPresent(Bool.self, forKey: .aot) ?? false
        aotVersion = try container.decodeIfPresent(Int.self, forKey: .aotVersion)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// The linked-game catalog of this build.
struct GameCatalog: Codable {
    /// Schema this shell understands.
    static let supportedSchemaVersion = 1

    /// Used when no catalog is bundled (a plain shell build).
    static let empty = GameCatalog(schemaVersion: GameCatalog.supportedSchemaVersion, games: [])

    let schemaVersion: Int
    let games: [GameCatalogGame]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case games
    }

    init(schemaVersion: Int = GameCatalog.supportedSchemaVersion, games: [GameCatalogGame] = []) {
        self.schemaVersion = schemaVersion
        self.games = games
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.supportedSchemaVersion
        games = try container.decodeIfPresent([GameCatalogGame].self, forKey: .games) ?? []
    }

    /// The catalog entry for a title id, nil for a game this build has no data
    /// for. Comparisons are case-insensitive and ignore surrounding spaces.
    func linkedGame(titleID: String?) -> GameCatalogGame? {
        guard let normalized = GameCatalog.normalizedTitleID(titleID) else { return nil }
        return games.first { $0.titleID == normalized }
    }

    /// Whether this build has linked AOT code for the title id. The home page
    /// uses it for the card badge and to decide whether to warn that the game
    /// runs in the interpreter.
    func isAOTPlayable(titleID: String?) -> Bool {
        linkedGame(titleID: titleID)?.aot == true
    }

    /// The games with linked AOT code.
    var linkedGames: [GameCatalogGame] {
        games.filter { $0.aot }
    }

    /// 16 upper-case hex digits, or nil when the value is not a title id.
    static func normalizedTitleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 16, trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        return trimmed
    }

    /// The catalog shipped in the app bundle, written by the desktop build
    /// scripts. Missing or unreadable means no linked game (empty catalog).
    static let bundled: GameCatalog = loadBundled()

    private static func loadBundled(bundle: Bundle = .main) -> GameCatalog {
        guard let url = bundle.url(forResource: "GameCatalog", withExtension: "json")
            ?? bundle.url(forResource: "GameCatalog", withExtension: "json", subdirectory: "Resources")
        else {
            AppLog.log(
                "[3ds2apple] game catalog: GameCatalog.json is not in the app bundle; every game runs in the interpreter"
            )
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(GameCatalog.self, from: data)
            let games = decoded.games.filter { game in
                normalizedTitleID(game.titleID) != nil && !game.displayName.isEmpty
            }
            let catalog = GameCatalog(schemaVersion: decoded.schemaVersion, games: games)
            AppLog.log(
                "[3ds2apple] game catalog: %ld game(s), %ld with linked AOT code",
                catalog.games.count,
                catalog.linkedGames.count
            )
            return catalog
        } catch {
            AppLog.log(
                "[3ds2apple] game catalog: could not read GameCatalog.json: %@",
                error.localizedDescription
            )
            return .empty
        }
    }
}
