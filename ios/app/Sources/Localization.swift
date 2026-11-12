//
//  Localization.swift
//  3ds2apple
//
//  Central localization helper. The app ships two Localizable.strings tables
//  (Resources/en.lproj and Resources/zh-Hans.lproj); iOS picks the table from
//  the system language, so there is no in-app language switch and no stored
//  language preference:
//
//  - Simplified Chinese (zh-Hans, and the zh-CN / zh-SG regions) shows Chinese;
//  - every other system language, including Traditional Chinese, falls back to
//    the development language, English.
//
//  Static SwiftUI string literals (texts, buttons, labels, Form section headers
//  and footers) are localizable keys by themselves, so the views do not repeat
//  the English text anywhere. Every string built at run time (model state, enum
//  labels, interpolated or formatted text, error messages) goes through
//  L10n.tr()/L10n.format(), which look up the same tables. An incomplete
//  translation falls back to the English source text.
//
//  The bundle resolves the language at launch. iOS restarts apps when the
//  system language changes; LocalizationStore additionally watches for a locale
//  change (region and number/date formatting while the app is running) and
//  publishes a revision so the view tree rebuilds.
//

import Combine
import Foundation

/// The language the app is displaying: English, or Simplified Chinese.
enum AppLanguage: String {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    /// The language's own name, the way language pickers show it.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// Lookups into the app's localization tables.
enum L10n {
    /// The language the bundle resolved for this launch. The name stays the
    /// same for the whole session; see `LocalizationStore` for the reactive
    /// part.
    static var currentLanguage: AppLanguage {
        guard let preferred = Bundle.main.preferredLocalizations.first?.lowercased(),
              !preferred.isEmpty else {
            return .english
        }
        // The only translated table is Simplified Chinese. A system set to
        // Traditional Chinese does not match it and iOS falls back to English.
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    /// The system's most preferred language, for the Settings row and the
    /// diagnostics report. Not used for lookups: the bundle already decided.
    static var systemLanguageIdentifier: String {
        Locale.preferredLanguages.first ?? Locale.current.identifier
    }

    /// `Language` row in Settings: which table is active plus where it came
    /// from, e.g. "English (system language)".
    static var languageSummary: String {
        switch currentLanguage {
        case .english:
            return tr("English (system language)")
        case .simplifiedChinese:
            return tr("Simplified Chinese (system language)")
        }
    }

    /// One line for the device log and the diagnostics report.
    static var diagnosticsLine: String {
        "app_language=\(currentLanguage.rawValue)"
            + " system_language=\(systemLanguageIdentifier)"
    }

    /// Looks up `source` in the current language's table. A missing key returns
    /// the English source, so an incomplete translation never shows raw keys.
    static func tr(_ source: String) -> String {
        NSLocalizedString(source, comment: "")
    }

    /// Localizes a format string and then formats it. Use this (not
    /// `String(format:)`) for every user-facing text with arguments, so the
    /// translated text is what gets the values.
    static func format(_ source: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(source, comment: ""), arguments: arguments)
    }

    // MARK: - Small reusable phrases

    /// "1 file" / "5 files", localized. English needs the plural form; the
    /// Chinese table has both keys.
    static func fileCount(_ count: Int) -> String {
        count == 1 ? tr("1 file") : format("%ld files", count)
    }

    /// "3 of 3 slots", localized.
    static func slotCount(_ used: Int, of total: Int) -> String {
        format("%ld of %ld slots", used, total)
    }

    /// "2 frames", localized.
    static func frameCount(_ count: UInt64) -> String {
        count == 1 ? tr("1 frame") : format("%llu frames", count)
    }

    /// Speed label used by the fast-forward controls: "1×", "2×", "4×".
    static func speedLabel(_ speed: Int) -> String {
        "\(max(1, speed))×"
    }
}

/// Re-renders the view tree when iOS reports a locale change while the app is
/// running (region, calendar, or the 12/24-hour setting). A full system
/// language switch restarts the app, and the next launch resolves the new
/// language from the bundle.
final class LocalizationStore: ObservableObject {
    static let shared = LocalizationStore()

    /// Bumped on every reported locale change. `ContentView` keys its root view
    /// on this value so the localized texts and formatters are read again.
    @Published private(set) var revision = 0

    private var observer: NSObjectProtocol?

    private init() {
        // The raw notification name keeps this free of an API-name import; the
        // constant has carried this value since iOS 2.
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSCurrentLocaleDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.localeDidChange()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Re-reads the resolved language and rebuilds the UI. The bundle's
    /// preferred localization is fixed at launch, so a full language switch is
    /// applied by the next launch; a region/format change shows up immediately.
    func localeDidChange() {
        revision &+= 1
        AppLog.log(
            "[3ds2apple] locale changed: %@",
            L10n.diagnosticsLine
        )
    }
}
