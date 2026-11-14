//
//  TouchControlsView.swift
//  3ds2apple
//
//  I3-T1: semi-transparent on-screen 3DS controls (D-pad, A/B/X/Y,
//  Start/Select, L/R). Presses map onto the ZK_BUTTON_* HID bits and are
//  merged with the hardware controller in `InputState`.
//
//  Portrait uses `TouchControlsView`, the pad under the screens. Landscape uses
//  the three `LandscapeControls*` views: the shoulder buttons and the two button
//  clusters sit in a top bar and in reserved side rails, so no button covers the
//  screens. Both styles report the same ZK_BUTTON_* bits.
//

import SwiftUI
import UIKit

/// On-screen button pad. Every press/release is reported through `onButton`
/// with the corresponding ZK_BUTTON_* bit.
struct TouchControlsView: View {
    /// (button bit, isPressed)
    private let onButton: (UInt32, Bool) -> Void
    /// Background opacity of the pad, 0...1 (the Settings controls slider).
    private let backgroundOpacity: Double
    /// Light haptic feedback on a button press.
    private let haptics: Bool

    init(backgroundOpacity: Double = 0.55,
         haptics: Bool = false,
         onButton: @escaping (UInt32, Bool) -> Void) {
        self.backgroundOpacity = min(max(backgroundOpacity, 0.0), 1.0)
        self.haptics = haptics
        self.onButton = onButton
    }

    var body: some View {
        VStack(spacing: 10) {
            shoulderRow
            HStack(alignment: .center, spacing: 16) {
                dpad
                Spacer(minLength: 0)
                faceButtons
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .accessibilityIdentifier("touch-controls")
    }

    private var shoulderRow: some View {
        HStack(spacing: 10) {
            TouchButton(label: "L", width: 56, height: 34, bit: ZKButton.l, haptics: haptics, onButton: onButton)
            Spacer(minLength: 0)
            TouchButton(label: "Select", width: 62, height: 34, bit: ZKButton.select, haptics: haptics, onButton: onButton)
            TouchButton(label: "Start", width: 62, height: 34, bit: ZKButton.start, haptics: haptics, onButton: onButton)
            Spacer(minLength: 0)
            TouchButton(label: "R", width: 56, height: 34, bit: ZKButton.r, haptics: haptics, onButton: onButton)
        }
    }

    private var dpad: some View {
        VStack(spacing: 7) {
            TouchButton(label: "▲", width: 52, bit: ZKButton.up, haptics: haptics, onButton: onButton)
            HStack(spacing: 7) {
                TouchButton(label: "◀", width: 52, bit: ZKButton.left, haptics: haptics, onButton: onButton)
                Color.clear.frame(width: 52, height: 52)
                TouchButton(label: "▶", width: 52, bit: ZKButton.right, haptics: haptics, onButton: onButton)
            }
            TouchButton(label: "▼", width: 52, bit: ZKButton.down, haptics: haptics, onButton: onButton)
        }
    }

    private var faceButtons: some View {
        VStack(spacing: 7) {
            TouchButton(label: "Y", width: 52, bit: ZKButton.y, haptics: haptics, onButton: onButton)
            HStack(spacing: 7) {
                TouchButton(label: "X", width: 52, bit: ZKButton.x, haptics: haptics, onButton: onButton)
                TouchButton(label: "A", width: 52, bit: ZKButton.a, haptics: haptics, onButton: onButton)
            }
            TouchButton(label: "B", width: 52, bit: ZKButton.b, haptics: haptics, onButton: onButton)
        }
    }
}

/// One overlay button. Press → `onButton(bit, true)`, release →
/// `onButton(bit, false)`.
private struct TouchButton: View {
    private let label: String
    private let width: CGFloat
    private let height: CGFloat
    private let bit: UInt32
    private let haptics: Bool
    private let onButton: (UInt32, Bool) -> Void

    @State private var isPressed = false

    init(
        label: String,
        width: CGFloat = 48,
        height: CGFloat? = nil,
        bit: UInt32,
        haptics: Bool = false,
        onButton: @escaping (UInt32, Bool) -> Void
    ) {
        self.label = label
        self.width = width
        self.height = height ?? width
        self.bit = bit
        self.haptics = haptics
        self.onButton = onButton
    }

    var body: some View {
        Text(label)
            .font(.system(size: width > 50 ? 12 : 17, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(isPressed ? 1 : 0.92))
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isPressed
                                ? [Color.white.opacity(0.42), Color.white.opacity(0.26)]
                                : [Color.white.opacity(0.16), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(isPressed ? 0.5 : 0.22), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        if haptics {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        onButton(bit, true)
                    }
                    .onEnded { _ in
                        isPressed = false
                        onButton(bit, false)
                    }
            )
            .accessibilityIdentifier("btn-\(label)")
    }
}

// MARK: - Landscape controls

/// Sizes shared by the landscape controls. The side rails are wide enough for
/// the 3x3 D-pad and the A/B/X/Y diamond, and the screens keep the space between
/// them, so no button overlaps a screen.
enum LandscapeControlsLayout {
    static let buttonSize: CGFloat = 46
    static let railWidth: CGFloat = 150
    static let shoulderWidth: CGFloat = 58
    static let shoulderHeight: CGFloat = 30
    static let selectStartWidth: CGFloat = 60
    static let selectStartHeight: CGFloat = 30
    static let topBarHeight: CGFloat = 40
    static let railPadding: CGFloat = 8
}

/// The top bar in landscape: Select/Start in the middle. The pause button is
/// drawn by the game view over the trailing end of this row, which is kept free.
struct LandscapeControlsTopBar: View {
    private let backgroundOpacity: Double
    private let haptics: Bool
    private let onButton: (UInt32, Bool) -> Void

    init(backgroundOpacity: Double = 0.55,
         haptics: Bool = false,
         onButton: @escaping (UInt32, Bool) -> Void) {
        self.backgroundOpacity = min(max(backgroundOpacity, 0.0), 1.0)
        self.haptics = haptics
        self.onButton = onButton
    }

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            TouchButton(
                label: "Select",
                width: LandscapeControlsLayout.selectStartWidth,
                height: LandscapeControlsLayout.selectStartHeight,
                bit: ZKButton.select,
                haptics: haptics,
                onButton: onButton
            )
            TouchButton(
                label: "Start",
                width: LandscapeControlsLayout.selectStartWidth,
                height: LandscapeControlsLayout.selectStartHeight,
                bit: ZKButton.start,
                haptics: haptics,
                onButton: onButton
            )
            // Room for the pause button on the trailing side.
            Spacer(minLength: 56)
        }
        .frame(height: LandscapeControlsLayout.topBarHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
        )
        .accessibilityIdentifier("touch-controls-top")
    }
}

/// The left rail in landscape: L at the top, the D-pad centred below it.
struct LandscapeControlsLeftRail: View {
    private let backgroundOpacity: Double
    private let haptics: Bool
    private let onButton: (UInt32, Bool) -> Void

