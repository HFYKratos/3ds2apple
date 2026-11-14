//
//  MockBackends.swift
//  3ds2apple macOS launcher
//
//  Deterministic stand-ins for the desktop CLI, the installer and the device
//  bridge. Mock mode exercises the real models, view state and push planner but
//  never touches a ROM, a device or a signing identity. This is what the build VM
//  (no Apple ID, no phone) and the screenshot renderer use.
//

import Foundation

enum MockFixtures {
    static let titlePokemonY = "0004000000055E00"
    static let titleAnimalCrossing = "0004000000086400"
    static let titleMario3DLand = "0004000000030600"

    static let devices: [DeviceInfo] = [
        DeviceInfo(
            udid: "00008120-000A1B2C3D4E5F60",
            name: "Kratos iPhone",
            model: "iPhone 17 Pro",
            iosVersion: "26.5",
            connection: "usb",
            paired: true
        ),
        DeviceInfo(
            udid: "00008110-0011223344556677",
            name: "Kratos iPad",
            model: "iPad Pro 13-inch (M5)",
            iosVersion: "26.5",
            connection: "network",
            paired: true
        ),
    ]

    static let capabilities = BridgeCapabilities(
        version: "1.0.0",
        schema: "devpush/1",
        commands: ["capabilities", "devices", "install", "uninstall", "app-attr", "ls", "stat", "put", "get", "put-tar", "mkdir", "rm", "free"],
        features: ["mock": true, "progress": true, "stallWatchdog": true, "install": true, "appAttr": true, "putTar": true, "get": true],
        mock: true
    )

    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("3ds2apple-launcher-mock", isDirectory: true)
    }

    static var outRoot: URL { root.appendingPathComponent("out", isDirectory: true) }
    static var stagingRoot: URL { root.appendingPathComponent("staging", isDirectory: true) }

    static func games() -> [GameEntry] {
        [
            GameEntry(
                titleID: titlePokemonY,
                displayName: "Pokemon Y",
                productCode: "CTR-P-EK2A",
                romPath: "/Users/you/ROM/Pokemon Y.cci",
                romBytes: 1_807_118_336,
                container: "ncsd",
                aotVersion: 1,
                buildSlug: "pokemon-y-00055e00",
                phase: .built,
                packPath: "out/packages/\(titlePokemonY)/GamePack.dylib",
                packBytes: 218_103_808,
                packSha256: "92bab7aaf4fbe7628ed82d392792f8bbc2085423f8518f830160ec1ba2145da2",
                packFormat: "macho",
                saveNamespace: titlePokemonY,
                pushedAt: nil,
                lastError: nil,
                romDataPath: "out/launcher-roms/\(titlePokemonY).cci",
                romSha256: "7ea17f4d6a1cfefdbf98a6f5b0c4e9a1a9a5f4e6b7c8d9e0f1a2b3c4d5e6f708"
            ),
            GameEntry(
                titleID: titleAnimalCrossing,
                displayName: "Animal Crossing: New Leaf",
                productCode: "CTR-P-ECJE",
                romPath: "/Users/you/ROM/Animal Crossing New Leaf.cci",
                romBytes: 2_147_483_648,
                container: "ncsd",
                aotVersion: 1,
                buildSlug: "animal-crossing-new-leaf-00086400",
                phase: .queued,
                packPath: nil,
                packBytes: nil,
                packSha256: nil,
                packFormat: nil,
                saveNamespace: titleAnimalCrossing,
                pushedAt: nil,
                lastError: nil,
                romDataPath: nil,
                romSha256: nil
            ),
            GameEntry(
                titleID: titleMario3DLand,
                displayName: "Super Mario 3D Land",
                productCode: "CTR-P-AREJ",
                romPath: "/Users/you/ROM/Super Mario 3D Land.3ds",
                romBytes: 536_870_912,
                container: "ncsd",
                aotVersion: 1,
                buildSlug: "super-mario-3d-land-00030600",
                phase: .failed,
                packPath: nil,
                packBytes: nil,
                packSha256: nil,
                packFormat: nil,
                saveNamespace: titleMario3DLand,
                pushedAt: nil,
                lastError: "Build failed: 3dsrecomp exited with code 1 (mock failure).",
                romDataPath: nil,
                romSha256: nil
            ),
        ]
    }

    static func manifests() -> [String: PackageManifest] {
        [
            titlePokemonY: PackageManifest(
                schemaVersion: 1,
                titleID: titlePokemonY,
                displayName: "Pokemon Y",
                productCode: "CTR-P-EK2A",
                aotVersion: 1,
                saveNamespace: titlePokemonY,
                packFile: "GamePack.dylib",
                packSha256: "92bab7aaf4fbe7628ed82d392792f8bbc2085423f8518f830160ec1ba2145da2",
                packBytes: 218_103_808,
                packFormat: "macho",
                romFile: "GameRom.cci",
                romSha256: "7ea17f4d6a1cfefdbf98a6f5b0c4e9a1a9a5f4e6b7c8d9e0f1a2b3c4d5e6f708",
                romBytes: 1_446_201_088
            ),
            titleAnimalCrossing: PackageManifest(
                schemaVersion: 1,
                titleID: titleAnimalCrossing,
                displayName: "Animal Crossing: New Leaf",
                productCode: "CTR-P-ECJE",
                aotVersion: 1,
                saveNamespace: titleAnimalCrossing,
                packFile: "GamePack.dylib",
                packSha256: String(repeating: "ab", count: 32),
                packBytes: 0,
                packFormat: "queued",
                romFile: nil,
                romSha256: nil,
                romBytes: nil
            ),
        ]
    }

    static func detectedROM() -> DetectedROM {
        DetectedROM(
            path: "/Users/you/ROM/Pokemon Y.cci",
            titleID: titlePokemonY,
            displayName: "Pokemon Y",
            productCode: "CTR-P-EK2A",
            container: "ncsd",
            bytes: 1_807_118_336,
            contentBytes: 1_446_201_088,
            titleVersion: 0
        )
    }

    /// Create the tiny mock package files the push planner checks for. The files
    /// are sparse, labelled mock artifacts; they are never real packs or ROMs.
    static func ensurePackageTree() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: outRoot.appendingPathComponent("packages/\(titlePokemonY)"), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        writePlaceholder(at: outRoot.appendingPathComponent("packages/\(titlePokemonY)/GamePack.dylib"), bytes: 8 * 1024 * 1024)
        try? FileManager.default.createDirectory(at: outRoot.appendingPathComponent("launcher-roms"), withIntermediateDirectories: true)
        writePlaceholder(at: outRoot.appendingPathComponent("launcher-roms/\(titlePokemonY).cci"), bytes: 1_446_201_088)
        writePlaceholder(at: outRoot.appendingPathComponent("packages/\(titlePokemonY)/GameRom.cci"), bytes: 32 * 1024 * 1024)
        try? "mock cover".data(using: .utf8)?.write(to: outRoot.appendingPathComponent("packages/\(titlePokemonY)/cover.png"))
    }

    private static func writePlaceholder(at url: URL, bytes: Int64) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        FileManager.default.createFile(atPath: url.path, contents: Data("3ds2apple launcher mock artifact - not a real pack or ROM\n".utf8))
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(bytes))
            try? handle.close()
        }
    }

    static func environment() -> EnvironmentReport {
        var apple = AppleReadiness(
            xcodePath: "/Applications/Xcode.app/Contents/Developer",
            xcodeVersion: "Xcode 26.6",
            devicectlAvailable: true,
            signingIdentityCount: 0,
            provisioningProfileCount: 0,
            teamID: "",
            checkedAt: Date()
        )
        apple.teamID = ""
        return EnvironmentReport(
            generatedAt: Date(),
            repoRoot: "/Users/you/3ds2apple",
            outDir: "/Users/you/3ds2apple/out (mock sandbox)",
            tools: [
                ToolStatus(name: "Xcode", state: .ok, detail: "Xcode 26.6", hint: ""),
                ToolStatus(name: "devicectl", state: .ok, detail: "available", hint: ""),
                ToolStatus(name: "3ds2apple checkout", state: .ok, detail: "/Users/you/3ds2apple", hint: ""),
                ToolStatus(name: "3ds2apple-pack CLI", state: .ok, detail: "builder/target/release/3ds2apple-pack", hint: ""),
                ToolStatus(name: "Shell runtime (arm64)", state: .ok, detail: "58.3 MB libzakuro_ios.a", hint: ""),
                ToolStatus(name: "Shell app project", state: .ok, detail: "ios/app/project.yml", hint: ""),
                ToolStatus(name: "xcodegen", state: .ok, detail: "/usr/local/bin/xcodegen", hint: ""),
                ToolStatus(name: "device bridge (devpush)", state: .ok, detail: "tools/devpush (mock)", hint: ""),
            ],
            apple: apple,
            devpushCapabilities: capabilities,
            notes: [
                "Mock mode: no ROM, device, Apple ID or network is used.",
                "No Apple ID signing assets on this Mac. Sign in to Xcode -> Settings -> Accounts before installing on a real device.",
            ]
        )
    }

    static func tasksForScreenshots() -> [TaskRecord] {
        var build = TaskRecord(
            kind: .buildAOT,
            title: "Build GamePack - Pokemon Y",
            titleID: titlePokemonY,
            state: .running,
            stages: [
                PipelineStage(title: "Queue AOT build", detail: "out/aot-queue.json", state: .succeeded),
                PipelineStage(title: "Run 3dsrecomp", detail: "ROM header -> generated C", state: .succeeded),
                PipelineStage(title: "Compile iOS archive", detail: "arm64-apple-ios16.0", state: .running),
                PipelineStage(title: "Link GamePack.dylib", detail: "zk_gamepack_register", state: .pending),
                PipelineStage(title: "Record package manifest", detail: "GameInfo.json via desktop CLI", state: .pending),
            ],
            startedAt: Date().addingTimeInterval(-252),
            endedAt: nil,
            errorMessage: nil,
            errorHint: nil,
            detail: "Mock build for UI review"
        )
        build.stages[2].detail = "218 MB of generated C (mock)"
        let install = TaskRecord(
            kind: .installShell,
            title: "Build & install library (1 game)",
            titleID: nil,
            state: .failed,
            stages: [
                PipelineStage(title: "Check Apple ID readiness", detail: "no signing assets", state: .failed),
                PipelineStage(title: "Build signed shell app", detail: "xcodebuild automatic signing", state: .pending),
                PipelineStage(title: "Embed GamePacks + GameCatalog", detail: "3ds2apple-pack pack --execute", state: .pending),
                PipelineStage(title: "Sign packs + install", detail: "codesign + devicectl", state: .pending),
                PipelineStage(title: "Verify install", detail: "app-attr", state: .pending),
            ],
            startedAt: Date().addingTimeInterval(-86),
            endedAt: Date().addingTimeInterval(-81),
            errorMessage: "Apple signing error 9120: the signing session was rejected.",
            errorHint: "Open Xcode -> Settings -> Accounts, sign out and sign back in with your own Apple ID, approve two-factor authentication, then retry.",
            detail: "Mock readiness failure"
        )
        return [install, build]
    }

    static func logsForScreenshots() -> [LogEntry] {
        [
            LogEntry(date: Date().addingTimeInterval(-360), level: .info, category: "launcher", message: "3ds2apple launcher 0.1.0 started (mock mode)"),
            LogEntry(date: Date().addingTimeInterval(-355), level: .info, category: "toolchain", message: "repository: /Users/you/3ds2apple"),
            LogEntry(date: Date().addingTimeInterval(-340), level: .command, category: "pack", message: "3ds2apple-pack --out out rom inspect \"/Users/you/ROM/Pokemon Y.cci\" --json"),
            LogEntry(date: Date().addingTimeInterval(-338), level: .success, category: "rom", message: "titleID=0004000000055E00 productCode=CTR-P-EK2A container=ncsd bytes=1.7 GiB"),
            LogEntry(date: Date().addingTimeInterval(-320), level: .command, category: "pack", message: "3ds2apple-pack --out out packages add --roms \"/Users/you/ROM/Pokemon Y.cci\" --include-rom --json"),
            LogEntry(date: Date().addingTimeInterval(-318), level: .success, category: "import", message: "queued 0004000000055E00 Pokemon Y -> out/packages/0004000000055E00"),
            LogEntry(date: Date().addingTimeInterval(-300), level: .info, category: "build", message: "build mode: fake preview pack (mock)"),
            LogEntry(date: Date().addingTimeInterval(-298), level: .info, category: "build", message: "[build-game-pack] compiling 218 MB generated C (mock)"),
            LogEntry(date: Date().addingTimeInterval(-160), level: .command, category: "library", message: "xcodebuild -project ios/app/3ds2apple.xcodeproj -scheme 3ds2apple -destination 'generic/platform=iOS' ... build"),
            LogEntry(date: Date().addingTimeInterval(-140), level: .command, category: "library", message: "3ds2apple-pack pack --all --execute --base-app ... --ipa-out IPA --ipa-name 3ds2apple-library"),
            LogEntry(date: Date().addingTimeInterval(-132), level: .success, category: "library", message: "embedded Frameworks/GamePack-0004000000055E00.dylib + GameCatalog.json (IPA stays ROM-free)"),
            LogEntry(date: Date().addingTimeInterval(-121), level: .command, category: "library", message: "codesign --force --sign <Apple Development identity> Frameworks/GamePack-0004000000055E00.dylib"),
            LogEntry(date: Date().addingTimeInterval(-119), level: .error, category: "library", message: "Apple signing error 9120: the signing session was rejected."),
            LogEntry(date: Date().addingTimeInterval(-60), level: .warn, category: "device", message: "device bridge: mock backend (no USB device touched)"),
        ]
    }

    static func installLogLines() -> [String] {
        [
            "Xcode 26.6 at /Applications/Xcode.app",
            "Team ID: (not set)",
            "Apple signing assets: 0 certificates, 0 profiles",
            "Sign in to Xcode -> Settings -> Accounts first.",
            "xcodebuild ... -allowProvisioningUpdates build",
            "3ds2apple-pack pack --all --execute (ROM-free)",
            "codesign embedded GamePack dylibs (local identity)",
            "xcrun devicectl device install app",
            "error: Apple signing error 9120 (session rejected)",
        ]
    }
}

