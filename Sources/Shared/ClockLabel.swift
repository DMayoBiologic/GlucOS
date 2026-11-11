import Foundation

/// Times of day as people read them, always in the device's own time zone (or the one passed in,
/// for tests). Every label that could be misread as today says which day it belongs to: at 5:30 am,
/// a dose shown only as "10:46 am" looks like it's still to come.
enum ClockLabel {
    /// The day an entry falls on, relative to `now`.
    enum Day: Equatable {
        case today
        case yesterday
        /// The start of an earlier (or later) day.
        case other(Date)
    }

    private static func style(calendar: Calendar, locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }

    /// "5:33 pm".
    static func time(_ date: Date, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(style(calendar: calendar, locale: locale).hour().minute())
    }

    static func day(of date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> Day {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return .yesterday
        }
        return .other(calendar.startOfDay(for: date))
    }

    /// "Today", "Yesterday", or "Mon 9 Nov".
    static func dayTitle(_ day: Day, calendar: Calendar = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent) -> String {
        switch day {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .other(let d):
            return d.formatted(style(calendar: calendar, locale: locale).weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// "5:33 pm" today, "Yesterday 10:46 am", or "Mon 9 Nov 10:46 am".
    static func dayTime(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                        locale: Locale = .autoupdatingCurrent) -> String {
        let t = time(date, calendar: calendar, locale: locale)
        let d = day(of: date, now: now, calendar: calendar)
        return d == .today ? t : "\(dayTitle(d, calendar: calendar, locale: locale)) \(t)"
    }

    /// Each midnight strictly after `start` and up to `end`, where a chart crosses into a new day.
    static func midnights(from start: Date, to end: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        guard start < end else { return [] }
        var out: [Date] = []
        var next = calendar.startOfDay(for: start)
        while let d = calendar.date(byAdding: .day, value: 1, to: next), d <= end {
            out.append(d)
            next = d
        }
        return out
    }
}
