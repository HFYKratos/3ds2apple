//
//  InstallBackend.swift
//  3ds2apple macOS launcher
//
//  Install half of the one-click Deploy flow (docs/launcher-flow-v2.md):
//
//    1. xcodebuild builds the shell .app with the user's own Apple ID signing
//       (automatic signing; the Team ID is detected from the local Xcode
//       provisioning state, never typed into the UI);
//    2. the desktop CLI allocates the selected built GamePacks into the app
//       (Frameworks/GamePack-<TITLEID>.dylib + schema-2 GameCatalog.json) and
//       produces the unsigned library IPA;
//    3. this backend UNPACKS and INSPECTS that IPA before signing: every selected
//       title needs its real GamePack dylib, the catalogue must be schema 2 and
//       non-empty, and no ROM/game data may be bundled. A bare shell or a
//       preview IPA is refused, so the app never installs nothing;
//    4. the launcher code-signs every embedded GamePack and the staged app with
//       the local Apple Development identity, installs with devicectl, and reads
//       the installed bundle identifier back from the app's own Info.plist so
//       the Documents push uses the actual installed bundle ID.
//
//  The launcher never asks for an Apple ID or password: the user signs in to
//  Xcode once. Apple signing failures (9120/9401 style) are translated to plain
//  language by AppleErrorMapper. Certificate names/identities are never logged.
//

import Foundation
import AppKit

