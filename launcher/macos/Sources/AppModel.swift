//
//  AppModel.swift
//  3ds2apple macOS launcher
//
//  The single state machine behind the two-section UI
//  (docs/macos-launcher.md):
//
//    Library: import a decrypted ROM -> list/remove games; the pack CLI's SMDH
//             metadata (localized name, publisher, cover.png) is shown read-only
//    Deploy:  select one or several games -> one-click batch deploy:
//             batch compile -> compose ONE ROM-free IPA with the selected real
//             packs + schema-2 GameCatalog -> verify the IPA -> sign/install ->
//             push each selected GameRom + GameInfo (using the bundle ID of the
//             app that was actually installed) -> verify -> Done.
//
//  Every long step becomes a TaskRecord with named stages; every command line
//  goes to the log. Live mode drives the real CLI/scripts/Xcode/devpush; mock
//  mode uses the deterministic stand-ins so the whole flow is testable on the
//  build VM without a ROM, a phone or an Apple ID.
//

import Foundation
import AppKit

enum MockScenario: String, CaseIterable {
    case importDetected
    case library
    case deploySelection
    case deployRunning
    case deployDone
    case deployFailed
    case settings
}

@MainActor
final class AppModel: ObservableObject {
    // Navigation and library
    @Published var screen: LauncherScreen = .library
    /// Settings is a modal panel (gear button), never a top-level tab.
    @Published var settingsPresented = false
    /// Import is a sheet of the Library, not a top-level tab.
    @Published var importPresented = false
    @Published var games: [GameEntry] = []
    @Published var detectedROM: DetectedROM?
    @Published var detectedROMError: String?

    // Deploy selection and the one-click report
    @Published var selectedForDeploy: Set<String> = []
    @Published var deployReport: DeployReport?
    @Published var pushPlans: [String: PushPlan] = [:]

    // Activity
    @Published var tasks: [TaskRecord] = []
    @Published var logs: [LogEntry] = []
    @Published var isBusy = false
    @Published var activeTaskID: UUID?
    @Published var banner: Banner?

    // Environment / devices
    @Published var envReport: EnvironmentReport?
    @Published var appleReadiness: AppleReadiness?
    /// Automatic startup readiness result: the persistent green/red light in the
    /// header (no manual "check" button in the UI).
    @Published var readiness: ReadinessStatus = .checking
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceUDID: String?

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
    /// Detected compile hardware (logical/physical cores + RAM). 3dsrecomp
    /// derives its own worker count from the logical CPUs and a memory budget,
    /// so the launcher only reports the numbers (Windows launcher 0.2.4 parity).
    let hardware: HardwareProfile

    private var lastInstallLine: String?
    private var hasRunStartupReadiness = false
    private let maximumVisibleLogs = 800

    // MARK: init

