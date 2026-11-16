//
//  SelfCheckFlow.swift
//  3ds2apple macOS launcher
//
//  Self-check part 2: Apple signing error translation, log redaction, library
//  management and the one-click Deploy batch flow end-to-end against the mock
//  backends: compile -> compose -> verify IPA -> install -> push with the actual
//  installed bundle id -> Done, plus the failure paths that must never install a
//  bare shell or a ROM-full/placeholder IPA.
//

import Foundation

@MainActor
enum SelfCheckFlow {
    static func checks() async -> [SelfCheck.Check] {
        var checks: [SelfCheck.Check] = []
        func expect(_ name: String, _ condition: Bool, _ detail: String = "") {
            checks.append(SelfCheck.Check(name: name, passed: condition, detail: condition ? "" : detail))
        }

        // 9. Apple signing error translation
        expect("apple errors: 9120 mapped", AppleErrorMapper.explain("error: 9120 signing session")?.title.contains("9120") == true)
        expect("apple errors: 9401 mapped", AppleErrorMapper.explain("Unable to install app (9401)")?.title.contains("9401") == true)
        expect("apple errors: no profile mapped", AppleErrorMapper.explain("No profiles for 'com.kratos.3ds2apple' were found")?.title.contains("provisioning") == true)
        expect("apple errors: developer mode mapped", AppleErrorMapper.explain("Developer Mode is disabled on this device")?.hint.contains("Developer Mode") == true)
        expect("apple errors: code signature trust mapped", AppleErrorMapper.explain("Failed to verify code signature of app")?.hint.lowercased().contains("trust") == true)
        expect("apple errors: unknown failure keeps log tail", AppleErrorMapper.failure(command: "xcodebuild", text: "some unexpected failure line").hint.contains("unexpected failure"))

        // 10. Log redaction
        let redacted = LogStore.redact("paired 00008120-000A1B2C3D4E5F60 email kratos@example.com sha 0123456789abcdef0123456789abcdef01234567")
        expect("logs: UDID redacted", !redacted.contains("00008120-000A1B2C3D4E5F60"))
        expect("logs: e-mail redacted", !redacted.contains("kratos@example.com"))
        expect("logs: SHA-1 redacted", !redacted.contains("0123456789abcdef0123456789abcdef01234567"))
        expect("logs: normal text kept", LogStore.redact("build finished for 0004000000055E00").contains("0004000000055E00"))

        // 11. Import a ROM-free package + staged game data
        let importModel = AppModel.mock(scenario: .importDetected)
        importModel.resetForSelfCheck()
        importModel.detectedROM = MockFixtures.detectedROM()
        await importModel.importDetected()
        expect("import: queues one game", importModel.games.count == 1 && importModel.games.first?.titleID == MockFixtures.titlePokemonY)
        expect("import: stages the ROM data for the Documents push", importModel.game(id: MockFixtures.titlePokemonY)?.romDataPath != nil)
        expect("import: closes the import sheet and lands in the library", importModel.importPresented == false && importModel.screen == .library)

        // 11b. Library management: read-only SMDH metadata (Windows 0.2.4
        // parity: no editable name input) + remove only; no build/install/push
        // buttons on this page.
        let libraryModel = AppModel.mock(scenario: .library)
        libraryModel.resetForSelfCheck()
        libraryModel.games = MockFixtures.games()
        let smdhGame = libraryModel.game(id: MockFixtures.titlePokemonY)
        expect("library: SMDH display names are shown read-only",
               smdhGame?.displayNames["zh-Hans"] == "宝可梦 Y" && smdhGame?.displayNames["en"] == "Pokemon Y")
        expect("library: SMDH publisher is shown", smdhGame?.publisher == "Nintendo")
        expect("library: the SMDH cover.png path resolves", smdhGame?.coverPath.map { FileProbe.exists($0) } == true)
        libraryModel.removeGame(titleID: MockFixtures.titleAnimalCrossing)
        expect("library: remove drops the game", libraryModel.games.count == 2 && libraryModel.game(id: MockFixtures.titleAnimalCrossing) == nil)

        // 11c. Restore from the portable workspace on launch (games, SMDH
        // metadata, built packs and the staged ROM copy survive a restart).
        let restoreModel = AppModel.mock(scenario: .library)
        restoreModel.resetForSelfCheck()
        await restoreModel.restoreLibrary()
        expect("library: restore rebuilds games from the workspace", restoreModel.games.count == 3, String(restoreModel.games.count))
        expect("library: restored game keeps its SMDH metadata",
               restoreModel.game(id: MockFixtures.titlePokemonY)?.publisher == "Nintendo"
               && restoreModel.game(id: MockFixtures.titlePokemonY)?.displayNames["zh-Hans"] == "宝可梦 Y")
        expect("library: restored built pack keeps its AOT state", restoreModel.game(id: MockFixtures.titlePokemonY)?.phase == .built)
        expect("library: restored game resolves the staged ROM for the push",
               restoreModel.game(id: MockFixtures.titlePokemonY)?.romDataPath != nil)
        expect("data root: the model uses the mock portable root",
               restoreModel.settings.dataRootPath == MockFixtures.root.path
               && restoreModel.settings.outRootURL.path == MockFixtures.outRoot.path)

        // 12. One-click Deploy success: batch compile -> compose -> verify IPA ->
        // install -> push each ROM with the ACTUAL installed bundle id -> Done.
        let model = AppModel.mock(scenario: .library)
        model.resetForSelfCheck()
        model.settings.installedBundleID = MockFixtures.staleInstalledBundleID
        model.games = MockFixtures.games()
        await model.detectDevices()
        expect("deploy: device detection selects a device", model.devices.count == 2 && model.selectedDeviceUDID == MockFixtures.devices.first?.udid)
        model.selectedForDeploy = [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing]
        await model.deploySelected()
        let report = model.deployReport
        expect("deploy: one-click run succeeds", report?.state == .succeeded, report.map { String(describing: $0.state) } ?? "nil")
        expect("deploy: all 7 steps succeeded", report?.steps.allSatisfy { $0.state == .succeeded } == true)
        expect("deploy: composed IPA contains 2 packs + schema-2 catalogue", report?.inspection?.packCount == 2 && report?.inspection?.catalogSchemaVersion == 2)
        expect("deploy: installed bundle id comes from the install result, not the stale value", report?.installedBundleID == MockFixtures.installedShellBundleID && model.settings.installedBundleID == MockFixtures.installedShellBundleID)
        let plans = model.pushPlans.filter { [MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing].contains($0.key) }.values
        expect("deploy: every push uses the actual installed bundle id", plans.count == 2 && plans.allSatisfy { $0.bundleID == MockFixtures.installedShellBundleID })
        expect("deploy: every push verified (size/sha + listing)", plans.allSatisfy { $0.verified })
        expect("deploy: both games pushed", report?.pushedTitles.sorted() == [MockFixtures.titleAnimalCrossing, MockFixtures.titlePokemonY].sorted())
        expect("deploy: installed library titles persisted", Set(model.settings.libraryInstalledTitles) == Set([MockFixtures.titlePokemonY, MockFixtures.titleAnimalCrossing]))
        expect("deploy: games marked on device", model.game(id: MockFixtures.titlePokemonY)?.phase == .pushed && model.game(id: MockFixtures.titleAnimalCrossing)?.phase == .pushed)
        expect("deploy: task recorded as succeeded", model.tasks.first(where: { $0.kind == .deploy })?.state == .succeeded)
        expect("deploy: compile step reports the detected hardware",
               model.logs.contains { $0.category == "build" && $0.message.contains("compile hardware") })
        expect("deploy: hardware line reports every logical core as a compile job",
               model.hardware.compileJobs == model.hardware.logicalCores && model.hardware.logicalCores >= 1
               && model.hardware.totalMemoryBytes > 0)

        // 13. No selection: nothing runs, an actionable warning is shown.
        let emptySelection = AppModel.mock(scenario: .library)
        emptySelection.resetForSelfCheck()
        emptySelection.games = MockFixtures.games()
        await emptySelection.deploySelected()
        expect("deploy: empty selection is refused with a warning", emptySelection.deployReport == nil && emptySelection.banner?.kind == .warning)

        // 14. A failed compile must never install the bare shell.
        let failureModel = AppModel.mock(scenario: .library)
        failureModel.resetForSelfCheck()
        failureModel.games = MockFixtures.games()
        await failureModel.detectDevices()
        (failureModel.pack as? MockPackBackend)?.failingTitles = [MockFixtures.titleMario3DLand]
        failureModel.selectedForDeploy = [MockFixtures.titlePokemonY, MockFixtures.titleMario3DLand]
        await failureModel.deploySelected()
        let failedReport = failureModel.deployReport
        let failedInstaller = failureModel.installer as? MockInstallBackend
        expect("deploy: compile failure fails the run at the compile step", failedReport?.state == .failed && failedReport?.failedStepIndex == 1)
        expect("deploy: compile failure never composes or installs", failedInstaller?.installCalls == 0 && failedReport?.installedBundleID == nil)
        expect("deploy: failure explains the failed step", failedReport?.failureMessage?.isEmpty == false && failureModel.banner?.kind == .error)

        // 14b. Retry after fixing the build succeeds on the same model.
        (failureModel.pack as? MockPackBackend)?.failingTitles = []
        failureModel.selectedForDeploy = [MockFixtures.titlePokemonY]
        await failureModel.deploySelected()
        expect("deploy: retry after a failure succeeds", failureModel.deployReport?.state == .succeeded && failureModel.settings.installedBundleID == MockFixtures.installedShellBundleID)

        // 15. A composed IPA that is not a real multi-game library payload is
        // refused before sign/install (never install a bare shell / preview IPA).
        let invalidIPAModel = AppModel.mock(scenario: .library)
        invalidIPAModel.resetForSelfCheck()
        invalidIPAModel.games = MockFixtures.games()
        await invalidIPAModel.detectDevices()
        let invalidInstaller = invalidIPAModel.installer as? MockInstallBackend
        var badInspection = IPAInspection(
            ipaPath: "/tmp/3ds2apple-library.ipa",
            appPath: "/tmp/Payload/3ds2apple.app",
            bundleID: "com.kratos.3ds2apple",
            packFiles: [],
            catalogSchemaVersion: 1,
            catalogTitleIDs: [],
            containsBundledROM: false,
            bytes: 1024
        )
        invalidInstaller?.overrideInspection = badInspection
        invalidIPAModel.selectedForDeploy = [MockFixtures.titlePokemonY]
        await invalidIPAModel.deploySelected()
        expect("deploy: invalid IPA is refused at the IPA verify step", invalidIPAModel.deployReport?.state == .failed && invalidIPAModel.deployReport?.failedStepIndex == 3)
        expect("deploy: invalid IPA never reaches sign/install", invalidInstaller?.installCalls == 0)
        badInspection.containsBundledROM = true
        expect("deploy: ROM-full IPA is refused by the shared check", !badInspection.problems(expectedTitles: [MockFixtures.titlePokemonY]).isEmpty)

        // 16. Task/report progress math
        var synthetic = DeployReport(
            state: .running,
            steps: [
                PipelineStage(title: "a", detail: "", state: .succeeded),
                PipelineStage(title: "b", detail: "", state: .running),
                PipelineStage(title: "c", detail: "", state: .pending),
            ],
            selectedTitles: ["x"],
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
        expect("tasks: progress counts completed and running stage", abs(synthetic.progress - 0.5) < 0.001, String(synthetic.progress))
        synthetic.state = .succeeded
        synthetic.endedAt = Date()
        expect("tasks: succeeded report duration is non-negative", synthetic.duration >= 0)

        // 17. Mock environment report and log export
        let environment = MockFixtures.readyEnvironment()
        expect("diagnostics: mock environment has tools", environment.tools.count >= 8)
        expect("diagnostics: mock environment is signing-ready with a detected Team ID", environment.apple.ready && environment.apple.teamID == MockFixtures.detectedTeamID)
        expect("diagnostics: mock devpush capabilities present", environment.devpushCapabilities?.schema == "devpush/1")
        let missing = MockFixtures.missingSigningEnvironment()
        expect("diagnostics: missing-signing fixture is not ready", !missing.apple.ready && missing.apple.hint.contains("Xcode"))
        let logModel = AppModel.mock(scenario: .library)
        logModel.resetForSelfCheck()
        logModel.appendLog(.info, "launcher", "export me")
        logModel.exportLog()
        expect("logs: export writes a file", logModel.lastExportPath.map { FileProbe.exists($0) } == true)

        // 18. Automatic startup readiness: green/red light, no manual button.
        let readyReport = MockFixtures.readyEnvironment()
        expect("readiness: ready fixture is green", readyReport.readinessStatus.isReady, readyReport.readinessStatus.detail)
        let missingSigning = MockFixtures.missingSigningEnvironment()
        expect("readiness: missing Apple ID signing is red", !missingSigning.readinessStatus.isReady, missingSigning.readinessStatus.detail)
        var missingToolReport = readyReport
        missingToolReport.tools[0].state = .missing
        let missingToolStatus = missingToolReport.readinessStatus
        expect("readiness: a missing tool is red with its name", !missingToolStatus.isReady && missingToolStatus.detail.contains(missingToolReport.tools[0].name), missingToolStatus.detail)
        let startupModel = AppModel.mock(scenario: .library)
        startupModel.resetForSelfCheck()
        expect("readiness: initial state is checking", startupModel.readiness.isChecking)
        await startupModel.runStartupReadinessCheck()
        expect("readiness: launch check turns green automatically", startupModel.readiness.isReady, startupModel.readiness.detail)
        expect("readiness: launch check is written to the log", startupModel.logs.contains { $0.category == "readiness" })
        expect("readiness: launch check refreshes the device list", !startupModel.devices.isEmpty)

        // 19. Single-action import: one button -> picker -> header read + staging + entry.
        let oneAction = AppModel.mock(scenario: .library)
        oneAction.resetForSelfCheck()
        await oneAction.importROM(at: "/tmp/Pokemon Y.cci")
        expect("import: one action imports the chosen ROM", oneAction.games.count == 1 && oneAction.games.first?.titleID == MockFixtures.titlePokemonY, String(oneAction.games.count))
        expect("import: one action stages the ROM data", oneAction.games.first?.romDataPath != nil)
        expect("import: one action lands in the library", oneAction.importPresented == false && oneAction.screen == .library)
        expect("import: SMDH names/publisher come from the pack CLI",
               oneAction.games.first?.displayNames["zh-Hans"] == "宝可梦 Y" && oneAction.games.first?.publisher == "Nintendo")
        expect("import: the SMDH cover.png is available for the card", oneAction.games.first?.coverPath.map { FileProbe.exists($0) } == true)

        // 19b. Re-importing a game that is already in the library passes
        // "--force" so the pack CLI refreshes the SMDH metadata and re-extracts
        // an old (scrambled) cover.png while keeping an already built GamePack;
        // a first import must not force.
        let mockPackBackend = oneAction.pack as? MockPackBackend
        expect("import: a first import does not force the pack CLI",
               mockPackBackend?.importCalls.count == 1 && mockPackBackend?.importCalls.first?.force == false,
               String(describing: mockPackBackend?.importCalls))
        await oneAction.importROM(at: "/tmp/Pokemon Y.cci")
        expect("import: re-import of an existing game passes --force (SMDH cover self-heal)",
               mockPackBackend?.importCalls.count == 2 && mockPackBackend?.importCalls.last?.force == true,
               String(describing: mockPackBackend?.importCalls))
        expect("import: the forced re-import updates the game in place and logs --force",
               oneAction.games.count == 1
               && oneAction.logs.contains { $0.message.contains("packages add") && $0.message.contains("--force") })

        return checks
    }
}