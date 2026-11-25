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
    /// Analog-stick dead zone (Settings Gamepad page), 0...0.35.
    var deadzone: Double = 0.14
    /// Built-in High contrast control appearance (Settings Gamepad page).
    var highContrast: Bool = false
    /// Light haptic feedback on a button press / stick touch.
    var haptics: Bool = false
    /// A button went down (true) or up (false).
    var onButton: (UInt32, Bool) -> Void
    /// Circle Pad vector, -1...1, +x right / +y up (0,0 on release).
    var onCirclePad: (Float, Float) -> Void
    /// C-stick vector, same convention.
    var onCStick: (Float, Float) -> Void
    /// Per-control visibility (pause menu "Toggle controls"); a hidden control
    /// is neither drawn nor hit-testable.
    var isVisible: (ControlElement) -> Bool = { _ in true }
    /// Per-control size multiplier (pause menu "Adjust size", 1.0 = 100%).
    var sizeScale: (ControlElement) -> Double = { _ in 1.0 }
    /// Round 0.1.6 app buttons: fast-forward held (true) / released (false).
    var onFastForward: (Bool) -> Void = { _ in }
    /// Round 0.1.6 app buttons: quick-save tapped.
    var onQuickSave: () -> Void = {}
    /// Round 0.1.6-beta2 app buttons.
    var onQuickLoad: () -> Void = {}
    var onSwapScreens: () -> Void = {}
    /// 0.2.1 app button (tap on release, like Quick save): `onSettings` is the
    /// SETTINGS element in the skins' HOME slot and opens the app's in-game
    /// menu (0.2.1-beta3: the separate MENU element and its `onMenu` callback
    /// were removed after user feedback, so the HOME slot is the only app menu
    /// button). It reports no 3DS button bit, so it never touches the hold
    /// logic.
    var onSettings: () -> Void = {}
    /// Whether the Fast-forward toggle is currently active (button highlight).
    var fastForwardActive: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            ZStack(alignment: .topLeading) {
                Color.clear
                // The four D-pad directions are one cross-shaped control on
                // screen (round 7): they stay four elements in the profile for
                // input/visibility/size, but only the cross is drawn.
                ForEach(ControlElement.allCases) { element in
                    if !element.isDpadDirection && isVisible(element) {
                        control(element, in: container)
                    }
                }
                if profile.isDpadVisible(isVisible) {
                    dpadCross(in: container)
                }
            }
            .frame(width: container.width, height: container.height)
        }
        .accessibilityIdentifier("virtual-controls")
    }

    /// The single cross-shaped D-pad. Its group centre is the average of the four
    /// directional placements and one arm's thickness is their average size; the
    /// gesture maps the touch position to one direction (supporting a press-and-
    /// slide to change direction) and reports the matching ZK bit.
    private func dpadCross(in container: CGSize) -> some View {
        let group = profile.dpadGroup(in: container, sizeScale: sizeScale(.dpadUp))
        let opacity = min(max(group.opacity * opacityScale, 0.05), 1.0)
        return DpadCrossControl(center: group.center,
                                diameter: group.diameter,
                                opacity: opacity,
                                haptics: haptics,
                                highContrast: highContrast) { element, pressed in
            if let bit = element.buttonBit {
                onButton(bit, pressed)
            }
        }
    }

    @ViewBuilder
    private func control(_ element: ControlElement,
                         in container: CGSize) -> some View {
        let placement = profile.placement(for: element)
        // Same point frame the controls editor manipulates; see
        // ControlElement.frame(for:in:) in GameViewGeometry.swift. The
        // round-4 size scale multiplies the profile size.
        let frame = element.frame(for: placement,
                                  in: container,
                                  sizeScale: sizeScale(element))
        let opacity = min(max(placement.opacity * opacityScale, 0.05), 1.0)
        if element.isAnalog {
            AnalogStickControl(
                label: element.symbol,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                diameter: frame.diameter,
                opacity: opacity,
                haptics: haptics,
                deadzone: CGFloat(deadzone),
                highContrast: highContrast,
                onChange: element == .circlePad ? onCirclePad : onCStick
            )
            .position(frame.center)
        } else if element == .fastForward {
            OverlayButtonControl(
                symbol: element.symbol,
                systemImage: element.systemImage,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                width: frame.width,
                height: frame.height,
                cornerFactor: CGFloat(element.shapeCornerFactor),
                opacity: opacity,
                haptics: haptics,
                highContrast: highContrast,
                isActive: fastForwardActive
            ) { pressed in
                // A tap toggles the temporary 2x mode (0.1.6-beta2).
                if !pressed { onFastForward(true) }
            }
            .position(frame.center)
        } else if element == .quickLoad {
            OverlayButtonControl(
                symbol: element.symbol,
                systemImage: element.systemImage,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                width: frame.width,
                height: frame.height,
                cornerFactor: CGFloat(element.shapeCornerFactor),
                opacity: opacity,
                haptics: haptics,
                highContrast: highContrast
            ) { pressed in
                if !pressed { onQuickLoad() }
            }
            .position(frame.center)
        } else if element == .swapScreens {
            OverlayButtonControl(
                symbol: element.symbol,
                systemImage: element.systemImage,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                width: frame.width,
                height: frame.height,
                cornerFactor: CGFloat(element.shapeCornerFactor),
                opacity: opacity,
                haptics: haptics,
                highContrast: highContrast
            ) { pressed in
                if !pressed { onSwapScreens() }
            }
            .position(frame.center)
        } else if element == .quickSave {
            OverlayButtonControl(
                symbol: element.symbol,
                systemImage: element.systemImage,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                width: frame.width,
                height: frame.height,
                cornerFactor: CGFloat(element.shapeCornerFactor),
                opacity: opacity,
                haptics: haptics,
                highContrast: highContrast
            ) { pressed in
                if !pressed { onQuickSave() }
            }
            .position(frame.center)
        } else if element == .settings {
            OverlayButtonControl(
                symbol: element.symbol,
                systemImage: element.systemImage,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                width: frame.width,
                height: frame.height,
                cornerFactor: CGFloat(element.shapeCornerFactor),
                opacity: opacity,
                haptics: haptics,
                highContrast: highContrast
            ) { pressed in
                if !pressed { onSettings() }
            }
            .position(frame.center)
        } else if let bit = element.buttonBit {
            OverlayButtonControl(
                symbol: element.symbol,
                systemImage: element.systemImage,
                accessibilityLabel: element.accessibilityTitle,
                identifier: "control-\(element.rawValue)",
                width: frame.width,
                height: frame.height,
                cornerFactor: CGFloat(element.shapeCornerFactor),
                opacity: opacity,
                haptics: haptics,
                highContrast: highContrast
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
    /// SF Symbol for the app-only buttons (nil for console controls).
    let systemImage: String?
    let accessibilityLabel: String
    let identifier: String
    let width: CGFloat
    let height: CGFloat
    /// Corner-radius factor of the rounded square; 0.16 for the D-pad cross.
    let cornerFactor: CGFloat
    let opacity: Double
    let haptics: Bool
    let highContrast: Bool
    /// Toggled buttons (Fast-forward) draw their active background.
    var isActive: Bool = false
    let onButton: (Bool) -> Void

    @State private var isPressed = false

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: max(min(height * 0.42, 20), 8),
                                  weight: .semibold))
            } else {
                Text(symbol)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
            .foregroundColor(.white.opacity(highContrast ? 1.0 : (isPressed ? 1.0 : 0.92)))
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: min(width, height) * 0.42, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: min(width, height) * 0.42, style: .continuous)
                    .strokeBorder(Color.white.opacity(highContrast ? 0.95 : (isPressed ? 0.55 : 0.25)),
                                  lineWidth: highContrast ? 2 : 1)
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
            colors: isActive
                ? [Color.accentColor.opacity(0.75), Color.accentColor.opacity(0.50)]
                : (isPressed
                    ? [Color.white.opacity(highContrast ? 0.62 : 0.44),
                       Color.white.opacity(highContrast ? 0.40 : 0.26)]
                    : [Color.black.opacity(highContrast ? 0.82 : 0.42),
                       Color.black.opacity(highContrast ? 0.66 : 0.26)]),
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
    let deadzone: CGFloat
    let highContrast: Bool
    let onChange: (Float, Float) -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var isActive = false

    /// How far the knob itself travels, as a fraction of the base radius.
    private static let knobTravel: CGFloat = 0.62

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(highContrast ? 0.84 : 0.42),
                            Color.black.opacity(highContrast ? 0.68 : 0.28)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(highContrast ? 0.95 : (isActive ? 0.55 : 0.28)),
                              lineWidth: highContrast ? 2 : 1)
            Circle()
                .fill(Color.white.opacity(highContrast ? 0.72 : (isActive ? 0.42 : 0.24)))
                .frame(width: diameter * 0.42, height: diameter * 0.42)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(highContrast ? 0.85 : 0.30),
                                          lineWidth: highContrast ? 1.5 : 1)
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
                    let dz = min(max(deadzone, 0), 0.9)
                    let normalised = (clamped - dz) / (1 - dz)
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
// MARK: - D-pad cross

