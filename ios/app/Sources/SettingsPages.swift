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

/// Colours and metrics shared by the settings pages. Since 0.1.7-beta4 the
/// settings use the system grouped style and semantic colours, so light/dark
/// follows the system appearance like the rest of the app.
enum SettingsTheme {
    static let background = Color(.systemGroupedBackground)
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
        case .other: return "ellipsis.circle"
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

/// Shared page body: an iOS inset-grouped list with a large navigation title.
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
        .navigationBarTitleDisplayMode(.inline)
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

    private enum UpdateStatus {
        case idle
        case checking
        case upToDate(String)
        case available(String)
        case failed
    }

    @State private var updateStatus: UpdateStatus = .idle

    var body: some View {
        SettingsPageScaffold(title: "General") {
            SettingsToggleRow(
                title: "Check for updates",
                description: "When this page opens, look up the latest GitHub release and show whether this build is current. The check is a single request; nothing runs in the background.",
                isOn: persistedBinding(settings, \.checkForUpdates)
            )
            .accessibilityIdentifier("settings-check-for-updates")

            SettingsInfoRow(
                title: "Update status",
                value: updateStatusText,
                description: updateStatusDescription
            )
            .accessibilityIdentifier("settings-update-status")

            SettingsToggleRow(
                title: "Turbo limit",
                description: "Limit the on-screen Turbo button to the selected Turbo speed. Off uses the fastest available speed (4×).",
                isOn: persistedBinding(settings, \.turboLimit)
            )
            .accessibilityIdentifier("settings-turbo-limit")

            SettingsChoiceRow(
                title: "Turbo speed",
                description: "The speed the on-screen Turbo button uses while it is active.",
                choices: [PlaybackSpeed.double, .triple, .quadruple],
                selection: persistedBinding(settings, \.turboSpeed),
                label: { $0.title }
            )
            .accessibilityIdentifier("settings-turbo-speed")

            SettingsChoiceRow(
                title: "Default speed",
                description: "The normal game speed. 1× is the 3DS's own speed; higher values advance extra frames per presented frame.",
                hint: model.playbackSpeedAutoReduced ? autoReducedText : nil,
                choices: PlaybackSpeed.allCases,
                selection: persistedBinding(settings, \.playbackSpeed),
                label: { $0.title }
            )
            .accessibilityIdentifier("settings-default-speed")
        }
        .task { await refreshUpdateStatus() }
        .onChange(of: settings.checkForUpdates) { enabled in
            if enabled {
                Task { await checkForUpdates() }
            } else {
                updateStatus = .idle
            }
        }
    }

    private var updateStatusText: String {
        switch updateStatus {
        case .idle: return L10n.tr("Not checked yet")
        case .checking: return L10n.tr("Checking…")
        case .upToDate(let version): return L10n.format("Up to date (%@)", version)
        case .available(let version): return L10n.format("Update available: %@", version)
        case .failed: return L10n.tr("Check failed")
        }
    }

    private var updateStatusDescription: String {
        switch updateStatus {
        case .idle:
            return L10n.tr("Enable Check for updates to look up the latest GitHub release.")
        case .checking:
            return L10n.tr("Contacting GitHub…")
        case .upToDate:
            return L10n.tr("This build is the latest release the repository reports.")
        case .available:
            return L10n.tr("A newer release is available on GitHub.")
        case .failed:
            return L10n.tr("The update check could not reach GitHub. Try again later.")
        }
    }

    private func refreshUpdateStatus() async {
        guard settings.checkForUpdates else {
            updateStatus = .idle
            return
        }
        await checkForUpdates()
    }

    /// Real update check: the latest GitHub release tag compared with this
    /// app's CFBundleShortVersionString. No fake switch state.
    private func checkForUpdates() async {
        updateStatus = .checking
        guard let url = URL(string: "https://api.github.com/repos/HFYKratos/3ds2apple/releases/latest") else {
            updateStatus = .failed
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                updateStatus = .failed
                return
            }
            struct GitHubRelease: Decodable { let tag_name: String }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst())
                : release.tag_name
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            updateStatus = Self.versionIsNewer(latest, than: current)
                ? .available(latest)
                : .upToDate(latest)
        } catch {
            updateStatus = .failed
        }
    }

    /// Default-speed state when the automatic fallback lowered the speed.
    /// Numeric dotted-version comparison; "0.1.7" is newer than "0.1.6" and
    /// a missing component counts as zero. Pre-release suffixes are ignored for
    /// this user-facing check.
    private static func versionIsNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ raw: String) -> [Int] {
            raw.split(separator: ".").map { part in
                Int(part.prefix(while: { $0.isNumber })) ?? 0
            }
        }
        let a = parts(candidate)
        let b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
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

/// Real system information and the app-wide appearance choice. Storage,
/// version, language and the About page moved to Other in 0.1.7-beta5.
struct SystemSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: ROMSession

    var body: some View {
        SettingsPageScaffold(title: "System") {
            SettingsChoiceRow(
                title: "Appearance",
                description: "Use the system light/dark appearance, or force light or dark for the whole app.",
                choices: AppAppearance.allCases,
                selection: persistedBinding(settings, \.appearance),
                label: { $0.title }
            )
            .accessibilityIdentifier("settings-appearance")

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