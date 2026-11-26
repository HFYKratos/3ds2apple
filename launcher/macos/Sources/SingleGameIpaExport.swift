//
//  SingleGameIpaExport.swift
//  3ds2apple macOS launcher
//
//  Library "Export IPA": one unsigned single-game IPA composed from the pinned
//  shell template. The template is unpacked (unzip), the game's GamePack, its own
//  ROM (Roms/<TITLEID>.<ext>) and a single-game GameCatalog.json with autoLaunch +
//  romFile are written into the app bundle, the template AppIcon*.png files are
//  replaced with the ROM's SMDH cover (NSImage), and the result is zipped back
//  with ditto. Nothing is signed, installed or uploaded; the user signs it with
//  Sideloadly/AltStore. The IPA contains the user's own game data, so it stays in
//  the local portable workspace and must never be uploaded or shared.
//

import AppKit
import CryptoKit
import Foundation

/// Result of one unsigned single-game IPA export.
struct SingleGameIpaExportResult: Equatable {
    var ipaPath: String
    var sha256: String
    var bytes: Int64
    var replacedIcons: Int
    var warnings: [String]
    /// Size of the embedded game data (the user's own ROM).
    var romBytes: Int64 = 0
    /// Bundle-relative path of the embedded data (Roms/<TITLEID>.<ext>).
    var romRelativePath: String = ""
}

/// Composes the unsigned single-game IPA on this Mac. The launcher only
/// orchestrates unzip/ditto and NSImage; the pack CLI writes the catalogue.
final class SingleGameIpaExporter {
    private let runner: CommandRunning
    private let fileManager = FileManager.default

    init(runner: CommandRunning) {
        self.runner = runner
    }

