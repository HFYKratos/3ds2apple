//
//  MockBackends.swift
//  3ds2apple macOS launcher
//
//  Deterministic stand-ins for the desktop CLI, the installer and the device
//  bridge. Mock mode exercises the real models, the deploy state machine and the
//  push planner but never touches a ROM, a device, an Apple ID or the network.
//  This is what the build VM (no signing assets, no phone) and the offscreen
//  screenshot renderer use.
//

import Foundation

enum MockFixtures {
    static let titlePokemonY = "0004000000055E00"
    static let titleAnimalCrossing = "0004000000086400"
    static let titleMario3DLand = "0004000000030600"

    /// Bundle ID of the app the mock installer reports as actually installed.
    /// It is deliberately read back from the install result (not from a template)
    /// by the Deploy flow.
    static let installedShellBundleID = "com.kratos.3ds2apple"
    /// A stale value a previous install could have left in UserDefaults; the
    /// self-check proves the Deploy flow replaces it with the install result.
    static let staleInstalledBundleID = "com.kratos.stale.shell"
    static let detectedTeamID = "ABCDE12345"

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
                romDataPath: "out/launcher-roms/\(titleAnimalCrossing).cci",
                romSha256: "aa11bb22cc33dd44ee55ff6600778899aabbccddeeff00112233445566778899"
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

    static func builtManifest(for titleID: String) -> PackageManifest {
        let game = games().first(where: { $0.titleID == titleID })
        return PackageManifest(
            schemaVersion: 1,
            titleID: titleID,
            displayName: game?.displayName ?? titleID,
            productCode: game?.productCode ?? "",
            aotVersion: 1,
            saveNamespace: titleID,
            packFile: "GamePack.dylib",
            packSha256: game?.packSha256 ?? String(repeating: "9f", count: 32),
            packBytes: game?.packBytes ?? 218_103_808,
            packFormat: "macho",
            romFile: "GameRom.cci",
            romSha256: game?.romSha256,
            romBytes: game?.romBytes
        )
    }

    static func queuedManifest(for titleID: String) -> PackageManifest {
        PackageManifest(
            schemaVersion: 1,
            titleID: titleID,
            displayName: games().first(where: { $0.titleID == titleID })?.displayName ?? titleID,
            productCode: games().first(where: { $0.titleID == titleID })?.productCode ?? "",
            aotVersion: 1,
            saveNamespace: titleID,
            packFile: nil,
            packSha256: nil,
            packBytes: 0,
            packFormat: "queued",
            romFile: nil,
            romSha256: nil,
            romBytes: nil
        )
    }

