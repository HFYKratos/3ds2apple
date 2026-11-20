//
//  ScreenLayoutSettingsView.swift
//  3ds2apple
//
//  The screen layout page under Settings -> Display (round-2 split).
//
//  Landscape and portrait are independent settings, like the reference layout
//  app:
//  - "Landscape screen layout" shows the landscape choice and opens a six-preset radio
//    picker (Large screen, Single screen, Side by side, Hybrid, Original,
//    Custom layout);
//  - "Portrait screen layout" shows the portrait choice and opens a three-preset
//    radio picker (Default, Original, Custom layout);
//  - "Landscape custom layout" and "Portrait custom layout" open the numeric
//    percent pages for the two custom layouts.
//
//  The page has no "how it works" section and no reset: the radio picker and the
//  numeric pages are the whole surface. The headless screenshot hook
//  -openLayoutPicker landscape|portrait asks this page to present one picker
//  straight away; see DebugLaunch.swift.
//

import Foundation
import SwiftUI

struct ScreenLayoutSettingsView: View {
    @ObservedObject var settings: AppSettings

    @State private var pickerOrientation: ControlLayoutOrientation?
    @State private var didHandleDebugLaunch = false

    var body: some View {
        Form {
            presetSection
            customSection
        }
        .navigationTitle(L10n.tr("Landscape screen layout"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerOrientation) { orientation in
            LayoutPresetPickerView(settings: settings, orientation: orientation)
        }
        .onAppear {
            guard !didHandleDebugLaunch else { return }
            didHandleDebugLaunch = true
            if let orientation = DebugLaunch.requestedLayoutPicker {
                pickerOrientation = orientation
            }
        }
    }

    // MARK: - Rows

    private var presetSection: some View {
        Section {
            presetRow(title: L10n.tr("Landscape screen layout"),
                      value: settings.landscapeScreenLayout.title,
                      orientation: .landscape)
            presetRow(title: L10n.tr("Portrait screen layout"),
                      value: settings.portraitScreenLayout.title,
                      orientation: .portrait)
        } header: {
            Text(L10n.tr("Screens"))
        }
    }

    private var customSection: some View {
        Section {
            NavigationLink {
                CustomScreenLayoutValuesView(settings: settings, orientation: .landscape)
            } label: {
                Text(L10n.tr("Landscape custom layout"))
            }
            .accessibilityIdentifier("custom-layout-landscape")
            NavigationLink {
                CustomScreenLayoutValuesView(settings: settings, orientation: .portrait)
            } label: {
                Text(L10n.tr("Portrait custom layout"))
            }
            .accessibilityIdentifier("custom-layout-portrait")
        } footer: {
            Text(L10n.tr("The custom layouts place each screen with percentages of the game view; they apply from the next game load."))
        }
    }

    private func presetRow(title: String,
                           value: String,
                           orientation: ControlLayoutOrientation) -> some View {
        Button {
            pickerOrientation = orientation
        } label: {
            HStack {
                Text(title).foregroundColor(.primary)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(orientation == .landscape
                                 ? "landscape-layout-picker"
                                 : "portrait-layout-picker")
    }
}

// MARK: - Preset picker

/// The radio picker of one direction's layout choices. Presented as a sheet by
/// the screen layout page (and by the headless screenshot hook).
struct LayoutPresetPickerView: View {
    @ObservedObject var settings: AppSettings
    let orientation: ControlLayoutOrientation

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch orientation {
                case .landscape:
                    ForEach(LandscapeScreenLayout.allCases) { layout in
                        row(title: layout.title,
                            selected: settings.landscapeScreenLayout == layout) {
                            settings.landscapeScreenLayout = layout
                            settings.persist()
                        }
                    }
                case .portrait:
                    ForEach(PortraitScreenLayout.allCases) { layout in
                        row(title: layout.title,
                            selected: settings.portraitScreenLayout == layout) {
                            settings.portraitScreenLayout = layout
                            settings.persist()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Done")) { dismiss() }
                        .accessibilityIdentifier("layout-picker-done")
                }
            }
        }
    }

    private var navigationTitle: String {
        orientation == .landscape
            ? L10n.tr("Landscape screen layout")
            : L10n.tr("Portrait screen layout")
    }

    private func row(title: String,
                     selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundColor(.primary)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("layout-row-\(orientation.rawValue)-\(title)")
    }
}
