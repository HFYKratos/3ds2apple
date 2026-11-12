//
//  SettingsView.swift
//  3ds2apple
//
//  Settings page: display, audio, controls, performance, storage and About.
//  The display rows are shared with the in-game quick settings sheet.
//
//  The settings live in AppSettings; every control writes through a binding that
//  also stores the new value in UserDefaults. Rows are written directly in the
//  Form sections (rather than grouped in helper view types) so a Form renders
//  each control as its own row.
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

    var body: some View {
        Form {
            Section {
                Picker("Screen layout", selection: persistedBinding(settings, \.screenLayout)) {
                    ForEach(ScreenLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                Text(settings.screenLayout.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Aspect ratio", selection: persistedBinding(settings, \.screenAspect)) {
                    ForEach(ScreenAspect.allCases) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
                Toggle("Integer scaling", isOn: persistedBinding(settings, \.integerScale))
                Picker("Render resolution", selection: persistedBinding(settings, \.renderScale)) {
                    Text("1x").tag(1)
                    Text("2x").tag(2)
                }
                .pickerStyle(.segmented)
                Picker("Orientation", selection: persistedBinding(settings, \.orientation)) {
                    ForEach(OrientationLock.allCases) { lock in
                        Text(lock.title).tag(lock)
                    }
                }
            } header: {
                Text("Display")
            } footer: {
                Text("The screen layout is read when a game loads, so a layout change applies to the next load. The presented console layout is the fastest path; other layouts use the screen-readback path. Integer scaling snaps the presented image to whole screen pixels.")
            }

            Section {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text(L10n.format("%ld%%", Int((settings.audioVolume * 100).rounded())))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: persistedBinding(settings, \.audioVolume),
                    in: 0...1,
                    step: 0.05
                )
                Toggle("Mute", isOn: persistedBinding(settings, \.audioMuted))
                Picker("Buffer size", selection: persistedBinding(settings, \.audioBuffer)) {
                    ForEach(AudioBufferSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                Text(settings.audioBuffer.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Audio")
            } footer: {
                Text("Changes apply immediately. A different buffer size restarts the audio engine once while a game is running.")
            }

            Section {
                Toggle(
                    "Show on-screen controls",
                    isOn: persistedBinding(settings, \.showTouchControls)
                )
                HStack {
                    Text("Overlay opacity")
                    Spacer()
                    Text(L10n.format("%ld%%", Int((settings.controlsOpacity * 100).rounded())))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: persistedBinding(settings, \.controlsOpacity),
                    in: 0.15...1.0,
                    step: 0.05
                )
                Toggle(
                    "Haptic feedback on button press",
                    isOn: persistedBinding(settings, \.haptics)
                )
                HStack {
                    Text("Controller")
                    Spacer()
                    Text(model.controllerName ?? L10n.tr("Not connected"))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Button remapping")
                    Spacer()
                    Text("Not available in this build")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Controls")
            } footer: {
                Text("The on-screen pad and a connected controller are merged. Dragging on the lower screen is the 3DS touchscreen.")
            }

            Section {
                Toggle(
                    "Custom frame-time HUD",
                    isOn: persistedBinding(settings, \.showCustomHUD)
                )
                Picker("Frame cap", selection: persistedBinding(settings, \.frameCap)) {
                    ForEach(FrameRateCap.allCases) { cap in
                        Text(cap.title).tag(cap)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Frame loop")
                    Spacer()
                    Text(model.frameLoopDisplayLabel)
                        .foregroundColor(.secondary)
                }
                Picker(
                    "Fast-forward",
                    selection: persistedBinding(settings, \.playbackSpeed)
                ) {
                    ForEach(PlaybackSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Running at")
                    Spacer()
                    Text(L10n.speedLabel(model.effectivePlaybackSpeed))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .accessibilityIdentifier("effective-playback-speed")
                }
                Text(fastForwardStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(
                    "System Metal HUD",
                    isOn: persistedBinding(settings, \.systemMetalHUD)
                )
                Text(systemHUDStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(
                    "First-load graphics warm-up (optional)",
                    isOn: persistedBinding(settings, \.graphicsWarmUpEnabled)
                )
                Text(warmUpStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Performance")
            } footer: {
                Text("The custom HUD shows the per-phase frame times. Fast-forward runs extra console frames per displayed frame and mutes audio while it is active; if presented frames stay below 20 fps the app lowers the speed automatically. The graphics warm-up is optional and off by default: the pipeline cache is still written while you play either way.")
            }

            Section {
                HStack {
                    Text("Save data")
                    Spacer()
                    Text(StorageFormat.size(storage.saveDataBytes))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Imported ROMs")
                    Spacer()
                    Text(StorageFormat.size(storage.romBytes))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("App logs")
                    Spacer()
                    Text(StorageFormat.size(storage.logBytes))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Graphics pipeline cache")
                    Spacer()
                    Text(StorageFormat.size(storage.cacheBytes))
                        .foregroundColor(.secondary)
                }
                Button("Clear graphics pipeline cache") {
                    isClearCacheConfirmationPresented = true
                }
                .disabled(model.isRuntimeActive)
                if model.isRuntimeActive {
                    Text("Available when no game is running.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder")
                    Text(storage.documentsPath)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Everything stays in the app's Documents and Caches folders on this device. The pipeline cache only holds compiled shader pipelines and is rebuilt automatically.")
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(versionText)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                HStack {
                    Text("Device")
                    Spacer()
                    Text(deviceText)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("AOT code")
                    Spacer()
                    Text(model.aotStatus.title)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Language")
                    Spacer()
                    Text(L10n.languageSummary)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if let url = URL(string: "https://github.com/HFYKratos/3ds2apple") {
                    Link(destination: url) {
                        HStack {
                            Text("Project page")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("About")
            } footer: {
                Text("Apache-2.0. 3ds2apple ships without game data; use only your own decrypted dumps. The app follows the system language: Simplified Chinese and English are included, and every other language uses English.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshStorage()
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

    // MARK: - Text

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

    /// Fast-forward state, including the automatic fallback when it happened.
    private var fastForwardStatusText: String {
        let effective = L10n.speedLabel(model.effectivePlaybackSpeed)
        if model.playbackSpeedAutoReduced {
            return L10n.format(
                "Running at %@: lowered automatically from %@ because presented frames stayed below 20 fps.",
                effective,
                L10n.speedLabel(settings.playbackSpeed.rawValue)
            )
        }
        return L10n.format("Running at %@.", effective)
    }

    /// What the system Metal HUD switch does right now, including the note when
    /// the build does not enable the HUD the runtime tries to show.
    private var systemHUDStatusText: String {
        let buildEnablesHUD = Bundle.main.object(forInfoDictionaryKey: "MetalHudEnabled") as? Bool ?? false
        if settings.systemMetalHUD {
            if buildEnablesHUD {
                return L10n.tr("On: the HUD is shown over the presented Metal layer.")
            }
            return L10n.tr("The switch is on, but this build must also enable the HUD (MetalHudEnabled in Info.plist), or turn on Developer → Graphics HUD on the device, then relaunch.")
        }
        if buildEnablesHUD {
            return L10n.tr("Off: the HUD is hidden for this app even though the build enables it.")
        }
        return L10n.tr("Off: the build does not enable the system HUD.")
    }

    /// What the optional first-load graphics warm-up does.
    private var warmUpStatusText: String {
        if settings.graphicsWarmUpEnabled {
            return L10n.tr("On: the first frames of each load run behind a “Preparing graphics” screen until they stop spiking (at most 5 s). Later pipelines can still compile on first use.")
        }
        return L10n.tr("Off by default: the game appears as soon as the ROM loads. The runtime still writes its pipeline cache while you play, so later loads start warm.")
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
                    Text(settings.screenLayout.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker(
                        "Aspect ratio",
                        selection: persistedBinding(settings, \.screenAspect)
                    ) {
                        ForEach(ScreenAspect.allCases) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }
                    Toggle(
                        "Integer scaling",
                        isOn: persistedBinding(settings, \.integerScale)
                    )
                    Picker(
                        "Render resolution",
                        selection: persistedBinding(settings, \.renderScale)
                    ) {
                        Text("1x").tag(1)
                        Text("2x").tag(2)
                    }
                    .pickerStyle(.segmented)
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
                } footer: {
                    Text("The screen layout is read when a game loads, so it applies to the next load. The other display changes apply immediately.")
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
