//
//  SelfCheckCore.swift
//  3ds2apple macOS launcher
//
//  Self-check part 1: CLI arguments, checkout detection, the desktop CLI JSON
//  contract, the shell GameInfo mapping, push-plan ordering/bundle-id use, the
//  library-IPA inspection rules, Team ID detection and the devpush NDJSON
//  contract v1. Everything is headless logic; no ROM, phone or Apple ID.
//

import Foundation

@MainActor
enum SelfCheckCore {
    static func checks() async -> [SelfCheck.Check] {
        var checks: [SelfCheck.Check] = []
        func expect(_ name: String, _ condition: Bool, _ detail: String = "") {
            checks.append(SelfCheck.Check(name: name, passed: condition, detail: condition ? "" : detail))
        }

        // 1. CLI argument parsing
        if case .app = LauncherCLI.parse(arguments: ["launcher"], environment: [:]) {
            expect("launcher args: default app mode", true)
        } else {
            expect("launcher args: default app mode", false)
        }
        if case .selfCheck = LauncherCLI.parse(arguments: ["launcher", "--selfcheck"], environment: [:]) {
            expect("launcher args: --selfcheck", true)
        } else {
            expect("launcher args: --selfcheck", false)
        }
        if case .screenshots(let directory, let theme, let language) = LauncherCLI.parse(
            arguments: ["launcher", "--screenshot-dir", "/tmp/shots", "--theme", "light"],
            environment: [:]
        ) {
            expect("launcher args: --screenshot-dir and theme", directory == "/tmp/shots" && theme == "light" && language == "all")
        } else {
            expect("launcher args: --screenshot-dir and theme", false)
        }
        if case .screenshots(let directory, _, let language) = LauncherCLI.parse(
            arguments: ["launcher", "--screenshot-dir", "/tmp/shots", "--lang", "zh"],
            environment: [:]
        ) {
            expect("launcher args: --lang override", directory == "/tmp/shots" && language == "zh")
        } else {
            expect("launcher args: --lang override", false)
        }

        // 2. Repository detection
        expect("settings: rejects a non-repo directory", !SettingsDefaults.isRepoRoot("/tmp/definitely-not-3ds2apple"))
        let repo = ProcessInfo.processInfo.environment["THREEDS2APPLE_ROOT"]
            ?? SettingsDefaults.detectRepoRoot()
        expect("settings: detects the 3ds2apple checkout", SettingsDefaults.isRepoRoot(repo), "detected " + repo)

        // 3. ROM inspector JSON
        let romJSON = """
        {"roms":[{"path":"/Users/you/ROM/Pokemon Y.cci","container":"ncsd","titleID":"0004000000055E00","productCode":"CTR-P-EK2A","displayName":"Pokemon Y","bytes":1807118336,"contentBytes":1446201088,"titleVersion":0}],"errors":[]}
        """
        let roms = PackJSON.parseROMs(Data(romJSON.utf8))
        expect("pack JSON: rom inspect parses title", roms.roms.first?.titleID == "0004000000055E00", String(describing: roms.roms.first))
        expect("pack JSON: rom inspect parses size and container", roms.roms.first?.bytes == 1_807_118_336 && roms.roms.first?.container == "ncsd")
        let badROMsJSON = """
        {"roms":[],"errors":[{"path":"/tmp/x.cia","error":"not a decrypted ROM"}]}
        """
        let badROMs = PackJSON.parseROMs(Data(badROMsJSON.utf8))
        expect("pack JSON: rom inspect reports errors", badROMs.errors.count == 1 && badROMs.roms.isEmpty)

        // 4. Package list JSON
        let packagesJSON = """
        {"packages":[{"titleID":"0004000000055E00","displayName":"Pokemon Y","productCode":"CTR-P-EK2A","aotVersion":1,"state":"built","pack":{"sha256":"92bab7aa","bytes":218103808,"format":"macho"},"issues":[]}],"errors":[]}
        """
        let packages = PackJSON.parsePackages(Data(packagesJSON.utf8))
        expect("pack JSON: packages list parses pack metadata", packages.packages.first?.pack?.format == "macho" && packages.packages.first?.isBuilt == true)
        let queuedJSON = """
        {"packages":[{"titleID":"1","displayName":"x","productCode":"","aotVersion":1,"state":"queued","issues":["pack missing"]}],"errors":[]}
        """
        expect("pack JSON: packages list has no pack while queued", PackJSON.parsePackages(Data(queuedJSON.utf8)).packages.first?.pack == nil)

        // 5. Package manifest parsing
        let manifestJSON = """
        {"schemaVersion":1,"titleID":"0004000000055E00","displayName":"Pokemon Y","productCode":"CTR-P-EK2A","aotVersion":1,"saveNamespace":"0004000000055E00","packFile":"GamePack.dylib","pack":{"sha256":"aa","bytes":1000,"format":"macho"},"rom":{"path":"/Users/you/ROM/x.cci","fileName":"x.cci","bytes":2000},"romFile":"GameRom.cci","romSha256":"bb","romBytes":2000}
        """
        let manifest = PackJSON.parseManifest(Data(manifestJSON.utf8), fallbackTitleID: "fallback")
        expect("pack JSON: manifest parses pack and bundled ROM", manifest?.packSha256 == "aa" && manifest?.romBytes == 2000 && manifest?.romFile == "GameRom.cci")

        // 6. Shell GameInfo mapping (ROM data manifest for the corrected layout)
        if let manifest {
            let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)
            let output = GameInfoWriter.makeManifest(
                package: manifest,
                romFile: "GameRom.cci",
                romBytes: 2000,
                romSha256: "bb",
                date: fixedDate
            )
            let object = PackJSON.object(output.data) ?? [:]
            let pack = object["pack"] as? [String: Any] ?? [:]
            let rom = object["rom"] as? [String: Any] ?? [:]
            expect("shell GameInfo: schemaVersion 1", object["schemaVersion"] as? Int == 1)
            expect("shell GameInfo: title ID upper-case", object["titleID"] as? String == "0004000000055E00")
            expect("shell GameInfo: rom file and sha256", rom["file"] as? String == "GameRom.cci" && rom["sha256"] as? String == "bb")
            expect("shell GameInfo: rom size", rom["size"] as? Int64 == 2000 || rom["size"] as? Int == 2000)
            expect("shell GameInfo: pack object is informational and in the bundle", (pack["inBundle"] as? Bool == true) && (pack["file"] as? String)?.contains("Frameworks/GamePack-") == true)
            expect("shell GameInfo: save namespace", object["saveNamespace"] as? String == "0004000000055E00")
            expect("shell GameInfo: pushedAt ISO-8601", (object["pushedAt"] as? String)?.contains("T") == true)
            expect("shell GameInfo: packInBundle flag", object["packInBundle"] as? Bool == true)
            expect("shell GameInfo: file sharing hint", object["requiresFileSharing"] as? Bool == true)
            expect("shell GameInfo: deterministic output", GameInfoWriter.makeManifest(
                package: manifest,
                romFile: "GameRom.cci",
                romBytes: 2000,
                romSha256: "bb",
                date: fixedDate
            ).data == output.data)
        } else {
            expect("shell GameInfo: fixture manifest parsed", false)
        }