// MARK: - Mock pack backend

final class MockPackBackend: PackBackend {
    let mode: LauncherRunMode = .mock
    let outRoot: URL = MockFixtures.outRoot
    let repoRoot = URL(fileURLWithPath: "/Users/you/3ds2apple", isDirectory: true)
    var manifests = MockFixtures.manifests()

    func inspectROM(_ path: String) async throws -> DetectedROM {
        try? await Task.sleep(nanoseconds: 180_000_000)
        var rom = MockFixtures.detectedROM()
        rom.path = path
        if path.lowercased().contains("animal") {
            rom.titleID = MockFixtures.titleAnimalCrossing
            rom.displayName = "Animal Crossing: New Leaf"
            rom.productCode = "CTR-P-ECJE"
        }
        return rom
    }

    func importROM(_ path: String, displayName: String?, includeROM: Bool) async throws -> DetectedPackage {
        try? await Task.sleep(nanoseconds: 220_000_000)
        let titleID = path.lowercased().contains("animal") ? MockFixtures.titleAnimalCrossing : MockFixtures.titlePokemonY
        return DetectedPackage(
            titleID: titleID,
            displayName: displayName ?? (titleID == MockFixtures.titleAnimalCrossing ? "Animal Crossing: New Leaf" : "Pokemon Y"),
            productCode: titleID == MockFixtures.titleAnimalCrossing ? "CTR-P-ECJE" : "CTR-P-EK2A",
            aotVersion: 1,
            state: "queued",
            pack: nil,
            issues: []
        )
    }