protocol InstallBackend: AnyObject {
    var mode: LauncherRunMode { get }
    var displayName: String { get }
    func readiness(teamID: String) async -> AppleReadiness
    func devices() async throws -> [DeviceInfo]
    /// Build the signed shell .app with Xcode automatic signing.
    func buildShellApp(
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> String
    /// Unpack the composed ROM-free library IPA and prove it carries the real
    /// per-title GamePacks + schema-2 GameCatalog (and no ROM data).
    func inspectLibraryIPA(ipaPath: String, expectedTitles: [String]) async throws -> IPAInspection
    /// Re-sign the inspected app with the local Apple Development identity,
    /// install with devicectl and return the actual installed bundle identifier.
    func installLibrary(
        inspection: IPAInspection,
        signedBaseAppPath: String,
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> InstallResult
}

// MARK: - Apple signing error translation

enum AppleErrorMapper {
    struct Explanation: Equatable {
        var title: String
        var hint: String
    }

    static func explain(_ text: String) -> Explanation? {
        let lowered = text.lowercased()
        func contains(_ needles: String...) -> Bool {
            needles.contains { lowered.contains($0.lowercased()) }
        }
        if contains("9120") {
            return Explanation(
                title: "Apple signing error 9120: the signing session was rejected.",
                hint: "Open Xcode -> Settings -> Accounts, sign out and sign back in with your own Apple ID, approve two-factor authentication, then retry."
            )
        }
        if contains("9401") {
            return Explanation(
                title: "Apple signing error 9401: this account/certificate cannot install the app.",
                hint: "Check: the Xcode account is signed in and trusted, the iPhone trusts the developer certificate (Settings -> General -> VPN & Device Management), the device is unlocked, and the free-account limits (3 apps / 7 days) are not exceeded."
            )
        }
        if contains("no signing certificate", "no valid signing certificate", "codesign failed", "0 valid identities") {
            return Explanation(
                title: "This Mac has no valid signing certificate for the selected team.",
                hint: "Sign in to Xcode -> Settings -> Accounts and let Xcode create the development certificate and profile (automatic signing)."
            )
        }
        if contains("no profiles for", "provisioning profile") {
            return Explanation(
                title: "No provisioning profile matches the shell's bundle identifier.",
                hint: "Open Xcode -> Settings -> Accounts once so automatic signing can create the profile, then retry."
            )
        }
        if contains("requires a development team", "development_team") {
            return Explanation(
                title: "Xcode signing needs your Apple Developer Team ID.",
                hint: "Open Xcode -> Settings -> Accounts and sign in; Xcode manages the team, and the launcher detects it automatically."
            )
        }
        if contains("not signed in", "unable to authenticate", "session expired") {
            return Explanation(
                title: "Xcode is not signed in to an Apple ID.",
                hint: "Open Xcode -> Settings -> Accounts and sign in with your own Apple ID. The launcher never asks for your password."
            )
        }
        if contains("developer mode") {
            return Explanation(
                title: "Developer Mode is disabled on the device.",
                hint: "On the iPhone/iPad: Settings -> Privacy & Security -> Developer Mode -> on, then reboot and confirm."
            )
        }
        if contains("failed to verify code signature", "integrity could not be verified", "amfi") {
            return Explanation(
                title: "The device rejected the app signature.",
                hint: "Trust the developer certificate on the device, reinstall with a fresh profile, and make sure the free-account 7-day profile has not expired."
            )
        }
        if contains("maximum number of apps", "free account") {
            return Explanation(
                title: "A free Apple ID can install at most 3 sideloaded apps per device.",
                hint: "Delete another sideloaded app on the device (Settings -> General -> iPhone Storage) and retry."
            )
        }
        if contains("device is locked", "unlock") {
            return Explanation(
                title: "The device is locked.",
                hint: "Unlock the iPhone/iPad, keep it connected and keep the screen on during the install."
            )
        }
        if contains("not paired", "pairing") {
            return Explanation(
                title: "This Mac is not paired with the device.",
                hint: "Unlock the device, tap Trust on the pairing prompt, then retry. Keep the cable connected."
            )
        }
        if contains("device not found", "no devices found", "no device") {
            return Explanation(
                title: "No iPhone/iPad was found.",
                hint: "Connect the device with a USB cable, unlock it, tap Trust, then refresh the device list."
            )
        }
        if contains("unable to install", "installation failed", "install failed") {
            return Explanation(
                title: "The device refused the install.",
                hint: "Check trust, Developer Mode, available storage and the free-account app limit, then retry."
            )
        }
        if contains("expired") {
            return Explanation(
                title: "A signing profile or certificate has expired.",
                hint: "Deploy again from the launcher so Xcode refreshes the profile (free Apple IDs expire after 7 days)."
            )
        }
        return nil
    }

    static func failure(command: String, text: String) -> LauncherFailure {
        let tail = text
            .split(separator: "\\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(3)
            .joined(separator: " | ")
        if let explanation = explain(text) {
            return LauncherFailure(
                code: "signing_error",
                message: explanation.title,
                hint: explanation.hint,
                detail: tail,
                exitCode: nil
            )
        }
        return LauncherFailure(
            code: "command_failed",
            message: "The " + command + " step failed.",
            hint: tail.isEmpty ? "Open the log for the full output." : tail,
            detail: tail,
            exitCode: nil
        )
    }
}

// MARK: - devicectl JSON

enum DevicectlJSON {
    static func parseDevices(_ data: Data) -> [DeviceInfo] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { item in
            let hardware = item["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = item["deviceProperties"] as? [String: Any] ?? [:]
            let connection = item["connectionProperties"] as? [String: Any] ?? [:]
            let udid = (hardware["udid"] as? String) ?? (item["identifier"] as? String) ?? ""
            guard !udid.isEmpty else { return nil }
            var transport = "usb"
            if let type = connection["transportType"] as? String {
                transport = type.lowercased().contains("network") || type.lowercased().contains("wifi") ? "network" : "usb"
            }
            let pairing = (connection["pairingState"] as? String) ?? "paired"
            return DeviceInfo(
                udid: udid,
                name: properties["name"] as? String ?? "iOS device",
                model: properties["modelName"] as? String ?? (hardware["productType"] as? String ?? "iPhone/iPad"),
                iosVersion: properties["osVersionNumber"] as? String ?? "?",
                connection: transport,
                paired: pairing == "paired"
            )
        }
    }
}

// MARK: - Library IPA inspection

/// Pure catalogue parsing / validation helpers. Kept static so the headless
/// self-check can prove the "pack + schema-2 catalogue + no ROM" rules without a
/// real IPA on disk.
enum LibraryIPACatalog {
    struct Facts: Equatable {
        var schemaVersion: Int
        var titleIDs: [String]
        var packedROMFiles: [String]
    }

    static func parse(_ data: Data) -> Facts? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let schema = PackJSON.int64(root["schemaVersion"])
        let games = root["games"] as? [[String: Any]] ?? []
        var titles: [String] = []
        var romFiles: [String] = []
        for game in games {
            let title = (game["titleID"] as? String ?? "").uppercased()
            if !title.isEmpty { titles.append(title) }
            if let romFile = game["romFile"] as? String, !romFile.isEmpty {
                romFiles.append(romFile)
            }
        }
        return Facts(schemaVersion: Int(schema), titleIDs: titles, packedROMFiles: romFiles)
    }

    /// Frameworks/GamePack-<TITLEID>.dylib files present in an app bundle.
    static func packDylibFiles(inAppAt appPath: String) -> [String] {
        let frameworks = URL(fileURLWithPath: appPath).appendingPathComponent("Frameworks")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return files
            .filter { $0.hasPrefix("GamePack-") && $0.hasSuffix(".dylib") }
            .sorted()
            .map { "Frameworks/" + $0 }
    }

    /// True when the app bundle or catalogue bundles game data (must not happen
    /// for a launcher deploy: only AOT code goes into the signed app).
    static func containsBundledROM(appPath: String, facts: Facts?) -> Bool {
        let roms = URL(fileURLWithPath: appPath).appendingPathComponent("Roms")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: roms.path), !entries.isEmpty {
            return true
        }
        return !(facts?.packedROMFiles.isEmpty ?? true)
    }
}

// MARK: - Xcode / devicectl implementation

final class XcodeInstallBackend: InstallBackend {
    let runner: CommandRunning
    let repoRoot: URL
    let paths: ToolchainPaths
    let mode: LauncherRunMode = .live
    /// Launcher-owned build scratch (<portable data root>/build): the signed
    /// shell DerivedData and the IPA inspection unzip live here, not in the
    /// checkout (Windows 0.2.4 portable-data parity).
    let workRoot: URL

