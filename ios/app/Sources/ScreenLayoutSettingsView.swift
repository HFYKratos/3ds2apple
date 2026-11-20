//
//  ScreenLayoutSettingsView.swift
//  3ds2apple
//
//  The screen layout page under Settings -> Display (round-1 layout redesign).
//
//  It is a radio list of the six screen layout presets - Original, Single
//  screen, Large screen (the default), Side by side, Hybrid and Custom - with a
//  one-line detail under every title and a checkmark on the selected row. The
//  Custom row also opens the existing full-screen editor for the direction the
//  device is in right now, and the page keeps the reset action.
//
//  Presets the Metal presenter can draw apply immediately (they just choose the
//  presented arrangement). Large in portrait, Hybrid in both directions and
//  Custom are placed on the readback path, so the session picks them up on the
//  next load; the footer says so. The editing itself happens in
//  ScreenLayoutEditorView, full screen, on a scaled copy of the real game view of
//  this device (see GameViewGeometry.swift).
//

import Foundation
import SwiftUI

struct ScreenLayoutSettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var isEditorPresented = false

    var body: some View {
        Form {
            presetSection
            aboutSection
        }
        .navigationTitle(L10n.tr("Screen layout"))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isEditorPresented) {
            ScreenLayoutEditorView(settings: settings)
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        Section {
            ForEach(ScreenLayoutPreset.allCases) { preset in
                presetRow(preset)
            }
            if settings.screenLayoutPreset == .custom {
                Button {
                    isEditorPresented = true
                } label: {
                    Label(L10n.tr("Edit screen layout"), systemImage: "rectangle.3.group")
                }
                .accessibilityIdentifier("screen-layout-edit")
            }
        } header: {
            Text(L10n.tr("Screens"))
        } footer: {
            Text(L10n.tr("Large in portrait, Hybrid and Custom are placed by the app on the readback path, so they can be slower and apply from the next game load."))
        }
    }

    private func presetRow(_ preset: ScreenLayoutPreset) -> some View {
        Button {
            select(preset)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .foregroundColor(.primary)
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if settings.screenLayoutPreset == preset {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("screen-layout-preset-\(preset.rawValue)")
        .accessibilityAddTraits(settings.screenLayoutPreset == preset ? .isSelected : [])
    }

    /// Choosing Custom opens the editor for the current direction right away;
    /// the editor is the only surface for the hand-placed rectangles.
    private func select(_ preset: ScreenLayoutPreset) {
        guard preset != settings.screenLayoutPreset else { return }
        settings.screenLayoutPreset = preset
        settings.persist()
        if preset == .custom {
            DispatchQueue.main.async { isEditorPresented = true }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            hint(L10n.tr("Custom screen layouts and the readback presets run on the software readback path, so they can be slower than the Metal presenter."))
            Button(L10n.tr("Reset screen layout to defaults"), role: .destructive) {
                settings.screenLayoutPreset = .defaultPreset
                settings.customScreenLayout = .standard()
                settings.persist()
            }
        } header: {
            Text(L10n.tr("How it works"))
        } footer: {
            Text(L10n.tr("Portrait and landscape keep their own custom layouts. The running game fills the screen; the FPS counter and the pause button float over the picture."))
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
