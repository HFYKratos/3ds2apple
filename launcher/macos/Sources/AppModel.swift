//
//  AppModel.swift
//  3ds2apple macOS launcher
//
//  The single state machine behind the UI:
//
//    import ROM -> detect header -> queue package -> build GamePack -> install
//    base shell -> push Documents/Games/<TITLEID> files -> verify
//
//  Every long step becomes a TaskRecord with named stages; every command line
//  goes to the log. Live mode drives the real CLI/scripts/Xcode; mock mode uses
//  the deterministic stand-ins so the whole flow is testable on the build VM
//  without a ROM, a phone or an Apple ID.
//

import Foundation
import AppKit

enum MockScenario: String, CaseIterable {
    case importDetected
    case library
    case buildRunning
    case install
    case devicePush
    case activity
    case diagnostics
}

@MainActor
final class AppModel: ObservableObject {
    // Navigation and library
    @Published var screen: LauncherScreen = .library
    /// Settings is a modal panel (gear button), never a top-level tab.
    @Published var settingsPresented = false
    /// Non-nil while the game-detail dialog is open (per-game install/push actions).
    @Published var detailGameID: String?
    @Published var games: [GameEntry] = []
    @Published var selectedGameID: String?
    @Published var detectedROM: DetectedROM?
    @Published var detectedROMError: String?

    // Activity
    @Published var tasks: [TaskRecord] = []
    @Published var logs: [LogEntry] = []
    @Published var isBusy = false
    @Published var activeTaskID: UUID?
    @Published var banner: Banner?

    // Environment / devices
    @Published var envReport: EnvironmentReport?
    @Published var appleReadiness: AppleReadiness?
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceUDID: String?

    // Install
    @Published var installProgressLines: [String] = []
    @Published var lastInstallFailure: LauncherFailure?
    @Published var installResult: InstallResult?
    @Published var adoptAppPath: String?
    @Published var adoptIPAPath: String?

    // Push
    @Published var pushPlans: [String: PushPlan] = [:]
    @Published var pushError: LauncherFailure?

    // Misc
    @Published var lastExportPath: String?
    @Published private(set) var scenario: MockScenario?

    let settings: LauncherSettings
    let kind: LauncherRunMode
    let runner: CommandRunning
    let pack: PackBackend
    let bridge: DeviceBridge
    let installer: InstallBackend
    let logStore: LogStore
    let stagingRoot: URL

    private var lastInstallLine: String?
    private let maximumVisibleLogs = 800

    // MARK: init

    init(settings: LauncherSettings, kind: LauncherRunMode) {
        self.settings = settings
        self.kind = kind
        let logURL: URL
        if kind == .live {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            logURL = support
                .appendingPathComponent("3ds2apple-launcher", isDirectory: true)
                .appendingPathComponent("launcher.log")
        } else {
            logURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("3ds2apple-launcher-mock", isDirectory: true)
                .appendingPathComponent("launcher.log")
        }
        self.logStore = LogStore(logFileURL: logURL)
        let paths = ToolchainPaths.resolve(settings: settings)

        if kind == .mock {
            self.runner = MockCommandRunner()
            self.pack = MockPackBackend()
            self.bridge = MockDeviceBridge()
            self.installer = MockInstallBackend(readinessState: MockFixtures.environment().apple)
            self.stagingRoot = MockFixtures.stagingRoot
            MockFixtures.ensurePackageTree()
        } else {
            let runner = RealCommandRunner()
            self.runner = runner
            let repoURL = URL(fileURLWithPath: settings.repoRoot, isDirectory: true)
            if let packBinary = paths.packCLI {
                self.pack = PackCLI(
                    runner: runner,
                    binary: packBinary,
                    repoRoot: repoURL,
                    outRoot: settings.outRootURL,
                    outArgument: settings.outDir
                )
            } else {
                self.pack = MissingPackBackend(
                    outRoot: settings.outRootURL,
                    repoRoot: repoURL,
                    reason: "Checked: " + settings.repoRoot + "/builder/target/release/3ds2apple-pack"
                )
            }
            if let devpush = paths.devpush {
                self.bridge = DevpushCLI(binary: devpush, mockDirectory: nil, runner: runner)
            } else {
                self.bridge = UnavailableDeviceBridge()
            }
            self.installer = XcodeInstallBackend(runner: runner, repoRoot: repoURL, paths: paths)
            self.stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("3ds2apple-launcher", isDirectory: true)
                .appendingPathComponent("staging", isDirectory: true)
        }
        appendLog(.info, "launcher", "3ds2apple launcher 0.1.0 started (" + (kind == .mock ? "mock mode" : "live mode") + ")")
        appendLog(.info, "launcher", "checkout: " + settings.repoRoot)
    }

    // MARK: convenience

    var selectedGame: GameEntry? {
        guard let selectedGameID else { return games.first }
        return games.first(where: { $0.titleID == selectedGameID }) ?? games.first
    }

    var activeTask: TaskRecord? {
        guard let activeTaskID else { return nil }
        return tasks.first(where: { $0.id == activeTaskID })
    }

    var selectedDevice: DeviceInfo? {
        devices.first(where: { $0.udid == selectedDeviceUDID })
    }

    var isMock: Bool { kind == .mock }

    func game(id: String) -> GameEntry? {
        games.first(where: { $0.titleID == id })
    }

    func latestTask(forGame id: String?) -> TaskRecord? {
        guard let id else { return tasks.first }
        return tasks.first(where: { $0.titleID == id })
    }

    // MARK: logging

    func appendLog(_ level: LogLevel, _ category: String, _ message: String) {
        let entry = logStore.append(level: level, category: category, message: message)
        logs.append(entry)
        if logs.count > maximumVisibleLogs {
            logs.removeFirst(logs.count - maximumVisibleLogs)
        }
    }

    func clearLogs() {
        logStore.clear()
        logs.removeAll()
    }

    func exportLog() {
        let text = logStore.exportText()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("3ds2apple-launcher-log-" + timestampForFile() + ".txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastExportPath = url.path
            appendLog(.success, "launcher", "log exported to " + url.path)
        } catch {
            appendLog(.error, "launcher", "could not export the log: " + error.localizedDescription)
        }
    }

    private func timestampForFile() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: task bookkeeping

    private func startTask(kind: TaskKind, title: String, titleID: String?, stages: [PipelineStage]) -> UUID {
        let task = TaskRecord(
            kind: kind,
            title: title,
            titleID: titleID,
            state: .running,
            stages: stages,
            startedAt: Date(),
            endedAt: nil,
            errorMessage: nil,
            errorHint: nil,
            detail: ""
        )
        tasks.insert(task, at: 0)
        activeTaskID = task.id
        return task.id
    }