/// One rounded plus: a vertical bar and a horizontal bar of the same thickness
/// (`diameter`), so the whole cross spans 2 x diameter. The eight outer corners
/// are rounded; the four inner corners stay sharp like a real D-pad.
struct DpadCrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 1 else { return Path() }
        let thickness = side / 2
        let radius = thickness * 0.16
        let ox = rect.midX - side / 2
        let oy = rect.midY - side / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x, y: oy + y)
        }
        let t = thickness
        let vertices: [CGPoint] = [
            point(t / 2, 0), point(3 * t / 2, 0),
            point(3 * t / 2, t / 2), point(2 * t, t / 2),
            point(2 * t, 3 * t / 2), point(3 * t / 2, 3 * t / 2),
            point(3 * t / 2, 2 * t), point(t / 2, 2 * t),
            point(t / 2, 3 * t / 2), point(0, 3 * t / 2),
            point(0, t / 2), point(t / 2, t / 2)
        ]
        let convex = [true, true, false, true, true, false,
                      true, true, false, true, true, false]
        func unit(_ from: CGPoint, _ to: CGPoint) -> CGVector {
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
            return CGVector(dx: dx / length, dy: dy / length)
        }
        var path = Path()
        let count = vertices.count
        var started = false
        for index in 0..<count {
            let previous = vertices[(index + count - 1) % count]
            let vertex = vertices[index]
            let next = vertices[(index + 1) % count]
            if convex[index] {
                let incoming = unit(previous, vertex)
                let outgoing = unit(vertex, next)
                let start = CGPoint(x: vertex.x - incoming.dx * radius,
                                    y: vertex.y - incoming.dy * radius)
                let end = CGPoint(x: vertex.x + outgoing.dx * radius,
                                  y: vertex.y + outgoing.dy * radius)
                if started {
                    path.addLine(to: start)
                } else {
                    path.move(to: start)
                    started = true
                }
                path.addQuadCurve(to: end, control: vertex)
            } else if started {
                path.addLine(to: vertex)
            } else {
                path.move(to: vertex)
                started = true
            }
        }
        path.closeSubpath()
        return path
    }
}

