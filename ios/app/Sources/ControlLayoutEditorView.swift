//
//  ControlLayoutEditorView.swift
//  3ds2apple
//
//  The "Control layout" editor (user requirement 7, reworked for 0.1.2 after
//  "adjusting the layout is too awkward and the proportions are completely
//  wrong"): a direct-manipulation editor drawn on the real game view.
//
//  What changed from the old editor:
//  - The preview is no longer an abstract container with a made-up aspect. It
//    is the running game screen of this device (same safe area, same paddings,
//    same pad height; see GameViewGeometry.swift), scaled down to fit the page.
//    A control dragged in the preview therefore lands where the runtime draws
//    it, also on an iPad where the old 1.6:1 preview was nowhere near the real
//    pad shape.
//  - Controls can be dragged anywhere in the container (the old normalised
//    clamp made the edges unreachable), with snapping to the container's
//    edges/centre and to the other controls, and alignment guides.
//  - Resize by pinching anywhere in the preview or by dragging the corner
//    handle of the selected control, and by the size slider; opacity has its
//    own slider per control.
//  - The selected control is highlighted; every change can be undone, and one
//    control, one orientation or both can be reset.
//  - Edits are applied to AppSettings immediately (there is nothing to lose by
//    leaving the page), so the Save button is gone and Done just closes.
//
//  The model (positions normalised to the container, size as a fraction of the
//  shorter side, per-control opacity) and the Codable profile format are
//  unchanged, so layouts saved by 0.1.1 keep working.
//

import Foundation
import SwiftUI