    init(backgroundOpacity: Double = 0.55,
         haptics: Bool = false,
         onButton: @escaping (UInt32, Bool) -> Void) {
        self.backgroundOpacity = min(max(backgroundOpacity, 0.0), 1.0)
        self.haptics = haptics
        self.onButton = onButton
    }

    var body: some View {
        VStack(spacing: 0) {
            TouchButton(
                label: "L",
                width: LandscapeControlsLayout.shoulderWidth,
                height: LandscapeControlsLayout.shoulderHeight,
                bit: ZKButton.l,
                haptics: haptics,
                onButton: onButton
            )
            Spacer(minLength: 8)
            DpadCluster(buttonSize: LandscapeControlsLayout.buttonSize,
                        haptics: haptics,
                        onButton: onButton)
            Spacer(minLength: 8)
        }
        .padding(LandscapeControlsLayout.railPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
        )
        .accessibilityIdentifier("touch-controls-left")
    }
}

/// The right rail in landscape: R at the top, A/B/X/Y centred below it.
struct LandscapeControlsRightRail: View {
    private let backgroundOpacity: Double
    private let haptics: Bool
    private let onButton: (UInt32, Bool) -> Void

    init(backgroundOpacity: Double = 0.55,
         haptics: Bool = false,
         onButton: @escaping (UInt32, Bool) -> Void) {
        self.backgroundOpacity = min(max(backgroundOpacity, 0.0), 1.0)
        self.haptics = haptics
        self.onButton = onButton
    }

