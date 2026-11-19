import Foundation
import SwiftUI

/// A user-facing string, looked up in the app bundle's `Localizable.strings` like SwiftUI's own
/// `Text("…")`. Interpolations become format arguments (`%@`, `%lld`, `%lf`), so the key matches what
/// `swiftc -emit-localized-strings` extracts.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .main)
}

/// The in-app language choice. `AppleLanguages` in the app's own defaults decides which `.lproj` the
/// bundle reads; it takes effect at the next launch.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    static let defaultsKey = "AppleLanguages"

    static func current(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[defaultsKey] != nil,
              let first = (defaults.array(forKey: defaultsKey) as? [String])?.first else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    func apply(in defaults: UserDefaults = .standard) {
        switch self {
        case .system: defaults.removeObject(forKey: Self.defaultsKey)
        case .simplifiedChinese, .english: defaults.set([rawValue], forKey: Self.defaultsKey)
        }
    }
}

/// Looks up a string that was built in English elsewhere (a metric's title, an error's description) by
/// its exact text, so data that doubles as an identifier stays English and only its display changes.
/// A string with no entry, such as one carrying a name or a number, shows as it is.
func LS(_ text: String) -> String {
    Bundle.main.localizedString(forKey: text, value: text, table: nil)
}


extension Text {
    /// `Text(verbatim:)` for an already-built string, translated by its exact English text when the
    /// table has it.
    init(loc text: String) {
        self.init(verbatim: LS(text))
    }
}
