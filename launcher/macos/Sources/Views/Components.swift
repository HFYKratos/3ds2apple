//
//  Components.swift
//  3ds2apple macOS launcher
//
//  Reusable UI pieces. Everything is pure SwiftUI (no AppKit-backed List/Table/
//  Picker) so the same view tree renders offscreen for screenshots on the
//  headless build VM.
//

import SwiftUI

// MARK: - Screenshot mode

private struct LauncherScreenshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the offscreen screenshot renderer draws a screen: controls that
    /// are AppKit-backed (text fields) fall back to static text and content is not
    /// put inside a ScrollView, so ImageRenderer sees the whole layout.
    var launcherScreenshotMode: Bool {
        get { self[LauncherScreenshotModeKey.self] }
        set { self[LauncherScreenshotModeKey.self] = newValue }
    }
}

// MARK: - Layout

struct ScreenContainer<Content: View>: View {
    @Environment(\.launcherScreenshotMode) private var screenshotMode
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if screenshotMode {
            VStack(alignment: .leading, spacing: 16) {
                content
                Spacer(minLength: 0)
            }
            .padding(LauncherTheme.screenPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(LauncherTheme.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var trailing: AnyView?
    let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let title {
                        Text(title)
                            .font(LauncherTheme.rounded(15, weight: .semibold))
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(LauncherTheme.mutedText)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        trailing
                    }
                }
            }
            content
        }
        .launcherCard()
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(LauncherTheme.mutedText)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(LauncherTheme.mutedText)
                .frame(width: 132, alignment: .leading)
            Text(value)
                .font(mono ? LauncherTheme.mono(12) : .system(size: 12, weight: .medium))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Badges

enum BadgeTone {
    case neutral
    case accent
    case success
    case warning
    case danger

    var foreground: Color {
        switch self {
        case .neutral: return Color.primary.opacity(0.8)
        case .accent: return LauncherTheme.accentDeep
        case .success: return LauncherTheme.success
        case .warning: return LauncherTheme.warning
        case .danger: return LauncherTheme.danger
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Color.primary.opacity(0.07)
        case .accent: return LauncherTheme.accent.opacity(0.18)
        case .success: return LauncherTheme.success.opacity(0.16)
        case .warning: return LauncherTheme.warning.opacity(0.18)
        case .danger: return LauncherTheme.danger.opacity(0.16)
        }
    }
}

struct Badge: View {
    let text: String
    var tone: BadgeTone = .neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tone.background))
    }
}

struct ModeBadge: View {
    let isMock: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isMock ? LauncherTheme.warning : LauncherTheme.success)
                .frame(width: 6, height: 6)
            Text(isMock ? "MOCK / DRY RUN" : "LIVE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(isMock ? LauncherTheme.warning : LauncherTheme.success)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill((isMock ? LauncherTheme.warning : LauncherTheme.success).opacity(0.12)))
    }
}

struct GamePhaseBadge: View {
    let phase: GamePhase

    var body: some View {
        switch phase {
        case .queued:
            Badge(text: "QUEUED", tone: .neutral, symbol: "clock")
        case .building:
            Badge(text: "BUILDING", tone: .accent, symbol: "hammer.fill")
        case .built:
            Badge(text: "AOT READY", tone: .success, symbol: "checkmark.circle.fill")
        case .pushed:
            Badge(text: "ON DEVICE", tone: .accent, symbol: "iphone")
        case .failed:
            Badge(text: "FAILED", tone: .danger, symbol: "exclamationmark.triangle.fill")
        }
    }
}

// MARK: - Progress

struct ProgressBar: View {
    var value: Double
    var height: CGFloat = 6
    var tint: Color = LauncherTheme.accent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

struct StageRow: View {
    let stage: PipelineStage

    private var color: Color {
        switch stage.state {
        case .succeeded: return LauncherTheme.success
        case .running: return LauncherTheme.accent
        case .failed: return LauncherTheme.danger
        case .pending: return Color.primary.opacity(0.28)
        case .skipped: return Color.primary.opacity(0.4)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stage.state.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title)
                    .font(.system(size: 12, weight: stage.state == .pending ? .regular : .semibold))
                    .foregroundStyle(stage.state == .pending ? LauncherTheme.mutedText : Color.primary)
                if !stage.detail.isEmpty {
                    Text(stage.detail)
                        .font(LauncherTheme.mono(10.5))
                        .foregroundStyle(LauncherTheme.mutedText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if stage.state == .running {
                Text("running")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(LauncherTheme.accent)
            }
        }
    }
}

struct TaskProgressCard: View {
    let task: TaskRecord
    var showsStages: Bool = true

