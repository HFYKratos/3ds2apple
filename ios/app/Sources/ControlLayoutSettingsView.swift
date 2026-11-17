//
//  ControlLayoutSettingsView.swift
//  3ds2apple
//
//  The control layout page under Settings -> Controls (0.1.3 simplification).
//
//  Exactly two choices are exposed:
//  - Default: the shipped positions of every control (nothing covers the picture
//    in portrait).
//  - Custom: the user's own positions. Choosing Custom opens the full-screen
//    editor for the direction the device is in right now - that editor is the
//    only control-layout surface left (no orientation picker or extra modes).
//
//  The stored profiles are unchanged from 0.1.2 (versioned Codable data under
//  UI.controlLayoutPortrait / ...Landscape), so a layout saved by 0.1.2 keeps
//  working; on upgrade a 0.1.2 install is treated as Custom.
//

import Foundation
import SwiftUI

struct ControlLayoutSettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var isEditorPresented = false

    var body: some View {
        Form {
            choiceSection
            aboutSection
        }
        .navigationTitle(L10n.tr("Control layout"))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isEditorPresented) {
            ControlLayoutEditorView(settings: settings)
        }
    }

    // MARK: - Choice

    private var choiceSection: some View {
        Section {
            Picker(L10n.tr("Control layout"), selection: choiceBinding) {
                ForEach(ControlLayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("control-layout-choice")
            if settings.controlLayoutMode == .custom {
                Button {
                    isEditorPresented = true
                } label: {
                    Label(L10n.tr("Edit control layout"), systemImage: "button.programmable")
                }
                .accessibilityIdentifier("control-layout-edit")
            }
            hint(settings.controlLayoutMode.detail)
        } header: {
            Text(L10n.tr("Controls"))
        } footer: {
            Text(L10n.tr("The overlay opacity under Controls applies to both choices."))
        }
    }

    /// Choosing Custom opens the editor for the current direction immediately.
    private var choiceBinding: Binding<ControlLayoutMode> {
        Binding(
            get: { settings.controlLayoutMode },
            set: { newValue in
                guard newValue != settings.controlLayoutMode else { return }
                settings.controlLayoutMode = newValue
                settings.persist()
                if newValue == .custom {
                    DispatchQueue.main.async { isEditorPresented = true }
                }
            }
        )
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            Button(L10n.tr("Reset control layout to defaults"), role: .destructive) {
                settings.controlLayoutMode = .standard
                for orientation in ControlLayoutOrientation.allCases {
                    settings.setControlLayout(.standard(for: orientation), for: orientation)
                }
                settings.persist()
            }
        } header: {
            Text(L10n.tr("How it works"))
        } footer: {
            Text(L10n.tr("Portrait and landscape keep their own control layouts."))
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