    func listPackages() async throws -> [DetectedPackage] {
        try? await Task.sleep(nanoseconds: 120_000_000)
        return MockFixtures.games().map { game in
            DetectedPackage(
                titleID: game.titleID,
                displayName: game.displayName,
                productCode: game.productCode,
                aotVersion: game.aotVersion,
                state: game.phase == .built || game.phase == .pushed ? "built" : (game.phase == .failed ? "broken" : "queued"),
                pack: game.packPath == nil ? nil : PackFileInfo(
                    sha256: game.packSha256 ?? "",
                    bytes: game.packBytes ?? 0,
                    format: game.packFormat ?? ""
                ),
                issues: []
            )
        }
    }

    func build(titleIDs: [String], mode buildMode: BuildMode, onLine: @escaping (LogLevel, String) -> Void) async throws -> [DetectedPackage] {
        let lines = [
            "[build-game-pack] name=pokemon-y titleID=0004000000055E00",
            "[build-game-pack] source: generated C in build/game/pokemon-y (mock)",
            "[build-game-pack] target: arm64-apple-ios16.0 shim=zk_gamepack_shim.c",
            "[build-game-pack] linking GamePack.dylib (mock)",
            "[3ds2apple-pack] recorded out/packages/0004000000055E00/GamePack.dylib",
        ]
        for line in lines {
            try? await Task.sleep(nanoseconds: 160_000_000)
            onLine(.info, line)
        }
        if buildMode == .dryRun {
            onLine(.info, "dry run: printed the macOS command plan; nothing was built")
            return []
        }
        let packages = try await listPackages()
        return packages.filter { titleIDs.contains($0.titleID) }
    }