/// The single runtime D-pad: a dark translucent plus with four arrows. A drag
/// over the arms reports one direction at a time; sliding from one arm to
/// another releases the old bit and presses the new one, and releasing the
/// gesture releases everything.
private struct DpadCrossControl: View {
    let center: CGPoint
    let diameter: CGFloat
    let opacity: Double
    let haptics: Bool
    let highContrast: Bool
    let onPress: (ControlElement, Bool) -> Void

    @State private var direction: ControlElement?

    private static let directions: [ControlElement] = ControlLayoutProfile.dpadDirections

    private var span: CGFloat { diameter * 2 }

    var body: some View {
        let localCenter = CGPoint(x: span / 2, y: span / 2)
        ZStack {
            DpadCrossShape()
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(highContrast ? 0.84 : 0.46),
                                 Color.black.opacity(highContrast ? 0.68 : 0.30)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            DpadCrossShape()
                .stroke(Color.white.opacity(highContrast ? 0.95 : (direction == nil ? 0.28 : 0.46)),
                        lineWidth: highContrast ? 2 : 1)
            if let direction {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: diameter * 0.62, height: diameter * 0.62)
                    .position(arrowPosition(for: direction, localCenter: localCenter))
            }
            ForEach(Self.directions, id: \.self) { element in
                Text(element.symbol)
                    .font(.system(size: max(min(diameter * 0.24, 18), 9),
                                  weight: .semibold, design: .rounded))
                    .foregroundColor(direction == nil || direction == element
                                     ? .white.opacity(highContrast ? 1.0 : 0.92)
                                     : .white.opacity(highContrast ? 0.70 : 0.38))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .position(arrowPosition(for: element, localCenter: localCenter))
            }
        }
        .frame(width: span, height: span)
        .opacity(opacity)
        .contentShape(DpadCrossShape())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let newDirection = direction(at: value.location, localCenter: localCenter)
                    guard newDirection != direction else { return }
                    if let old = direction, let bit = old.buttonBit {
                        onPress(old, false)
                    }
                    if let newDirection, let bit = newDirection.buttonBit {
                        direction = newDirection
                        if haptics {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        onPress(newDirection, true)
                    } else {
                        direction = nil
                    }
                }
                .onEnded { _ in
                    if let old = direction, let bit = old.buttonBit {
                        onPress(old, false)
                    }
                    direction = nil
                }
        )
        .position(center)
        .accessibilityLabel(L10n.tr("D-pad"))
        .accessibilityIdentifier("dpad-cross")
    }

    private func direction(at location: CGPoint, localCenter: CGPoint) -> ControlElement? {
        let dx = location.x - localCenter.x
        let dy = location.y - localCenter.y
        // The middle of the cross is neutral; the arms report their direction.
        if abs(dx) < diameter * 0.18 && abs(dy) < diameter * 0.18 {
            return nil
        }
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? .dpadRight : .dpadLeft
        }
        return dy >= 0 ? .dpadDown : .dpadUp
    }

    private func arrowPosition(for element: ControlElement, localCenter: CGPoint) -> CGPoint {
        let offset = diameter * 0.52
        switch element {
        case .dpadUp: return CGPoint(x: localCenter.x, y: localCenter.y - offset)
        case .dpadDown: return CGPoint(x: localCenter.x, y: localCenter.y + offset)
        case .dpadLeft: return CGPoint(x: localCenter.x - offset, y: localCenter.y)
        case .dpadRight: return CGPoint(x: localCenter.x + offset, y: localCenter.y)
        default: return localCenter
        }
    }
}