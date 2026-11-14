//
//  GameCatalog.swift
//  3ds2apple
//
//  The games this build carries AOT code for. The desktop launcher writes
//  Resources/GameCatalog.json into the signed app bundle together with one
//  Frameworks/GamePack-<TITLEID>.dylib per game; the shell reads the catalog as
//  the game list. A base shell may ship an empty (or no) catalog and then shows
//  its launcher empty state.
//
//  The game DATA is not in the bundle: the launcher pushes it into
//  Documents/Games/<TITLEID>/ after installing the build (InstalledGame.swift).
//  The catalog's "romFile" is only used by an app updated from the previous
//  self-contained build, whose ROM still sits inside the bundle; it is the
//  legacy fallback, not the launcher-first path.
//
//  Schema version 2 (this file). Version 1 catalogs still decode unchanged:
//
//  {
//    "schemaVersion": 2,
//    "games": [
//      { "titleID": "0004000000055E00",          // 16 upper-case hex digits
//        "displayName": "Pokémon Y",
//        "productCode": "CTR-P-EK2A",            // optional
//        "aot": true,                            // AOT code allocated for this game
//        "aotVersion": 1,                        // optional, >= 1 when aot is true
//        "packFile": "Frameworks/GamePack-0004000000055E00.dylib",  // optional
//        "packABIVersion": 1,                    // optional, default 1
//        "registrationSymbol": "zk_gamepack_register",  // optional override
//        "coverFile": "Covers/0004000000055E00.png",    // optional
//        "notes": "" }                           // optional
//    ]
//  }
//
//  - "packFile" is a path RELATIVE TO THE APP BUNDLE of the per-game AOT dylib.
//    When it is absent, the AOT code is statically linked into the app binary
//    (today's single-game IPA): that is the compatibility fallback.
//  - "romFile" (optional) is a path RELATIVE TO THE APP BUNDLE of the game data
//    (the user's decrypted ROM, e.g. "Roms/0004000000055E00.cci"). The shell
//    hands that file to the runtime, so a package that carries it needs no
//    on-device import. A package build without it cannot start; the legacy
//    Documents/roms cartridge is only used by statically linked builds.
//  - "aot": false lists a game the desktop build did not compile. It is shown
//    in the library as "No AOT" and cannot be started.
//  - "schemaVersion": 1 catalogs have no packFile, so every AOT entry is treated
//    as statically linked; that keeps every 0.1.x build working.
//
//  A missing or unreadable GameCatalog.json is not an error: a base shell with
//  no games has an empty library, and the home page explains that games are
//  added from the desktop launcher.
//

import Foundation

/// One game this build carries AOT code for, as written by the desktop build.
struct GameCatalogGame: Codable, Hashable, Identifiable {
    /// 16 upper-case hex digits, e.g. "0004000000055E00".
    let titleID: String
    /// Name shown on the library card, e.g. "Pokémon Y".
    let displayName: String
    /// 3DS product code, e.g. "CTR-P-EK2A".
    let productCode: String?
    /// Whether the desktop build allocated AOT code for this game.
    let aot: Bool
    /// Version of the AOT artifact itself (informational, >= 1 when aot).
    let aotVersion: Int?
    /// Bundle-relative path of the per-game AOT dylib, nil when the AOT code is
    /// statically linked into the app binary (today's single-game builds).
    let packFile: String?
    /// Bundle-relative path of the game data the pack runs, e.g.
    /// "Roms/0004000000055E00.cci". nil when this build does not bundle the ROM.
    let romFile: String?
    /// ABI version of the GamePack dylib contract (AOTPackageLoader.hostABIVersion).
    let packABIVersion: Int?
    /// Optional override of the registration symbol the loader looks up.
    let registrationSymbol: String?
    /// Optional bundle-relative cover image.
    let coverFile: String?
    /// Free-form note from the build pipeline (informational).
    let notes: String?

    var id: String { titleID }

    enum CodingKeys: String, CodingKey {
        case titleID
        case displayName
        case productCode
        case aot
        case aotVersion
        case packFile
        case romFile
        case packABIVersion
        case registrationSymbol
        case coverFile
        case notes
    }

