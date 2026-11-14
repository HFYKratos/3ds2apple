//
//  GameInfo.swift
//  3ds2apple
//
//  Documents/Games/<TITLEID>/GameInfo.json: the per-game manifest the desktop
//  launcher writes when it pushes a game's DATA into the app's Documents
//  folder. The AOT code is not here — iOS will not dlopen an unsigned dylib
//  from Documents — so GamePack.dylib ships inside the signed IPA and is listed
//  in the bundle GameCatalog.json. The layout the launcher pushes is:
//
//    Documents/Games/0004000000055E00/
//      GameInfo.json     this manifest (required; written last)
//      GameRom.cci       user's decrypted game data (required; "rom.file")
//      cover.png         optional cover image ("cover")
//
//  GameInfo.json is authoritative for the game's display title, save namespace
//  and the pushed game data's size/SHA-256. The "pack" object is informational
//  only: it describes the pack the launcher built into the IPA, which the shell
//  never loads from Documents.
//
//  Schema version 1:
//
//  {
//    "schemaVersion": 1,
//    "titleID": "0004000000055E00",                 // 16 upper-case hex digits
//    "displayName": "Pokémon Y",
//    "productCode": "CTR-P-EK2A",                   // optional
//    "aot": true,                                    // optional, default true
//    "aotVersion": 1,                                // optional, informational
//    "packABIVersion": 1,                            // optional, default 1
//    "registrationSymbol": "zk_gamepack_register",   // optional override
//    "saveNamespace": "0004000000055E00",            // optional, default titleID
//    "pack": { "file": "GamePack.dylib", "size": 1234567, "sha256": "…" },
//    "rom":  { "file": "GameRom.cci", "size": 1446201088, "sha256": "…" },
//    "cover": "cover.png",                           // optional
//    "launcherVersion": "3ds2apple-launcher-macos/0.1.0",   // optional
//    "pushedAt": "2026-11-14T14:00:00Z",             // optional, informational
//    "notes": ""                                     // optional
//  }
//
//  - Every field except the game data file is optional. The shell defaults the
//    game data to "GameRom.cci" (or "GameRom.3ds"), so a launcher that only
//    copies the ROM plus a bare manifest still produces a usable push.
//  - "rom.size" and "rom.sha256" are optional. When the launcher records them
//    the shell verifies them: a size mismatch is caught while scanning, a
//    SHA-256 mismatch by a background check. Either one turns the library card
//    into a per-game error and blocks launch; the shell never starts a game
//    whose data it cannot trust. (The pack in the IPA is validated separately
//    by AOTPackageLoader: title, ABI and registration hook.)
//  - Unknown fields are ignored, so a newer launcher can add fields without
//    breaking an older shell.
//  - The folder name is the title ID. A manifest that names a different title
//    is rejected: a push that wrote one game's files under another title ID
//    must never run that game's code.
//

import Foundation

/// One file of a pushed game (the AOT dylib or the game data) as recorded in
/// GameInfo.json. Every field is optional: a launcher may record only names,
/// only sizes, or sizes and a SHA-256.
struct GameFileInfo: Codable, Hashable {
    /// File name relative to the game's folder, e.g. "GamePack.dylib".
    let file: String?
    /// Size in bytes, checked against the file on disk when present.
    let size: UInt64?
    /// Lower-case hex SHA-256, checked in the background when present.
    let sha256: String?

    init(file: String? = nil, size: UInt64? = nil, sha256: String? = nil) {
        self.file = file
        self.size = size
        self.sha256 = sha256
    }
}

/// Documents/Games/<TITLEID>/GameInfo.json: the launcher's record of one game.
struct GameInfo: Codable, Hashable {
    /// The manifest schema this shell understands.
    static let supportedSchemaVersion = 1
    static let manifestFileName = "GameInfo.json"
    static let defaultPackFileName = "GamePack.dylib"
    /// Defaults when the manifest has no "rom.file": the launcher's canonical
    /// name first, then the .3ds spelling some dumps use.
    static let defaultROMFileNames = ["GameRom.cci", "GameRom.3ds"]

    let schemaVersion: Int?
    /// 16 upper-case hex digits; must match the folder name.
    let titleID: String?
    /// Name shown on the library card; falls back to the title ID.
    let displayName: String?
    let productCode: String?
    /// Whether the launcher built AOT code for this game. Default true.
    let aot: Bool?
    let aotVersion: Int?
    /// GamePack ABI version the pack was built against (the host speaks 1).
    let packABIVersion: Int?
    /// Override of the registration symbol the pack exports.
    let registrationSymbol: String?
    /// Save-data folder name; defaults to the title ID.
    let saveNamespace: String?
    /// The AOT dylib: name, optional size and SHA-256.
    let pack: GameFileInfo?
    /// The game data: name, optional size and SHA-256.
    let rom: GameFileInfo?
    /// Optional cover image, relative to the game's folder.
    let cover: String?
    /// Free-form launcher identity, e.g. "3ds2apple-launcher-macos/0.1.0".
    let launcherVersion: String?
    /// Informational push timestamp (ISO 8601, UTC).
    let pushedAt: String?
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case titleID
        case displayName
        case productCode
        case aot
        case aotVersion
        case packABIVersion
        case registrationSymbol
        case saveNamespace
        case pack
        case rom
        case cover
        case launcherVersion
        case pushedAt
        case notes
    }

    init(schemaVersion: Int? = GameInfo.supportedSchemaVersion,
         titleID: String? = nil,
         displayName: String? = nil,
         productCode: String? = nil,
         aot: Bool? = true,
         aotVersion: Int? = nil,
         packABIVersion: Int? = nil,
         registrationSymbol: String? = nil,
         saveNamespace: String? = nil,
         pack: GameFileInfo? = nil,
         rom: GameFileInfo? = nil,
         cover: String? = nil,
         launcherVersion: String? = nil,
         pushedAt: String? = nil,
         notes: String? = nil) {
        self.schemaVersion = schemaVersion
        self.titleID = titleID
        self.displayName = displayName
        self.productCode = productCode
        self.aot = aot
        self.aotVersion = aotVersion
        self.packABIVersion = packABIVersion
        self.registrationSymbol = registrationSymbol
        self.saveNamespace = saveNamespace
        self.pack = pack
        self.rom = rom
        self.cover = cover
        self.launcherVersion = launcherVersion
        self.pushedAt = pushedAt
        self.notes = notes
    }

    /// Reads and decodes a manifest. Throws with a user-facing description when
    /// the file cannot be read or is not valid schema-1 JSON.
    static func load(from url: URL, maxBytes: Int = 1 << 20) throws -> GameInfo {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maxBytes {
            throw GameInfoError.unreadable(
                L10n.format("the manifest is %ld bytes (limit %ld)", size, maxBytes)
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GameInfoError.unreadable(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(GameInfo.self, from: data)
        } catch {
            throw GameInfoError.unreadable(error.localizedDescription)
        }
    }

    /// Trimmed display name as the launcher wrote it, nil when empty.
    var trimmedDisplayName: String? {
        guard let displayName else { return nil }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Why GameInfo.json could not be used; the message is user-facing.
enum GameInfoError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return detail
        }
    }
}
