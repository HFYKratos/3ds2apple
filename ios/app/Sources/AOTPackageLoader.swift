//
//  AOTPackageLoader.swift
//  3ds2apple
//
//  Resolves the AOT code of a catalog game and loads the per-game AOT package
//  dylib when the build carries one.
//
//  Two ways a build can contain AOT code for a game:
//
//  1. STATIC LINK (today's single-game IPA). The game's recompiled code is
//     linked into the main binary; zk_linked_code() is 1 and
//     zk_linked_program_id() names the title. The shell loads nothing here: this
//     is the compatibility fallback for every 0.1.x build.
//
//  2. GAME PACKAGE (the AOT-first build). The desktop build writes one dylib per
//     game into the app bundle and lists it as "packFile" in GameCatalog.json.
//     The shell resolves that path inside the bundle, dlopen()s it and, when the
//     pack exports the registration symbol, lets it register with the runtime.
//
//  The shell never launches a game without AOT code. Every failure returns an
//  AOTUnavailableReason the UI shows as "No AOT build for this game".
//
//  GamePack C ABI v1 (the pack's side; built by the desktop AOT pipeline):
//
//      #include <stdint.h>
//
//      /* Title this pack was built for (0x0004000000055E00). Optional: when
//         exported, the shell compares it with the catalog entry and refuses a
//         pack built for another game. */
//      uint64_t zk_gamepack_title_id — returns the pack's title ID; no arguments.
//
//      /* ABI version the pack implements. Optional: when exported it must be
//         ZK_GAMEPACK_ABI_VERSION (1); the shell refuses a mismatch. */
//      uint32_t zk_gamepack_abi_version — returns the pack's ABI version; no arguments.
//
//      /* Registration hook. Optional. Called once, on the main thread, right
//         after a successful dlopen with the host's ABI version. Return 0 when
//         the pack accepted the host; a non-zero result unloads the pack and
//         reports the game as unavailable. The catalog entry can point the
//         loader at a differently named symbol with "registrationSymbol". */
//      int32_t zk_gamepack_register — one uint32_t argument (host_abi_version).
//
//  The registration hook is where a pack hands its AOT code image to the
//  runtime. That image hand-off is runtime work (ios/zakuro-ios): this shell
//  version loads and validates packs, and starts the statically linked game.
//  See docs/aot-first.md ("GamePack dylib 契约") for the current status.
//

import Darwin
import Foundation

/// Where the AOT code of a catalog game comes from.
enum AOTCodeSource: Equatable {
    /// Compiled into the app binary (today's single-game linked build).
    case staticLinked
    /// A per-game dylib at this bundle-relative path, not loaded yet.
    case bundlePackage(String)
}

/// Why a catalog game cannot be started by this build.
enum AOTUnavailableReason: Equatable {
    /// The catalog says the desktop build did not allocate AOT code.
    case noAOTAllocated
    /// The catalog lists a packFile that is not in the app bundle.
    case packageMissing(String)
    /// dlopen()/registration/title/ABI validation failed; detail is technical.
    case packageInvalid(String)
    /// The linked AOT code belongs to another title.
    case linkedTitleMismatch(expected: String, linked: String)
    /// The catalog expects static AOT code but the binary has none.
    case noLinkedCode

    /// One localized sentence for the "No AOT build for this game" notice.
    var localizedMessage: String {
        switch self {
        case .noAOTAllocated:
            return L10n.tr("The desktop build did not allocate AOT code for this game. Build it on your computer and install that build.")
        case .packageMissing(let path):
            return L10n.format("The game package “%@” is missing from this app. Repackage the app on your computer and reinstall it.", path)
        case .packageInvalid(let detail):
            return L10n.format("The game package could not be loaded: %@", detail)
        case .linkedTitleMismatch(let expected, let linked):
            return L10n.format("The AOT code linked into this app is for title %@, not %@. Rebuild the app for this game.", linked, expected)
        case .noLinkedCode:
            return L10n.tr("This app contains no linked AOT code. Build the game on your computer and install that build.")
        }
    }
}

