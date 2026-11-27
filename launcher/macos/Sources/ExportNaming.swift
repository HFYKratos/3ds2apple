//
//  ExportNaming.swift
//  3ds2apple macOS launcher
//
//  0.2.2-beta4: both Library exports use the same base name
//  TITLE_ID-English game name.<32a|ipa> (no slug/version/"unsigned"), and the
//  single-game IPA renames the installed app: CFBundleDisplayName/CFBundleName
//  = the English game name, plus <lang>.lproj/InfoPlist.strings for every
//  GameInfo.displayNames language so a Chinese device shows the Chinese title.
//  A game imported from a .32a stores the package in romPath; GameRomResolver
//  reads the embedded GameRom copy for the IPA export and the Documents push.
//

import Foundation

enum GameFileNaming {
    static let maxNameBytes = 120

    /// Invalid characters on macOS/Windows become '_'; trailing dots/spaces are
    /// trimmed; the name is capped at 120 UTF-8 bytes; empty falls back to "game".
    static func sanitize(_ name: String) -> String {
        let invalid: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
        var cleaned = ""
        var bytes = 0
        for character in name.trimmingCharacters(in: .whitespacesAndNewlines) {
            let value: Character = character.unicodeScalars.contains(where: { $0.value < 0x20 }) ? "_" : character
            let mapped: Character = invalid.contains(value) ? "_" : value
            let added = String(mapped).utf8.count
            if bytes + added > maxNameBytes {
                break
            }
            bytes += added
            cleaned.append(mapped)
        }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "game" : trimmed
    }

    static func baseName(displayName: String, titleID: String) -> String {
        titleID.trimmingCharacters(in: .whitespaces).uppercased() + "-" + sanitize(displayName)
    }

    static func ipaFileName(displayName: String, titleID: String) -> String {
        baseName(displayName: displayName, titleID: titleID) + ".ipa"
    }

    static func buildPackageFileName(displayName: String, titleID: String) -> String {
        baseName(displayName: displayName, titleID: titleID) + ".32a"
    }
}

enum AppDisplayNameRewriter {
    static let infoPlistName = "Info.plist"
    static let infoPlistStringsName = "InfoPlist.strings"
    private static let languagePattern = try! NSRegularExpression(pattern: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")

    static func normalizeLanguage(_ key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        let language = key.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        if language.caseInsensitiveCompare("Base") == .orderedSame { return nil }
        let range = NSRange(location: 0, length: language.utf16.count)
        guard languagePattern.firstMatch(in: language, options: [], range: range) != nil else { return nil }
        var parts = language.split(separator: "-")
        guard let first = parts.first else { return nil }
        let head = first.lowercased()
        parts.removeFirst()
        return parts.isEmpty ? head : ([head] + parts.map(String.init)).joined(separator: "-")
    }

    /// "en" first (English fallback), then every valid displayNames language.
    static func localizedNames(displayName: String, displayNames: [String: String]?) -> [(language: String, name: String)] {
        var names: [(language: String, name: String)] = [(language: "en", name: displayName)]
        var seen: Set<String> = ["en"]
        for (key, value) in (displayNames ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty,
                  let language = normalizeLanguage(key),
                  !seen.contains(language) else { continue }
            seen.insert(language)
            names.append((language: language, name: value.trimmingCharacters(in: .whitespaces)))
        }
        return names
    }

    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Rewrite Payload/<app>/Info.plist (CFBundleDisplayName + CFBundleName) and
    /// write <lang>.lproj/InfoPlist.strings for every localized SMDH title.
    static func rewrite(appRoot: String, displayName: String, displayNames: [String: String]?) throws {
        let fileManager = FileManager.default
        let plistPath = (appRoot as NSString).appendingPathComponent(infoPlistName)
        let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw LauncherFailure(
                code: "template_invalid",
                message: "The shell app Info.plist is not a dictionary.",
                hint: "Rebuild the pinned shell template from the current main.",
                detail: plistPath,
                exitCode: nil
            )
        }
        plist["CFBundleDisplayName"] = displayName
        plist["CFBundleName"] = displayName
        let rewritten = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try rewritten.write(to: URL(fileURLWithPath: plistPath), options: .atomic)

        for (language, name) in localizedNames(displayName: displayName, displayNames: displayNames) {
            let directory = (appRoot as NSString).appendingPathComponent(language + ".lproj")
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let text = "\"CFBundleDisplayName\" = \"" + escaped(name) + "\";\n"
            try text.write(toFile: (directory as NSString).appendingPathComponent(infoPlistStringsName),
                           atomically: true, encoding: .utf8)
        }
    }
}

