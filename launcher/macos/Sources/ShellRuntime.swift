//
//  ShellRuntime.swift
//  3ds2apple macOS launcher
//
//  The iOS shell built by the launcher must ship Frameworks/MoltenVK.framework:
//  Zakuro's Vulkan renderer dlopen()s the embedded framework at run time to
//  create the presented CAMetalLayer (hardware PICA200 path + the system Metal
//  HUD). A shell without it falls back to the software renderer: low fps and no
//  Metal layer for the HUD (task-32 root cause; the old launcher-built shell
//  never copied the framework, so device deploys stayed on the CPU path).
//
//  This helper copies the verified framework into the shell .app BEFORE it is
//  signed or composed into the library IPA; the deploy flow refuses to
//  sign/install a shell that is not Metal/HUD ready.
//
//  Sources, in priority order:
//    1. <launcher>.app/Contents/Resources/MoltenVK.framework - embedded at
//       packaging time by scripts/vm-build.sh from the pinned template, so the
//       user-facing launcher is self-contained;
//    2. <checkout>/build/third_party/MoltenVK.framework (the task-32 build
//       input; also the xcframework path from scripts/README.md);
//    3. <checkout>/out/shell/3ds2apple-shell.ipa - the pinned ROM-free shell
//       template (0.1.6-beta2 build 1); Payload/*.app/Frameworks/MoltenVK.framework is
//       extracted read-only to a system temporary directory.
//
//  The binary is pinned to MoltenVK 1.4.2 ios-arm64 (the one shipped in
//  out/shell/3ds2apple-shell.ipa 0.1.6-beta2 build 1): 4,822,128 bytes, SHA-256
//  6cd58884... and a Mach-O arm64 dynamic library. The shell template itself is
//  pinned by size+SHA-256 too. Anything else is refused, so a deploy can never
//  silently end up on the software renderer.
//

import Foundation
import CryptoKit

enum ShellRuntime {
    // MARK: - Pinned verified runtime

    static let frameworksRelativePath = "Frameworks/MoltenVK.framework"
    static let frameworkName = "MoltenVK.framework"
    static let frameworkBinaryName = "MoltenVK"
    /// Frameworks/MoltenVK.framework/MoltenVK relative to the .app root.
    static let binaryRelativePath = frameworksRelativePath + "/" + frameworkBinaryName

    /// MoltenVK 1.4.2 ios-arm64 dynamic framework from the task-32 template.
    static let expectedBytes: Int64 = 4_822_128
    static let expectedSHA256 = "6cd5888490d08b36356d04c50c05e2eda5b9bcb3d0338ece693a28987de96aff"

    /// Pinned ROM-free shell template that carries the verified framework
    /// (shell 0.1.6-beta2 build 1, Metal HUD + Documents file sharing enabled).
    static let pinnedTemplateRelativePath = "out/shell/3ds2apple-shell.ipa"
    /// Rebuilt 0.1.6-beta2 build 1 ROM-free shell IPA from current main (0.1.6-beta2
    /// local pre-release; the shell's CFBundleShortVersionString is the numeric 0.1.6-beta2).
    static let pinnedTemplateBytes: Int64 = 6_262_989
    static let pinnedTemplateSHA256 = "051b07a8320e0dce0537a6940abd728cef71c652c7b255f69697444ed8506bd1"
    /// The rebuilt shell identity the launcher is built against. The pinned
    /// template must report exactly these values; another shell build is refused.
    static let expectedShellVersion = "0.1.6"
    static let expectedShellBuild = "1"

    /// Info.plist keys the shell must keep: the Metal HUD build flag and the
    /// Documents/Games file sharing the launcher pushes game data into.
    static let requiredInfoPlistFlags: [(key: String, reason: String)] = [
        ("MetalHudEnabled", "the system Metal HUD"),
        ("UIFileSharingEnabled", "Documents/Games file sharing"),
        ("LSSupportsOpeningDocumentsInPlace", "Files app visibility of Documents/"),
    ]

    // MARK: - Source

    struct Source {
        enum Origin: String {
            case launcherBundle = "launcher-embedded"
            case checkoutThirdParty = "checkout-build-third-party"
            case pinnedTemplate = "pinned-shell-template"
        }

        var origin: Origin
        /// For the two checkout/bundle sources this is a MoltenVK.framework
        /// directory; for the pinned template it is the extracted framework.
        var directory: String
        var detail: String
        /// Temporary extraction root, set only for the pinned template.
        var temporaryRoot: String?