        // 7. Push plan ordering, paths and the ACTUAL installed bundle id
        MockFixtures.ensurePackageTree()
        let fixtures = MockFixtures.games()
        let actualInstalledBundleID = "com.kratos.3ds2apple.installed"
        let planner = PushPlanner(outRoot: MockFixtures.outRoot, bundleID: actualInstalledBundleID)
        if let game = fixtures.first, let fixtureManifest = MockFixtures.manifests()[game.titleID] {
            do {
                let plan = try planner.plan(
                    game: game,
                    manifest: fixtureManifest,
                    device: MockFixtures.devices.first,
                    stagingDirectory: MockFixtures.stagingRoot
                )
                expect("push plan: 2 files (GameRom.cci + GameInfo.json)", plan.files.count == 2, plan.files.map { $0.name }.joined(separator: ","))
                expect("push plan: no dylib in Documents", plan.files.allSatisfy { !$0.name.hasSuffix(".dylib") })
                expect("push plan: GameInfo.json is last", plan.files.last?.name == "GameInfo.json", plan.files.last?.name ?? "nil")
                expect("push plan: remote path uses Documents/Games/TITLEID", plan.files.allSatisfy { $0.remotePath.hasPrefix("Documents/Games/0004000000055E00/") })
                expect("push plan: uses the passed installed bundle id", plan.bundleID == actualInstalledBundleID)
                expect("push plan: bundle id and device recorded", plan.bundleID == actualInstalledBundleID && plan.deviceUDID == MockFixtures.devices.first?.udid)
                expect("push plan: rom hash comes from the staged game data", plan.files[0].sha256 == game.romSha256)
            } catch {
                expect("push plan: fixture plan builds", false, error.localizedDescription)
            }
            do {
                var noData = game
                noData.romDataPath = nil
                noData.titleID = "00040000DEADBEEF"
                _ = try planner.plan(game: noData, manifest: fixtureManifest, device: nil, stagingDirectory: MockFixtures.stagingRoot)
                expect("push plan: rejects a game without staged ROM data", false)
            } catch {
                expect("push plan: rejects a game without staged ROM data", error.launcherFailure().code == "rom_data_missing")
            }
        }

