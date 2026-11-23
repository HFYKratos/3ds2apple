//
//  InGameControlEditOverlay.swift
//  3ds2apple
//
//  In-game control editing (rounds 4–0.1.6-beta2). The menu closes, the runtime
//  stays paused and the controls are edited over the frozen picture.
//
//  0.1.6-beta2: ONE stationary DragGesture on the full-screen canvas, never on a
//  moving control. On start it hit-tests the control (or the single D-pad cross)
//  under the finger, captures its base centre, then renders a local preview from
//  (base + location - start); the profile is committed once in onEnded. This
//  removes the moving-view / moving-coordinate feedback loop that made the
//  edited item jitter between its start and target positions.
//

import SwiftUI
import UIKit

struct InGameControlEditOverlay: View {
    let profile: ControlLayoutProfile
    let isVisible: (ControlElement) -> Bool
    let sizeScale: (ControlElement) -> Double
    let opacityScale: Double
    let haptics: Bool
    /// Committed once per drag; the point is normalised to the container.
    var onMove: (ControlElement, CGPoint) -> Void
    var onDone: () -> Void

    private enum DragTarget {
        case control(ControlElement, base: CGPoint, frame: ControlFrame)
        case dpad(base: CGPoint, span: CGFloat)
    }

    @State private var previewCenters: [ControlElement: CGPoint] = [:]
    @State private var dpadPreviewCenter: CGPoint?
    @State private var target: DragTarget?
    @State private var dragStart: CGPoint?
    @State private var didMove = false

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            ZStack {
                // The stationary canvas gesture: every touch that is not on the
                // Done pill starts here.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(canvasGesture(container: container))
                controlsLayer(container: container)
                doneOverlay
            }
            .frame(width: container.width, height: container.height)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("control-edit-overlay")
    }

    private func canvasGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if target == nil {
                    dragStart = value.startLocation
                    target = hitTest(value.startLocation, container: container)
                    didMove = false
                    if target != nil, haptics {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                guard let target, let start = dragStart else { return }
                let dx = value.location.x - start.x
                let dy = value.location.y - start.y
                if abs(dx) + abs(dy) > 3 { didMove = true }
                switch target {
                case .control(let element, let base, let frame):
                    let proposed = CGPoint(x: base.x + dx, y: base.y + dy)
                    previewCenters[element] = frame.clampedCenter(proposed, in: container)
                case .dpad(let base, let span):
                    let half = span / 2
                    let proposed = CGPoint(x: base.x + dx, y: base.y + dy)
                    dpadPreviewCenter = CGPoint(
                        x: min(max(proposed.x, half), max(container.width - half, half)),
                        y: min(max(proposed.y, half), max(container.height - half, half))
                    )
                }
            }
            .onEnded { _ in
                guard let target else { return }
                if didMove {
                    switch target {
                    case .control(let element, _, _):
                        if let center = previewCenters[element] {
                            onMove(element, CGPoint(x: center.x / max(container.width, 1),
                                                   y: center.y / max(container.height, 1)))
                        }
                    case .dpad(_, _):
                        if let center = dpadPreviewCenter {
                            onMove(.dpadUp, CGPoint(x: center.x / max(container.width, 1),
                                                    y: center.y / max(container.height, 1)))
                        }
                    }
                }
                previewCenters = [:]
                dpadPreviewCenter = nil
                target = nil
                dragStart = nil
                didMove = false
            }
    }

    private func hitTest(_ point: CGPoint, container: CGSize) -> DragTarget? {
        if profile.isDpadVisible(isVisible) {
            let group = profile.dpadGroup(in: container, sizeScale: sizeScale(.dpadUp))
            if group.bounds.contains(point) {
                return .dpad(base: group.center, span: group.span)
            }
        }
        for element in ControlElement.allCases.reversed()
            where !element.isDpadDirection && isVisible(element) {
            let placement = profile.placement(for: element)
            let frame = element.frame(for: placement,
                                      in: container,
                                      sizeScale: sizeScale(element))
            if frame.bounds.contains(point) {
                return .control(element, base: frame.center, frame: frame)
            }
        }
        return nil
    }

    @ViewBuilder
    private func controlsLayer(container: CGSize) -> some View {
        ZStack {
            ForEach(ControlElement.allCases) { element in
                if !element.isDpadDirection && isVisible(element) {
                    let placement = profile.placement(for: element)
                    let frame = element.frame(for: placement,
                                              in: container,
                                              sizeScale: sizeScale(element))
                    let opacity = min(max(placement.opacity * opacityScale, 0.30), 1.0)
                    let displayCenter = previewCenters[element] ?? frame.center
                    EditableControlBox(element: element,
                                       frame: frame,
                                       displayCenter: displayCenter,
                                       opacity: opacity)
                }
            }
            if profile.isDpadVisible(isVisible) {
                let group = profile.dpadGroup(in: container, sizeScale: sizeScale(.dpadUp))
                let opacity = min(max(group.opacity * opacityScale, 0.30), 1.0)
                EditableDpadCrossBox(center: dpadPreviewCenter ?? group.center,
                                     diameter: group.diameter,
                                     opacity: opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private var doneOverlay: some View {
        Button(action: onDone) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                Text(L10n.tr("Done"))
            }
            .font(.body.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(Capsule().fill(Color.accentColor))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("control-edit-done")
    }
}

/// A control drawn in edit mode (no gesture of its own).
private struct EditableControlBox: View {
    let element: ControlElement
    let frame: ControlFrame
    let displayCenter: CGPoint
    let opacity: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(frame.width, frame.height) * 0.42,
                             style: .continuous)
                .fill(Color.accentColor.opacity(0.28))
            RoundedRectangle(cornerRadius: min(frame.width, frame.height) * 0.42,
                             style: .continuous)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
            Group {
                if let systemImage = element.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: max(min(frame.height * 0.4, 16), 7),
                                      weight: .semibold))
                } else {
                    Text(element.symbol)
                        .font(.system(size: max(min(frame.height * 0.36, 14), 7),
                                      weight: .semibold, design: .rounded))
                }
            }
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 2)
        }
        .frame(width: frame.width, height: frame.height)
        .opacity(opacity)
        .position(displayCenter)
        .accessibilityIdentifier("control-edit-\(element.rawValue)")
    }
}

/// The single D-pad cross in edit mode (no gesture of its own).
private struct EditableDpadCrossBox: View {
    let center: CGPoint
    let diameter: CGFloat
    let opacity: Double

    private var span: CGFloat { diameter * 2 }

    var body: some View {
        let localCenter = CGPoint(x: span / 2, y: span / 2)
        ZStack {
            DpadCrossShape()
                .fill(Color.accentColor.opacity(0.28))
            DpadCrossShape()
                .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
            ForEach(ControlLayoutProfile.dpadDirections, id: \.self) { element in
                Text(element.symbol)
                    .font(.system(size: max(min(diameter * 0.22, 14), 8),
                                  weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .position(arrowPosition(for: element, localCenter: localCenter))
            }
        }
        .frame(width: span, height: span)
        .opacity(opacity)
        .position(center)
        .accessibilityIdentifier("control-edit-dpad")
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
