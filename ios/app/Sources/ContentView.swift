//
//  ContentView.swift
//  3ds2apple
//
//  I2-T1: ROM import UI on top of the I1 shell. The frame loop is not wired
//  yet (I2-T2 owns zk_run_frame), so a loaded ROM only proves that zk_create()
//  succeeded and a runtime handle is alive.
//

import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = ROMSession()
    @State private var isPickerPresented = false

    /// Screen geometry is read from the linked static library.
    private let topScreen = ZakuroScreen(which: 0)
    private let bottomScreen = ZakuroScreen(which: 1)

    /// Explicit internal init: the synthesized memberwise init would be
    /// file-private because the stored properties are private, and App.swift
    /// constructs ContentView() from another file.
    init() {}

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                romCard
                runtimeCard
                footer
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $isPickerPresented) {
            ROMDocumentPicker { url in
                isPickerPresented = false
                if let url {
                    model.importROM(from: url)
                }
            }
        }
        .onAppear(perform: logRuntimeProbe)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            Text("3ds2apple")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .accessibilityIdentifier("app-title")
            Text("Nintendo 3DS, natively on iPhone")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 24)
    }

    private var romCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            romStatus
            romActions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityIdentifier("rom-card")
    }

    @ViewBuilder
    private var romStatus: some View {
        switch model.phase {
        case .idle:
            Label("No ROM loaded", systemImage: "doc.badge.plus")
                .font(.headline)
            Text("Import a decrypted .3ds or .cci ROM from Files. The ROM is copied "
                 + "into this app's Documents folder and stays on the device.")
                .font(.footnote)
                .foregroundColor(.secondary)
        case .importing(let name):
            statusRow(
                title: "Importing \(name)…",
                detail: "Copying the file into the app container. Large ROMs take a while."
            )
        case .starting(let name):
            statusRow(
                title: "Starting Zakuro…",
                detail: "Loading \(name). zk_create() can take several seconds."
            )
        case .loaded(let name):
            Label("Loaded: \(name)", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundColor(.green)
                .accessibilityIdentifier("rom-loaded")
            Text("The runtime is initialised. The frame loop arrives in I2-T2.")
                .font(.footnote)
                .foregroundColor(.secondary)
        case .failed(let message):
            Label("Could not load ROM", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.red)
                .accessibilityIdentifier("rom-error")
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var romActions: some View {
        switch model.phase {
        case .idle, .failed:
            Button {
                isPickerPresented = true
            } label: {
                Label("Import ROM…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("import-rom")

            if let last = model.lastROM {
                Button("Load “\(last.name)”") {
                    model.loadLastROM()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }

            if case .failed = model.phase {
                Button("Dismiss") {
                    model.dismissFailure()
                }
                .buttonStyle(.borderless)
                .font(.footnote)
            }
        case .importing, .starting:
            EmptyView()
        case .loaded:
            Button {
                isPickerPresented = true
            } label: {
                Label("Change ROM…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(role: .destructive) {
                model.unload()
            } label: {
                Label("Unload ROM", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Zakuro runtime", systemImage: "cpu")
                .font(.headline)

            HStack {
                Text("Upper screen")
                Spacer()
                Text(topScreen.label)
                    .monospacedDigit()
            }
            HStack {
                Text("Lower screen")
                Spacer()
                Text(bottomScreen.label)
                    .monospacedDigit()
            }
            Text("zk_screen_width(0) = \(topScreen.width)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("zk-screen-width")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var footer: some View {
        Text("I2 · ROM import · interpreter only, no JIT")
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func statusRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView()
                Text(title)
                    .font(.headline)
            }
            Text(detail)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Diagnostics

    /// One line in `idevicesyslog` that proves the static library was linked
    /// and called on device, plus the ROM state at launch (I2 acceptance).
    private func logRuntimeProbe() {
        NSLog(
            "[3ds2apple] zk_screen_width(0)=%u zk_screen_height(0)=%u "
                + "zk_screen_width(1)=%u zk_screen_height(1)=%u",
            topScreen.width,
            topScreen.height,
            bottomScreen.width,
            bottomScreen.height
        )
        if let last = model.lastROM {
            NSLog("[3ds2apple] last imported ROM: %@", last.relativePath)
        } else {
            NSLog("[3ds2apple] no ROM imported yet")
        }
    }
}

/// One 3DS screen as reported by the linked static library.
private struct ZakuroScreen {
    let width: UInt32
    let height: UInt32

    init(which: UInt32) {
        self.width = zk_screen_width(which)
        self.height = zk_screen_height(which)
    }

    var label: String { "\(width) × \(height)" }
}
