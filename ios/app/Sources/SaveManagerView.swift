//
//  SaveManagerView.swift
//  3ds2apple
//
//  Save manager: what the runtime has written into the per-game data directory
//  (battery saves) and how much space the app container uses.
//
//  The page is read-only in this build: instant save states and save import /
//  export come with the runtime's save-state support. It never deletes or moves
//  a save file.
//

import Foundation
import SwiftUI
import UIKit

struct SaveManagerView: View {
    @ObservedObject var model: ROMSession

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SaveDataEntry] = []
    @State private var snapshot = StorageSnapshot.empty

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Game")
                    Spacer()
                    Text(model.lastROM?.name ?? "No game loaded")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Text("Save data")
                    Spacer()
                    Text(StorageFormat.size(snapshot.saveDataBytes))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Files")
                    Spacer()
                    Text("\(entries.count)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("Battery saves are written by the game runtime into the app's "
                     + "Documents/data folder and stay on this device.")
            }

            Section {
                if entries.isEmpty {
                    Text("No save data yet. Start a game and save from its own menu; "
                         + "the files appear here.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.subheadline)
                            HStack(spacing: 8) {
                                if !entry.game.isEmpty {
                                    Text(entry.game)
                                }
                                Text(StorageFormat.size(entry.bytes))
                                Text(StorageFormat.date(entry.modified))
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Save files")
            }

            Section {
                Text("Save data import and export are not available in this build.")
                Text("Instant save states are not available in this build; the in-game "
                     + "menu labels the buttons as unavailable.")
            } header: {
                Text("Not available in this build")
            }
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
            refresh()
        }
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let entries = StorageInspector.saveDataEntries()
            let snapshot = StorageInspector.snapshot()
            DispatchQueue.main.async {
                self.entries = entries
                self.snapshot = snapshot
            }
        }
    }
}
