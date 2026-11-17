import Foundation

// Sharing one Insights card as a picture (docs/InsightsShare.md). The card is drawn as it looks on
// screen, with a small footer saying which card, over what period and which dates. Nothing in the
// picture names the person or their account: the footer is built only from the card and the dates.

/// The span a card's figures cover, for the footer.
enum InsightsSharePeriod: Equatable, Sendable {
    /// The last so many hours (At a glance on its 24h setting).
    case hours(Int)
    /// The last so many days, ending now.
    case days(Int)
    /// This week beside last week: the last 14 days, said the way the card says it.
    case twoWeeks
    /// Every reading kept on the device, from the first one (or unknown when there are none).
    case allStored(since: Date?)

    /// "Last 24 hours", "Last 14 days", "This week and last week", "All readings kept".
    var label: String {
        switch self {
        case .hours(let h): return h == 1 ? "Last hour" : "Last \(h) hours"
        case .days(let d): return d == 1 ? "Last day" : "Last \(d) days"
        case .twoWeeks: return "This week and last week"
        case .allStored: return "All readings kept"
        }
    }

    /// When the span starts, for the date range. Nil when nothing is stored yet.
    func start(now: Date) -> Date? {
        switch self {
        case .hours(let h): return now.addingTimeInterval(-Double(h) * 3_600)
        case .days(let d): return now.addingTimeInterval(-Double(d) * 86_400)
        case .twoWeeks: return now.addingTimeInterval(-14 * 86_400)
        case .allStored(let since): return since.map { min($0, now) }
        }
    }
}

enum InsightsShare {
    /// UserDefaults keys the cards keep their period pickers in. Kept here so the footer always
    /// names the period the card was drawn with.
    enum Key {
        static let glanceHours = "insights.glanceHours"
        static let lows = "insights.lowsDays"
        static let highs = "insights.highsDays"
        static let overnight = "insights.overnightDays"
        static let weekPart = "insights.weekPartDays"
        static let bestDays = "insights.bestDaysDays"
        static let tags = "insights.tagsDays"
        static let dayPattern = "insights.dayPatternDays"
    }

    /// The period a card's picker is on, read from `defaults` (each card's own default when it has
    /// never been changed). `firstReading` is the oldest reading kept, for the cards that use them all.
    static func period(for card: InsightsCard, defaults: UserDefaults = .standard,
                       firstReading: Date?) -> InsightsSharePeriod {
        func days(_ key: String, fallback: Int = 14) -> InsightsSharePeriod {
            let stored = defaults.integer(forKey: key)
            return .days(stored > 0 ? stored : fallback)
        }
        switch card {
        case .glance:
            let hours = defaults.integer(forKey: Key.glanceHours)
            let h = hours > 0 ? hours : 24
            return h % 24 == 0 && h > 24 ? .days(h / 24) : .hours(h)
        case .days: return .days(7)
        case .weekInReview: return .twoWeeks
        case .lows: return days(Key.lows)
        case .highs: return days(Key.highs)
        case .overnight: return days(Key.overnight)
        case .weekdayWeekend: return days(Key.weekPart)
        case .streaks: return .days(14)
        case .bestDays: return days(Key.bestDays)
        case .tags: return days(Key.tags)
        case .dayPattern: return days(Key.dayPattern)
        case .mornings: return .allStored(since: firstReading)
        case .forecastAccuracy: return .days(7)
        }
    }

    /// "3–17 Nov 2026", "28 Oct – 17 Nov 2026", "28 Dec 2025 – 10 Jan 2026", or one day,
    /// "17 Nov 2026". Day first, month as a short name in `locale`.
    static func dateRange(from start: Date, to end: Date, calendar: Calendar = .autoupdatingCurrent,
                          locale: Locale = .autoupdatingCurrent) -> String {
        let a = calendar.dateComponents([.year, .month, .day], from: start)
        let b = calendar.dateComponents([.year, .month, .day], from: end)
        let day = formatter("d", calendar: calendar, locale: locale)
        let dayMonth = formatter("d MMM", calendar: calendar, locale: locale)
        let full = formatter("d MMM yyyy", calendar: calendar, locale: locale)
        if a == b { return full.string(from: end) }
        if a.year == b.year && a.month == b.month {
            return "\(day.string(from: start))–\(full.string(from: end))"
        }
        if a.year == b.year {
            return "\(dayMonth.string(from: start)) – \(full.string(from: end))"
        }
        return "\(full.string(from: start)) – \(full.string(from: end))"
    }

    /// The footer's first line: "Lows · Last 14 days · 3–17 Nov 2026". Only the card's title, the
    /// period and the dates: never a name, email or account.
    static func footer(card: InsightsCard, period: InsightsSharePeriod, now: Date,
                       calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        var parts = [card.title, period.label]
        if let start = period.start(now: now) {
            parts.append(dateRange(from: start, to: now, calendar: calendar, locale: locale))
        }
        return parts.joined(separator: " · ")
    }

    /// The footer's second line.
    static let credit = "Shared from GlucOS"

    /// "GlucOS Lows 17 Nov 2026.png": the picture's file name in the share sheet.
    static func fileName(card: InsightsCard, now: Date, calendar: Calendar = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent) -> String {
        let date = formatter("d MMM yyyy", calendar: calendar, locale: locale).string(from: now)
        let title = card.title.replacingOccurrences(of: "/", with: "-")
        return "GlucOS \(title) \(date).png"
    }

    private static func formatter(_ format: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }
}