    init(
        titleID: String,
        displayName: String,
        productCode: String? = nil,
        aot: Bool,
        aotVersion: Int? = nil,
        packFile: String? = nil,
        romFile: String? = nil,
        packABIVersion: Int? = nil,
        registrationSymbol: String? = nil,
        coverFile: String? = nil,
        notes: String? = nil
    ) {
        self.titleID = titleID.uppercased()
        self.displayName = displayName
        self.productCode = productCode
        self.aot = aot
        self.aotVersion = aotVersion
        self.packFile = packFile
        self.romFile = romFile
        self.packABIVersion = packABIVersion
        self.registrationSymbol = registrationSymbol
        self.coverFile = coverFile
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitleID = try container.decodeIfPresent(String.self, forKey: .titleID) ?? ""
        titleID = rawTitleID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let rawName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = trimmedName.isEmpty ? titleID : trimmedName
        productCode = try container.decodeIfPresent(String.self, forKey: .productCode)
        // Version 1 wrote "aot" for every entry; a value this shell cannot see
        // means "not built", never "assume AOT".
        aot = try container.decodeIfPresent(Bool.self, forKey: .aot) ?? false
        aotVersion = try container.decodeIfPresent(Int.self, forKey: .aotVersion)
        packFile = try container.decodeIfPresent(String.self, forKey: .packFile)
        romFile = try container.decodeIfPresent(String.self, forKey: .romFile)
        packABIVersion = try container.decodeIfPresent(Int.self, forKey: .packABIVersion)
        registrationSymbol = try container.decodeIfPresent(String.self, forKey: .registrationSymbol)
        coverFile = try container.decodeIfPresent(String.self, forKey: .coverFile)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// The AOT game manifest of this build.
struct GameCatalog: Codable {
    /// Schema this shell understands. Version 1 catalogs decode as a version 2
    /// catalog whose entries have no packFile (static-link fallback).
    static let supportedSchemaVersion = 2

    /// Used when no catalog is bundled (a shell build with no AOT games).
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

    // MARK: - Queries

    /// The catalog entry for a title id, nil for a game this build has no data
    /// for. Comparisons are case-insensitive and ignore surrounding spaces.
    func game(titleID: String?) -> GameCatalogGame? {
        guard let normalized = GameCatalog.normalizedTitleID(titleID) else { return nil }
        return games.first { $0.titleID == normalized }
    }

    /// Whether the manifest allocates AOT code for the title id.
    func isAOTBuilt(titleID: String?) -> Bool {
        guard let game = game(titleID: titleID) else { return false }
        return game.aot
    }

    /// The games the manifest marks as built.
    var aotGames: [GameCatalogGame] {
        games.filter { $0.aot }
    }

    // MARK: - Loading

    /// 16 upper-case hex digits, or nil when the value is not a title id.
    static func normalizedTitleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 16, trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        return trimmed
    }

    /// Decodes a catalog file, drops entries the shell cannot use and logs why.
    /// Throws only when the JSON itself is unreadable so the caller can fall
    /// back to an empty catalog.
    static func load(from url: URL) throws -> GameCatalog {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(GameCatalog.self, from: data)
        return sanitized(decoded, source: url.lastPathComponent)
    }

    /// Drops invalid entries and normalizes the catalog. Keeps every valid
    /// entry, including "aot": false ones, so the library can show them as
    /// unavailable instead of silently hiding data a build intended to ship.
    private static func sanitized(_ decoded: GameCatalog, source: String) -> GameCatalog {
        if decoded.schemaVersion > supportedSchemaVersion {
            AppLog.log(
                "[3ds2apple] game catalog: %@ uses schemaVersion %ld, newer than the %ld this shell understands; decoding the fields it knows",
                source,
                decoded.schemaVersion,
                supportedSchemaVersion
            )
        } else if decoded.schemaVersion < supportedSchemaVersion {
            AppLog.log(
                "[3ds2apple] game catalog: %@ uses legacy schemaVersion %ld; AOT entries without packFile are treated as statically linked",
                source,
                decoded.schemaVersion
            )
        }

        var games: [GameCatalogGame] = []
        var seen = Set<String>()
        for game in decoded.games {
            guard normalizedTitleID(game.titleID) != nil else {
                AppLog.log(
                    "[3ds2apple] game catalog: skipping an entry with invalid titleID '%@'",
                    game.titleID
                )
                continue
            }
            guard !seen.contains(game.titleID) else {
                AppLog.log(
                    "[3ds2apple] game catalog: skipping duplicate titleID %@",
                    game.titleID
                )
                continue
            }
            seen.insert(game.titleID)

            var packFile = game.packFile?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rawPackFile = packFile, !rawPackFile.isEmpty {
                if AOTPackageLoader.isValidRelativePath(rawPackFile) {
                    packFile = rawPackFile
                } else {
                    AppLog.log(
                        "[3ds2apple] game catalog: %@ has an invalid packFile '%@' (must be a relative path inside the app bundle); treating it as statically linked",
                        game.titleID,
                        rawPackFile
                    )
                    packFile = nil
                }
            } else {
                packFile = nil
            }

            // Same untrusted-path rule as packFile: a romFile that escapes the
            // bundle is dropped, never opened.
            var romFile = game.romFile?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rawROMFile = romFile, !rawROMFile.isEmpty {
                if AOTPackageLoader.isValidRelativePath(rawROMFile) {
                    romFile = rawROMFile
                } else {
                    AppLog.log(
                        "[3ds2apple] game catalog: %@ has an invalid romFile '%@' (must be a relative path inside the app bundle); the game data is treated as missing",
                        game.titleID,
                        rawROMFile
                    )
                    romFile = nil
                }
            } else {
                romFile = nil
            }

            var coverFile = game.coverFile?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rawCover = coverFile, rawCover.isEmpty || !AOTPackageLoader.isValidRelativePath(rawCover) {
                coverFile = nil
            }

            games.append(GameCatalogGame(
                titleID: game.titleID,
                displayName: game.displayName,
                productCode: game.productCode,
                aot: game.aot,
                aotVersion: game.aotVersion,
                packFile: packFile,
                romFile: romFile,
                packABIVersion: game.packABIVersion,
                registrationSymbol: game.registrationSymbol,
                coverFile: coverFile,
                notes: game.notes
            ))
        }
        return GameCatalog(schemaVersion: decoded.schemaVersion, games: games)
    }

    /// The catalog shipped in the app bundle (bundle root or Resources/),
    /// written by the desktop build. Missing or unreadable means no games.
    static let bundled: GameCatalog = loadBundled()

    private static func loadBundled(bundle: Bundle = .main) -> GameCatalog {
        guard let url = bundle.url(forResource: "GameCatalog", withExtension: "json")
            ?? bundle.url(forResource: "GameCatalog", withExtension: "json", subdirectory: "Resources")
        else {
            AppLog.log(
                "[3ds2apple] game catalog: no GameCatalog.json in the app bundle (base shell with no AOT games)"
            )
            return .empty
        }
        do {
            let catalog = try load(from: url)
            AppLog.log(
                "[3ds2apple] game catalog: %@ · schemaVersion %ld · %ld game(s), %ld built",
                url.lastPathComponent,
                catalog.schemaVersion,
                catalog.games.count,
                catalog.aotGames.count
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
