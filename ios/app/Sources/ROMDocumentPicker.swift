//
//  ROMDocumentPicker.swift
//  3ds2apple
//
//  I2-T1: thin SwiftUI wrapper around UIDocumentPickerViewController.
//
//  Files are opened in place (`asCopy: false`) and copied by ROMSession, so a
//  multi-GB ROM is not duplicated by the system before we copy it into the app
//  container.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker. `onPick` receives the selected URL, or
/// `nil` when the user cancels.
struct ROMDocumentPicker: UIViewControllerRepresentable {
    private let onPick: (URL?) -> Void

    init(onPick: @escaping (URL?) -> Void) {
        self.onPick = onPick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .3ds / .cci have no registered UTTypes; public.data covers them.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
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
