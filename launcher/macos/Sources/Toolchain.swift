//
//  Toolchain.swift
//  3ds2apple macOS launcher
//
//  Locate the checkout and every external tool the pipeline drives, then report
//  a readiness snapshot for the Diagnostics screen. Nothing here writes file
//  content or contacts the network.
//

import Foundation

struct ToolchainPaths: Equatable {
    var repoRoot: String?
    var packCLI: String?
    var devpush: String?
    var deviceCLI: String?
    var xcodegen: String?
    var xcodebuild: String
    var security: String
    var xcrun: String

    @MainActor
    static func resolve(settings: LauncherSettings) -> ToolchainPaths {
        let repo = settings.repoRoot
        let packCLI = firstExecutable([
            settings.packCLIPath,
            repo + "/builder/target/release/3ds2apple-pack",
            repo + "/builder/target/debug/3ds2apple-pack",
        ])
        let devpush = firstExecutable([
            settings.devpushPath,
            ProcessInfo.processInfo.environment["DEVPUSH_EXE"] ?? "",
            repo + "/tools/devpush/target/release/devpush",
            repo + "/tools/devpush/target/debug/devpush",
            repo + "/builder/device/devpush",
        ])
        let deviceCLI = firstExecutable([
            settings.deviceCLIPath,
            repo + "/builder/device/device_cli.py",
        ])
        let xcodegen = firstExecutable([
            "/usr/local/bin/xcodegen",
            "/opt/homebrew/bin/xcodegen",
        ])
        return ToolchainPaths(
            repoRoot: SettingsDefaults.isRepoRoot(repo) ? repo : nil,
            packCLI: packCLI,
            devpush: devpush,
            deviceCLI: deviceCLI,
            xcodegen: xcodegen,
            xcodebuild: "/usr/bin/xcodebuild",
            security: "/usr/bin/security",
            xcrun: "/usr/bin/xcrun"
        )
    }