    init(runner: CommandRunning, repoRoot: URL, paths: ToolchainPaths, buildRoot: URL? = nil) {
        self.runner = runner
        self.repoRoot = repoRoot
        self.paths = paths
        self.workRoot = buildRoot ?? repoRoot.appendingPathComponent("build", isDirectory: true)
    }

    var displayName: String { "Xcode + devicectl" }

    func readiness(teamID: String) async -> AppleReadiness {
        let xcode = try? await runner.run(CommandSpec(executable: paths.xcodebuild, arguments: ["-version"]), onLine: nil)
        let xcodeVersion = xcode?.combined
            .split(separator: "\\n")
            .first(where: { $0.hasPrefix("Xcode") })
            .map(String.init) ?? "Xcode not available"
        let devicectl = try? await runner.run(CommandSpec(executable: paths.xcrun, arguments: ["--find", "devicectl"]), onLine: nil)
        let identities = await countIdentities()
        let profiles = countProfiles()
        let teams = await TeamDetector.detect(runner: runner)
        return AppleReadiness(
            xcodePath: await xcodeSelectPath(),
            xcodeVersion: xcodeVersion,
            devicectlAvailable: (devicectl?.succeeded ?? false),
            signingIdentityCount: identities,
            provisioningProfileCount: profiles,
            teamID: teams.first ?? teamID,
            checkedAt: Date()
        )
    }

    private func xcodeSelectPath() async -> String {
        let result = try? await runner.run(CommandSpec(executable: "/usr/bin/xcode-select", arguments: ["-p"]), onLine: nil)
        return (result?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func countIdentities() async -> Int {
        guard let result = try? await runner.run(
            CommandSpec(executable: paths.security, arguments: ["find-identity", "-v", "-p", "codesigning"]),
            onLine: nil
        ) else { return 0 }
        guard let regex = try? NSRegularExpression(pattern: "([0-9]+) valid identities found") else { return 0 }
        let text = result.combined
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return 0 }
        return Int(text[captured]) ?? 0
    }

    private func countProfiles() -> Int {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "mobileprovision" }.count
    }

    func devices() async throws -> [DeviceInfo] {
        let jsonPath = NSTemporaryDirectory() + "zl-devicectl-devices-" + UUID().uuidString + ".json"
        defer { try? FileManager.default.removeItem(atPath: jsonPath) }
        let result = try await runner.run(CommandSpec(
            executable: paths.xcrun,
            arguments: ["devicectl", "--json-output", jsonPath, "list", "devices"]
        ), onLine: nil)
        let data = (try? Data(contentsOf: URL(fileURLWithPath: jsonPath))) ?? Data()
        let devices = DevicectlJSON.parseDevices(data)
        if devices.isEmpty && !result.succeeded {
            throw AppleErrorMapper.failure(command: "devicectl list devices", text: result.combined)
        }
        return devices
    }

