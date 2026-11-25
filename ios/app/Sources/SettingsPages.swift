//
//  SettingsPages.swift
//  3ds2apple
//
//  The category pages of the 0.2.1 settings redesign. Everything here follows
//  the system Settings app: an inset-grouped List card per topic with the
//  system section header/footer styling, an iOS large title on every page, and
//  rows that use the system semantic text colours - body regular weight for a
//  row title (no custom bold or semibold), a footnote secondary explanation and
//  a secondary trailing value. Switches keep the system style, choice rows push
//  a radio selection page and navigation rows stay NavigationLink pushes.
//  Colours are semantic, so light
//  and dark appearance follow the system (Settings -> System -> Appearance can
//  still force one if the user asks for it).
//
//  Page layout: General (speed limit, default speed, turbo, update checks),
//  Layout (screens, the performance overlay and the Metal HUD), System
//  (appearance and the device/version facts), Gamepad (on-screen controls and
//  their subpages), Graphics (resolution/aspect plus the experimental GPU
//  switches), Sound (volume/mute/buffer), Debug (AOT verification and tools),
//  and Other (storage, version, language, About).
//
//  The General page order follows reference screenshots of another emulator's
//  settings app for the order only; every string below is our own and is
//  localized through Localizable.strings / L10n. No code or text was copied
//  from that project (it is GPL and reference-only for this repo).
//
//  The two experimental switches are next-launch settings: App.init applies
//  them before the renderer creates its first device, so the rows say that a
//  restart is required. Every existing settings row keeps its behaviour and
//  accessibility identifier.
//

import Foundation
import SwiftUI
import UIKit

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
    case other

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
        case .other: return L10n.tr("Other")
        }
    }

    /// The white SF Symbol on the main page's rounded-square icon tile.
    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .system: return "iphone"
        case .gamepad: return "gamecontroller.fill"
        case .graphics: return "square.grid.2x2.fill"
        case .layout: return "rectangle.split.2x1"
        case .sound: return "speaker.wave.2.fill"
        case .debug: return "chevron.left.forwardslash.chevron.right"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// The tile colour on the main page, like the system Settings app's icons.
    var iconTint: Color {
        switch self {
        case .general: return .gray
        case .system: return .blue
        case .gamepad: return .green
        case .graphics: return .purple
        case .layout: return .orange
        case .sound: return .pink
        case .debug: return .indigo
        case .other: return .teal
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
            case .other:
                OtherSettingsPage(settings: settings, model: model)
            }
        }

    }
}

// MARK: - Page scaffolding

