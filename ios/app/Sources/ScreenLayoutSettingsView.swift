//
//  ScreenLayoutSettingsView.swift
//  3ds2apple
//
//  The screen layout page under Settings -> Display (0.1.3 simplification).
//
//  Exactly two choices are exposed:
//  - Default: the automatic arrangement (stacked screens in portrait, the large
//    upper screen in landscape), drawn by the Metal presenter.
//  - Custom: a hand-placed layout per device orientation. Choosing Custom opens
//    the full-screen editor for the direction the device is in right now - that
//    editor is the only screen-layout surface left (no mode, preset or
//    "only one screen" choices). It runs on the software readback path.
//
//  The screen layout page stays a normal Settings page; the editing itself
//  happens in ScreenLayoutEditorView, full screen, on a scaled copy of the real
//  game view of this device (see GameViewGeometry.swift).
//

import Foundation
import SwiftUI

struct ScreenLayoutSettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var isEditorPresented = false

    var body: some View {
        Form {
            choiceSection
            aboutSection
        }
        .navigationTitle(L10n.tr("Screen layout"))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isEditorPresented) {
            ScreenLayoutEditorView(settings: settings)
        }
    }

    // MARK: - Choice

    private var choiceSection: some View {
        Section {
            Picker(L10n.tr("Screen layout"), selection: choiceBinding) {
                ForEach(ScreenLayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("screen-layout-choice")
            if settings.screenLayoutMode == .custom {
                Button {
                    isEditorPresented = true
                } label: {
                    Label(L10n.tr("Edit screen layout"), systemImage: "rectangle.3.group")
                }
                .accessibilityIdentifier("screen-layout-edit")
            }
            hint(settings.screenLayoutMode.detail)
        } header: {
            Text(L10n.tr("Screens"))
        } footer: {
            Text(L10n.tr("Rotation, aspect ratio and integer scaling keep their meaning in both choices."))
        }
    }

    /// Choosing Custom opens the editor for the current direction immediately;
    /// there is no other screen-layout screen in the app any more.
    private var choiceBinding: Binding<ScreenLayoutMode> {
        Binding(
            get: { settings.screenLayoutMode },
            set: { newValue in
                guard newValue != settings.screenLayoutMode else { return }
                settings.screenLayoutMode = newValue
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
            hint(L10n.tr("Custom screen layouts run on the software readback path, so they can be slower; a change applies from the next game load."))
            Button(L10n.tr("Reset screen layout to defaults"), role: .destructive) {
                settings.screenLayoutMode = .standard
                settings.customScreenLayout = .standard()
                settings.persist()
            }
        } header: {
            Text(L10n.tr("How it works"))
        } footer: {
            Text(L10n.tr("Portrait and landscape keep their own custom layouts."))
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
