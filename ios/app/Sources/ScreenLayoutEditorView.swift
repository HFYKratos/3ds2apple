//
//  ScreenLayoutEditorView.swift
//  3ds2apple
//
//  The "Custom screen layout" editor (user requirement 8): drag each 3DS screen
//  in a preview of the game view, resize it, hide one of them, and keep the
//  console's own screen shape with one switch. Portrait and landscape have their
//  own arrangements, like the control profiles.
//
//  Saving writes the layout into AppSettings; the game view's readback path
//  places the two screen images with exactly the rectangles previewed here
//  (CustomScreenGeometry), and the lower screen's touch mapping uses the same
//  rectangle. See CustomScreenLayout.swift for why a custom layout runs on the
//  readback display path.
//

import Foundation
import SwiftUI

struct ScreenLayoutEditorView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    @State private var orientation: ControlLayoutOrientation
    @State private var draft: CustomScreenLayout
    @State private var selection: ScreenSelection = .top
    @State private var keepNativeAspect = true
    @State private var previewAspect: CGFloat = 0.8

    enum ScreenSelection: String, CaseIterable, Identifiable {
        case top
        case bottom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .top: return L10n.tr("Upper screen")
            case .bottom: return L10n.tr("Lower screen")
            }
        }

        var screenKind: ScreenKind {
            switch self {
            case .top: return .upper
            case .bottom: return .lower
            }
        }
    }

    init(settings: AppSettings, orientation: ControlLayoutOrientation = .portrait) {
        self.settings = settings
        _orientation = State(initialValue: orientation)
        _draft = State(initialValue: settings.customScreenLayout)
    }

    var body: some View {
        Form {
            Section {
                Picker("Orientation", selection: orientationBinding) {
                    ForEach(ControlLayoutOrientation.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Layout")
            } footer: {
                Text(L10n.tr("Portrait and landscape keep separate screen positions, like the control layouts. Each rectangle is a fraction of the game view, so it scales with the device."))
            }

            Section {
                screenPreview
                    .frame(height: 280)
                    .accessibilityIdentifier("screen-layout-preview")
            } header: {
                Text("Preview")
            } footer: {
                Text(L10n.tr("Drag a screen to move it. Drag the corner handle to resize it. A custom layout uses the readback display path, so it can be slower than the Metal presenter, and it applies from the next game load."))
            }

            Section {
                Picker("Screen", selection: $selection) {
                    ForEach(ScreenSelection.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(L10n.tr("Show upper screen"), isOn: showsTopBinding)
                Toggle(L10n.tr("Show lower screen"), isOn: showsBottomBinding)

                Toggle(L10n.tr("Keep the 3DS screen shape"), isOn: $keepNativeAspect)
                    .onChange(of: keepNativeAspect) { enabled in
                        guard enabled else { return }
                        snapToNativeAspect()
                    }

                sliderRow(L10n.tr("Horizontal position"),
                          value: rectBinding(for: selection, keyPath: \.x),
                          range: 0.0...0.92,
                          format: "%.2f")
                sliderRow(L10n.tr("Vertical position"),
                          value: rectBinding(for: selection, keyPath: \.y),
                          range: 0.0...0.92,
                          format: "%.2f")
                sliderRow(L10n.tr("Width"),
                          value: rectBinding(for: selection, keyPath: \.width),
                          range: 0.08...1.0,
                          format: "%.2f")
                if !keepNativeAspect {
                    sliderRow(L10n.tr("Height"),
                              value: rectBinding(for: selection, keyPath: \.height),
                              range: 0.08...1.0,
                              format: "%.2f")
                }
            } header: {
                Text("Selected screen")
            }

            Section {
                Button(L10n.tr("Reset custom screen layout"), role: .destructive) {
                    draft = CustomScreenLayout.standard()
                    selection = .top
                }
            }
        }
        .navigationTitle("Custom screen layout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.tr("Save")) {
                    commit()
                    dismiss()
                }
            }
        }
        .onDisappear { commit() }
    }

    // MARK: - Preview

    private var screenPreview: some View {
        GeometryReader { geometry in
            let container = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.6))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                screenRect(.top, container: container)
                screenRect(.bottom, container: container)
            }
            .frame(width: container.width, height: container.height)
            .onAppear { previewAspect = geometry.size.width / max(geometry.size.height, 1) }
            .onChange(of: geometry.size) { newValue in
                previewAspect = newValue.width / max(newValue.height, 1)
            }
        }
    }

    @ViewBuilder
    private func screenRect(_ screen: ScreenSelection, container: CGSize) -> some View {
        let placement = draft.placement(for: orientation)
        let shows = screen == .top ? placement.showsTop : placement.showsBottom
        let rect = (screen == .top ? placement.top : placement.bottom).cgRect(in: container)
        if shows {
            EditableScreenRect(
                title: screen == .top ? L10n.tr("Upper screen") : L10n.tr("Lower screen"),
                rect: rect,
                fill: screen == .top
                    ? Color(red: 0.20, green: 0.36, blue: 0.52)
                    : Color(red: 0.30, green: 0.26, blue: 0.44),
                isSelected: selection == screen,
                container: container,
                onSelect: { selection = screen },
                onMove: { newRect in
                    update(screen, with: newRect, in: container)
                },
                onResize: { newRect in
                    update(screen, with: newRect, in: container, keepAspect: keepNativeAspect)
                }
            )
        }
    }

    /// Applies a dragged/resized point rectangle to the draft, keeping it inside
    /// the container and (on request) the console's screen shape.
    private func update(_ screen: ScreenSelection,
                        with rect: CGRect,
                        in container: CGSize,
                        keepAspect: Bool = false) {
        guard container.width > 0, container.height > 0 else { return }
        var normalised = ScreenRect.normalised(rect, in: container)
        if keepAspect {
            let aspect = CustomScreenGeometry.nativeAspect(for: screen.screenKind)
            let containerAspect = container.width / container.height
            normalised.height = CustomScreenGeometry.heightKeepingNativeAspect(
                width: normalised.width,
                containerAspect: containerAspect,
                screenAspect: aspect
            )
            normalised = normalised.clamped()
        }
        var placement = draft.placement(for: orientation)
        switch screen {
        case .top: placement.top = normalised
        case .bottom: placement.bottom = normalised
        }
        draft.setPlacement(placement, for: orientation)
    }

    // MARK: - Bindings

    /// Commits the old orientation's rectangles before switching to the other
    /// one (the picker's setter runs before the state changes).
    private var orientationBinding: Binding<ControlLayoutOrientation> {
        Binding(
            get: { orientation },
            set: { newValue in
                guard newValue != orientation else { return }
                commit()
                orientation = newValue
                draft = settings.customScreenLayout
            }
        )
    }

    private var showsTopBinding: Binding<Bool> {
        Binding(
            get: { draft.placement(for: orientation).showsTop },
            set: { value in
                var placement = draft.placement(for: orientation)
                placement.showsTop = value
                draft.setPlacement(placement, for: orientation)
            }
        )
    }

    private var showsBottomBinding: Binding<Bool> {
        Binding(
            get: { draft.placement(for: orientation).showsBottom },
            set: { value in
                var placement = draft.placement(for: orientation)
                placement.showsBottom = value
                draft.setPlacement(placement, for: orientation)
            }
        )
    }

    private func rectBinding(for screen: ScreenSelection,
                             keyPath: WritableKeyPath<ScreenRect, Double>) -> Binding<Double> {
        Binding(
            get: { (screen == .top ? draft.placement(for: orientation).top
                                   : draft.placement(for: orientation).bottom)[keyPath: keyPath] },
            set: { value in
                var placement = draft.placement(for: orientation)
                var rect = screen == .top ? placement.top : placement.bottom
                rect[keyPath: keyPath] = value
                rect = rect.clamped()
                if keepNativeAspect, keyPath == \.width {
                    let aspect = CustomScreenGeometry.nativeAspect(for: screen.screenKind)
                    rect.height = min(max(
                        CustomScreenGeometry.heightKeepingNativeAspect(
                            width: rect.width,
                            containerAspect: previewAspect,
                            screenAspect: aspect
                        ),
                        ScreenRect.minimumSize
                    ), 1.0 - rect.y)
                }
                switch screen {
                case .top: placement.top = rect
                case .bottom: placement.bottom = rect
                }
                draft.setPlacement(placement, for: orientation)
            }
        )
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    /// Gives both rectangles their screen's own shape without moving their
    /// top-left corners.
    private func snapToNativeAspect() {
        let containerAspect = previewAspect > 0 ? previewAspect : 0.8
        var placement = draft.placement(for: orientation)
        for kind in [ScreenKind.upper, ScreenKind.lower] {
            let aspect = CustomScreenGeometry.nativeAspect(for: kind)
            switch kind {
            case .upper:
                placement.top.height = CustomScreenGeometry.heightKeepingNativeAspect(
                    width: placement.top.width,
                    containerAspect: containerAspect,
                    screenAspect: aspect
                )
                placement.top = placement.top.clamped()
            case .lower:
                placement.bottom.height = CustomScreenGeometry.heightKeepingNativeAspect(
                    width: placement.bottom.width,
                    containerAspect: containerAspect,
                    screenAspect: aspect
                )
                placement.bottom = placement.bottom.clamped()
            }
        }
        draft.setPlacement(placement, for: orientation)
    }

    // MARK: - Persistence

    private func commit() {
        settings.customScreenLayout = draft
        settings.persist()
    }
}

