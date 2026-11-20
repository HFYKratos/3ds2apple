//
//  InGameControlEditOverlay.swift
//  3ds2apple
//
//  Round-4 in-game control editing: opened from the paused game's menu, the
//  menu closes, the runtime stays paused and the on-screen controls become
//  directly draggable over the frozen picture (haptic tick on pick-up). The HUD
//  (FPS pill and pause button) is hidden while editing. A centered Done pill
//  saves the current orientation's profile, leaves edit mode and resumes the
//  game directly (no extra pause/resume cycle).
//
//  Hidden controls (pause menu "Toggle controls") are not drawn here; their
//  per-row size scale (pause menu "Adjust size") is applied to the editable
//  frames so the edit matches the running overlay.
//

import SwiftUI
import UIKit

struct InGameControlEditOverlay: View {
    /// The draft profile being edited (already includes earlier drags).
    let profile: ControlLayoutProfile
    let isVisible: (ControlElement) -> Bool
    let sizeScale: (ControlElement) -> Double
    let opacityScale: Double
    let haptics: Bool
    /// A control was dragged; the point is normalised to the container.
    var onMove: (ControlElement, CGPoint) -> Void
    var onDone: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            ZStack {
                // Every touch that is not on a control is a no-op: the game is
                // paused, so a stray drag must not reach the picture.
                Color.clear
                    .contentShape(Rectangle())
                // The D-pad is edited as one cross, not four buttons; its four
                // elements still move/scale together.
                ForEach(ControlElement.allCases) { element in
                    if !element.isDpadDirection && isVisible(element) {
                        editableControl(element, in: container)
                    }
                }
                if profile.isDpadVisible(isVisible) {
                    editableDpad(in: container)
                }
                doneOverlay
            }
            .frame(width: container.width, height: container.height)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("control-edit-overlay")
    }

    /// The Done surface is centered on the screen (round-8 user request): the
    /// hint sits above the pill, and the VStack keeps its intrinsic size so only
    /// the text and the pill are hit-testable — the empty area stays inert.
    private var doneOverlay: some View {
        VStack(spacing: 10) {
            Text(L10n.tr("Drag the controls to move them. Done saves this orientation's layout and resumes the game."))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
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
        .padding(.horizontal, 18)
    }

    /// The single D-pad cross in edit mode. Dragging it moves the whole group
    /// (all four placements); the runtime keeps them in sync.
    private func editableDpad(in container: CGSize) -> some View {
        let group = profile.dpadGroup(in: container, sizeScale: sizeScale(.dpadUp))
        let opacity = min(max(group.opacity * opacityScale, 0.30), 1.0)
        return EditableDpadCrossBox(center: group.center,
                                    diameter: group.diameter,
                                    container: container,
                                    opacity: opacity,
                                    haptics: haptics,
                                    onMove: { point in
                                        onMove(.dpadUp,
                                               CGPoint(x: point.x / max(container.width, 1),
                                                       y: point.y / max(container.height, 1)))
                                    })
    }

    @ViewBuilder
    private func editableControl(_ element: ControlElement, in container: CGSize) -> some View {
        let placement = profile.placement(for: element)
        let frame = element.frame(for: placement,
                                  in: container,
                                  sizeScale: sizeScale(element))
        let opacity = min(max(placement.opacity * opacityScale, 0.30), 1.0)
        EditableControlBox(element: element,
                           frame: frame,
                           container: container,
                           opacity: opacity,
                           haptics: haptics,
                           onMove: { point in
                               onMove(element, CGPoint(x: point.x / max(container.width, 1),
                                                       y: point.y / max(container.height, 1)))
                           })
    }
}

/// One draggable control in edit mode. The gesture applies its total
/// translation to the frame captured when the drag started, so the control
/// follows the finger exactly even while the draft profile updates live.
private struct EditableControlBox: View {
    let element: ControlElement
    let frame: ControlFrame
    let container: CGSize
    let opacity: Double
    let haptics: Bool
    let onMove: (CGPoint) -> Void

    @State private var dragStart: CGPoint?

    private var cornerFactor: CGFloat {
        CGFloat(element.shapeCornerFactor)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(frame.width, frame.height) * 0.42,
                             style: .continuous)
                .fill(Color.accentColor.opacity(0.28))
            RoundedRectangle(cornerRadius: min(frame.width, frame.height) * 0.42,
                             style: .continuous)
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
            Text(element.symbol)
                .font(.system(size: max(min(frame.height * 0.36, 14), 7),
                              weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 2)
        }
        // Round-8 fix: contentShape/gesture attach BEFORE .position. SwiftUI's
        // .position fills the parent container, so a gesture attached after it
        // would make this whole overlay a drag target for the control.
        .frame(width: frame.width, height: frame.height)
        .opacity(opacity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start: CGPoint
                    if let dragStart {
                        start = dragStart
                    } else {
                        start = frame.center
                        dragStart = start
                        if haptics {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    let proposed = CGPoint(x: start.x + value.translation.width,
                                           y: start.y + value.translation.height)
                    onMove(frame.clampedCenter(proposed, in: container))
                }
                .onEnded { _ in
                    dragStart = nil
                }
        )
        .accessibilityIdentifier("control-edit-\(element.rawValue)")
        .position(frame.center)
    }
}
/// The single D-pad cross in edit mode: one draggable plus. It moves all four
/// directional placements together; size changes come from the pause menu's
/// Adjust size sheet (the D-pad row).
private struct EditableDpadCrossBox: View {
    let center: CGPoint
    let diameter: CGFloat
    let container: CGSize
    let opacity: Double
    let haptics: Bool
    let onMove: (CGPoint) -> Void

    @State private var dragStart: CGPoint?

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
        // Round-8 fix: same ordering as EditableControlBox (gesture before
        // .position, so only the cross itself is a drag target).
        .frame(width: span, height: span)
        .opacity(opacity)
        .contentShape(DpadCrossShape())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start: CGPoint
                    if let dragStart {
                        start = dragStart
                    } else {
                        start = center
                        dragStart = start
                        if haptics {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    let half = span / 2
                    let proposed = CGPoint(x: start.x + value.translation.width,
                                           y: start.y + value.translation.height)
                    let clamped = CGPoint(
                        x: min(max(proposed.x, half), max(container.width - half, half)),
                        y: min(max(proposed.y, half), max(container.height - half, half))
                    )
                    onMove(clamped)
                }
                .onEnded { _ in
                    dragStart = nil
                }
        )
        .accessibilityIdentifier("control-edit-dpad")
        .position(center)
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