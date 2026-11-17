//
//  KeyboardRequest.swift
//  3ds2apple
//
//  The 3DS software keyboard (the library applet a title starts when it needs a
//  name, a message, a password) as the app sees it.
//
//  Zakuro's C ABI exposes an open request as one JSON document
//  (zk_keyboard_request_json(), schema 1) and answers it with
//  zk_answer_keyboard(). This file is the Swift side of that contract: decoding,
//  the applet's confirmation rules (`Request::accepts` in Zakuro's keyboard
//  service), and the UTF-16 length handling the overlay and the session share.
//
//  The title is waiting on the applet while a request is open, so the session
//  stops running frames until the request is answered; see ROMSession.
//

import Foundation

/// One open 3DS software-keyboard request.
struct KeyboardRequest: Equatable {
    /// How the applet's confirming button validates the typed text.
    ///
    /// The names are the `valid` strings of the JSON ABI; the checks mirror
    /// Zakuro's `Request::accepts` exactly so the overlay disables the right
    /// button instead of letting the title reject an answer after the fact.
    enum Validity: String, Equatable {
        /// Any text, including an empty one.
        case anything
        /// At least one UTF-16 unit.
        case notEmpty
        /// At least one unit, and not only whitespace.
        case notEmptyNotBlank
        /// Not only whitespace (an empty text passes).
        case notBlank
        /// Exactly `maxLength` UTF-16 units.
        case fixedLength
    }

    /// The JSON schema this request was decoded from (1 today).
    let schema: Int
    /// The applet's prompt line, e.g. "Your name". May be empty.
    let hint: String
    /// The text the applet starts with (read from the title's shared block).
    let initialText: String
    /// The longest text the title accepts, in UTF-16 units.
    let maxLength: Int
    /// Button labels left to right, as the applet shows them. The last one
    /// confirms; the others dismiss with their own result. Empty only for a
    /// malformed document (the overlay then shows a single OK).
    let buttons: [String]
    /// The confirming button's rule.
    let validity: Validity

    /// The longest text the overlay may hold. Never below zero.
    var countLimit: Int { max(0, maxLength) }

    /// The labels to draw: the applet's own, or one localized OK when the
    /// document carried none, so the player can always close the applet.
    var displayButtons: [String] {
        buttons.isEmpty ? [L10n.tr("OK")] : buttons
    }

    /// Index of the confirming button: the last one, like the applet.
    var confirmIndex: Int { displayButtons.count - 1 }

    /// The prompt to show: the title's hint, or a neutral localized line when
    /// the applet did not ask for anything specific.
    var prompt: String {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.tr("Enter text") : trimmed
    }

    /// Whether the confirming button takes this text. Mirrors `Request::accepts`.
    func accepts(_ text: String) -> Bool {
        let length = Self.utf16Count(text)
        guard length <= countLimit else { return false }
        let blank = !text.isEmpty
            && text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        switch validity {
        case .anything:
            return true
        case .notEmpty:
            return length > 0
        case .notEmptyNotBlank:
            return length > 0 && !blank
        case .notBlank:
            return !blank
        case .fixedLength:
            return length == countLimit
        }
    }

    /// Why the confirming button is disabled for this text, as a localized
    /// line; nil when the text is acceptable.
    func rejectionMessage(for text: String) -> String? {
        guard !accepts(text) else { return nil }
        switch validity {
        case .anything:
            // Only the count limit can fail here; the counter line says it.
            return L10n.format("Too long: at most %ld characters.", countLimit)
        case .notEmpty:
            return L10n.tr("Text is required.")
        case .notEmptyNotBlank:
            return L10n.tr("Text cannot be empty or only spaces.")
        case .notBlank:
            return L10n.tr("Text cannot be only spaces.")
        case .fixedLength:
            return L10n.format("Enter exactly %ld characters.", countLimit)
        }
    }

    /// `text` cut to `countLimit` UTF-16 units without splitting a character
    /// (an emoji counts as two units and is either kept or dropped whole).
    func truncated(_ text: String) -> String {
        guard Self.utf16Count(text) > countLimit else { return text }
        var units = 0
        var result = ""
        result.reserveCapacity(countLimit)
        for character in text {
            let count = character.utf16.count
            if units + count > countLimit { break }
            units += count
            result.append(character)
        }
        return result
    }

    /// UTF-16 length, the unit both the applet's limit and the 3DS text block
    /// count in.
    static func utf16Count(_ text: String) -> Int {
        text.utf16.count
    }

    /// One line for the device log and the diagnostics (no game text beyond
    /// the applet's own hint/labels is user data; the typed text is never
    /// logged).
    var logLine: String {
        "hint=\(hint.isEmpty ? "-" : hint) maxLength=\(maxLength)"
            + " buttons=\(buttons.count) valid=\(validity.rawValue)"
    }

    // MARK: - JSON schema 1

    /// Decodes one `zk_keyboard_request_json()` document. Returns nil when the
    /// document is not schema-1 JSON.
    static func decode(json: String) -> KeyboardRequest? {
        guard let data = json.data(using: .utf8) else { return nil }
        return decode(data: data)
    }

    /// Decodes one `zk_keyboard_request_json()` document.
    static func decode(data: Data) -> KeyboardRequest? {
        struct Payload: Decodable {
            let schema: Int?
            let hint: String?
            let text: String?
            let maxLength: Int?
            let buttons: [String]?
            let valid: String?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        return KeyboardRequest(
            schema: payload.schema ?? 1,
            hint: payload.hint ?? "",
            initialText: payload.text ?? "",
            maxLength: max(0, payload.maxLength ?? 0),
            buttons: payload.buttons ?? [],
            // A rule this build does not know (a newer runtime) must not trap
            // the player; the applet still validates the answer itself.
            validity: payload.valid.flatMap(Validity.init(rawValue:)) ?? .anything
        )
    }
}