/// The result of asking the loader about a catalog game.
enum AOTResolution {
    /// The build has statically linked AOT code for the title.
    case staticLinked
    /// The pack was loaded (and registered when it exports the hook).
    case package(AOTPackage)
    /// The game cannot run: the UI reports it as "No AOT build for this game".
    case unavailable(AOTUnavailableReason)
}

/// A loaded GamePack dylib. The pack registration hook is required: a pack
/// without it cannot hand its AOT code to the runtime, so it is refused before
/// it is cached (see `loadPackage`).
struct AOTPackage {
    let titleID: String
    /// Catalog "packFile": path relative to the app bundle.
    let bundleRelativePath: String
    /// Absolute on-disk location of the loaded dylib.
    let url: URL
    /// dlopen() handle; never closed for a pack that registered successfully.
    let handle: UnsafeMutableRawPointer
    /// Registration symbol the pack exported and accepted, nil when it exports
    /// none (a pack without a hook is still a valid AOT package).
    let registrationSymbol: String?
}

/// Whether this build can start a catalog game, and from where.
enum AOTAvailability: Equatable {
    case available(AOTCodeSource)
    case unavailable(AOTUnavailableReason)

    /// Whether this build can start the game (green AOT badge on the home page).
    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// Resolves catalog games to runnable AOT code (see the file header for the
/// GamePack C ABI).
final class AOTPackageLoader {
    static let shared = AOTPackageLoader()
    static let hostABIVersion: UInt32 = 1
    static let defaultRegistrationSymbol = "zk_gamepack_register"
    static let titleIDSymbol = "zk_gamepack_title_id"
    static let abiVersionSymbol = "zk_gamepack_abi_version"

    /// UI preview only (ios/preview/SnapshotRenderer.swift): title IDs treated
    /// as statically linked. The shipping app never sets it.
    var previewStaticTitleIDs: Set<String> = []

    private var packages: [String: AOTPackage] = [:]
    private let lock = NSLock()
    private init() {}

    // MARK: - Queries
    /// Cheap check for the home-page badge and launch gating: no dlopen, only
    /// the catalog flag, the static-link probe and a file check.
    ///
    /// "Available" here means the build **allocated** AOT code for the title and
    /// the pack/ROM files are present; it is not a promise that the pack will
    /// load and register. `resolve(for:)` does that work and can still refuse a
    /// corrupt, wrong-title or wrong-ABI pack.
    func availability(for game: GameEntry) -> AOTAvailability {
        guard game.aot else { return .unavailable(.noAOTAllocated) }
        if let packFile = game.packFile, !packFile.isEmpty {
            guard let url = Self.bundleURL(forBundleRelativePath: packFile),
                  FileManager.default.fileExists(atPath: url.path) else {
                return .unavailable(.packageMissing(packFile))
            }
            if let catalogABI = game.packABIVersion, catalogABI != Int(Self.hostABIVersion) {
                return .unavailable(.packageInvalid(
                    L10n.format(
                        "the catalog says the pack uses ABI version %ld, this app speaks %ld",
                        catalogABI,
                        Self.hostABIVersion
                    )
                ))
            }
            return .available(.bundlePackage(packFile))
        }
        let linked = staticallyLinkedTitleIDs()
        if linked.contains(game.titleID) { return .available(.staticLinked) }
        if let other = linked.first {
            return .unavailable(.linkedTitleMismatch(expected: game.titleID, linked: other))
        }
        return .unavailable(.noLinkedCode)
    }

    /// Whether this build can start the game (green AOT badge).
    func isAOTAvailable(_ game: GameEntry) -> Bool {
        if case .unavailable = availability(for: game) { return false }
        return true
    }

    /// Full resolution: loads, validates and registers the game package when the
    /// catalog lists one. Safe to call more than once; a loaded pack is cached,
    /// but its registration hook is re-run when the runtime's registration slot
    /// names another title (launching A -> B -> A must run A's AOT tables).
    func resolve(for game: GameEntry) -> AOTResolution {
        switch availability(for: game) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(.staticLinked):
            return .staticLinked
        case .available(.bundlePackage(let packFile)):
            guard let url = Self.bundleURL(forBundleRelativePath: packFile) else {
                return .unavailable(.packageMissing(packFile))
            }
            return loadPackage(for: game, relativePath: packFile, url: url)
        }
    }

