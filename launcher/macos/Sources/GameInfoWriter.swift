//
//  GameInfoWriter.swift
//  3ds2apple macOS launcher
//
//  Corrected launcher-first architecture (2026-11-14): iOS never dlopens code
//  copied into the app container, so per-game AOT code stays inside the signed
//  library IPA (Frameworks/GamePack-<TITLEID>.dylib + bundle GameCatalog).
//  Documents only receives the player's ROM data and this ROM-oriented manifest:
//
//      Documents/Games/<TITLEID>/GameInfo.json   (pushed last)
//      Documents/Games/<TITLEID>/GameRom.cci
//
//  GameInfo.json keeps titleID/displayName/productCode/saveNamespace and
//  rom{file,size,sha256}; the pack object is informational only (the shell loads
//  the bundle pack from the catalogue) but is included for compatibility with
//  shells that use it to show which AOT pack belongs to the game.
//
//  Since 0.1.1 the same single writer also records the SMDH base metadata the
//  launcher already read at import time, so the iOS library card needs no ROM
//  parsing: displayName is the SMDH title for the app language
//  (GameNames.resolve, English fallback), displayNames keeps every original
//  localized title, publisher/region are optional, and cover is the pushed
//  "cover.png" file name (local user data, never committed). schemaVersion stays
//  1; every added field is optional and older shells ignore unknown keys.
//

import Foundation

enum GameInfoWriter {
    static let shellSchemaVersion = 1
    static let launcherVersion = "0.2.1-beta2"

    struct Output {
        var json: [String: Any]
        var data: Data
    }

    static func makeManifest(
        package: PackageManifest,
        romFile: String,
        romBytes: Int64,
        romSha256: String,
        coverFile: String? = nil,
        uiLanguageTag: String? = nil,
        fileSharingRequired: Bool = true,
        date: Date = Date()
    ) -> Output {
        // `displayName` is the title for the app's own UI language; the full
        // SMDH map goes along so the phone can pick its own language.
        let displayName = GameNames.resolve(
            displayNames: package.displayNames,
            displayName: package.displayName,
            uiLanguageTag: uiLanguageTag
        )
        var json: [String: Any] = [
            "schemaVersion": shellSchemaVersion,
            "titleID": package.titleID.uppercased(),
            "displayName": displayName,
            "productCode": package.productCode,
            "aot": true,
            "aotVersion": package.aotVersion,
            "packABIVersion": 1,
            "registrationSymbol": "zk_gamepack_register",
            "packInBundle": true,
            "saveNamespace": package.saveNamespace.isEmpty ? package.titleID : package.saveNamespace,
            "launcherVersion": launcherVersion,
            "pushedAt": iso8601(date),
            "notes": "",
        ]
        if !package.displayNames.isEmpty {
            json["displayNames"] = package.displayNames
        }
        let publisher = GameNames.resolvePublisher(package.publisher)
        if !publisher.isEmpty {
            json["publisher"] = publisher
        }
        let region = package.region.trimmingCharacters(in: .whitespacesAndNewlines)
        if !region.isEmpty {
            json["region"] = region
        }
        // Only the fixed pushed file name is ever recorded; a path (absolute or
        // relative with directories) is never written into the shell manifest.
        if let coverFile, coverFile == "cover.png" {
            json["cover"] = coverFile
        }
        if !romFile.isEmpty {
            var rom: [String: Any] = ["file": romFile]
            if romBytes > 0 { rom["size"] = romBytes }
            if !romSha256.isEmpty { rom["sha256"] = romSha256 }
            json["rom"] = rom
        }
        if let packFile = package.packFile, !packFile.isEmpty {
            var pack: [String: Any] = ["file": "Frameworks/GamePack-" + package.titleID.uppercased() + ".dylib"]
            if let bytes = package.packBytes { pack["size"] = bytes }
            if let sha = package.packSha256 { pack["sha256"] = sha }
            pack["inBundle"] = true
            pack["sourceFile"] = packFile
            json["pack"] = pack
        }
        if fileSharingRequired {
            json["requiresFileSharing"] = true
        }
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
        return Output(json: json, data: data)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
