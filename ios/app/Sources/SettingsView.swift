//
//  SettingsView.swift
//  3ds2apple
//
//  Settings main page and the in-game quick display sheet.
//
//  0.1.7 reorganises Settings into a flat main menu and one page per category:
//  General, System, Gamepad, Graphics, Layout, Sound, Debug and About. The main
//  page is a plain dark list with a large SF Symbol and a label per category
//  (no grouped cards, no separators, no chevrons); the category pages live in
//  SettingsPages.swift. The design follows reference screenshots of another
//  emulator's settings app for its layout only - all strings and code here are
//  our own, and that project's GPL code/text is not copied.
//
//  The settings live in AppSettings; every control writes through a binding that
//  also stores the new value in UserDefaults. The in-game quick display sheet
//  (opened from the pause overlay) stays a compact Form because it floats over
//  the running game and only covers the layout/rotation rows.
//
//  User-facing text: static SwiftUI literals localize through
//  Localizable.strings; strings built at run time go through L10n.
//

import Foundation
import SwiftUI

// MARK: - Persisting binding

/// Binding for one setting that stores the new value whenever it changes.
func persistedBinding<T>(
    _ settings: AppSettings,
    _ keyPath: ReferenceWritableKeyPath<AppSettings, T>
) -> Binding<T> {
    Binding(
        get: { settings[keyPath: keyPath] },
        set: { newValue in
            settings[keyPath: keyPath] = newValue
            settings.persist()
        }
    )
}

// MARK: - Settings main page

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SettingsCategory.allCases) { category in
                    NavigationLink(value: category) {
                        SettingsMainRow(category: category)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-category-\(category.rawValue)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 36)
            .frame(maxWidth: SettingsTheme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(SettingsTheme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // The settings redesign is a dark, flat list; this applies to the
        // settings stack only, the home page and the game keep the system
        // appearance.
        .preferredColorScheme(.dark)
        .navigationDestination(for: SettingsCategory.self) { category in
            SettingsCategoryPage(category: category, settings: settings, model: model)
        }
    }
}

/// One row of the main page: a large SF Symbol and the category name. The whole
/// row is the NavigationLink label, so there is no disclosure chevron.
private struct SettingsMainRow: View {
    let category: SettingsCategory

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: category.systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 38, alignment: .center)
            Text(category.title)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 21)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - In-game quick display settings

struct QuickDisplaySettingsView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        "Landscape screen layout",
                        selection: persistedBinding(settings, \.landscapeScreenLayout)
                    ) {
                        ForEach(LandscapeScreenLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    Picker(
                        "Portrait screen layout",
                        selection: persistedBinding(settings, \.portraitScreenLayout)
                    ) {
                        ForEach(PortraitScreenLayout.allCases) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    Picker(
                        "Screen rotation",
                        selection: persistedBinding(settings, \.screenRotation)
                    ) {
                        ForEach(ScreenRotation.allCases) { rotation in
                            Text(rotation.title).tag(rotation)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Resolution")
                        Picker(
                            "Resolution",
                            selection: persistedBinding(settings, \.renderScale)
                        ) {
                            Text("1x").tag(1)
                            Text("2x").tag(2)
                            Text("3x").tag(3)
                            Text("4x").tag(4)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(resolutionCaption(for: settings.renderScale))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker(
                        "Orientation",
                        selection: persistedBinding(settings, \.orientation)
                    ) {
                        ForEach(OrientationLock.allCases) { lock in
                            Text(lock.title).tag(lock)
                        }
                    }
                } header: {
                    Text("Display")
                }
            }
            .navigationTitle("Display settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