/// Shared page body: an inset-grouped List with the system large title every
/// Settings page uses. Each page builds its own sections and system headers.
struct SettingsPageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    private let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        List {
            content()
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Rows

/// One settings row: a body-weight title, a footnote explanation and a trailing
/// control, matching a row inside a system Settings grouped card.
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if restartRequired {
                    SettingsRestartBadge()
                        .padding(.top, 1)
                }
                if let hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
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

/// A settings row that pushes a radio selection page, the system Settings app's
/// way of choosing one value: the row shows the current value in secondary text
/// and the pushed page lists every choice with a blue checkmark on the selected
/// one. Choosing a value updates the binding and stays on the page.
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
        NavigationLink {
            SettingsChoicePage(
                title: title,
                description: description,
                choices: choices,
                selection: $selection,
                label: label
            )
        } label: {
            SettingsRowShell(title: title, description: description, hint: hint) {
                Text(label(selection))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The radio selection page a choice row pushes: one row per choice with the
/// system blue checkmark on the selected one. Selecting a value updates the
/// setting and keeps the page open, like the system Settings app.
struct SettingsChoicePage<Choice: Hashable>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let choices: [Choice]
    @Binding var selection: Choice
    let label: (Choice) -> String

    var body: some View {
        SettingsPageScaffold(title: title) {
            Section {
                ForEach(choices, id: \.self) { choice in
                    Button {
                        selection = choice
                    } label: {
                        HStack(spacing: 8) {
                            Text(label(choice))
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if choice == selection {
                                Image(systemName: "checkmark")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(description)
            }
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
                    .font(.body)
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
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step)
                .tint(.accentColor)
        }
    }
}

/// A read-only facts row: title on the left, value on the right, optionally
/// with a two-line explanation.
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let description {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

/// A warning row for settings that can heat the device or drain the battery.
struct SettingsWarningRow: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // The List/NavigationLink already draws the disclosure chevron;
            // adding our own made the two chevrons from the user screenshot.
            SettingsRowShell(title: title, description: description) {
                EmptyView()
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
    }
}

/// The small orange note on rows whose setting is read once at launch.
struct SettingsRestartBadge: View {
    var body: some View {
        Text("Restart required")
            .font(.footnote)
            .foregroundStyle(.orange)
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession
    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        SettingsPageScaffold(title: "General") {
            Section {
                SettingsToggleRow(
                    title: "Run speed limit",
                    description: "On: capped speed. Off: uncapped — hot, fast drain, muted.",
                    isOn: persistedBinding(settings, \.runSpeedLimit)
                )
                .accessibilityIdentifier("settings-run-speed-limit")

                if !settings.runSpeedLimit || !settings.turboLimit {
                    SettingsWarningRow(
                        title: "High power use",
                        message: !settings.runSpeedLimit
                            ? "Unlimited speed: device heats up, battery drains fast, audio muted."
                            : "Turbo limit off: holding Turbo is uncapped — hot, fast drain, muted."
                    )
                    .accessibilityIdentifier("settings-unlimited-warning")
                }

                SettingsChoiceRow(
                    title: "Default speed",
                    description: "Normal speed; 1× is native, higher adds frames.",
                    hint: model.playbackSpeedAutoReduced ? autoReducedText : nil,
                    choices: PlaybackSpeed.allCases,
                    selection: persistedBinding(settings, \.playbackSpeed),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-default-speed")

                SettingsToggleRow(
                    title: "Turbo limit",
                    description: "On: Turbo speed, auto-lowered under 20 fps. Off: uncapped.",
                    isOn: persistedBinding(settings, \.turboLimit)
                )
                .accessibilityIdentifier("settings-turbo-limit")

                SettingsChoiceRow(
                    title: "Turbo speed",
                    description: "Turbo button speed while Turbo limit is on.",
                    choices: [PlaybackSpeed.double, .triple, .quadruple],
                    selection: persistedBinding(settings, \.turboSpeed),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-turbo-speed")
            } header: {
                Text("Speed")
            }

            Section {
                SettingsToggleRow(
                    title: "Check for updates",
                    description: "Check GitHub on open and daily; notify on a new release.",
                    isOn: persistedBinding(settings, \.checkForUpdates)
                )
                .accessibilityIdentifier("settings-check-for-updates")

                SettingsChoiceRow(
                    title: "Update channel",
                    description: "Stable: full releases only. Beta: pre-releases too.",
                    choices: UpdateChannel.allCases,
                    selection: persistedBinding(settings, \.updateChannel),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-update-channel")

                SettingsInfoRow(
                    title: "Update status",
                    value: updateStatusText,
                    description: LocalizedStringKey(updateStatusDescription)
                )
                .accessibilityIdentifier("settings-update-status")
            } header: {
                Text("Updates")
            }
        }
        .task { await refreshUpdateStatus() }
        .onChange(of: settings.checkForUpdates) { enabled in
            if enabled {
                Task { await refreshUpdateStatus() }
            }
        }
        .onChange(of: settings.updateChannel) { _ in
            Task { await refreshUpdateStatus() }
        }
    }

    private var updateStatusText: String {
        guard settings.checkForUpdates else { return L10n.tr("Not checked yet") }
        switch updateChecker.status {
        case .idle: return L10n.tr("Not checked yet")
        case .checking: return L10n.tr("Checking…")
        case .upToDate(let version): return L10n.format("Up to date (%@)", version)
        case .available(let version): return L10n.format("Update available: %@", version)
        case .failed: return L10n.tr("Check failed")
        }
    }

    private var updateStatusDescription: String {
        guard settings.checkForUpdates else {
            return L10n.tr("Enable Check for updates to look up releases.")
        }
        switch updateChecker.status {
        case .idle:
            return L10n.tr("Enable Check for updates to look up releases.")
        case .checking:
            return L10n.tr("Contacting GitHub…")
        case .upToDate:
            return L10n.tr("This build is the latest release.")
        case .available:
            return L10n.tr("A newer release is available on GitHub.")
        case .failed:
            return L10n.tr("Could not reach GitHub. Try again later.")
        }
    }

    private func refreshUpdateStatus() async {
        guard settings.checkForUpdates else { return }
        await updateChecker.refresh(channel: settings.updateChannel)
    }

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
            Section {
                SettingsNavigationRow(
                    title: "Screen layout",
                    description: "Landscape and portrait arrangements, plus the two custom layouts.",
                    identifier: "settings-screen-layout"
                ) {
                    ScreenLayoutSettingsView(settings: settings)
                }

                SettingsChoiceRow(
                    title: "Screen rotation",
                    description: "Rotate the picture for a sideways-held console.",
                    choices: ScreenRotation.allCases,
                    selection: persistedBinding(settings, \.screenRotation),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-screen-rotation")

                SettingsChoiceRow(
                    title: "Orientation lock",
                    description: "Allowed orientations; iOS can still override.",
                    choices: OrientationLock.allCases,
                    selection: persistedBinding(settings, \.orientation),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-orientation-lock")

                SettingsToggleRow(
                    title: "Swap screens",
                    description: "Swap top/bottom pictures; both render paths follow.",
                    isOn: persistedBinding(settings, \.swapScreens)
                )
                .accessibilityIdentifier("settings-swap-screens")
            } header: {
                Text("Screens")
            }

            Section {
                SettingsNavigationRow(
                    title: "Performance overlay",
                    description: "Frame rate, frame time, speed and memory over the game.",
                    identifier: "settings-performance-overlay"
                ) {
                    PerformanceOverlaySettingsView(settings: settings)
                }

                SettingsToggleRow(
                    title: "System Metal HUD",
                    description: "Apple's GPU performance overlay on the presented Metal layer.",
                    hint: hudUnavailableText,
                    isOn: persistedBinding(settings, \.systemMetalHUD)
                )
                .accessibilityIdentifier("settings-system-metal-hud")
            } header: {
                Text("Performance monitoring")
            }
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

// MARK: - Performance overlay

/// The performance overlay page (0.2.1-beta4). It replaces the old FPS pill
/// row: two groups, Visibility (the master switch, the background behind the
/// text and the place on screen, which pushes a radio selection page) and
/// Information (one switch per line the overlay can show).
///
/// The page order and the shipped defaults follow reference screenshots of
/// another emulator's settings app; every string here is our own and is
/// localized through Localizable.strings / L10n. The overlay itself is drawn
/// by GameView; this page only stores the choices in AppSettings.
struct PerformanceOverlaySettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPageScaffold(title: "Performance overlay") {
            Section {
                SettingsToggleRow(
                    title: "Enable performance overlay",
                    description: "Draw the overlay over the game picture.",
                    isOn: persistedBinding(settings, \.performanceOverlayEnabled)
                )
                .accessibilityIdentifier("settings-performance-overlay-enabled")

                SettingsToggleRow(
                    title: "Overlay background",
                    description: "Add a background behind the overlay so it is easier to read.",
                    isOn: persistedBinding(settings, \.performanceOverlayBackground)
                )
                .accessibilityIdentifier("settings-performance-overlay-background")

                SettingsChoiceRow(
                    title: "Overlay position",
                    description: "Which place over the game the overlay uses.",
                    choices: PerformanceOverlayPosition.allCases,
                    selection: persistedBinding(settings, \.performanceOverlayPosition),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-performance-overlay-position")
            } header: {
                Text("Visibility")
            }

            Section {
                SettingsToggleRow(
                    title: "Show frame rate",
                    description: "Show the current frames per second.",
                    isOn: persistedBinding(settings, \.performanceOverlayShowFPS)
                )
                .accessibilityIdentifier("settings-performance-overlay-fps")

                SettingsToggleRow(
                    title: "Show frame time",
                    description: "Show how long the current frame took to draw.",
                    isOn: persistedBinding(settings, \.performanceOverlayShowFrameTime)
                )
                .accessibilityIdentifier("settings-performance-overlay-frame-time")

                SettingsToggleRow(
                    title: "Show speed",
                    description: "Show the emulation speed as a percentage of real time.",
                    isOn: persistedBinding(settings, \.performanceOverlayShowSpeed)
                )
                .accessibilityIdentifier("settings-performance-overlay-speed")

                SettingsToggleRow(
                    title: "Show app memory usage",
                    description: "Show how much memory the emulator is using.",
                    isOn: persistedBinding(settings, \.performanceOverlayShowProcessMemory)
                )
                .accessibilityIdentifier("settings-performance-overlay-process-memory")

                SettingsToggleRow(
                    title: "Show available memory",
                    description: "Show how much memory the device still has free.",
                    isOn: persistedBinding(settings, \.performanceOverlayShowAvailableMemory)
                )
                .accessibilityIdentifier("settings-performance-overlay-available-memory")

                SettingsToggleRow(
                    title: "Show battery temperature",
                    description: "Show the battery temperature in °C and °F; unavailable values say so.",
                    isOn: persistedBinding(settings, \.performanceOverlayShowBatteryTemperature)
                )
                .accessibilityIdentifier("settings-performance-overlay-battery")
            } header: {
                Text("Information")
            }
        }
    }
}

// MARK: - System

/// Real system information and the app-wide appearance choice. Storage,
/// version, language and the About page moved to Other in 0.1.7-beta5.
struct SystemSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        SettingsPageScaffold(title: "System") {
            Section {
                SettingsChoiceRow(
                    title: "Appearance",
                    description: "Follow the system, or force light/dark.",
                    choices: AppAppearance.allCases,
                    selection: persistedBinding(settings, \.appearance),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-appearance")
            } header: {
                Text("Display")
            }

            Section {
                SettingsInfoRow(
                    title: "Device",
                    value: UIDevice.current.model,
                    description: "The device this build is running on."
                )
                .accessibilityIdentifier("settings-device")

                SettingsInfoRow(
                    title: "System version",
                    value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                )
                .accessibilityIdentifier("settings-system-version")

                SettingsInfoRow(
                    title: "App version",
                    value: versionText
                )
                .accessibilityIdentifier("settings-app-version")

                SettingsInfoRow(
                    title: "Package",
                    value: packageVersionText
                )
                .accessibilityIdentifier("settings-package-version")
            }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return L10n.format("Version %@ · build %@", version, build)
    }

    private var packageVersionText: String {
        Bundle.main.object(forInfoDictionaryKey: "ThreeDS2ApplePackageVersion") as? String
            ?? L10n.tr("Unknown")
    }
}

// MARK: - Other

/// Storage, version, language and the About page (moved from System in
/// 0.1.7-beta5; the main category is now called Other with an ellipsis icon).
struct OtherSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    @State private var storage = StorageSnapshot.empty
    @State private var isClearCacheConfirmationPresented = false

    var body: some View {
        SettingsPageScaffold(title: "Other") {
            Section {
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
                    description: "Rebuilt next load (one slow load); saves untouched.",
                    systemImage: "trash",
                    identifier: "settings-clear-cache",
                    isEnabled: !model.isRuntimeActive
                ) {
                    isClearCacheConfirmationPresented = true
                }
            } header: {
                Text("Storage")
            } footer: {
                if model.isRuntimeActive {
                    Text("Available when no game is running.")
                }
            }

            Section {
                SettingsInfoRow(title: "Version", value: versionText)
                SettingsInfoRow(title: "Language", value: L10n.languageSummary)
            }

            Section {
                SettingsNavigationRow(
                    title: "About",
                    description: "App version, links, acknowledgements and the legal notice.",
                    identifier: "settings-about"
                ) {
                    AboutView(model: model)
                }
            }
        }
        .onAppear(perform: refreshStorage)
        .alert("Clear the graphics pipeline cache?", isPresented: $isClearCacheConfirmationPresented) {
            Button("Clear", role: .destructive) {
                clearPipelineCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rebuilt next load (one slow load); saves untouched.")
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
            Section {
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
                    description: "Vibrate on button press and control pickup.",
                    isOn: persistedBinding(settings, \.haptics)
                )
                .accessibilityIdentifier("settings-haptics")

                SettingsSliderRow(
                    title: "Deadzone",
                    description: "Stick travel before input; on-screen and controller.",
                    valueText: "\(Int((settings.analogDeadzone * 100).rounded()))%",
                    value: persistedBinding(settings, \.analogDeadzone),
                    range: 0...0.30,
                    step: 0.01
                )
                .accessibilityIdentifier("settings-analog-deadzone")

                SettingsSegmentedRow(
                    title: "Control appearance",
                    description: "Standard: translucent; High contrast: opaque. Built-in only.",
                    choices: ControlAppearance.allCases,
                    selection: persistedBinding(settings, \.controlAppearance),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-control-appearance")
            } header: {
                Text("On-screen controls")
            }

            Section {
                SettingsNavigationRow(
                    title: "Button mapping",
                    description: "Map controller buttons to 3DS buttons; reset restores stock.",
                    identifier: "settings-controller-button-mapping"
                ) {
                    ControllerButtonMappingView(settings: settings)
                }

                SettingsNavigationRow(
                    title: "Hotkeys",
                    description: "Controller combos (2–4 buttons) for Turbo, save/load, screens, menu.",
                    identifier: "settings-hotkeys"
                ) {
                    HotkeySettingsView(settings: settings, model: model)
                }

                SettingsInfoRow(
                    title: "Controller",
                    value: model.controllerName ?? L10n.tr("Not connected"),
                    description: "The connected game controller, if any."
                )
                .accessibilityIdentifier("settings-controller")
            } header: {
                Text("Controller")
            }
        }
    }
}

/// Physical controller button remapping page (0.2.0 C). Every row maps one
/// physical button to a 3DS button; Reset restores the identity mapping. Hotkey
/// remapping is not implemented (see TODO).
struct ControllerButtonMappingView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPageScaffold(title: "Button mapping") {
            Section {
                ForEach(PhysicalControllerButton.allCases) { button in
                    SettingsChoiceRow(
                        title: LocalizedStringKey(button.title),
                        description: "Which 3DS button this physical button sends.",
                        choices: GamepadAction.allCases,
                        selection: actionBinding(for: button),
                        label: { $0.title }
                    )
                    .accessibilityIdentifier("settings-controller-map-\(button.rawValue)")
                }
            } header: {
                Text("Physical controller")
            }

            Section {
                SettingsActionRow(
                    title: "Reset button mapping",
                    description: "Restores the stock controller mapping.",
                    systemImage: "arrow.counterclockwise",
                    identifier: "settings-controller-map-reset"
                ) {
                    settings.resetControllerButtonMap()
                }
            }
        }
    }

    private func actionBinding(for button: PhysicalControllerButton) -> Binding<GamepadAction> {
        Binding(
            get: { settings.controllerAction(for: button) },
            set: { settings.setControllerAction($0, for: button) }
        )
    }
}

// MARK: - Hotkeys

/// Physical-controller hotkey combinations (0.2.0 final). Each row records or
/// chooses a 2–4 button combination; the manager suppresses the combination
/// from the guest while it is held and GameView performs the action once.
struct HotkeySettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession
    @State private var recordingAction: HotkeyAction?

    var body: some View {
        SettingsPageScaffold(title: "Hotkeys") {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(comboText(for: action))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(L10n.tr("Record")) {
                            recordingAction = action
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings-hotkey-record-\(action.rawValue)")
                        if !settings.hotkeyButtons(for: action).isEmpty {
                            Button {
                                settings.clearHotkey(for: action)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings-hotkey-clear-\(action.rawValue)")
                        }
                    }
                    .accessibilityIdentifier("settings-hotkey-\(action.rawValue)")
                }
            } header: {
                Text("Physical controller combinations")
            }

            Section {
                SettingsActionRow(
                    title: "Reset all hotkeys",
                    description: "Clears every controller combination. No hotkey is assigned by default.",
                    systemImage: "arrow.counterclockwise",
                    identifier: "settings-hotkeys-reset"
                ) {
                    settings.resetHotkeys()
                }
            } footer: {
                Text(L10n.tr("A combination triggers once per press and its buttons are not sent to the game while held."))
            }
        }
        .sheet(item: $recordingAction) { action in
            HotkeyRecorderSheet(action: action, settings: settings, model: model)
        }
    }

    private func comboText(for action: HotkeyAction) -> String {
        let buttons = settings.hotkeyButtons(for: action)
        guard !buttons.isEmpty else { return L10n.tr("Not set") }
        return buttons.map(\.title).joined(separator: " + ")
    }
}

/// Records a physical 2–4 button combination live, or lets the user pick a
/// common preset without a controller. Buttons are suppressed from the guest
/// while the sheet is open.
struct HotkeyRecorderSheet: View {
    let action: HotkeyAction
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    @Environment(\.dismiss) private var dismiss
    @State private var pressed: [PhysicalControllerButton] = []
    @State private var captured: [PhysicalControllerButton] = []
    @State private var isTooMany = false

    private static let presets: [[PhysicalControllerButton]] = [
        [.l, .r],
        [.zl, .zr],
        [.l, .r, .zl],
        [.zl, .zr, .start],
        [.l, .r, .start],
        [.select, .start]
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(action.title)
                        .font(.body)
                    Text(L10n.tr("Press and hold 2–4 controller buttons at the same time. Release to record the combination."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(L10n.tr("Captured combination")) {
                    if captured.isEmpty {
                        Text(pressed.isEmpty
                             ? L10n.tr("Waiting for controller buttons…")
                             : pressed.map(\.title).joined(separator: " + "))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(captured.map(\.title).joined(separator: " + "))
                            .font(.body)
                    }
                    if isTooMany {
                        Text(L10n.tr("Too many buttons: use 2–4."))
                            .foregroundStyle(.orange)
                    }
                }
                Section(L10n.tr("Presets")) {
                    ForEach(Self.presets, id: \.self) { preset in
                        Button(preset.map(\.title).joined(separator: " + ")) {
                            captured = preset.sorted { lhs, rhs in
                                index(of: lhs) < index(of: rhs)
                            }
                            isTooMany = false
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.tr("Record hotkey"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("Save")) {
                        settings.setHotkey(captured, for: action)
                        dismiss()
                    }
                    .disabled(captured.count < 2 || captured.count > 4)
                }
            }
        }
        .onAppear {
            model.beginControllerHotkeyRecording { buttons in
                pressed = sorted(buttons)
                if buttons.count >= 2 && buttons.count <= 4 {
                    captured = sorted(buttons)
                    isTooMany = false
                } else if buttons.count > 4 {
                    isTooMany = true
                }
            }
        }
        .onDisappear {
            model.endControllerHotkeyRecording()
        }
    }

    private func sorted(_ buttons: [PhysicalControllerButton]) -> [PhysicalControllerButton] {
        buttons.sorted { index(of: $0) < index(of: $1) }
    }

    private func index(of button: PhysicalControllerButton) -> Int {
        PhysicalControllerButton.allCases.firstIndex(of: button) ?? 0
    }
}

// MARK: - Graphics

struct GraphicsSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        SettingsPageScaffold(title: "Graphics") {
            Section {
                SettingsSegmentedRow(
                    title: "Resolution",
                    description: "Drawable and internal 3D scale; internal applies next load.",
                    hint: resolutionCaption(for: settings.renderScale),
                    choices: [1, 2, 3, 4],
                    selection: persistedBinding(settings, \.renderScale),
                    label: { "\($0)x" }
                )
                .accessibilityIdentifier("settings-resolution")

                SettingsSegmentedRow(
                    title: "Screen aspect",
                    description: "Fit/4:3/Stretch fill presets; custom ignores this.",
                    choices: ScreenAspect.allCases,
                    selection: persistedBinding(settings, \.screenAspect),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-screen-aspect")

                SettingsToggleRow(
                    title: "Integer scaling",
                    description: "Fit/4:3: whole-pixel scaling; presets only.",
                    isOn: persistedBinding(settings, \.integerScale)
                )
                .accessibilityIdentifier("settings-integer-scaling")
            } header: {
                Text("Display")
            }

            Section {
                SettingsToggleRow(
                    title: "GPU vertex shading",
                    description: "Experimental: vertex stage on GPU; needs restart.",
                    restartRequired: true,
                    isOn: persistedBinding(settings, \.gpuVertexShaders)
                )
                .accessibilityIdentifier("settings-gpu-vertex-shaders")

                SettingsToggleRow(
                    title: "Precise shading",
                    description: "Experimental: precise fragment math; needs restart.",
                    restartRequired: true,
                    isOn: persistedBinding(settings, \.preciseShading)
                )
                .accessibilityIdentifier("settings-precise-shading")
            } header: {
                Text("Experimental")
            }

            if model.isRuntimeLoaded {
                Section {
                    SettingsInfoRow(
                        title: "Active path",
                        value: model.displayPath.title
                    )
                    .accessibilityIdentifier("settings-active-path")
                }
            }
        }
    }
}

// MARK: - Sound

struct SoundSettingsPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPageScaffold(title: "Sound") {
            Section {
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
                    description: "Latency vs dropouts; change restarts audio once.",
                    choices: AudioBufferSize.allCases,
                    selection: persistedBinding(settings, \.audioBuffer),
                    label: { $0.title }
                )
                .accessibilityIdentifier("settings-buffer-size")
            } header: {
                Text("Audio")
            }
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
            Section {
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
            } header: {
                Text("AOT verification")
            }

            Section {
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
            } header: {
                Text("Tools")
            } footer: {
                if let diagnosticsHint {
                    Text(diagnosticsHint)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-diagnostics-hint")
                }
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
