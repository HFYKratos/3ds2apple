//
//  CheatBridge.swift
//  3ds2apple
//
//  The runtime half of the cheat codes (0.2.2): the zk_cheats_* ABI from
//  ios/ZakuroBridge.h (provided by the runtime work) and the observable state
//  the in-game menu shows.
//
//  Every call that takes a zk_system_t runs on ROMSession's runtime serial
//  queue: the runtime owns the handle and the enabled list, and the app only
//  reads/toggles through these functions. The file itself is CheatManager's
//  (Documents/Cheats/<TITLEID>.txt); this file passes the explicit path.
//
//  A toggle writes back through zk_cheats_save() so the file stays the
//  authority: the in-game menu and the Settings editor both end up in the same
//  text, and a crash between the toggle and the save cannot lose the rest.
//

import Combine
import Foundation

/// One entry as zk_cheats_json() reports it (schema 1). The index is the list
/// order the ABI's zk_cheats_set_enabled() takes.
struct RuntimeCheat: Identifiable, Equatable {
    let index: Int
    let name: String
    let enabled: Bool
    /// `XXXXXXXX YYYYYYYY` lines the entry runs.
    let lines: Int
    /// Lines the runtime keeps and writes back but does not run.
    let invalidLines: Int

    var id: Int { index }
}

/// The runtime's cheat state for the loaded game, plus the file facts the
/// diagnostics report and the in-game page show.
struct CheatsRuntimeSnapshot: Equatable {
    var titleID = ""
    var path = ""
    var fileExists = false
    var fileBytes = 0
    var loadedCount = 0
    /// The player's cheats in the runtime's order (empty when none loaded).
    var cheats: [RuntimeCheat] = []
    /// Why the file could not be loaded/read; nil when the load was clean.
    var error: String?

    static let none = CheatsRuntimeSnapshot()

    var enabledCount: Int { cheats.filter { $0.enabled }.count }
    var filePathDescription: String {
        guard !path.isEmpty else { return "-" }
        return "Documents/Cheats/" + URL(fileURLWithPath: path).lastPathComponent
    }

    /// The diagnostics report's `cheats_runtime=` line.
    var diagnosticsLine: String {
        guard !titleID.isEmpty, !path.isEmpty else {
            return "no game loaded"
        }
        var parts = [
            "file=\(filePathDescription)",
            "exists=\(fileExists ? 1 : 0)",
            "bytes=\(fileBytes)",
            "loaded=\(loadedCount)",
            "enabled=\(enabledCount)",
        ]
        if let error {
            parts.append("error=\(error)")
        }
        return parts.joined(separator: " ")
    }
}

/// The C ABI calls. Runtime queue only (the caller names a live handle); the
/// file path always comes from CheatManager.
enum CheatBridge {
    /// Loads Documents/Cheats/<TITLEID>.txt into the runtime: replaces the
    /// player's cheats, the `*citra_enabled` ones run from the next frame.
    /// A missing file is not an error (the title simply has no cheats).
    static func load(system: zk_system_t?, titleID: String, path: String) -> CheatsRuntimeSnapshot {
        var snapshot = CheatsRuntimeSnapshot()
        snapshot.titleID = titleID
        snapshot.path = path
        snapshot.fileExists = fileFacts(path: path, snapshot: &snapshot)
        guard snapshot.fileExists else { return snapshot }
        guard let system else {
            snapshot.error = L10n.tr("The game is not running.")
            return snapshot
        }
        let loaded = zk_cheats_load(system, path)
        if loaded < 0 {
            snapshot.error = lastErrorMessage(fallback: L10n.tr("The cheat file could not be loaded."))
            return snapshot
        }
        snapshot.loadedCount = Int(loaded)
        applyJSON(system: system, to: &snapshot)
        return snapshot
    }

    /// Re-reads the runtime's current list without touching the file (the
    /// in-game page refreshes this after a toggle or when it opens).
    static func snapshot(system: zk_system_t?, titleID: String, path: String) -> CheatsRuntimeSnapshot {
        var snapshot = CheatsRuntimeSnapshot()
        snapshot.titleID = titleID
        snapshot.path = path
        snapshot.fileExists = fileFacts(path: path, snapshot: &snapshot)
        guard let system else { return snapshot }
        let count = zk_cheats_count(system)
        snapshot.loadedCount = count > 0 ? Int(count) : 0
        applyJSON(system: system, to: &snapshot)
        return snapshot
    }

    /// Turns one runtime cheat on/off and writes the file back through
    /// zk_cheats_save(). Returns nil on success, or a user-facing reason.
    static func setEnabled(system: zk_system_t?, path: String, index: Int, enabled: Bool) -> String? {
        guard let system else {
            return L10n.tr("The game is not running.")
        }
        let result = zk_cheats_set_enabled(system, Int32(clamping: index), enabled ? 1 : 0)
        if result < 0 {
            return lastErrorMessage(fallback: L10n.tr("The cheat could not be switched."))
        }
        let saved = zk_cheats_save(system, path)
        if saved < 0 {
            return lastErrorMessage(fallback: L10n.tr("The cheat file could not be saved."))
        }
        return nil
    }

