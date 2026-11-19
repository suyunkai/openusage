import Foundation

/// How a span of time reads: `1d 2h` everywhere, or spelled out in the app's language (`1天2小时`,
/// `1 day 2 hr`).
enum DurationFormatSetting: String, Hashable, Sendable, CaseIterable {
    case localized
    case compact

    static let key = "durationFormat"

    static var current: DurationFormatSetting { UserDefaults.standard.enumValue(forKey: key, default: .localized) }

    var label: String {
        switch self {
        case .localized: return "Full (1 day 2 hr)"
        case .compact: return "Compact (1d 2h)"
        }
    }

    /// Spells out a duration of up to two units, in the bundle's language.
    static func spelledOut(days: Int = 0, hours: Int = 0, minutes: Int = 0, months: Int = 0, seconds: Int = 0) -> String {
        var components = DateComponents()
        components.month = months
        components.day = days
        components.hour = hours
        components.minute = minutes
        components.second = seconds
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        formatter.unitsStyle = calendar.locale?.language.languageCode == .chinese ? .abbreviated : .short
        formatter.allowedUnits = [.month, .day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: components) ?? ""
    }
}
