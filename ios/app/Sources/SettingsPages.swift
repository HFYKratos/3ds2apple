//
//  SettingsPages.swift
//  3ds2apple
//
//  The category pages of the 0.1.7 settings redesign. The main page (see
//  SettingsView.swift) is a flat dark list of large category rows plus a
//  Reset All Settings action; each category opens one page with a large title
//  and rows that show a title, a one-line explanation and a trailing control.
//  There are no grouped cards, no separators and no chevrons on the main page.
//
//  0.1.7-beta2 page layout: General (fast-forward speed and the read-only frame
//  limiter), Layout (screen layout entry, screen rotation, orientation lock,
//  swap screens, and the Performance monitoring group with the FPS counter and
//  the system Metal HUD), Gamepad (on-screen controls, overlay opacity,
//  haptics, controller), Graphics (resolution, the two experimental GPU
//  switches and read-only renderer information), Sound (volume, mute, buffer),
//  System (storage, version, language, About), Debug (AOT verification, Save
//  Manager, CPU profiler and the diagnostics export) and About.
//
//  The design was sketched after reference screenshots of another emulator's
//  settings app. Only the layout idea was used: every string below is our own
//  and is localized through Localizable.strings / L10n. No code or text was
//  copied from that project (it is GPL and reference-only for this repo).
//
//  The two experimental switches are next-launch settings: App.init applies
//  them before the renderer creates its first device, so the rows say that a
//  restart is required. Every existing settings row keeps its behaviour and
//  accessibility identifier.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Theme

/// Colours and metrics shared by the settings pages. The redesign is a flat,
/// near-black list, so the settings surface forces its own dark palette; the
/// home page and the game keep following the system appearance.
enum SettingsTheme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.062)
    static let horizontalPadding: CGFloat = 20
    /// Vertical gap between two settings rows (the reference has no dividers).
    static let rowSpacing: CGFloat = 28
    /// The page content stays readable on iPad.
    static let contentMaxWidth: CGFloat = 700
}

// MARK: - Categories

/// One row of the Settings main page.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general
    case system
    case gamepad
    case graphics
    case layout
    case sound
    case debug
    case about

    var id: String { rawValue }

    /// The localized row title (and the page's navigation title).
    var title: String {
        switch self {
        case .general: return L10n.tr("General")
        case .system: return L10n.tr("System")
        case .gamepad: return L10n.tr("Gamepad")
        case .graphics: return L10n.tr("Graphics")
        case .layout: return L10n.tr("Layout")
        case .sound: return L10n.tr("Sound")
        case .debug: return L10n.tr("Debug")
        case .about: return L10n.tr("About")
        }
    }

    /// The large SF Symbol on the main page.
    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .system: return "iphone"
        case .gamepad: return "gamecontroller"
        case .graphics: return "square.grid.2x2"
        case .layout: return "rectangle.split.2x1"
        case .sound: return "speaker"
        case .debug: return "chevron.left.forwardslash.chevron.right"
        case .about: return "info.circle"
        }
    }
}

/// Routes one main-page category to its page. The settings are one shared,
/// persisted model, so every page observes the same instance.
struct SettingsCategoryPage: View {
    let category: SettingsCategory
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        Group {
            switch category {
            case .general:
                GeneralSettingsPage(settings: settings, model: model)
            case .system:
                SystemSettingsPage(settings: settings, model: model)
            case .gamepad:
                GamepadSettingsPage(settings: settings, model: model)
            case .graphics:
                GraphicsSettingsPage(settings: settings, model: model)
            case .layout:
                LayoutSettingsPage(settings: settings, model: model)
            case .sound:
                SoundSettingsPage(settings: settings)
            case .debug:
                DebugSettingsPage(settings: settings, model: model)
            case .about:
                AboutView(model: model)
            }
        }
        // The settings pages keep the dark flat look in either system
        // appearance; this preference only covers the settings presentation.
        .preferredColorScheme(.dark)
    }
}

// MARK: - Page scaffolding

