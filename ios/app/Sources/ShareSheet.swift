//
//  ShareSheet.swift
//  3ds2apple
//
//  Small UIKit bridge for exporting the diagnostics report with the system
//  share sheet. No file leaves the device unless the user picks a destination.
//

import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
