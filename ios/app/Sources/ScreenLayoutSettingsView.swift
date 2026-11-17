//
//  ScreenLayoutSettingsView.swift
//  3ds2apple
//
//  The screen layout page under Settings -> Display (split out of the old
//  combined "Screen and control layout" page for 0.1.2): the arrangement mode
//  (Automatic / Preset / Custom (Metal) / Free layout), the base arrangement,
//  the Metal custom scale/offset and the entry to the full screen layout editor.
//
//  The control layout lives on its own page under Settings -> Controls
//  (ControlLayoutEditorView); this page only owns the screen side. The editing
//  itself happens in ScreenLayoutEditorView, on a scaled copy of the real
//  picture stage of this device (see GameViewGeometry.swift).
//
//  Three screen modes keep the fast path fast:
//  - Automatic / Preset / Custom (Metal) all present through the CAMetalLayer;
//    the custom one only adds a uniform scale and offset on the layer, which the
//    presenter never sees, so the GPU path is unchanged.
//  - Free layout (software) places each screen anywhere; the upstream Zakuro
//    presenter has no arbitrary arrangement, so this mode runs the readback
//    display path. It is opt-in and the page says so.
//

import Foundation
import SwiftUI

struct ScreenLayoutSettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var orientation: ControlLayoutOrientation = .portrait

    var body: some View {
        Form {
            screensSection
            adjustmentSection
            aboutSection
        }
        .navigationTitle(L10n.tr("Screen layout"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Screens

    private var screensSection: some View {
        Section {
            Picker("Screen layout", selection: persistedBinding(settings, \.screenLayoutMode)) {
                ForEach(ScreenLayoutMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if settings.screenLayoutMode != .automatic {
                Picker("Base arrangement", selection: persistedBinding(settings, \.screenLayout)) {
                    ForEach(ScreenLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
            }
            hint(settings.screenLayoutMode.detail)
            if settings.screenLayoutMode == .freeform {
                NavigationLink {
                    ScreenLayoutEditorView(settings: settings)
                } label: {
                    Label(L10n.tr("Edit screen layout"), systemImage: "rectangle.3.group")
                }
                hint(L10n.tr("Free screen layout runs on the software readback path, so it can be slower; it applies from the next game load."))
            }
        } header: {
            Text("Screens")
        } footer: {
            Text(L10n.tr("Rotation, aspect ratio, integer scaling and resolution keep their meaning in every mode."))
        }
    }

    // MARK: - Metal custom zoom/position

    @ViewBuilder
    private var adjustmentSection: some View {
        if settings.screenLayoutMode == .customMetal {
            Section {
                Picker("Orientation", selection: $orientation) {
                    ForEach(ControlLayoutOrientation.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                adjustmentSlider(L10n.tr("Scale"),
                                 keyPath: \.scale,
                                 range: 0.50...1.50,
                                 format: "%.2f")
                adjustmentSlider(L10n.tr("Horizontal offset"),
                                 keyPath: \.offsetX,
                                 range: -0.30...0.30,
                                 format: "%+.2f")
                adjustmentSlider(L10n.tr("Vertical offset"),
                                 keyPath: \.offsetY,
                                 range: -0.30...0.30,
                                 format: "%+.2f")
                Button(L10n.tr("Reset scale and position")) {
                    settings.setScreenAdjustment(.standard, for: orientation)
                    settings.persist()
                }
            } header: {
                Text("Custom scale and position")
            } footer: {
                Text(L10n.tr("The Metal presenter still draws the base arrangement; this only zooms and moves the whole picture on the layer. Enlarging past 100% shows the same render resolution, so it gets softer. Saved separately for portrait and landscape."))
            }
        }
    }

    private func adjustmentSlider(_ title: String,
                                  keyPath: WritableKeyPath<MetalScreenAdjustment, Double>,
                                  range: ClosedRange<Double>,
                                  format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(String(format: format,
                            settings.screenAdjustment(for: orientation)[keyPath: keyPath]))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: adjustmentBinding(keyPath, for: orientation), in: range)
        }
    }

    private func adjustmentBinding(
        _ keyPath: WritableKeyPath<MetalScreenAdjustment, Double>,
        for orientation: ControlLayoutOrientation
    ) -> Binding<Double> {
        Binding(
            get: { settings.screenAdjustment(for: orientation)[keyPath: keyPath] },
            set: { value in
                var adjustment = settings.screenAdjustment(for: orientation)
                adjustment[keyPath: keyPath] = value
                settings.setScreenAdjustment(adjustment, for: orientation)
                settings.persist()
            }
        )
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            hint(L10n.tr("Presets and Custom (Metal) draw through the CAMetalLayer presenter: full speed, and every phone rotates, scales and filters the picture the same way. Free layout trades that Metal path for exact per-screen placement, because the presenter only knows its own arrangements; the game picture then comes from the readback path the app also uses when Metal is unavailable."))
            Button(L10n.tr("Reset screen layout to defaults"), role: .destructive) {
                settings.screenLayoutMode = .automatic
                settings.screenLayout = .stacked
                settings.screenAdjustmentPortrait = .standard
                settings.screenAdjustmentLandscape = .standard
                settings.customScreenLayout = .standard()
                settings.persist()
            }
        } header: {
            Text("How it works")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