/// Shared page body: a dark scroll surface, a large navigation title and the
/// flat row stack.
struct SettingsPageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    private let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsTheme.rowSpacing) {
                content
            }
            .padding(.horizontal, SettingsTheme.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: SettingsTheme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(SettingsTheme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Rows

/// One settings row: a title, a one-line explanation and a trailing control.
/// A row sits directly on the page background, without a card or a divider.
struct SettingsRowShell<Control: View>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let restartRequired: Bool
    let hint: String?
    private let control: Control

    init(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        restartRequired: Bool = false,
        hint: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.restartRequired = restartRequired
        self.hint = hint
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if restartRequired {
                    SettingsRestartBadge()
                        .padding(.top, 3)
                }
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 10)
            control
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A settings row with a trailing switch.
struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let restartRequired: Bool
    let hint: String?
    @Binding var isOn: Bool

    init(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        restartRequired: Bool = false,
        hint: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.description = description
        self.restartRequired = restartRequired
        self.hint = hint
        self._isOn = isOn
    }

    var body: some View {
        SettingsRowShell(
            title: title,
            description: description,
            restartRequired: restartRequired,
            hint: hint
        ) {
            Toggle(isOn: $isOn) { EmptyView() }
                .labelsHidden()
                .accessibilityLabel(Text(title))
        }
    }
}

/// A settings row that picks one of several values from a trailing menu.
struct SettingsChoiceRow<Choice: Hashable>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let hint: String?
    let choices: [Choice]
    @Binding var selection: Choice
    let label: (Choice) -> String

    init(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        hint: String? = nil,
        choices: [Choice],
        selection: Binding<Choice>,
        label: @escaping (Choice) -> String
    ) {
        self.title = title
        self.description = description
        self.hint = hint
        self.choices = choices
        self._selection = selection
        self.label = label
    }

    var body: some View {
        SettingsRowShell(title: title, description: description, hint: hint) {
            Menu {
                ForEach(choices, id: \.self) { choice in
                    Button {
                        selection = choice
                    } label: {
                        if choice == selection {
                            Label(label(choice), systemImage: "checkmark")
                        } else {
                            Text(label(choice))
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(label(selection))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.09)))
            }
            .accessibilityLabel(Text(title))
        }
    }
}