struct ControlLayoutEditorView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var orientation: ControlLayoutOrientation
    @State private var draft: ControlLayoutProfile
    @State private var selected: ControlElement?
    @State private var metrics: GameViewDeviceMetrics = .current()
    @State private var undoStack: [ControlLayoutProfile] = []

    // Gesture bookkeeping: a gesture always applies its total translation to the
    // placement captured when it started, never to the already-moved one.
    @State private var dragBase: ControlPlacement?
    @State private var pinchBaseSize: Double?
    @State private var resizeBaseSize: Double?

    // Alignment guides (container points) shown while a drag is snapped.
    @State private var guideX: CGFloat?
    @State private var guideY: CGFloat?

    init(settings: AppSettings, orientation: ControlLayoutOrientation = .portrait) {
        self.settings = settings
        _orientation = State(initialValue: orientation)
        _draft = State(initialValue: settings.controlLayout(for: orientation))
    }

    private var geometry: GameViewPreviewGeometry {
        GameViewPreviewGeometry.make(orientation: orientation, metrics: metrics)
    }

    private var containerSize: CGSize { geometry.controlContainerRect.size }

    var body: some View {
        VStack(spacing: 10) {
            orientationPicker
            preview
            if let selected {
                inspector(for: selected)
            } else {
                Text(L10n.tr("Tap a control to select it, then drag it in the preview or use the sliders below. Several fingers can press different controls at the same time during a game."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actionBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .navigationTitle(L10n.tr("Control layout"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("Done")) { dismiss() }
            }
        }
        .onAppear {
            metrics = .current()
            draft = settings.controlLayout(for: orientation)
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
        .accessibilityIdentifier("control-layout-orientation")
    }

    private var orientationBinding: Binding<ControlLayoutOrientation> {
        Binding(
            get: { orientation },
            set: { newValue in
                guard newValue != orientation else { return }
                commit()
                orientation = newValue
                draft = settings.controlLayout(for: newValue)
                selected = nil
                undoStack = []
                guideX = nil
                guideY = nil
            }
        )
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
                mockGameContent(scaler)
                controls(scaler)
                alignmentGuides(scaler)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(pinchGesture)
            .accessibilityIdentifier("control-layout-preview")
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
    private func mockGameContent(_ scaler: GameViewPreviewScaler) -> some View {
        let stage = scaler.rect(geometry.screenStageRect)
        // The 3DS picture: a black stage with the two screens at their real
        // proportions (what the game will show under the controls).
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .frame(width: stage.width, height: stage.height)
            .position(x: stage.midX, y: stage.midY)

        let viewports = GameViewPreviewGeometry.screenViewports(
            in: geometry.screenStageRect.size,
            settings: settings,
            orientation: orientation,
            displayScale: displayScale
        )
        mockScreen(viewports.top,
                   label: L10n.tr("Upper screen"),
                   stage: geometry.screenStageRect,
                   scaler: scaler)
        mockScreen(viewports.bottom,
                   label: L10n.tr("Lower screen"),
                   stage: geometry.screenStageRect,
                   scaler: scaler)

        // The portrait title bar (title / FPS / pause) is part of the game view
        // and reserves space the controls must stay out of.
        if let topBar = geometry.topBarRect {
            let bar = scaler.rect(topBar)
            HStack(spacing: 4) {
                Text(L10n.tr("Game"))
                    .font(.system(size: max(bar.height * 0.34, 6)))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5))
                    .frame(width: bar.height * 0.5, height: bar.height * 0.5)
                Circle()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: max(bar.height * 0.05, 0.5))
                    .frame(width: bar.height * 0.34, height: bar.height * 0.34)
            }
            .padding(.horizontal, 2)
            .frame(width: bar.width, height: bar.height)
            .position(x: bar.midX, y: bar.midY)
        }

        // The editable control container: the exact box the runtime overlay gets.
        let container = scaler.rect(geometry.controlContainerRect)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .frame(width: container.width, height: container.height)
            .position(x: container.midX, y: container.midY)
    }

    @ViewBuilder
    private func mockScreen(_ viewport: CGRect?,
                            label: String,
                            stage: CGRect,
                            scaler: GameViewPreviewScaler) -> some View {
        if let viewport, viewport.width >= 1, viewport.height >= 1 {
            let origin = scaler.point(CGPoint(x: stage.minX + viewport.minX,
                                              y: stage.minY + viewport.minY))
            let rect = CGRect(x: origin.x, y: origin.y,
                              width: viewport.width * scaler.scale,
                              height: viewport.height * scaler.scale)
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(red: 0.14, green: 0.17, blue: 0.22))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                Text(label)
                    .font(.system(size: max(min(rect.width, rect.height) * 0.16, 9), weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        }
    }

    @ViewBuilder
    private func controls(_ scaler: GameViewPreviewScaler) -> some View {
        let container = geometry.controlContainerRect
        ForEach(ControlElement.allCases) { element in
            let placement = draft.placement(for: element)
            let frame = element.frame(for: placement, in: containerSize)
            let center = scaler.point(CGPoint(x: container.minX + frame.center.x,
                                              y: container.minY + frame.center.y))
            let diameter = scaler.length(frame.diameter)
            let width = scaler.length(frame.width)
            EditableOverlayControl(
                element: element,
                center: center,
                diameter: max(diameter, 10),
                width: max(width, 10),
                opacity: placement.opacity,
                isSelected: selected == element,
                onBeginDrag: { beginDrag(element) },
                onDrag: { translation in drag(element, translation: translation, scale: scaler.scale) },
                onEndDrag: { endDrag() },
                onBeginResize: { beginResize(element) },
                onResize: { translation in resize(element, translation: translation) },
                onEndResize: { endResize() }
            )
            .position(center)
            .zIndex(selected == element ? 2 : 1)
        }
    }

    @ViewBuilder
    private func alignmentGuides(_ scaler: GameViewPreviewScaler) -> some View {
        let container = scaler.rect(geometry.controlContainerRect)
        if let guideX {
            let x = container.minX + guideX * scaler.scale
            Path { path in
                path.move(to: CGPoint(x: x, y: container.minY))
                path.addLine(to: CGPoint(x: x, y: container.maxY))
            }
            .stroke(Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)
        }
        if let guideY {
            let y = container.minY + guideY * scaler.scale
            Path { path in
                path.move(to: CGPoint(x: container.minX, y: y))
                path.addLine(to: CGPoint(x: container.maxX, y: y))
            }
            .stroke(Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)
        }
    }

    /// The real container size in points, so the preview's proportions can be
    /// checked against the game view (also on an iPad, where the old abstract
    /// 1.6:1 preview was misleading).
    private var containerSizeLabel: String {
        L10n.tr("Control area") + " " +
            "\(Int(containerSize.width.rounded())) × \(Int(containerSize.height.rounded())) pt"
    }

    // MARK: - Inspector

    private func inspector(for element: ControlElement) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(element.symbol)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                Text(element.accessibilityTitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    resetSelected(element)
                } label: {
                    Label(L10n.tr("Reset this control"), systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
            }
            sliderRow(L10n.tr("Size"),
                      value: sizeBinding(for: element),
                      range: 0.05...0.60,
                      format: "%.0f%%",
                      scale: 100,
                      onEditingChanged: { editing in
                          if editing { pushUndo() } else { commit() }
                      })
            sliderRow(L10n.tr("Opacity"),
                      value: opacityBinding(for: element),
                      range: 0.20...1.00,
                      format: "%.0f%%",
                      scale: 100,
                      onEditingChanged: { editing in
                          if editing { pushUndo() } else { commit() }
                      })
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.12))
        )
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           format: String,
                           scale: Double,
                           onEditingChanged: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 46, alignment: .leading)
            Slider(value: value, in: range) { editing in
                onEditingChanged(editing)
            }
            Text(String(format: format, value.wrappedValue * scale))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func sizeBinding(for element: ControlElement) -> Binding<Double> {
        Binding(
            get: { draft.placement(for: element).size },
            set: { newValue in
                var placement = draft.placement(for: element)
                placement.size = newValue
                draft.setPlacement(placement, for: element)
            }
        )
    }

    private func opacityBinding(for element: ControlElement) -> Binding<Double> {
        Binding(
            get: { draft.placement(for: element).opacity },
            set: { newValue in
                var placement = draft.placement(for: element)
                placement.opacity = newValue
                draft.setPlacement(placement, for: element)
            }
        )
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 16) {
            Button {
                undo()
            } label: {
                Label(L10n.tr("Undo"), systemImage: "arrow.uturn.backward")
            }
            .disabled(undoStack.isEmpty)
            Spacer()
            Text(containerSizeLabel)
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
            Menu {
                Button(L10n.tr("Reset this orientation"), role: .destructive) {
                    resetOrientation()
                }
                Button(L10n.tr("Reset both control layouts"), role: .destructive) {
                    resetBoth()
                }
            } label: {
                Label(L10n.tr("Reset"), systemImage: "arrow.counterclockwise")
            }
        }
        .font(.footnote)
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
        selected = nil
        commit()
    }

    private func commit() {
        settings.setControlLayout(draft, for: orientation)
        settings.persist()
    }

    private func resetSelected(_ element: ControlElement) {
        pushUndo()
        draft.setPlacement(
            ControlLayoutProfile.defaultPlacement(for: element, orientation: orientation),
            for: element
        )
        commit()
    }

    private func resetOrientation() {
        pushUndo()
        draft = ControlLayoutProfile.standard(for: orientation)
        selected = nil
        commit()
    }

    private func resetBoth() {
        pushUndo()
        for value in ControlLayoutOrientation.allCases {
            settings.setControlLayout(.standard(for: value), for: value)
        }
        settings.persist()
        draft = settings.controlLayout(for: orientation)
        selected = nil
        undoStack = []
    }

    // MARK: - Gestures

    private func beginDrag(_ element: ControlElement) {
        selected = element
        guard dragBase == nil else { return }
        pushUndo()
        dragBase = draft.placement(for: element)
    }

    private func drag(_ element: ControlElement, translation: CGSize, scale: CGFloat) {
        guard let base = dragBase else { return }
        let factor = max(scale, 0.0001)
        let baseFrame = element.frame(for: base, in: containerSize)
        let proposed = CGPoint(x: baseFrame.center.x + translation.width / factor,
                               y: baseFrame.center.y + translation.height / factor)
        let frame = element.frame(for: base, in: containerSize)
        // Keep the whole control inside, in points (the normalised clamp in the
        // model cannot know the container's shape).
        let bounded = frame.clampedCenter(proposed, in: containerSize)
        let others = ControlElement.allCases
            .filter { $0 != element }
            .map { (element: $0, frame: $0.frame(for: draft.placement(for: $0), in: containerSize)) }
        let snapped = ControlLayoutSnapping.snap(center: bounded,
                                                 frame: frame,
                                                 container: containerSize,
                                                 others: others)
        var placement = base
        placement.x = Double(snapped.center.x / max(containerSize.width, 1))
        placement.y = Double(snapped.center.y / max(containerSize.height, 1))
        guideX = snapped.guideX
        guideY = snapped.guideY
        draft.setPlacement(placement, for: element)
    }

    private func endDrag() {
        dragBase = nil
        guideX = nil
        guideY = nil
        commit()
    }

    private func beginResize(_ element: ControlElement) {
        selected = element
        guard resizeBaseSize == nil else { return }
        pushUndo()
        resizeBaseSize = draft.placement(for: element).size
    }

    private func resize(_ element: ControlElement, translation: CGSize) {
        guard let base = resizeBaseSize else { return }
        // The handle is at the control's bottom-right; either axis grows it, but
        // the average keeps a diagonal drag natural.
        let points = (translation.width + translation.height) / 2
        let shortSide = max(min(containerSize.width, containerSize.height), 1)
        var placement = draft.placement(for: element)
        placement.size = min(max(base + Double(points / shortSide), 0.05), 0.60)
        draft.setPlacement(placement, for: element)
    }

    private func endResize() {
        resizeBaseSize = nil
        commit()
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { factor in
                guard let element = selected else { return }
                if pinchBaseSize == nil {
                    pushUndo()
                    pinchBaseSize = draft.placement(for: element).size
                }
                guard let base = pinchBaseSize else { return }
                var placement = draft.placement(for: element)
                placement.size = min(max(base * Double(factor), 0.05), 0.60)
                draft.setPlacement(placement, for: element)
            }
            .onEnded { _ in
                guard pinchBaseSize != nil else { return }
                pinchBaseSize = nil
                commit()
            }
    }
}