        // 8. Library IPA inspection rules (never install a bare shell / a ROM-full IPA)
        let validInspection = IPAInspection(
            ipaPath: "/tmp/3ds2apple-library.ipa",
            appPath: "/tmp/Payload/3ds2apple.app",
            bundleID: "com.kratos.3ds2apple",
            packFiles: [
                "Frameworks/GamePack-0004000000055E00.dylib",
                "Frameworks/GamePack-0004000000086400.dylib",
            ],
            catalogSchemaVersion: 2,
            catalogTitleIDs: ["0004000000055E00", "0004000000086400"],
            containsBundledROM: false,
            hasMoltenVK: true,
            bytes: 12_345_678
        )
        let expectedTitles = ["0004000000055E00", "0004000000086400"]
        expect("IPA check: valid multi-game payload has no problems", validInspection.problems(expectedTitles: expectedTitles).isEmpty)
        var missingPack = validInspection
        missingPack.packFiles = ["Frameworks/GamePack-0004000000055E00.dylib"]
        expect("IPA check: missing selected GamePack is refused", !missingPack.problems(expectedTitles: expectedTitles).isEmpty)
        var oldCatalog = validInspection
        oldCatalog.catalogSchemaVersion = 1
        expect("IPA check: schema-1 catalogue is refused", !oldCatalog.problems(expectedTitles: expectedTitles).isEmpty)
        var emptyCatalog = validInspection
        emptyCatalog.catalogTitleIDs = []
        expect("IPA check: empty catalogue is refused", !emptyCatalog.problems(expectedTitles: expectedTitles).isEmpty)
        var wrongTitle = validInspection
        wrongTitle.catalogTitleIDs = ["0004000000055E00"]
        expect("IPA check: a selected title missing from the catalogue is refused", !wrongTitle.problems(expectedTitles: expectedTitles).isEmpty)
        var romFull = validInspection
        romFull.containsBundledROM = true
        expect("IPA check: bundled ROM data is refused (ROM-free rule)", !romFull.problems(expectedTitles: expectedTitles).isEmpty)
        var noBundle = validInspection
        noBundle.bundleID = ""
        expect("IPA check: app without CFBundleIdentifier is refused", !noBundle.problems(expectedTitles: expectedTitles).isEmpty)
        var noRuntime = validInspection
        noRuntime.hasMoltenVK = false
        expect("IPA check: a shell without Frameworks/MoltenVK.framework is refused", !noRuntime.problems(expectedTitles: expectedTitles).isEmpty)

        let catalogJSON = """
        {"schemaVersion":2,"games":[{"titleID":"0004000000055E00","displayName":"Pokemon Y","packFile":"Frameworks/GamePack-0004000000055E00.dylib"},{"titleID":"0004000000086400","displayName":"Animal Crossing","packFile":"Frameworks/GamePack-0004000000086400.dylib"}]}
        """
        let facts = LibraryIPACatalog.parse(Data(catalogJSON.utf8))
        expect("catalog JSON: schema-2 games parse", facts?.schemaVersion == 2 && facts?.titleIDs == expectedTitles)
        expect("catalog JSON: no bundled ROM files in a ROM-free catalogue", facts?.packedROMFiles.isEmpty == true)
        let romCatalog = LibraryIPACatalog.parse(Data("""
        {"schemaVersion":2,"games":[{"titleID":"0004000000055E00","romFile":"Roms/0004000000055E00.cci"}]}
        """.utf8))
        expect("catalog JSON: romFile entries are detected", romCatalog?.packedROMFiles.count == 1)
        expect("catalog JSON: invalid JSON parses to nil", LibraryIPACatalog.parse(Data("not json".utf8)) == nil)

