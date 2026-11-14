//
//  Theme.swift
//  3ds2apple macOS launcher
//
//  Small design system: one place for colors, spacing and type so the screens
//  stay consistent and the offscreen screenshots look like the real app.
//

import SwiftUI

enum LauncherTheme {
    // Accent: a calm mint over deep ink; readable in light and dark mode.
    static let accent = Color(red: 0.34, green: 0.79, blue: 0.72)
    static let accentDeep = Color(red: 0.10, green: 0.36, blue: 0.45)
    static let success = Color(red: 0.27, green: 0.74, blue: 0.51)
    static let warning = Color(red: 0.95, green: 0.66, blue: 0.25)
    static let danger = Color(red: 0.92, green: 0.38, blue: 0.40)

    static let cardRadius: CGFloat = 12
    static let screenPadding: CGFloat = 24
    static let sidebarWidth: CGFloat = 232

    static var background: Color { Color(nsColor: .windowBackgroundColor) }
    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var sidebarBackground: Color {
        Color(nsColor: .underPageBackgroundColor)
    }
    static var border: Color { Color.primary.opacity(0.10) }
    static var mutedText: Color { Color.primary.opacity(0.62) }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension View {
    /// Card surface used by every panel.
    func launcherCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: LauncherTheme.cardRadius, style: .continuous)
                    .fill(LauncherTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LauncherTheme.cardRadius, style: .continuous)
                    .stroke(LauncherTheme.border, lineWidth: 1)
            )
    }
}