    // MARK: - Helpers

    /// Fills the file existence/size fields from the path; returns whether the
    /// file exists.
    private static func fileFacts(path: String, snapshot: inout CheatsRuntimeSnapshot) -> Bool {
        guard !path.isEmpty else { return false }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return false
        }
        snapshot.fileBytes = values.fileSize ?? 0
        return true
    }

    /// Copies zk_cheats_json() into the snapshot. The pointer is library-owned
    /// and only valid until the next call on this thread, so it is decoded here.
    private static func applyJSON(system: zk_system_t, to snapshot: inout CheatsRuntimeSnapshot) {
        guard let pointer = zk_cheats_json(system) else {
            snapshot.error = L10n.tr("The runtime did not return the cheat list.")
            return
        }
        let json = String(cString: pointer)
        guard let data = json.data(using: .utf8) else {
            snapshot.error = L10n.tr("The runtime did not return the cheat list.")
            return
        }
        do {
            let document = try JSONDecoder().decode(CheatsJSONDocument.self, from: data)
            snapshot.cheats = document.cheats.enumerated().map { offset, cheat in
                RuntimeCheat(
                    index: offset,
                    name: cheat.name,
                    enabled: cheat.enabled,
                    lines: cheat.lines,
                    invalidLines: cheat.invalidLines
                )
            }
            if !document.cheats.isEmpty {
                snapshot.loadedCount = document.cheats.count
            }
        } catch {
            snapshot.error = L10n.format("The runtime's cheat list could not be read: %@", error.localizedDescription)
        }
    }

    /// zk_last_error() is thread-local: copy it on the thread that saw the
    /// failure, before hopping anywhere else.
    private static func lastErrorMessage(fallback: String) -> String {
        guard let pointer = zk_last_error() else { return fallback }
        let text = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    // MARK: - JSON schema 1

    private struct CheatsJSONDocument: Decodable {
        let schema: Int?
        let cheats: [CheatJSON]
    }

    private struct CheatJSON: Decodable {
        let name: String
        let enabled: Bool
        let lines: Int
        let invalidLines: Int
    }
}

/// Observable state for the in-game Cheats page. ROMSession installs the
/// handlers (they run its runtime queue) and publishes the snapshot after every
/// game load; the page observes this object and asks it to refresh/toggle.
final class CheatRuntime: ObservableObject {
    static let shared = CheatRuntime()

    /// What the loaded game's runtime has, from the last load or toggle.
    @Published private(set) var snapshot: CheatsRuntimeSnapshot = .none
    /// A refresh/toggle is in flight (the page disables its controls).
    @Published private(set) var isBusy = false

    /// The title/path of the loaded game; empty while no game runs.
    private(set) var titleID = ""
    private(set) var filePath = ""
    /// Bumped when the game unloads: a refresh/toggle that was already running
    /// must not publish its result for the previous session.
    private var generation: UInt64 = 0

    /// ROMSession's runtime-queue entry points; installed by its init.
    var reloadHandler: ((_ titleID: String, _ path: String,
                         _ completion: @escaping (CheatsRuntimeSnapshot) -> Void) -> Void)?
    var toggleHandler: ((_ titleID: String, _ path: String, _ index: Int, _ enabled: Bool,
                         _ completion: @escaping (CheatsRuntimeSnapshot?, String?) -> Void) -> Void)?

    private init() {}

    /// Publishes the snapshot from a game load (main queue).
    func publish(_ snapshot: CheatsRuntimeSnapshot, titleID: String, path: String) {
        self.titleID = titleID
        self.filePath = path
        self.snapshot = snapshot
    }

    /// The game unloaded: the next load starts from the file again.
    func reset() {
        generation &+= 1
        titleID = ""
        filePath = ""
        snapshot = .none
        isBusy = false
    }

    /// Re-reads the runtime's list (the in-game page calls it when it opens).
    func refresh() {
        guard !titleID.isEmpty, let reloadHandler else { return }
        let requestGeneration = generation
        isBusy = true
        reloadHandler(titleID, filePath) { [weak self] snapshot in
            guard let self, self.generation == requestGeneration else { return }
            self.isBusy = false
            self.snapshot = snapshot
        }
    }

    /// Switches one entry and saves the file; reports a user-facing error, if any.
    func setEnabled(index: Int, enabled: Bool, completion: @escaping (String?) -> Void) {
        guard !titleID.isEmpty, let toggleHandler else {
            completion(L10n.tr("The game is not running."))
            return
        }
        let requestGeneration = generation
        isBusy = true
        toggleHandler(titleID, filePath, index, enabled) { [weak self] snapshot, error in
            guard let self, self.generation == requestGeneration else { return }
            self.isBusy = false
            if let snapshot {
                self.snapshot = snapshot
            }
            completion(error)
        }
    }
}
