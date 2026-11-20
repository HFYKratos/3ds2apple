//
//  ScreenLayoutEditorView.swift
//  3ds2apple
//
//  The full-screen custom screen layout drag editor.
//
//  The numeric custom layout page ("Edit by dragging") opens it for one fixed
//  direction (portrait edits the portrait layout, landscape the landscape one),
//  and the canvas is the whole screen. The canvas mirrors the running game view
//  (GameViewGeometry.swift): the real safe area and the full-bleed picture
//  stage, with the floating controls over the whole screen. The current
//  on-screen control layout is drawn over the picture, translucent and
//  non-interactive, so the screens can be placed between or away from the
//  controls.
//
//  Round-4 interaction: drag a screen directly to move it, drag its large
//  (>=44 pt) corner handle or pinch to resize it, and tap the one clear Done pill
//  (bottom centre) to save and leave. Movement snaps to the stage edges/centre
//  and to the other screen with dashed guides; every change is saved immediately
//  and there is no scrolling/zooming surface in the editor.
//
//  The custom layout still runs on the software readback path - the upstream
//  Zakuro presenter only knows its fixed arrangements - so it applies from the
//  next game load. Archive: CustomScreenLayout version 3 (older archives are
//  migrated on read); see CustomScreenLayout.swift and ios/app/README.md.
//

import Foundation
import SwiftUI