// MARK: - One control in the preview

/// One editable control. It draws exactly like the runtime overlay (same symbol,
/// same capsule widths) and owns the drag and the corner resize handle; the
/// distance between it and the runtime in the game is only the preview scale.
private struct EditableOverlayControl: View {
    let element: ControlElement
    let center: CGPoint
    /// Preview-points diameter (already scaled).
    let diameter: CGFloat
    /// Preview-points width (already scaled; shoulder capsules are wider).
    let width: CGFloat
    let opacity: Double
    let isSelected: Bool
    let onBeginDrag: () -> Void
    let onDrag: (CGSize) -> Void
    let onEndDrag: () -> Void
    let onBeginResize: () -> Void
    let onResize: (CGSize) -> Void
    let onEndResize: () -> Void

    @State private var isDragging = false
    @State private var isResizing = false

    private var handleSize: CGFloat { max(min(diameter * 0.34, 20), 12) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            controlShape
                .frame(width: width, height: diameter)
                .contentShape(RoundedRectangle(cornerRadius: min(width, diameter) * 0.42,
                                               style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onBeginDrag()
                            }
                            onDrag(value.translation)
                        }
                        .onEnded { _ in
                            isDragging = false
                            onEndDrag()
                        }
                )
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                    .frame(width: handleSize, height: handleSize)
                    .position(x: width - handleSize / 2, y: diameter - handleSize / 2)
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
                    .accessibilityIdentifier("control-resize-handle")
            }
        }
        .frame(width: width, height: diameter)
        .opacity(opacity)
        .accessibilityLabel(element.accessibilityTitle)
        .accessibilityIdentifier("editor-control-\(element.rawValue)")
    }

    private var controlShape: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(width, diameter) * 0.42, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.30 : 0.16))
            RoundedRectangle(cornerRadius: min(width, diameter) * 0.42, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.5),
                              lineWidth: isSelected ? 2 : 1)
            Text(element.symbol)
                .font(.system(size: max(min(diameter * 0.36, 12), 6),
                              weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 1)
        }
        .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear, radius: 4)
    }
}