/// A settings row with a segmented control below the explanation (used for the
/// resolution choices, which read better side by side than in a menu).
struct SettingsSegmentedRow<Choice: Hashable>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let hint: String?
    let choices: [Choice]
    @Binding var selection: Choice
    let label: (Choice) -> String

    init(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        hint: String? = nil,
        choices: [Choice],
        selection: Binding<Choice>,
        label: @escaping (Choice) -> String
    ) {
        self.title = title
        self.description = description
        self.hint = hint
        self.choices = choices
        self._selection = selection
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRowShell(title: title, description: description, hint: hint) {
                Text(label(selection))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Picker(title, selection: $selection) {
                ForEach(choices, id: \.self) { choice in
                    Text(label(choice)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// A settings row with a slider below the explanation and the current value in
/// the trailing position.
struct SettingsSliderRow: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRowShell(title: title, description: description) {
                Text(valueText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .tint(.accentColor)
        }
    }
}

/// A read-only facts row: title on the left, value on the right, optionally
/// with a one-line explanation.
struct SettingsInfoRow: View {
    let title: LocalizedStringKey
    let value: String
    let description: LocalizedStringKey?

    init(title: LocalizedStringKey,
         value: String,
         description: LocalizedStringKey? = nil) {
        self.title = title
        self.value = value
        self.description = description
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                if let description {
                    Text(description)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

/// A row that opens another page.
struct SettingsNavigationRow<Destination: View>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let identifier: String
    private let destination: Destination

    init(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        identifier: String,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.description = description
        self.identifier = identifier
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsRowShell(title: title, description: description) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A row that performs an action (export, clear cache).
struct SettingsActionRow: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let systemImage: String
    let identifier: String
    let isEnabled: Bool
    let action: () -> Void

    init(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRowShell(title: title, description: description) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityIdentifier(identifier)
    }
}

/// The small orange note on rows whose setting is read once at launch.
struct SettingsRestartBadge: View {
    var body: some View {
        Text("Restart required")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.16)))
    }
}

/// A flat group caption inside a category page (for example the Layout page's
/// Performance monitoring group). It keeps the flat style: no card, just a
/// small secondary label above its rows.
struct SettingsSectionCaption: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        SettingsPageScaffold(title: "General") {
            SettingsChoiceRow(
                title: "Fast-forward",
                description: "The speed fast-forward runs at. Audio is muted while fast-forwarding.",
                hint: model.playbackSpeedAutoReduced ? autoReducedText : nil,
                choices: PlaybackSpeed.allCases,
                selection: persistedBinding(settings, \.playbackSpeed),
                label: { $0.title }
            )
            .accessibilityIdentifier("settings-fast-forward")

            // Read-only: the frame cap is fixed to the 3DS's own 60 Hz timeline
            // (the performance page no longer offers a 30 fps cap); fast-forward
            // is the only speed control.
            SettingsInfoRow(
                title: "Frame limiter",
                value: L10n.tr("Automatic 60 Hz"),
                description: "The runtime follows the 3DS's native 60 Hz timeline. Fast-forward is the only speed control."
            )
            .accessibilityIdentifier("settings-frame-limiter")
        }
    }

    /// Fast-forward state when the automatic fallback lowered the speed.
    private var autoReducedText: String {
        L10n.format(
            "Lowered automatically from %@ because frames stayed below 20 fps.",
            L10n.speedLabel(settings.playbackSpeed.rawValue)
        )
    }
}

// MARK: - Layout

struct LayoutSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        SettingsPageScaffold(title: "Layout") {
            SettingsNavigationRow(
                title: "Screen layout",
                description: "Landscape and portrait arrangements, plus the two custom layouts.",
                identifier: "settings-screen-layout"
            ) {
                ScreenLayoutSettingsView(settings: settings)
            }

            SettingsChoiceRow(
                title: "Screen rotation",
                description: "Turn the pictures inside their area for a console held sideways.",
                choices: ScreenRotation.allCases,
                selection: persistedBinding(settings, \.screenRotation),
                label: { $0.title }
            )
            .accessibilityIdentifier("settings-screen-rotation")

            SettingsChoiceRow(
                title: "Orientation lock",
                description: "Which interface orientations the app allows. iOS can still override it, for example during a call.",
                choices: OrientationLock.allCases,
                selection: persistedBinding(settings, \.orientation),
                label: { $0.title }
            )
            .accessibilityIdentifier("settings-orientation-lock")

            SettingsToggleRow(
                title: "Swap screens",
                description: "Swap which screen is shown in the top and bottom positions. The Metal presenter and the software path both follow it.",
                isOn: persistedBinding(settings, \.swapScreens)
            )
            .accessibilityIdentifier("settings-swap-screens")

            SettingsSectionCaption(title: "Performance monitoring")
            SettingsToggleRow(
                title: "FPS counter",
                description: "Show a small frames-per-second pill over the game.",
                isOn: persistedBinding(settings, \.showFPS)
            )
            .accessibilityIdentifier("settings-fps-hud")

            SettingsToggleRow(
                title: "System Metal HUD",
                description: "Apple's GPU performance overlay on the presented Metal layer.",
                hint: hudUnavailableText,
                isOn: persistedBinding(settings, \.systemMetalHUD)
            )
            .accessibilityIdentifier("settings-system-metal-hud")
        }
    }

    /// Why the system Metal HUD switch cannot work right now, if it cannot.
    private var hudUnavailableText: String? {
        if !model.buildEnablesSystemMetalHUD {
            return L10n.tr("This build does not enable the Metal HUD; rebuild the shell with scripts/build-ios-app.sh.")
        }
        if settings.systemMetalHUD && model.isRuntimeLoaded && !model.displayPath.usesMetalLayer {
            return L10n.tr("The game is on the CPU readback path, so the HUD has no Metal layer to attach to.")
        }
        return nil
    }
}

// MARK: - System

