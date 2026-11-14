//
//  InstallBackend.swift
//  3ds2apple macOS launcher
//
//  Corrected launcher-first architecture (2026-11-14): the per-game AOT code
//  must live inside the signed app/IPA (iOS will not dlopen unsigned code from
//  the container). The install path therefore is:
//
//    1. xcodebuild builds the ROM-free shell .app with the user's own Apple ID
//       signing (automatic signing, -allowProvisioningUpdates);
//    2. the desktop CLI allocates the built GamePacks into the app
//       (Frameworks/GamePack-<TITLEID>.dylib + bundle GameCatalog.json) and
//       produces the unsigned library IPA;
//    3. the launcher unzips the IPA, code-signs every embedded GamePack and the
//       staged .app with the same local Apple Development identity, and installs
//       it with xcrun devicectl.
//
//  The launcher never asks for an Apple ID or password: the user signs in to
//  Xcode once. The Impactor strategy opens the unsigned library IPA in the
//  official Impactor (if installed) for a manual sign/install instead.
//
//  Apple signing failures (9120/9401 style) are translated to plain language by
//  AppleErrorMapper. Certificate names/identities are never logged.
//

import Foundation
import AppKit

protocol InstallBackend: AnyObject {
    var mode: LauncherRunMode { get }
    var displayName: String { get }
    func readiness(teamID: String) async -> AppleReadiness
    func devices() async throws -> [DeviceInfo]
    /// Build the shell .app with Xcode. signed=true is the base for the
    /// library-IPA signing path; signed=false is used by the Impactor flow.
    func buildShellApp(
        signed: Bool,
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> String
    /// Unpack the ROM-free library IPA, sign embedded GamePacks + app with the
    /// local Apple Development identity, install with devicectl, verify.
    func installLibrary(
        ipaPath: String,
        signedBaseAppPath: String,
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> InstallResult
    /// Open an unsigned library IPA in the official Impactor (manual sign/install).
    func openLibraryIPAInImpactor(ipaPath: String, options: InstallOptions) async throws
    func commandPlan(options: InstallOptions) -> [String]
    func impactorApplicationPath() -> String?
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
                hint: "Set your Team ID, then retry with automatic signing. If the bundle ID was changed, use a unique com.yourname.3ds2apple value."
            )
        }
        if contains("requires a development team", "development_team") {
            return Explanation(
                title: "Xcode signing needs your Apple Developer Team ID.",
                hint: "Enter the 10-character Team ID on the Shell + library screen (Xcode -> Settings -> Accounts shows it)."
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
                hint: "Rebuild and reinstall from the launcher so Xcode refreshes the profile (free Apple IDs expire after 7 days)."
            )
        }
        return nil
    }

    static func failure(command: String, text: String) -> LauncherFailure {
        let tail = text
            .split(separator: "\n")
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

// MARK: - Xcode / devicectl implementation

final class XcodeInstallBackend: InstallBackend {
    let runner: CommandRunning
    let repoRoot: URL
    let paths: ToolchainPaths
    let mode: LauncherRunMode = .live

    init(runner: CommandRunning, repoRoot: URL, paths: ToolchainPaths) {
        self.runner = runner
        self.repoRoot = repoRoot
        self.paths = paths
    }

    var displayName: String { "Xcode + devicectl" }

    func readiness(teamID: String) async -> AppleReadiness {
        let xcode = try? await runner.run(CommandSpec(executable: paths.xcodebuild, arguments: ["-version"]), onLine: nil)
        let xcodeVersion = xcode?.combined
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("Xcode") })
            .map(String.init) ?? "Xcode not available"
        let devicectl = try? await runner.run(CommandSpec(executable: paths.xcrun, arguments: ["--find", "devicectl"]), onLine: nil)
        let identities = await countIdentities()
        let profiles = countProfiles()
        return AppleReadiness(
            xcodePath: await xcodeSelectPath(),
            xcodeVersion: xcodeVersion,
            devicectlAvailable: (devicectl?.succeeded ?? false),
            signingIdentityCount: identities,
            provisioningProfileCount: profiles,
            teamID: teamID,
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

    func commandPlan(options: InstallOptions) -> [String] {
        let team = options.teamID.isEmpty ? "<YOUR_TEAM_ID>" : options.teamID
        return [
            "cd " + repoRoot.path + "/ios/app && xcodegen generate --spec project.yml",
            "xcodebuild -project ios/app/3ds2apple.xcodeproj -scheme 3ds2apple -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/launcher-shell CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=" + team + " -allowProvisioningUpdates build",
            "3ds2apple-pack --out out pack --all --execute --base-app build/launcher-shell/Build/Products/Debug-iphoneos/3ds2apple.app --ipa-out IPA --ipa-name 3ds2apple-library",
            "codesign -f -s <Apple Development identity> <staged app>/Frameworks/GamePack-<TITLEID>.dylib",
            "codesign -f -s <Apple Development identity> <staged app>",
            "xcrun devicectl device install app --device <DEVICE_UDID> <staged app>",
        ]
    }

    func impactorApplicationPath() -> String? {
        let candidates = ["/Applications/Impactor.app", "/Applications/Impactor 2.app"]
        return candidates.first(where: { FileProbe.exists($0) })
    }

    // MARK: shell app build

    func buildShellApp(
        signed: Bool,
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

        let derived = repoRoot.appendingPathComponent(signed ? "build/launcher-shell" : "build/launcher-shell-unsigned")
        let stageName = signed ? "Building signed shell app" : "Building shell app"
        onProgress(InstallProgress(stage: stageName, fraction: 0.12, line: "xcodebuild build (this can take a few minutes)"))
        var arguments = [
            "-project", "ios/app/3ds2apple.xcodeproj",
            "-scheme", "3ds2apple",
            "-configuration", "Debug",
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", derived.path,
        ]
        if signed {
            arguments += [
                "CODE_SIGN_STYLE=Automatic",
                "CODE_SIGNING_ALLOWED=YES",
                "CODE_SIGNING_REQUIRED=YES",
                "DEVELOPMENT_TEAM=" + options.teamID,
            ]
            if options.allowProvisioningUpdates {
                arguments.append("-allowProvisioningUpdates")
            }
        } else {
            arguments += ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
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
        return app.path
    }

    // MARK: library IPA sign + install

    func installLibrary(
        ipaPath: String,
        signedBaseAppPath: String,
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> InstallResult {
        let started = Date()
        guard let udid = options.deviceUDID, !udid.isEmpty else {
            throw LauncherFailure(
                code: "device_missing",
                message: "No device selected.",
                hint: "Connect the iPhone/iPad, tap Trust, and press Refresh in the device list.",
                detail: nil,
                exitCode: nil
            )
        }
        guard FileProbe.exists(ipaPath) else {
            throw LauncherFailure(
                code: "ipa_missing",
                message: "The library IPA was not found.",
                hint: "Build the library IPA first.",
                detail: ipaPath,
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

        onProgress(InstallProgress(stage: "Unpacking library IPA", fraction: 0.1, line: "unzip " + ipaPath))
        let stagedApp = try await unpackIPA(ipaPath)
        onProgress(InstallProgress(stage: "Signing GamePacks", fraction: 0.35, line: "codesign embedded Frameworks/GamePack-*.dylib (local identity)"))

        let frameworksURL = URL(fileURLWithPath: stagedApp).appendingPathComponent("Frameworks")
        let frameworkFiles = (try? FileManager.default.contentsOfDirectory(at: frameworksURL, includingPropertiesForKeys: nil)) ?? []
        let packs = frameworkFiles.filter { $0.pathExtension == "dylib" }
        guard !packs.isEmpty else {
            throw LauncherFailure(
                code: "library_ipa_no_packs",
                message: "The library IPA contains no GamePack dylib.",
                hint: "Build at least one GamePack and allocate it into the library IPA.",
                detail: frameworksURL.path,
                exitCode: nil
            )
        }
        for pack in packs {
            let sign = try await runner.run(CommandSpec(
                executable: "/usr/bin/codesign",
                arguments: ["--force", "--sign", identity, "--timestamp=none", pack.path]
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
                hint: "Check that the Team ID matches the Apple ID signing in Xcode, then retry.",
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
        onProgress(InstallProgress(stage: "Installed", fraction: 1.0, line: "Library app installed. Next: push game data."))
        return InstallResult(
            appPath: stagedApp,
            signed: true,
            installed: true,
            verifiedBundleID: options.bundleID,
            duration: Date().timeIntervalSince(started)
        )
    }

    func openLibraryIPAInImpactor(ipaPath: String, options: InstallOptions) async throws {
        guard let impactor = impactorApplicationPath() else {
            throw LauncherFailure(
                code: "impactor_missing",
                message: "The official Impactor app is not installed.",
                hint: "Download Impactor from its official release and put it in /Applications, or use the Xcode + devicectl strategy.",
                detail: nil,
                exitCode: nil
            )
        }
        try await openInImpactor(ipaPath: ipaPath, impactorPath: impactor)
    }

    private func openInImpactor(ipaPath: String, impactorPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                NSWorkspace.shared.open(
                    [URL(fileURLWithPath: ipaPath)],
                    withApplicationAt: URL(fileURLWithPath: impactorPath),
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: LauncherFailure(
                            code: "impactor_open_failed",
                            message: "Could not open Impactor with the library IPA.",
                            hint: "Open Impactor manually and choose the IPA from IPA/3ds2apple-library.ipa.",
                            detail: error.localizedDescription,
                            exitCode: nil
                        ))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func unpackIPA(_ ipaPath: String) async throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zl-library-" + UUID().uuidString)
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
                hint: "Let xcodebuild sign the shell with automatic signing first (Team ID set and Xcode account signed in).",
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

    init(readinessState: AppleReadiness) {
        self.readinessState = readinessState
    }

    func readiness(teamID: String) async -> AppleReadiness {
        var state = readinessState
        state.teamID = teamID
        return state
    }

    func devices() async throws -> [DeviceInfo] {
        MockFixtures.devices
    }

    func buildShellApp(
        signed: Bool,
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> String {
        let stages: [(String, Double, String)] = [
            ("Generate Xcode project", 0.08, "xcodegen generate --spec project.yml (mock)"),
            ("Building signed shell app", 0.3, "xcodebuild ... DEVELOPMENT_TEAM=<team> (mock)"),
        ]
        for stage in stages {
            try? await Task.sleep(nanoseconds: 120_000_000)
            onProgress(InstallProgress(stage: stage.0, fraction: stage.1, line: stage.2))
        }
        return "/Users/you/3ds2apple/build/launcher-shell/Build/Products/Debug-iphoneos/3ds2apple.app"
    }

    func installLibrary(
        ipaPath: String,
        signedBaseAppPath: String,
        options: InstallOptions,
        onProgress: @escaping (InstallProgress) -> Void
    ) async throws -> InstallResult {
        let stages: [(String, Double, String)] = [
            ("Signing GamePacks", 0.5, "codesign Frameworks/GamePack-0004000000055E00.dylib (local identity, mock)"),
            ("Signing app bundle", 0.7, "codesign the staged library app (local identity, mock)"),
            ("Installing with devicectl", 0.9, "xcrun devicectl device install app --device <mock> (mock)"),
            ("Installed", 1.0, "Library app installed (mock)."),
        ]
        for stage in stages {
            try? await Task.sleep(nanoseconds: 120_000_000)
            onProgress(InstallProgress(stage: stage.0, fraction: stage.1, line: stage.2))
        }
        return InstallResult(
            appPath: signedBaseAppPath,
            signed: true,
            installed: true,
            verifiedBundleID: options.bundleID,
            duration: 0.6
        )
    }

    func openLibraryIPAInImpactor(ipaPath: String, options: InstallOptions) async throws {
        throw LauncherFailure(
            code: "impactor_missing",
            message: "The official Impactor app is not installed (mock).",
            hint: "Use the Xcode + devicectl strategy, or install Impactor for the manual path.",
            detail: nil,
            exitCode: nil
        )
    }

    func commandPlan(options: InstallOptions) -> [String] {
        let team = options.teamID.isEmpty ? "<YOUR_TEAM_ID>" : options.teamID
        return [
            "cd ~/3ds2apple/ios/app && xcodegen generate --spec project.yml",
            "xcodebuild -project ios/app/3ds2apple.xcodeproj -scheme 3ds2apple -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/launcher-shell CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=" + team + " -allowProvisioningUpdates build",
            "3ds2apple-pack --out out pack --all --execute --base-app build/launcher-shell/Build/Products/Debug-iphoneos/3ds2apple.app --ipa-out IPA --ipa-name 3ds2apple-library",
            "codesign -f -s <Apple Development identity> <staged app>/Frameworks/GamePack-<TITLEID>.dylib",
            "xcrun devicectl device install app --device <DEVICE_UDID> <staged app>",
        ]
    }

    func impactorApplicationPath() -> String? { nil }
}
