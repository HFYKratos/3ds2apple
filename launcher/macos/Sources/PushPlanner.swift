//
//  PushPlanner.swift
//  3ds2apple macOS launcher
//
//  Documents push plan for the corrected architecture. Only game data goes into
//  the app container; the AOT pack lives in the signed IPA:
//
//      Documents/Games/<TITLEID>/GameRom.cci     (the player's ROM data)
//      Documents/Games/<TITLEID>/GameInfo.json   (ROM manifest, pushed LAST)
//      Documents/Games/<TITLEID>/cover.png       (optional)
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
        stagingDirectory: URL
    ) throws -> PushPlan {
        let remoteDirectory = "Documents/Games/" + game.titleID.uppercased()

        guard let romPath = resolveROMDataPath(for: game) else {
            throw LauncherFailure(
                code: "rom_data_missing",
                message: "Game data for " + game.displayName + " has not been staged for pushing.",
                hint: "Re-import the ROM: the launcher keeps a gitignored copy in out/launcher-roms for the device push.",
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

        let manifestOutput = GameInfoWriter.makeManifest(
            package: manifest,
            romFile: romFile,
            romBytes: romBytes,
            romSha256: romSha
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
