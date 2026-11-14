//
//  SettingsView.swift
//  3ds2apple
//
//  Settings page: display, audio, controls, performance, storage and About.
//  The display rows are shared with the in-game quick settings sheet.
//
//  The settings live in AppSettings; every control writes through a binding that
//  also stores the new value in UserDefaults. Rows are written directly in the
//  Form sections so a Form renders each control as its own row.
//
//  User-facing text: static SwiftUI literals localize through
//  Localizable.strings; strings built at run time go through L10n.
//

import Foundation
import SwiftUI
import UIKit

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

// MARK: - Settings page

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    @State private var storage = StorageSnapshot.empty
    @State private var isClearCacheConfirmationPresented = false
    @State private var shareItem: SettingsShareItem?

    var body: some View {
        Form {
            displaySection
            audioSection
            controlsSection
            performanceSection
            storageSection
            toolsSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshStorage()
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Clear the graphics pipeline cache?", isPresented: $isClearCacheConfirmationPresented) {
            Button("Clear", role: .destructive) {
                clearPipelineCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cache is rebuilt on the next load, so that first load is slower. Save data is not touched.")
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            Picker("Screen layout", selection: persistedBinding(settings, \.screenLayout)) {
                ForEach(ScreenLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            Picker("Screen rotation", selection: persistedBinding(settings, \.screenRotation)) {
                ForEach(ScreenRotation.allCases) { rotation in
                    Text(rotation.title).tag(rotation)
                }
            }
            Picker("Aspect ratio", selection: persistedBinding(settings, \.screenAspect)) {
                ForEach(ScreenAspect.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Integer scaling", isOn: persistedBinding(settings, \.integerScale))
                    .disabled(settings.screenAspect == .stretch)
                hintText(L10n.tr("Whole-pixel scaling: every 3DS pixel becomes a whole block of screen pixels, so the picture stays sharp."))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Resolution")
                Picker("Resolution", selection: persistedBinding(settings, \.renderScale)) {
                    Text("1x").tag(1)
                    Text("2x").tag(2)
                    Text("3x").tag(3)
                    Text("4x").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                hintText(L10n.tr("1x is the 3DS's native 400×240."))
            }
            Picker("Orientation", selection: persistedBinding(settings, \.orientation)) {
                ForEach(OrientationLock.allCases) { lock in
                    Text(lock.title).tag(lock)
                }
            }
        } header: {
            Text("Display")
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section {
            settingRow("Volume") {
                Slider(value: persistedBinding(settings, \.audioVolume), in: 0...1, step: 0.05)
                    .labelsHidden()
            } hint: {
                Text(L10n.format("%ld%%", Int((settings.audioVolume * 100).rounded())))
                    .monospacedDigit()
            }
            Toggle("Mute", isOn: persistedBinding(settings, \.audioMuted))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Buffer size")
                    Spacer(minLength: 12)
                    Picker("Buffer size", selection: persistedBinding(settings, \.audioBuffer)) {
                        ForEach(AudioBufferSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                hintText(L10n.tr("A different buffer size restarts audio once while a game is running."))
            }
        } header: {
            Text("Audio")
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        Section {
            Toggle("Show on-screen controls", isOn: persistedBinding(settings, \.showTouchControls))
            settingRow("Overlay opacity") {
                Slider(value: persistedBinding(settings, \.controlsOpacity), in: 0.15...1.0, step: 0.05)
                    .labelsHidden()
            } hint: {
                Text(L10n.format("%ld%%", Int((settings.controlsOpacity * 100).rounded())))
                    .monospacedDigit()
            }
            Toggle("Haptic feedback on button press", isOn: persistedBinding(settings, \.haptics))
            infoRow("Controller", model.controllerName ?? L10n.tr("Not connected"))
        } header: {
            Text("Controls")
        }
    }

    // MARK: - Performance

    private var performanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fast-forward")
                Picker("Fast-forward", selection: persistedBinding(settings, \.playbackSpeed)) {
                    ForEach(PlaybackSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.playbackSpeedAutoReduced {
                    hintText(autoReducedText)
                } else if settings.playbackSpeed == .normal {
                    hintText(L10n.tr("Fast-forward runs extra console frames per presented frame."))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("System Metal HUD", isOn: persistedBinding(settings, \.systemMetalHUD))
                    .accessibilityIdentifier("settings-system-metal-hud")
                if settings.systemMetalHUD {
                    hintText(L10n.tr("Restart the app to apply. If it still does not appear, check System Settings."))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("First-load graphics warm-up (optional)", isOn: persistedBinding(settings, \.graphicsWarmUpEnabled))
                hintText(warmUpStatusText)
            }
        } header: {
            Text("Performance")
        }
    }
    // MARK: - Storage

    private var storageSection: some View {
        Section {
            infoRow("Installed games", StorageFormat.size(storage.gamesBytes))
            infoRow("Save data", StorageFormat.size(storage.saveDataBytes))
            if storage.romBytes > 0 {
                // 0.1.x shell cartridges: only present on an updated install.
                infoRow("Legacy game files", StorageFormat.size(storage.romBytes))
            }
            infoRow("App logs", StorageFormat.size(storage.logBytes))
            infoRow("Graphics pipeline cache", StorageFormat.size(storage.cacheBytes))
            Text("Each game's AOT code is part of this app; the desktop launcher pushes the game data into this app's Documents/Games folder over USB or Wi-Fi. The Files app shows the same folder under On My iPhone → 3ds2apple.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Clear graphics pipeline cache") {
                isClearCacheConfirmationPresented = true
            }
            .disabled(model.isRuntimeActive)
            .accessibilityIdentifier("settings-clear-cache")
            if model.isRuntimeActive {
                Text("Available when no game is running.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Storage")
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section {
            NavigationLink {
                SaveManagerView(model: model, saveStates: model.saveStates)
            } label: {
                Label("Save Manager", systemImage: "externaldrive.fill")
            }
            Button {
                exportDiagnostics()
            } label: {
                Label("Export logs", systemImage: "square.and.arrow.up")
            }
            NavigationLink {
                AboutView(model: model)
            } label: {
                Label("About", systemImage: "info.circle.fill")
            }
        } header: {
            Text("More")
        }
    }

    /// Standard inline hint under a control: one caption style everywhere, no
    /// separate row/divider.
    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    /// One settings row: the control, with an optional one-line hint directly
    /// underneath it (no extra divider row), so every hint in the page has the
    /// same shape.
    @ViewBuilder
    private func settingRow<Control: View, Hint: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder control: () -> Control,
        @ViewBuilder hint: () -> Hint
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            control()
            hint()
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func settingRow<Control: View>(_ title: LocalizedStringKey,
                                           @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            control()
        }
    }

    private func exportDiagnostics() {
        if let url = DiagnosticsExporter.write(model: model, settings: settings) {
            shareItem = SettingsShareItem(url: url)
        }
    }

    // MARK: - Text

    /// Fast-forward state when the automatic fallback lowered the speed.
    private var autoReducedText: String {
        L10n.format(
            "Lowered automatically from %@ because frames stayed below 20 fps.",
            L10n.speedLabel(settings.playbackSpeed.rawValue)
        )
    }

    /// What the optional first-load graphics warm-up does.
    private var warmUpStatusText: String {
        if settings.graphicsWarmUpEnabled {
            return L10n.tr("Shows a “Preparing graphics” screen while the first frames of each load compile their pipelines (at most 5 s).")
        }
        return L10n.tr("Off by default: the game appears as soon as it loads, and the pipeline cache is still written while you play.")
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var deviceText: String {
        let device = UIDevice.current
        return "\(device.model) · \(device.systemName) \(device.systemVersion)"
    }

    private func infoRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Actions

    private func refreshStorage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = StorageInspector.snapshot()
            DispatchQueue.main.async {
                self.storage = snapshot
            }
        }
    }

    private func clearPipelineCache() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = StorageInspector.clearPipelineCache()
            let snapshot = StorageInspector.snapshot()
            DispatchQueue.main.async {
                self.storage = snapshot
            }
        }
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
                        "Screen layout",
                        selection: persistedBinding(settings, \.screenLayout)
                    ) {
                        ForEach(ScreenLayout.allCases) { layout in
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
                    Picker(
                        "Aspect ratio",
                        selection: persistedBinding(settings, \.screenAspect)
                    ) {
                        ForEach(ScreenAspect.allCases) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(
                            "Integer scaling",
                            isOn: persistedBinding(settings, \.integerScale)
                        )
                        .disabled(settings.screenAspect == .stretch)
                        Text("Whole-pixel scaling: every 3DS pixel becomes a whole block of screen pixels, so the picture stays sharp.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                        Text("1x is the 3DS's native 400×240.")
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

/// Share sheet payload for the diagnostics export from Settings.
private struct SettingsShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