struct SystemSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    @State private var storage = StorageSnapshot.empty
    @State private var isClearCacheConfirmationPresented = false

    var body: some View {
        SettingsPageScaffold(title: "System") {
            SettingsInfoRow(
                title: "Installed games",
                value: StorageFormat.size(storage.gamesBytes)
            )
            SettingsInfoRow(
                title: "Save data",
                value: StorageFormat.size(storage.saveDataBytes)
            )
            if storage.romBytes > 0 {
                // 0.1.x shell cartridges: only present on an updated install.
                SettingsInfoRow(
                    title: "Legacy game files",
                    value: StorageFormat.size(storage.romBytes)
                )
            }
            SettingsInfoRow(
                title: "App logs",
                value: StorageFormat.size(storage.logBytes)
            )
            SettingsInfoRow(
                title: "Graphics pipeline cache",
                value: StorageFormat.size(storage.cacheBytes)
            )
            SettingsActionRow(
                title: "Clear graphics pipeline cache",
                description: "The cache is rebuilt on the next load, so that first load is slower. Save data is not touched.",
                systemImage: "trash",
                identifier: "settings-clear-cache",
                isEnabled: !model.isRuntimeActive
            ) {
                isClearCacheConfirmationPresented = true
            }
            if model.isRuntimeActive {
                Text("Available when no game is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsInfoRow(title: "Version", value: versionText)
            SettingsInfoRow(title: "Language", value: L10n.languageSummary)

            SettingsNavigationRow(
                title: "About",
                description: "App version, links, acknowledgements and the legal notice.",
                identifier: "settings-about"
            ) {
                AboutView(model: model)
            }
        }
        .onAppear(perform: refreshStorage)
        .alert("Clear the graphics pipeline cache?", isPresented: $isClearCacheConfirmationPresented) {
            Button("Clear", role: .destructive) {
                clearPipelineCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cache is rebuilt on the next load, so that first load is slower. Save data is not touched.")
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return L10n.format("Version %@ · build %@", version, build)
    }

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

// MARK: - Gamepad

struct GamepadSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        SettingsPageScaffold(title: "Gamepad") {
            SettingsToggleRow(
                title: "Show on-screen controls",
                description: "Draw the virtual buttons over the game.",
                isOn: persistedBinding(settings, \.showTouchControls)
            )
            .accessibilityIdentifier("settings-show-touch-controls")

            SettingsSliderRow(
                title: "Overlay opacity",
                description: "How solid the virtual buttons are.",
                valueText: settingsPercentText(settings.controlsOpacity),
                value: persistedBinding(settings, \.controlsOpacity),
                range: 0.15...1.0,
                step: 0.05
            )
            .accessibilityIdentifier("settings-controls-opacity")

            SettingsToggleRow(
                title: "Haptics",
                description: "A light vibration when an on-screen button is pressed or a control is picked up.",
                isOn: persistedBinding(settings, \.haptics)
            )
            .accessibilityIdentifier("settings-haptics")

            SettingsInfoRow(
                title: "Controller",
                value: model.controllerName ?? L10n.tr("Not connected"),
                description: "The connected game controller, if any."
            )
            .accessibilityIdentifier("settings-controller")
        }
    }
}

// MARK: - Graphics

struct GraphicsSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        SettingsPageScaffold(title: "Graphics") {
            SettingsSegmentedRow(
                title: "Resolution",
                description: "The presenter drawable and the internal 3D render scale. The internal scale changes on the next game load.",
                hint: resolutionCaption(for: settings.renderScale),
                choices: [1, 2, 3, 4],
                selection: persistedBinding(settings, \.renderScale),
                label: { "\($0)x" }
            )
            .accessibilityIdentifier("settings-resolution")

            SettingsSegmentedRow(
                title: "Screen aspect",
                description: "How the preset screen layouts fill the game view: Fit keeps the picture shape, 4:3 fits it into a 4:3 box with black bars, Stretch fills the view and distorts the picture. The custom layouts place each screen explicitly and ignore this.",
                choices: ScreenAspect.allCases,
                selection: persistedBinding(settings, \.screenAspect),
                label: { $0.title }
            )
            .accessibilityIdentifier("settings-screen-aspect")

            SettingsToggleRow(
                title: "Integer scaling",
                description: "With Fit and 4:3, snap each 3DS pixel to a whole number of screen pixels (nearest-pixel magnification). Applies immediately to the preset screen layouts; the custom layouts keep their own placement.",
                isOn: persistedBinding(settings, \.integerScale)
            )
            .accessibilityIdentifier("settings-integer-scaling")

            SettingsToggleRow(
                title: "GPU vertex shading",
                description: "Experimental: run the 3D vertex stage on the GPU. Rendering and performance can change. Takes effect after restarting the app.",
                restartRequired: true,
                isOn: persistedBinding(settings, \.gpuVertexShaders)
            )
            .accessibilityIdentifier("settings-gpu-vertex-shaders")

            SettingsToggleRow(
                title: "Precise shading",
                description: "Experimental: use precise math in the 3D fragment stage instead of the fast approximation. Takes effect after restarting the app.",
                restartRequired: true,
                isOn: persistedBinding(settings, \.preciseShading)
            )
            .accessibilityIdentifier("settings-precise-shading")

            // Read-only backend facts: whether this build carries the MoltenVK
            // framework the presenter needs, and which path the running game uses.
            SettingsInfoRow(
                title: "Renderer",
                value: MetalBackend.isMoltenVKEmbedded
                    ? L10n.tr("Metal via MoltenVK")
                    : L10n.tr("CPU readback (MoltenVK not bundled)"),
                description: "The GPU backend this build ships. The presented screens draw through Metal; without the embedded framework the runtime falls back to its software renderer."
            )
            .accessibilityIdentifier("settings-renderer")

            if model.isRuntimeLoaded {
                SettingsInfoRow(
                    title: "Active path",
                    value: model.displayPath.title
                )
                .accessibilityIdentifier("settings-active-path")
            }
        }
    }
}

