//
//  ControlOptionsViews.swift
//  3ds2apple
//
//  The pause menu's virtual-control option sheets (round 4): Toggle controls
//  (per row visibility), Adjust size (per row 10%-200% slider) and Adjust
//  opacity (the existing global overlay opacity). Every value is global, not
//  per orientation, and persists through AppSettings.
//
//  The rows are ControlOptionItem: one per control, with the D-pad's four
//  directions as one group. They match the labels in the reference layout
//  app's controller-options page, without its unimplemented behaviour rows.
//  Every row is enumerated from ControlOptionItem.allCases, so a control the
//  layout adds (the 0.2.1-beta2 Settings/Menu buttons) turns up in both sheets
//  with no extra code.
//

import SwiftUI

/// The sheet the pause menu opens from the virtual-controls card.
enum ControlOptionsPage: String, Identifiable {
    case visibility
    case size
    case opacity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visibility: return L10n.tr("Toggle controls")
        case .size: return L10n.tr("Adjust size")
        case .opacity: return L10n.tr("Adjust opacity")
        }
    }
}

// MARK: - Toggle controls

struct ControlVisibilitySheet: View {
    @ObservedObject var settings: AppSettings
    /// The direction the pause menu was opened in: visibility is per direction
    /// since 0.1.6-beta2 (size stays global).
    let orientation: ControlLayoutOrientation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ControlOptionItem.allCases) { item in
                        Toggle(isOn: visibilityBinding(item)) {
                            Text(item.title)
                        }
                        .tint(.accentColor)
                        .accessibilityIdentifier("control-visibility-\(item.rawValue)")
                    }
                } footer: {
                    Text(L10n.tr("Hidden controls are not drawn and do not respond to touches. The D-pad is toggled as one group."))
                }
            }
            .navigationTitle(L10n.tr("Toggle controls"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
            }
            .onChange(of: orientation == .landscape
                        ? settings.hiddenControlItemsLandscape
                        : settings.hiddenControlItemsPortrait) { _ in
                settings.persist()
            }
        }
    }

    private func visibilityBinding(_ item: ControlOptionItem) -> Binding<Bool> {
        Binding(
            get: { settings.isControlItemVisible(item, orientation: orientation) },
            set: { settings.setControlItem(item, visible: $0, orientation: orientation) }
        )
    }
}

// MARK: - Adjust size

struct ControlSizeSheet: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ControlOptionItem.allCases) { item in
                        sizeRow(item)
                    }
                } footer: {
                    Text(L10n.tr("The size scale multiplies each control (or the D-pad group) in the running overlay. 100% is the layout's own size."))
                }
            }
            .navigationTitle(L10n.tr("Adjust size"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
            }
            .onChange(of: settings.controlSizeScales) { _ in
                settings.persist()
            }
        }
    }

    private func sizeRow(_ item: ControlOptionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title)
                Spacer(minLength: 12)
                Text(L10n.format("%ld%%", Int((settings.controlSizeScale(for: item) * 100).rounded())))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: sizeBinding(item), in: AppSettings.controlSizeScaleRange, step: 0.05)
                .tint(.accentColor)
                .accessibilityIdentifier("control-size-\(item.rawValue)")
        }
    }

    private func sizeBinding(_ item: ControlOptionItem) -> Binding<Double> {
        Binding(
            get: { settings.controlSizeScale(for: item) },
            set: { settings.setControlSizeScale($0, for: item) }
        )
    }
}

// MARK: - Adjust opacity

struct ControlOpacitySheet: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.tr("Overlay opacity"))
                            Spacer(minLength: 12)
                            Text(L10n.format("%ld%%", Int((settings.controlsBackgroundOpacity * 100).rounded())))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: opacityBinding, in: 0.15...1.0, step: 0.05)
                            .tint(.accentColor)
                            .accessibilityIdentifier("controls-opacity-slider")
                    }
                } footer: {
                    Text(L10n.tr("The opacity applies to every on-screen control, including the sticks."))
                }
            }
            .navigationTitle(L10n.tr("Adjust opacity"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                }
            }
            .onChange(of: settings.controlsOpacity) { _ in
                settings.persist()
            }
        }
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { settings.controlsOpacity },
            set: { settings.controlsOpacity = $0 }
        )
    }
}