    /// Packages loaded during this app run, for diagnostics.
    var loadedPackages: [AOTPackage] {
        lock.lock()
        defer { lock.unlock() }
        return packages.values.sorted { $0.titleID < $1.titleID }
    }

    // MARK: - Paths
    /// Whether a catalog "packFile" is a safe bundle-relative path: not
    /// absolute, no "..", no empty components.
    static func isValidBundleRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }

    /// Absolute URL of a bundle-relative path, or nil when the path escapes the
    /// app bundle (a catalog from the desktop build is still untrusted input).
    static func bundleURL(forBundleRelativePath path: String,
                          bundle: Bundle = .main) -> URL? {
        guard isValidBundleRelativePath(path) else { return nil }
        let base = bundle.bundleURL.standardizedFileURL
        let url = base.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { return nil }
        return url
    }

    /// Absolute URL of a catalog game's bundled game data (the packaged ROM).
    ///
    /// `romFile` comes from GameCatalog.json like `packFile`, so it is untrusted
    /// input and goes through the same bundle-relative check: a path from the
    /// catalog can never escape the app bundle. Returns nil when the catalog has
    /// no romFile, the path is unsafe, or the file is not in the bundle.
    static func bundleROMURL(for game: GameEntry, bundle: Bundle = .main) -> URL? {
        guard let romFile = game.romFile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !romFile.isEmpty,
              let url = bundleURL(forBundleRelativePath: romFile, bundle: bundle),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    // MARK: - Static link

    /// Title IDs whose AOT code is statically linked into this binary.
    private func staticallyLinkedTitleIDs() -> Set<String> {
        if !previewStaticTitleIDs.isEmpty { return previewStaticTitleIDs }
        guard zk_linked_code() == 1 else { return [] }
        let programID = zk_linked_program_id()
        guard programID != 0 else { return [] }
        return [String(format: "%016llX", programID)]
    }

    // MARK: - Game package loading

    private func loadPackage(for game: GameEntry,
                             relativePath: String,
                             url: URL) -> AOTResolution {
        if let loaded = cachedPackage(for: game.titleID) {
            switch register(package: loaded) {
            case .registered:
                return .package(loaded)
            case .failed(let detail):
                // A cached pack that no longer registers must not be reused.
                invalidatePackage(titleID: game.titleID)
                return .unavailable(.packageInvalid(detail))
            }
        }

        // dlopen errors are per-call state on the calling thread; clear a stale
        // message first so it cannot be attributed to this pack.
        _ = dlerror()
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? L10n.tr("dlopen failed")
            AppLog.log("[3ds2apple] game package %@: dlopen failed: %@", relativePath, detail)
            return .unavailable(.packageInvalid(detail))
        }

        // A pack can state which title it was built for; a mismatch must never
        // run code meant for another game.
        if let symbol = dlsym(handle, Self.titleIDSymbol) {
            typealias TitleIDFunction = @convention(c) () -> UInt64
            let packed = unsafeBitCast(symbol, to: TitleIDFunction.self)()
            let packedTitleID = String(format: "%016llX", packed)
            guard packedTitleID == game.titleID else {
                dlclose(handle)
                AppLog.log(
                    "[3ds2apple] game package %@: pack is for %@, catalog says %@",
                    relativePath,
                    packedTitleID,
                    game.titleID
                )
                return .unavailable(.linkedTitleMismatch(expected: game.titleID, linked: packedTitleID))
            }
        }
        if let symbol = dlsym(handle, Self.abiVersionSymbol) {
            typealias ABIVersionFunction = @convention(c) () -> UInt32
            let packABI = unsafeBitCast(symbol, to: ABIVersionFunction.self)()
            guard packABI == Self.hostABIVersion else {
                dlclose(handle)
                let detail = L10n.format(
                    "the pack uses ABI version %ld, this app speaks %ld",
                    packABI,
                    Self.hostABIVersion
                )
                AppLog.log("[3ds2apple] game package %@: %@", relativePath, detail)
                return .unavailable(.packageInvalid(detail))
            }
        }
        // The hook is REQUIRED. A pack without it can only make the runtime fall
        // back to the interpreter, and this shell never runs interpreted code.
        let registrationName = game.registrationSymbol ?? Self.defaultRegistrationSymbol
        guard dlsym(handle, registrationName) != nil else {
            dlclose(handle)
            let detail = L10n.format(
                "the game package “%@” does not export the required registration hook “%@”, so it cannot hand its AOT code to the runtime",
                relativePath,
                registrationName
            )
            AppLog.log("[3ds2apple] game package %@: %@", relativePath, detail)
            return .unavailable(.packageInvalid(detail))
        }
        let package = AOTPackage(
            titleID: game.titleID,
            bundleRelativePath: relativePath,
            url: url,
            handle: handle,
            registrationSymbol: registrationName
        )
        switch register(package: package) {
        case .failed(let detail):
            // Refused: unload and do not cache, so a retry cannot use it either.
            dlclose(handle)
            return .unavailable(.packageInvalid(detail))
        case .registered:
            break
        }
        lock.lock()
        packages[game.titleID] = package
        lock.unlock()
        return .package(package)
    }

    // MARK: - Registration

    /// Outcome of (re-)running a pack's registration hook.
    private enum RegistrationResult {
        case registered
        case failed(String)
    }

    /// Makes the runtime's single GamePack registration slot name this pack.
    ///
    /// `zk_register_gamepack()` replaces the previous pack, so the hook is safe to
    /// re-run. The shell checks the registered title first and re-runs the hook
    /// when another game is in the slot: launching A, then B, then A again must
    /// leave A's AOT tables registered, never B's. A pack whose hook fails is
    /// unregistered again before it is reported unavailable, so a refusal leaves
    /// no half-registered state behind.
    private func register(package: AOTPackage) -> RegistrationResult {
        let expectedTitle = UInt64(package.titleID, radix: 16) ?? 0
        if expectedTitle != 0, zk_registered_gamepack_title_id() == expectedTitle {
            // Already in the slot: the normal case for a re-launch of this game.
            return .registered
        }
        guard let registrationName = package.registrationSymbol,
              let symbol = dlsym(package.handle, registrationName) else {
            return .failed(L10n.format(
                "the game package “%@” does not export its registration hook any more",
                package.bundleRelativePath
            ))
        }
        typealias RegisterFunction = @convention(c) (UInt32) -> Int32
        _ = dlerror()
        let result = unsafeBitCast(symbol, to: RegisterFunction.self)(Self.hostABIVersion)
        guard result == 0 else {
            _ = zk_unregister_gamepack()
            let detail = L10n.format(
                "“%@” refused this app (result %ld)",
                registrationName,
                result
            )
            AppLog.log("[3ds2apple] game package %@: %@", package.bundleRelativePath, detail)
            return .failed(detail)
        }
        let registeredTitle = zk_registered_gamepack_title_id()
        guard expectedTitle != 0, registeredTitle == expectedTitle else {
            _ = zk_unregister_gamepack()
            let detail = L10n.format(
                "registering “%@” left title %016llX in the runtime, expected %@",
                registrationName,
                registeredTitle,
                package.titleID
            )
            AppLog.log("[3ds2apple] game package %@: %@", package.bundleRelativePath, detail)
            return .failed(detail)
        }
        AppLog.log(
            "[3ds2apple] game package %@: registered for %@ (abi %ld)",
            package.bundleRelativePath,
            package.titleID,
            Self.hostABIVersion
        )
        return .registered
    }

    /// A pack already loaded in this app run, if any.
    private func cachedPackage(for titleID: String) -> AOTPackage? {
        lock.lock()
        defer { lock.unlock() }
        return packages[titleID]
    }

    /// Drops a cached pack that failed to (re-)register.
    private func invalidatePackage(titleID: String) {
        lock.lock()
        packages.removeValue(forKey: titleID)
        lock.unlock()
    }
}
