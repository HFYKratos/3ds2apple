//
//  ROMSession.swift
//  3ds2apple
//
//  I2-T1: ROM import + zk_create() wiring.
//
//  Owns the Zakuro runtime handle. The frame loop is deliberately absent —
//  I2-T2 owns zk_run_frame().
//
//  Threading contract (docs/integration.md, ios/zakuro-ios/README.md):
//  - every zk_* call that takes a handle runs on `runtimeQueue`, a single
//    serial queue;
//  - zk_create() runs off the main thread (it may take seconds);
//  - zk_last_error() is thread-local and only valid until the next
//    zk_create()/zk_last_error() call on the same thread, so a failure is
//    copied to a Swift String inside the same queue block;
//  - @Published state is only mutated on the main queue.
//

import Combine
import Foundation

/// A ROM stored in the app's Documents directory.
struct ImportedROM {
    /// Display name, e.g. "game.3ds".
    let name: String
    /// Path relative to the app's Documents directory, e.g. "roms/game.3ds".
    /// Persisted instead of an absolute path because the app container path
    /// changes between installs and updates.
    let relativePath: String
}

/// Owns the Zakuro runtime handle and the ROM import pipeline.
final class ROMSession: ObservableObject {
    enum Phase {
        /// Nothing imported or loaded yet.
        case idle
        /// Copying the picked file into Documents/roms.
        case importing(name: String)
        /// zk_create() is running on the runtime queue.
        case starting(name: String)
        /// zk_create() succeeded and a handle is alive.
        case loaded(name: String)
        /// Import or load failed; `message` is user-readable.
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Most recent successfully loaded ROM (nil before the first success).
    @Published private(set) var lastROM: ImportedROM? = nil

    /// Serial queue that owns every zk_* call.
    private let runtimeQueue = DispatchQueue(
        label: "com.kratos.3ds2apple.zakuro-runtime",
        qos: .userInitiated
    )
    /// Runtime handle; only read/written on `runtimeQueue` (except deinit).
    private var system: zk_system_t?
    private let fileManager = FileManager.default

    private static let lastROMPathKey = "I2.lastROMRelativePath"

    init() {
        if let relativePath = UserDefaults.standard.string(forKey: Self.lastROMPathKey) {
            let name = URL(fileURLWithPath: relativePath).lastPathComponent
            lastROM = ImportedROM(name: name, relativePath: relativePath)
        }
    }

    deinit {
        // Every queue block captures `self` weakly, so once deinit runs no
        // other block can still be creating a handle. zk_destroy() may be
        // called from a different thread as long as no other thread uses the
        // pointer (ios/zakuro-ios/README.md: 线程规则).
        if let system {
            zk_destroy(system)
        }
    }

    // MARK: - Commands (main queue)

    /// Copies `url` picked in Files into `Documents/roms/` (reusing an existing
    /// import of the same name) and starts `zk_create`.
    func importROM(from url: URL) {
        let name = url.lastPathComponent
        guard Self.isSupportedROM(name) else {
            setPhase(.failed(message: "Unsupported file “\(name)”. Choose a decrypted .3ds or .cci ROM."))
            return
        }
        setPhase(.importing(name: name))
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            switch self.prepareROM(from: url) {
            case .success(let rom):
                self.startRuntime(for: rom)
            case .failure(let failure):
                self.publishFailure("Could not import “\(name)”: \(failure.message)")
            }
        }
    }

