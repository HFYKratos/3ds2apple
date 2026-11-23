//
//  ScreenLayoutEditorView.swift
//  3ds2apple
//
//  Full-screen custom screen layout editor (0.1.6-beta2). No device frame, no
//  rounded stage border and no padding: the editable canvas is the whole screen
//  and the two screens can be dragged to its edges.
//
//  Interaction: ONE stationary DragGesture on the canvas (never on a moving
//  screen). On start it hit-tests the topmost screen under the finger, captures
//  its base rectangle and renders a local preview from (base + location - start);
//  the draft/settings are committed once in onEnded. Pinch on the same stationary
//  canvas resizes the selected screen. Taps select only; empty space does not
//  move anything. The Done pill is the only overlay text.
//
//  A landscape editor forces the app into landscape while it is open.
//

import Foundation
import SwiftUI

struct ScreenLayoutEditorView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    @State private var orientation: ControlLayoutOrientation
    @State private var draft: CustomScreenLayout
    @State private var selection: ScreenKind = .upper

    // The stationary-canvas drag: hit-tested kind, base rectangle and start
    // point are captured once; only a local preview changes while moving.
    @State private var dragKind: ScreenKind?
    @State private var dragBase: ScreenRect?
    @State private var dragStart: CGPoint?
    @State private var dragMoved = false
    @State private var previewRect: ScreenRect?
    @State private var previewKind: ScreenKind?

    // Pinch resize (stationary canvas).
    @State private var pinchBase: ScreenRect?

    // Snapping guides in canvas points.
    @State private var guideXs: [CGFloat] = []
    @State private var guideYs: [CGFloat] = []

    init(settings: AppSettings, orientation: ControlLayoutOrientation? = nil) {
        self.settings = settings
        let target = orientation ?? GameViewDeviceMetrics.currentLayoutOrientation
        _orientation = State(initialValue: target)
        _draft = State(initialValue: settings.customScreenLayout)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                canvas(available: proxy.size)
                doneOverlay
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            refresh()
            AppOrientation.beginOverride(orientation == .landscape ? .landscape : .portrait)
        }
        .onDisappear {
            AppOrientation.endOverride()
        }
    }

    private func refresh() {
        draft = settings.customScreenLayout.withDefaultsFilled()
        selection = .upper
        dragKind = nil
        dragBase = nil
        dragStart = nil
        previewRect = nil
        previewKind = nil
        guideXs = []
        guideYs = []
    }

    // MARK: - Canvas

    private func canvas(available: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // One stationary gesture layer at the bottom; every drawn item above
            // is non-interactive, so the gesture coordinate space never moves.
            Color.clear
                .contentShape(Rectangle())
                .gesture(canvasDrag(available: available))
                .simultaneousGesture(pinchGesture(available: available))
            controlOverlay(available: available)
                .allowsHitTesting(false)
            screenBox(.upper, available: available)
            screenBox(.lower, available: available)
            guideLines(available: available)
                .allowsHitTesting(false)
        }
        .frame(width: available.width, height: available.height)
        .accessibilityIdentifier("screen-layout-preview")
    }

    private func displayedRect(_ kind: ScreenKind, available: CGSize) -> CGRect {
        let source = (previewKind == kind ? previewRect : nil)
            ?? draft.placement(for: orientation).rect(for: kind)
        return CGRect(x: CGFloat(source.x) * available.width,
                      y: CGFloat(source.y) * available.height,
                      width: CGFloat(source.width) * available.width,
                      height: CGFloat(source.height) * available.height)
    }

    @ViewBuilder
    private func screenBox(_ kind: ScreenKind, available: CGSize) -> some View {
        let rect = displayedRect(kind, available: available)
        EditableScreenBox(kind: kind,
                          rect: rect,
                          screenAspect: CustomScreenGeometry.nativeAspect(for: kind),
                          isSelected: selection == kind,
                          label: label(for: kind))
            .position(x: rect.midX, y: rect.midY)
            .zIndex(kind == .lower ? 2 : 1)
    }

    private func label(for kind: ScreenKind) -> String {
        switch kind {
        case .upper: return L10n.format("Upper screen %@", "400×240")
        case .lower: return L10n.format("Lower screen %@", "320×240")
        }
    }

    /// The translucent current control layout (whole screen), including the
    /// single-cross D-pad, as a non-interactive reference.
    private func controlOverlay(available: CGSize) -> some View {
        let profile = settings.controlLayout(for: orientation)
        let container = CGRect(origin: .zero, size: available)
        return ZStack(alignment: .topLeading) {
            ForEach(ControlElement.allCases) { element in
                if !element.isDpadDirection {
                    let frame = element.frame(for: profile.placement(for: element),
                                              in: container.size)
                    let width = max(frame.width, 6)
                    let height = max(frame.height, 6)
                    RoundedRectangle(cornerRadius: min(width, height) * 0.42, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: min(width, height) * 0.42,
                                             style: .continuous)
                                .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.7)
                        )
                        .frame(width: width, height: height)
                        .position(frame.center)
                }
            }
            let group = profile.dpadGroup(in: available)
            let span = max(group.span, 6)
            ZStack {
                DpadCrossShape()
                    .fill(Color.white.opacity(0.10))
                DpadCrossShape()
                    .stroke(Color.white.opacity(0.38), lineWidth: 0.7)
            }
            .frame(width: span, height: span)
            .position(group.center)
        }
    }

    @ViewBuilder
    private func guideLines(available: CGSize) -> some View {
        if !guideXs.isEmpty || !guideYs.isEmpty {
            Path { path in
                for x in guideXs {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: available.height))
                }
                for y in guideYs {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: available.width, y: y))
                }
            }
            .stroke(Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    // MARK: - Stationary gestures

    private func canvasDrag(available: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragKind == nil {
                    guard let hit = hitTest(value.startLocation, available: available) else {
                        return
                    }
                    dragKind = hit
                    selection = hit
                    dragBase = draft.placement(for: orientation).rect(for: hit)
                    dragStart = value.startLocation
                    dragMoved = false
                }
                guard let kind = dragKind, let base = dragBase, let start = dragStart else {
                    return
                }
                let dx = value.location.x - start.x
                let dy = value.location.y - start.y
                if abs(dx) + abs(dy) > 3 { dragMoved = true }
                var rect = base.cgRect(in: available)
                rect.origin.x += dx
                rect.origin.y += dy
                rect.origin.x = min(max(rect.minX, 0), max(available.width - rect.width, 0))
                rect.origin.y = min(max(rect.minY, 0), max(available.height - rect.height, 0))
                let other = otherRect(for: kind, available: available)
                let snapped = ScreenLayoutSnapping.snap(rect: rect, canvas: available, other: other)
                guideXs = snapped.guidesX
                guideYs = snapped.guidesY
                previewKind = kind
                previewRect = ScreenRect.normalised(snapped.rect, in: available)
            }
            .onEnded { _ in
                if dragMoved { commitPreview() }
                dragKind = nil
                dragBase = nil
                dragStart = nil
                dragMoved = false
                guideXs = []
                guideYs = []
            }
    }

    private func pinchGesture(available: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { factor in
                if pinchBase == nil {
                    pinchBase = draft.placement(for: orientation).rect(for: selection)
                }
                guard let base = pinchBase else { return }
                let rect = base.cgRect(in: available)
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                let scale = max(CGFloat(factor), 0.2)
                var width = min(max(rect.width * scale, 24), available.width)
                var height = min(max(rect.height * scale, 24), available.height)
                if draft.placement(for: orientation).keepsNativeAspect {
                    let aspect = CustomScreenGeometry.nativeAspect(for: selection)
                    height = width / aspect
                    if height > available.height {
                        height = available.height
                        width = height * aspect
                    }
                }
                var x = centre.x - width / 2
                var y = centre.y - height / 2
                x = min(max(x, 0), max(available.width - width, 0))
                y = min(max(y, 0), max(available.height - height, 0))
                previewKind = selection
                previewRect = ScreenRect.normalised(
                    CGRect(x: x, y: y, width: width, height: height), in: available)
            }
            .onEnded { _ in
                guard pinchBase != nil else { return }
                pinchBase = nil
                commitPreview()
            }
    }

    private func hitTest(_ point: CGPoint, available: CGSize) -> ScreenKind? {
        // The lower screen is drawn on top; check it first.
        for kind in [ScreenKind.lower, .upper] {
            if displayedRect(kind, available: available).contains(point) { return kind }
        }
        return nil
    }

    private func otherRect(for kind: ScreenKind, available: CGSize) -> CGRect? {
        let placement = draft.placement(for: orientation)
        let other: ScreenRect = kind == .upper ? placement.bottom : placement.top
        return other.cgRect(in: available)
    }

    /// One write for a finished drag/pinch.
    private func commitPreview() {
        guard let kind = previewKind, let rect = previewRect else { return }
        var layout = draft
        var placement = layout.placement(for: orientation)
        placement.setRect(rect, for: kind)
        layout.setPlacement(placement, for: orientation)
        draft = layout
        previewKind = nil
        previewRect = nil
        settings.selectCustomScreenLayout(for: orientation)
        settings.customScreenLayout = draft
        settings.persist()
    }

    private var doneOverlay: some View {
        Button {
            dismiss()
        } label: {
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
        .accessibilityIdentifier("screen-editor-done")
    }
}