    var body: some View {
        VStack(spacing: 0) {
            TouchButton(
                label: "R",
                width: LandscapeControlsLayout.shoulderWidth,
                height: LandscapeControlsLayout.shoulderHeight,
                bit: ZKButton.r,
                haptics: haptics,
                onButton: onButton
            )
            Spacer(minLength: 8)
            FaceButtonCluster(buttonSize: LandscapeControlsLayout.buttonSize,
                              haptics: haptics,
                              onButton: onButton)
            Spacer(minLength: 8)
        }
        .padding(LandscapeControlsLayout.railPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
        )
        .accessibilityIdentifier("touch-controls-right")
    }
}

// MARK: - Button clusters

/// The four direction buttons as a plus.
private struct DpadCluster: View {
    let buttonSize: CGFloat
    let haptics: Bool
    let onButton: (UInt32, Bool) -> Void

    var body: some View {
        VStack(spacing: 4) {
            TouchButton(label: "▲", width: buttonSize, bit: ZKButton.up,
                        haptics: haptics, onButton: onButton)
            HStack(spacing: 4) {
                TouchButton(label: "◀", width: buttonSize, bit: ZKButton.left,
                            haptics: haptics, onButton: onButton)
                Color.clear.frame(width: buttonSize, height: buttonSize)
                TouchButton(label: "▶", width: buttonSize, bit: ZKButton.right,
                            haptics: haptics, onButton: onButton)
            }
            TouchButton(label: "▼", width: buttonSize, bit: ZKButton.down,
                        haptics: haptics, onButton: onButton)
        }
    }
}

/// Y over X/A over B, the 3DS face-button diamond.
private struct FaceButtonCluster: View {
    let buttonSize: CGFloat
    let haptics: Bool
    let onButton: (UInt32, Bool) -> Void

    var body: some View {
        VStack(spacing: 4) {
            TouchButton(label: "Y", width: buttonSize, bit: ZKButton.y,
                        haptics: haptics, onButton: onButton)
            HStack(spacing: 4) {
                TouchButton(label: "X", width: buttonSize, bit: ZKButton.x,
                            haptics: haptics, onButton: onButton)
                TouchButton(label: "A", width: buttonSize, bit: ZKButton.a,
                            haptics: haptics, onButton: onButton)
            }
            TouchButton(label: "B", width: buttonSize, bit: ZKButton.b,
                        haptics: haptics, onButton: onButton)
        }
    }
}
// MARK: - Edge-to-edge landscape overlay

/// Landscape controls drawn directly over the picture, like a handheld skin.
/// The overlay never reserves layout, so hiding the on-screen controls does not
/// move or resize the game picture.
struct LandscapeOverlayControls: View {
    private let backgroundOpacity: Double
    private let haptics: Bool
    private let onButton: (UInt32, Bool) -> Void

    init(backgroundOpacity: Double = 0.55,
         haptics: Bool = false,
         onButton: @escaping (UInt32, Bool) -> Void) {
        self.backgroundOpacity = min(max(backgroundOpacity, 0.0), 1.0)
        self.haptics = haptics
        self.onButton = onButton
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    TouchButton(label: "L", width: 66, height: 34, bit: ZKButton.l,
                                haptics: haptics, onButton: onButton)
                    Spacer(minLength: 12)
                    HStack(spacing: 10) {
                        TouchButton(label: "Select", width: 64, height: 30, bit: ZKButton.select,
                                    haptics: haptics, onButton: onButton)
                        TouchButton(label: "Start", width: 64, height: 30, bit: ZKButton.start,
                                    haptics: haptics, onButton: onButton)
                    }
                    Spacer(minLength: 12)
                    TouchButton(label: "R", width: 66, height: 34, bit: ZKButton.r,
                                haptics: haptics, onButton: onButton)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    DpadCluster(buttonSize: 58, haptics: haptics, onButton: onButton)
                    Spacer(minLength: 24)
                    FaceButtonCluster(buttonSize: 58, haptics: haptics, onButton: onButton)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 14)
            }
        }
        .opacity(0.30 + backgroundOpacity * 0.70)
        .accessibilityIdentifier("touch-controls-overlay")
    }
}
