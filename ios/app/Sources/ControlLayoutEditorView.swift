//
//  ControlLayoutEditorView.swift
//  3ds2apple
//
//  The full-screen on-screen control layout editor (0.1.3 simplification).
//
//  The Settings page opens it for the direction the device is in right now
//  (portrait edits the portrait profile, landscape the landscape one); there is
//  no orientation picker and no other mode. The canvas is the whole screen and
//  mirrors the running game view (GameViewGeometry.swift), including the
//  current screen layout: the two 3DS pictures are drawn behind the controls,
//  translucent, so a control can be placed between or away from them.
//
//  Drag a control to move it (guides snap it to the container edges/centre and
//  to the other controls), pinch it or drag its corner handle to resize it, and
//  use the size/opacity sliders for the selected control. Undo and reset (one
//  control, this direction or both) are one tap away; every change is saved
//  immediately in the Custom profile.
//
//  The model is unchanged from 0.1.2 - positions normalised to the container,
//  size as a fraction of the shorter side, per-control opacity, versioned
//  Codable profiles (UI.controlLayoutPortrait / ...Landscape) - so layouts saved
//  by 0.1.2 keep working.
//

import Foundation
import SwiftUI

struct ControlLayoutEditorView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    /// The direction this editor edits. Fixed when the page opens: portrait and
    /// landscape have separate profiles.
    @State private var orientation: ControlLayoutOrientation
    @State private var draft: ControlLayoutProfile
    @State private var selected: ControlElement?
    @State private var metrics: GameViewDeviceMetrics = .current()
    @State private var undoStack: [ControlLayoutProfile] = []

    // Gesture bookkeeping: a gesture always applies its total translation to the
    // placement captured when it started, never to the already-moved one.
    @State private var dragBase: ControlPlacement?
    /// Group centre captured when a D-pad cross drag starts (the four directions
    /// move together).
    @State private var dragBaseDpadCenter: CGPoint?
    @State private var pinchBaseSize: Double?
    @State private var resizeBaseSize: Double?

    // Alignment guides (container points) shown while a drag is snapped.
    @State private var guideX: CGFloat?
    @State private var guideY: CGFloat?

    /// `orientation` nil means "the direction the device is held in right now".
    /// The headless screenshot launch passes one explicitly.
    init(settings: AppSettings, orientation: ControlLayoutOrientation? = nil) {
        self.settings = settings
        let target = orientation ?? GameViewDeviceMetrics.currentLayoutOrientation
        _orientation = State(initialValue: target)
        _draft = State(initialValue: settings.controlLayout(for: target))
    }

    private var geometry: GameViewPreviewGeometry {
        GameViewPreviewGeometry.make(orientation: orientation, metrics: metrics)
    }

    private var containerSize: CGSize { geometry.controlContainerRect.size }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black
                canvas(available: proxy.size)
                VStack(spacing: 8) {
                    topBar
                    Spacer(minLength: 8)
                    bottomPanel
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear(perform: refresh)
    }

    private func refresh() {
        metrics = .current()
        draft = settings.controlLayout(for: orientation)
        selected = nil
        undoStack = []
        guideX = nil
        guideY = nil
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
            mockGameContent(scaler)
            controls(scaler)
            alignmentGuides(scaler)
        }
        .frame(width: available.width, height: available.height)
        .contentShape(Rectangle())
        .simultaneousGesture(pinchGesture)
        .accessibilityIdentifier("control-layout-preview")
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

    /// The running game view around the controls: the full-bleed picture stage
    /// with the two screens at the current screen layout (the reference for
    /// placing controls) and the editable control container (the whole screen).
    @ViewBuilder
    private func mockGameContent(_ scaler: GameViewPreviewScaler) -> some View {
        let stage = scaler.rect(geometry.screenStageRect)
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
                   isUpper: true,
                   label: L10n.tr("Upper screen"),
                   stage: geometry.screenStageRect,
                   scaler: scaler)
        mockScreen(viewports.bottom,
                   isUpper: false,
                   label: L10n.tr("Lower screen"),
                   stage: geometry.screenStageRect,
                   scaler: scaler)

        // The exact box the runtime overlay gets.
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

    /// One 3DS screen placeholder at the current screen layout. It is reference
    /// only: the controls are what the editor moves.
    @ViewBuilder
    private func mockScreen(_ viewport: CGRect?,
                            isUpper: Bool,
                            label: String,
                            stage: CGRect,
                            scaler: GameViewPreviewScaler) -> some View {
        if let viewport, viewport.width >= 1, viewport.height >= 1 {
            let origin = scaler.point(CGPoint(x: stage.minX + viewport.minX,
                                              y: stage.minY + viewport.minY))
            let rect = CGRect(x: origin.x, y: origin.y,
                              width: viewport.width * scaler.scale,
                              height: viewport.height * scaler.scale)
            let fill = isUpper
                ? Color(red: 0.20, green: 0.36, blue: 0.52)
                : Color(red: 0.30, green: 0.26, blue: 0.44)
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill.opacity(0.38))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                Text(label)
                    .font(.system(size: max(min(rect.width, rect.height) * 0.16, 9),
                                  weight: .medium))
                    .foregroundColor(.white.opacity(0.50))
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
            if !element.isDpadDirection {
                editableOverlayControl(element, container: container, scaler: scaler)
            }
        }
        // The D-pad is one cross-shaped control; dragging it moves all four
        // directions together.
        let group = draft.dpadGroup(in: containerSize)
        let groupCenter = scaler.point(CGPoint(x: container.minX + group.center.x,
                                               y: container.minY + group.center.y))
        EditableDpadCrossControl(
            center: groupCenter,
            diameter: max(scaler.length(group.diameter), 10),
            opacity: group.opacity,
            isSelected: selected?.isDpadDirection == true,
            onBeginDrag: { beginDrag(.dpadUp) },
            onDrag: { translation in drag(.dpadUp, translation: translation, scale: scaler.scale) },
            onEndDrag: { endDrag() }
        )
        .position(groupCenter)
        .zIndex(selected?.isDpadDirection == true ? 2 : 1)
    }

    @ViewBuilder
    private func editableOverlayControl(_ element: ControlElement,
                                        container: CGRect,
                                        scaler: GameViewPreviewScaler) -> some View {
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

    // MARK: - Bars

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("Control layout"))
                    .font(.footnote.weight(.semibold))
                Text(L10n.format("Editing the %@ layout", orientation.title))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button(L10n.tr("Done")) { dismiss() }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("control-editor-done")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            if let selected {
                inspector(for: selected)
            } else {
                Text(L10n.tr("Tap a control, then drag or pinch it. The screens show the current screen layout."))
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
                Spacer(minLength: 4)
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
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Inspector

    private func inspector(for element: ControlElement) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(element.symbol)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                Text(element.isDpadDirection ? L10n.tr("D-pad") : element.accessibilityTitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer(minLength: 4)
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
            get: { draft.placement(for: element.isDpadDirection ? .dpadUp : element).size },
            set: { newValue in
                if element.isDpadDirection {
                    draft = draft.settingDpadSize(newValue)
                } else {
                    var placement = draft.placement(for: element)
                    placement.size = newValue
                    draft.setPlacement(placement, for: element)
                }
            }
        )
    }

    private func opacityBinding(for element: ControlElement) -> Binding<Double> {
        Binding(
            get: { draft.placement(for: element.isDpadDirection ? .dpadUp : element).opacity },
            set: { newValue in
                if element.isDpadDirection {
                    draft = draft.settingDpadOpacity(newValue)
                } else {
                    var placement = draft.placement(for: element)
                    placement.opacity = newValue
                    draft.setPlacement(placement, for: element)
                }
            }
        )
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
        selected = nil
        commit()
    }

    private func commit() {
        // Hand editing the controls is exactly the Custom choice; the Settings
        // page also switches it before opening the editor.
        if settings.controlLayoutMode != .custom {
            settings.controlLayoutMode = .custom
        }
        settings.setControlLayout(draft, for: orientation)
        settings.persist()
    }

    private func resetSelected(_ element: ControlElement) {
        pushUndo()
        if element.isDpadDirection {
            for direction in ControlLayoutProfile.dpadDirections {
                draft.setPlacement(
                    ControlLayoutProfile.defaultPlacement(for: direction, orientation: orientation),
                    for: direction
                )
            }
        } else {
            draft.setPlacement(
                ControlLayoutProfile.defaultPlacement(for: element, orientation: orientation),
                for: element
            )
        }
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
        if element.isDpadDirection {
            guard dragBaseDpadCenter == nil else { return }
            pushUndo()
            dragBaseDpadCenter = draft.dpadGroup(in: containerSize).center
            return
        }
        guard dragBase == nil else { return }
        pushUndo()
        dragBase = draft.placement(for: element)
    }

    private func drag(_ element: ControlElement, translation: CGSize, scale: CGFloat) {
        let factor = max(scale, 0.0001)
        if element.isDpadDirection {
            guard let baseCenter = dragBaseDpadCenter else { return }
            let group = draft.dpadGroup(in: containerSize)
            let proposed = CGPoint(x: baseCenter.x + translation.width / factor,
                                   y: baseCenter.y + translation.height / factor)
            let bounded = group.clampedCenter(proposed, in: containerSize)
            let others = ControlElement.allCases
                .filter { !$0.isDpadDirection }
                .map { (element: $0,
                        frame: $0.frame(for: draft.placement(for: $0), in: containerSize)) }
            let snapped = ControlLayoutSnapping.snap(center: bounded,
                                                     frame: group.snapFrame,
                                                     container: containerSize,
                                                     others: others)
            guideX = snapped.guideX
            guideY = snapped.guideY
            draft = draft.movingDpadGroup(to: snapped.center, in: containerSize)
            return
        }
        guard let base = dragBase else { return }
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
        dragBaseDpadCenter = nil
        guideX = nil
        guideY = nil
        commit()
    }

    private func beginResize(_ element: ControlElement) {
        selected = element
        guard resizeBaseSize == nil else { return }
        pushUndo()
        resizeBaseSize = draft.placement(for: element.isDpadDirection ? .dpadUp : element).size
    }

    private func resize(_ element: ControlElement, translation: CGSize) {
        guard let base = resizeBaseSize else { return }
        // The handle is at the control's bottom-right; either axis grows it, but
        // the average keeps a diagonal drag natural.
        let points = (translation.width + translation.height) / 2
        let shortSide = max(min(containerSize.width, containerSize.height), 1)
        let newSize = min(max(base + Double(points / shortSide), 0.05), 0.60)
        if element.isDpadDirection {
            draft = draft.settingDpadSize(newSize)
        } else {
            var placement = draft.placement(for: element)
            placement.size = newSize
            draft.setPlacement(placement, for: element)
        }
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
                    pinchBaseSize = draft.placement(for: element.isDpadDirection ? .dpadUp : element).size
                }
                guard let base = pinchBaseSize else { return }
                let newSize = min(max(base * Double(factor), 0.05), 0.60)
                if element.isDpadDirection {
                    draft = draft.settingDpadSize(newSize)
                } else {
                    var placement = draft.placement(for: element)
                    placement.size = newSize
                    draft.setPlacement(placement, for: element)
                }
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

    /// Same shape factor as the runtime: the D-pad directions are tighter so the
    /// four buttons read as one cross.
    private var cornerFactor: CGFloat {
        CGFloat(element.shapeCornerFactor)
    }

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
            Group {
                if let systemImage = element.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: max(min(diameter * 0.4, 13), 6),
                                      weight: .semibold))
                } else {
                    Text(element.symbol)
                        .font(.system(size: max(min(diameter * 0.36, 12), 6),
                                      weight: .semibold, design: .rounded))
                }
            }
            .foregroundColor(.white.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 1)
        }
        .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear, radius: 4)
    }
}
// MARK: - D-pad cross in the preview