        // 8b. Shell runtime (task-35): the shell the launcher builds must carry
        // the verified Frameworks/MoltenVK.framework (hardware PICA200/Metal
        // layer + system Metal HUD) and keep the HUD/file-sharing Info.plist
        // keys. The framework is hash-pinned; sources are the launcher-embedded
        // resource, checkout build/third_party, or the pinned
        // out/shell/3ds2apple-shell.ipa template.
        let runtimeScratch = NSTemporaryDirectory() + "zl-shell-runtime-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: runtimeScratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: runtimeScratch) }
        var runtimeSource: ShellRuntime.Source?
        do {
            runtimeSource = try ShellRuntime.resolveFramework(repoRoot: repo)
        } catch {
            expect("shell runtime: a verified MoltenVK.framework source resolves", false, error.localizedDescription)
        }
        if let source = runtimeSource {
            defer { source.cleanUp() }
            expect(
                "shell runtime: a verified MoltenVK.framework source resolves",
                true,
                source.origin.rawValue + " · " + source.detail
            )
            let sourceProblems = ShellRuntime.problemsWithFramework(at: source.directory)
            expect(
                "shell runtime: the source is the pinned arm64 MoltenVK 1.4.2 dylib",
                sourceProblems.isEmpty,
                sourceProblems.joined(separator: "; ")
            )
            let template = repo + "/" + ShellRuntime.pinnedTemplateRelativePath
            if FileManager.default.fileExists(atPath: template) {
                let templateProblems = ShellRuntime.inspectPinnedTemplate(at: template)
                expect(
                    "shell runtime: pinned shell template carries the verified framework + HUD/file-sharing plist",
                    templateProblems.isEmpty,
                    templateProblems.joined(separator: "; ")
                )
            } else {
                expect("shell runtime: pinned shell template not in checkout (launcher-embedded copy is used)", true)
            }

            // Copy the framework exactly like buildShellApp does, then prove the
            // shell verification accepts the good shell and refuses the broken
            // variants (no framework / HUD off / file sharing off).
            let scratchApp = runtimeScratch + "/Payload/3ds2apple.app"
            try? FileManager.default.createDirectory(atPath: scratchApp + "/Frameworks", withIntermediateDirectories: true)
            writeShellInfoPlist(to: scratchApp + "/Info.plist", metalHUD: true, fileSharing: true)
            do {
                try ShellRuntime.copyFramework(from: source, intoShellAppAt: scratchApp)
                let shellProblems = ShellRuntime.verifyShellApp(at: scratchApp)
                expect(
                    "shell runtime: built shell with Frameworks/MoltenVK.framework verifies",
                    shellProblems.isEmpty,
                    shellProblems.joined(separator: "; ")
                )
                let copied = ShellRuntime.problemsWithFramework(at: ShellRuntime.frameworkDirectory(inShellAppAt: scratchApp))
                expect(
                    "shell runtime: copied framework keeps the pinned bytes",
                    copied.isEmpty,
                    copied.joined(separator: "; ")
                )
                try? FileManager.default.removeItem(atPath: ShellRuntime.frameworkDirectory(inShellAppAt: scratchApp))
                expect(
                    "shell runtime: a shell without Frameworks/MoltenVK.framework is refused",
                    !ShellRuntime.verifyShellApp(at: scratchApp).isEmpty
                )
                try? ShellRuntime.copyFramework(from: source, intoShellAppAt: scratchApp)
                writeShellInfoPlist(to: scratchApp + "/Info.plist", metalHUD: false, fileSharing: true)
                expect(
                    "shell runtime: a shell without MetalHudEnabled is refused",
                    ShellRuntime.verifyShellApp(at: scratchApp).contains { $0.contains("MetalHudEnabled") }
                )
                writeShellInfoPlist(to: scratchApp + "/Info.plist", metalHUD: true, fileSharing: false)
                expect(
                    "shell runtime: a shell without Documents file sharing is refused",
                    ShellRuntime.verifyShellApp(at: scratchApp).contains { $0.contains("UIFileSharingEnabled") }
                )
            } catch {
                for name in [
                    "shell runtime: built shell with Frameworks/MoltenVK.framework verifies",
                    "shell runtime: copied framework keeps the pinned bytes",
                    "shell runtime: a shell without Frameworks/MoltenVK.framework is refused",
                    "shell runtime: a shell without MetalHudEnabled is refused",
                    "shell runtime: a shell without Documents file sharing is refused",
                ] {
                    expect(name, false, error.localizedDescription)
                }
            }
        } else {
            for name in [
                "shell runtime: the source is the pinned arm64 MoltenVK 1.4.2 dylib",
                "shell runtime: pinned shell template carries the verified framework + HUD/file-sharing plist",
                "shell runtime: built shell with Frameworks/MoltenVK.framework verifies",
                "shell runtime: copied framework keeps the pinned bytes",
                "shell runtime: a shell without Frameworks/MoltenVK.framework is refused",
                "shell runtime: a shell without MetalHudEnabled is refused",
                "shell runtime: a shell without Documents file sharing is refused",
            ] {
                expect(name, false, "no verified MoltenVK.framework source")
            }
        }

