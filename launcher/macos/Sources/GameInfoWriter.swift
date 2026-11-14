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

import Foundation

enum GameInfoWriter {
    static let shellSchemaVersion = 1
    static let launcherVersion = "0.1.0"

    struct Output {
        var json: [String: Any]
        var data: Data
    }

    static func makeManifest(
        package: PackageManifest,
        romFile: String,
        romBytes: Int64,
        romSha256: String,
        fileSharingRequired: Bool = true,
        date: Date = Date()
    ) -> Output {
        var json: [String: Any] = [
            "schemaVersion": shellSchemaVersion,
            "titleID": package.titleID.uppercased(),
            "displayName": package.displayName,
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
