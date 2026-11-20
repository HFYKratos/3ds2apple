//
//  CustomScreenLayoutValuesView.swift
//  3ds2apple
//
//  The numeric custom screen layout pages (round 2): one page per device
//  direction, reached from Settings -> Display -> Landscape screen layout, the in-game
//  quick display settings or the -openCustomLayoutPage launch hook.
//
//  Unlike the reference layout app (which shows framebuffer pixels), the fields
//  are integer percentages of the game view: X/Y position and width/height for
//  the upper and the lower screen, 0-100. They edit the existing
//  CustomScreenLayout archive (percent <-> normalised rectangle) and apply from
//  the next game load, like the custom layout always did. Opening or editing
//  this page also makes the direction's Custom layout the active choice; the
//  optional "Edit by dragging" button opens the full-screen drag editor for the
//  same direction.
//

import Foundation
import SwiftUI

struct CustomScreenLayoutValuesView: View {
    @ObservedObject var settings: AppSettings
    let orientation: ControlLayoutOrientation

    @Environment(\.dismiss) private var dismiss
    @State private var isDragEditorPresented = false
    @FocusState private var focusedField: String?

    private enum Field: String {
        case x
        case y
        case width
        case height
    }

    var body: some View {
        Form {
            Section {
                percentRow(L10n.tr("X position"), screen: .upper, field: .x)
                percentRow(L10n.tr("Y position"), screen: .upper, field: .y)
                percentRow(L10n.tr("Width"), screen: .upper, field: .width)
                percentRow(L10n.tr("Height"), screen: .upper, field: .height)
            } header: {
                Text(L10n.tr("Upper screen"))
            }
            Section {
                percentRow(L10n.tr("X position"), screen: .lower, field: .x)
                percentRow(L10n.tr("Y position"), screen: .lower, field: .y)
                percentRow(L10n.tr("Width"), screen: .lower, field: .width)
                percentRow(L10n.tr("Height"), screen: .lower, field: .height)
            } header: {
                Text(L10n.tr("Lower screen"))
            }
            Section {
                Button {
                    focusedField = nil
                    isDragEditorPresented = true
                } label: {
                    Label(L10n.tr("Edit by dragging"), systemImage: "hand.draw")
                }
                .accessibilityIdentifier("custom-layout-drag-editor")
                Text(L10n.tr("Values are percentages of the game view (0-100). The custom layout applies from the next game load."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("Done")) { focusedField = nil }
            }
        }
        .onAppear(perform: selectCustomLayout)
        .fullScreenCover(isPresented: $isDragEditorPresented) {
            ScreenLayoutEditorView(settings: settings, orientation: orientation)
        }
    }

    private var navigationTitle: String {
        orientation == .landscape
            ? L10n.tr("Landscape custom layout")
            : L10n.tr("Portrait custom layout")
    }

    /// Opening (or editing) a custom layout makes it the active choice for this
    /// direction; the picker stays the authority for the other direction.
    private func selectCustomLayout() {
        guard !settings.usesCustomLayout(for: orientation) else { return }
        settings.selectCustomScreenLayout(for: orientation)
        settings.persist()
    }

    // MARK: - Percent fields

    private func percentRow(_ title: String,
                            screen: ScreenKind,
                            field: Field) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            TextField("0", text: percentText(screen: screen, field: field))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .focused($focusedField, equals: identifier(screen: screen, field: field))
            Text("%").foregroundColor(.secondary)
        }
        .accessibilityIdentifier("custom-\(orientation.rawValue)-\(screen == .upper ? "upper" : "lower")-\(field.rawValue)")
    }

    private func identifier(screen: ScreenKind, field: Field) -> String {
        "\(orientation.rawValue)-\(screen == .upper ? "upper" : "lower")-\(field.rawValue)"
    }

    /// The field's text; edits are written straight to the custom archive (a
    /// field without digits is ignored, everything else is clamped to 0-100).
    private func percentText(screen: ScreenKind, field: Field) -> Binding<String> {
        Binding(
            get: { String(percent(screen: screen, field: field)) },
            set: { raw in
                let digits = raw.filter { $0.isNumber }
                guard let value = Int(digits) else { return }
                setPercent(value, screen: screen, field: field)
            }
        )
    }

    private func percent(screen: ScreenKind, field: Field) -> Int {
        let rect = rect(for: screen)
        let value: Double
        switch field {
        case .x: value = rect.x
        case .y: value = rect.y
        case .width: value = rect.width
        case .height: value = rect.height
        }
        return Int((value * 100).rounded())
    }

    private func rect(for screen: ScreenKind) -> ScreenRect {
        let placement = settings.customScreenLayout.placement(for: orientation)
        switch screen {
        case .upper: return placement.top
        case .lower: return placement.bottom
        }
    }

    private func setPercent(_ value: Int, screen: ScreenKind, field: Field) {
        var layout = settings.customScreenLayout
        var placement = layout.placement(for: orientation)
        var rect = screen == .upper ? placement.top : placement.bottom
        let fraction = Double(min(max(value, 0), 100)) / 100.0
        switch field {
        case .x:
            rect.x = min(max(fraction, 0), max(1 - rect.width, 0))
        case .y:
            rect.y = min(max(fraction, 0), max(1 - rect.height, 0))
        case .width:
            rect.width = min(max(fraction, ScreenRect.minimumSize),
                             max(1 - rect.x, ScreenRect.minimumSize))
        case .height:
            rect.height = min(max(fraction, ScreenRect.minimumSize),
                              max(1 - rect.y, ScreenRect.minimumSize))
        }
        if screen == .upper {
            placement.top = rect
        } else {
            placement.bottom = rect
        }
        layout.setPlacement(placement, for: orientation)
        settings.customScreenLayout = layout
        settings.persist()
    }
}
