//
//  SaveArchivePicker.swift
//  3ds2apple
//
//  Files picker for save-data import: a ZIP backup of the battery save data, or
//  single save files. The picker copies the selection into the app's temporary
//  directory (`asCopy: true`), so reading it never depends on another app's
//  container and the file can be processed off the main thread.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker for a save-data import. `onPick`
/// receives the selected file, or nil when the user cancels.
struct SaveArchivePicker: UIViewControllerRepresentable {
    private let onPick: (URL?) -> Void

    init(onPick: @escaping (URL?) -> Void) {
        self.onPick = onPick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // ZIP covers archives made by this app, the Files app or a desktop
        // tool; public.data covers a single save file picked on its own.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.zip, .data],
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