// MARK: - One draggable screen rectangle

/// A screen placeholder in the editor: drag the body to move it, drag the corner
/// handle to resize it. The gestures work on point rectangles; the parent
/// converts them to normalised screen coordinates.
private struct EditableScreenRect: View {
    let title: String
    let rect: CGRect
    let fill: Color
    let isSelected: Bool
    let container: CGSize
    let onSelect: () -> Void
    let onMove: (CGRect) -> Void
    let onResize: (CGRect) -> Void

    @State private var moveOrigin: CGRect?
    @State private var resizeOrigin: CGRect?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill.opacity(0.85))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.35),
                              lineWidth: isSelected ? 2 : 1)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(4)
        }
        .frame(width: max(rect.width, 24), height: max(rect.height, 24))
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onSelect()
                    let origin = moveOrigin ?? rect
                    if moveOrigin == nil { moveOrigin = rect }
                    let moved = CGRect(
                        x: min(max(origin.minX + value.translation.width, 0),
                               max(container.width - origin.width, 0)),
                        y: min(max(origin.minY + value.translation.height, 0),
                               max(container.height - origin.height, 0)),
                        width: origin.width,
                        height: origin.height
                    )
                    onMove(moved)
                }
                .onEnded { _ in moveOrigin = nil }
        )
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                    .contentShape(Circle())
                    .offset(x: 6, y: 6)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let origin = resizeOrigin ?? rect
                                if resizeOrigin == nil { resizeOrigin = rect }
                                let newRect = CGRect(
                                    x: origin.minX,
                                    y: origin.minY,
                                    width: min(max(origin.width + value.translation.width, 40),
                                               container.width - origin.minX),
                                    height: min(max(origin.height + value.translation.height, 40),
                                                container.height - origin.minY)
                                )
                                onResize(newRect)
                            }
                            .onEnded { _ in resizeOrigin = nil }
                    )
                    .accessibilityIdentifier("screen-resize-handle")
            }
        }
    }
}
