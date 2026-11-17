//
//  SaveManagerView.swift
//  3ds2apple
//
//  Save manager for one game at a time: the battery save data the runtime has
//  written into Documents/data/<save namespace>, and the three instant
//  save-state slots in Documents/states/<save namespace>.
//
//  A picker fed by GameLibrary selects the game, so the saves of every game in
//  this build can be managed from Settings without starting it; the selection is
//  remembered in UserDefaults, and opened from the in-game menu the running game
//  is selected. Battery saves can be exported as a ZIP archive through the share
//  sheet, imported back from a ZIP or from single files, and deleted. Import and
//  delete are only offered while no game is running: the runtime may hold those
//  files open. Save-state slots of the selected game can be listed and deleted
//  without a runtime; writing or restoring one needs that exact game running
//  (the runtime serializes its live console), and a successful load resumes the
//  game when the page was opened from the in-game menu.
//
//  User-facing text: static SwiftUI literals localize through
//  Localizable.strings; strings built at run time go through L10n.
//

import Foundation
import SwiftUI
import UIKit

struct SaveManagerView: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var saveStates: SaveStateSupport
    /// The app's game library: the picker lists every game in this build.
    @ObservedObject var library: GameLibrary = GameLibrary.shared
    /// Called after a save-state load succeeded. The game view passes a closure
    /// that closes the menu and resumes the restored session; the page is also
    /// reachable from the home page, where nothing needs resuming.
    var onLoadStateCompleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// Title id of the game whose saves are shown, nil for "No game".
    @State private var selectedTitleID: String?
    @State private var files: [BatterySaveFile] = []
    /// Slot files of the selected game while its runtime is not running; the
    /// running game's slots come live from SaveStateSupport instead.
    @State private var offlineSlots: [SaveStateSlot] = []
    @State private var snapshot = StorageSnapshot.empty
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var sheet: SaveManagerSheet?
    @State private var pendingDeletion: PendingDeletion?
    @State private var isDeleteConfirmationPresented = false

    /// UserDefaults: title id of the game managed last time; "" when the user
    /// chose "No game" explicitly, so the next open stays empty too.
    private static let selectionDefaultsKey = "SaveManager.selectedGameTitleID"

    /// One sheet slot: the share sheet for an exported file or the Files picker
    /// for an import.
    private enum SaveManagerSheet: Identifiable {
        case share(URL)
        case importPicker

        var id: String {
            switch self {
            case .share(let url): return "share-\(url.path)"
            case .importPicker: return "import-picker"
            }
        }
    }

    /// What a delete confirmation is about.
    private enum PendingDeletion {
        case batterySave(BatterySaveFile)
        case state(Int)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                gameCard
                summaryCard
                batterySaveCard
                saveStateCard
                messagesCard
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Save Manager")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityIdentifier("save-manager-refresh")
            }
        }
        .onAppear {
            saveStates.clearMessages()
            resolveDefaultSelection()
            refresh()
        }
        .onChange(of: library.entries.map { $0.titleID }) { titleIDs in
            // The library can change while this page is open (the app rescans
            // Documents/Games when it comes back to the foreground): keep the
            // selection valid instead of showing a game that is gone.
            guard let selectedTitleID, !titleIDs.contains(selectedTitleID) else { return }
            resolveDefaultSelection()
            refresh()
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .share(let url):
                ShareSheet(items: [url])
            case .importPicker:
                SaveArchivePicker { url in
                    self.sheet = nil
                    if let url {
                        importSaveData(from: url)
                    }
                }
            }
        }
        .alert(deleteConfirmationTitle, isPresented: $isDeleteConfirmationPresented) {
            Button("Delete", role: .destructive) {
                if let deletion = pendingDeletion { performDeletion(deletion) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    // MARK: - Cards

    private func card<Content: View>(title: LocalizedStringKey,
                                     systemImage: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func statRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
    }

    private func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Game picker: every game in this build's library, whatever the runtime is
    /// doing, plus "No game" and "Restore default".
    private var gameCard: some View {
        card(title: "Game", systemImage: "gamecontroller.fill") {
            Menu {
                ForEach(library.entries) { entry in
                    Button {
                        selectGame(entry.titleID, persist: true, reload: true)
                    } label: {
                        if entry.titleID == selectedTitleID {
                            Label(entry.title, systemImage: "checkmark")
                        } else {
                            Text(entry.title)
                        }
                    }
                    .accessibilityIdentifier("save-manager-game-\(entry.titleID)")
                }
                if !library.entries.isEmpty { Divider() }
                Button {
                    selectGame(nil, persist: true, reload: true)
                } label: {
                    Label("No game", systemImage: selectedTitleID == nil ? "checkmark" : "minus.circle")
                }
                .accessibilityIdentifier("save-manager-game-none")
                Button {
                    restoreDefaultSelection()
                } label: {
                    Label("Restore default", systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier("save-manager-game-default")
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedEntry?.title ?? L10n.tr("No game selected"))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = selectedGameDetail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("save-manager-game-picker")
            if library.entries.isEmpty {
                emptyHint("No games in this build yet")
            }
        }
    }

    private var summaryCard: some View {
        card(title: "Summary", systemImage: "externaldrive.fill") {
            if selectedEntry == nil {
                emptyHint("Select a game above to manage its saves.")
            } else {
                statRow("Battery saves", L10n.format("%@ · %@", L10n.fileCount(files.count), StorageFormat.size(batterySaveBytes)))
                statRow("Save states", L10n.format("%@ · %@", L10n.slotCount(savedSlotCount, of: SaveStateSupport.slotCount), StorageFormat.size(saveStateBytes)))
                statRow("App storage", snapshot.totalText)
            }
        }
    }

    private var batterySaveCard: some View {
        card(title: "Battery saves", systemImage: "sdcard.fill") {
            if selectedEntry == nil {
                emptyHint("Select a game above to manage its battery saves.")
            } else {
                if files.isEmpty {
                    emptyHint("No battery save data yet. Save from the game's own menu and the files appear here.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(files) { file in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.fill")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text([file.folder, StorageFormat.size(file.bytes), StorageFormat.date(file.modified)]
                                            .filter { !$0.isEmpty }
                                            .joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Menu {
                                    Button { share(file) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                                    if canChangeBatterySaves {
                                        Button(role: .destructive) { requestDeletion(.batterySave(file)) } label: { Label("Delete", systemImage: "trash") }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                }
                            }
                            if file.id != files.last?.id { Divider() }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button { exportArchive() } label: {
                        Label("Export ZIP", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(files.isEmpty || isBusy)
                    .accessibilityIdentifier("save-data-export")

                    Button { sheet = .importPicker } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canChangeBatterySaves)
                    .accessibilityIdentifier("save-data-import")
                }

                emptyHint("A backup is a ZIP archive of the files above; importing one merges its files back.")
                if model.isRuntimeActive {
                    emptyHint("Exit to the home page before importing or deleting save data: the running game may hold these files open.")
                }
            }
        }
    }

    private var saveStateCard: some View {
        card(title: "Save states", systemImage: "camera.on.rectangle") {
            if selectedEntry == nil {
                emptyHint("Select a game above to manage its saves.")
            } else {
                ForEach(displayedSlots) { slot in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(slot.title)
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 8)
                            Text(slot.detail)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            stateButton("Save", systemImage: "camera.on.rectangle", enabled: canSaveState) {
                                saveState(slot: slot.number)
                            }
                            stateButton("Load", systemImage: "arrow.uturn.backward", enabled: canLoadState(slot: slot.number)) {
                                loadState(slot: slot.number)
                            }
                            stateButton("Delete", systemImage: "trash", enabled: slot.exists && !stateOperationBusy) {
                                requestDeletion(.state(slot.number))
                            }
                        }
                    }
                    .accessibilityIdentifier("save-state-slot-\(slot.number)")
                    if slot.id != displayedSlots.last?.id { Divider() }
                }
                saveStateStatus
                emptyHint("Loading a state restores that point and continues the same game session.")
            }
        }
    }

    private func stateButton(_ title: LocalizedStringKey,
                             systemImage: String,
                             enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
    }

    @ViewBuilder
    private var saveStateStatus: some View {
        if isSelectedGameRunning && saveStates.busy {
            HStack(spacing: 8) {
                ProgressView()
                Text(saveStates.statusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .accessibilityIdentifier("save-state-progress")
        } else if isSelectedGameRunning, let error = saveStates.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("save-state-error")
        } else if !isSelectedGameRunning {
            emptyHint("Start this game to save or load a state.")
        }
    }

    @ViewBuilder
    private var messagesCard: some View {
        if busyMessage != nil || statusMessage != nil || errorMessage != nil {
            card(title: "Messages", systemImage: "text.bubble") {
                if let busyMessage {
                    HStack(spacing: 8) { ProgressView(); Text(busyMessage).font(.footnote).foregroundColor(.secondary) }
                }
                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundColor(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Game selection

    /// The game the page manages: the picker's current entry, nil for "No game".
    private var selectedEntry: GameEntry? {
        guard let selectedTitleID else { return nil }
        return library.entries.first { $0.titleID == selectedTitleID }
    }

    /// Save namespace (the title ID by default) of the selected game's save-data
    /// and save-state folders; nil when no game is selected.
    private var namespace: String? { selectedEntry?.saveNamespace }

    /// True when the selected game is the one the runtime has loaded: only then
    /// can a save state be written or restored.
    private var isSelectedGameRunning: Bool {
        guard model.isRuntimeLoaded,
              let selectedTitleID,
              let current = model.currentGame else { return false }
        return current.titleID == selectedTitleID
    }

    /// Publisher and game-data size of the selected game, with the library's
    /// "data missing" state when the launcher has not pushed the data yet.
    private var selectedGameDetail: String? {
        guard let selectedEntry else { return nil }
        var parts: [String] = []
        if let publisher = selectedEntry.publisher, !publisher.isEmpty {
            parts.append(publisher)
        }
        if let bytes = selectedEntry.romBytes {
            parts.append(StorageFormat.size(bytes))
        }
        if !selectedEntry.hasPushedData && !selectedEntry.isLegacyBundled {
            parts.append(L10n.tr("Game data missing"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Opens the page with a sensible game selected: the running game when the
    /// page comes from the in-game menu, else the game managed last time (when
    /// it is still in the library), else the first game. A remembered "No game"
    /// stays empty.
    private func resolveDefaultSelection() {
        let entries = library.entries
        if model.isRuntimeLoaded,
           let running = model.currentGame,
           entries.contains(where: { $0.titleID == running.titleID }) {
            selectGame(running.titleID, persist: true, reload: false)
            return
        }
        if let remembered = UserDefaults.standard.string(forKey: Self.selectionDefaultsKey) {
            if remembered.isEmpty {
                selectGame(nil, persist: false, reload: false)
                return
            }
            if entries.contains(where: { $0.titleID == remembered }) {
                selectGame(remembered, persist: false, reload: false)
                return
            }
        }
        selectGame(entries.first?.titleID, persist: true, reload: false)
    }

    private func selectGame(_ titleID: String?, persist: Bool, reload: Bool) {
        selectedTitleID = titleID
        if persist {
            UserDefaults.standard.set(titleID ?? "", forKey: Self.selectionDefaultsKey)
        }
        saveStates.clearMessages()
        errorMessage = nil
        statusMessage = nil
        if reload { refresh() }
    }

    /// "Restore default": the running game when one is loaded, else the first
    /// game in the library.
    private func restoreDefaultSelection() {
        let running = model.isRuntimeLoaded ? model.currentGame : nil
        let titleID = running.flatMap { running in
            library.entries.first { $0.titleID == running.titleID }?.titleID
        } ?? library.entries.first?.titleID
        selectGame(titleID, persist: true, reload: true)
    }

    // MARK: - State helpers

    /// Slots shown for the selected game: the live list of the running game
    /// (SaveStateSupport), or the slot files on disk while it is not running.
    private var displayedSlots: [SaveStateSlot] {
        isSelectedGameRunning ? saveStates.slots : offlineSlots
    }

    private var isBusy: Bool { busyMessage != nil }

    /// The runtime may hold save files open; import and delete wait until it is
    /// released (the Save Manager is reachable from the home page too).
    private var canChangeBatterySaves: Bool { !model.isRuntimeActive && !isBusy }

    /// Writing a state needs the runtime of exactly this game: it serializes the
    /// live console, so it cannot target a game that is not loaded.
    private var canSaveState: Bool { isSelectedGameRunning && saveStates.canSave }

    private func canLoadState(slot number: Int) -> Bool {
        isSelectedGameRunning && saveStates.canLoad(slot: number)
    }

    /// A save/load/delete is running (the running game's live list tracks its
    /// own operations; deleting a non-running game's slot is a page operation).
    private var stateOperationBusy: Bool {
        isSelectedGameRunning ? saveStates.busy : isBusy
    }

    private var batterySaveBytes: UInt64 { SaveDataStore.totalBytes(of: files) }

    private var saveStateBytes: UInt64 { displayedSlots.reduce(0) { $0 + $1.bytes } }

    private var savedSlotCount: Int { displayedSlots.filter { $0.exists }.count }

    private var deleteConfirmationTitle: String {
        guard let pendingDeletion else { return L10n.tr("Delete?") }
        switch pendingDeletion {
        case .batterySave:
            return L10n.tr("Delete this save file?")
        case .state(let number):
            return L10n.format("Delete Slot %ld?", number)
        }
    }

    private var deleteConfirmationMessage: String {
        guard let pendingDeletion else { return "" }
        switch pendingDeletion {
        case .batterySave(let file):
            return L10n.format("“%@” is removed from this device. This cannot be undone.", file.name)
        case .state(let number):
            return L10n.format("The instant save state in Slot %ld is removed. The game's own battery saves are not touched.", number)
        }
    }

    // MARK: - Actions

    /// Re-reads the selected game's battery saves, the slots it is not running
    /// at the moment (the running game's slots come from SaveStateSupport), and
    /// the container usage.
    private func refresh() {
        if isSelectedGameRunning { saveStates.refresh() }
        let namespace = self.namespace
        offlineSlots = isSelectedGameRunning ? [] : SaveManagerView.readSlotFiles(namespace: namespace)
        DispatchQueue.global(qos: .userInitiated).async {
            let files = namespace.map { SaveDataStore.batterySaveFiles(namespace: $0) } ?? []
            let snapshot = StorageInspector.snapshot()
            DispatchQueue.main.async {
                // The user may have picked another game while the folder was
                // read: never show one game's files under another game's header.
                guard self.namespace == namespace else { return }
                self.files = files
                self.snapshot = snapshot
            }
        }
    }

    /// Slot files of a game with no running runtime. SaveStateSupport only lists
    /// the loaded game's slots, so the page reads the same per-namespace slot
    /// paths (documents/states/<namespace>/slot<N>.bin) from disk itself; the
    /// file format is untouched.
    private static func readSlotFiles(namespace: String?) -> [SaveStateSlot] {
        guard let namespace else { return [] }
        return (1...SaveStateSupport.slotCount).map { number in
            let url = SaveStateSupport.slotURL(namespace: namespace, slot: number)
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

    private func requestDeletion(_ deletion: PendingDeletion) {
        pendingDeletion = deletion
        isDeleteConfirmationPresented = true
    }

    private func performDeletion(_ deletion: PendingDeletion) {
        pendingDeletion = nil
        errorMessage = nil
        statusMessage = nil
        switch deletion {
        case .batterySave(let file):
            guard let namespace else { return }
            do {
                try SaveDataStore.remove(file, namespace: namespace)
                statusMessage = L10n.format("Deleted “%@”.", file.name)
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .state(let number):
            if isSelectedGameRunning {
                saveStates.delete(slot: number) { error in
                    if let error {
                        errorMessage = error.message
                    }
                }
            } else {
                deleteStateFile(slot: number)
            }
        }
    }

    /// Deletes a slot file of a game that is not running; the runtime is not
    /// involved, so this works from Settings without starting the game.
    private func deleteStateFile(slot number: Int) {
        guard let namespace, !isSelectedGameRunning else { return }
        let slotTitle = L10n.format("Slot %ld", number)
        busyMessage = L10n.format("Deleting %@…", slotTitle)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                let url = SaveStateSupport.slotURL(namespace: namespace, slot: number)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                failure = L10n.format("Could not delete %@: %@", slotTitle, error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.busyMessage = nil
                if let failure {
                    self.errorMessage = failure
                } else {
                    self.statusMessage = L10n.format("Deleted %@", slotTitle)
                    AppLog.log("[3ds2apple] save state: deleted slot %d", number)
                    self.refresh()
                }
            }
        }
    }

    private func saveState(slot number: Int) {
        guard isSelectedGameRunning else { return }
        saveStates.save(slot: number)
    }

    private func loadState(slot number: Int) {
        guard isSelectedGameRunning else { return }
        saveStates.load(slot: number) { result in
            if case .success = result { onLoadStateCompleted?() }
        }
    }

    private func share(_ file: BatterySaveFile) {
        guard let namespace else { return }
        sheet = .share(SaveDataStore.batterySaveURL(for: file, namespace: namespace))
    }

    private func exportArchive() {
        guard let namespace, !isBusy else { return }
        errorMessage = nil
        statusMessage = nil
        busyMessage = L10n.tr("Packing battery saves into a ZIP archive…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try SaveDataStore.exportArchive(namespace: namespace)
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.statusMessage = L10n.tr("The backup is ready to share.")
                    self.sheet = .share(url)
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func importSaveData(from url: URL) {
        guard let namespace, !model.isRuntimeActive, !isBusy else { return }
        errorMessage = nil
        statusMessage = nil
        busyMessage = L10n.tr("Importing battery saves…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try SaveDataStore.importSaveData(from: url, namespace: namespace)
                let skipped = summary.skippedEntries
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    var message = L10n.format(
                        "Imported %@ (%@).",
                        L10n.fileCount(summary.fileCount),
                        StorageFormat.size(summary.bytes)
                    )
                    if skipped > 0 {
                        message += " "
                            + L10n.format("Skipped %ld archive metadata entries.", skipped)
                    }
                    self.statusMessage = message
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
