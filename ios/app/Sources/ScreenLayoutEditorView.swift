//
//  ScreenLayoutEditorView.swift
//  3ds2apple
//
//  The "Screen layout" editor for the free per-screen layout (user requirement
//  8, reworked for 0.1.2 after "the proportions are completely wrong"): the
//  preview is the real picture stage of this device and the two screens are
//  drawn at the console's own pixel shape (upper 400x240 = 5:3, lower
//  320x240 = 4:3).
//
//  What changed from the old editor:
//  - The preview uses the real picture-stage aspect instead of a form-width
//    box; a screen dragged to the stage edge lands on the edge in the game.
//  - Drag a screen to move it, pinch to scale it about its centre, drag the
//    corner handle to resize it. Movement snaps to the stage edges/centre and
//    to the other screen, with dashed guide lines.
//  - One-tap presets (stacked, side by side, upper only, lower only); the
//    "custom" chip lights up when the rectangles match none of them.
//  - "Lock ratio" (persisted, archive version 2) keeps the console's screen
//    shape while moving/resizing; turning it on fixes the current rectangles.
//  - Show/hide each screen, undo, reset one orientation or both.
//  - Edits are applied immediately; Done just closes the page.
//
//  The page still says the free layout runs on the software readback path,
//  because the upstream Zakuro presenter only knows its five arrangements; see
//  CustomScreenLayout.swift and ios/app/README.md.
//

import Foundation
import SwiftUI

