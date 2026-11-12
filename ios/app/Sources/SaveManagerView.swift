//
//  SaveManagerView.swift
//  3ds2apple
//
//  Save manager for the current game: the battery save data the runtime has
//  written into Documents/data/<game>, and the three instant save-state slots in
//  Documents/states/<game>.
//
//  Battery saves can be exported as a ZIP archive through the share sheet,
//  imported back from a ZIP or from single files, and deleted. Import and delete
//  are only offered while no game is running: the runtime may hold those files
//  open. Save-state slots can be written, restored and deleted here too; a
//  successful load resumes the game when the page was opened from the in-game
//  menu.
//

import Foundation
import SwiftUI
import UIKit

struct SaveManagerView: View {
    @ObservedObject var model: ROMSession
    @ObservedObject var saveStates: SaveStateSupport
    /// Called after a save-state load succeeded. The game view passes a closure
    /// that closes the menu and resumes the restored session; the page is also
    /// reachable from the home page, where nothing needs resuming.
    var onLoadStateCompleted: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var files: [BatterySaveFile] = []
    @State private var snapshot = StorageSnapshot.empty
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var sheet: SaveManagerSheet?
    @State private var pendingDeletion: PendingDeletion?
    @State private var isDeleteConfirmationPresented = false

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
        List {
            summarySection
            batterySaveSection
            saveStateSection
            archiveMessagesSection
        }
        .navigationTitle("Save Manager")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("save-manager-refresh")
            }
        }
        .onAppear {
            saveStates.clearMessages()
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
                if let deletion = pendingDeletion {
                    performDeletion(deletion)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            infoRow("Game", model.lastROM?.name ?? "No game imported")
            infoRow(
                "Battery saves",
                "\(files.count) file\(files.count == 1 ? "" : "s") · \(StorageFormat.size(batterySaveBytes))"
            )
            infoRow(
                "Save states",
                "\(savedSlotCount) of \(SaveStateSupport.slotCount) slots · \(StorageFormat.size(saveStates.totalBytes))"
            )
            infoRow("App storage", snapshot.totalText)
        } header: {
            Text("Summary")
        } footer: {
            Text("Battery saves are written by the game runtime into "
                 + "Documents/data/<game>. Instant save slots are stored in "
                 + "Documents/states/<game>. Both stay on this device.")
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Battery saves

    private var batterySaveSection: some View {
        Section {
            if gameName == nil {
                Text("Import a game first: battery saves are listed per game.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if files.isEmpty {
                Text("No battery save data yet. Save from the game's own menu and "
                     + "the files appear here.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(files) { file in
                    batterySaveRow(file)
                }
            }
            batterySaveActions
        } header: {
            Text("Battery saves")
        } footer: {
            Text("A backup is a ZIP archive of the files above. Importing one merges "
                 + "its files back into this game's save-data folder.")
        }
    }

    private func batterySaveRow(_ file: BatterySaveFile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                if !file.folder.isEmpty {
                    Text(file.folder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(StorageFormat.size(file.bytes))
                Text(StorageFormat.date(file.modified))
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canChangeBatterySaves {
                Button(role: .destructive) {
                    requestDeletion(.batterySave(file))
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button {
                share(file)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var batterySaveActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                exportArchive()
            } label: {
                Label("Export battery saves as a ZIP…", systemImage: "square.and.arrow.up")
            }
            .disabled(files.isEmpty || isBusy)
            .accessibilityIdentifier("save-data-export")

            Button {
                sheet = .importPicker
            } label: {
                Label("Import battery saves from a ZIP or file…", systemImage: "square.and.arrow.down")
            }
            .disabled(gameName == nil || !canChangeBatterySaves)
            .accessibilityIdentifier("save-data-import")

            if model.isRuntimeActive {
                Text("Exit to the home page before importing or deleting save data: "
                     + "the running game may hold these files open.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Save states

    private var saveStateSection: some View {
        Section {
            ForEach(saveStates.slots) { slot in
                saveStateRow(slot)
            }
            saveStateStatus
        } header: {
            HStack {
                Text("Save states")
                Spacer()
                Text(StorageFormat.size(saveStates.totalBytes))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("A save state is a snapshot of the whole console, taken between "
                 + "frames. Loading one restores that point, drops the audio buffered "
                 + "before it and continues the same game session.")
        }
    }

    private func saveStateRow(_ slot: SaveStateSlot) -> some View {
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
                stateButton(
                    "Save",
                    systemImage: "camera.on.rectangle",
                    enabled: saveStates.canSave
                ) {
                    saveStates.save(slot: slot.number)
                }
                stateButton(
                    "Load",
                    systemImage: "arrow.uturn.backward",
                    enabled: saveStates.canLoad(slot: slot.number)
                ) {
                    saveStates.load(slot: slot.number) { result in
                        if case .success = result {
                            onLoadStateCompleted?()
                        }
                    }
                }
                stateButton(
                    "Delete",
                    systemImage: "trash",
                    enabled: slot.exists && !saveStates.busy
                ) {
                    requestDeletion(.state(slot.number))
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("save-state-slot-\(slot.number)")
    }

    private func stateButton(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
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
        if saveStates.busy {
            HStack(spacing: 8) {
                ProgressView()
                Text(saveStates.statusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .accessibilityIdentifier("save-state-progress")
        } else if let error = saveStates.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("save-state-error")
        } else if !saveStates.isRuntimeLoaded {
            Text("Load a game to save or restore a state. Slots already on disk "
                 + "can be deleted here.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Messages

    @ViewBuilder
    private var archiveMessagesSection: some View {
        if busyMessage != nil || statusMessage != nil || errorMessage != nil {
            Section {
                if let busyMessage {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(busyMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
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

    // MARK: - State helpers

    private var gameName: String? { model.lastROM?.name }

    private var isBusy: Bool { busyMessage != nil }

    /// The runtime may hold save files open; import and delete wait until it is
    /// released (the Save Manager is reachable from the home page too).
    private var canChangeBatterySaves: Bool { !model.isRuntimeActive && !isBusy }

    private var batterySaveBytes: UInt64 { SaveDataStore.totalBytes(of: files) }

    private var savedSlotCount: Int {
        saveStates.slots.filter { $0.exists }.count
    }

    private var deleteConfirmationTitle: String {
        guard let pendingDeletion else { return "Delete?" }
        switch pendingDeletion {
        case .batterySave:
            return "Delete this save file?"
        case .state(let number):
            return "Delete Slot \(number)?"
        }
    }

    private var deleteConfirmationMessage: String {
        guard let pendingDeletion else { return "" }
        switch pendingDeletion {
        case .batterySave(let file):
            return "“\(file.name)” is removed from this device. This cannot be undone."
        case .state(let number):
            return "The instant save state in Slot \(number) is removed. "
                + "The game's own battery saves are not touched."
        }
    }

    // MARK: - Actions

    private func refresh() {
        saveStates.refresh()
        let gameName = self.gameName
        DispatchQueue.global(qos: .userInitiated).async {
            let files = gameName.map { SaveDataStore.batterySaveFiles(forROMName: $0) } ?? []
            let snapshot = StorageInspector.snapshot()
            DispatchQueue.main.async {
                self.files = files
                self.snapshot = snapshot
            }
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
            guard let gameName else { return }
            do {
                try SaveDataStore.remove(file, forROMName: gameName)
                statusMessage = "Deleted “\(file.name)”."
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        case .state(let number):
            saveStates.delete(slot: number) { error in
                if let error {
                    errorMessage = error.message
                }
            }
        }
    }

    private func share(_ file: BatterySaveFile) {
        guard let gameName else { return }
        sheet = .share(SaveDataStore.batterySaveURL(for: file, forROMName: gameName))
    }

    private func exportArchive() {
        guard let gameName, !isBusy else { return }
        errorMessage = nil
        statusMessage = nil
        busyMessage = "Packing battery saves into a ZIP archive…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try SaveDataStore.exportArchive(forROMName: gameName)
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.statusMessage = "The backup is ready to share."
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
        guard let gameName, !model.isRuntimeActive, !isBusy else { return }
        errorMessage = nil
        statusMessage = nil
        busyMessage = "Importing battery saves…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try SaveDataStore.importSaveData(from: url, forROMName: gameName)
                let skipped = summary.skippedEntries
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.statusMessage = "Imported \(summary.fileCount) "
                        + "file\(summary.fileCount == 1 ? "" : "s") "
                        + "(\(StorageFormat.size(summary.bytes)))"
                        + (skipped > 0 ? ", skipped \(skipped) archive metadata entries." : ".")
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
