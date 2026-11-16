//
//  Toolchain.swift
//  3ds2apple macOS launcher
//
//  Locate the checkout and every external tool the pipeline drives, then report
//  a readiness snapshot for Settings and the Deploy preflight. The v2 flow has
//  no tool-path controls: the launcher looks inside its own bundle first, then
//  the checkout, then PATH (launcher/macos/README.md). Nothing here writes file
//  content or contacts the network.
//

import Foundation

struct ToolchainPaths: Equatable {
    var repoRoot: String?
    var packCLI: String?
    var devpush: String?
    var xcodegen: String?
    var xcodebuild: String
    var security: String
    var xcrun: String

    @MainActor
    static func resolve(settings: LauncherSettings) -> ToolchainPaths {
        let repo = settings.repoRoot
        var packCandidates: [String] = []
        var devpushCandidates: [String] = []
        if let resourceTools = Bundle.main.resourceURL?.appendingPathComponent("tools", isDirectory: true).path {
            packCandidates.append(resourceTools + "/3ds2apple-pack")
            devpushCandidates.append(resourceTools + "/devpush")
        }
        packCandidates.append(contentsOf: [
            repo + "/builder/target/release/3ds2apple-pack",
            repo + "/builder/target/debug/3ds2apple-pack",
        ])
        devpushCandidates.append(contentsOf: [
            repo + "/tools/devpush/target/release/devpush",
            repo + "/tools/devpush/target/debug/devpush",
        ])
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["THREEDS2APPLE_PACK"], !explicit.isEmpty {
            packCandidates.insert(explicit, at: 0)
        }
        if let explicit = environment["DEVPUSH_EXE"], !explicit.isEmpty {
            devpushCandidates.insert(explicit, at: 0)
        }
        packCandidates.append(contentsOf: pathCandidates(named: "3ds2apple-pack"))
        devpushCandidates.append(contentsOf: pathCandidates(named: "devpush"))
        return ToolchainPaths(
            repoRoot: SettingsDefaults.isRepoRoot(repo) ? repo : nil,
            packCLI: firstExecutable(packCandidates),
            devpush: firstExecutable(devpushCandidates),
            xcodegen: firstExecutable(["/usr/local/bin/xcodegen", "/opt/homebrew/bin/xcodegen", "/usr/bin/xcodegen"]),
            xcodebuild: "/usr/bin/xcodebuild",
            security: "/usr/bin/security",
            xcrun: "/usr/bin/xcrun"
        )
    }

    /// Candidates found on PATH, so a user who installed the tools with cargo or
    /// a package manager does not need any Settings override.
    static func pathCandidates(named name: String) -> [String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map { directory in
            String(directory) + "/" + name
        }
    }

