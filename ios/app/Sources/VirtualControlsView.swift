//
//  VirtualControlsView.swift
//  3ds2apple
//
//  The runtime on-screen controls (user requirement 7): every control the layout
//  profile places, including the two analog sticks.
//
//  - Buttons report ZK_BUTTON_* presses through `onButton`, exactly like the old
//    fixed pad did.
//  - The Circle Pad reports an analog vector through `onCirclePad` (it is NOT a
//    second D-pad: the vector goes into InputState.circleX/circleY and on to
//    zk_set_input()).
//  - The New 3DS C-stick reports its vector through `onCStick` (InputState
//    carries it to zk_set_cstick(); see ios/zakuro-ios/README.md).
//
//  Every control has its own gesture, so several fingers can hold a direction,
//  the circle pad and a face button at the same time. Touches are tracked per
//  view, which is what multi-touch on the 3DS needs (D-pad + A + touchscreen, or
//  Circle Pad + C-stick + ZL in a New 3DS title).
//

import SwiftUI
import UIKit

/// Draws a `ControlLayoutProfile` as an interactive overlay. The container is
/// the whole frame SwiftUI gives it; positions/sizes in the profile are relative
/// to it, so the same profile works on every screen size.
struct VirtualControlsView: View {
    let profile: ControlLayoutProfile
    /// Multiplies every control's own opacity (the Settings "overlay opacity").
    var opacityScale: Double = 1.0
    /// Light haptic feedback on a button press / stick touch.
    var haptics: Bool = false
    /// A button went down (true) or up (false).
    var onButton: (UInt32, Bool) -> Void
    /// Circle Pad vector, -1...1, +x right / +y up (0,0 on release).
    var onCirclePad: (Float, Float) -> Void
    /// C-stick vector, same convention.
    var onCStick: (Float, Float) -> Void

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(ControlElement.allCases) { element in
                    control(element, in: container)
                }
            }
            .frame(width: container.width, height: container.height)
        }
        .accessibilityIdentifier("virtual-controls")
    }

    @ViewBuilder
    private func control(_ element: ControlElement,
                         in container: CGSize) -> some View {
        let placement = profile.placement(for: element)
        // Same point frame the controls editor manipulates; see
        // ControlElement.frame(for:in:) in GameViewGeometry.swift.
        let frame = element.frame(for: placement, in: container)
        let opacity = min(max(placement.opacity * opacityScale, 0.05), 1.0)
        if element.isAnalog {
            AnalogStickControl(
                label: element.symbol,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                diameter: frame.diameter,
                opacity: opacity,
                haptics: haptics,
                onChange: element == .circlePad ? onCirclePad : onCStick
            )
            .position(frame.center)
        } else if let bit = element.buttonBit {
            OverlayButtonControl(
                symbol: element.symbol,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                width: frame.width,
                height: frame.height,
                opacity: opacity,
                haptics: haptics
            ) { pressed in
                onButton(bit, pressed)
            }
            .position(frame.center)
        }
    }

}

// MARK: - One button

/// One overlay button with its own press state. A `DragGesture(minimumDistance:
/// 0)` covers the whole button, so the press starts on touch-down (not on a tap
/// that has already ended) and the release is always reported.
private struct OverlayButtonControl: View {
    let symbol: String
    let accessibilityLabel: String
    let identifier: String
    let width: CGFloat
    let height: CGFloat
    let opacity: Double
    let haptics: Bool
    let onButton: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        Text(symbol)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(isPressed ? 1.0 : 0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: min(width, height) * 0.42, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: min(width, height) * 0.42, style: .continuous)
                    .strokeBorder(Color.white.opacity(isPressed ? 0.55 : 0.25), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .opacity(opacity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        if haptics {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        onButton(true)
                    }
                    .onEnded { _ in
                        isPressed = false
                        onButton(false)
                    }
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(identifier)
    }

    private var fontSize: CGFloat {
        if symbol.count > 2 { return max(min(height * 0.42, 12), 8) }
        if symbol.count == 2 { return max(min(height * 0.42, 14), 8) }
        return max(min(height * 0.45, 20), 9)
    }

    private var backgroundFill: LinearGradient {
        LinearGradient(
            colors: isPressed
                ? [Color.white.opacity(0.44), Color.white.opacity(0.26)]
                : [Color.black.opacity(0.42), Color.black.opacity(0.26)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Analog stick

/// The Circle Pad / C-stick. Dragging anywhere in the stick base moves a knob and
/// reports the vector; releasing recentres it. The knob's travel is limited to
/// the base, and a small dead zone keeps a resting finger at exactly (0,0).
private struct AnalogStickControl: View {
    let label: String
    let accessibilityLabel: String
    let identifier: String
    let diameter: CGFloat
    let opacity: Double
    let haptics: Bool
    let onChange: (Float, Float) -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var isActive = false

    /// Fraction of the radius a resting finger may wander before reporting.
    private static let deadZone: CGFloat = 0.14
    /// How far the knob itself travels, as a fraction of the base radius.
    private static let knobTravel: CGFloat = 0.62

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.42),
                            Color.black.opacity(0.28)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(isActive ? 0.55 : 0.28), lineWidth: 1)
            Circle()
                .fill(Color.white.opacity(isActive ? 0.42 : 0.24))
                .frame(width: diameter * 0.42, height: diameter * 0.42)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
                )
                .offset(knobOffset)
        }
        .frame(width: diameter, height: diameter)
        .opacity(opacity)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isActive {
                        isActive = true
                        if haptics {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    let radius = max(diameter / 2, 1)
                    let dx = value.location.x - diameter / 2
                    let dy = value.location.y - diameter / 2
                    let magnitude = sqrt(dx * dx + dy * dy)
                    guard magnitude > 0.001 else {
                        knobOffset = .zero
                        onChange(0, 0)
                        return
                    }
                    // Knob travel is clamped to the base; the reported vector is
                    // the direction with a dead zone removed from the magnitude,
                    // so a full-deflection drag reaches exactly 1.0.
                    let clamped = min(magnitude / radius, 1.0)
                    let travel = radius * Self.knobTravel
                    knobOffset = CGSize(width: dx / magnitude * clamped * travel,
                                        height: dy / magnitude * clamped * travel)
                    let normalised = (clamped - Self.deadZone) / (1 - Self.deadZone)
                    guard normalised > 0 else {
                        onChange(0, 0)
                        return
                    }
                    // SwiftUI's y grows downwards; the 3DS reports +y up.
                    onChange(Float(dx / magnitude * normalised),
                             Float(-dy / magnitude * normalised))
                }
                .onEnded { _ in
                    isActive = false
                    knobOffset = .zero
                    onChange(0, 0)
                }
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }
}