    // MARK: shell app build

    func buildShellApp(
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> String {
        guard let xcodegen = paths.xcodegen else {
            throw LauncherFailure(
                code: "xcodegen_missing",
                message: "xcodegen is not installed.",
                hint: "Install it once with: brew install xcodegen (or put the binary in /usr/local/bin).",
                detail: nil,
                exitCode: nil
            )
        }
        guard !options.teamID.isEmpty else {
            throw LauncherFailure(
                code: "team_missing",
                message: "No Apple Developer Team ID could be detected.",
                hint: "Open Xcode -> Settings -> Accounts, sign in with your own Apple ID and let Xcode create a development certificate/profile, then retry.",
                detail: nil,
                exitCode: nil
            )
        }
        let staticLibrary = repoRoot.appendingPathComponent("build/ios/libzakuro_ios.a")
        guard FileProbe.exists(staticLibrary.path) else {
            throw LauncherFailure(
                code: "shell_runtime_missing",
                message: "The shell runtime static library is missing.",
                hint: "Build it once on this Mac: scripts/build-zakuro-ios.sh (needs the Rust aarch64-apple-ios target).",
                detail: staticLibrary.path,
                exitCode: nil
            )
        }
        let appDirectory = repoRoot.appendingPathComponent("ios/app")
        onProgress(InstallProgress(stage: "Generate Xcode project", fraction: 0.05, line: "xcodegen generate"))
        let generate = try await runner.run(CommandSpec(
            executable: xcodegen,
            arguments: ["generate", "--spec", "project.yml"],
            workingDirectory: appDirectory.path
        ), onLine: { _, line in
            onProgress(InstallProgress(stage: "Generate Xcode project", fraction: 0.08, line: line))
        })
        if !generate.succeeded {
            throw LauncherFailure(code: "xcodegen_failed", message: "Could not generate the shell Xcode project.", hint: "Check ios/app/project.yml and the xcodegen install.", detail: generate.combined, exitCode: generate.exitCode)
        }

        let derived = workRoot.appendingPathComponent("launcher-shell")
        let stageName = "Building signed shell app"
        onProgress(InstallProgress(stage: stageName, fraction: 0.12, line: "xcodebuild build (this can take a few minutes)"))
        var arguments = [
            "-project", "ios/app/3ds2apple.xcodeproj",
            "-scheme", "3ds2apple",
            "-configuration", "Debug",
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", derived.path,
            "CODE_SIGN_STYLE=Automatic",
            "CODE_SIGNING_ALLOWED=YES",
            "CODE_SIGNING_REQUIRED=YES",
            "DEVELOPMENT_TEAM=" + options.teamID,
        ]
        if options.allowProvisioningUpdates {
            arguments.append("-allowProvisioningUpdates")
        }
        arguments.append("build")
        let build = try await runner.run(CommandSpec(
            executable: paths.xcodebuild,
            arguments: arguments,
            workingDirectory: repoRoot.path
        ), onLine: { _, line in
            onProgress(InstallProgress(stage: stageName, fraction: nil, line: line))
        })
        if !build.succeeded {
            throw AppleErrorMapper.failure(command: "xcodebuild", text: build.combined)
        }
        let app = derived.appendingPathComponent("Build/Products/Debug-iphoneos/3ds2apple.app")
        guard FileProbe.exists(app.path) else {
            throw LauncherFailure(
                code: "shell_app_missing",
                message: "xcodebuild finished but the shell .app was not found.",
                hint: "Check the build log; the signing profile may have failed to resolve.",
                detail: app.path,
                exitCode: nil
            )
        }

        // The shell's Vulkan renderer dlopen()s Frameworks/MoltenVK.framework at
        // run time (hardware PICA200 + CAMetalLayer Metal HUD). Copy the
        // verified framework into the built .app BEFORE it is signed or
        // composed into the library IPA; a shell without it stays on the slow
        // software renderer with no HUD.
        onProgress(InstallProgress(stage: stageName, fraction: 0.9, line: "Embedding Frameworks/MoltenVK.framework (Metal renderer + HUD)"))
        let runtimeSource: ShellRuntime.Source
        do {
            runtimeSource = try ShellRuntime.resolveFramework(repoRoot: repoRoot.path)
        } catch {
            throw LauncherFailure(
                code: "shell_runtime_source_missing",
                message: "The MoltenVK runtime for hardware rendering and the Metal HUD was not found.",
                hint: "Keep the launcher's embedded MoltenVK resource, the pinned out/shell/3ds2apple-shell.ipa template, or build/third_party/MoltenVK.framework in the checkout.",
                detail: error.localizedDescription,
                exitCode: nil
            )
        }
        defer { runtimeSource.cleanUp() }
        do {
            try ShellRuntime.copyFramework(from: runtimeSource, intoShellAppAt: app.path)
        } catch {
            throw LauncherFailure(
                code: "shell_runtime_embed_failed",
                message: "Could not embed Frameworks/MoltenVK.framework into the shell app.",
                hint: "The app was built but is not Metal/HUD capable, so the deploy is refused.",
                detail: error.localizedDescription,
                exitCode: nil
            )
        }
        let runtimeProblems = ShellRuntime.verifyShellApp(at: app.path)
        guard runtimeProblems.isEmpty else {
            throw LauncherFailure(
                code: "shell_runtime_invalid",
                message: "The built shell is not Metal/HUD ready.",
                hint: runtimeProblems.joined(separator: "; "),
                detail: app.path,
                exitCode: nil
            )
        }
        onProgress(InstallProgress(
            stage: stageName,
            fraction: 0.92,
            line: "MoltenVK.framework: " + runtimeSource.origin.rawValue + " (" + String(ShellRuntime.expectedBytes) + " bytes, pinned arm64)"
        ))
        // Keep the base .app signature valid after adding nested code: sign the
        // framework, then re-seal the app preserving its entitlements. The
        // install step re-signs everything again, so a failure here is not fatal.
        if let identity = await firstSigningIdentityHash() {
            let frameworkBinary = app.path + "/" + ShellRuntime.binaryRelativePath
            let signFramework = try? await runner.run(CommandSpec(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", identity, "--timestamp=none", frameworkBinary]
            ), onLine: nil)
            let resealApp = try? await runner.run(CommandSpec(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", identity, "--timestamp=none", "--preserve-metadata=entitlements", app.path]
            ), onLine: nil)
            if signFramework?.succeeded != true || resealApp?.succeeded != true {
                onProgress(InstallProgress(stage: stageName, fraction: 0.94, line: "warning: could not re-seal the base shell after embedding MoltenVK; the install step re-signs it"))
            }
        }
        onProgress(InstallProgress(stage: stageName, fraction: 1.0, line: "Shell app ready (MoltenVK embedded): " + app.path))
        return app.path
    }

    // MARK: IPA inspection

    func inspectLibraryIPA(ipaPath: String, expectedTitles: [String]) async throws -> IPAInspection {
        guard FileProbe.exists(ipaPath) else {
            throw LauncherFailure(
                code: "ipa_missing",
                message: "The composed library IPA was not found.",
                hint: "Retry the deploy; the compose step must finish before install.",
                detail: ipaPath,
                exitCode: nil
            )
        }
        let stagedApp = try await unpackIPA(ipaPath)
        return try inspectStagedApp(appPath: stagedApp, ipaPath: ipaPath, expectedTitles: expectedTitles)
    }

    private func inspectStagedApp(appPath: String, ipaPath: String, expectedTitles: [String]) throws -> IPAInspection {
        let bundleID = appBundleIdentifier(at: appPath) ?? ""
        let packFiles = LibraryIPACatalog.packDylibFiles(inAppAt: appPath)
        let catalogURL = URL(fileURLWithPath: appPath).appendingPathComponent("GameCatalog.json")
        let facts = (try? Data(contentsOf: catalogURL)).flatMap { LibraryIPACatalog.parse($0) }
        if facts == nil {
            throw LauncherFailure(
                code: "library_ipa_invalid",
                message: "The composed IPA has no readable GameCatalog.json.",
                hint: "The packaging script must embed a schema-2 GameCatalog.json in the app bundle. Check the packaging log and retry.",
                detail: catalogURL.path,
                exitCode: nil
            )
        }
        let containsROM = LibraryIPACatalog.containsBundledROM(appPath: appPath, facts: facts)
        let inspection = IPAInspection(
            ipaPath: ipaPath,
            appPath: appPath,
            bundleID: bundleID,
            packFiles: packFiles,
            catalogSchemaVersion: facts?.schemaVersion ?? 0,
            catalogTitleIDs: facts?.titleIDs ?? [],
            containsBundledROM: containsROM,
            hasMoltenVK: ShellRuntime.hasFramework(inShellAppAt: appPath),
            bytes: FileProbe.size(ipaPath) ?? 0
        )
        let problems = inspection.problems(expectedTitles: expectedTitles)
        if !problems.isEmpty {
            throw LauncherFailure(
                code: "library_ipa_invalid",
                message: "The composed IPA is not a valid multi-game library payload.",
                hint: problems.joined(separator: "; "),
                detail: "app=" + appPath + " packs=" + packFiles.joined(separator: ",") + " catalog=" + (facts?.titleIDs.joined(separator: ",") ?? "none"),
                exitCode: nil
            )
        }
        return inspection
    }

    private func appBundleIdentifier(at appPath: String) -> String? {
        let plist = appPath + "/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleID = object["CFBundleIdentifier"] as? String else { return nil }
        return bundleID
    }

    // MARK: library sign + install

    func installLibrary(
        inspection: IPAInspection,
        signedBaseAppPath: String,
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> InstallResult {
        let started = Date()
        guard let udid = options.deviceUDID, !udid.isEmpty else {
            throw LauncherFailure(
                code: "device_missing",
                message: "No device selected.",
                hint: "Connect the iPhone/iPad, tap Trust, then refresh the device list.",
                detail: nil,
                exitCode: nil
            )
        }
        guard let identity = await firstSigningIdentityHash() else {
            throw LauncherFailure(
                code: "no_signing_assets",
                message: "No Apple Development signing identity was found.",
                hint: "Open Xcode -> Settings -> Accounts, sign in with your own Apple ID and let Xcode create the development certificate.",
                detail: nil,
                exitCode: nil
            )
        }
        let stagedApp = inspection.appPath
        guard FileProbe.exists(stagedApp), !inspection.packFiles.isEmpty else {
            throw LauncherFailure(
                code: "library_ipa_no_packs",
                message: "The composed IPA contains no GamePack dylib.",
                hint: "Build at least one real GamePack and compose the IPA again.",
                detail: inspection.packFiles.joined(separator: ","),
                exitCode: nil
            )
        }

        // The composed shell must still carry the Metal/HUD runtime; sign the
        // nested framework BEFORE the outer app so codesign --verify --deep
        // --strict can succeed. A shell without it would run in software.
        let runtimeProblems = ShellRuntime.verifyShellApp(at: stagedApp)
        guard runtimeProblems.isEmpty else {
            throw LauncherFailure(
                code: "shell_runtime_invalid",
                message: "The composed library IPA is missing the Metal/HUD runtime.",
                hint: runtimeProblems.joined(separator: "; "),
                detail: stagedApp,
                exitCode: nil
            )
        }
        onProgress(InstallProgress(stage: "Signing MoltenVK", fraction: 0.3, line: "codesign nested Frameworks/MoltenVK.framework (local identity)"))
        let runtimeSign = try await runner.run(CommandSpec(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", identity, "--timestamp=none", stagedApp + "/" + ShellRuntime.binaryRelativePath]
        ), onLine: nil)
        if !runtimeSign.succeeded {
            throw AppleErrorMapper.failure(command: "codesign (MoltenVK.framework)", text: runtimeSign.combined)
        }

        onProgress(InstallProgress(stage: "Signing GamePacks", fraction: 0.35, line: "codesign embedded Frameworks/GamePack-*.dylib (local identity)"))
        for pack in inspection.packFiles {
            let packPath = stagedApp + "/" + pack
            let sign = try await runner.run(CommandSpec(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", identity, "--timestamp=none", packPath]
            ), onLine: nil)
            if !sign.succeeded {
                throw AppleErrorMapper.failure(command: "codesign (GamePack)", text: sign.combined)
            }
        }
        onProgress(InstallProgress(stage: "Signing app bundle", fraction: 0.55, line: "codesign the staged app (local identity)"))
        try copyEmbeddedProfileIfNeeded(stagedApp: stagedApp, signedBaseAppPath: signedBaseAppPath)
        let entitlementsPath = await extractEntitlements(from: signedBaseAppPath)
        var signArguments = ["--force", "--sign", identity, "--timestamp=none"]
        if let entitlementsPath {
            signArguments += ["--entitlements", entitlementsPath]
        }
        signArguments.append(stagedApp)
        let signApp = try await runner.run(CommandSpec(executable: "/usr/bin/codesign", arguments: signArguments), onLine: nil)
        if !signApp.succeeded {
            throw AppleErrorMapper.failure(command: "codesign (app)", text: signApp.combined)
        }
        let verify = try await runner.run(CommandSpec(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", stagedApp]
        ), onLine: nil)
        if !verify.succeeded {
            throw LauncherFailure(
                code: "signature_invalid",
                message: "The re-signed library app did not pass codesign verification.",
                hint: "Check that the detected Team ID matches the Apple ID signed in to Xcode, then retry.",
                detail: verify.combined,
                exitCode: verify.exitCode
            )
        }

        onProgress(InstallProgress(stage: "Installing with devicectl", fraction: 0.8, line: "xcrun devicectl device install app --device <device>"))
        let install = try await runner.run(CommandSpec(
            executable: paths.xcrun,
            arguments: ["devicectl", "device", "install", "app", "--device", udid, stagedApp]
        ), onLine: { _, line in
            onProgress(InstallProgress(stage: "Installing with devicectl", fraction: 0.9, line: line))
        })
        if !install.succeeded {
            throw AppleErrorMapper.failure(command: "devicectl install", text: install.combined)
        }
        let installedBundleID = appBundleIdentifier(at: stagedApp) ?? inspection.bundleID
        onProgress(InstallProgress(stage: "Installed", fraction: 1.0, line: "Library app installed (" + installedBundleID + "). Next: push the game data."))
        return InstallResult(
            appPath: stagedApp,
            signed: true,
            installed: true,
            verifiedBundleID: installedBundleID,
            packFiles: inspection.packFiles,
            catalogTitleIDs: inspection.catalogTitleIDs,
            duration: Date().timeIntervalSince(started)
        )
    }

    private func unpackIPA(_ ipaPath: String) async throws -> String {
        let directory = workRoot.appendingPathComponent("ipa-inspect-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await runner.run(CommandSpec(
            executable: "/usr/bin/unzip",
            arguments: ["-q", "-o", ipaPath, "-d", directory.path]
        ), onLine: nil)
        guard result.succeeded else {
            throw LauncherFailure(code: "unzip_failed", message: "Could not unpack the library IPA.", hint: "Rebuild the library IPA.", detail: result.combined, exitCode: result.exitCode)
        }
        let payload = directory.appendingPathComponent("Payload")
        let contents = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw LauncherFailure(code: "ipa_layout", message: "The library IPA has no Payload/*.app.", hint: "Rebuild the library IPA.", detail: ipaPath, exitCode: nil)
        }
        return app.path
    }