    func verify() async throws -> [String] {
        try? await Task.sleep(nanoseconds: 120_000_000)
        return []
    }

    func buildLibraryIPA(
        titleIDs: [String],
        baseAppPath: String,
        ipaOutDir: String,
        ipaName: String,
        dryRun: Bool,
        onLine: @escaping (LogLevel, String) -> Void
    ) async throws -> LibraryIPAResult {
        let lines = [
            "[build-multi-game-ipa] allocating " + String(titleIDs.count) + " package(s) into one shell IPA",
            "[build-multi-game-ipa] embedded Frameworks/GamePack-" + (titleIDs.first ?? "0004000000055E00") + ".dylib",
            "[build-multi-game-ipa] catalog installed in the app bundle: GameCatalog.json",
            "[build-multi-game-ipa] ipa: " + ipaName + ".ipa (ROM-free: no Roms/ entry, no GameRom)",
        ]
        for line in lines {
            try? await Task.sleep(nanoseconds: 140_000_000)
            onLine(.info, line)
        }
        let command = ["scripts/build-multi-game-ipa.sh", "--base-app", baseAppPath, "--ipa-name", ipaName]
        if dryRun {
            onLine(.info, "dry run: printed the packaging plan; no IPA written (mock)")
            return LibraryIPAResult(ipaPath: nil, titles: titleIDs, executed: false, command: command, summary: "mock dry run")
        }
        let ipaPath = (ipaOutDir as NSString).appendingPathComponent(ipaName + ".ipa")
        try? FileManager.default.createDirectory(atPath: ipaOutDir, withIntermediateDirectories: true)
        try? Data("mock library ipa - layout only, not installable (no packs/ROMs)\n".utf8).write(to: URL(fileURLWithPath: ipaPath))
        return LibraryIPAResult(
            ipaPath: ipaPath,
            titles: titleIDs,
            executed: true,
            command: command,
            summary: "mock " + String(titleIDs.count) + " game(s)"
        )
    }

