//
//  ROMDocumentPicker.swift
//  3ds2apple
//
//  Thin SwiftUI wrapper around UIDocumentPickerViewController.
//
//  Files are opened in place (asCopy: false) and copied into the app container
//  by GameLibrary, so a multi-GB ROM is not duplicated by the system before the
//  import. Several files can be picked at once; the home page imports them one
//  after another.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker. "onPick" receives the selected URLs
/// (empty when the user cancels).
struct ROMDocumentPicker: UIViewControllerRepresentable {
    private let onPick: ([URL]) -> Void

    init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .3ds / .cci / .cia have no registered UTTypes; public.data covers them.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}