    private func updateTask(_ id: UUID, _ body: (inout TaskRecord) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        body(&tasks[index])
    }

    private func setStage(_ taskID: UUID, _ index: Int, _ state: StageState, _ detail: String? = nil) {
        updateTask(taskID) { task in
            guard index >= 0 && index < task.stages.count else { return }
            task.stages[index].state = state
            if let detail { task.stages[index].detail = detail }
        }
    }

    private func finishTask(
        _ taskID: UUID,
        _ state: TaskState,
        message: String? = nil,
        hint: String? = nil
    ) {
        updateTask(taskID) { task in
            task.state = state
            task.endedAt = Date()
            if let message { task.errorMessage = message }
            if let hint { task.errorHint = hint }
            if state != .failed {
                for index in task.stages.indices where task.stages[index].state == .running {
                    task.stages[index].state = .succeeded
                }
            }
        }
        if activeTaskID == taskID { activeTaskID = nil }
    }

    private func beginBusy() -> Bool {
        if isBusy {
            banner = Banner(kind: .warning, title: "A task is already running", message: "Wait for it to finish (or cancel it) before starting another one.")
            return false
        }
        isBusy = true
        return true
    }

    private func endBusy() {
        isBusy = false
    }

    func cancelActiveTask() {
        runner.terminateAll()
        if let activeTaskID {
            updateTask(activeTaskID) { task in
                task.state = .cancelled
                task.endedAt = Date()
                for index in task.stages.indices where task.stages[index].state == .running {
                    task.stages[index].state = .failed
                    task.stages[index].detail = "cancelled"
                }
            }
        }
        activeTaskID = nil
        isBusy = false
        appendLog(.warn, "launcher", "active task cancelled")
    }

    // MARK: environment

    func refreshEnvironment() async {
        appendLog(.info, "toolchain", "probing toolchain and Apple ID readiness")
        let report: EnvironmentReport
        if kind == .mock {
            report = MockFixtures.environment()
        } else {
            report = await ToolchainProbe(runner: runner, settings: settings).probe()
        }
        envReport = report
        appleReadiness = report.apple
        appendLog(.info, "toolchain", "ready: " + String(report.okCount) + "/" + String(report.tools.count) + " checks passed")
        for tool in report.tools where tool.state != .ok {
            appendLog(.warn, "toolchain", tool.name + ": " + tool.detail + " - " + tool.hint)
        }
    }

    // MARK: ROM detection and import

