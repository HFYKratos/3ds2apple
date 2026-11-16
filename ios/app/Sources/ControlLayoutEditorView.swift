//
//  ControlLayoutEditorView.swift
//  3ds2apple
//
//  The "Control layout" page (user requirement 7): drag every virtual control
//  where it should sit, size it, set its opacity, and reset back to the shipped
//  default. Two profiles are edited separately (portrait pad area / landscape
//  overlay); the same page saves them into AppSettings (UserDefaults).
//
//  The preview uses the same normalised geometry as VirtualControlsView, so what
//  is dragged here is exactly what the game shows. A control is selected with a
//  tap; positions change by dragging in the preview, size and opacity with the
//  sliders below - all on the phone itself, no desktop step.
//

import SwiftUI

struct ControlLayoutEditorView: View {
    @ObservedObject var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    @State private var orientation: ControlLayoutOrientation
    @State private var draft: ControlLayoutProfile
    @State private var selected: ControlElement?

    init(settings: AppSettings, orientation: ControlLayoutOrientation = .landscape) {
        self.settings = settings
        _orientation = State(initialValue: orientation)
        _draft = State(initialValue: settings.controlLayout(for: orientation))
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
                Text(L10n.tr("The portrait layout is the pad area under the screens; the landscape layout covers the whole game view. The default portrait layout does not cover the screens."))
            }

            Section {
                ControlLayoutPreview(
                    profile: draft,
                    orientation: orientation,
                    selected: $selected
                ) { element, placement in
                    draft.setPlacement(placement, for: element)
                }
                .frame(height: 250)
                .accessibilityIdentifier("control-layout-preview")
            } header: {
                Text("Preview")
            } footer: {
                Text(L10n.tr("Tap a control to select it, then drag it in the preview or use the sliders below. Several fingers can press different controls at the same time during a game."))
            }

            if let selected {
                Section {
                    HStack {
                        Text(selected.symbol)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                        Text(selected.accessibilityTitle)
                            .foregroundColor(.secondary)
                    }
                    sliderRow("Size", value: sizeBinding(for: selected), range: 0.05...0.60)
                    sliderRow("Opacity", value: opacityBinding(for: selected), range: 0.20...1.00)
                    Button(L10n.tr("Reset this control")) {
                        draft.setPlacement(
                            ControlLayoutProfile.defaultPlacement(for: selected, orientation: orientation),
                            for: selected
                        )
                    }
                } header: {
                    Text("Selected control")
                }
            } else {
                Section {
                    Text(L10n.tr("Tap a control in the preview to select it."))
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Button(L10n.tr("Reset this orientation"), role: .destructive) {
                    draft = ControlLayoutProfile.standard(for: orientation)
                    selected = nil
                }
                Button(L10n.tr("Reset both control layouts"), role: .destructive) {
                    draft = ControlLayoutProfile.standard(for: orientation)
                    for value in ControlLayoutOrientation.allCases {
                        settings.setControlLayout(.standard(for: value), for: value)
                    }
                    settings.persist()
                    selected = nil
                    draft = settings.controlLayout(for: orientation)
                }
            }
        }
        .navigationTitle("Control layout")
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

    // MARK: - Bindings

    /// Switching orientation commits the old draft first, so the two profiles
    /// never overwrite each other (the picker's setter runs before the state
    /// changes, which is why this is a custom binding and not .onChange).
    private var orientationBinding: Binding<ControlLayoutOrientation> {
        Binding(
            get: { orientation },
            set: { newValue in
                guard newValue != orientation else { return }
                commit()
                orientation = newValue
                draft = settings.controlLayout(for: newValue)
                selected = nil
            }
        )
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

    private func sliderRow(_ title: LocalizedStringKey,
                           value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(L10n.format("%ld%%", Int((value.wrappedValue * 100).rounded())))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - Persistence

    private func commit() {
        settings.setControlLayout(draft, for: orientation)
        settings.persist()
    }
}

// MARK: - Preview

/// The draggable preview: a container with the same aspect the runtime overlay
/// gets and one movable representation per control.
private struct ControlLayoutPreview: View {
    let profile: ControlLayoutProfile
    let orientation: ControlLayoutOrientation
    @Binding var selected: ControlElement?
    /// Reports a new (normalised) placement for one control.
    let onPlacement: (ControlElement, ControlPlacement) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = min(geometry.size.height, width / orientation.editorAspect)
            let container = CGSize(width: width, height: height)
            let shortSide = min(container.width, container.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                ForEach(ControlElement.allCases) { element in
                    previewControl(element, in: container, shortSide: shortSide)
                }
            }
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func previewControl(_ element: ControlElement,
                                in container: CGSize,
                                shortSide: CGFloat) -> some View {
        let placement = profile.placement(for: element)
        let diameter = max(shortSide * CGFloat(placement.size), 16)
        let center = CGPoint(x: container.width * CGFloat(placement.x),
                             y: container.height * CGFloat(placement.y))
        EditableControl(
            element: element,
            center: center,
            diameter: diameter,
            opacity: placement.opacity,
            isSelected: selected == element,
            container: container,
            onSelect: { selected = element },
            onMove: { newCenter in
                var moved = placement
                moved.x = Double(newCenter.x / max(container.width, 1))
                moved.y = Double(newCenter.y / max(container.height, 1))
                onPlacement(element, moved)
            }
        )
        .position(center)
    }
}

/// One draggable representation of a control in the editor preview.
private struct EditableControl: View {
    let element: ControlElement
    let center: CGPoint
    let diameter: CGFloat
    let opacity: Double
    let isSelected: Bool
    let container: CGSize
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void

    /// The control's centre when the current drag started. Keeping it means the
    /// translation is always applied to the same origin even while the view is
    /// moving under the finger.
    @State private var dragOrigin: CGPoint?

    var body: some View {
        ZStack {
            shape
                .fill(Color.white.opacity(0.22))
            shape
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.45),
                              lineWidth: isSelected ? 2 : 1)
            Text(element.symbol)
                .font(.system(size: min(diameter * 0.4, 12),
                              weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .opacity(opacity)
        .frame(width: width, height: diameter)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onSelect()
                    let origin = dragOrigin ?? center
                    if dragOrigin == nil { dragOrigin = center }
                    let halfWidth = width / 2
                    let halfHeight = diameter / 2
                    let moved = CGPoint(
                        x: min(max(origin.x + value.translation.width, halfWidth),
                               max(container.width - halfWidth, halfWidth)),
                        y: min(max(origin.y + value.translation.height, halfHeight),
                               max(container.height - halfHeight, halfHeight))
                    )
                    onMove(moved)
                }
                .onEnded { _ in
                    dragOrigin = nil
                }
        )
        .accessibilityLabel(element.accessibilityTitle)
    }

    private var width: CGFloat {
        switch element {
        case .buttonL, .buttonR, .buttonZL, .buttonZR:
            return diameter * 1.65
        case .buttonStart, .buttonSelect:
            return diameter * 1.55
        default:
            return diameter
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(width, diameter) * 0.42, style: .continuous)
    }
}
