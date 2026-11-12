//
//  TouchControlsView.swift
//  3ds2apple
//
//  I3-T1: semi-transparent on-screen 3DS controls (D-pad, A/B/X/Y,
//  Start/Select, L/R). Presses map onto the ZK_BUTTON_* HID bits and are
//  merged with the hardware controller in `InputState`.
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
            HStack(alignment: .center, spacing: 18) {
                dpad
                Spacer(minLength: 0)
                faceButtons
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
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
        VStack(spacing: 6) {
            TouchButton(label: "▲", bit: ZKButton.up, haptics: haptics, onButton: onButton)
            HStack(spacing: 6) {
                TouchButton(label: "◀", bit: ZKButton.left, haptics: haptics, onButton: onButton)
                Color.clear.frame(width: 48, height: 48)
                TouchButton(label: "▶", bit: ZKButton.right, haptics: haptics, onButton: onButton)
            }
            TouchButton(label: "▼", bit: ZKButton.down, haptics: haptics, onButton: onButton)
        }
    }

    private var faceButtons: some View {
        VStack(spacing: 6) {
            TouchButton(label: "Y", bit: ZKButton.y, haptics: haptics, onButton: onButton)
            HStack(spacing: 6) {
                TouchButton(label: "X", bit: ZKButton.x, haptics: haptics, onButton: onButton)
                TouchButton(label: "A", bit: ZKButton.a, haptics: haptics, onButton: onButton)
            }
            TouchButton(label: "B", bit: ZKButton.b, haptics: haptics, onButton: onButton)
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
            .foregroundColor(.white)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPressed ? Color.white.opacity(0.45) : Color.white.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
            )
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
