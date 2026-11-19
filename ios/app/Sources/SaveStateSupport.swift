//
//  SaveStateSupport.swift
//  3ds2apple
//
//  Instant save states: three slots per game, written by asking the Zakuro
//  runtime to serialize the running console and restored by handing that blob
//  back.
//
//  The runtime's C ABI is a size -> copy protocol (ios/ZakuroBridge.h,
//  "saved states"): `zk_save_state_size` serializes the console once and keeps
//  the blob, `zk_save_state_copy` copies that exact snapshot, and
//  `zk_load_state` puts it back. Every call takes a runtime handle and therefore
//  runs on the session's single serial runtime queue, with the frame loop and
//  the audio engine stopped, so a state is always taken and restored between
//  frames. Errors come from `zk_last_error()` on that same queue.
//
//  A slot is one file: Documents/states/<game>/slot<N>.bin. It is written
//  through a temporary file in the same directory and renamed into place, so an
//  interrupted save cannot destroy a good slot.
//
//  This type is the single place the UI asks about save states. Battery save
//  data (Documents/data/<title id>) is handled by SaveDataStore.
//

import Combine
import Foundation
import os

/// One instant save-state slot of the loaded game.
struct SaveStateSlot: Identifiable, Equatable {
    let number: Int
    let exists: Bool
    let bytes: UInt64
    let modified: Date?

    var id: Int { number }

    var title: String { L10n.format("Slot %ld", number) }

    /// Short row text: size and date, or that the slot is free.
    var detail: String {
        guard exists else { return L10n.tr("Empty") }
        let sizeText = StorageFormat.size(bytes)
        guard let modified else { return sizeText }
        return "\(sizeText) · \(StorageFormat.date(modified))"
    }
}

/// A save-state failure with a message the UI shows as-is.
struct SaveStateError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One background recovery snapshot: the console state written when the app
/// moved to the background, together with the game it belongs to. Stored as
/// Documents/states/background.json next to the game's save-state folder.
struct BackgroundSnapshot: Codable, Equatable {
    /// 16 upper-case hex digits of the 3DS program id.
    let titleID: String
    /// Display name for the home page's resume card.
    let title: String
    /// Save-state / save-data folder name of the game (title id by default).
    let namespace: String
    /// When the snapshot was taken.
    let capturedAt: Date
    /// Size of the state file in bytes.
    let bytes: UInt64
}

/// What save states need from the running session: whether a game is loaded,
/// how to stop and restart it around a serialization, and the serial queue that
/// owns the runtime handle.
protocol SaveStateRuntime: AnyObject {
    /// True while a game is loaded and its handle is alive.
    var isRuntimeLoaded: Bool { get }
    /// Title-id namespace of the loaded game, used to find its slot folder.
    var saveStateNamespace: String? { get }
    /// Stops the frame loop and the audio engine before the console is
    /// serialized or restored. Returns true when it stopped a running session.
    func suspendForStateWork() -> Bool
    /// Restarts what `suspendForStateWork()` stopped (and only that).
    func resumeAfterStateWork(_ suspended: Bool)
    /// Drops audio buffered before a load: the DSP state jumped back too.
    func discardBufferedAudio()
    /// Queues one operation on the serial queue that owns the runtime handle.
    /// The handle is nil when the game was unloaded before the block ran.
    func runOnRuntimeQueue(_ work: @escaping (zk_system_t?) -> Void)
}

/// Save-state slots of the loaded game plus the operations on them.
final class SaveStateSupport: ObservableObject {
    /// Slots offered per game.
    static let slotCount = 3

    /// Slot the in-game menu's quick Save State / Load State buttons use.
    static let quickSlot = 1

    /// The largest state accepted in either direction. Mirrors
    /// `ZK_SAVE_STATE_MAX_BYTES` in ios/ZakuroBridge.h (512 MiB): the raw
    /// console memories are at most 256 MiB of FCRAM plus VRAM and DSP RAM, so a
    /// bigger blob is a bug or a damaged file.
    static let maximumStateBytes = 512 * 1024 * 1024