    /// "<build-slug>-<titleid last 8>-<version>-unsigned.ipa", all ASCII.
    static func outputFileName(displayName: String, titleID: String, version: String) -> String {
        let suffix = String(titleID.suffix(8)).lowercased()
        var slug = ""
        for character in displayName.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
            } else if slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        if slug.isEmpty {
            slug = "game"
        }
        let safeVersion = version.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        return slug + "-" + suffix + "-" + (safeVersion.isEmpty ? "0.0.0" : safeVersion) + "-unsigned.ipa"
    }

    /// ROM extensions the runtime boots and the builder catalogue accepts.
    static let romExtensions = ["cci", "3ds", "ncch", "cxi"]

    /// Canonical bundle-relative ROM path: Roms/<TITLEID>.<lowercase ext>.
    static func romRelativePath(titleID: String, extensionName: String) -> String {
        "Roms/" + titleID.uppercased() + "." + extensionName.lowercased()
    }

    func export(
        shellTemplateIpaPath: String,
        packPath: String,
        titleID: String,
        displayName: String,
        coverPath: String?,
        romPath: String,
        version: String,
        outputDirectory: String,
        outputFileName: String? = nil,
        writeCatalog: (String, String) async throws -> Void,
        onLine: @escaping (LogLevel, String) -> Void
    ) async throws -> SingleGameIpaExportResult {
        if !fileManager.fileExists(atPath: shellTemplateIpaPath) {
            throw LauncherFailure(
                code: "shell_missing",
                message: "The pinned shell template IPA is missing.",
                hint: "Rebuild the shell on this Mac or reinstall the launcher package.",
                detail: shellTemplateIpaPath,
                exitCode: nil
            )
        }
        if !fileManager.fileExists(atPath: packPath) {
            throw LauncherFailure(
                code: "pack_missing",
                message: "The GamePack for " + titleID + " is missing.",
                hint: "Build the game before exporting an IPA.",
                detail: packPath,
                exitCode: nil
            )
        }
        let romExtension = (romPath as NSString).pathExtension.lowercased()
        if !fileManager.fileExists(atPath: romPath) {
            throw LauncherFailure(
                code: "rom_missing",
                message: "The game's ROM is missing: " + (romPath.isEmpty ? "(no ROM path recorded)" : romPath),
                hint: "The single-game IPA embeds the game data, so import/re-add the ROM (or restore its file) and export again.",
                detail: romPath,
                exitCode: nil
            )
        }
        if !Self.romExtensions.contains(romExtension) {
            throw LauncherFailure(
                code: "rom_unsupported",
                message: "Cannot embed " + (romPath as NSString).lastPathComponent + ": only ." + Self.romExtensions.joined(separator: "/.") + " ROMs are supported.",
                hint: "Use the decrypted .3ds/.cci you imported, or export the .32a build package instead.",
                detail: romPath,
                exitCode: nil
            )
        }
        let romRelative = Self.romRelativePath(titleID: titleID, extensionName: romExtension)
        let romAttributes = try? fileManager.attributesOfItem(atPath: romPath)
        let romBytes = (romAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        try? fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let staging = (outputDirectory as NSString)
            .appendingPathComponent(".single-game-" + String(UUID().uuidString.prefix(8)))
        try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(atPath: staging) }

        let templateRoot = (staging as NSString).appendingPathComponent("template")
        try fileManager.createDirectory(atPath: templateRoot, withIntermediateDirectories: true)
        onLine(.command, "unzip -q -o " + shellTemplateIpaPath)
        let unzip = try await run("/usr/bin/unzip", ["-q", "-o", shellTemplateIpaPath, "-d", templateRoot], workingDirectory: nil)
        if !unzip.succeeded {
            throw LauncherFailure(
                code: "template_unzip_failed",
                message: "Could not unpack the shell template IPA.",
                hint: "Rebuild the pinned shell template on this Mac.",
                detail: unzip.combined,
                exitCode: unzip.exitCode
            )
        }
        let payload = (templateRoot as NSString).appendingPathComponent("Payload")
        let payloadNames = (try? fileManager.contentsOfDirectory(atPath: payload)) ?? []
        guard let appName = payloadNames.first(where: { $0.hasSuffix(".app") }) else {
            throw LauncherFailure(
                code: "template_invalid",
                message: "The shell template has no Payload/*.app bundle.",
                hint: "Rebuild the pinned shell template from the current main.",
                detail: payload,
                exitCode: nil
            )
        }
        let appRoot = (payload as NSString).appendingPathComponent(appName)
        if !fileManager.fileExists(atPath: (appRoot as NSString).appendingPathComponent("Info.plist")) {
            throw LauncherFailure(
                code: "template_invalid",
                message: "The shell app bundle has no Info.plist.",
                hint: "Rebuild the pinned shell template from the current main.",
                detail: appRoot,
                exitCode: nil
            )
        }

        let frameworks = (appRoot as NSString).appendingPathComponent("Frameworks")
        try? fileManager.createDirectory(atPath: frameworks, withIntermediateDirectories: true)
        let packDestination = (frameworks as NSString).appendingPathComponent("GamePack-" + titleID + ".dylib")
        if fileManager.fileExists(atPath: packDestination) {
            try? fileManager.removeItem(atPath: packDestination)
        }
        try fileManager.copyItem(atPath: packPath, toPath: packDestination)

        // Embed the user's own game data: exactly one canonical Roms entry. The
        // template itself is ROM-free, so a stale Roms/ directory (if any) is
        // replaced; the resulting IPA is intentionally NOT ROM-free.
        let roms = (appRoot as NSString).appendingPathComponent("Roms")
        if fileManager.fileExists(atPath: roms) {
            try? fileManager.removeItem(atPath: roms)
        }
        try fileManager.createDirectory(atPath: roms, withIntermediateDirectories: true)
        let embeddedRom = (appRoot as NSString).appendingPathComponent(romRelative)
        if fileManager.fileExists(atPath: embeddedRom) {
            try? fileManager.removeItem(atPath: embeddedRom)
        }
        try fileManager.copyItem(atPath: romPath, toPath: embeddedRom)

        let catalogPath = (appRoot as NSString).appendingPathComponent("GameCatalog.json")
        try await writeCatalog(catalogPath, romRelative)
        guard let catalogData = try? Data(contentsOf: URL(fileURLWithPath: catalogPath)),
              let catalogObject = (try? JSONSerialization.jsonObject(with: catalogData)) as? [String: Any],
              (catalogObject["autoLaunch"] as? Bool) == true,
              let catalogGames = catalogObject["games"] as? [[String: Any]],
              catalogGames.count == 1,
              (catalogGames[0]["romFile"] as? String) == romRelative else {
            throw LauncherFailure(
                code: "catalog_invalid",
                message: "The single-game GameCatalog.json is missing autoLaunch or the embedded romFile.",
                hint: "Update 3ds2apple-pack / the launcher; this is a tool mismatch.",
                detail: catalogPath,
                exitCode: nil
            )
        }

        var warnings: [String] = []
        var replacedIcons = 0
        if let coverPath, fileManager.fileExists(atPath: coverPath), let cover = NSImage(contentsOfFile: coverPath) {
            let names = (try? fileManager.contentsOfDirectory(atPath: appRoot)) ?? []
            for name in names where name.hasPrefix("AppIcon") && name.hasSuffix(".png") {
                let path = (appRoot as NSString).appendingPathComponent(name)
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let template = NSBitmapImageRep(data: data),
                      template.pixelsWide > 0, template.pixelsHigh > 0 else {
                    continue
                }
                let width = template.pixelsWide
                let height = template.pixelsHigh
                guard let icon = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: width,
                    pixelsHigh: height,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ), let context = NSGraphicsContext(bitmapImageRep: icon) else {
                    continue
                }
                icon.size = NSSize(width: width, height: height)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                cover.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                guard let png = icon.representation(using: .png, properties: [:]) else {
                    continue
                }
                if (try? png.write(to: URL(fileURLWithPath: path))) != nil {
                    replacedIcons += 1
                }
            }
            if replacedIcons == 0 {
                warnings.append("The template AppIcon*.png files could not be replaced; the template icons were kept.")
            }
        } else {
            warnings.append("The game has no readable SMDH cover (cover.png); the template app icon was kept.")
        }

        // Structure gate before zipping: exactly one non-empty embedded game-data
        // file, named exactly as the catalogue says.
        let romEntries = ((try? fileManager.contentsOfDirectory(atPath: roms)) ?? [])
            .filter { $0 == (romRelative as NSString).lastPathComponent }
        if romEntries.count != 1 {
            throw LauncherFailure(
                code: "rom_embed_failed",
                message: "The single-game IPA must contain exactly one embedded game-data file.",
                hint: "This is a launcher bug; retry the export and include the log when reporting.",
                detail: romRelative,
                exitCode: nil
            )
        }
        let embeddedAttributes = try? fileManager.attributesOfItem(atPath: embeddedRom)
        let embeddedBytes = (embeddedAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        if embeddedBytes <= 0 || embeddedBytes != romBytes {
            throw LauncherFailure(
                code: "rom_embed_failed",
                message: "The embedded game data is incomplete (" + String(embeddedBytes) + " of " + String(romBytes) + " bytes).",
                hint: "Check free disk space in the portable data folder and retry.",
                detail: embeddedRom,
                exitCode: nil
            )
        }
        warnings.append("This IPA contains your own game data (" + romRelative + ", "
            + FileProbe.formatBytes(romBytes) + "). Keep it local, never upload or share it, and sign it yourself (Sideloadly/AltStore).")

        let defaultName = Self.outputFileName(displayName: displayName, titleID: titleID, version: version)
        let fileName = (outputFileName?.isEmpty == false) ? outputFileName! : defaultName
        if !fileName.lowercased().hasSuffix(".ipa") {
            throw LauncherFailure(
                code: "ipa_name_invalid",
                message: "The IPA file name must end with .ipa (got " + fileName + ").",
                hint: "Choose a file name ending in .ipa in the export dialog.",
                detail: outputDirectory,
                exitCode: nil
            )
        }
        let outputPath = (outputDirectory as NSString).appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: outputPath) {
            try? fileManager.removeItem(atPath: outputPath)
        }
        onLine(.command, "ditto -c -k --sequesterRsrc --keepParent Payload " + outputPath)
        let zip = try await run(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", "Payload", outputPath],
            workingDirectory: templateRoot
        )
        if !zip.succeeded || !fileManager.fileExists(atPath: outputPath) {
            throw LauncherFailure(
                code: "ipa_zip_failed",
                message: "Could not zip the single-game IPA.",
                hint: "Check that ditto can run from the launcher.",
                detail: zip.combined,
                exitCode: zip.exitCode
            )
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        onLine(.success, "single-game IPA: " + outputPath + " (" + FileProbe.formatBytes(Int64(data.count))
            + ", sha256 " + sha + ", " + String(replacedIcons) + " icon(s), embedded game data "
            + romRelative + " " + FileProbe.formatBytes(romBytes) + ") - contains the user's own game data; keep it local, sign it yourself")
        return SingleGameIpaExportResult(
            ipaPath: outputPath,
            sha256: sha,
            bytes: Int64(data.count),
            replacedIcons: replacedIcons,
            warnings: warnings,
            romBytes: romBytes,
            romRelativePath: romRelative
        )
    }

    private func run(_ executable: String, _ arguments: [String], workingDirectory: String?) async throws -> CommandResult {
        let spec = CommandSpec(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
        return try await runner.run(spec, onLine: nil)
    }
}