    func readManifest(titleID: String) async throws -> PackageManifest {
        if let manifest = manifests[titleID] { return manifest }
        throw LauncherFailure(
            code: "manifest_missing",
            message: "GameInfo.json is missing for " + titleID + " (mock).",
            hint: "Import and build the ROM first.",
            detail: nil,
            exitCode: nil
        )
    }
}

/// Live-mode placeholder when the Rust CLI has not been built yet.
final class MissingPackBackend: PackBackend {
    let mode: LauncherRunMode = .live
    let outRoot: URL
    let repoRoot: URL
    private let reason: String

    init(outRoot: URL, repoRoot: URL, reason: String) {
        self.outRoot = outRoot
        self.repoRoot = repoRoot
        self.reason = reason
    }

    private func missing() -> LauncherFailure {
        LauncherFailure(
            code: "pack_cli_missing",
            message: "The desktop pack CLI is not built.",
            hint: "Run: cd builder && cargo build -p builder-pack --release. " + reason,
            detail: nil,
            exitCode: nil
        )
    }

    func inspectROM(_ path: String) async throws -> DetectedROM { throw missing() }
    func importROM(_ path: String, displayName: String?, includeROM: Bool) async throws -> DetectedPackage { throw missing() }
    func listPackages() async throws -> [DetectedPackage] { throw missing() }
    func build(titleIDs: [String], mode: BuildMode, onLine: @escaping (LogLevel, String) -> Void) async throws -> [DetectedPackage] { throw missing() }
    func verify() async throws -> [String] { throw missing() }
    func readManifest(titleID: String) async throws -> PackageManifest { throw missing() }
    func buildLibraryIPA(
        titleIDs: [String],
        baseAppPath: String,
        ipaOutDir: String,
        ipaName: String,
        dryRun: Bool,
        onLine: @escaping (LogLevel, String) -> Void
    ) async throws -> LibraryIPAResult { throw missing() }
}