    init(settings: LauncherSettings, kind: LauncherRunMode) {
        self.settings = settings
        self.kind = kind
        // Everthing writable lives under the portable data root (0.2.4): logs,
        // pack workspace, compile staging, ROM copies and composed IPAs.
        let logURL = settings.logsRootURL.appendingPathComponent("launcher.log")
        if kind == .mock {
            try? FileManager.default.createDirectory(at: settings.logsRootURL, withIntermediateDirectories: true)
        }
        self.logStore = LogStore(logFileURL: logURL)
        let paths = ToolchainPaths.resolve(settings: settings)
        self.hardware = kind == .mock ? MockFixtures.hardware : HardwareProfile.detect()

        if kind == .mock {
            self.runner = MockCommandRunner()
            self.pack = MockPackBackend()
            self.bridge = MockDeviceBridge()
            self.installer = MockInstallBackend(readinessState: MockFixtures.readyEnvironment().apple)
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
                    outArgument: settings.outRootURL.path
                )
            } else {
                self.pack = MissingPackBackend(
                    outRoot: settings.outRootURL,
                    repoRoot: repoURL,
                    reason: "Checked: " + settings.repoRoot + "/builder/target/release/3ds2apple-pack and PATH"
                )
            }
            if let devpush = paths.devpush {
                self.bridge = DevpushCLI(binary: devpush, mockDirectory: nil, runner: runner)
            } else {
                self.bridge = UnavailableDeviceBridge()
            }
            self.installer = XcodeInstallBackend(
                runner: runner,
                repoRoot: repoURL,
                paths: paths,
                buildRoot: settings.buildRootURL
            )
            self.stagingRoot = settings.stagingRootURL
        }
        // Create the portable folders and adopt the old <checkout>/out workspace
        // exactly once, then log the decision + hardware line.
        let bootLines = settings.prepareDataRoot()
        appendLog(.info, "launcher", "3ds2apple launcher " + LauncherInfo.version + " started (" + (kind == .mock ? "mock mode" : "live mode") + ")")
        appendLog(.info, "launcher", "checkout: " + settings.repoRoot)
        appendLog(.info, "hardware", hardware.describe)
        for line in bootLines {
            appendLog(.info, "data", line)
        }
    }

    // MARK: convenience

    var strings: LauncherStrings {
        LauncherStrings(language: settings.language.resolved())
    }

    var isMock: Bool { kind == .mock }

    var selectedDevice: DeviceInfo? {
        devices.first(where: { $0.udid == selectedDeviceUDID })
    }

    var activeTask: TaskRecord? {
        guard let activeTaskID else { return nil }
        return tasks.first(where: { $0.id == activeTaskID })
    }

    func game(id: String) -> GameEntry? {
        games.first(where: { $0.titleID == id })
    }

    /// Games currently checked on the Deploy page, sorted by title ID.
    var deployCandidates: [GameEntry] {
        games.filter { selectedForDeploy.contains($0.titleID) }.sorted { $0.titleID < $1.titleID }
    }

    var deployCandidateTitles: [String] { deployCandidates.map { $0.titleID } }

    var builtGames: [GameEntry] {
        games.filter { $0.packIsReal || $0.phase == .built || $0.phase == .pushed }
    }

    /// True when the installed library IPA no longer matches the built packs.
    var libraryNeedsRebuild: Bool {
        let installed = Set(settings.libraryInstalledTitles.map { $0.uppercased() })
        let built = Set(builtGames.map { $0.titleID.uppercased() })
        return !built.isEmpty && installed != built
    }

    func isInInstalledLibrary(_ titleID: String) -> Bool {
        settings.libraryInstalledTitles.map { $0.uppercased() }.contains(titleID.uppercased())
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
        // Exports live with the other logs under the portable data root.
        let url = settings.logsRootURL
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
            banner = Banner(kind: .warning, title: strings.statusNeedsAttention, message: strings.busyWorking)
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
        if var report = deployReport, report.state == .running {
            for index in report.steps.indices where report.steps[index].state == .running {
                report.steps[index].state = .failed
                report.steps[index].detail = "cancelled"
                report.failedStepIndex = index
            }
            report.state = .cancelled
            report.endedAt = Date()
            deployReport = report
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
            report = MockFixtures.readyEnvironment()
        } else {
            report = await ToolchainProbe(runner: runner, settings: settings).probe()
        }
        envReport = report
        appleReadiness = report.apple
        readiness = report.readinessStatus
        appendLog(.info, "toolchain", "ready: " + String(report.okCount) + "/" + String(report.tools.count) + " checks passed")
        for tool in report.tools where tool.state != .ok {
            appendLog(.warn, "toolchain", tool.name + ": " + tool.detail + " - " + tool.hint)
        }
    }

    /// Runs automatically on every live launch: probe the local build/signing
    /// environment once and keep the result as the persistent readiness light.
    /// There is deliberately no manual readiness button in the UI.
    func runStartupReadinessCheck() async {
        if hasRunStartupReadiness { return }
        hasRunStartupReadiness = true
        readiness = .checking
        appendLog(.info, "readiness", "automatic startup readiness check")
        await refreshEnvironment()
        switch readiness {
        case .ready(let detail):
            appendLog(.success, "readiness", "ready: " + detail)
        case .notReady(let detail):
            appendLog(.warn, "readiness", "not ready: " + detail.replacingOccurrences(of: "\n", with: "; "))
        case .checking:
            break
        }
        // Refresh the device list quietly so Deploy is usable without extra clicks;
        // a missing cable/phone is not a readiness failure.
        await detectDevicesWithoutBusy(quiet: true)
        // Rebuild the library from the portable workspace (imported games + SMDH
        // metadata survive a restart and the one-time migration).
        await restoreLibrary()
    }

    // MARK: ROM detection and import

    func detectROM(at path: String) async {
        guard !path.isEmpty else { return }
        guard beginBusy() else { return }
        defer { endBusy() }
        detectedROMError = nil
        let taskID = startTask(
            kind: .detect,
            title: strings.detectedTitle,
            titleID: nil,
            stages: [PipelineStage(title: strings.fieldTitleID, detail: path, state: .running)]
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
            banner = Banner(kind: .error, title: strings.unrecognisedTitle, message: failure.plainText)
        }
    }

    func importDetected() async {
        guard let rom = detectedROM else {
            banner = Banner(kind: .warning, title: strings.unrecognisedTitle, message: strings.deployNoGames)
            return
        }
        guard beginBusy() else { return }
        defer { endBusy() }
        let taskID = startTask(
            kind: .importROM,
            title: strings.importTitle + " " + rom.displayName,
            titleID: rom.titleID,
            stages: [
                PipelineStage(title: strings.step1Title, detail: rom.container.uppercased(), state: .succeeded),
                PipelineStage(title: strings.dropTitle, detail: "workspace/packages/" + rom.titleID, state: .running),
                PipelineStage(title: strings.step4Title, detail: "workspace/launcher-roms", state: .pending),
            ]
        )
        // No --display-name: the pack CLI picks the ROM's own SMDH title. The
        // launcher never asks the user to type/rename a game (0.2.4 parity).
        // Re-importing an existing game passes --force so the pack CLI refreshes
        // the ROM/SMDH metadata and re-extracts an old scrambled cover.png
        // (self-heal) while keeping the already built GamePack; a first import
        // must not force.
        let existingPackage = pack.outRoot
            .appendingPathComponent("packages/" + rom.titleID + "/GameInfo.json").path
        let reimporting = game(id: rom.titleID) != nil || FileProbe.exists(existingPackage)
        if reimporting {
            appendLog(.info, "import", "re-import of " + rom.titleID
                + ": passing --force so the pack CLI refreshes the SMDH cover/metadata (the built GamePack is kept)")
        }
        appendLog(.command, "pack", "packages add --roms \"" + rom.path + "\" --json"
            + (reimporting ? " --force" : "") + "  (no --include-rom: the IPA stays ROM-free)")
        do {
            let package = try await pack.importROM(rom.path, displayName: nil, includeROM: false, force: reimporting)
            var game = makeGame(from: rom, package: package)
            setStage(taskID, 1, .succeeded, "queued " + game.titleID + " (ROM not bundled)")
            setStage(taskID, 2, .running, "keeping a gitignored game-data copy for the device push")
            let staged = try stageROMData(rom)
            game.romDataPath = staged.path
            game.romSha256 = staged.sha256
            upsertGame(game)
            setStage(taskID, 2, .succeeded, staged.path)
            finishTask(taskID, .succeeded)
            detectedROM = nil
            detectedROMError = nil
            importPresented = false
            appendLog(.success, "import", "queued " + game.displayName + " (" + game.titleID + ", " + String(game.displayNames.count)
                + " SMDH name(s), publisher " + (game.publisher.isEmpty ? "-" : game.publisher)
                + "): AOT code goes into the signed app, game data into workspace/launcher-roms")
            banner = Banner(kind: .success, title: strings.importTitle, message: game.displayName)
            screen = .library
        } catch {
            let failure = error.launcherFailure()
            setStage(taskID, 1, .failed, failure.message)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "import", failure.message + " " + failure.hint)
            banner = Banner(kind: .error, title: strings.importTitle, message: failure.plainText)
        }
    }

    /// Single-action import used by the Library button: inspect the chosen ROM
    /// header, stage the game data for the device push and add the game to the
    /// library — one button press, no import sheet/confirmation card.
    func importROM(at path: String) async {
        guard !path.isEmpty, !isBusy else { return }
        await detectROM(at: path)
        if detectedROM != nil {
            await importDetected()
        }
    }

    private func makeGame(from rom: DetectedROM, package: DetectedPackage) -> GameEntry {
        let existing = game(id: package.titleID)
        // The pack CLI reports the SMDH displayNames/publisher/coverPath for the
        // package (fall back to the rom inspect values when the CLI is older).
        let names = package.displayNames.isEmpty ? rom.displayNames : package.displayNames
        let publisher = GameNames.resolvePublisher(package.publisher.isEmpty ? rom.publisher : package.publisher)
        let packageDirectory = pack.outRoot.appendingPathComponent("packages/" + package.titleID).path
        let cover = GameNames.resolveCoverPath(packageDirectory: packageDirectory, coverPath: package.coverPath)
        return GameEntry(
            titleID: package.titleID,
            displayName: package.displayName.isEmpty ? rom.displayName : package.displayName,
            displayNames: names,
            publisher: publisher,
            coverPath: cover,
            productCode: package.productCode.isEmpty ? rom.productCode : package.productCode,
            romPath: rom.path,
            romBytes: rom.bytes,
            container: rom.container,
            aotVersion: package.aotVersion,
            buildSlug: slug(displayName: package.displayName.isEmpty ? rom.displayName : package.displayName, titleID: package.titleID),
            phase: existing?.phase == .built || existing?.phase == .pushed ? existing?.phase ?? .built : .queued,
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

    private func updateGame(_ id: String, _ body: (inout GameEntry) -> Void) {
        guard let index = games.firstIndex(where: { $0.titleID == id }) else { return }
        body(&games[index])
    }

    // MARK: library management (no build/install/push buttons here)

    func removeGame(titleID: String) {
        guard let game = game(id: titleID) else { return }
        games.removeAll(where: { $0.titleID == titleID })
        selectedForDeploy.remove(titleID)
        pushPlans.removeValue(forKey: titleID)
        if let staged = game.romDataPath, staged.hasPrefix(pack.outRoot.path + "/launcher-roms/") {
            try? FileManager.default.removeItem(atPath: staged)
        }
        appendLog(.info, "library", "removed " + game.displayName + " (" + titleID + ") from the library")
        banner = Banner(kind: .info, title: strings.remove, message: game.displayName)
    }

    func refreshLibrary() async {
        await refreshPackages()
        for game in games where game.romDataPath == nil {
            let planner = PushPlanner(outRoot: pack.outRoot, bundleID: settings.installedBundleID)
            if let staged = planner.resolveROMDataPath(for: game) {
                updateGame(game.titleID) { entry in
                    entry.romDataPath = staged
                    if entry.romSha256 == nil { entry.romSha256 = FileProbe.sha256(ofFile: staged) }
                }
            }
        }
    }

    func refreshPackages() async {
        do {
            let packages = try await pack.listPackages()
            for package in packages {
                guard let index = games.firstIndex(where: { $0.titleID == package.titleID }) else { continue }
                games[index].aotVersion = package.aotVersion
                if !package.displayNames.isEmpty {
                    games[index].displayNames = package.displayNames
                }
                let publisher = GameNames.resolvePublisher(package.publisher)
                if !publisher.isEmpty { games[index].publisher = publisher }
                let packageDirectory = pack.outRoot.appendingPathComponent("packages/\(package.titleID)").path
                if let cover = GameNames.resolveCoverPath(packageDirectory: packageDirectory, coverPath: package.coverPath) {
                    games[index].coverPath = cover
                }
                if let packFile = package.pack {
                    games[index].packPath = pack.outRoot.appendingPathComponent("packages/\(package.titleID)/GamePack.dylib").path
                    games[index].packBytes = packFile.bytes
                    games[index].packSha256 = packFile.sha256
                    games[index].packFormat = packFile.format
                }
                if package.isBuilt && (games[index].phase == .queued || games[index].phase == .failed) {
                    games[index].phase = .built
                    games[index].lastError = nil
                }
            }
        } catch {
            appendLog(.warn, "packages", "could not list packages: " + error.localizedDescription)
        }
    }

    /// Rebuild the visible library from the portable workspace on launch. The
    /// workspace (packages + GameInfo.json) is the single source of truth, so
    /// imported games and their SMDH name/icon/publisher and built AOT packs
    /// survive a restart, a read-only fallback and the one-time migration from
    /// the old <checkout>/out layout.
    func restoreLibrary() async {
        do {
            let packages = try await pack.listPackages()
            var restored = 0
            for package in packages where game(id: package.titleID) == nil {
                let manifest = try? await pack.readManifest(titleID: package.titleID)
                games.append(makeRestoredGame(package: package, manifest: manifest))
                restored += 1
            }
            games.sort { $0.titleID < $1.titleID }
            if restored > 0 {
                appendLog(.success, "library", "restored " + String(restored) + " game(s) from the portable workspace")
            }
        } catch {
            appendLog(.warn, "library", "could not restore the library from the workspace: " + error.localizedDescription)
        }
        await refreshLibrary()
    }

    private func makeRestoredGame(package: DetectedPackage, manifest: PackageManifest?) -> GameEntry {
        let packageDirectory = pack.outRoot.appendingPathComponent("packages/" + package.titleID).path
        let names = package.displayNames.isEmpty ? (manifest?.displayNames ?? [:]) : package.displayNames
        let publisher = GameNames.resolvePublisher(
            package.publisher.isEmpty ? (manifest?.publisher ?? "") : package.publisher
        )
        let cover = GameNames.resolveCoverPath(
            packageDirectory: packageDirectory,
            coverPath: package.coverPath ?? manifest?.coverPath
        )
        let romPath = manifest?.romPath ?? ""
        let extensionName = (romPath as NSString).pathExtension.lowercased()
        let container: String
        switch extensionName {
        case "3ds", "cci": container = "ncsd"
        case "cxi", "ncch", "app": container = "ncch"
        default: container = "ncsd"
        }
        // The pack CLI's staged ROM copy (workspace/launcher-roms) is the push
        // source; a restored library does not need the original ROM path for it.
        let romsRoot = pack.outRoot.appendingPathComponent("launcher-roms")
        var stagedPath: String?
        for ext in PushPlanner.romExtensions {
            let candidate = romsRoot.appendingPathComponent(package.titleID + "." + ext)
            if FileProbe.exists(candidate.path), (FileProbe.size(candidate.path) ?? 0) > 0 {
                stagedPath = candidate.path
                break
            }
        }
        let defaultName = GameNames.resolve(
            displayNames: names,
            displayName: package.displayName.isEmpty ? (manifest?.displayName ?? package.titleID) : package.displayName,
            uiLanguageTag: "en"
        )
        return GameEntry(
            titleID: package.titleID,
            displayName: defaultName,
            displayNames: names,
            publisher: publisher,
            coverPath: cover,
            productCode: package.productCode,
            romPath: romPath,
            romBytes: manifest?.romBytes ?? 0,
            container: container,
            aotVersion: package.aotVersion,
            buildSlug: slug(displayName: defaultName, titleID: package.titleID),
            phase: package.isBuilt ? .built : .queued,
            packPath: package.isBuilt ? packageDirectory + "/GamePack.dylib" : nil,
            packBytes: package.pack?.bytes,
            packSha256: package.pack?.sha256,
            packFormat: package.pack?.format,
            saveNamespace: package.titleID,
            pushedAt: nil,
            lastError: nil,
            romDataPath: stagedPath,
            romSha256: nil
        )
    }

    // MARK: devices

    func detectDevices() async {
        guard beginBusy() else { return }
        defer { endBusy() }
        await detectDevicesWithoutBusy(quiet: false)
    }

    private func detectDevicesWithoutBusy(quiet: Bool) async {
        let taskID = startTask(
            kind: .detectDevice,
            title: strings.deployDetectDevice,
            titleID: nil,
            stages: [
                PipelineStage(title: strings.deployDeviceTitle, detail: bridge.displayName, state: .running),
                PipelineStage(title: strings.fieldContainer, detail: "usbmuxd / CoreDevice", state: .pending),
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
            if found.isEmpty && !quiet {
                banner = Banner(kind: .warning, title: strings.deployDeviceNone, message: strings.dropHint)
            }
        } catch {
            let failure = error.launcherFailure()
            setStage(taskID, 0, .failed, failure.message)
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "device", failure.message + " " + failure.hint)
            if !quiet {
                banner = Banner(kind: .error, title: strings.deployDeviceTitle, message: failure.plainText)
            }
        }
    }

    // MARK: ROM data staging (push source; gitignored, never in the IPA)

    /// Copy (or hardlink) the user's ROM into out/launcher-roms. The signed IPA
    /// only carries AOT code, so this gitignored copy is what the device push
    /// sends as GameRom.<ext>; it also survives library re-installs.
    private func stageROMData(_ rom: DetectedROM) throws -> (path: String, sha256: String) {
        if kind == .mock {
            MockFixtures.ensurePackageTree()
            let path = pack.outRoot.appendingPathComponent("launcher-roms/" + rom.titleID + ".cci").path
            if !FileProbe.exists(path) {
                FileManager.default.createFile(atPath: path, contents: Data("3ds2apple launcher mock game data (not a real ROM)\n".utf8))
                if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                    try? handle.truncate(atOffset: 4 * 1024 * 1024)
                    try? handle.close()
                }
            }
            return (path, FileProbe.sha256(ofFile: path) ?? "")
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
                appendLog(.info, "rom", "hardlinked game data into workspace/launcher-roms (no extra copy): " + target.lastPathComponent)
            } catch {
                try fileManager.copyItem(atPath: rom.path, toPath: target.path)
                appendLog(.info, "rom", "copied game data into workspace/launcher-roms: " + target.lastPathComponent)
            }
        }
        guard let sha = FileProbe.sha256(ofFile: target.path) else {
            throw LauncherFailure(code: "rom_stage_failed", message: "Could not hash the staged game data.", hint: "Check free disk space and file permissions.", detail: target.path, exitCode: nil)
        }
        return (target.path, sha)
    }

    private func ensureStagedGameData(titleID: String) throws {
        guard let game = game(id: titleID) else { return }
        if let staged = game.romDataPath, FileProbe.exists(staged), (FileProbe.size(staged) ?? 0) > 0 {
            return
        }
        let rom = DetectedROM(
            path: game.romPath,
            titleID: game.titleID,
            displayName: game.displayName,
            productCode: game.productCode,
            container: game.container,
            bytes: game.romBytes,
            contentBytes: nil,
            titleVersion: nil
        )
        let staged = try stageROMData(rom)
        updateGame(titleID) { entry in
            entry.romDataPath = staged.path
            entry.romSha256 = staged.sha256
        }
    }

    // MARK: - Deploy: one-click batch flow

    private func deployStepTitles(count: Int) -> [PipelineStage] {
        [
            PipelineStage(title: strings.deployStepCheckDevice, detail: "", state: .pending),
            PipelineStage(title: strings.deployCompileStep(count), detail: "", state: .pending),
            PipelineStage(title: strings.deployStepCompose, detail: "", state: .pending),
            PipelineStage(title: strings.deployStepVerifyIPA, detail: "", state: .pending),
            PipelineStage(title: strings.deployStepInstall, detail: "", state: .pending),
            PipelineStage(title: strings.deployStepPush, detail: "", state: .pending),
            PipelineStage(title: strings.deployStepDone, detail: "", state: .pending),
        ]
    }

    private func setDeployStep(_ index: Int, _ state: StageState, _ detail: String? = nil) {
        if var report = deployReport, index >= 0, index < report.steps.count {
            report.steps[index].state = state
            if let detail { report.steps[index].detail = detail }
            deployReport = report
        }
        if let taskID = activeTaskID {
            setStage(taskID, index, state, detail)
        }
    }

    func toggleDeploySelection(_ titleID: String) {
        if selectedForDeploy.contains(titleID) {
            selectedForDeploy.remove(titleID)
        } else {
            selectedForDeploy.insert(titleID)
        }
    }

    func selectAllDeploy() {
        selectedForDeploy = Set(games.map { $0.titleID })
    }

    func clearDeploySelection() {
        selectedForDeploy.removeAll()
    }

    /// The single user-visible action on the Deploy page: compile -> compose one
    /// ROM-free IPA with the selected packs -> verify -> sign/install -> push
    /// each ROM+GameInfo with the ACTUAL installed bundle id -> verify -> Done.
    func deploySelected() async {
        guard !isBusy else {
            banner = Banner(kind: .warning, title: strings.statusNeedsAttention, message: strings.busyWorking)
            return
        }
        let strings = self.strings
        let selected = deployCandidates
        guard !selected.isEmpty else {
            banner = Banner(kind: .warning, title: strings.deploySelectionTitle, message: strings.deployNoSelection)
            return
        }
        let titles = selected.map { $0.titleID }

        if devices.isEmpty {
            if let found = try? await bridge.devices(), !found.isEmpty {
                devices = found
                if selectedDeviceUDID == nil { selectedDeviceUDID = found.first?.udid }
            }
        }
        guard let device = selectedDevice else {
            banner = Banner(kind: .warning, title: strings.deployDeviceTitle, message: strings.deployDeviceNone)
            return
        }
        guard beginBusy() else { return }
        defer { endBusy() }

        let report = DeployReport(
            state: .running,
            steps: deployStepTitles(count: titles.count),
            selectedTitles: titles,
            builtTitles: [],
            ipaPath: nil,
            inspection: nil,
            installedBundleID: nil,
            pushedTitles: [],
            failedStepIndex: nil,
            failureMessage: nil,
            failureHint: nil,
            startedAt: Date(),
            endedAt: nil
        )
        deployReport = report
        let taskID = startTask(
            kind: .deploy,
            title: strings.deployRunningFor(titles.count),
            titleID: nil,
            stages: report.steps
        )
        appendLog(.info, "deploy", "one-click deploy: " + String(titles.count) + " game(s) on " + device.name + " (" + device.udid + ")")
        appendLog(.info, "deploy", "selected titles: " + titles.joined(separator: ", "))
        screen = .deploy

        do {
            // 0. device + Apple ID readiness + push source validation
            setDeployStep(0, .running, strings.deployDeviceTitle)
            let readiness = await installer.readiness(teamID: "")
            appleReadiness = readiness
            guard readiness.hasSigningAssets else {
                throw LauncherFailure(code: "no_signing_assets", message: readiness.plainTextState, hint: readiness.hint, detail: readiness.xcodeVersion, exitCode: nil)
            }
            guard !readiness.teamID.isEmpty else {
                throw LauncherFailure(code: "team_missing", message: readiness.plainTextState, hint: readiness.hint, detail: nil, exitCode: nil)
            }
            for title in titles { try ensureStagedGameData(titleID: title) }
            setDeployStep(0, .succeeded, device.name + " · " + readiness.teamID)
            appendLog(.success, "deploy", "preflight ok: " + device.name + ", Team " + readiness.teamID)

            // 1. batch compile (local, real AOT in live mode). The compile line
            // reports the detected cores/RAM: 3dsrecomp spawns one worker per
            // logical CPU under a memory budget (same as the Windows launcher).
            appendLog(.info, "build", "compile hardware: " + hardware.describe)
            setDeployStep(1, .running, strings.deployCompileHardware(hardware))
            _ = try await pack.build(titleIDs: titles, mode: kind == .mock ? .fake : .real) { [weak self] level, line in
                Task { @MainActor in self?.appendLog(level, "build", line) }
            }
            var built: [String] = []
            for (offset, title) in titles.enumerated() {
                let manifest = try await pack.readManifest(titleID: title)
                guard manifest.packFormat == "macho" else {
                    throw LauncherFailure(
                        code: "pack_not_built",
                        message: "The AOT pack for " + title + " is not a real build.",
                        hint: "The Deploy flow only installs real GamePacks. Check the build log and retry; a preview/placeholder pack is refused on purpose.",
                        detail: manifest.packFormat ?? "missing",
                        exitCode: nil
                    )
                }
                updateGame(title) { entry in
                    entry.phase = .built
                    entry.packFormat = manifest.packFormat
                    entry.packBytes = manifest.packBytes
                    entry.packSha256 = manifest.packSha256
                    entry.packPath = pack.outRoot.appendingPathComponent("packages/\(title)/GamePack.dylib").path
                    entry.lastError = nil
                }
                built.append(title)
                setDeployStep(1, .running, strings.deployCompileProgress(offset + 1, titles.count))
                if var currentReport = deployReport {
                    currentReport.builtTitles = built
                    deployReport = currentReport
                }
                appendLog(.success, "build", "AOT pack ready: " + title + " (" + FileProbe.formatBytes(manifest.packBytes ?? 0) + ")")
            }
            setDeployStep(1, .succeeded, String(built.count) + " GamePack(s)")

            // 2. compose ONE ROM-free IPA from the built packs + schema-2 catalog
            setDeployStep(2, .running, strings.deployStepCompose)
            let options = InstallOptions(teamID: readiness.teamID, deviceUDID: device.udid, allowProvisioningUpdates: true)
            let shellApp = try await installer.buildShellApp(options: options) { [weak self] progress in
                Task { @MainActor in self?.setDeployStep(2, .running, progress.line) }
            }
            let ipaOutDir = settings.ipaRootURL.path
            let ipaName = "3ds2apple-library-" + String(titles.count) + "-games"
            let result = try await pack.buildLibraryIPA(
                titleIDs: titles,
                baseAppPath: shellApp,
                ipaOutDir: ipaOutDir,
                ipaName: ipaName,
                dryRun: false,
                onLine: { [weak self] level, line in
                    Task { @MainActor in self?.appendLog(level, "library", line) }
                }
            )
            guard result.executed, let produced = result.ipaPath else {
                throw LauncherFailure(code: "library_ipa_missing", message: "The library IPA was not produced.", hint: "Check the packaging log and retry.", detail: result.summary, exitCode: nil)
            }
            settings.libraryIPAPath = produced
            if var currentReport = deployReport {
                currentReport.ipaPath = produced
                deployReport = currentReport
            }
            setDeployStep(2, .succeeded, (produced as NSString).lastPathComponent)
            appendLog(.success, "library", "composed ROM-free IPA: " + produced)

            // 3. verify packs + schema-2 catalog + no ROM BEFORE any install
            setDeployStep(3, .running, "reading GameCatalog.json + Frameworks/")
            let inspected = try await installer.inspectLibraryIPA(ipaPath: produced, expectedTitles: titles)
            let problems = inspected.problems(expectedTitles: titles)
            guard problems.isEmpty else {
                throw LauncherFailure(code: "library_ipa_invalid", message: "The composed IPA is missing the selected packs or the catalogue.", hint: problems.joined(separator: "; "), detail: nil, exitCode: nil)
            }
            if var currentReport = deployReport {
                currentReport.inspection = inspected
                deployReport = currentReport
            }
            setDeployStep(3, .succeeded, strings.deployIPAVerified(inspected.packCount))
            appendLog(.success, "library", "IPA verified: " + String(inspected.packCount) + " pack(s), schema-2 catalogue, no Roms/ entry, bundle " + inspected.bundleID)

            // 4. sign & install; remember the ACTUAL installed bundle id
            setDeployStep(4, .running, strings.deployStepInstall)
            let installed = try await installer.installLibrary(inspection: inspected, signedBaseAppPath: shellApp, options: options) { [weak self] progress in
                Task { @MainActor in self?.setDeployStep(4, .running, progress.line) }
            }
            guard installed.installed else {
                throw LauncherFailure(code: "install_failed", message: "The app was not installed.", hint: "Check the device connection and retry.", detail: nil, exitCode: nil)
            }
            let resolvedBundleID = try await resolveInstalledBundleID(preferred: installed.verifiedBundleID, inspection: inspected, device: device)
            settings.installedBundleID = resolvedBundleID
            settings.save()
            if var currentReport = deployReport {
                currentReport.installedBundleID = resolvedBundleID
                deployReport = currentReport
            }
            markLibraryInstalled(titles: titles, ipaPath: produced)
            setDeployStep(4, .succeeded, resolvedBundleID)
            appendLog(.success, "install", "installed and verified bundle id: " + resolvedBundleID)

            // 5. push each selected ROM + GameInfo with the installed bundle id
            setDeployStep(5, .running, strings.deployPushed(0))
            for (offset, title) in titles.enumerated() {
                try await pushGameData(titleID: title, bundleID: resolvedBundleID, device: device)
                if var currentReport = deployReport {
                    currentReport.pushedTitles.append(title)
                    deployReport = currentReport
                }
                setDeployStep(5, .running, strings.deployPushed(offset + 1))
            }
            setDeployStep(5, .succeeded, strings.deployPushed(titles.count))

            // 6. final verification and the explicit Done state
            setDeployStep(6, .running, strings.statusLabel)
            guard let attribute = try? await bridge.appAttr(bundleID: resolvedBundleID, udid: device.udid), attribute.installed else {
                throw LauncherFailure(code: "installed_bundle_unverified", message: "The installed app could not be found on the device after install.", hint: "Reconnect the device and retry the deploy.", detail: resolvedBundleID, exitCode: nil)
            }
            for title in titles {
                guard let plan = pushPlans[title], plan.verified else {
                    throw LauncherFailure(code: "push_verify_missing", message: "The game data for " + title + " was not verified on the device.", hint: "Retry the deploy; the push is idempotent and GameInfo.json goes last.", detail: nil, exitCode: nil)
                }
            }
            setDeployStep(6, .succeeded, strings.deployDoneMessage)
            if var finalReport = deployReport {
                finalReport.state = .succeeded
                finalReport.endedAt = Date()
                deployReport = finalReport
            }
            finishTask(taskID, .succeeded)
            appendLog(.success, "deploy", "Done: " + String(titles.count) + " game(s) installed and pushed with bundle id " + resolvedBundleID)
            banner = Banner(kind: .success, title: strings.deployDoneTitle, message: strings.deployDoneMessage)
            screen = .deploy
        } catch {
            let failure = error.launcherFailure()
            if var currentReport = deployReport {
                if let index = currentReport.steps.firstIndex(where: { $0.state == .running }) {
                    currentReport.steps[index].state = .failed
                    currentReport.steps[index].detail = failure.message
                    currentReport.failedStepIndex = index
                }
                currentReport.state = .failed
                currentReport.endedAt = Date()
                currentReport.failureMessage = failure.message
                currentReport.failureHint = failure.hint
                deployReport = currentReport
            }
            if let index = tasks.first(where: { $0.id == taskID })?.stages.firstIndex(where: { $0.state == .running }) {
                setStage(taskID, index, .failed, failure.message)
            }
            finishTask(taskID, .failed, message: failure.message, hint: failure.hint)
            appendLog(.error, "deploy", failure.message + " " + failure.hint)
            banner = Banner(kind: .error, title: strings.deployFailedTitle, message: failure.plainText)
        }
    }

    /// Resolve the bundle identifier of the app that is ACTUALLY installed: the
    /// value read back from the built app's Info.plist / reported by the install
    /// result first, then the device bridge confirms it. A stale persisted value
    /// or a template default is never used blindly.
    private func resolveInstalledBundleID(preferred: String?, inspection: IPAInspection, device: DeviceInfo) async throws -> String {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty { candidates.append(preferred) }
        if !inspection.bundleID.isEmpty { candidates.append(inspection.bundleID) }
        candidates.append(SettingsDefaults.shellTemplateBundleID)
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if kind == .mock { (bridge as? MockDeviceBridge)?.markInstalled(candidate) }
            if let attribute = try? await bridge.appAttr(bundleID: candidate, udid: device.udid), attribute.installed {
                appendLog(.info, "install", "installed bundle id read back: " + candidate)
                return candidate
            }
        }
        throw LauncherFailure(
            code: "installed_bundle_unverified",
            message: "The app that was just installed could not be found on the device.",
            hint: "Keep the device unlocked and connected, then retry the deploy; the push needs the actual installed bundle id.",
            detail: candidates.joined(separator: ", "),
            exitCode: nil
        )
    }

    /// Push exactly GameRom + GameInfo.json (manifest LAST) for one game and
    /// verify each remote size plus the final listing before marking it pushed.
    private func pushGameData(titleID: String, bundleID: String, device: DeviceInfo) async throws {
        guard game(id: titleID) != nil else { return }
        try ensureStagedGameData(titleID: titleID)
        let manifest = try await pack.readManifest(titleID: titleID)
        let planner = PushPlanner(outRoot: pack.outRoot, bundleID: bundleID)
        guard let current = game(id: titleID) else { return }
        var plan = try planner.plan(game: current, manifest: manifest, device: device, stagingDirectory: stagingRoot)
        pushPlans[titleID] = plan
        for file in plan.files {
            guard FileProbe.exists(file.localPath) else {
                throw LauncherFailure(code: "push_file_missing", message: "Missing local file: " + file.name, hint: "Re-import the game and retry the deploy.", detail: file.localPath, exitCode: nil)
            }
        }
        appendLog(.command, "devpush", "mkdir " + plan.remoteDirectory + " (bundle " + bundleID + ")")
        try await bridge.mkdir(bundleID: bundleID, path: plan.remoteDirectory, udid: device.udid)
        for index in plan.files.indices {
            plan.files[index].state = .running
            pushPlans[titleID] = plan
            appendLog(.command, "devpush", "put " + plan.files[index].name + " (" + FileProbe.formatBytes(plan.files[index].bytes) + ")")
            let put = try await bridge.put(
                bundleID: bundleID,
                local: plan.files[index].localPath,
                remote: plan.files[index].remotePath,
                udid: device.udid,
                onProgress: { [weak self] sent, total in
                    Task { @MainActor in
                        guard var currentPlan = self?.pushPlans[titleID], index < currentPlan.files.count else { return }
                        currentPlan.files[index].progress = total > 0 ? min(1, Double(sent) / Double(total)) : 0
                        if currentPlan.files[index].state == .pending {
                            currentPlan.files[index].state = .running
                        }
                        self?.pushPlans[titleID] = currentPlan
                    }
                }
            )
            let expected = FileProbe.size(plan.files[index].localPath) ?? put.bytes
            if let remote = try await bridge.stat(bundleID: bundleID, path: plan.files[index].remotePath, udid: device.udid),
               let remoteSize = remote.size,
               remoteSize != expected {
                throw LauncherFailure(
                    code: "push_size_mismatch",
                    message: "The device has a different size for " + plan.files[index].name + ".",
                    hint: "The transfer was interrupted. Retry the deploy; the file will be overwritten.",
                    detail: "remote " + String(remoteSize) + " B vs local " + String(expected) + " B",
                    exitCode: nil
                )
            }
            plan.files[index].state = .succeeded
            plan.files[index].progress = 1
            pushPlans[titleID] = plan
        }
        let attribute = try await bridge.appAttr(bundleID: bundleID, udid: device.udid)
        guard attribute.installed else {
            throw LauncherFailure(code: "app_missing", message: "The installed app was not found while pushing game data.", hint: "Reconnect the device and retry the deploy.", detail: bundleID, exitCode: nil)
        }
        let remoteFiles = try await bridge.ls(bundleID: bundleID, path: plan.remoteDirectory, udid: device.udid)
        let names = Set(remoteFiles.map { $0.name })
        let missing = plan.files.map { $0.name }.filter { !names.contains($0) }
        if !missing.isEmpty {
            throw LauncherFailure(code: "push_verify_missing", message: "The device is missing " + String(missing.count) + " file(s) after the transfer.", hint: "Retry the deploy; the bridge overwrites files and the manifest goes last.", detail: missing.joined(separator: ", "), exitCode: nil)
        }
        plan.verified = true
        plan.verifiedAt = Date()
        pushPlans[titleID] = plan
        updateGame(titleID) { entry in
            entry.phase = .pushed
            entry.pushedAt = Date()
            entry.lastError = nil
        }
        appendLog(.success, "push", plan.displayName + " pushed to " + plan.remoteDirectory + " (verified size/sha + listing)")
    }

    private func markLibraryInstalled(titles: [String], ipaPath: String) {
        settings.libraryInstalledTitles = titles
        settings.libraryIPAPath = ipaPath
        settings.libraryInstalledAt = Date()
        settings.save()
    }

    // MARK: - Mock seeding for screenshots and self-checks

    static func mock(scenario: MockScenario) -> AppModel {
        let settings = LauncherSettings(persist: false, dataRootOverride: MockFixtures.root.path)
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
        envReport = MockFixtures.readyEnvironment()
        appleReadiness = envReport?.apple
        readiness = envReport?.readinessStatus ?? .ready(detail: "mock environment")
        hasRunStartupReadiness = true
        devices = MockFixtures.devices
        selectedDeviceUDID = devices.first?.udid
        selectedForDeploy = []
        tasks = []
        deployReport = nil
        pushPlans = [:]
        detectedROM = nil
        detectedROMError = nil
        banner = nil
        settings.libraryInstalledTitles = []
        settings.libraryIPAPath = ""
        settings.libraryInstalledAt = nil
        settings.installedBundleID = ""
        settingsPresented = false
        importPresented = false
        screen = .library
        (bridge as? MockDeviceBridge)?.appsInstalled = []

        switch scenario {
        case .importDetected:
            importPresented = true
            detectedROM = MockFixtures.detectedROM()
        case .library:
            settings.libraryInstalledTitles = [MockFixtures.titlePokemonY]
            settings.installedBundleID = MockFixtures.installedShellBundleID
            settings.libraryIPAPath = MockFixtures.ipaRoot.appendingPathComponent("3ds2apple-library-1-games.ipa").path
            settings.libraryInstalledAt = Date().addingTimeInterval(-3_600)
            (bridge as? MockDeviceBridge)?.markInstalled(MockFixtures.installedShellBundleID)
        case .deploySelection:
            screen = .deploy
            selectedForDeploy = [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing]
        case .deployRunning:
            screen = .deploy
            selectedForDeploy = [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing]
            var report = DeployReport(
                state: .running,
                steps: deployStepTitles(count: 2),
                selectedTitles: [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing],
                builtTitles: [MockFixtures.titlePokemonY],
                ipaPath: nil,
                inspection: nil,
                installedBundleID: nil,
                pushedTitles: [],
                failedStepIndex: nil,
                failureMessage: nil,
                failureHint: nil,
                startedAt: Date().addingTimeInterval(-120),
                endedAt: nil
            )
            report.steps[0].state = .succeeded
            report.steps[0].detail = "Kratos iPhone · " + MockFixtures.detectedTeamID
            report.steps[1].state = .running
            report.steps[1].detail = "Animal Crossing: New Leaf (mock)"
            deployReport = report
            tasks = MockFixtures.tasksForScreenshots().map { task in
                var copy = task
                copy.stages = report.steps
                return copy
            }
        case .deployDone:
            screen = .deploy
            selectedForDeploy = [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing]
            settings.libraryInstalledTitles = [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing]
            settings.installedBundleID = MockFixtures.installedShellBundleID
            settings.libraryIPAPath = MockFixtures.ipaRoot.appendingPathComponent("3ds2apple-library-2-games.ipa").path
            settings.libraryInstalledAt = Date().addingTimeInterval(-600)
            (bridge as? MockDeviceBridge)?.markInstalled(MockFixtures.installedShellBundleID)
            for title in [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing] {
                updateGame(title) { entry in
                    entry.phase = .pushed
                    entry.pushedAt = Date().addingTimeInterval(-90)
                }
                seedPushPlan(titleID: title, verified: true)
            }
            var report = DeployReport(
                state: .succeeded,
                steps: deployStepTitles(count: 2),
                selectedTitles: [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing],
                builtTitles: [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing],
                ipaPath: settings.libraryIPAPath,
                inspection: mockInspection(titles: [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing], ipaPath: settings.libraryIPAPath),
                installedBundleID: MockFixtures.installedShellBundleID,
                pushedTitles: [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing],
                failedStepIndex: nil,
                failureMessage: nil,
                failureHint: nil,
                startedAt: Date().addingTimeInterval(-180),
                endedAt: Date().addingTimeInterval(-90)
            )
            report.steps[0].state = .succeeded
            report.steps[0].detail = "Kratos iPhone · " + MockFixtures.detectedTeamID
            report.steps[1].state = .succeeded
            report.steps[1].detail = "2 GamePack(s)"
            report.steps[2].state = .succeeded
            report.steps[2].detail = "3ds2apple-library-2-games.ipa"
            report.steps[3].state = .succeeded
            report.steps[3].detail = strings.deployIPAVerified(2)
            report.steps[4].state = .succeeded
            report.steps[4].detail = MockFixtures.installedShellBundleID
            report.steps[5].state = .succeeded
            report.steps[5].detail = strings.deployPushed(2)
            report.steps[6].state = .succeeded
            report.steps[6].detail = strings.deployDoneMessage
            deployReport = report
        case .deployFailed:
            screen = .deploy
            selectedForDeploy = [MockFixtures.titlePokemonY, MockFixtures.titleMario3DLand]
            var report = DeployReport(
                state: .failed,
                steps: deployStepTitles(count: 2),
                selectedTitles: [MockFixtures.titlePokemonY, MockFixtures.titleMario3DLand],
                builtTitles: [MockFixtures.titlePokemonY],
                ipaPath: nil,
                inspection: nil,
                installedBundleID: nil,
                pushedTitles: [],
                failedStepIndex: 1,
                failureMessage: "The GamePack build failed for " + MockFixtures.titleMario3DLand + ".",
                failureHint: "Open the log; in mock mode this is the labelled failure fixture.",
                startedAt: Date().addingTimeInterval(-60),
                endedAt: nil
            )
            report.steps[0].state = .succeeded
            report.steps[0].detail = "Kratos iPhone · " + MockFixtures.detectedTeamID
            report.steps[1].state = .failed
            report.steps[1].detail = report.failureMessage ?? ""
            deployReport = report
        case .settings:
            settingsPresented = true
        }
    }

    private func mockInspection(titles: [String], ipaPath: String?) -> IPAInspection {
        IPAInspection(
            ipaPath: ipaPath ?? MockFixtures.ipaRoot.appendingPathComponent("3ds2apple-library.ipa").path,
            appPath: "/mock/library-ipa/Payload/3ds2apple.app",
            bundleID: MockFixtures.installedShellBundleID,
            packFiles: titles.sorted().map { "Frameworks/GamePack-" + $0.uppercased() + ".dylib" },
            catalogSchemaVersion: 2,
            catalogTitleIDs: titles.map { $0.uppercased() },
            containsBundledROM: false,
            hasMoltenVK: true,
            bytes: 12_345_678
        )
    }

    private func seedPushPlan(titleID: String, verified: Bool) {
        guard let game = game(id: titleID),
              let manifest = MockFixtures.manifests()[titleID] else { return }
        let planner = PushPlanner(outRoot: pack.outRoot, bundleID: MockFixtures.installedShellBundleID)
        guard var plan = try? planner.plan(game: game, manifest: manifest, device: devices.first, stagingDirectory: stagingRoot) else { return }
        for index in plan.files.indices {
            plan.files[index].state = .succeeded
            plan.files[index].progress = 1
        }
        plan.verified = verified
        plan.verifiedAt = verified ? Date().addingTimeInterval(-90) : nil
        pushPlans[titleID] = plan
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
        importPresented = false
        selectedForDeploy.removeAll()
        deployReport = nil
        banner = nil
        envReport = nil
        appleReadiness = nil
        readiness = .checking
        hasRunStartupReadiness = false
        selectedDeviceUDID = nil
        settings.libraryInstalledTitles = []
        settings.libraryIPAPath = ""
        settings.libraryInstalledAt = nil
        settings.installedBundleID = ""
        (bridge as? MockDeviceBridge)?.appsInstalled = []
        screen = .library
    }
}