/// A screen box on the full-screen canvas (display only; the canvas gesture
/// owns all interaction).
private struct EditableScreenBox: View {
    let kind: ScreenKind
    let rect: CGRect
    let screenAspect: CGFloat
    let isSelected: Bool
    let label: String

    private var size: CGSize {
        CGSize(width: max(rect.width, 16), height: max(rect.height, 16))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(boxFill)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(pictureFill)
                .frame(width: pictureSize.width, height: pictureSize.height)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.45),
                              lineWidth: isSelected ? 2 : 1)
            Text(label)
                .font(.system(size: max(min(size.width, size.height) * 0.12, 9),
                              weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(2)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityIdentifier("editor-screen-\(kind == .upper ? "upper" : "lower")")
    }

    private var pictureSize: CGSize {
        guard size.width > 0, size.height > 0, screenAspect > 0 else { return .zero }
        if size.width / size.height > screenAspect {
            return CGSize(width: size.height * screenAspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / screenAspect)
    }

    private var boxFill: Color {
        kind == .upper
            ? Color(red: 0.20, green: 0.36, blue: 0.52).opacity(0.45)
            : Color(red: 0.30, green: 0.26, blue: 0.44).opacity(0.45)
    }

    private var pictureFill: Color {
        kind == .upper
            ? Color(red: 0.24, green: 0.42, blue: 0.60)
            : Color(red: 0.36, green: 0.31, blue: 0.54)
    }
}
