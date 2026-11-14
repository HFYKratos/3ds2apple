//
//  SelfCheckCore.swift
//  3ds2apple macOS launcher
//
//  Self-check part 1: CLI arguments, checkout detection, the desktop CLI JSON
//  contract, the shell GameInfo mapping, push-plan ordering and the devpush
//  NDJSON contract v1.
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

        // 7. Push plan ordering and paths
        MockFixtures.ensurePackageTree()
        let fixtures = MockFixtures.games()
        let planner = PushPlanner(outRoot: MockFixtures.outRoot, bundleID: "com.kratos.3ds2apple")
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
                expect("push plan: bundle id and device recorded", plan.bundleID == "com.kratos.3ds2apple" && plan.deviceUDID == MockFixtures.devices.first?.udid)
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
            // The library IPA (packs + catalog) is ROM-free: the mock pack backend
            // simulates the allocation and reports an IPA path.
            let mockModel = AppModel.mock(scenario: .library)
            if let allocated = try? await mockModel.pack.buildLibraryIPA(
                titleIDs: [MockFixtures.titlePokemonY],
                baseAppPath: "/Users/you/3ds2apple/build/launcher-shell/Build/Products/Debug-iphoneos/3ds2apple.app",
                ipaOutDir: NSTemporaryDirectory() + "zl-selfcheck-ipa",
                ipaName: "3ds2apple-library",
                dryRun: false,
                onLine: { _, _ in }
            ) {
                expect("library IPA: allocation executes", allocated.executed && allocated.titles == [MockFixtures.titlePokemonY])
                expect("library IPA: output path exists", allocated.ipaPath.map { FileProbe.exists($0) } == true)
            } else {
                expect("library IPA: mock allocation runs", false)
            }
        }

        // 8. devpush NDJSON contract v1
        let beginLine = """
        {"schema":"devpush/1","type":"begin","command":"put","udid":"mock"}
        """
        expect("devpush: begin line parses", DevpushNDJSON.parse(beginLine)?.type == "begin")
        let progressLine = """
        {"schema":"devpush/1","type":"progress","command":"put","file":"GamePack.dylib","bytesSent":120000,"bytesTotal":480000,"percent":25}
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
}