struct ScreenLayoutEditorView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    /// The direction this editor edits. Fixed when the page opens: portrait and
    /// landscape keep separate saved layouts.
    @State private var orientation: ControlLayoutOrientation
    @State private var draft: CustomScreenLayout
    @State private var selection: ScreenKind = .upper
    @State private var metrics: GameViewDeviceMetrics = .current()
    @State private var undoStack: [CustomScreenLayout] = []

    // Gesture bookkeeping: a gesture always applies its total translation to the
    // rectangle captured when it started, never to the already-moved one.
    @State private var moveBase: ScreenRect?
    @State private var resizeBase: ScreenRect?
    @State private var pinchBase: ScreenRect?

    // Snapping guides (stage points).
    @State private var guideXs: [CGFloat] = []
    @State private var guideYs: [CGFloat] = []

    /// `orientation` nil means "the direction the device is held in right now".
    /// The headless screenshot launch passes one explicitly.
    init(settings: AppSettings, orientation: ControlLayoutOrientation? = nil) {
        self.settings = settings
        let target = orientation ?? GameViewDeviceMetrics.currentLayoutOrientation
        _orientation = State(initialValue: target)
        _draft = State(initialValue: settings.customScreenLayout)
    }

    private var geometry: GameViewPreviewGeometry {
        GameViewPreviewGeometry.make(orientation: orientation, metrics: metrics)
    }

    /// The upright canvas the rectangles are stored in (the stage, or the stage
    /// with its sides swapped for a quarter-turn screen rotation).
    private var canvasPointSize: CGSize {
        CustomScreenGeometry.canvasSize(available: geometry.screenStageRect.size,
                                        rotation: settings.screenRotation)
    }

    private var canvasAspect: CGFloat {
        let canvas = canvasPointSize
        guard canvas.height > 0 else { return 1 }
        return canvas.width / canvas.height
    }

    private var rotationDegrees: Double {
        switch settings.screenRotation {
        case .upright: return 0
        case .clockwise: return 90
        case .upsideDown: return 180
        case .counterClockwise: return -90
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black
                canvas(available: proxy.size)
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                doneOverlay
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear(perform: refresh)
    }

    private func refresh() {
        metrics = .current()
        // Heal an older archive that hid a screen: the simplified editor only
        // knows "both screens shown", and the value is saved on the next edit.
        draft = settings.customScreenLayout.withDefaultsFilled()
        undoStack = []
        selection = .upper
    }

    // MARK: - Canvas

    private func canvas(available: CGSize) -> some View {
        let scaler = GameViewPreviewScaler(available: available,
                                          metrics: metrics,
                                          orientation: orientation,
                                          padding: 8)
        return ZStack(alignment: .topLeading) {
            Color.clear
            deviceFrame(scaler)
            stageView(scaler)
            controlOverlay(scaler)
        }
        .frame(width: available.width, height: available.height)
        .contentShape(Rectangle())
        .simultaneousGesture(pinchGesture)
        .accessibilityIdentifier("screen-layout-preview")
    }

    private func deviceFrame(_ scaler: GameViewPreviewScaler) -> some View {
        let rect = scaler.screenRect
        let radius = min(rect.width, rect.height) * 0.07
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(white: 0.07))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    /// The translucent current control layout: the reference the user places the
    /// picture against. Not interactive, so every gesture reaches the screens.
    private func controlOverlay(_ scaler: GameViewPreviewScaler) -> some View {
        let container = geometry.controlContainerRect
        let profile = settings.controlLayout(for: orientation)
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(ControlElement.allCases) { element in
                let frame = element.frame(for: profile.placement(for: element),
                                         in: container.size)
                let center = scaler.point(CGPoint(x: container.minX + frame.center.x,
                                                  y: container.minY + frame.center.y))
                let width = max(scaler.length(frame.width), 6)
                let height = max(scaler.length(frame.height), 6)
                RoundedRectangle(cornerRadius: min(width, height) * 0.42, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: min(width, height) * 0.42,
                                         style: .continuous)
                            .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.7)
                    )
                    .overlay(
                        Text(element.symbol)
                            .font(.system(size: max(min(height * 0.36, 10), 5),
                                          weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    )
                    .frame(width: width, height: height)
                    .position(center)
            }
        }
        .allowsHitTesting(false)
    }

    private func stageView(_ scaler: GameViewPreviewScaler) -> some View {
        let stage = scaler.rect(geometry.screenStageRect)
        let canvas = canvasPointSize
        let previewCanvas = CGSize(width: canvas.width * scaler.scale,
                                   height: canvas.height * scaler.scale)
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)
            screensCanvas(scaler, canvas: canvas)
                .frame(width: previewCanvas.width, height: previewCanvas.height)
                .rotationEffect(.degrees(rotationDegrees))
        }
        .frame(width: stage.width, height: stage.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .position(x: stage.midX, y: stage.midY)
    }

    private func screensCanvas(_ scaler: GameViewPreviewScaler,
                               canvas: CGSize) -> some View {
        let scale = scaler.scale
        let preview = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        let placement = draft.placement(for: orientation)
        return ZStack(alignment: .topLeading) {
            Color.clear
            // Both screens are always shown in the simplified editor; the model
            // heals the old "only one screen" flags on read.
            editableScreen(.upper, source: placement.top, canvas: canvas, scale: scale)
            editableScreen(.lower, source: placement.bottom, canvas: canvas, scale: scale)
            guideLines(preview: preview, scale: scale)
        }
        .frame(width: preview.width, height: preview.height)
    }

    private func editableScreen(_ kind: ScreenKind,
                                source: ScreenRect,
                                canvas: CGSize,
                                scale: CGFloat) -> some View {
        let rect = CGRect(x: CGFloat(source.x) * canvas.width * scale,
                          y: CGFloat(source.y) * canvas.height * scale,
                          width: CGFloat(source.width) * canvas.width * scale,
                          height: CGFloat(source.height) * canvas.height * scale)
        return EditableScreenBox(
            kind: kind,
            rect: rect,
            screenAspect: CustomScreenGeometry.nativeAspect(for: kind),
            isSelected: selection == kind,
            label: label(for: kind),
            onBeginMove: { beginMove(kind) },
            onMove: { translation in move(kind, translation: translation, scale: scale) },
            onEndMove: { endMove() },
            onBeginResize: { beginResize(kind) },
            onResize: { translation in resize(kind, translation: translation, scale: scale) },
            onEndResize: { endResize() },
            onSelect: { selection = kind }
        )
        .position(x: rect.midX, y: rect.midY)
        .zIndex(selection == kind ? 2 : 1)
    }

    private func label(for kind: ScreenKind) -> String {
        switch kind {
        case .upper:
            return L10n.format("Upper screen %@", "400×240")
        case .lower:
            return L10n.format("Lower screen %@", "320×240")
        }
    }

    @ViewBuilder
    private func guideLines(preview: CGSize, scale: CGFloat) -> some View {
        if !guideXs.isEmpty || !guideYs.isEmpty {
            Path { path in
                for x in guideXs {
                    path.move(to: CGPoint(x: x * scale, y: 0))
                    path.addLine(to: CGPoint(x: x * scale, y: preview.height))
                }
                for y in guideYs {
                    path.move(to: CGPoint(x: 0, y: y * scale))
                    path.addLine(to: CGPoint(x: preview.width, y: y * scale))
                }
            }
            .stroke(Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("Custom screen layout"))
                    .font(.footnote.weight(.semibold))
                Text(L10n.format("Editing the %@ layout", orientation.title))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// The round-4 Done surface: one obvious pill over the canvas (the edits are
    /// already committed live), with the interaction hint above it.
    private var doneOverlay: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(L10n.tr("Drag a screen to move it. Drag the large corner handle or pinch to resize. Done saves the layout."))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
            Button {
                commit()
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
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(L10n.tr("Drag to move, pinch to scale. The controls are shown for reference."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if settings.screenRotation != .upright {
                Text(L10n.tr("The game applies the screen rotation; this editor arranges the upright screens."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 14) {
                Button {
                    undo()
                } label: {
                    Label(L10n.tr("Undo"), systemImage: "arrow.uturn.backward")
                }
                .disabled(undoStack.isEmpty)
                Toggle(isOn: keepsAspectBinding) {
                    Label(L10n.tr("Lock ratio"), systemImage: "lock")
                }
                .fixedSize()
                .accessibilityIdentifier("screen-lock-ratio")
                Spacer(minLength: 4)
                Menu {
                    Button(L10n.tr("Reset screen layout"), role: .destructive) {
                        resetOrientation()
                    }
                    Button(L10n.tr("Reset both screen layouts"), role: .destructive) {
                        resetBoth()
                    }
                } label: {
                    Label(L10n.tr("Reset"), systemImage: "arrow.counterclockwise")
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Bindings

    private var keepsAspectBinding: Binding<Bool> {
        Binding(
            get: { draft.placement(for: orientation).keepsNativeAspect },
            set: { value in
                pushUndo()
                var layout = draft
                var placement = layout.placement(for: orientation)
                placement.keepsNativeAspect = value
                if value {
                    placement = placement.withNativeAspect(containerAspect: canvasAspect)
                }
                layout.setPlacement(placement, for: orientation)
                draft = layout
                commit()
            }
        )
    }

    // MARK: - Gestures

    private func beginMove(_ kind: ScreenKind) {
        selection = kind
        guard moveBase == nil else { return }
        pushUndo()
        moveBase = draft.placement(for: orientation).rect(for: kind)
    }

    private func move(_ kind: ScreenKind, translation: CGSize, scale: CGFloat) {
        guard let base = moveBase else { return }
        let canvas = canvasPointSize
        let factor = max(scale, 0.0001)
        var rect = base.cgRect(in: canvas)
        rect.origin.x += translation.width / factor
        rect.origin.y += translation.height / factor
        rect.origin.x = min(max(rect.minX, 0), max(canvas.width - rect.width, 0))
        rect.origin.y = min(max(rect.minY, 0), max(canvas.height - rect.height, 0))
        let placement = draft.placement(for: orientation)
        var other: CGRect?
        switch kind {
        case .upper: other = placement.bottom.cgRect(in: canvas)
        case .lower: other = placement.top.cgRect(in: canvas)
        }
        let snapped = ScreenLayoutSnapping.snap(rect: rect, canvas: canvas, other: other)
        guideXs = snapped.guidesX
        guideYs = snapped.guidesY
        apply(kind, rect: ScreenRect.normalised(snapped.rect, in: canvas))
    }

    private func endMove() {
        moveBase = nil
        guideXs = []
        guideYs = []
        commit()
    }

    private func beginResize(_ kind: ScreenKind) {
        selection = kind
        guard resizeBase == nil else { return }
        pushUndo()
        resizeBase = draft.placement(for: orientation).rect(for: kind)
    }

    private func resize(_ kind: ScreenKind, translation: CGSize, scale: CGFloat) {
        guard let base = resizeBase else { return }
        let canvas = canvasPointSize
        let factor = max(scale, 0.0001)
        let rect = base.cgRect(in: canvas)
        let screenAspect = CustomScreenGeometry.nativeAspect(for: kind)
        let locked = draft.placement(for: orientation).keepsNativeAspect
        let maximumWidth = max(canvas.width - rect.minX, 32)
        let maximumHeight = max(canvas.height - rect.minY, 32)
        var width = max(rect.width + translation.width / factor, 32)
        var height = max(rect.height + translation.height / factor, 32)
        if locked {
            // The console screen's shape: in points, width / height = aspect.
            width = min(width, maximumWidth)
            height = width / screenAspect
            if height > maximumHeight {
                height = maximumHeight
                width = height * screenAspect
            }
            if width > maximumWidth {
                width = maximumWidth
                height = width / screenAspect
            }
        } else {
            width = min(width, maximumWidth)
            height = min(height, maximumHeight)
        }
        let newRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: height)
        apply(kind, rect: ScreenRect.normalised(newRect, in: canvas))
    }

    private func endResize() {
        resizeBase = nil
        commit()
    }

    private func apply(_ kind: ScreenKind, rect: ScreenRect) {
        var layout = draft
        var placement = layout.placement(for: orientation)
        placement.setRect(rect, for: kind)
        layout.setPlacement(placement, for: orientation)
        draft = layout
    }

    /// Pinch over the canvas shrinks/enlarges the selected screen about its
    /// centre (tap a screen to select it).
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { factor in
                if pinchBase == nil {
                    pushUndo()
                    pinchBase = draft.placement(for: orientation).rect(for: selection)
                }
                guard let base = pinchBase else { return }
                let canvas = canvasPointSize
                let placement = draft.placement(for: orientation)
                let rect = base.cgRect(in: canvas)
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                let scale = max(CGFloat(factor), 0.2)
                var width = min(max(rect.width * scale, 32), canvas.width)
                var height = min(max(rect.height * scale, 32), canvas.height)
                if placement.keepsNativeAspect {
                    let aspect = CustomScreenGeometry.nativeAspect(for: selection)
                    height = width / aspect
                    if height > canvas.height {
                        height = canvas.height
                        width = height * aspect
                    }
                }
                var x = centre.x - width / 2
                var y = centre.y - height / 2
                x = min(max(x, 0), max(canvas.width - width, 0))
                y = min(max(y, 0), max(canvas.height - height, 0))
                let newRect = CGRect(x: x, y: y, width: width, height: height)
                apply(selection, rect: ScreenRect.normalised(newRect, in: canvas))
            }
            .onEnded { _ in
                guard pinchBase != nil else { return }
                pinchBase = nil
                commit()
            }
    }

    // MARK: - Actions

    private func pushUndo() {
        if undoStack.last != draft {
            undoStack.append(draft)
        }
        if undoStack.count > 40 {
            undoStack.removeFirst()
        }
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        draft = previous
        commit()
    }

    private func commit() {
        // Hand editing a custom screen layout is exactly that direction's Custom
        // choice; the numeric custom page also switches it before opening the
        // editor.
        settings.selectCustomScreenLayout(for: orientation)
        settings.customScreenLayout = draft
        settings.persist()
    }

    private func resetOrientation() {
        pushUndo()
        var layout = draft
        layout.setPlacement(CustomScreenLayout.defaultPlacement(for: orientation),
                            for: orientation)
        draft = layout
        commit()
    }

    private func resetBoth() {
        pushUndo()
        let layout = CustomScreenLayout.standard()
        settings.customScreenLayout = layout
        settings.persist()
        draft = layout
        undoStack = []
    }
}

// MARK: - One editable screen

/// A screen box in the editor canvas. The translucent outer box is the layout
/// rectangle; the brighter inner box is the picture at the console's own
/// aspect, so a non-native rectangle shows the letterboxing the game will show.
private struct EditableScreenBox: View {
    let kind: ScreenKind
    let rect: CGRect
    let screenAspect: CGFloat
    let isSelected: Bool
    let label: String
    let onBeginMove: () -> Void
    let onMove: (CGSize) -> Void
    let onEndMove: () -> Void
    let onBeginResize: () -> Void
    let onResize: (CGSize) -> Void
    let onEndResize: () -> Void
    let onSelect: () -> Void

    @State private var isMoving = false
    @State private var isResizing = false

    private var size: CGSize {
        CGSize(width: max(rect.width, 24), height: max(rect.height, 24))
    }

    /// Round-4 interaction: the corner handle is a >=44 pt touch target with a
    /// visible knob, so a finger can grab it without zooming.
    private var handleSize: CGFloat { 44 }

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
                .font(.system(size: max(min(size.width, size.height) * 0.14, 9),
                              weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(2)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isMoving {
                        isMoving = true
                        onSelect()
                        onBeginMove()
                    }
                    onMove(value.translation)
                }
                .onEnded { _ in
                    isMoving = false
                    onEndMove()
                }
        )
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                    .frame(width: 22, height: 22)
                    .padding(11)
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isResizing {
                                    isResizing = true
                                    onBeginResize()
                                }
                                onResize(value.translation)
                            }
                            .onEnded { _ in
                                isResizing = false
                                onEndResize()
                            }
                    )
                    .accessibilityIdentifier("screen-resize-handle")
            }
        }
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