    private static func firstExecutable(_ candidates: [String]) -> String? {
        for candidate in candidates where !candidate.isEmpty {
            if FileProbe.isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

/// Read the Apple Developer Team ID from the local Xcode state so Settings and
/// the Deploy preflight never ask the user to type it. The Team ID is not a
/// secret (it is in every provisioning profile) but certificate names and
/// identity hashes are never logged.
enum TeamDetector {
    static func detect(runner: CommandRunning) async -> [String] {
        var teams: Set<String> = []
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
        let profiles = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mobileprovision" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(12)
        for profile in profiles {
            guard let result = try? await runner.run(CommandSpec(
                executable: "/usr/bin/security",
                arguments: ["cms", "-D", "-i", profile.path]
            ), onLine: nil), result.succeeded else { continue }
            if let team = firstTeamID(inPlistText: result.stdout) {
                teams.insert(team)
            }
        }
        if teams.isEmpty,
           let result = try? await runner.run(CommandSpec(
               executable: "/usr/bin/security",
               arguments: ["find-identity", "-v", "-p", "codesigning"]
           ), onLine: nil) {
            teams.formUnion(certificateTeamIDs(in: result.combined))
        }
        return teams.sorted()
    }

    /// Find the first TeamIdentifier in a decoded provisioning plist.
    static func firstTeamID(inPlistText text: String) -> String? {
        let pattern = "<key>TeamIdentifier</key>[\\s\\S]*?<string>([A-Z0-9]{6,12})</string>"
        return firstMatch(pattern: pattern, in: text)
    }

    /// Xcode identity lines end with "(TEAMID)" for Apple Development certs.
    static func certificateTeamIDs(in text: String) -> [String] {
        let pattern = "\\(([A-Z0-9]{10})\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
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
            let scriptsOK = FileProbe.exists(repoRoot + "/ios/app/project.yml")
            tools.append(ToolStatus(
                name: "3ds2apple checkout",
                state: scriptsOK ? .ok : .missing,
                detail: repoRoot,
                hint: scriptsOK ? "" : "Put a clone of the 3ds2apple repository at ~/3ds2apple or set THREEDS2APPLE_ROOT (developer environment variable, not a UI setting)."
            ))
        } else {
            tools.append(ToolStatus(
                name: "3ds2apple checkout",
                state: .missing,
                detail: "not found",
                hint: "Put a clone of the 3ds2apple repository at ~/3ds2apple or set THREEDS2APPLE_ROOT."
            ))
        }

        // 4. Desktop pack CLI (import/build/catalogue writer)
        if let packCLI = paths.packCLI {
            tools.append(ToolStatus(name: "3ds2apple-pack CLI", state: .ok, detail: packCLI, hint: ""))
        } else {
            tools.append(ToolStatus(
                name: "3ds2apple-pack CLI",
                state: .warning,
                detail: "not found (auto-detected)",
                hint: "Build it once: cd builder && cargo build -p builder-pack --release. The Deploy flow needs it to compile packs and compose the GameCatalog."
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

        // 6. xcodegen (generates the shell Xcode project)
        tools.append(ToolStatus(
            name: "xcodegen",
            state: paths.xcodegen == nil ? .warning : .ok,
            detail: paths.xcodegen ?? "not found",
            hint: paths.xcodegen == nil ? "brew install xcodegen (used to generate the shell Xcode project on demand)." : ""
        ))

        // 7. Device bridge (tools/devpush)
        if let devpush = paths.devpush {
            tools.append(ToolStatus(name: "device bridge (devpush)", state: .ok, detail: devpush, hint: ""))
        } else {
            tools.append(ToolStatus(
                name: "device bridge (devpush)",
                state: .warning,
                detail: "not found (auto-detected)",
                hint: "Build tools/devpush with cargo build --release; the Deploy flow pushes the ROM data with it."
            ))
        }

        // 8. App signing assets (counts + detected Team ID only; never log
        // certificate names, identities, passwords or UDIDs)
        let identities = await countSigningIdentities(paths)
        let profiles = countProvisioningProfiles()
        let teamIDs = await TeamDetector.detect(runner: runner)
        let apple = AppleReadiness(
            xcodePath: (await runTool(paths.xcrun, ["--find", "devicectl"])).succeeded ? "/usr/bin/xcrun" : "",
            xcodeVersion: xcodeVersion,
            devicectlAvailable: devicectl.succeeded,
            signingIdentityCount: identities,
            provisioningProfileCount: profiles,
            teamID: teamIDs.first ?? "",
            checkedAt: Date()
        )
        if !apple.hasSigningAssets {
            notes.append("No Apple ID signing assets: sign in to Xcode -> Settings -> Accounts on this Mac before deploying.")
        } else if apple.teamID.isEmpty {
            notes.append("Signing assets found, but no Team ID could be read from the provisioning profiles. Open Xcode -> Settings -> Accounts once to create one.")
        }
        if paths.packCLI == nil {
            notes.append("Desktop pack CLI missing: the Deploy flow cannot compile packs or compose the GameCatalog.")
        }
        if paths.devpush == nil {
            notes.append("Device bridge missing: the Deploy flow cannot push the ROM data.")
        }

        var capabilities: BridgeCapabilities?
        if let devpush = paths.devpush {
            capabilities = try? await DevpushCLI(binary: devpush, mockDirectory: nil).capabilities()
        }
        return EnvironmentReport(
            generatedAt: Date(),
            repoRoot: paths.repoRoot,
            outDir: settings.outRootURL.path,
            dataRoot: settings.dataRootPath,
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