// MARK: - Mock device bridge

final class MockDeviceBridge: DeviceBridge {
    let mode: LauncherRunMode = .mock
    var displayName: String { "devpush (mock)" }
    private var files: [String: Int64] = [:]
    private var directories: Set<String> = []
    var appsInstalled: Set<String> = ["com.kratos.3ds2apple"]

    private func key(_ bundleID: String, _ path: String) -> String { bundleID + ":" + path }

    func capabilities() async throws -> BridgeCapabilities {
        MockFixtures.capabilities
    }

    func devices() async throws -> [DeviceInfo] {
        try? await Task.sleep(nanoseconds: 160_000_000)
        return MockFixtures.devices
    }

    func appAttr(bundleID: String, udid: String?) async throws -> AppAttr {
        try? await Task.sleep(nanoseconds: 120_000_000)
        let installed = appsInstalled.contains(bundleID)
        return AppAttr(
            installed: installed,
            dataContainer: installed ? "/mock/containers/" + bundleID : nil,
            appBundleVersion: "0.2.0-beta1",
            fileSharingEnabled: installed
        )
    }

    func mkdir(bundleID: String, path: String, udid: String?) async throws {
        try? await Task.sleep(nanoseconds: 60_000_000)
        directories.insert(key(bundleID, path))
    }

    func put(
        bundleID: String,
        local: String,
        remote: String,
        udid: String?,
        onProgress: @escaping (Int64, Int64) -> Void
    ) async throws -> PutResult {
        let started = Date()
        let total = FileProbe.size(local) ?? 1
        var sent: Int64 = 0
        while sent < total {
            sent = min(total, sent + max(total / 4, 1))
            onProgress(sent, total)
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
        files[key(bundleID, remote)] = total
        return PutResult(remotePath: remote, bytes: total, sha256: FileProbe.sha256(ofFile: local) ?? "", elapsed: Date().timeIntervalSince(started))
    }

    func stat(bundleID: String, path: String, udid: String?) async throws -> RemoteEntry? {
        try? await Task.sleep(nanoseconds: 40_000_000)
        guard let size = files[key(bundleID, path)] else { return nil }
        return RemoteEntry(name: path.split(separator: "/").last.map(String.init) ?? path, isDirectory: false, size: size, modifiedAt: nil)
    }

    func ls(bundleID: String, path: String, udid: String?) async throws -> [RemoteEntry] {
        try? await Task.sleep(nanoseconds: 40_000_000)
        let prefix = key(bundleID, path) + "/"
        return files.compactMap { pair in
            guard pair.key.hasPrefix(prefix) else { return nil }
            let name = String(pair.key.dropFirst(prefix.count))
            return RemoteEntry(name: name, isDirectory: false, size: pair.value, modifiedAt: nil)
        }
    }
}