    /// Whether this build can save and restore instant save states.
    ///
    /// The saved-state calls are part of the runtime static library the shell
    /// links (the saved-state section of ios/ZakuroBridge.h), so they are always
    /// bound in a built app; availability is a build-time fact and not something
    /// to probe at run time. Whether a state can be taken right now is separate:
    /// the game must be loaded (`canSave`) and a load needs an existing slot.
    static let isAvailable = true

    /// The three slots of the current game, in order. Empty slots have
    /// `exists == false`.
    @Published private(set) var slots: [SaveStateSlot]

    /// A save, load or delete is running; the buttons stay disabled meanwhile.
    @Published private(set) var busy = false

    /// What the current operation is doing ("Serializing the console…").
    @Published private(set) var statusText = ""

    /// Why the last operation failed; cleared by the next one.
    @Published private(set) var errorMessage: String?

    private weak var runtime: SaveStateRuntime?

    init(runtime: SaveStateRuntime) {
        self.runtime = runtime
        self.slots = SaveStateSupport.emptySlots()
    }

    // MARK: - State

    /// Title-id namespace the slots belong to (nil before a game is loaded).
    var namespace: String? { runtime?.saveStateNamespace }

    /// True while a game is loaded: a state can be taken or restored.
    var isRuntimeLoaded: Bool { runtime?.isRuntimeLoaded ?? false }

    /// Whether the in-game menu may save now.
    var canSave: Bool { Self.isAvailable && isRuntimeLoaded && !busy }

    /// Whether the quick-slot load button may run now.
    var canLoad: Bool { canLoad(slot: Self.quickSlot) }

    /// Whether one slot may be loaded now.
    func canLoad(slot number: Int) -> Bool {
        canSave && slotInfo(number: number).exists
    }

    /// Total bytes the existing slots take.
    var totalBytes: UInt64 {
        slots.reduce(0) { $0 + $1.bytes }
    }

    /// One slot, whether or not it exists.
    func slotInfo(number: Int) -> SaveStateSlot {
        slots.first { $0.number == number }
            ?? SaveStateSlot(number: number, exists: false, bytes: 0, modified: nil)
    }

    /// The slot the in-game menu's quick buttons act on.
    var quickSlotInfo: SaveStateSlot { slotInfo(number: Self.quickSlot) }

