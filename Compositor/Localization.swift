import Foundation

/// Runtime localization for dynamic labels such as enum-backed pickers and AppKit alerts.
/// English source strings are stable keys and the fallback value, matching String Catalog extraction.
nonisolated enum L10n {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