struct ScreenLayoutEditorView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    @State private var orientation: ControlLayoutOrientation
    @State private var draft: CustomScreenLayout
    @State private var selection: ScreenKind = .upper
    @State private var metrics: GameViewDeviceMetrics = .current()
    @State private var undoStack: [CustomScreenLayout] = []

    @State private var moveBase: ScreenRect?
    @State private var resizeBase: ScreenRect?
    @State private var pinchBase: ScreenRect?

    @State private var guideXs: [CGFloat] = []
    @State private var guideYs: [CGFloat] = []

    init(settings: AppSettings, orientation: ControlLayoutOrientation = .portrait) {
        self.settings = settings
        _orientation = State(initialValue: orientation)
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
        VStack(spacing: 8) {
            orientationPicker
            presetPicker
            preview
            bottomPanel
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .navigationTitle(L10n.tr("Screen layout"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("Done")) { dismiss() }
            }
        }
        .onAppear {
            metrics = .current()
            draft = settings.customScreenLayout
        }
    }

    // MARK: - Orientation

    private var orientationPicker: some View {
        Picker("Orientation", selection: orientationBinding) {
            ForEach(ControlLayoutOrientation.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("screen-layout-orientation")
    }

    private var orientationBinding: Binding<ControlLayoutOrientation> {
        Binding(
            get: { orientation },
            set: { newValue in
                guard newValue != orientation else { return }
                commit()
                orientation = newValue
                draft = settings.customScreenLayout
                selection = .upper
                undoStack = []
                guideXs = []
                guideYs = []
            }
        )
    }

    // MARK: - Presets

    private var presetPicker: some View {
        let current = currentPreset
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ScreenLayoutPreset.allCases) { preset in
                    Button {
                        applyPreset(preset)
                    } label: {
                        Text(preset.title)
                            .font(.caption2.weight(current == preset ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(current == preset
                                    ? Color.accentColor.opacity(0.30)
                                    : Color.white.opacity(0.08))
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    current == preset
                                        ? Color.accentColor
                                        : Color.white.opacity(0.12),
                                    lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.primary)
                    .disabled(preset == .custom)
                    .accessibilityIdentifier("screen-preset-\(preset.rawValue)")
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 34)
    }

    private var currentPreset: ScreenLayoutPreset {
        let placement = draft.placement(for: orientation)
        for preset in [ScreenLayoutPreset.stacked, .sideBySide, .upperOnly, .lowerOnly] {
            let expected = CustomScreenLayout.preset(preset, containerAspect: canvasAspect)
            if matches(placement, expected) {
                return preset
            }
        }
        return .custom
    }

    private func matches(_ lhs: CustomScreenPlacement, _ rhs: CustomScreenPlacement) -> Bool {
        lhs.showsTop == rhs.showsTop
            && lhs.showsBottom == rhs.showsBottom
            && rectMatches(lhs.top, rhs.top)
            && rectMatches(lhs.bottom, rhs.bottom)
    }

    private func rectMatches(_ lhs: ScreenRect, _ rhs: ScreenRect) -> Bool {
        abs(lhs.x - rhs.x) < 0.01
            && abs(lhs.y - rhs.y) < 0.01
            && abs(lhs.width - rhs.width) < 0.01
            && abs(lhs.height - rhs.height) < 0.01
    }

    private func applyPreset(_ preset: ScreenLayoutPreset) {
        guard preset != .custom else { return }
        pushUndo()
        var layout = draft
        let placement = layout.placement(applying: preset,
                                         for: orientation,
                                         containerAspect: canvasAspect)
        layout.setPlacement(placement, for: orientation)
        draft = layout
        selection = preset.showsOnly ?? .upper
        commit()
    }

    // MARK: - Preview

    private var preview: some View {
        GeometryReader { proxy in
            let scaler = GameViewPreviewScaler(available: proxy.size,
                                              metrics: metrics,
                                              orientation: orientation)
            ZStack(alignment: .topLeading) {
                Color.clear
                deviceFrame(scaler)
                mockChrome(scaler)
                stageView(scaler)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(pinchGesture)
            .accessibilityIdentifier("screen-layout-preview")
        }
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

    @ViewBuilder
    private func mockChrome(_ scaler: GameViewPreviewScaler) -> some View {
        if let topBar = geometry.topBarRect {
            let bar = scaler.rect(topBar)
            HStack(spacing: 4) {
                Text(L10n.tr("Game"))
                    .font(.system(size: max(bar.height * 0.34, 6)))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Circle()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: max(bar.height * 0.05, 0.5))
                    .frame(width: bar.height * 0.34, height: bar.height * 0.34)
            }
            .frame(width: bar.width, height: bar.height)
            .position(x: bar.midX, y: bar.midY)
        }
        if orientation == .portrait {
            let pad = scaler.rect(geometry.controlContainerRect)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Text(L10n.tr("Control area"))
                    .font(.system(size: max(min(pad.height * 0.16, 8), 5), weight: .medium))
                    .foregroundColor(.white.opacity(0.30))
            }
            .frame(width: pad.width, height: pad.height)
            .position(x: pad.midX, y: pad.midY)
        }
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
            if placement.showsTop {
                editableScreen(.upper, source: placement.top, canvas: canvas, scale: scale)
            }
            if placement.showsBottom {
                editableScreen(.lower, source: placement.bottom, canvas: canvas, scale: scale)
            }
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

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            Text(L10n.tr("Free screen layout runs on the software readback path, so it can be slower; it applies from the next game load."))
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
            HStack(spacing: 10) {
                Picker("Screen", selection: $selection) {
                    Text(L10n.tr("Upper screen")).tag(ScreenKind.upper)
                    Text(L10n.tr("Lower screen")).tag(ScreenKind.lower)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                Spacer(minLength: 4)
                Toggle(L10n.tr("Lock ratio"), isOn: keepsAspectBinding)
                    .font(.caption)
                    .fixedSize()
                    .accessibilityIdentifier("screen-lock-ratio")
            }
            HStack(spacing: 18) {
                Button {
                    toggleShown(.upper)
                } label: {
                    Label(L10n.tr("Upper screen"), systemImage: showsUpper ? "eye" : "eye.slash")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(Text(L10n.tr("Show upper screen")))
                Button {
                    toggleShown(.lower)
                } label: {
                    Label(L10n.tr("Lower screen"), systemImage: showsLower ? "eye" : "eye.slash")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(Text(L10n.tr("Show lower screen")))
                Spacer()
                Button {
                    undo()
                } label: {
                    Label(L10n.tr("Undo"), systemImage: "arrow.uturn.backward")
                }
                .disabled(undoStack.isEmpty)
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
    }

    private var showsUpper: Bool { draft.placement(for: orientation).showsTop }
    private var showsLower: Bool { draft.placement(for: orientation).showsBottom }

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
        case .upper:
            if placement.showsBottom { other = placement.bottom.cgRect(in: canvas) }
        case .lower:
            if placement.showsTop { other = placement.top.cgRect(in: canvas) }
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

    private func toggleShown(_ kind: ScreenKind) {
        var layout = draft
        var placement = layout.placement(for: orientation)
        let showsTop = placement.showsTop
        let showsBottom = placement.showsBottom
        switch kind {
        case .upper:
            if showsTop && !showsBottom { return }
            placement.showsTop.toggle()
        case .lower:
            if showsBottom && !showsTop { return }
            placement.showsBottom.toggle()
        }
        pushUndo()
        layout.setPlacement(placement, for: orientation)
        draft = layout
        selection = kind
        commit()
    }

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
        settings.customScreenLayout = draft
        settings.persist()
    }

    private func resetOrientation() {
        pushUndo()
        var layout = draft
        layout.setPlacement(CustomScreenLayout.defaultPlacement(for: orientation),
                            for: orientation)
        draft = layout
        selection = .upper
        commit()
    }

    private func resetBoth() {
        pushUndo()
        let layout = CustomScreenLayout.standard()
        settings.customScreenLayout = layout
        settings.persist()
        draft = layout
        selection = .upper
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

    private var handleSize: CGFloat { 16 }

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
                    .frame(width: handleSize, height: handleSize)
                    .padding(3)
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