// MARK: - Sound

struct SoundSettingsPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPageScaffold(title: "Sound") {
            SettingsSliderRow(
                title: "Volume",
                description: "Game audio volume.",
                valueText: settingsPercentText(settings.audioVolume),
                value: persistedBinding(settings, \.audioVolume),
                range: 0...1,
                step: 0.05
            )
            .accessibilityIdentifier("settings-volume")

            SettingsToggleRow(
                title: "Mute",
                description: "Silence all game audio.",
                isOn: persistedBinding(settings, \.audioMuted)
            )
            .accessibilityIdentifier("settings-mute")

            SettingsChoiceRow(
                title: "Buffer size",
                description: "Audio latency and dropout trade-off. A change restarts the audio engine once while a game runs.",
                choices: AudioBufferSize.allCases,
                selection: persistedBinding(settings, \.audioBuffer),
                label: { $0.title }
            )
            .accessibilityIdentifier("settings-buffer-size")
        }
    }
}

// MARK: - Debug

struct DebugSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    @State private var shareItem: SettingsShareItem?
    /// Path of the last diagnostics export kept in Documents, if it was kept.
    @State private var diagnosticsHint: String?

    var body: some View {
        SettingsPageScaffold(title: "Debug") {
            // Read-only proof that the loaded game really executes AOT code: the
            // build's linked-code state, the runtime's recompiled flag and the
            // interpreted percentage it reports (see AOTDiagnostics).
            SettingsSectionCaption(title: "AOT verification")
            SettingsInfoRow(
                title: "AOT status",
                value: model.aotStatus.title
            )
            .accessibilityIdentifier("settings-aot-status")
            SettingsInfoRow(
                title: "AOT coverage",
                value: settingsAOTPercentText(model.aotDiagnostics.aotPercent)
            )
            .accessibilityIdentifier("settings-aot-coverage")
            SettingsInfoRow(
                title: "Interpreted code",
                value: settingsAOTPercentText(model.aotDiagnostics.interpretedPercent)
            )
            .accessibilityIdentifier("settings-aot-interpreted")
            if let fallbacks = model.aotDiagnostics.instructionFallbacks {
                SettingsInfoRow(
                    title: "Instruction fallbacks",
                    value: L10n.format("%ld", fallbacks)
                )
                .accessibilityIdentifier("settings-aot-fallbacks")
            }

            SettingsNavigationRow(
                title: "Save Manager",
                description: "Battery saves and instant save states for each game.",
                identifier: "settings-save-manager"
            ) {
                SaveManagerView(model: model, saveStates: model.saveStates)
            }

            SettingsNavigationRow(
                title: "CPU profiler",
                description: "Record where the frame time goes while a game runs.",
                identifier: "settings-cpu-profiler"
            ) {
                CPUProfilerView(model: model)
            }

            SettingsActionRow(
                title: "Export logs",
                description: "Write a diagnostics report and the session log, then share them.",
                systemImage: "square.and.arrow.up",
                identifier: "settings-export-logs"
            ) {
                exportDiagnostics()
            }
            if let diagnosticsHint {
                Text(diagnosticsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-diagnostics-hint")
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func exportDiagnostics() {
        guard let export = DiagnosticsExporter.write(model: model, settings: settings) else { return }
        diagnosticsHint = export.documentsPath.map { L10n.format("Saved to Documents/%@", $0) }
        shareItem = SettingsShareItem(url: export.shareURL)
    }

    /// "99.79%" for an AOT percentage, or "Not measured" when the runtime did
    /// not report it (no game loaded, or its status text has no figure).
    private func settingsAOTPercentText(_ value: Double?) -> String {
        guard let value else { return L10n.tr("Not measured") }
        return L10n.format("%.2f%%", value)
    }
}

/// Share-sheet payload for the diagnostics export from the Debug page.
private struct SettingsShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Small helpers

/// "42%" for a 0...1 setting value.
private func settingsPercentText(_ value: Double) -> String {
    L10n.format("%ld%%", Int((value * 100).rounded()))
}

/// The caption under the resolution control: the exact pixels the selected
/// render factor produces. A resolution change takes effect from the next game
/// load (the runtime builds its renderer then); the presented drawable resizes
/// at once.
func resolutionCaption(for renderScale: Int) -> String {
    guard renderScale > 1 else {
        return L10n.tr("1x is the 3DS's native 400×240.")
    }
    return L10n.format("%ldx is %ld×%ld.", renderScale, 400 * renderScale, 240 * renderScale)
}