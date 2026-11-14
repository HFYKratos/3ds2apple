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
//  User-facing text: static SwiftUI literals localize through
//  Localizable.strings; strings built at run time go through L10n.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

    private var summaryCard: some View {
        card(title: "Summary", systemImage: "externaldrive.fill") {
            Text(gameName ?? L10n.tr("No game imported"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if gameName != nil {
                statRow("Battery saves", L10n.format("%@ · %@", L10n.fileCount(files.count), StorageFormat.size(batterySaveBytes)))
                statRow("Save states", L10n.format("%@ · %@", L10n.slotCount(savedSlotCount, of: SaveStateSupport.slotCount), StorageFormat.size(saveStates.totalBytes)))
                statRow("App storage", snapshot.totalText)
            }
        }
    }

    private var batterySaveCard: some View {
        card(title: "Battery saves", systemImage: "sdcard.fill") {
            if gameName == nil {
                emptyHint("Import a game first: battery saves are listed per game.")
            } else if files.isEmpty {
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
                .disabled(gameName == nil || !canChangeBatterySaves)
                .accessibilityIdentifier("save-data-import")
            }

            emptyHint("A backup is a ZIP archive of the files above; importing one merges its files back.")
            if model.isRuntimeActive {
                emptyHint("Exit to the home page before importing or deleting save data: the running game may hold these files open.")
            }
        }
    }

    private var saveStateCard: some View {
        card(title: "Save states", systemImage: "camera.on.rectangle") {
            ForEach(saveStates.slots) { slot in
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
                        stateButton("Save", systemImage: "camera.on.rectangle", enabled: saveStates.canSave) {
                            saveStates.save(slot: slot.number)
                        }
                        stateButton("Load", systemImage: "arrow.uturn.backward", enabled: saveStates.canLoad(slot: slot.number)) {
                            saveStates.load(slot: slot.number) { result in
                                if case .success = result { onLoadStateCompleted?() }
                            }
                        }
                        stateButton("Delete", systemImage: "trash", enabled: slot.exists && !saveStates.busy) {
                            requestDeletion(.state(slot.number))
                        }
                    }
                }
                .accessibilityIdentifier("save-state-slot-\(slot.number)")
                if slot.id != saveStates.slots.last?.id { Divider() }
            }
            saveStateStatus
            emptyHint("Loading a state restores that point and continues the same game session.")
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
            emptyHint("Load a game to save or restore a state. Slots already on disk can be deleted here.")
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
                statusMessage = L10n.format("Deleted “%@”.", file.name)
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
        busyMessage = L10n.tr("Packing battery saves into a ZIP archive…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try SaveDataStore.exportArchive(forROMName: gameName)
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
        guard let gameName, !model.isRuntimeActive, !isBusy else { return }
        errorMessage = nil
        statusMessage = nil
        busyMessage = L10n.tr("Importing battery saves…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try SaveDataStore.importSaveData(from: url, forROMName: gameName)
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