    /// Re-reads the slots from disk. Call from `onAppear` of the pages that show
    /// them, and after an operation changed a slot.
    func refresh() {
        let namespace = runtime?.saveStateNamespace
        let read = SaveStateSupport.readSlots(namespace: namespace)
        let publish: () -> Void = { [weak self] in
            guard let self else { return }
            self.slots = read
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    /// Clears the last status/error line (a page just opened).
    func clearMessages() {
        statusText = ""
        errorMessage = nil
    }

    // MARK: - Operations

    /// Serializes the running console into `number` while the frame loop and
    /// audio are stopped. The completion runs on the main queue.
    func save(
        slot number: Int,
        completion: ((Result<SaveStateSlot, SaveStateError>) -> Void)? = nil
    ) {
        if case .failure(let error) = validate(slot: number, requiresLoadedRuntime: true) {
            publish(error)
            completion?(.failure(error))
            return
        }
        guard let runtime, let namespace = runtime.saveStateNamespace, runtime.isRuntimeLoaded else {
            let error = SaveStateError(message: L10n.tr("Start a game before saving a state."))
            publish(error)
            completion?(.failure(error))
            return
        }
        guard !busy else { return }
        busy = true
        errorMessage = nil
        statusText = L10n.format("Saving to slot %ld…", number)
        let suspended = runtime.suspendForStateWork()
        let slotURL = SaveStateSupport.slotURL(namespace: namespace, slot: number)
        runtime.runOnRuntimeQueue { [weak self] handle in
            let result: Result<SaveStateSlot, SaveStateError>
            if let handle {
                result = SaveStateSupport.writeState(
                    handle: handle,
                    to: slotURL,
                    number: number,
                    progress: { text in self?.publishStatus(text) }
                )
            } else {
                result = .failure(
                    SaveStateError(message: L10n.tr("The game stopped before the state could be saved."))
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                runtime.resumeAfterStateWork(suspended)
                switch result {
                case .success(let slot):
                    self.errorMessage = nil
                    self.statusText = L10n.format("Saved %@ · %@", slot.title, StorageFormat.size(slot.bytes))
                    self.replace(slot)
                    AppLog.log(
                        "[3ds2apple] save state: saved slot %d (%llu bytes)",
                        number,
                        slot.bytes
                    )
                case .failure(let error):
                    self.publish(error)
                }
                completion?(result)
            }
        }
    }

    /// Restores `number` into the running console. A successful load drops the
    /// audio buffered before it; the caller resumes the session (the in-game
    /// menu closes over a resumed game). The completion runs on the main queue.
    func load(
        slot number: Int,
        completion: ((Result<SaveStateSlot, SaveStateError>) -> Void)? = nil
    ) {
        guard !busy else { return }
        guard let runtime, let namespace = runtime.saveStateNamespace, runtime.isRuntimeLoaded else {
            let error = SaveStateError(message: L10n.tr("Start a game before loading a state."))
            publish(error)
            completion?(.failure(error))
            return
        }
        let slot = slotInfo(number: number)
        guard slot.exists else {
            let error = SaveStateError(message: L10n.format("%@ is empty.", slot.title))
            publish(error)
            completion?(.failure(error))
            return
        }
        busy = true
        errorMessage = nil
        statusText = L10n.format("Loading %@…", slot.title)
        let suspended = runtime.suspendForStateWork()
        let slotURL = SaveStateSupport.slotURL(namespace: namespace, slot: number)
        runtime.runOnRuntimeQueue { [weak self] handle in
            let result: Result<SaveStateSlot, SaveStateError>
            if let handle {
                result = SaveStateSupport.readAndApply(
                    handle: handle,
                    from: slotURL,
                    number: number,
                    progress: { text in self?.publishStatus(text) }
                )
            } else {
                result = .failure(
                    SaveStateError(message: L10n.tr("The game stopped before the state could be restored."))
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let loaded):
                    // The console (and its DSP) is back at the saved point:
                    // samples produced before the load must not play, and the
                    // next frame redraws over the last frame that stayed on
                    // screen.
                    runtime.discardBufferedAudio()
                    self.errorMessage = nil
                    self.statusText = L10n.format("Loaded %@ · %@", loaded.title, StorageFormat.size(loaded.bytes))
                    self.replace(loaded)
                    runtime.resumeAfterStateWork(suspended)
                    AppLog.log(
                        "[3ds2apple] save state: loaded slot %d (%llu bytes)",
                        number,
                        loaded.bytes
                    )
                case .failure(let error):
                    self.publish(error)
                    runtime.resumeAfterStateWork(suspended)
                }
                completion?(result)
            }
        }
    }

    /// Deletes the file of `number`. Deleting needs no running game.
    /// `completion` receives nil on success, or the error that stopped it.
    func delete(
        slot number: Int,
        completion: ((SaveStateError?) -> Void)? = nil
    ) {
        guard !busy else { return }
        guard let namespace = runtime?.saveStateNamespace else {
            let error = SaveStateError(message: L10n.tr("No game is selected."))
            publish(error)
            completion?(error)
            return
        }
        let slot = slotInfo(number: number)
        guard slot.exists else {
            completion?(nil)
            return
        }
        busy = true
        errorMessage = nil
        statusText = L10n.format("Deleting %@…", slot.title)
        let slotURL = SaveStateSupport.slotURL(namespace: namespace, slot: number)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: SaveStateError?
            do {
                if FileManager.default.fileExists(atPath: slotURL.path) {
                    try FileManager.default.removeItem(at: slotURL)
                }
            } catch {
                failure = SaveStateError(
                    message: L10n.format("Could not delete %@: %@", slot.title, error.localizedDescription)
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let failure {
                    self.publish(failure)
                } else {
                    self.errorMessage = nil
                    self.statusText = L10n.format("Deleted %@", slot.title)
                    self.slots = self.slots.map { current in
                        current.number == number
                            ? SaveStateSlot(number: number, exists: false, bytes: 0, modified: nil)
                            : current
                    }
                    AppLog.log("[3ds2apple] save state: deleted slot %d", number)
                }
                completion?(failure)
            }
        }
    }

    // MARK: - Background recovery snapshot
    //
    // 0.1.4 keeps the runtime alive when the app moves to the background, so a
    // normal switch away and back continues the same session. iOS may still
    // jettison a backgrounded process under memory pressure; this snapshot is
    // the recovery path for that case: the console is serialized into the
    // game's state folder before the process can be suspended, and the home
    // page offers to restore it after a cold launch. The snapshot is removed
    // again as soon as the app returns to the foreground, because the running
    // console is then newer than the snapshot.

    /// Memory headroom the process needs before the snapshot is attempted:
    /// serializing the console holds the runtime's copy plus the buffer copied
    /// out of it, so capturing in a memory-constrained process would invite the
    /// jetsam the snapshot is meant to survive.
    static let backgroundSnapshotHeadroomBytes = 700 * 1024 * 1024

    /// Free disk space the snapshot needs: the console state is at most 512 MiB
    /// and the write goes through a temporary file next to the old one.
    static let backgroundSnapshotDiskBytes: Int64 = 1024 * 1024 * 1024

    /// The recovery snapshot offered on the home page after a cold launch, nil
    /// when there is none (or its state file is missing: the metadata is then
    /// removed too).
    static func pendingBackgroundSnapshot() -> BackgroundSnapshot? {
        guard let snapshot = decodeBackgroundSnapshot() else { return nil }
        let stateURL = backgroundSnapshotURL(namespace: snapshot.namespace)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size > 0 else {
            discardBackgroundSnapshot()
            return nil
        }
        return snapshot
    }

    /// Serializes the running console into the recovery snapshot. The caller
    /// (ROMSession.suspendForBackground) has already stopped the frame loop and
    /// the audio engine. Completion runs on the main queue; nil means nothing
    /// was written (no loaded game, a save-state operation in flight, not
    /// enough memory or disk, or the runtime refused).
    func captureBackgroundSnapshot(
        titleID: String,
        title: String,
        completion: ((BackgroundSnapshot?) -> Void)? = nil
    ) {
        guard let runtime, let namespace = runtime.saveStateNamespace, runtime.isRuntimeLoaded else {
            completionOnMain(nil, completion)
            return
        }
        guard !busy else {
            AppLog.log("[3ds2apple] background snapshot: skipped (a save-state operation is running)")
            completionOnMain(nil, completion)
            return
        }
        let headroom = os_proc_available_memory()
        guard headroom >= Self.backgroundSnapshotHeadroomBytes else {
            AppLog.log(
                "[3ds2apple] background snapshot: skipped (%ld MiB of memory headroom, %ld MiB needed)",
                headroom / (1024 * 1024),
                Self.backgroundSnapshotHeadroomBytes / (1024 * 1024)
            )
            completionOnMain(nil, completion)
            return
        }
        guard Self.hasDiskSpaceForBackgroundSnapshot() else {
            AppLog.log("[3ds2apple] background snapshot: skipped (not enough free disk space)")
            completionOnMain(nil, completion)
            return
        }
        let stateURL = SaveStateSupport.backgroundSnapshotURL(namespace: namespace)
        let metadataURL = SaveStateSupport.backgroundMetadataURL
        busy = true
        runtime.runOnRuntimeQueue { [weak self] handle in
            guard let self else { return }
            let result: Result<BackgroundSnapshot, SaveStateError>
            if let handle {
                result = Self.writeBackgroundSnapshot(
                    handle: handle,
                    to: stateURL,
                    metadataURL: metadataURL,
                    titleID: titleID,
                    title: title,
                    namespace: namespace
                )
            } else {
                result = .failure(
                    SaveStateError(message: L10n.tr("The game stopped before the recovery snapshot could be saved."))
                )
            }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let snapshot):
                    AppLog.log(
                        "[3ds2apple] background snapshot: saved %@ (%@) · %@",
                        snapshot.titleID,
                        StorageFormat.size(snapshot.bytes),
                        snapshot.title
                    )
                    completion?(snapshot)
                case .failure(let error):
                    AppLog.log("[3ds2apple] background snapshot: %@", error.message)
                    completion?(nil)
                }
            }
        }
    }

    /// Restores the recovery snapshot into the loaded console and removes the
    /// snapshot files afterwards. A state that fails to load is removed too: it
    /// was written by this app and will not become compatible again. Completion
    /// runs on the main queue with nil on success, or the failure message.
    func restoreBackgroundSnapshot(
        snapshot: BackgroundSnapshot,
        completion: ((String?) -> Void)? = nil
    ) {
        guard let runtime, runtime.isRuntimeLoaded else {
            SaveStateSupport.discardBackgroundSnapshot()
            completionOnMain(L10n.tr("The game stopped before the recovery snapshot could be restored."), completion)
            return
        }
        guard !busy else {
            AppLog.log("[3ds2apple] background snapshot: restore skipped (a save-state operation is running)")
            completionOnMain(L10n.tr("The game was busy with another save-state operation."), completion)
            return
        }
        let stateURL = SaveStateSupport.backgroundSnapshotURL(namespace: snapshot.namespace)
        busy = true
        runtime.runOnRuntimeQueue { [weak self] handle in
            guard let self else { return }
            var failure: String?
            if let handle {
                switch Self.readAndApply(handle: handle, from: stateURL, number: 0, progress: { _ in }) {
                case .success:
                    break
                case .failure(let error):
                    failure = error.message
                }
            } else {
                failure = L10n.tr("The game stopped before the recovery snapshot could be restored.")
            }
            SaveStateSupport.discardBackgroundSnapshot()
            DispatchQueue.main.async {
                self.busy = false
                if let failure {
                    AppLog.log("[3ds2apple] background snapshot: restore failed: %@", failure)
                } else {
                    AppLog.log("[3ds2apple] background snapshot: restored %@", snapshot.titleID)
                }
                completion?(failure)
            }
        }
    }

    /// Removes the recovery snapshot and its metadata. Safe to call when there
    /// is none, and from any thread (the home page and the session call it).
    static func discardBackgroundSnapshot() {
        let fileManager = FileManager.default
        if let snapshot = decodeBackgroundSnapshot() {
            try? fileManager.removeItem(at: backgroundSnapshotURL(namespace: snapshot.namespace))
        }
        try? fileManager.removeItem(at: backgroundMetadataURL)
        removeStaleSnapshotTemporaries()
    }

    private static func hasDiskSpaceForBackgroundSnapshot() -> Bool {
        let values = try? statesRootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else {
            return true
        }
        return capacity >= backgroundSnapshotDiskBytes
    }

    /// Serializes the console and writes the state file plus its metadata.
    /// runtime queue only.
    private static func writeBackgroundSnapshot(
        handle: zk_system_t,
        to url: URL,
        metadataURL: URL,
        titleID: String,
        title: String,
        namespace: String
    ) -> Result<BackgroundSnapshot, SaveStateError> {
        let state: Data
        switch copyState(handle: handle, progress: { _ in }) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            state = data
        }
        do {
            try AtomicFileWriter.write(state, to: url)
        } catch {
            return .failure(
                SaveStateError(
                    message: L10n.format("Could not write the recovery snapshot: %@", error.localizedDescription)
                )
            )
        }
        let snapshot = BackgroundSnapshot(
            titleID: titleID,
            title: title,
            namespace: namespace,
            capturedAt: Date(),
            bytes: UInt64(state.count)
        )
        do {
            try AtomicFileWriter.write(try backgroundJSONEncoder().encode(snapshot), to: metadataURL)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .failure(
                SaveStateError(
                    message: L10n.format("Could not write the recovery snapshot: %@", error.localizedDescription)
                )
            )
        }
        return .success(snapshot)
    }

    private static func decodeBackgroundSnapshot() -> BackgroundSnapshot? {
        guard let data = try? Data(contentsOf: backgroundMetadataURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackgroundSnapshot.self, from: data)
    }

    private static func backgroundJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Temporary files left behind by a write that was killed with the process
    /// (a suspended app cannot finish its file IO): both writes go through
    /// AtomicFileWriter, whose temporary files are dot-files next to the target.
    private static func removeStaleSnapshotTemporaries() {
        let fileManager = FileManager.default
        func removeTemporaries(in directory: URL) {
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(".tmp") {
                try? fileManager.removeItem(at: file)
            }
        }
        removeTemporaries(in: statesRootURL)
        let entries = (try? fileManager.contentsOfDirectory(at: statesRootURL, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            removeTemporaries(in: entry)
        }
    }

    private func completionOnMain<T>(_ value: T, _ completion: ((T) -> Void)?) {
        guard let completion else { return }
        if Thread.isMainThread {
            completion(value)
        } else {
            DispatchQueue.main.async { completion(value) }
        }
    }

    // MARK: - Paths

    /// Root of all games' slot folders: Documents/states.
    static var statesRootURL: URL {
        StorageInspector.documentsURL.appendingPathComponent("states", isDirectory: true)
    }

    /// A game's slot folder: Documents/states/<title-id namespace>.
    static func statesDirectory(namespace: String) -> URL {
        statesRootURL.appendingPathComponent(
            SaveDataStore.directoryName(forNamespace: namespace),
            isDirectory: true
        )
    }

    /// One slot's file: Documents/states/<namespace>/slot<N>.bin.
    static func slotURL(namespace: String, slot: Int) -> URL {
        statesDirectory(namespace: namespace)
            .appendingPathComponent("slot\(slot).bin", isDirectory: false)
    }

    /// Fixed file name of the recovery snapshot inside a game's state folder.
    static let backgroundStateFileName = "background.bin"

    /// Metadata of the recovery snapshot: which game, when, how large. It lives
    /// at the states root because the home page reads it before a game loads;
    /// the state file itself is in the game's folder so deleting a game removes
    /// it with the rest of its save data.
    static var backgroundMetadataURL: URL {
        statesRootURL.appendingPathComponent("background.json", isDirectory: false)
    }

    /// The recovery state file in a game's state folder.
    static func backgroundSnapshotURL(namespace: String) -> URL {
        statesDirectory(namespace: namespace)
            .appendingPathComponent(backgroundStateFileName, isDirectory: false)
    }

    // MARK: - Validation and publishing

    private enum SlotValidation {
        case success
        case failure(SaveStateError)
    }

    private func validate(slot number: Int, requiresLoadedRuntime: Bool) -> SlotValidation {
        guard Self.isAvailable else {
            return .failure(
                SaveStateError(message: L10n.tr("Save states are not available in this build."))
            )
        }
        guard (1...Self.slotCount).contains(number) else {
            return .failure(SaveStateError(message: L10n.format("There is no save-state slot %ld.", number)))
        }
        if requiresLoadedRuntime {
            guard isRuntimeLoaded else {
                return .failure(SaveStateError(message: L10n.tr("Start a game before using save states.")))
            }
        }
        return .success
    }

    private func replace(_ slot: SaveStateSlot) {
        slots = slots.map { current in
            current.number == slot.number ? slot : current
        }
    }

    private func publish(_ error: SaveStateError) {
        errorMessage = error.message
        statusText = ""
        AppLog.log("[3ds2apple] save state: %@", error.message)
    }

    private func publishStatus(_ text: String) {
        if Thread.isMainThread {
            statusText = text
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusText = text
            }
        }
    }

    private static func emptySlots() -> [SaveStateSlot] {
        (1...slotCount).map { number in
            SaveStateSlot(number: number, exists: false, bytes: 0, modified: nil)
        }
    }

    private static func readSlots(namespace: String?) -> [SaveStateSlot] {
        guard let namespace else { return emptySlots() }
        return (1...slotCount).map { number in
            let url = slotURL(namespace: namespace, slot: number)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  size > 0 else {
                return SaveStateSlot(number: number, exists: false, bytes: 0, modified: nil)
            }
            return SaveStateSlot(
                number: number,
                exists: true,
                bytes: size,
                modified: attributes[.modificationDate] as? Date
            )
        }
    }

    // MARK: - Runtime serialization (runtime queue only)

    /// Serializes the console and writes it to `url`. Runs on the runtime queue
    /// with the frame loop stopped, so the snapshot is a real frame boundary.
    /// Serializes the console into memory. Runs on the runtime queue with the
    /// frame loop stopped, so the snapshot is a real frame boundary. The error
    /// texts are generic: both the instant save slots and the background
    /// recovery snapshot copy the state through this function.
    private static func copyState(
        handle: zk_system_t,
        progress: (String) -> Void
    ) -> Result<Data, SaveStateError> {
        progress(L10n.tr("Serializing the console…"))
        let measured = zk_save_state_size(handle)
        guard measured > 0 else {
            zk_save_state_discard(handle)
            return .failure(
                SaveStateError(
                    message: L10n.format(
                        "Could not save the state: %@",
                        currentRuntimeError(fallback: L10n.tr("the runtime could not serialize the console"))
                    )
                )
            )
        }
        guard measured <= maximumStateBytes else {
            zk_save_state_discard(handle)
            return .failure(
                SaveStateError(
                    message: L10n.format(
                        "Could not save the state: the runtime reported %@, larger than a save state can be.",
                        StorageFormat.size(UInt64(measured))
                    )
                )
            )
        }

        progress(L10n.format("Copying %@…", StorageFormat.size(UInt64(measured))))
        var buffer = UnsafeMutableRawPointer.allocate(
            byteCount: measured,
            alignment: MemoryLayout<UInt8>.alignment
        )
        var copied = zk_save_state_copy(
            handle,
            buffer.assumingMemoryBound(to: UInt8.self),
            measured
        )
        if copied > measured {
            // The state grew between the size and copy calls (a copy with a
            // short buffer copies what fits and returns the full length). Retry
            // once with the reported length; the runtime kept the snapshot, so
            // the retry does not serialize the console again.
            buffer.deallocate()
            guard copied <= maximumStateBytes else {
                zk_save_state_discard(handle)
                return .failure(
                    SaveStateError(
                        message: L10n.format(
                            "Could not save the state: it changed to %@, larger than a save state can be.",
                            StorageFormat.size(UInt64(copied))
                        )
                    )
                )
            }
            progress(L10n.format("Copying %@…", StorageFormat.size(UInt64(copied))))
            buffer = UnsafeMutableRawPointer.allocate(
                byteCount: copied,
                alignment: MemoryLayout<UInt8>.alignment
            )
            let retried = zk_save_state_copy(
                handle,
                buffer.assumingMemoryBound(to: UInt8.self),
                copied
            )
            if retried == 0 || retried > copied {
                buffer.deallocate()
                zk_save_state_discard(handle)
                return .failure(
                    SaveStateError(
                        message: L10n.format(
                            "Could not copy the state: %@",
                            currentRuntimeError(fallback: L10n.tr("the runtime did not return a stable state"))
                        )
                    )
                )
            }
            copied = retried
        } else if copied == 0 {
            buffer.deallocate()
            zk_save_state_discard(handle)
            return .failure(
                SaveStateError(
                    message: L10n.format(
                        "Could not copy the state: %@",
                        currentRuntimeError(fallback: L10n.tr("the runtime returned no state data"))
                    )
                )
            )
        }

        // A complete copy releases the runtime's snapshot, so the file write can
        // happen without the library holding a second tens-of-MiB copy.
        let data = Data(
            bytesNoCopy: buffer,
            count: copied,
            deallocator: .custom { pointer, _ in pointer.deallocate() }
        )
        return .success(data)
    }

    /// Serializes the console and writes it to one instant save-state slot.
    /// Runs on the runtime queue with the frame loop stopped.
    private static func writeState(
        handle: zk_system_t,
        to url: URL,
        number: Int,
        progress: (String) -> Void
    ) -> Result<SaveStateSlot, SaveStateError> {
        let state: Data
        switch copyState(handle: handle, progress: progress) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            state = data
        }
        progress(L10n.format("Writing slot %ld…", number))
        do {
            try AtomicFileWriter.write(state, to: url)
        } catch {
            return .failure(
                SaveStateError(
                    message: L10n.format("Could not write slot %ld: %@", number, error.localizedDescription)
                )
            )
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return .success(
            SaveStateSlot(
                number: number,
                exists: true,
                bytes: UInt64(state.count),
                modified: attributes?[.modificationDate] as? Date
            )
        )
    }

    /// Reads a slot file and hands it to the runtime. runtime queue only.
    private static func readAndApply(
        handle: zk_system_t,
        from url: URL,
        number: Int,
        progress: (String) -> Void
    ) -> Result<SaveStateSlot, SaveStateError> {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size > 0 else {
            return .failure(SaveStateError(message: L10n.format("Slot %ld has no state file.", number)))
        }
        guard size <= UInt64(maximumStateBytes) else {
            return .failure(
                SaveStateError(message: L10n.format("Slot %ld is too large to be a save state.", number))
            )
        }
        progress(L10n.format("Reading slot %ld (%@)…", number, StorageFormat.size(size)))
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return .failure(
                SaveStateError(
                    message: L10n.format("Could not read slot %ld: %@", number, error.localizedDescription)
                )
            )
        }
        guard data.count > 0 else {
            return .failure(SaveStateError(message: L10n.format("Slot %ld has no state data.", number)))
        }
        progress(L10n.tr("Restoring the console…"))
        let result: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return -2
            }
            return zk_load_state(handle, base, data.count)
        }
        guard result == 0 else {
            let reason = currentRuntimeError(fallback: loadFailureFallback(result))
            return .failure(
                SaveStateError(message: L10n.format("Could not load slot %ld: %@", number, reason))
            )
        }
        return .success(
            SaveStateSlot(
                number: number,
                exists: true,
                bytes: UInt64(data.count),
                modified: attributes[.modificationDate] as? Date
            )
        )
    }

    /// Copies `zk_last_error()` into Swift text. Must run on the thread that
    /// just saw a runtime call fail (the error slot is thread-local).
    private static func currentRuntimeError(fallback: String) -> String {
        guard let pointer = zk_last_error() else { return fallback }
        let text = String(cString: pointer)
        return text.isEmpty ? fallback : text
    }

    /// Reading for `zk_load_state`'s documented negative result codes.
    private static func loadFailureFallback(_ result: Int32) -> String {
        switch result {
        case -1:
            return L10n.tr("the game is no longer running")
        case -2:
            return L10n.tr("the file cannot be passed to the runtime")
        case -3:
            return L10n.tr("the state was made by another game, another runtime version or another console model, or the file is damaged")
        default:
            return L10n.format("the runtime refused the state (code %d)", result)
        }
    }
}