    static func manifests() -> [String: PackageManifest] {
        [
            titlePokemonY: builtManifest(for: titlePokemonY),
            titleAnimalCrossing: queuedManifest(for: titleAnimalCrossing),
            titleMario3DLand: queuedManifest(for: titleMario3DLand),
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

    /// Create the mock package files the planner checks for. They are sparse,
    /// labelled mock artifacts; they are never real packs or ROMs. Sizes are
    /// small so the headless self-check and screenshots stay fast.
    static func ensurePackageTree() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: outRoot.appendingPathComponent("packages"), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: outRoot.appendingPathComponent("launcher-roms"), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        for titleID in [titlePokemonY, titleAnimalCrossing] {
            try? fileManager.createDirectory(at: outRoot.appendingPathComponent("packages/\(titleID)"), withIntermediateDirectories: true)
        }
        writePlaceholder(at: outRoot.appendingPathComponent("packages/\(titlePokemonY)/GamePack.dylib"), bytes: 8 * 1024 * 1024)
        writePlaceholder(at: outRoot.appendingPathComponent("launcher-roms/\(titlePokemonY).cci"), bytes: 8 * 1024 * 1024)
        writePlaceholder(at: outRoot.appendingPathComponent("launcher-roms/\(titleAnimalCrossing).cci"), bytes: 4 * 1024 * 1024)
        writePlaceholder(at: outRoot.appendingPathComponent("packages/\(titlePokemonY)/cover.png"), bytes: 512)
    }

    private static func writePlaceholder(at url: URL, bytes: Int64) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        FileManager.default.createFile(atPath: url.path, contents: Data("3ds2apple launcher mock artifact - not a real pack or ROM\n".utf8))
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(bytes))
            try? handle.close()
        }
    }

    static func readyEnvironment() -> EnvironmentReport {
        var apple = AppleReadiness(
            xcodePath: "/Applications/Xcode.app/Contents/Developer",
            xcodeVersion: "Xcode 26.6",
            devicectlAvailable: true,
            signingIdentityCount: 2,
            provisioningProfileCount: 3,
            teamID: detectedTeamID,
            checkedAt: Date()
        )
        apple.teamID = detectedTeamID
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
            notes: ["Mock mode: no ROM, device, Apple ID or network is used."]
        )
    }

    static func missingSigningEnvironment() -> EnvironmentReport {
        var report = readyEnvironment()
        report.apple = AppleReadiness(
            xcodePath: "/Applications/Xcode.app/Contents/Developer",
            xcodeVersion: "Xcode 26.6",
            devicectlAvailable: true,
            signingIdentityCount: 0,
            provisioningProfileCount: 0,
            teamID: "",
            checkedAt: Date()
        )
        report.notes = [
            "Mock mode: no ROM, device, Apple ID or network is used.",
            "No Apple ID signing assets on this Mac. Sign in to Xcode -> Settings -> Accounts before deploying.",
        ]
        return report
    }

    static func tasksForScreenshots() -> [TaskRecord] {
        [TaskRecord(
            kind: .deploy,
            title: "Deploy 2 games",
            titleID: nil,
            state: .running,
            stages: [
                PipelineStage(title: "Check device & Apple ID", detail: "Kratos iPhone, ABCDE12345", state: .succeeded),
                PipelineStage(title: "Compile GamePacks", detail: "Animal Crossing: 218 MB generated C (mock)", state: .running),
                PipelineStage(title: "Compose ROM-free IPA", detail: "Frameworks/GamePack-*.dylib + GameCatalog.json", state: .pending),
                PipelineStage(title: "Verify IPA", detail: "schema 2, no ROM", state: .pending),
                PipelineStage(title: "Sign & install", detail: "Xcode + devicectl", state: .pending),
                PipelineStage(title: "Push game data", detail: "GameRom.cci + GameInfo.json", state: .pending),
                PipelineStage(title: "Done", detail: "可以打开手机 App 游玩", state: .pending),
            ],
            startedAt: Date().addingTimeInterval(-126),
            endedAt: nil,
            errorMessage: nil,
            errorHint: nil,
            detail: "Mock deploy for UI review"
        )]
    }

    static func logsForScreenshots() -> [LogEntry] {
        [
            LogEntry(date: Date().addingTimeInterval(-300), level: .info, category: "launcher", message: "3ds2apple launcher started (mock mode)"),
            LogEntry(date: Date().addingTimeInterval(-295), level: .info, category: "deploy", message: "selected 2 game(s): 0004000000055E00, 0004000000086400"),
            LogEntry(date: Date().addingTimeInterval(-280), level: .info, category: "deploy", message: "device: Kratos iPhone (iPhone 17 Pro, iOS 26.5)"),
            LogEntry(date: Date().addingTimeInterval(-240), level: .command, category: "pack", message: "3ds2apple-pack --out out build --queued --execute --json"),
            LogEntry(date: Date().addingTimeInterval(-200), level: .success, category: "deploy", message: "GamePack built: Frameworks/GamePack-0004000000055E00.dylib (218 MB, macho)"),
            LogEntry(date: Date().addingTimeInterval(-160), level: .command, category: "library", message: "xcodebuild -project ios/app/3ds2apple.xcodeproj -scheme 3ds2apple ... build"),
            LogEntry(date: Date().addingTimeInterval(-140), level: .command, category: "library", message: "3ds2apple-pack pack --title-id ... --execute --base-app ... --ipa-out IPA --ipa-name 3ds2apple-library"),
            LogEntry(date: Date().addingTimeInterval(-130), level: .success, category: "library", message: "embedded Frameworks/GamePack-*.dylib + GameCatalog.json (ROM-free IPA)"),
            LogEntry(date: Date().addingTimeInterval(-110), level: .success, category: "library", message: "IPA verified: 2 packs, schema-2 catalogue, no Roms/ entry"),
            LogEntry(date: Date().addingTimeInterval(-90), level: .command, category: "install", message: "xcrun devicectl device install app --device <device> <staged app>"),
            LogEntry(date: Date().addingTimeInterval(-70), level: .success, category: "install", message: "installed bundle id: com.kratos.3ds2apple"),
            LogEntry(date: Date().addingTimeInterval(-50), level: .command, category: "push", message: "devpush put --bundle-id com.kratos.3ds2apple --local GameRom.cci --remote Documents/Games/0004000000055E00/GameRom.cci"),
            LogEntry(date: Date().addingTimeInterval(-30), level: .info, category: "push", message: "GameInfo.json is pushed last so the shell never sees a partial game"),
        ]
    }

    static func installLogLines() -> [String] {
        [
            "Xcode 26.6 at /Applications/Xcode.app",
            "Detected Team ID: ABCDE12345",
            "Apple signing assets: 2 certificates, 3 profiles",
            "xcodebuild ... -allowProvisioningUpdates build",
            "3ds2apple-pack pack --title-id ... --execute (ROM-free)",
            "IPA verified: 2 packs, GameCatalog schema 2, no bundled ROM",
            "codesign embedded GamePack dylibs (local identity)",
            "xcrun devicectl device install app",
            "installed bundle id: com.kratos.3ds2apple",
            "devpush put Documents/Games/... (GameInfo.json last)",
        ]
    }
}