    private static func firstExecutable(_ candidates: [String]) -> String? {
        for candidate in candidates where !candidate.isEmpty {
            if FileProbe.isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

@MainActor
struct ToolchainProbe {
    let runner: CommandRunning
    let settings: LauncherSettings

    func probe() async -> EnvironmentReport {
        let paths = ToolchainPaths.resolve(settings: settings)
        var tools: [ToolStatus] = []
        var notes: [String] = []

        // 1. macOS host
        let version = await runTool(paths.xcodebuild, ["-version"])
        let xcodeVersion = version.combined
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("Xcode") })
            .map(String.init) ?? "unknown"
        tools.append(ToolStatus(
            name: "Xcode",
            state: version.succeeded ? .ok : .missing,
            detail: version.succeeded ? xcodeVersion : "xcodebuild not runnable",
            hint: version.succeeded ? "" : "Install Xcode from the App Store and run: sudo xcode-select -s /Applications/Xcode.app"
        ))

        // 2. devicectl (CoreDevice) for signed app installation
        let devicectl = await runTool(paths.xcrun, ["devicectl", "--version"])
        tools.append(ToolStatus(
            name: "devicectl",
            state: devicectl.succeeded ? .ok : .missing,
            detail: devicectl.succeeded
                ? (devicectl.combined.split(separator: "\n").last.map(String.init) ?? "available")
                : "not available",
            hint: devicectl.succeeded ? "" : "devicectl ships with Xcode 15+; update Xcode or install the device support package."
        ))

        // 3. Repository checkout
        if let repoRoot = paths.repoRoot {
            let scriptsOK = FileProbe.exists(repoRoot + "/scripts/build-game-pack.sh")
            tools.append(ToolStatus(
                name: "3ds2apple checkout",
                state: scriptsOK ? .ok : .missing,
                detail: repoRoot,
                hint: scriptsOK ? "" : "Set the checkout path in Settings or THREEDS2APPLE_ROOT."
            ))
        } else {
            tools.append(ToolStatus(
                name: "3ds2apple checkout",
                state: .missing,
                detail: "not found",
                hint: "Point Settings -> Checkout at a clone of the 3ds2apple repository."
            ))
        }

        // 4. Desktop pack CLI (import/build/catalogue writer)
        if let packCLI = paths.packCLI {
            tools.append(ToolStatus(
                name: "3ds2apple-pack CLI",
                state: .ok,
                detail: packCLI,
                hint: ""
            ))
        } else {
            tools.append(ToolStatus(
                name: "3ds2apple-pack CLI",
                state: .warning,
                detail: "not built",
                hint: "Run: cd builder && cargo build -p builder-pack --release (the CLI does ROM detection and package metadata)."
            ))
        }

        // 5. Shell runtime static library and app project
        if paths.repoRoot != nil {
            let staticLibrary = settings.repoRoot + "/build/ios/libzakuro_ios.a"
            let size = FileProbe.size(staticLibrary)
            tools.append(ToolStatus(
                name: "Shell runtime (arm64)",
                state: size == nil ? .missing : .ok,
                detail: size.map { FileProbe.formatBytes($0) + " libzakuro_ios.a" } ?? "build/ios/libzakuro_ios.a missing",
                hint: size == nil ? "Build it once with scripts/build-zakuro-ios.sh (needs the Rust iOS target)." : ""
            ))
            let project = settings.repoRoot + "/ios/app/project.yml"
            tools.append(ToolStatus(
                name: "Shell app project",
                state: FileProbe.exists(project) ? .ok : .missing,
                detail: project,
                hint: FileProbe.exists(project) ? "" : "The checkout looks incomplete; re-clone the repository."
            ))
        }

        // 6. xcodegen (generates the shell/launcher Xcode project)
        tools.append(ToolStatus(
            name: "xcodegen",
            state: paths.xcodegen == nil ? .warning : .ok,
            detail: paths.xcodegen ?? "not found",
            hint: paths.xcodegen == nil ? "brew install xcodegen (used to generate the shell Xcode project on demand)." : ""
        ))

        // 7. Device bridge (tools/devpush) - optional until the task publishes it
        if let devpush = paths.devpush {
            tools.append(ToolStatus(
                name: "device bridge (devpush)",
                state: .ok,
                detail: devpush,
                hint: ""
            ))
        } else {
            tools.append(ToolStatus(
                name: "device bridge (devpush)",
                state: .warning,
                detail: "not built yet",
                hint: "Push-to-device needs tools/devpush (device-bridge task). Mock/dry-run mode works without it."
            ))
        }

        // 8. App signing assets (counts only: never log certificate names or IDs)
        let identities = await countSigningIdentities(paths)
        let profiles = countProvisioningProfiles()
        let apple = AppleReadiness(
            xcodePath: (await runTool(paths.xcrun, ["--find", "devicectl"])).succeeded ? "/usr/bin/xcrun" : "",
            xcodeVersion: xcodeVersion,
            devicectlAvailable: devicectl.succeeded,
            signingIdentityCount: identities,
            provisioningProfileCount: profiles,
            teamID: settings.teamID,
            checkedAt: Date()
        )
        if !apple.hasSigningAssets {
            notes.append("No Apple ID signing assets: sign in to Xcode -> Settings -> Accounts on this Mac before installing the shell.")
        }
        if paths.packCLI == nil {
            notes.append("Desktop pack CLI missing: import/build actions need the Rust CLI built once.")
        }
        if paths.devpush == nil {
            notes.append("Device bridge missing: pushes are simulated until tools/devpush is available.")
        }

        var capabilities: BridgeCapabilities?
        if let devpush = paths.devpush {
            capabilities = try? await DevpushCLI(binary: devpush, mockDirectory: nil).capabilities()
        }
        return EnvironmentReport(
            generatedAt: Date(),
            repoRoot: paths.repoRoot,
            outDir: settings.outRootURL.path,
            tools: tools,
            apple: apple,
            devpushCapabilities: capabilities,
            notes: notes
        )
    }

    private func runTool(_ executable: String, _ arguments: [String]) async -> CommandResult {
        let spec = CommandSpec(executable: executable, arguments: arguments)
        do {
            return try await runner.run(spec, onLine: nil)
        } catch {
            return CommandResult(command: spec, exitCode: -1, stdout: "", stderr: error.localizedDescription, duration: 0)
        }
    }

    private func countSigningIdentities(_ paths: ToolchainPaths) async -> Int {
        let result = await runTool(paths.security, ["find-identity", "-v", "-p", "codesigning"])
        guard result.succeeded else { return 0 }
        let pattern = "([0-9]+) valid identities found"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let text = result.combined
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return 0 }
        return Int(text[captured]) ?? 0
    }

    private func countProvisioningProfiles() -> Int {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        return contents.filter { $0.pathExtension == "mobileprovision" }.count
    }
}
