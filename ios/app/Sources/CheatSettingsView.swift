//
//  CheatSettingsView.swift
//  3ds2apple
//
//  Settings -> Cheats: the player's own cheat codes, per game.
//
//  The code file is Documents/Cheats/<TITLEID>.txt (CheatManager); this page
//  lists the library's games with their file summary and opens one game's
//  detail page, where the file can be imported from the Files app, pasted and
//  edited as text, exported with the share sheet and switched per entry. Every
//  edit is validated against the runtime's limits before it is written.
//
//  The app ships no code database and downloads nothing: only the user's own
//  file content is shown. Nothing here names a commercial title; the rows come
//  from the player's own library.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Settings -> Cheats

/// One row per library game; the row's subtitle is that game's file summary.
struct CheatsSettingsPage: View {
    @ObservedObject private var library = GameLibrary.shared
    @State private var summaries: [String: String] = [:]

    var body: some View {
        SettingsPageScaffold(title: "Cheats") {
            Section {
                if library.entries.isEmpty {
                    Text("No games are in this build yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.entries) { entry in
                        NavigationLink {
                            CheatGamePage(titleID: entry.titleID, title: entry.title)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(.tint)
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(summaries[entry.titleID] ?? L10n.tr("No cheat file"))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .accessibilityIdentifier("settings-cheats-game-\(entry.titleID)")
                    }
                }
            } header: {
                Text("Games")
            } footer: {
                Text("Cheat codes are your own text files in Documents/Cheats/<TITLEID>.txt, in the Citra/Azahar format: a [name] line, an optional *citra_enabled line, then XXXXXXXX YYYYYYYY code lines. The app ships no codes and downloads nothing; import a file from the Files app or paste your own text. Only data patches are supported: codes that rewrite the game's code can slow an AOT build down. Back up your saves before using codes.")
            }
        }
        .onAppear { reloadSummaries() }
    }

    private func reloadSummaries() {
        var next: [String: String] = [:]
        for entry in library.entries {
            next[entry.titleID] = CheatManager.summaryLine(titleID: entry.titleID)
        }
        summaries = next
    }
}

// MARK: - One game's cheat file

/// One game's cheat file: the file facts, the ways to import/edit/export it and
/// the entries with their switches.
struct CheatGamePage: View {
    let titleID: String
    let title: String

    @State private var document: CheatDocument?
    @State private var snapshot: CheatFileSnapshot?
    @State private var isDirty = false
    @State private var statusMessage: String?
    @State private var alertMessage: String?
    @State private var isEditorPresented = false
    @State private var isImporterPresented = false
    @State private var shareItem: CheatShareItem?