// MARK: - Mock pack backend

final class MockPackBackend: PackBackend {
    let mode: LauncherRunMode = .mock
    let outRoot: URL = MockFixtures.outRoot
    let repoRoot = URL(fileURLWithPath: "/Users/you/3ds2apple", isDirectory: true)
    var builtTitles: Set<String> = [MockFixtures.titlePokemonY]
    var failingTitles: Set<String> = []

    func inspectROM(_ path: String) async throws -> DetectedROM {
        try? await Task.sleep(nanoseconds: 60_000_000)
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
        try? await Task.sleep(nanoseconds: 60_000_000)
        let isAnimal = path.lowercased().contains("animal")
        let titleID = isAnimal ? MockFixtures.titleAnimalCrossing : MockFixtures.titlePokemonY
        MockFixtures.ensurePackageTree()
        return DetectedPackage(
            titleID: titleID,
            displayName: displayName ?? (isAnimal ? "Animal Crossing: New Leaf" : "Pokemon Y"),
            productCode: isAnimal ? "CTR-P-ECJE" : "CTR-P-EK2A",
            aotVersion: 1,
            state: "queued",
            pack: nil,
            issues: []
        )
    }

    func listPackages() async throws -> [DetectedPackage] {
        try? await Task.sleep(nanoseconds: 40_000_000)
        return MockFixtures.games().map { game in
            let built = builtTitles.contains(game.titleID)
            return DetectedPackage(
                titleID: game.titleID,
                displayName: game.displayName,
                productCode: game.productCode,
                aotVersion: game.aotVersion,
                state: built ? "built" : (game.phase == .failed ? "broken" : "queued"),
                pack: built ? PackFileInfo(
                    sha256: game.packSha256 ?? MockFixtures.builtManifest(for: game.titleID).packSha256 ?? "",
                    bytes: game.packBytes ?? 0,
                    format: "macho"
                ) : nil,
                issues: []
            )
        }
    }

    func build(titleIDs: [String], mode buildMode: BuildMode, onLine: @escaping (LogLevel, String) -> Void) async throws -> [DetectedPackage] {
        if buildMode == .dryRun {
            onLine(.info, "dry run: printed the macOS command plan; nothing was built")
            return []
        }
        for titleID in titleIDs.sorted() {
            if failingTitles.contains(titleID) {
                onLine(.error, "[3ds2apple-pack] build failed for " + titleID + " (mock failure)")
                throw LauncherFailure(
                    code: "build_failed",
                    message: "The GamePack build failed for " + titleID + ".",
                    hint: "Open the log; in mock mode this is the labelled failure fixture.",
                    detail: "mock 3dsrecomp exit 1",
                    exitCode: 1
                )
            }
            let game = MockFixtures.games().first(where: { $0.titleID == titleID })
            let lines = [
                "[3ds2apple-pack] building " + titleID + " (" + (game?.displayName ?? "") + ")",
                "[build-recomp-ios] ROM -> generated C (mock)",
                "[build-game-pack] target: arm64-apple-ios16.0 (mock)",
                "[build-game-pack] linking Frameworks/GamePack-" + titleID + ".dylib",
                "[3ds2apple-pack] recorded out/packages/" + titleID + "/GameInfo.json",
            ]
            for line in lines {
                try? await Task.sleep(nanoseconds: 50_000_000)
                onLine(.info, line)
            }
            builtTitles.insert(titleID)
            MockFixtures.ensurePackageTree()
        }
        return try await listPackages()
    }