    private func firstSigningIdentityHash() async -> String? {
        guard let result = try? await runner.run(
            CommandSpec(executable: paths.security, arguments: ["find-identity", "-v", "-p", "codesigning"]),
            onLine: nil
        ) else { return nil }
        let text = result.combined
        guard let regex = try? NSRegularExpression(pattern: "([0-9A-Fa-f]{40})") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        let hash = String(text[captured])
        return hash.isEmpty ? nil : hash
    }

    private func copyEmbeddedProfileIfNeeded(stagedApp: String, signedBaseAppPath: String) throws {
        let staged = stagedApp + "/embedded.mobileprovision"
        guard !FileProbe.exists(staged) else { return }
        let source = signedBaseAppPath + "/embedded.mobileprovision"
        guard FileProbe.exists(source) else {
            throw LauncherFailure(
                code: "profile_missing",
                message: "The signed shell app carries no provisioning profile to reuse.",
                hint: "Let xcodebuild sign the shell with automatic signing first (Xcode account signed in), then retry.",
                detail: source,
                exitCode: nil
            )
        }
        try FileManager.default.copyItem(atPath: source, toPath: staged)
    }

    private func extractEntitlements(from appPath: String) async -> String? {
        guard let result = try? await runner.run(CommandSpec(
            executable: "/usr/bin/codesign",
            arguments: ["--display", "--entitlements", ":-", appPath]
        ), onLine: nil), result.succeeded else { return nil }
        let output = result.stdout
        guard output.contains("<?xml") || output.contains("<plist") else { return nil }
        let path = NSTemporaryDirectory() + "zl-entitlements-" + UUID().uuidString + ".plist"
        do {
            try output.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }
}

// MARK: - Mock installer

final class MockInstallBackend: InstallBackend {
    let mode: LauncherRunMode = .mock
    var displayName: String { "Mock installer" }
    var readinessState: AppleReadiness
    /// Test hooks: the self-check proves that compose/install never runs when an
    /// earlier deploy step failed, and can inject an invalid IPA inspection.
    private(set) var shellBuildCalls = 0
    private(set) var installCalls = 0
    var overrideInspection: IPAInspection?
    var overrideInstallBundleID: String?

