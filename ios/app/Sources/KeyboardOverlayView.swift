//
//  KeyboardOverlayView.swift
//  3ds2apple
//
//  The overlay that answers a 3DS software-keyboard request: the title is
//  waiting on the library applet, the session has stopped its frame loop, and
//  this card collects the text and the button. Answering calls back into the
//  session, which runs zk_answer_keyboard() on the runtime serial queue and
//  resumes the game.
//
//  It is a full-screen overlay so the on-screen controls and the pause button
//  cannot be reached while the applet is open (the title is stopped anyway), and
//  it works in both orientations: the card scrolls above the system keyboard in
//  landscape, where the keyboard takes most of the height.
//

import SwiftUI
import UIKit

struct KeyboardOverlayView: View {
    /// The open request: its hint, initial text, limit, buttons and rule.
    let request: KeyboardRequest
    /// Called with the typed text and the button index pressed (the last button
    /// confirms). The session answers the applet and clears the request, which
    /// dismisses this overlay.
    let onAnswer: (String, Int) -> Void

    @State private var text: String
    @FocusState private var inputFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(request: KeyboardRequest, onAnswer: @escaping (String, Int) -> Void) {
        self.request = request
        self.onAnswer = onAnswer
        _text = State(initialValue: request.truncated(request.initialText))
    }

    private var buttons: [String] { request.displayButtons }
    private var isConfirmEnabled: Bool { request.accepts(text) }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            // Dim the paused picture but keep it visible, like the console keeps
            // its screen while the applet is open. This layer also swallows every
            // touch that misses the card, so no control behind it reacts.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)

            ScrollView(.vertical) {
                card
                    .frame(maxWidth: 540)
                    .padding(.horizontal, 20)
                    .padding(.vertical, isCompactHeight ? 8 : 24)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboard-overlay")
        .onAppear {
            // Focus once the overlay is in the hierarchy: asking for focus from
            // onAppear directly can be dropped while the view is still being
            // inserted, and then the system keyboard never comes up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                inputFocused = true
            }
        }
        .onChange(of: text) { newValue in
            let limited = request.truncated(newValue)
            if limited != newValue {
                text = limited
            }
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: isCompactHeight ? 10 : 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Text input"))
                    .font(.headline)
                Text(request.prompt)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputField

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.format("%ld/%ld characters",
                                 KeyboardRequest.utf16Count(text),
                                 request.countLimit))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                if let message = request.rejectionMessage(for: text) {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.trailing)
                }
            }

            buttonsRow
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
        .accessibilityIdentifier("keyboard-card")
    }

    private var inputField: some View {
        TextField(request.prompt, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .focused($inputFocused)
            .submitLabel(.done)
            .onSubmit {
                if isConfirmEnabled {
                    answer(request.confirmIndex)
                }
            }
            .textInputAutocapitalization(.sentences)
            .autocorrectionDisabled(false)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .accessibilityIdentifier("keyboard-input")
    }

    private var buttonsRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { index, label in
                button(index: index, label: label)
            }
        }
    }

    @ViewBuilder
    private func button(index: Int, label: String) -> some View {
        let isConfirm = index == request.confirmIndex
        let action = { answer(index) }
        if isConfirm {
            Button(action: action) {
                buttonLabel(label, isConfirm: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isConfirmEnabled)
            .accessibilityIdentifier("keyboard-button-\(index)")
        } else {
            Button(action: action) {
                buttonLabel(label, isConfirm: false)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("keyboard-button-\(index)")
        }
    }

    private func buttonLabel(_ label: String, isConfirm: Bool) -> some View {
        Text(label)
            .font(.body.weight(isConfirm ? .semibold : .regular))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    // MARK: - Answer

    /// Sends one answer. The confirming button is ignored while the applet's
    /// rule rejects the text; the others always close the applet (Cancel-like).
    private func answer(_ index: Int) {
        let clamped = min(max(index, 0), buttons.count - 1)
        if clamped == request.confirmIndex && !isConfirmEnabled {
            return
        }
        inputFocused = false
        onAnswer(text, clamped)
    }
}