    func verify() async throws -> [String] {
        try? await Task.sleep(nanoseconds: 40_000_000)
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
            "[build-multi-game-ipa] embedded Frameworks/GamePack-<TITLEID>.dylib for each selected game",
            "[build-multi-game-ipa] schema-2 GameCatalog.json installed in the app bundle",
            "[build-multi-game-ipa] ipa: " + ipaName + ".ipa (ROM-free: no Roms/ entry, no GameRom)",
        ]
        for line in lines {
            try? await Task.sleep(nanoseconds: 60_000_000)
            onLine(.info, line)
        }
        let command = ["scripts/build-multi-game-ipa.sh", "--base-app", baseAppPath, "--ipa-name", ipaName]
        if dryRun {
            onLine(.info, "dry run: printed the packaging plan; no IPA written (mock)")
            return LibraryIPAResult(ipaPath: nil, titles: titleIDs, executed: false, command: command, summary: "mock dry run")
        }
        let ipaPath = (ipaOutDir as NSString).appendingPathComponent(ipaName + ".ipa")
        try? FileManager.default.createDirectory(atPath: ipaOutDir, withIntermediateDirectories: true)
        try? Data("mock library ipa - layout only, not installable (mock pack bytes)\n".utf8).write(to: URL(fileURLWithPath: ipaPath))
        return LibraryIPAResult(
            ipaPath: ipaPath,
            titles: titleIDs,
            executed: true,
            command: command,
            summary: "mock " + String(titleIDs.count) + " game(s)"
        )
    }

    func readManifest(titleID: String) async throws -> PackageManifest {
        if builtTitles.contains(titleID) {
            return MockFixtures.builtManifest(for: titleID)
        }
        if MockFixtures.games().contains(where: { $0.titleID == titleID }) {
            return MockFixtures.queuedManifest(for: titleID)
        }
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
    var appsInstalled: Set<String> = []

    private func key(_ bundleID: String, _ path: String) -> String { bundleID + ":" + path }

    /// Called by the Deploy flow after a mock install, mirroring the real
    /// install -> app-attr chain.
    func markInstalled(_ bundleID: String) {
        appsInstalled.insert(bundleID)
    }

    func capabilities() async throws -> BridgeCapabilities {
        MockFixtures.capabilities
    }

    func devices() async throws -> [DeviceInfo] {
        try? await Task.sleep(nanoseconds: 40_000_000)
        return MockFixtures.devices
    }

    func appAttr(bundleID: String, udid: String?) async throws -> AppAttr {
        try? await Task.sleep(nanoseconds: 30_000_000)
        let installed = appsInstalled.contains(bundleID)
        return AppAttr(
            installed: installed,
            dataContainer: installed ? "/mock/containers/" + bundleID : nil,
            appBundleVersion: installed ? "0.2.0-beta1" : nil,
            fileSharingEnabled: installed
        )
    }

    func mkdir(bundleID: String, path: String, udid: String?) async throws {
        try? await Task.sleep(nanoseconds: 20_000_000)
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
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        files[key(bundleID, remote)] = total
        return PutResult(remotePath: remote, bytes: total, sha256: FileProbe.sha256(ofFile: local) ?? "", elapsed: Date().timeIntervalSince(started))
    }

    func stat(bundleID: String, path: String, udid: String?) async throws -> RemoteEntry? {
        try? await Task.sleep(nanoseconds: 15_000_000)
        guard let size = files[key(bundleID, path)] else { return nil }
        return RemoteEntry(name: path.split(separator: "/").last.map(String.init) ?? path, isDirectory: false, size: size, modifiedAt: nil)
    }

    func ls(bundleID: String, path: String, udid: String?) async throws -> [RemoteEntry] {
        try? await Task.sleep(nanoseconds: 15_000_000)
        let prefix = key(bundleID, path) + "/"
        return files.compactMap { pair in
            guard pair.key.hasPrefix(prefix) else { return nil }
            let name = String(pair.key.dropFirst(prefix.count))
            return RemoteEntry(name: name, isDirectory: false, size: pair.value, modifiedAt: nil)
        }
    }
}