    init(readinessState: AppleReadiness) {
        self.readinessState = readinessState
    }

    func readiness(teamID: String) async -> AppleReadiness {
        var state = readinessState
        if state.teamID.isEmpty { state.teamID = teamID }
        return state
    }

    func devices() async throws -> [DeviceInfo] {
        MockFixtures.devices
    }

    func buildShellApp(
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> String {
        shellBuildCalls += 1
        let stages: [(String, Double, String)] = [
            ("Generate Xcode project", 0.08, "xcodegen generate --spec project.yml (mock)"),
            ("Building signed shell app", 0.3, "xcodebuild ... DEVELOPMENT_TEAM=<detected> (mock)"),
        ]
        for stage in stages {
            try? await Task.sleep(nanoseconds: 60_000_000)
            onProgress(InstallProgress(stage: stage.0, fraction: stage.1, line: stage.2))
        }
        return "/Users/you/3ds2apple/build/launcher-shell/Build/Products/Debug-iphoneos/3ds2apple.app"
    }

    func inspectLibraryIPA(ipaPath: String, expectedTitles: [String]) async throws -> IPAInspection {
        try? await Task.sleep(nanoseconds: 60_000_000)
        if let overrideInspection { return overrideInspection }
        return IPAInspection(
            ipaPath: ipaPath,
            appPath: "/mock/library-ipa/Payload/3ds2apple.app",
            bundleID: MockFixtures.installedShellBundleID,
            packFiles: expectedTitles.sorted().map { "Frameworks/GamePack-" + $0.uppercased() + ".dylib" },
            catalogSchemaVersion: 2,
            catalogTitleIDs: expectedTitles.map { $0.uppercased() },
            containsBundledROM: false,
            hasMoltenVK: true,
            bytes: 12_345_678
        )
    }

    func installLibrary(
        inspection: IPAInspection,
        signedBaseAppPath: String,
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> InstallResult {
        installCalls += 1
        let stages: [(String, Double, String)] = [
            ("Signing MoltenVK", 0.42, "codesign nested Frameworks/MoltenVK.framework (local identity, mock)"),
            ("Signing GamePacks", 0.5, "codesign Frameworks/GamePack-*.dylib (local identity, mock)"),
            ("Signing app bundle", 0.7, "codesign the staged library app (local identity, mock)"),
            ("Installing with devicectl", 0.9, "xcrun devicectl device install app --device <mock> (mock)"),
            ("Installed", 1.0, "Library app installed (mock)."),
        ]
        for stage in stages {
            try? await Task.sleep(nanoseconds: 60_000_000)
            onProgress(InstallProgress(stage: stage.0, fraction: stage.1, line: stage.2))
        }
        return InstallResult(
            appPath: inspection.appPath,
            signed: true,
            installed: true,
            verifiedBundleID: overrideInstallBundleID ?? inspection.bundleID,
            packFiles: inspection.packFiles,
            catalogTitleIDs: inspection.catalogTitleIDs,
            duration: 0.3
        )
    }
}