        func cleanUp() {
            guard let temporaryRoot else { return }
            try? FileManager.default.removeItem(atPath: temporaryRoot)
        }
    }

    enum RuntimeError: LocalizedError {
        case noVerifiedSource([String])
        case extractionFailed(String)
        case copyFailed(String)
        case invalidInstalled([String])

        var errorDescription: String? {
            switch self {
            case .noVerifiedSource(let problems):
                return "No verified MoltenVK.framework source was found. " + problems.joined(separator: "; ")
            case .extractionFailed(let message):
                return "Could not extract MoltenVK.framework from the pinned shell template: " + message
            case .copyFailed(let message):
                return "Could not embed Frameworks/MoltenVK.framework into the shell app: " + message
            case .invalidInstalled(let problems):
                return "The embedded MoltenVK.framework failed verification: " + problems.joined(separator: "; ")
            }
        }
    }

    // MARK: - Paths / probes

    static func frameworksPath(inShellAppAt appPath: String) -> String {
        appPath + "/Frameworks"
    }

    static func frameworkDirectory(inShellAppAt appPath: String) -> String {
        appPath + "/" + frameworksRelativePath
    }

    /// Cheap presence check used by the IPA inspection (the deep byte check is
    /// done by verifyShellApp during build/install).
    static func hasFramework(inShellAppAt appPath: String) -> Bool {
        FileManager.default.fileExists(atPath: appPath + "/" + binaryRelativePath)
    }

    static func fileBytes(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.int64Value
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Verified framework checks

    /// Every reason a MoltenVK.framework directory is not the pinned, verified
    /// arm64 dynamic framework. Empty means it is safe to embed.
    static func problemsWithFramework(at directory: String) -> [String] {
        var problems: [String] = []
        let binary = directory + "/" + frameworkBinaryName
        guard FileManager.default.fileExists(atPath: binary) else {
            return ["the framework has no " + frameworkBinaryName + " binary"]
        }
        if let bytes = fileBytes(binary) {
            if bytes != expectedBytes {
                problems.append("expected \(expectedBytes) bytes, found \(bytes)")
            }
        } else {
            problems.append("could not read the framework binary")
        }
        guard let data = FileManager.default.contents(atPath: binary) else {
            problems.append("could not read the framework binary")
            return problems
        }
        if data.count < 16 {
            problems.append("the framework binary is too small to be Mach-O")
        } else {
            let magic = data.uint32LE(at: 0)
            let cpuType = data.int32LE(at: 4)
            let fileType = data.uint32LE(at: 12)
            if magic != 0xFEEDFACF {
                problems.append("not a 64-bit Mach-O (magic " + String(format: "0x%08x", magic) + ")")
            }
            if cpuType != 0x0100000C {
                problems.append("not an arm64 Mach-O (cputype " + String(format: "0x%08x", UInt32(bitPattern: cpuType)) + ")")
            }
            if fileType != 6 {
                problems.append("not a dynamic library (Mach-O filetype \(fileType))")
            }
        }
        let digest = sha256Hex(data)
        if digest != expectedSHA256 {
            problems.append("SHA-256 " + digest + " is not the pinned verified MoltenVK 1.4.2 binary")
        }
        return problems
    }

    /// Info.plist keys the shell must keep. Empty means the file-sharing and
    /// Metal HUD configuration survived the build.
    static func infoPlistProblems(inShellAppAt appPath: String) -> [String] {
        let plistPath = appPath + "/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath) else {
            return ["Info.plist is missing"]
        }
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let object = root as? [String: Any] else {
            return ["Info.plist is not a readable dictionary"]
        }
        var problems: [String] = []
        for flag in requiredInfoPlistFlags where (object[flag.key] as? Bool) != true {
            problems.append("Info.plist " + flag.key + " must stay true (" + flag.reason + ")")
        }
        if let bundleID = object["CFBundleIdentifier"] as? String, !bundleID.isEmpty {
            // fine: the launch/install flow reads it back
        } else {
            problems.append("Info.plist has no CFBundleIdentifier")
        }
        return problems
    }