    private var badgeTone: BadgeTone {
        switch task.state {
        case .running: return .accent
        case .succeeded: return .success
        case .failed: return .danger
        case .cancelled: return .warning
        case .queued: return .neutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: task.kind.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LauncherTheme.accentDeep)
                Text(task.title)
                    .font(LauncherTheme.rounded(14, weight: .semibold))
                Spacer()
                Badge(text: task.state.title.uppercased(), tone: badgeTone)
                if task.state == .running {
                    Text(String(format: "%.0f%%", task.progress * 100))
                        .font(LauncherTheme.mono(11, weight: .semibold))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
            }
            ProgressBar(value: task.progress, tint: task.state == .failed ? LauncherTheme.danger : LauncherTheme.accent)
            if showsStages {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(task.stages) { stage in
                        StageRow(stage: stage)
                    }
                }
            }
            if let message = task.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LauncherTheme.danger)
                    if let hint = task.errorHint, !hint.isEmpty {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(LauncherTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(LauncherTheme.danger.opacity(0.08)))
            }
        }
        .launcherCard()
    }
}

// MARK: - Logs

struct LogConsole: View {
    let entries: [LogEntry]
    var maximumLines: Int = 14
    var showsHeader: Bool = true
    @Environment(\.launcherScreenshotMode) private var screenshotMode

    private var visible: [LogEntry] {
        if screenshotMode { return Array(entries.suffix(18)) }
        return Array(entries.suffix(maximumLines))
    }

    private var color: Color {
        Color(nsColor: .textBackgroundColor).opacity(0.72)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack {
                    SectionLabel(text: "Log")
                    Spacer()
                    Text(String(entries.count) + " lines")
                        .font(LauncherTheme.mono(10))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if visible.isEmpty {
                    Text("No log lines yet.")
                        .font(LauncherTheme.mono(11))
                        .foregroundStyle(LauncherTheme.mutedText)
                }
                ForEach(visible) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text(entry.level.label)
                            .font(LauncherTheme.mono(9, weight: .bold))
                            .foregroundStyle(levelColor(entry.level))
                            .frame(width: 34, alignment: .leading)
                        Text(entry.message)
                            .font(LauncherTheme.mono(10.5))
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(color))
        }
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info: return LauncherTheme.mutedText
        case .command: return LauncherTheme.accentDeep
        case .success: return LauncherTheme.success
        case .warn: return LauncherTheme.warning
        case .error: return LauncherTheme.danger
        }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = LauncherTheme.accentDeep

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.75 : 1))
            )
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(LauncherTheme.border, lineWidth: 1)
            )
    }
}

struct ChipButton: View {
    let title: String
    var symbol: String?
    var selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? LauncherTheme.accentDeep : Color.primary.opacity(0.7))
            .background(Capsule().fill(selected ? LauncherTheme.accent.opacity(0.2) : Color.primary.opacity(0.05)))
            .overlay(Capsule().stroke(selected ? LauncherTheme.accent.opacity(0.6) : LauncherTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fields

struct LauncherTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @Environment(\.launcherScreenshotMode) private var screenshotMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LauncherTheme.mutedText)
            if screenshotMode {
                Text(text.isEmpty ? placeholder : text)
                    .font(LauncherTheme.mono(12))
                    .foregroundStyle(text.isEmpty ? LauncherTheme.mutedText : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(LauncherTheme.border, lineWidth: 1))
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(LauncherTheme.mono(12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(LauncherTheme.border, lineWidth: 1))
            }
        }
    }
}

// MARK: - Banners and empty states

struct BannerView: View {
    let banner: Banner
    let dismiss: () -> Void

    private var tone: BadgeTone {
        switch banner.kind {
        case .info: return .accent
        case .success: return .success
        case .warning: return .warning
        case .error: return .danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.foreground)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(banner.message)
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LauncherTheme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(tone.background))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tone.foreground.opacity(0.25), lineWidth: 1))
    }

    private var symbol: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LauncherTheme.mutedText)
            Text(title)
                .font(LauncherTheme.rounded(14, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(LauncherTheme.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LauncherTheme.mutedText)
            Text(value)
                .font(LauncherTheme.rounded(18, weight: .bold))
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(LauncherTheme.border, lineWidth: 1))
    }
}

struct ToolStatusRow: View {
    let status: ToolStatus

    private var tone: BadgeTone {
        switch status.state {
        case .ok: return .success
        case .warning: return .warning
        case .missing: return .danger
        }
    }

    private var symbol: String {
        switch status.state {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.foreground)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(status.detail)
                    .font(LauncherTheme.mono(10.5))
                    .foregroundStyle(LauncherTheme.mutedText)
                    .lineLimit(2)
                if status.state != .ok && !status.hint.isEmpty {
                    Text(status.hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(tone.foreground.opacity(0.9))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
