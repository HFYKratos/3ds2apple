//
//  SelfCheckFlow.swift
//  3ds2apple macOS launcher
//
//  Self-check part 2: Apple signing error translation, log redaction and the
//  full mock import -> build -> push -> install-readiness flow.
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

        // 11. End-to-end mock flow: import (ROM-free) -> build -> library -> push data
        let model = AppModel.mock(scenario: .library)
        model.resetForSelfCheck()
        model.detectedROM = MockFixtures.detectedROM()
        await model.importDetected(includeROM: false)
        expect("flow: import queues a game", model.games.count == 1 && model.games.first?.titleID == MockFixtures.titlePokemonY)
        expect("flow: import stages ROM data for the Documents push", model.game(id: MockFixtures.titlePokemonY)?.romDataPath != nil)
        await model.detectDevices()
        expect("flow: device detection selects a device", model.devices.count == 2 && model.selectedDeviceUDID == MockFixtures.devices.first?.udid)
        model.settings.buildMode = .fake
        await model.build(gameID: MockFixtures.titlePokemonY)
        expect("flow: build sets AOT-ready phase", model.game(id: MockFixtures.titlePokemonY)?.phase == .built)
        expect("flow: build task succeeded", model.tasks.first(where: { $0.kind == .buildAOT })?.state == .succeeded)
        model.markLibraryInstalled(titles: [MockFixtures.titlePokemonY], ipaPath: "/tmp/3ds2apple-library.ipa")
        expect("flow: library matches after marking installed", model.libraryNeedsRebuild == false)
        _ = await model.preparePush(gameID: MockFixtures.titlePokemonY)
        expect("flow: push plan prepared (2 files, GameInfo last)", model.pushPlans[MockFixtures.titlePokemonY]?.files.count == 2 && model.pushPlans[MockFixtures.titlePokemonY]?.files.last?.name == "GameInfo.json")
        await model.pushGame(gameID: MockFixtures.titlePokemonY)
        expect("flow: push marks on-device", model.game(id: MockFixtures.titlePokemonY)?.phase == .pushed)
        expect("flow: push verified on device", model.pushPlans[MockFixtures.titlePokemonY]?.verified == true)
        expect("flow: push task succeeded", model.tasks.first(where: { $0.kind == .pushGame })?.state == .succeeded)

        // 11b. Pushing a game whose pack is not in the installed library is refused.
        let guarded = AppModel.mock(scenario: .library)
        guarded.resetForSelfCheck()
        guarded.games = [MockFixtures.games()[0]]
        guarded.selectedDeviceUDID = MockFixtures.devices.first?.udid
        await guarded.pushGame(gameID: MockFixtures.titlePokemonY)
        expect("flow: push refused when the pack is not in the installed library", guarded.pushError?.code == "library_not_installed")

        // 11c. Library rebuild detection when the built set changes.
        var extraGame = MockFixtures.games()[1]
        extraGame.phase = .built
        model.games.append(extraGame)
        expect("flow: adding a built game marks the library for rebuild", model.libraryNeedsRebuild == true)

        // 12. Library install readiness failure is plain language (no Apple ID on the VM)
        let installModel = AppModel.mock(scenario: .install)
        installModel.settings.installStrategy = .xcodebuild
        await installModel.buildAndInstallLibrary()
        expect("flow: library install refuses without signing assets", installModel.lastInstallFailure?.code == "no_signing_assets")
        expect("flow: install failure explains Xcode accounts", installModel.lastInstallFailure?.hint.contains("Xcode") == true)
        expect("flow: install task records the failure", installModel.tasks.first(where: { $0.kind == .installShell })?.state == .failed)

        // 13. Mock strategy keeps a structured outcome instead of crashing
        let readyModel = AppModel.mock(scenario: .install)
        readyModel.settings.installStrategy = .mock
        await readyModel.buildAndInstallLibrary()
        expect("flow: mock strategy returns a structured outcome", readyModel.lastInstallFailure != nil || readyModel.installResult != nil)

        // 14. Dry run never changes the package phase
        let dryModel = AppModel.mock(scenario: .library)
        dryModel.settings.buildMode = .dryRun
        let before = dryModel.game(id: MockFixtures.titlePokemonY)?.phase
        await dryModel.build(gameID: MockFixtures.titlePokemonY)
        expect("flow: dry run keeps the package phase", dryModel.game(id: MockFixtures.titlePokemonY)?.phase == before, String(describing: before))
        expect("flow: dry run task succeeded", dryModel.tasks.first(where: { $0.kind == .buildAOT })?.state == .succeeded)

        // 15. Task progress math
        var task = TaskRecord(
            kind: .buildAOT,
            title: "t",
            titleID: "1",
            state: .running,
            stages: [
                PipelineStage(title: "a", detail: "", state: .succeeded),
                PipelineStage(title: "b", detail: "", state: .running),
                PipelineStage(title: "c", detail: "", state: .pending),
            ],
            startedAt: Date(),
            endedAt: nil,
            errorMessage: nil,
            errorHint: nil,
            detail: ""
        )
        expect("tasks: progress counts completed and running stage", abs(task.progress - 0.5) < 0.001, String(task.progress))
        task.state = .succeeded
        task.endedAt = Date()
        expect("tasks: succeeded task duration is non-negative", task.duration >= 0)

        // 16. Mock environment report and log export
        let report = MockFixtures.environment()
        expect("diagnostics: mock environment has tools", report.tools.count >= 8)
        expect("diagnostics: mock environment flags missing signing", !report.apple.hasSigningAssets)
        expect("diagnostics: mock devpush capabilities present", report.devpushCapabilities?.schema == "devpush/1")
        let logModel = AppModel.mock(scenario: .activity)
        logModel.exportLog()
        expect("logs: export writes a file", logModel.lastExportPath.map { FileProbe.exists($0) } == true)

        return checks
    }
}