    func detectROM(at path: String) async {
        guard !path.isEmpty else { return }
        guard beginBusy() else { return }
        defer { endBusy() }
        detectedROMError = nil
        let taskID = startTask(
            kind: .detect,
            title: "Read ROM header",
            titleID: nil,
            stages: [PipelineStage(title: "Read NCSD/NCCH header", detail: path, state: .running)]
        )
        appendLog(.command, "pack", "rom inspect \"" + path + "\" --json")
        do {
            let rom = try await pack.inspectROM(path)
            detectedROM = rom
            setStage(taskID, 0, .succeeded, rom.container.uppercased() + " header, " + FileProbe.formatBytes(rom.bytes))
            finishTask(taskID, .succeeded)
            appendLog(.success, "rom", "titleID=" + rom.titleID + " productCode=" + rom.productCode + " container=" + rom.container + " bytes=" + FileProbe.formatBytes(rom.bytes))
        } catch {
            let failure = error.launcherFailure()
            detectedROM = nil
            detectedROMError = failure.plainText
            setStage(taskID, 0, .failed, failure.message)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "rom", failure.message + " " + failure.hint)
            banner = Banner(kind: .error, title: "ROM not recognised", message: failure.message + " " + failure.hint)
        }
    }

    func importDetected(includeROM: Bool = false) async {
        guard let rom = detectedROM else {
            banner = Banner(kind: .warning, title: "No ROM selected", message: "Choose a decrypted .3ds/.cci file first.")
            return
        }
        guard beginBusy() else { return }
        defer { endBusy() }
        let taskID = startTask(
            kind: .importROM,
            title: "Import " + rom.displayName,
            titleID: rom.titleID,
            stages: [
                PipelineStage(title: "Read decrypted header", detail: rom.container.uppercased(), state: .succeeded),
                PipelineStage(title: "Queue AOT package (ROM-free)", detail: "out/packages/" + rom.titleID, state: .running),
                PipelineStage(title: "Stage game data for push", detail: "out/launcher-roms (gitignored)", state: .pending),
                PipelineStage(title: "Write GameInfo.json", detail: "single writer: desktop CLI", state: .pending),
            ]
        )
        appendLog(.command, "pack", "packages add --roms \"" + rom.path + "\" --json  (no --include-rom: the IPA stays ROM-free)")
        do {
            let package = try await pack.importROM(rom.path, displayName: rom.displayName, includeROM: false)
            var game = makeGame(from: rom, package: package)
            setStage(taskID, 1, .succeeded, "queued " + game.titleID + " (ROM not bundled)")
            setStage(taskID, 2, .running, "staging a gitignored game-data copy for the device push")
            let staged = try stageROMData(rom)
            game.romDataPath = staged.path
            game.romSha256 = staged.sha256
            upsertGame(game)
            selectedGameID = game.titleID
            setStage(taskID, 2, .succeeded, staged.path)
            setStage(taskID, 3, .succeeded, "GameInfo.json written by the desktop CLI")
            finishTask(taskID, .succeeded)
            detectedROM = nil
            appendLog(.success, "import", "queued " + game.displayName + " (" + game.titleID + "): AOT code goes into the signed library IPA, game data into out/launcher-roms")
            banner = Banner(
                kind: .success,
                title: "Imported " + game.displayName,
                message: "Package queued (ROM-free). Next: Build AOT, then build & install the library IPA."
            )
            screen = .library
        } catch {
            let failure = error.launcherFailure()
            setStage(taskID, 1, .failed, failure.message)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "import", failure.message + " " + failure.hint)
            banner = Banner(kind: .error, title: "Import failed", message: failure.message + " " + failure.hint)
        }
    }

    private func makeGame(from rom: DetectedROM, package: DetectedPackage) -> GameEntry {
        let existing = game(id: package.titleID)
        return GameEntry(
            titleID: package.titleID,
            displayName: package.displayName.isEmpty ? rom.displayName : package.displayName,
            productCode: package.productCode.isEmpty ? rom.productCode : package.productCode,
            romPath: rom.path,
            romBytes: rom.bytes,
            container: rom.container,
            aotVersion: package.aotVersion,
            buildSlug: slug(displayName: rom.displayName, titleID: package.titleID),
            phase: existing?.phase == .built ? .built : .queued,
            packPath: existing?.packPath,
            packBytes: existing?.packBytes,
            packSha256: existing?.packSha256,
            packFormat: existing?.packFormat,
            saveNamespace: package.titleID,
            pushedAt: existing?.pushedAt,
            lastError: nil,
            romDataPath: existing?.romDataPath,
            romSha256: existing?.romSha256
        )
    }

    private func slug(displayName: String, titleID: String) -> String {
        let lowered = displayName.lowercased()
        var output = ""
        var lastWasDash = false
        for character in lowered {
            if character.isASCII && (character.isLetter || character.isNumber) {
                output.append(character)
                lastWasDash = false
            } else if !lastWasDash && !output.isEmpty {
                output.append("-")
                lastWasDash = true
            }
        }
        let suffix = String(titleID.suffix(8)).lowercased()
        return (output.isEmpty ? "game" : output) + "-" + suffix
    }

    private func upsertGame(_ game: GameEntry) {
        if let index = games.firstIndex(where: { $0.titleID == game.titleID }) {
            games[index] = game
        } else {
            games.append(game)
        }
        games.sort { $0.titleID < $1.titleID }
    }

    // MARK: packages and build

    func refreshPackages() async {
        do {
            let packages = try await pack.listPackages()
            for package in packages {
                if let index = games.firstIndex(where: { $0.titleID == package.titleID }) {
                    games[index].aotVersion = package.aotVersion
                    if let packFile = package.pack {
                        games[index].packPath = pack.outRoot.appendingPathComponent("packages/\(package.titleID)/GamePack.dylib").path
                        games[index].packBytes = packFile.bytes
                        games[index].packSha256 = packFile.sha256
                        games[index].packFormat = packFile.format
                    }
                    if package.isBuilt {
                        if games[index].phase != .pushed { games[index].phase = .built }
                    } else if games[index].phase == .queued || games[index].phase == .failed {
                        if !package.issues.isEmpty {
                            games[index].phase = .failed
                            games[index].lastError = package.issues.joined(separator: "; ")
                        }
                    }
                    if games[index].romDataPath == nil {
                        let planner = PushPlanner(outRoot: pack.outRoot, bundleID: settings.deviceBundleID)
                        if let staged = planner.resolveROMDataPath(for: games[index]) {
                            games[index].romDataPath = staged
                            games[index].romSha256 = FileProbe.sha256(ofFile: staged)
                        }
                    }
                }
            }
        } catch {
            appendLog(.warn, "packages", "could not list packages: " + error.localizedDescription)
        }
    }

    func build(gameID: String) async {
        guard let game = game(id: gameID) else { return }
        guard beginBusy() else { return }
        defer { endBusy() }
        let mode = settings.buildMode
        var stages: [PipelineStage]
        switch mode {
        case .dryRun:
            stages = [PipelineStage(title: "Validate package", detail: "out/packages/" + game.titleID, state: .running)]
        case .fake:
            stages = [
                PipelineStage(title: "Validate package", detail: game.titleID, state: .running),
                PipelineStage(title: "Build placeholder pack", detail: "scripts/build-game-pack.sh --fake", state: .pending),
                PipelineStage(title: "Record manifest", detail: "GameInfo.json", state: .pending),
            ]
        case .real:
            stages = [
                PipelineStage(title: "Validate package", detail: game.titleID, state: .running),
                PipelineStage(title: "Run 3dsrecomp", detail: "ROM -> generated C", state: .pending),
                PipelineStage(title: "Compile iOS archive", detail: "arm64-apple-ios16.0", state: .pending),
                PipelineStage(title: "Link GamePack.dylib", detail: "zk_gamepack_register", state: .pending),
                PipelineStage(title: "Record manifest", detail: "GameInfo.json", state: .pending),
            ]
        }
        let taskID = startTask(kind: .buildAOT, title: "Build GamePack - " + game.displayName, titleID: game.titleID, stages: stages)
        if mode != .dryRun {
            updateGame(gameID) { $0.phase = .building; $0.lastError = nil }
        }
        appendLog(.info, "build", "mode: " + mode.title + " - " + mode.explanation)
        do {
            setStage(taskID, 0, .succeeded, "package and ROM validated")
            if mode == .dryRun {
                let built = try await pack.build(titleIDs: [gameID], mode: mode) { [weak self] level, line in
                    Task { @MainActor in self?.appendLog(level, "build", line) }
                }
                _ = built
                finishTask(taskID, .succeeded)
                appendLog(.success, "build", "dry run finished: command plan printed, nothing written")
                banner = Banner(kind: .info, title: "Dry run finished", message: "No files were compiled. Switch the build mode to build a real GamePack.")
                return
            }
            // Fake and real both go through pack.build; stage animation is fed by
            // the CLI command plus a coarse stage timeline.
            setStage(taskID, 1, .running, "started")
            let built = try await pack.build(titleIDs: [gameID], mode: mode) { [weak self] level, line in
                Task { @MainActor in self?.appendLog(level, "build", line) }
            }
            for index in stages.indices.dropFirst() where index < task_stages_count(taskID) {
                setStage(taskID, index, index == stages.count - 1 ? .running : .succeeded, nil)
            }
            let manifest = try await pack.readManifest(titleID: gameID)
            let packURL = pack.outRoot.appendingPathComponent("packages/\(gameID)/GamePack.dylib")
            updateGame(gameID) { entry in
                entry.phase = .built
                entry.packPath = packURL.path
                entry.packBytes = manifest.packBytes
                entry.packSha256 = manifest.packSha256
                entry.packFormat = manifest.packFormat
                entry.lastError = nil
            }
            let finalIndex = max(0, task_stages_count(taskID) - 1)
            setStage(taskID, finalIndex, .succeeded, "GamePack.dylib recorded")
            finishTask(taskID, .succeeded)
            appendLog(.success, "build", "GamePack ready for " + game.displayName + " (" + FileProbe.formatBytes(manifest.packBytes ?? 0) + ")")
            banner = Banner(kind: .success, title: "GamePack built", message: game.displayName + " is AOT ready. Build & install the library IPA, then push its game data.")
            _ = built
        } catch {
            let failure = error.launcherFailure()
            updateGame(gameID) { $0.phase = .failed; $0.lastError = failure.message }
            if let index = tasks.firstIndex(where: { $0.id == taskID }) {
                for stageIndex in tasks[index].stages.indices where tasks[index].stages[stageIndex].state == .running {
                    setStage(taskID, stageIndex, .failed, failure.message)
                }
            }
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "build", failure.message + " " + failure.hint)
            banner = Banner(kind: .error, title: "Build failed", message: failure.message + " " + failure.hint)
        }
    }

    private func task_stages_count(_ taskID: UUID) -> Int {
        tasks.first(where: { $0.id == taskID })?.stages.count ?? 0
    }

    private func updateGame(_ id: String, _ body: (inout GameEntry) -> Void) {
        guard let index = games.firstIndex(where: { $0.titleID == id }) else { return }
        body(&games[index])
    }

    func verifyPackages() async {
        guard beginBusy() else { return }
        defer { endBusy() }
        let taskID = startTask(
            kind: .verifyPackages,
            title: "Verify packages",
            titleID: nil,
            stages: [PipelineStage(title: "Hash GamePack and bundled ROM", detail: "packages verify", state: .running)]
        )
        do {
            let issues = try await pack.verify()
            if issues.isEmpty {
                setStage(taskID, 0, .succeeded, "all manifests consistent")
                finishTask(taskID, .succeeded)
                banner = Banner(kind: .success, title: "Packages verified", message: "Every manifest and pack hash is consistent.")
            } else {
                setStage(taskID, 0, .failed, issues.joined(separator: " | "))
                finishTask(taskID, .failed, message: "Package problems found", hint: issues.joined(separator: "\n"))
                banner = Banner(kind: .warning, title: "Package problems", message: issues.joined(separator: "; "))
            }
        } catch {
            let failure = error.launcherFailure()
            setStage(taskID, 0, .failed, failure.message)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
        }
    }

    // MARK: devices

    func detectDevices() async {
        guard beginBusy() else { return }
        defer { endBusy() }
        let taskID = startTask(
            kind: .detectDevice,
            title: "Detect devices",
            titleID: nil,
            stages: [
                PipelineStage(title: "Query device bridge", detail: bridge.displayName, state: .running),
                PipelineStage(title: "Read paired devices", detail: "usbmuxd / CoreDevice", state: .pending),
            ]
        )
        do {
            let found = try await bridge.devices()
            devices = found
            if selectedDeviceUDID == nil || !found.contains(where: { $0.udid == selectedDeviceUDID }) {
                selectedDeviceUDID = found.first?.udid
            }
            setStage(taskID, 0, .succeeded, bridge.displayName)
            setStage(taskID, 1, .succeeded, String(found.count) + " device(s)")
            finishTask(taskID, .succeeded)
            appendLog(.success, "device", "found " + String(found.count) + " device(s)")
            if found.isEmpty {
                banner = Banner(kind: .warning, title: "No device found", message: "Connect the iPhone/iPad with a cable, unlock it and tap Trust.")
            }
        } catch {
            let failure = error.launcherFailure()
            setStage(taskID, 0, .failed, failure.message)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "device", failure.message + " " + failure.hint)
            banner = Banner(kind: .error, title: "Device bridge error", message: failure.message + " " + failure.hint)
        }
    }

    // MARK: base shell install

    // MARK: library IPA build + install (corrected architecture)

    private var libraryStageNames: [String] {
        ["Check Apple ID readiness", "Build signed shell app", "Embed GamePacks + GameCatalog", "Sign packs + install", "Verify install"]
    }

    var builtGames: [GameEntry] {
        games.filter { $0.phase == .built || $0.phase == .pushed }
    }

    var libraryNeedsRebuild: Bool {
        let installed = Set(settings.libraryInstalledTitles)
        let built = Set(builtGames.map { $0.titleID })
        return !built.isEmpty && installed != built
    }

    func markLibraryInstalled(titles: [String], ipaPath: String) {
        settings.libraryInstalledTitles = titles
        settings.libraryIPAPath = ipaPath
        settings.libraryInstalledAt = Date()
        settings.save()
    }

    /// Build the ROM-free shell app, allocate the built GamePacks into it
    /// (Frameworks/GamePack-<TITLEID>.dylib + GameCatalog.json), sign the nested
    /// packs and the app with the local Apple Development identity, then install
    /// with devicectl. Adding/removing a game means rebuilding + reinstalling the
    /// library IPA; pushed ROM data in Documents survives the reinstall.
    func buildAndInstallLibrary() async {
        guard beginBusy() else { return }
        defer { endBusy() }
        installResult = nil
        lastInstallFailure = nil
        installProgressLines.removeAll()
        let titles = builtGames.map { $0.titleID }
        guard !titles.isEmpty else {
            banner = Banner(kind: .warning, title: "No built GamePacks", message: "Build at least one GamePack (AOT READY) before installing the library.")
            return
        }
        let taskID = startTask(
            kind: .installShell,
            title: "Build & install library (" + String(titles.count) + " game(s))",
            titleID: nil,
            stages: libraryStageNames.map { PipelineStage(title: $0, detail: "", state: .pending) }
        )
        appendLog(.info, "library", "strategy: " + settings.installStrategy.title + " - games: " + titles.joined(separator: ", "))
        let backend: InstallBackend
        if settings.installStrategy == .mock {
            backend = MockInstallBackend(readinessState: MockFixtures.environment().apple)
        } else {
            backend = installer
        }
        setStage(taskID, 0, .running, "probing Xcode and Apple ID assets")
        let readiness = await backend.readiness(teamID: settings.teamID)
        appleReadiness = readiness
        let impactorFlow = settings.installStrategy == .impactor
        if !impactorFlow {
            if !readiness.hasSigningAssets {
                finishWithSigningFailure(readiness, taskID: taskID, stage: 0)
                return
            }
            if settings.teamID.trimmingCharacters(in: .whitespaces).isEmpty {
                let failure = LauncherFailure(
                    code: "team_missing",
                    message: "Your Apple Developer Team ID is missing.",
                    hint: "Enter the 10-character Team ID on the Shell + library screen.",
                    detail: nil,
                    exitCode: nil
                )
                lastInstallFailure = failure
                setStage(taskID, 0, .failed, "team ID missing")
                finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
                banner = Banner(kind: .error, title: "Team ID missing", message: failure.plainText)
                return
            }
        }
        setStage(taskID, 0, .succeeded, readiness.hasSigningAssets ? "Team " + settings.teamID : "Impactor manual path")
        let options = InstallOptions(
            strategy: settings.installStrategy,
            teamID: settings.teamID,
            bundleID: settings.deviceBundleID,
            deviceUDID: selectedDeviceUDID,
            allowProvisioningUpdates: true,
            adoptAppPath: adoptAppPath,
            adoptIPAPath: adoptIPAPath
        )
        do {
            if let adopted = adoptIPAPath, !adopted.isEmpty {
                appendLog(.info, "library", "using adopted library IPA: " + adopted)
                await openLibraryInImpactor(ipaPath: adopted, backend: backend, options: options, taskID: taskID)
                return
            }
            let shellApp: String
            if impactorFlow {
                setStage(taskID, 1, .running, "building unsigned shell app (Impactor signs later)")
                shellApp = try await backend.buildShellApp(signed: false, options: options) { [weak self] progress in
                    Task { @MainActor in self?.applyLibraryProgress(progress, taskID: taskID) }
                }
            } else {
                setStage(taskID, 1, .running, "xcodebuild automatic signing")
                shellApp = try await backend.buildShellApp(signed: true, options: options) { [weak self] progress in
                    Task { @MainActor in self?.applyLibraryProgress(progress, taskID: taskID) }
                }
            }
            setStage(taskID, 1, .succeeded, shellApp)
            setStage(taskID, 2, .running, "3ds2apple-pack pack --all --execute (GamePacks + GameCatalog only)")
            let ipaOutDir = settings.repoRootURL.appendingPathComponent("IPA").path
            let libraryName = "3ds2apple-library"
            let dryRun = settings.buildMode == .dryRun
            let result = try await pack.buildLibraryIPA(
                titleIDs: titles,
                baseAppPath: shellApp,
                ipaOutDir: ipaOutDir,
                ipaName: libraryName,
                dryRun: dryRun,
                onLine: { [weak self] level, line in
                    Task { @MainActor in self?.appendLog(level, "library", line) }
                }
            )
            if dryRun || !result.executed || result.ipaPath == nil {
                setStage(taskID, 2, .succeeded, "dry run: plan printed, no IPA written")
                finishTask(taskID, .succeeded)
                banner = Banner(kind: .info, title: "Dry run finished", message: "The library packaging plan was printed; switch the build mode to build a real library IPA.")
                return
            }
            guard let ipaPath = result.ipaPath else {
                throw LauncherFailure(code: "library_ipa_missing", message: "The library IPA path was not reported.", hint: "Retry the build.", detail: nil, exitCode: nil)
            }
            settings.libraryIPAPath = ipaPath
            setStage(taskID, 2, .succeeded, ipaPath)
            if impactorFlow {
                setStage(taskID, 3, .running, "opening the official Impactor")
                try await backend.openLibraryIPAInImpactor(ipaPath: ipaPath, options: options)
                setStage(taskID, 3, .succeeded, "Impactor opened with " + (ipaPath as NSString).lastPathComponent)
                finishTask(taskID, .succeeded)
                appendLog(.success, "library", "library IPA built; finish sign/install in Impactor: " + ipaPath)
                banner = Banner(kind: .info, title: "Library IPA ready for Impactor", message: "Sign in with your Apple ID inside Impactor and install the IPA. Then push game data from the Device push screen.")
                return
            }
            setStage(taskID, 3, .running, "codesign embedded GamePacks + app, then devicectl install")
            let installed = try await backend.installLibrary(ipaPath: ipaPath, signedBaseAppPath: shellApp, options: options) { [weak self] progress in
                Task { @MainActor in self?.applyLibraryProgress(progress, taskID: taskID) }
            }
            installResult = installed
            setStage(taskID, 3, .succeeded, "installed with devicectl")
            setStage(taskID, 4, .running, "verifying on the device")
            if bridge.mode == .live {
                if let attribute = try? await bridge.appAttr(bundleID: settings.deviceBundleID, udid: selectedDeviceUDID) {
                    if attribute.installed {
                        setStage(taskID, 4, .succeeded, "app-attr: shell " + (attribute.appBundleVersion ?? "installed"))
                    } else {
                        setStage(taskID, 4, .failed, "app-attr says the shell is not installed yet")
                    }
                } else {
                    setStage(taskID, 4, .skipped, "device bridge unavailable")
                }
            } else {
                setStage(taskID, 4, .succeeded, "mock verification")
            }
            markLibraryInstalled(titles: titles, ipaPath: ipaPath)
            finishTask(taskID, .succeeded)
            appendLog(.success, "library", "library installed with " + String(titles.count) + " game(s); Documents ROM data persists across reinstalls")
            banner = Banner(kind: .success, title: "Library installed", message: "GamePacks live in the signed app. Next: push GameRom.cci + GameInfo.json for each game.")
            screen = .library
        } catch {
            let failure = error.launcherFailure()
            lastInstallFailure = failure
            if let stageIndex = tasks.first(where: { $0.id == taskID })?.stages.firstIndex(where: { $0.state == .running }) {
                setStage(taskID, stageIndex, .failed, failure.message)
            }
            installProgressLines.append("error: " + failure.message)
            installProgressLines.append(failure.hint)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "library", failure.message + " " + failure.hint)
            banner = Banner(kind: .error, title: "Library install failed", message: failure.message + " " + failure.hint)
        }
    }

    private func finishWithSigningFailure(_ readiness: AppleReadiness, taskID: UUID, stage: Int) {
        let failure = LauncherFailure(
            code: "no_signing_assets",
            message: readiness.plainTextState,
            hint: readiness.hint,
            detail: readiness.xcodeVersion,
            exitCode: nil
        )
        lastInstallFailure = failure
        setStage(taskID, stage, .failed, "no signing assets")
        finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
        appendLog(.error, "library", failure.message + " " + failure.hint)
        banner = Banner(kind: .error, title: "Apple ID signing not set up", message: failure.message + " " + failure.hint)
    }

    private func openLibraryInImpactor(ipaPath: String, backend: InstallBackend, options: InstallOptions, taskID: UUID) async {
        do {
            try await backend.openLibraryIPAInImpactor(ipaPath: ipaPath, options: options)
            setStage(taskID, 3, .succeeded, "Impactor opened")
            finishTask(taskID, .succeeded)
            banner = Banner(kind: .info, title: "Impactor opened", message: "Finish the sign/install there, then push game data.")
        } catch {
            let failure = error.launcherFailure()
            lastInstallFailure = failure
            setStage(taskID, 3, .failed, failure.message)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            banner = Banner(kind: .error, title: "Impactor", message: failure.message + " " + failure.hint)
        }
    }

    private func libraryStageIndex(for name: String) -> Int? {
        let lowered = name.lowercased()
        if lowered.contains("readiness") || lowered.contains("apple") { return 0 }
        if lowered.contains("xcodegen") || lowered.contains("building") || lowered.contains("shell app") { return 1 }
        if lowered.contains("embed") || lowered.contains("catalog") { return 2 }
        if lowered.contains("sign") || lowered.contains("install") || lowered.contains("unpack") { return 3 }
        if lowered.contains("verify") { return 4 }
        return nil
    }

    private func applyLibraryProgress(_ progress: InstallProgress, taskID: UUID) {
        if let index = libraryStageIndex(for: progress.stage) {
            setStage(taskID, index, .running, progress.line)
        }
        if progress.line != lastInstallLine {
            lastInstallLine = progress.line
            installProgressLines.append(progress.line)
            if installProgressLines.count > 140 { installProgressLines.removeFirst(installProgressLines.count - 140) }
            appendLog(.info, "library", progress.line)
        }
    }

    var libraryCommandPlan: [String] {
        installer.commandPlan(options: InstallOptions(
            strategy: settings.installStrategy,
            teamID: settings.teamID,
            bundleID: settings.deviceBundleID,
            deviceUDID: selectedDeviceUDID,
            allowProvisioningUpdates: true,
            adoptAppPath: nil,
            adoptIPAPath: adoptIPAPath
        ))
    }

    // MARK: ROM data staging (push source; gitignored, never in the IPA)

    /// Copy (or hardlink) the user's ROM into out/launcher-roms. The library IPA
    /// only carries AOT code, so this gitignored copy is what the device push
    /// sends as GameRom.<ext>; it also survives library re-installs.
    private func stageROMData(_ rom: DetectedROM) throws -> (path: String, sha256: String) {
        if kind == .mock {
            MockFixtures.ensurePackageTree()
            let path = pack.outRoot.appendingPathComponent("launcher-roms/" + rom.titleID + ".cci").path
            return (path, "7ea17f4d6a1cfefdbf98a6f5b0c4e9a1a9a5f4e6b7c8d9e0f1a2b3c4d5e6f708")
        }
        let fileManager = FileManager.default
        let directory = pack.outRoot.appendingPathComponent("launcher-roms")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceExtension = (rom.path as NSString).pathExtension
        let ext = sourceExtension.isEmpty ? "cci" : sourceExtension.lowercased()
        let target = directory.appendingPathComponent(rom.titleID + "." + ext)
        if !FileProbe.exists(target.path) {
            do {
                try fileManager.linkItem(atPath: rom.path, toPath: target.path)
                appendLog(.info, "rom", "hardlinked game data into out/launcher-roms (no extra copy): " + target.lastPathComponent)
            } catch {
                try fileManager.copyItem(atPath: rom.path, toPath: target.path)
                appendLog(.info, "rom", "copied game data into out/launcher-roms: " + target.lastPathComponent)
            }
        }
        guard let sha = FileProbe.sha256(ofFile: target.path) else {
            throw LauncherFailure(code: "rom_stage_failed", message: "Could not hash the staged game data.", hint: "Check free disk space and file permissions.", detail: target.path, exitCode: nil)
        }
        return (target.path, sha)
    }

    // MARK: push

    @discardableResult
    func preparePush(gameID: String, quiet: Bool = false) async -> PushPlan? {
        guard let current = game(id: gameID) else { return nil }
        var game = current
        do {
            if kind == .mock { MockFixtures.ensurePackageTree() }
            let manifest = try await pack.readManifest(titleID: gameID)
            let planner = PushPlanner(outRoot: pack.outRoot, bundleID: settings.deviceBundleID)
            if game.romDataPath == nil, let staged = planner.resolveROMDataPath(for: game) {
                game.romDataPath = staged
                if game.romSha256 == nil { game.romSha256 = FileProbe.sha256(ofFile: staged) }
                updateGame(gameID) { entry in
                    entry.romDataPath = game.romDataPath
                    entry.romSha256 = game.romSha256
                }
            }
            let device = selectedDevice
            let plan = try planner.plan(
                game: game,
                manifest: manifest,
                device: device,
                stagingDirectory: stagingRoot
            )
            pushPlans[gameID] = plan
            pushError = nil
            if !quiet {
                appendLog(.info, "push", "plan: " + String(plan.files.count) + " files -> " + plan.remoteDirectory + " (" + FileProbe.formatBytes(plan.totalBytes) + ")")
            }
            return plan
        } catch {
            let failure = error.launcherFailure()
            pushError = failure
            if !quiet {
                appendLog(.error, "push", failure.message + " " + failure.hint)
                banner = Banner(kind: .error, title: "Cannot prepare push", message: failure.message + " " + failure.hint)
            }
            return nil
        }
    }

    func pushGame(gameID: String) async {
        guard beginBusy() else { return }
        defer { endBusy() }
        if pushPlans[gameID] == nil {
            _ = await preparePush(gameID: gameID, quiet: true)
        }
        guard var plan = pushPlans[gameID] else {
            banner = Banner(kind: .error, title: "Push not ready", message: pushError?.plainText ?? "Prepare the push plan first.")
            return
        }
        guard let udid = selectedDeviceUDID else {
            let failure = LauncherFailure(
                code: "device_missing",
                message: "No device selected.",
                hint: "Connect the iPhone/iPad, tap Trust, then refresh the device list.",
                detail: nil,
                exitCode: nil
            )
            pushError = failure
            banner = Banner(kind: .error, title: "No device", message: failure.plainText)
            return
        }
        let installedLibrary = Set(settings.libraryInstalledTitles)
        if !installedLibrary.contains(gameID.uppercased()) {
            let failure = LauncherFailure(
                code: "library_not_installed",
                message: "This game is not in the installed library IPA.",
                hint: "GamePacks must live inside the signed app. Open Shell + library and press Build & install library IPA; pushed ROM data survives the reinstall.",
                detail: installedLibrary.isEmpty ? "no library installed yet" : "installed library: " + installedLibrary.sorted().joined(separator: ", "),
                exitCode: nil
            )
            pushError = failure
            banner = Banner(kind: .error, title: "Library out of date", message: failure.message + " " + failure.hint)
            return
        }
        plan.deviceUDID = udid
        plan.deviceName = selectedDevice.map { $0.name + " (" + $0.model + ")" } ?? "device"
        pushPlans[gameID] = plan
        let taskID = startTask(
            kind: .pushGame,
            title: "Push " + plan.displayName,
            titleID: gameID,
            stages: [
                PipelineStage(title: "Validate files", detail: String(plan.files.count) + " files", state: .running),
                PipelineStage(title: "Create remote folder", detail: plan.remoteDirectory, state: .pending),
                PipelineStage(title: "Upload files", detail: "GameInfo.json last", state: .pending),
                PipelineStage(title: "Verify on device", detail: "stat + app-attr", state: .pending),
            ]
        )
        do {
            for index in plan.files.indices {
                let path = plan.files[index].localPath
                guard FileProbe.exists(path) else {
                    throw LauncherFailure(
                        code: "push_file_missing",
                        message: "Missing local file: " + plan.files[index].name,
                        hint: "Rebuild or re-import the package, then prepare the push again.",
                        detail: path,
                        exitCode: nil
                    )
                }
            }
            setStage(taskID, 0, .succeeded, plan.files.count.description + " files, " + FileProbe.formatBytes(plan.totalBytes))
            setStage(taskID, 1, .running, plan.remoteDirectory)
            appendLog(.command, "devpush", "mkdir " + plan.remoteDirectory)
            try await bridge.mkdir(bundleID: plan.bundleID, path: plan.remoteDirectory, udid: udid)
            setStage(taskID, 1, .succeeded, plan.remoteDirectory)
            setStage(taskID, 2, .running, "0 / " + String(plan.files.count))
            for index in plan.files.indices {
                plan.files[index].state = .running
                plan.files[index].progress = 0
                pushPlans[gameID] = plan
                appendLog(.command, "devpush", "put " + plan.files[index].name + " (" + FileProbe.formatBytes(plan.files[index].bytes) + ")")
                let put = try await bridge.put(
                    bundleID: plan.bundleID,
                    local: plan.files[index].localPath,
                    remote: plan.files[index].remotePath,
                    udid: udid,
                    onProgress: { [weak self] sent, total in
                        Task { @MainActor in
                            self?.updatePushFileProgress(gameID: gameID, fileIndex: index, sent: sent, total: total)
                        }
                    }
                )
                let expectedSize = FileProbe.size(plan.files[index].localPath) ?? put.bytes
                if let remote = try await bridge.stat(bundleID: plan.bundleID, path: plan.files[index].remotePath, udid: udid),
                   let remoteSize = remote.size,
                   remoteSize != expectedSize {
                    throw LauncherFailure(
                        code: "push_size_mismatch",
                        message: "The device has a different size for " + plan.files[index].name + ".",
                        hint: "The transfer was interrupted. Retry the push; the file will be overwritten.",
                        detail: "remote " + String(remoteSize) + " B vs local " + String(expectedSize) + " B",
                        exitCode: nil
                    )
                }
                plan.files[index].state = .succeeded
                plan.files[index].progress = 1
                pushPlans[gameID] = plan
                setStage(taskID, 2, .running, String(index + 1) + " / " + String(plan.files.count))
            }
            setStage(taskID, 2, .succeeded, String(plan.files.count) + " files uploaded")
            setStage(taskID, 3, .running, "checking the shell container")
            let attribute = try await bridge.appAttr(bundleID: plan.bundleID, udid: udid)
            guard attribute.installed else {
                throw LauncherFailure(
                    code: "app_missing",
                    message: "The base shell is not installed on the device.",
                    hint: "Install the base shell first (Base shell screen), then push the game.",
                    detail: nil,
                    exitCode: nil
                )
            }
            let remoteFiles = try await bridge.ls(bundleID: plan.bundleID, path: plan.remoteDirectory, udid: udid)
            let names = Set(remoteFiles.map { $0.name })
            let missing = plan.files.map { $0.name }.filter { !names.contains($0) }
            if !missing.isEmpty {
                throw LauncherFailure(
                    code: "push_verify_missing",
                    message: "The device is missing " + String(missing.count) + " file(s) after the transfer.",
                    hint: "Retry the push; the bridge overwrites files and the manifest goes last.",
                    detail: missing.joined(separator: ", "),
                    exitCode: nil
                )
            }
            plan.verified = true
            plan.verifiedAt = Date()
            pushPlans[gameID] = plan
            updateGame(gameID) { entry in
                entry.phase = .pushed
                entry.pushedAt = Date()
                entry.lastError = nil
            }
            setStage(taskID, 3, .succeeded, String(names.count) + " files visible in " + plan.remoteDirectory)
            finishTask(taskID, .succeeded)
            appendLog(.success, "push", plan.displayName + " pushed to " + plan.remoteDirectory)
            banner = Banner(kind: .success, title: "Game pushed", message: plan.displayName + " is now in Documents/Games on the device. Launch the shell to play.")
        } catch {
            let failure = error.launcherFailure()
            for index in plan.files.indices where plan.files[index].state == .running {
                plan.files[index].state = .failed
            }
            pushPlans[gameID] = plan
            updateGame(gameID) { $0.lastError = failure.message }
            if let index = tasks.firstIndex(where: { $0.id == taskID }) {
                for stageIndex in tasks[index].stages.indices where tasks[index].stages[stageIndex].state == .running {
                    setStage(taskID, stageIndex, .failed, failure.message)
                }
            }
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "push", failure.message + " " + failure.hint)
            banner = Banner(kind: .error, title: "Push failed", message: failure.message + " " + failure.hint)
        }
    }

    private func updatePushFileProgress(gameID: String, fileIndex: Int, sent: Int64, total: Int64) {
        guard var plan = pushPlans[gameID], fileIndex < plan.files.count else { return }
        let fraction = total > 0 ? min(1, Double(sent) / Double(total)) : 0
        plan.files[fileIndex].progress = fraction
        if plan.files[fileIndex].state == .pending {
            plan.files[fileIndex].state = .running
        }
        pushPlans[gameID] = plan
    }

    func verifyPush(gameID: String) async {
        guard let plan = pushPlans[gameID] else {
            banner = Banner(kind: .warning, title: "Nothing to verify", message: "Prepare and push the game first.")
            return
        }
        guard beginBusy() else { return }
        defer { endBusy() }
        let taskID = startTask(
            kind: .verifyPush,
            title: "Verify " + plan.displayName + " on device",
            titleID: gameID,
            stages: [
                PipelineStage(title: "Registered bundle", detail: plan.bundleID, state: .running),
                PipelineStage(title: "Remote files", detail: plan.remoteDirectory, state: .pending),
            ]
        )
        do {
            let attribute = try await bridge.appAttr(bundleID: plan.bundleID, udid: selectedDeviceUDID)
            setStage(taskID, 0, .succeeded, attribute.installed ? "shell installed" : "shell missing")
            let remote = try await bridge.ls(bundleID: plan.bundleID, path: plan.remoteDirectory, udid: selectedDeviceUDID)
            let expected = Set(plan.files.map { $0.name })
            let actual = Set(remote.map { $0.name })
            if expected.isSubset(of: actual) {
                setStage(taskID, 1, .succeeded, String(actual.count) + " files present")
                finishTask(taskID, .succeeded)
                var updated = plan
                updated.verified = true
                updated.verifiedAt = Date()
                pushPlans[gameID] = updated
                banner = Banner(kind: .success, title: "Verified", message: "All " + String(expected.count) + " files are on the device.")
            } else {
                let missing = expected.subtracting(actual)
                setStage(taskID, 1, .failed, "missing: " + missing.joined(separator: ", "))
                finishTask(taskID, .failed, message: "Some files are missing on the device.", hint: "Push the game again.")
            }
        } catch {
            let failure = error.launcherFailure()
            setStage(taskID, 0, .failed, failure.message)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            banner = Banner(kind: .error, title: "Verify failed", message: failure.message + " " + failure.hint)
        }
    }

    // MARK: mock seeding for screenshots and self-checks

    static func mock(scenario: MockScenario) -> AppModel {
        let settings = LauncherSettings(persist: false)
        settings.repoRoot = "/Users/you/3ds2apple"
        let model = AppModel(settings: settings, kind: .mock)
        model.seed(scenario: scenario)
        return model
    }

    func seed(scenario: MockScenario) {
        self.scenario = scenario
        MockFixtures.ensurePackageTree()
        games = MockFixtures.games()
        logs = MockFixtures.logsForScreenshots()
        envReport = MockFixtures.environment()
        appleReadiness = envReport?.apple
        devices = MockFixtures.devices
        selectedDeviceUDID = devices.first?.udid
        selectedGameID = MockFixtures.titlePokemonY
        installProgressLines = []
        lastInstallFailure = nil
        installResult = nil
        pushError = nil
        settings.teamID = ""
        settings.buildMode = .fake
        settings.libraryInstalledTitles = []
        settings.libraryIPAPath = ""
        settings.libraryInstalledAt = nil
        switch scenario {
        case .importDetected:
            screen = .importROM
            detectedROM = MockFixtures.detectedROM()
        case .library:
            screen = .library
            tasks = []
            settings.libraryInstalledTitles = [MockFixtures.titlePokemonY]
            settings.libraryIPAPath = "/Users/you/3ds2apple/IPA/3ds2apple-library.ipa"
            settings.libraryInstalledAt = Date().addingTimeInterval(-3_600)
        case .buildRunning:
            screen = .library
            tasks = MockFixtures.tasksForScreenshots().filter { $0.kind == .buildAOT }
            activeTaskID = tasks.first?.id
            games[0].phase = .building
            appendLog(.info, "build", "mock build running for screenshot")
        case .install:
            screen = .library
            tasks = MockFixtures.tasksForScreenshots().filter { $0.kind == .installShell }
            installProgressLines = MockFixtures.installLogLines()
            if let explanation = AppleErrorMapper.explain("error: Apple signing error 9120: the signing session was rejected.") {
                lastInstallFailure = LauncherFailure(
                    code: "signing_error",
                    message: explanation.title,
                    hint: explanation.hint,
                    detail: "mock",
                    exitCode: nil
                )
            }
            settings.libraryInstalledTitles = [MockFixtures.titlePokemonY]
            settings.libraryInstalledAt = Date().addingTimeInterval(-7_200)
        case .devicePush:
            settings.libraryInstalledTitles = [MockFixtures.titlePokemonY]
            settings.libraryIPAPath = "/Users/you/3ds2apple/IPA/3ds2apple-library.ipa"
            settings.libraryInstalledAt = Date().addingTimeInterval(-7_200)
            screen = .library
            detailGameID = MockFixtures.titlePokemonY
            tasks = []
            buildMockPushPlan(progress: true)
            appendLog(.info, "library", "library installed: 0004000000055E00 (GamePack in the signed app bundle)")
            appendLog(.command, "devpush", "mkdir Documents/Games/0004000000055E00")
            appendLog(.command, "devpush", "put GameRom.cci (1.3 GB) - 62%")
            appendLog(.info, "devpush", "bridge: streaming progress every ~1 s, 90 s stall watchdog armed")
            appendLog(.info, "push", "GameInfo.json is pushed last so the shell never sees a partial game")
        case .activity:
            screen = .library
            tasks = MockFixtures.tasksForScreenshots()
        case .diagnostics:
            screen = .library
            settingsPresented = true
            tasks = []
        }
    }

    private func buildMockPushPlan(progress: Bool) {
        guard let game = games.first, let manifest = MockFixtures.manifests()[game.titleID] else { return }
        let planner = PushPlanner(outRoot: pack.outRoot, bundleID: settings.deviceBundleID)
        do {
            var plan = try planner.plan(
                game: game,
                manifest: manifest,
                device: devices.first,
                stagingDirectory: stagingRoot
            )
            if progress {
                if !plan.files.isEmpty {
                    plan.files[0].state = .running
                    plan.files[0].progress = 0.62
                }
                if plan.files.count > 1 {
                    plan.files[1].state = .pending
                    plan.files[1].progress = 0
                }
            }
            pushPlans[game.titleID] = plan
        } catch {
            pushError = error.launcherFailure()
        }
    }

    // MARK: self-check helpers

    /// Clear state and prepare a live/mock model for the self-check flow.
    func resetForSelfCheck() {
        games.removeAll()
        tasks.removeAll()
        logs.removeAll()
        pushPlans.removeAll()
        devices.removeAll()
        detectedROM = nil
        detectedROMError = nil
        settingsPresented = false
        detailGameID = nil
        lastInstallFailure = nil
        installResult = nil
        pushError = nil
        envReport = nil
        appleReadiness = nil
        selectedDeviceUDID = nil
        selectedGameID = nil
        settings.libraryInstalledTitles = []
        settings.libraryIPAPath = ""
        settings.libraryInstalledAt = nil
    }
}