        // 9. Team ID detection from Xcode's local state (never typed by the user)
        let profilePlist = """
        <key>TeamIdentifier</key>
        <array>
            <string>ABCDE12345</string>
        </array>
        """
        expect("team detection: TeamIdentifier in a profile plist", TeamDetector.firstTeamID(inPlistText: profilePlist) == "ABCDE12345")
        let identityLines = "  1) 0123456789ABCDEF Apple Development: player (ABCDE12345)"
        expect("team detection: certificate subject fallback", TeamDetector.certificateTeamIDs(in: identityLines) == ["ABCDE12345"])
        expect("team detection: no team returns nil", TeamDetector.firstTeamID(inPlistText: "no team here") == nil)

        // 10. devpush NDJSON contract v1
        let beginLine = """
        {"schema":"devpush/1","type":"begin","command":"put","udid":"mock"}
        """
        expect("devpush: begin line parses", DevpushNDJSON.parse(beginLine)?.type == "begin")
        let progressLine = """
        {"schema":"devpush/1","type":"progress","command":"put","file":"GameRom.cci","bytesSent":120000,"bytesTotal":480000,"percent":25}
        """
        if let line = DevpushNDJSON.parse(progressLine), let parsed = DevpushNDJSON.progress(line) {
            expect("devpush: progress bytes parse", parsed.sent == 120000 && parsed.total == 480000)
        } else {
            expect("devpush: progress bytes parse", false)
        }
        let errorLine = """
        {"schema":"devpush/1","type":"error","command":"put","error":{"code":"stall_timeout","message":"no progress for 90s","hint":"check the cable"},"exitCode":6}
        """
        if let line = DevpushNDJSON.parse(errorLine), let parsed = DevpushNDJSON.error(line) {
            expect("devpush: error code and hint parse", parsed.code == "stall_timeout" && parsed.hint == "check the cable")
        } else {
            expect("devpush: error code and hint parse", false)
        }
        let doneLine = """
        {"schema":"devpush/1","type":"done","command":"capabilities","version":"1.0.0","commands":["devices","put"],"features":{"mock":true}}
        """
        let donePayload = DevpushNDJSON.lastDone(doneLine, command: "capabilities")
        expect("devpush: done payload parses", donePayload?["version"] as? String == "1.0.0")
        expect("devpush: schema mismatch refused", DevpushNDJSON.parse("{\"schema\":\"devpush/2\",\"type\":\"done\"}") == nil)
        expect("devpush: stall hint is actionable", BridgeExitCodes.hint(for: "stall_timeout").lowercased().contains("stalled"))
        expect("devpush: container hint mentions file sharing", BridgeExitCodes.hint(for: "container_unavailable").lowercased().contains("file sharing"))

        return checks
    }

    /// Write a synthetic shell Info.plist for the shell-runtime checks; the
    /// launcher verifies these same keys on the real built shell.
    private static func writeShellInfoPlist(to path: String, metalHUD: Bool, fileSharing: Bool) {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.kratos.3ds2apple",
            "CFBundleShortVersionString": "0.2.2",
            "CFBundleVersion": "10",
            "MetalHudEnabled": metalHUD,
            "UIFileSharingEnabled": fileSharing,
            "LSSupportsOpeningDocumentsInPlace": fileSharing,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