enum GameRomResolver {
    static let romExtensions = ["cci", "3ds", "ncch", "cxi"]
    static let buildPackageExtension = "32a"
    static let gameRomPrefix = "GameRom"

    static func isBuildPackage(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == buildPackageExtension
    }

    static func isROM(_ path: String) -> Bool {
        romExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func findPackageRom(packageDirectory: String?) -> String? {
        guard let packageDirectory, !packageDirectory.isEmpty else { return nil }
        for extensionName in romExtensions {
            let candidate = (packageDirectory as NSString)
                .appendingPathComponent(gameRomPrefix + "." + extensionName)
            if FileProbe.exists(candidate), (FileProbe.size(candidate) ?? 0) > 0 {
                return candidate
            }
        }
        return nil
    }

    /// Resolve the ROM for the IPA export / Documents push. Plain ROM paths keep
    /// working; a .32a-imported game falls back to the package's GameRom copy, then
    /// to the GameRom entry inside the .32a (extracted into the launcher cache).
    static func resolve(romPath: String, packageDirectory: String?, cacheDirectory: String) -> (path: String, error: String?) {
        if !romPath.isEmpty, FileProbe.exists(romPath), isROM(romPath) {
            return (romPath, nil)
        }
        if let packaged = findPackageRom(packageDirectory: packageDirectory) {
            return (packaged, nil)
        }
        if !romPath.isEmpty, FileProbe.exists(romPath), isBuildPackage(romPath) {
            return extractGameRom(from: romPath, cacheDirectory: cacheDirectory)
        }
        return ("", "The game's ROM is missing. Import the ROM again (or re-import a .32a that contains game data) and retry.")
    }

    static func extractGameRom(from packagePath: String, cacheDirectory: String) -> (path: String, error: String?) {
        let fileManager = FileManager.default
        let staging = (cacheDirectory as NSString)
            .appendingPathComponent("extract-" + String(UUID().uuidString.prefix(8)))
        do {
            try fileManager.createDirectory(atPath: staging, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(atPath: staging) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-q", "-o", packagePath, "-d", staging]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return ("", "The .32a " + (packagePath as NSString).lastPathComponent + " could not be read. Import a .32a that includes game data or add the original ROM.")
            }
            let rootCache = cacheDirectory
            for extensionName in romExtensions {
                let candidate = (staging as NSString).appendingPathComponent(gameRomPrefix + "." + extensionName)
                if FileProbe.exists(candidate), (FileProbe.size(candidate) ?? 0) > 0 {
                    try fileManager.createDirectory(atPath: rootCache, withIntermediateDirectories: true)
                    let destination = (rootCache as NSString).appendingPathComponent(gameRomPrefix + "." + extensionName)
                    if FileProbe.exists(destination) {
                        try? fileManager.removeItem(atPath: destination)
                    }
                    try fileManager.moveItem(atPath: candidate, toPath: destination)
                    return (destination, nil)
                }
            }
            return ("", "The .32a " + (packagePath as NSString).lastPathComponent
                + " does not contain game data (no GameRom entry), so the single-game IPA/deploy cannot read the ROM. "
                + "Import a .32a that includes game data or add the original ROM.")
        } catch {
            return ("", "The .32a could not be read: " + error.localizedDescription)
        }
    }
}