    /// Loads the last successfully imported ROM from Documents again.
    func loadLastROM() {
        guard let rom = lastROM else {
            setPhase(.failed(message: "No ROM has been imported yet. Tap “Import ROM…” first."))
            return
        }
        let url = documentsDirectory.appendingPathComponent(rom.relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            clearLastROM()
            setPhase(.failed(message: "“\(rom.name)” is no longer in this app's Documents folder. Import it again."))
            return
        }
        setPhase(.starting(name: rom.name))
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.startRuntime(for: rom)
        }
    }

    /// Releases the runtime handle and returns to the "no ROM loaded" state.
    /// The imported file stays in Documents so it can be loaded again.
    func unload() {
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            self.destroySystem()
            self.setPhase(.idle)
        }
    }

    /// Clears a failure message without touching the loaded runtime.
    func dismissFailure() {
        if case .failed = phase {
            setPhase(.idle)
        }
    }

    // MARK: - Runtime (runtimeQueue only)

    /// Releases the current handle. Must run on `runtimeQueue`.
    private func destroySystem() {
        guard let system else { return }
        zk_destroy(system)
        self.system = nil
        NSLog("[3ds2apple] zk_destroy: runtime released")
    }

    /// zk_create() for `rom`: destroy old handle, create new one, publish state.
    /// Must run on `runtimeQueue`.
    private func startRuntime(for rom: ImportedROM) {
        let romURL = documentsDirectory.appendingPathComponent(rom.relativePath)
        let dataDirectory = documentsDirectory
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(Self.dataDirectoryName(for: rom.name), isDirectory: true)
        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            publishFailure("Could not create the save-data directory: \(error.localizedDescription)")
            return
        }

        // Replacing a ROM always releases the previous handle first.
        destroySystem()

        NSLog("[3ds2apple] zk_create: loading %@", romURL.path)
        let startedAt = Date()
        let handle = zk_create(romURL.path, dataDirectory.path)
        let elapsed = Date().timeIntervalSince(startedAt)

        guard let handle else {
            // zk_last_error() is thread-local: read and copy it here, in the
            // same block, before hopping to the main queue.
            let message = Self.currentRuntimeError()
            NSLog("[3ds2apple] zk_create failed after %.1f s: %@", elapsed, message)
            publishFailure(message)
            return
        }

        system = handle
        NSLog("[3ds2apple] zk_create OK after %.1f s: %@", elapsed, rom.relativePath)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastROM = rom
            UserDefaults.standard.set(rom.relativePath, forKey: Self.lastROMPathKey)
            self.setPhase(.loaded(name: rom.name))
        }
    }

    /// Copies `zk_last_error()` into a Swift String. Must run on the thread
    /// that just saw `zk_create()` fail (the error slot is thread-local).
    private static func currentRuntimeError() -> String {
        guard let pointer = zk_last_error() else {
            return "The Zakuro runtime could not load this ROM (no error text was reported)."
        }
        let text = String(cString: pointer)
        return text.isEmpty ? "The Zakuro runtime could not load this ROM (empty error text)." : text
    }

    // MARK: - ROM storage (runtimeQueue only)

    private struct ROMImportFailure: Error {
        let message: String
    }

    /// Copies the picked file into `Documents/roms/` and returns its relative
    /// path. An existing file with the same name is reused.
    private func prepareROM(from url: URL) -> Result<ImportedROM, ROMImportFailure> {
        let romsDirectory = documentsDirectory.appendingPathComponent("roms", isDirectory: true)
        do {
            try fileManager.createDirectory(at: romsDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(ROMImportFailure(
                message: "Could not create Documents/roms: \(error.localizedDescription)"
            ))
        }

        let name = url.lastPathComponent
        let destination = romsDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            NSLog("[3ds2apple] reusing imported ROM: %@", destination.path)
            return .success(ImportedROM(name: name, relativePath: relativePath(of: destination)))
        }

        // Files picked in Files/iCloud Drive are security-scoped.
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        // Copy through a temporary file so an interrupted import cannot leave a
        // truncated ROM behind under the final name.
        let temporary = romsDirectory.appendingPathComponent(".incoming-\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: url, to: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .failure(ROMImportFailure(
                message: "Could not read the selected file: \(error.localizedDescription)"
            ))
        }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            // A concurrent import of the same file may have won the race.
            if fileManager.fileExists(atPath: destination.path) {
                return .success(ImportedROM(name: name, relativePath: relativePath(of: destination)))
            }
            return .failure(ROMImportFailure(
                message: "Could not store the ROM in Documents: \(error.localizedDescription)"
            ))
        }

        NSLog("[3ds2apple] imported ROM: %@", destination.path)
        return .success(ImportedROM(name: name, relativePath: relativePath(of: destination)))
    }

    /// Path relative to the app's Documents directory (persisted across
    /// launches; absolute container paths are not stable).
    private func relativePath(of url: URL) -> String {
        let documentsPath = documentsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(documentsPath + "/") {
            return String(path.dropFirst(documentsPath.count + 1))
        }
        return url.lastPathComponent
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Per-ROM directory for saves/cache, passed as `data_dir` to zk_create.
    private static func dataDirectoryName(for romName: String) -> String {
        let stem = (romName as NSString).deletingPathExtension
        let sanitized = stem.map { character -> Character in
            if character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." {
                return character
            }
            return "_"
        }
        return sanitized.isEmpty ? "rom" : String(sanitized)
    }

    /// .3ds / .cci have no registered UTTypes on iOS, so the picker offers
    /// public.data and we validate the extension ourselves.
    private static func isSupportedROM(_ fileName: String) -> Bool {
        ["3ds", "cci"].contains((fileName as NSString).pathExtension.lowercased())
    }

    // MARK: - State (main queue)

    private func setPhase(_ phase: Phase) {
        if Thread.isMainThread {
            self.phase = phase
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.phase = phase
            }
        }
    }

    private func publishFailure(_ message: String) {
        NSLog("[3ds2apple] ROM load failed: %@", message)
        setPhase(.failed(message: message))
    }

    private func clearLastROM() {
        UserDefaults.standard.removeObject(forKey: Self.lastROMPathKey)
        lastROM = nil
    }
}