    var body: some View {
        SettingsPageScaffold(title: LocalizedStringKey(title)) {
            fileSection
            actionsSection
            entriesSection
            issuesSection
            saveSection
        }
        .onAppear { reloadFromDisk() }
        .sheet(isPresented: $isEditorPresented) {
            CheatTextEditorSheet(initialText: document?.text ?? snapshot?.text ?? "") { text in
                applyEditedText(text)
            }
        }
        .sheet(isPresented: $isImporterPresented) {
            CheatFilePicker { url in
                isImporterPresented = false
                if let url { importFile(url) }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(L10n.tr("Cheat codes"), isPresented: alertPresented) {
            Button(L10n.tr("OK"), role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    // MARK: Sections

    private var fileSection: some View {
        Section {
            SettingsInfoRow(
                title: "Cheat file",
                value: snapshot?.fileName ?? CheatManager.fileURL(titleID: titleID).lastPathComponent
            )
            SettingsInfoRow(title: "Cheats", value: summaryText)
            if let bytes = snapshot?.bytes, snapshot?.exists == true {
                SettingsInfoRow(title: "Size", value: StorageFormat.size(UInt64(bytes)))
            }
            if isDirty {
                Text("Changes are not saved yet.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("cheats-unsaved")
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("cheats-status")
            }
        } header: {
            Text("File")
        } footer: {
            if snapshot?.exists != true {
                Text("No cheat file for this game yet. Import one from the Files app or paste codes with Edit text.")
            } else {
                Text("The file is Documents/Cheats/<TITLEID>.txt. It stays on this device and is not part of a game's save data.")
            }
        }
    }

    private var actionsSection: some View {
        Section {
            SettingsActionRow(
                title: "Import file…",
                description: "Copy a Citra/Azahar text file from the Files app.",
                systemImage: "square.and.arrow.down",
                identifier: "cheats-import"
            ) {
                isImporterPresented = true
            }
            SettingsActionRow(
                title: "Edit text…",
                description: "Paste or edit the cheat text directly.",
                systemImage: "text.cursor",
                identifier: "cheats-edit"
            ) {
                isEditorPresented = true
            }
            SettingsActionRow(
                title: "Export file",
                description: "Share this game's cheat file.",
                systemImage: "square.and.arrow.up",
                identifier: "cheats-export",
                isEnabled: document != nil
            ) {
                exportFile()
            }
            SettingsActionRow(
                title: "Reload from disk",
                description: "Drop unsaved changes and read the file again.",
                systemImage: "arrow.clockwise",
                identifier: "cheats-reload"
            ) {
                reloadFromDisk()
            }
        } header: {
            Text("File actions")
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        Section {
            if let document, !document.entries.isEmpty {
                ForEach(document.entries.indices, id: \.self) { index in
                    cheatRow(document.entries[index], index: index)
                }
            } else if snapshot?.exists == true, snapshot?.readError == nil {
                Text("This file has no cheats with code lines yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("No cheat file for this game yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Cheats")
        }
    }

    @ViewBuilder
    private var issuesSection: some View {
        if let issues = snapshot?.limitIssues, !issues.isEmpty {
            Section {
                ForEach(issues.indices, id: \.self) { index in
                    Text(issues[index].localizedMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("File problems")
            } footer: {
                Text("The game runtime refuses a file past these limits, so this file cannot be loaded until it is fixed. Import a smaller file or edit it.")
            }
        }
        if let readError = snapshot?.readError {
            Section {
                Text(readError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("File problems")
            } footer: {
                Text("Replace the unreadable file by importing a UTF-8 text file or pasting the codes with Edit text.")
            }
        }
    }

    private var saveSection: some View {
        Section {
            SettingsActionRow(
                title: "Save",
                description: "Write the enabled switches into the cheat file.",
                systemImage: "square.and.arrow.down.on.square",
                identifier: "cheats-save",
                isEnabled: isDirty
            ) {
                save()
            }
        } footer: {
            Text("A saved file is read again when the game starts; a switch changed here does not affect a game that is already running (the in-game menu Cheats page does that).")
        }
    }

    // MARK: Rows

    private func cheatRow(_ entry: CheatEntry, index: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name.isEmpty ? L10n.tr("(unnamed)") : entry.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(entryDetailText(entry))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(isOn: enabledBinding(index: index)) {
                EmptyView()
            }
            .labelsHidden()
            .accessibilityLabel(Text(entry.name.isEmpty ? L10n.tr("(unnamed)") : entry.name))
        }
        .accessibilityIdentifier("cheats-entry-\(index)")
    }

    private func enabledBinding(index: Int) -> Binding<Bool> {
        Binding(
            get: { document?.entries[index].enabled ?? false },
            set: { enabled in
                guard var current = document, current.entries.indices.contains(index) else { return }
                current.entries[index].enabled = enabled
                document = current
                isDirty = true
                statusMessage = nil
            }
        )
    }

    // MARK: Actions

    private func reloadFromDisk() {
        let fresh = CheatManager.snapshot(titleID: titleID)
        snapshot = fresh
        document = fresh.document
        isDirty = false
        statusMessage = nil
    }

    private func save() {
        guard let document else { return }
        do {
            try CheatManager.write(document, titleID: titleID)
            reloadFromDisk()
            statusMessage = L10n.tr("Cheat file saved.")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func exportFile() {
        guard let text = document?.text ?? snapshot?.text else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(snapshot?.fileName ?? CheatManager.fileURL(titleID: titleID).lastPathComponent)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItem = CheatShareItem(url: url)
        } catch {
            alertMessage = L10n.format("Could not write the cheat file: %@", error.localizedDescription)
        }
    }

    /// The Files-app import: read the picked copy, validate it against the
    /// runtime's limits and replace this game's file.
    private func importFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= CheatDocument.maxFileBytes else {
                throw CheatFileError.limit(
                    CheatLimitIssue.fileTooLarge(bytes: data.count).localizedMessage
                )
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CheatFileError.notUTF8
            }
            let parsed = CheatDocument(text: text)
            let issues = parsed.limitIssues(fileBytes: data.count)
            guard issues.isEmpty else {
                throw CheatFileError.limit(issues.map(\.localizedMessage).joined(separator: " "))
            }
            try CheatManager.write(parsed, titleID: titleID)
            reloadFromDisk()
            statusMessage = L10n.tr("Cheat file imported.")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// The text editor's Save: parse, check the limits, write the file. Returns
    /// nil on success so the sheet closes, or the reason it stays open.
    private func applyEditedText(_ text: String) -> String? {
        let parsed = CheatDocument(text: text)
        let issues = parsed.limitIssues()
        if !issues.isEmpty {
            return issues.map(\.localizedMessage).joined(separator: " ")
        }
        do {
            try CheatManager.write(parsed, titleID: titleID)
            reloadFromDisk()
            statusMessage = L10n.tr("Cheat file saved.")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Text

    private var summaryText: String {
        if let error = snapshot?.readError {
            return error
        }
        guard let document, snapshot?.exists == true else {
            return L10n.tr("No cheat file")
        }
        return L10n.format("%ld cheats · %ld on", document.entries.count, document.enabledCount)
    }

    private func entryDetailText(_ entry: CheatEntry) -> String {
        var text = entry.codeLineCount == 1
            ? L10n.tr("1 code line")
            : L10n.format("%ld code lines", entry.codeLineCount)
        if entry.invalidLineCount > 0 {
            text += L10n.format(" · %ld lines not run", entry.invalidLineCount)
        }
        return text
    }
}

// MARK: - Text editor

/// The paste/edit sheet: a monospaced editor over the whole file. Save validates
/// the text against the runtime's limits before it writes anything.
struct CheatTextEditorSheet: View {
    let initialText: String
    /// Returns nil when the text was saved (the sheet then closes), or a
    /// user-facing reason to keep it open.
    let onSave: (String) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var errorMessage: String?

    init(initialText: String, onSave: @escaping (String) -> String?) {
        self.initialText = initialText
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("cheats-editor-text")
            }
            .padding(16)
            .navigationTitle(L10n.tr("Edit cheat text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Save")) {
                        if let error = onSave(text) {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("cheats-editor-save")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Paste a Citra/Azahar cheat file here: a [name] line, an optional *citra_enabled line, then XXXXXXXX YYYYYYYY code lines.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
    }
}

// MARK: - Files import

/// The Files-app picker for a cheat text file. The picker hands back a copy in
/// the app's temporary directory (asCopy), so reading it never depends on
/// another app's container.
struct CheatFilePicker: UIViewControllerRepresentable {
    private let onPick: (URL?) -> Void

    init(onPick: @escaping (URL?) -> Void) {
        self.onPick = onPick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.plainText, .data],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}

/// Share-sheet payload for a cheat file export.
private struct CheatShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