    /// The pinned shell's advertised product version/build (0.1.6-beta2 build 1 since
    /// the product-version reset). Empty means the shell is the identity this
    /// launcher pins; anything else means a mismatched template/build.
    static func shellIdentityProblems(inShellAppAt appPath: String) -> [String] {
        let plistPath = appPath + "/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let object = root as? [String: Any] else {
            return ["Info.plist is missing or unreadable for the pinned shell identity"]
        }
        var problems: [String] = []
        let version = object["CFBundleShortVersionString"] as? String ?? ""
        let buildValue = object["CFBundleVersion"]
        let build: String
        if let text = buildValue as? String {
            build = text
        } else if let number = buildValue as? NSNumber {
            build = number.stringValue
        } else {
            build = ""
        }
        if version != expectedShellVersion {
            problems.append("expected shell version " + expectedShellVersion + ", found " + (version.isEmpty ? "missing" : version))
        }
        if build != expectedShellBuild {
            problems.append("expected shell build " + expectedShellBuild + ", found " + (build.isEmpty ? "missing" : build))
        }
        return problems
    }

    /// The full rule for a shell .app the launcher may sign/install: it must
    /// carry the pinned Frameworks/MoltenVK.framework AND keep the Metal HUD +
    /// file-sharing Info.plist keys. Empty means Metal/HUD ready.
    static func verifyShellApp(at appPath: String) -> [String] {
        if !FileManager.default.fileExists(atPath: appPath) {
            return ["the shell .app does not exist at " + appPath]
        }
        var problems: [String] = []
        let framework = frameworkDirectory(inShellAppAt: appPath)
        if !FileManager.default.fileExists(atPath: framework) {
            problems.append("Frameworks/MoltenVK.framework is missing (the shell would fall back to the software renderer: no CAMetalLayer/Metal HUD)")
        } else {
            problems.append(contentsOf: problemsWithFramework(at: framework))
        }
        problems.append(contentsOf: infoPlistProblems(inShellAppAt: appPath))
        return problems
    }

    // MARK: - Resolve a verified source

    static func candidateSources(repoRoot: String, bundle: Bundle = .main) -> [Source] {
        var sources: [Source] = []
        if let resources = bundle.resourceURL?.path {
            let embedded = resources + "/" + frameworkName
            if FileManager.default.fileExists(atPath: embedded) {
                sources.append(Source(
                    origin: .launcherBundle,
                    directory: embedded,
                    detail: "launcher bundle Contents/Resources/" + frameworkName
                ))
            }
        }
        let checkoutCandidates = [
            repoRoot + "/build/third_party/MoltenVK.framework",
            repoRoot + "/build/third_party/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework",
        ]
        for candidate in checkoutCandidates where FileManager.default.fileExists(atPath: candidate) {
            sources.append(Source(origin: .checkoutThirdParty, directory: candidate, detail: candidate))
        }
        let template = repoRoot + "/" + pinnedTemplateRelativePath
        if FileManager.default.fileExists(atPath: template) {
            sources.append(Source(
                origin: .pinnedTemplate,
                directory: template,
                detail: "pinned ROM-free shell template " + template
            ))
        }
        return sources
    }

    /// Resolve a hash-pinned MoltenVK.framework, extracting the pinned shell
    /// template when that is the only verified source left. Callers must call
    /// cleanUp() on the result when done.
    static func resolveFramework(repoRoot: String, bundle: Bundle = .main) throws -> Source {
        var problems: [String] = []
        for candidate in candidateSources(repoRoot: repoRoot, bundle: bundle) {
            if candidate.origin == .pinnedTemplate {
                do {
                    let extraction = try extractFrameworkFromPinnedTemplate(ipaPath: candidate.directory)
                    var issues = problemsWithFramework(at: extraction.frameworkPath)
                    issues.append(contentsOf: infoPlistProblems(inShellAppAt: extraction.appPath))
                    issues.append(contentsOf: shellIdentityProblems(inShellAppAt: extraction.appPath))
                    if issues.isEmpty {
                        return Source(
                            origin: .pinnedTemplate,
                            directory: extraction.frameworkPath,
                            detail: "extracted from " + candidate.directory,
                            temporaryRoot: extraction.temporaryRoot
                        )
                    }
                    try? FileManager.default.removeItem(atPath: extraction.temporaryRoot)
                    problems.append("pinned-shell-template: " + issues.joined(separator: "; "))
                } catch {
                    problems.append("pinned-shell-template: " + error.localizedDescription)
                }
                continue
            }
            let issues = problemsWithFramework(at: candidate.directory)
            if issues.isEmpty {
                return candidate
            }
            problems.append(candidate.origin.rawValue + " (" + candidate.detail + "): " + issues.joined(separator: "; "))
        }
        throw RuntimeError.noVerifiedSource(problems.isEmpty ? ["no MoltenVK.framework candidate exists for this checkout"] : problems)
    }

    /// Validate the pinned shell template itself (IPA bytes + the embedded
    /// framework + the shell Info.plist + the 0.1.6-beta2 build 1 identity). Used by
    /// the self-check; empty is good.
    static func inspectPinnedTemplate(at ipaPath: String) -> [String] {
        do {
            let extraction = try extractFrameworkFromPinnedTemplate(ipaPath: ipaPath)
            defer { try? FileManager.default.removeItem(atPath: extraction.temporaryRoot) }
            var issues = problemsWithFramework(at: extraction.frameworkPath)
            issues.append(contentsOf: infoPlistProblems(inShellAppAt: extraction.appPath))
            issues.append(contentsOf: shellIdentityProblems(inShellAppAt: extraction.appPath))
            return issues
        } catch {
            return [error.localizedDescription]
        }
    }

    // MARK: - Copy into the built shell

    /// Copy the resolved framework into <app>/Frameworks/MoltenVK.framework and
    /// re-validate the installed copy. Callers sign the nested framework (and
    /// the app) afterwards.
    static func copyFramework(from source: Source, intoShellAppAt appPath: String) throws {
        let manager = FileManager.default
        let frameworks = frameworksPath(inShellAppAt: appPath)
        let destination = frameworkDirectory(inShellAppAt: appPath)
        do {
            try manager.createDirectory(atPath: frameworks, withIntermediateDirectories: true)
        } catch {
            throw RuntimeError.copyFailed("could not create " + frameworks + ": " + error.localizedDescription)
        }
        if manager.fileExists(atPath: destination) {
            try? manager.removeItem(atPath: destination)
        }
        do {
            try manager.copyItem(atPath: source.directory, toPath: destination)
        } catch {
            throw RuntimeError.copyFailed("copy " + source.detail + " -> " + destination + ": " + error.localizedDescription)
        }
        let issues = problemsWithFramework(at: destination)
        guard issues.isEmpty else {
            throw RuntimeError.invalidInstalled(issues)
        }
    }

    // MARK: - Pinned template extraction (read-only)

    private struct TemplateExtraction {
        var frameworkPath: String
        var appPath: String
        var temporaryRoot: String
    }

    private static func extractFrameworkFromPinnedTemplate(ipaPath: String) throws -> TemplateExtraction {
        var pinProblems: [String] = []
        if let bytes = fileBytes(ipaPath) {
            if bytes != pinnedTemplateBytes {
                pinProblems.append("expected \(pinnedTemplateBytes) bytes, found \(bytes)")
            }
        } else {
            pinProblems.append("could not read " + ipaPath)
        }
        guard let data = FileManager.default.contents(atPath: ipaPath) else {
            throw RuntimeError.extractionFailed(pinProblems.joined(separator: "; "))
        }
        let digest = sha256Hex(data)
        if digest != pinnedTemplateSHA256 {
            pinProblems.append("SHA-256 " + digest + " does not match the pinned ROM-free shell template")
        }
        guard pinProblems.isEmpty else {
            throw RuntimeError.extractionFailed(pinProblems.joined(separator: "; "))
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zl-moltenvk-" + UUID().uuidString)
            .path
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            throw RuntimeError.extractionFailed("could not create " + root + ": " + error.localizedDescription)
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", ipaPath, "-d", root]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = pipe
        do {
            try unzip.run()
        } catch {
            try? FileManager.default.removeItem(atPath: root)
            throw RuntimeError.extractionFailed("unzip could not run: " + error.localizedDescription)
        }
        unzip.waitUntilExit()
        if unzip.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? FileManager.default.removeItem(atPath: root)
            throw RuntimeError.extractionFailed("unzip exited \(unzip.terminationStatus): " + String(output.suffix(400)))
        }

        let payload = root + "/Payload"
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: payload)) ?? [])
            .filter { $0.hasSuffix(".app") }
            .sorted()
        guard let appName = apps.first else {
            try? FileManager.default.removeItem(atPath: root)
            throw RuntimeError.extractionFailed("the template has no Payload/*.app")
        }
        let appPath = payload + "/" + appName
        let frameworkPath = appPath + "/" + frameworksRelativePath
        guard FileManager.default.fileExists(atPath: frameworkPath + "/" + frameworkBinaryName) else {
            try? FileManager.default.removeItem(atPath: root)
            throw RuntimeError.extractionFailed("the template app has no " + frameworksRelativePath)
        }
        return TemplateExtraction(frameworkPath: frameworkPath, appPath: appPath, temporaryRoot: root)
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }.littleEndian
    }

    func int32LE(at offset: Int) -> Int32 {
        Int32(bitPattern: uint32LE(at: offset))
    }
}
