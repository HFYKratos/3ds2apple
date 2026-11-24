//
//  SettingsView.swift
//  3ds2apple
//
//  Settings main page and the in-game quick display sheet.
//
//  0.1.7 reorganises Settings into a flat main menu and one page per category:
//  General, System, Gamepad, Graphics, Layout, Sound, Debug and About, plus a
//  real Reset All Settings action at the bottom. The main page is a plain dark
//  list with a large SF Symbol and a label per row (no grouped cards, no
//  separators, no chevrons); the category pages live in SettingsPages.swift.
//  The design follows reference screenshots of another emulator's settings app
//  for its layout only - all strings and code here are our own, and that
//  project's GPL code/text is not copied.
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

    /// Two-step destructive flow: confirm the reset, then tell the user to
    /// relaunch (the live AppSettings object keeps its values until then).
    @State private var isResetConfirmationPresented = false
    @State private var isResetDonePresented = false

    var body: some View {
        List {
            Section {
                ForEach(SettingsCategory.allCases) { category in
                    NavigationLink(value: category) {
                        Label {
                            Text(category.title)
                        } icon: {
                            Image(systemName: category.systemImage)
                                .foregroundStyle(.tint)
                        }
                    }
                    .accessibilityIdentifier("settings-category-\(category.rawValue)")
                }
            }
            Section {
                // Real reset: removes the app's whole UserDefaults domain and
                // then asks for a relaunch. Game files, saves and diagnostics are
                // stored in Documents, not in UserDefaults, so they stay.
                Button(role: .destructive) {
                    isResetConfirmationPresented = true
                } label: {
                    Label(L10n.tr("Reset All Settings"),
                          systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier("settings-reset-all")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: SettingsCategory.self) { category in
            SettingsCategoryPage(category: category, settings: settings, model: model)
        }
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                resetAllSettings()
                isResetDonePresented = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every app setting returns to its default. Save data, games and the diagnostics export are not touched. Quit and reopen 3ds2apple to apply the reset.")
        }
        .alert("Settings reset", isPresented: $isResetDonePresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Quit and reopen 3ds2apple for the default settings to take effect.")
        }
    }

    /// Removes the app's persisted preference domain. AppSettings keeps its
    /// in-memory values until the next launch, so the flow ends by asking the
    /// user to quit and reopen the app; Documents data (games, saves, logs) is
    /// not part of UserDefaults and is not touched.
    private func resetAllSettings() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        AppLog.log("[3ds2apple] settings reset: removed the app defaults domain; relaunch to apply")
    }
}

/// One row of the main page: a large SF Symbol and a label. The whole row is the
/// NavigationLink/Button label, so there is no disclosure chevron.
private struct SettingsMainRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 38, alignment: .center)
            Text(title)
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