/// The one editable D-pad cross of the legacy full-screen editor. It is drawn
/// from the four directional placements and drags them together; size/opacity
/// are edited through the inspector's group bindings.
private struct EditableDpadCrossControl: View {
    let center: CGPoint
    let diameter: CGFloat
    let opacity: Double
    let isSelected: Bool
    let onBeginDrag: () -> Void
    let onDrag: (CGSize) -> Void
    let onEndDrag: () -> Void

    @State private var isDragging = false

    private var span: CGFloat { diameter * 2 }

    var body: some View {
        let localCenter = CGPoint(x: span / 2, y: span / 2)
        ZStack {
            DpadCrossShape()
                .fill(Color.white.opacity(isSelected ? 0.30 : 0.16))
            DpadCrossShape()
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.5),
                        lineWidth: isSelected ? 2 : 1)
            ForEach(ControlLayoutProfile.dpadDirections, id: \.self) { element in
                Text(element.symbol)
                    .font(.system(size: max(min(diameter * 0.22, 12), 6),
                                  weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                    .position(arrowPosition(for: element, localCenter: localCenter))
            }
        }
        .frame(width: span, height: span)
        .opacity(opacity)
        .contentShape(DpadCrossShape())
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
        .accessibilityLabel(L10n.tr("D-pad"))
        .accessibilityIdentifier("editor-dpad-cross")
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