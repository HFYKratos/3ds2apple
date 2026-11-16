//
//  PushPlanner.swift
//  3ds2apple macOS launcher
//
//  Documents push plan for the corrected architecture. Only game data goes into
//  the app container; the AOT pack lives in the signed IPA:
//
//      Documents/Games/<TITLEID>/GameRom.cci     (the player's ROM data)
//      Documents/Games/<TITLEID>/cover.png       (optional SMDH/user cover)
//      Documents/Games/<TITLEID>/GameInfo.json   (ROM manifest, pushed LAST)
//
//  cover.png is the icon the desktop launcher already extracted for its own
//  Library; it is local user data, pushed next to the ROM and referenced by the
//  manifest (never committed, never decoded on the phone).
//
//  The ROM data source is the launcher's gitignored copy in
//  out/launcher-roms/<TITLEID>.<ext>; the desktop package stays ROM-free.
//

import Foundation

struct PushPlanner {
    let outRoot: URL
    let bundleID: String

    static let defaultROMFileName = "GameRom.cci"
    static let gameInfoFileName = "GameInfo.json"
    static let coverFileName = "cover.png"
    static let romExtensions = ["cci", "3ds", "ncch", "cxi", "app"]

    func plan(
        game: GameEntry,
        manifest: PackageManifest,
        device: DeviceInfo?,
        stagingDirectory: URL,
        uiLanguageTag: String? = nil
    ) throws -> PushPlan {
        let remoteDirectory = "Documents/Games/" + game.titleID.uppercased()

        guard let romPath = resolveROMDataPath(for: game) else {
            throw LauncherFailure(
                code: "rom_data_missing",
                message: "Game data for " + game.displayName + " has not been staged for pushing.",
                hint: "Re-import the ROM from the Library; the launcher keeps a gitignored copy in out/launcher-roms for the device push.",
                detail: "out/launcher-roms/" + game.titleID,
                exitCode: nil
            )
        }
        let romFile = "GameRom." + (romPath as NSString).pathExtension.lowercased()
        let romBytes = FileProbe.size(romPath) ?? game.romBytes
        let romSha = game.romSha256 ?? FileProbe.sha256(ofFile: romPath) ?? ""
        var files: [PushFile] = []
        files.append(PushFile(
            name: romFile,
            localPath: romPath,
            remotePath: remoteDirectory + "/" + romFile,
            bytes: romBytes,
            sha256: romSha,
            state: .pending,
            progress: 0
        ))

        // The cover is the package's SMDH icon (or a user cover). Resolve it
        // against the package directory first, then use the absolute path the
        // Library card already resolved; a missing cover is not an error.
        let packageDirectory = outRoot
            .appendingPathComponent("packages/" + game.titleID.uppercased()).path
        let coverPath = GameNames.resolveCoverPath(
            packageDirectory: packageDirectory,
            coverPath: manifest.coverPath
        ) ?? game.coverPath.flatMap { FileProbe.exists($0) ? $0 : nil }
        let coverName = coverPath == nil ? nil : PushPlanner.coverFileName

        let manifestOutput = GameInfoWriter.makeManifest(
            package: manifest,
            romFile: romFile,
            romBytes: romBytes,
            romSha256: romSha,
            coverFile: coverName,
            uiLanguageTag: uiLanguageTag
        )
        let staging = stagingDirectory.appendingPathComponent(game.titleID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let infoPath = staging.appendingPathComponent(PushPlanner.gameInfoFileName)
        do {
            try manifestOutput.data.write(to: infoPath)
        } catch {
            throw LauncherFailure(
                code: "manifest_write_failed",
                message: "Could not write the shell manifest for " + game.displayName + ".",
                hint: "Check free disk space and that the output directory is writable.",
                detail: error.localizedDescription,
                exitCode: nil
            )
        }
        if let coverPath, let coverBytes = FileProbe.size(coverPath), coverBytes > 0 {
            files.append(PushFile(
                name: PushPlanner.coverFileName,
                localPath: coverPath,
                remotePath: remoteDirectory + "/" + PushPlanner.coverFileName,
                bytes: coverBytes,
                sha256: FileProbe.sha256(ofFile: coverPath) ?? "",
                state: .pending,
                progress: 0
            ))
        }
        files.append(PushFile(
            name: PushPlanner.gameInfoFileName,
            localPath: infoPath.path,
            remotePath: remoteDirectory + "/" + PushPlanner.gameInfoFileName,
            bytes: Int64(manifestOutput.data.count),
            sha256: FileProbe.sha256(ofFile: infoPath.path) ?? "",
            state: .pending,
            progress: 0
        ))

        return PushPlan(
            titleID: game.titleID.uppercased(),
            displayName: game.displayName,
            bundleID: bundleID,
            deviceUDID: device?.udid,
            deviceName: device.map { $0.name + "  (" + $0.model + ", iOS " + $0.iosVersion + ")" } ?? "No device selected",
            remoteDirectory: remoteDirectory,
            files: files,
            verified: false,
            verifiedAt: nil
        )
    }

    static func remoteDirectory(for titleID: String) -> String {
        "Documents/Games/" + titleID.uppercased()
    }

    static func isManifest(_ file: PushFile) -> Bool {
        file.name == gameInfoFileName
    }

    /// Find the launcher's staged ROM copy for a game (explicit field first, then
    /// any known extension in out/launcher-roms).
    func resolveROMDataPath(for game: GameEntry) -> String? {
        if let explicit = game.romDataPath, FileProbe.exists(explicit), FileProbe.size(explicit) ?? 0 > 0 {
            return explicit
        }
        let root = outRoot.appendingPathComponent("launcher-roms")
        for ext in PushPlanner.romExtensions {
            let candidate = root.appendingPathComponent(game.titleID + "." + ext)
            if FileProbe.exists(candidate.path), (FileProbe.size(candidate.path) ?? 0) > 0 {
                return candidate.path
            }
        }
        return nil
    }
}
