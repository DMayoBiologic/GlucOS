import Foundation

/// The compact month calendar the Logbook jumps from (tap a day header on iPhone, ⌘J on the Mac).
/// Days with nothing logged are dimmed and can't be picked; months run from the first one with an
/// entry to this one. Plain Foundation so the grid, the limits and the spoken labels are tested.
/// docs/LogbookSearch.md "Jump to a date".
struct LogbookCalendar: Equatable {
    struct Cell: Equatable, Identifiable {
        /// Local midnight.
        let day: Date
        /// 1…31.
        let number: Int
        /// Entries logged that day (alerts don't count).
        let entries: Int
        let isToday: Bool
        let isFuture: Bool
        var id: Date { day }
        /// Dimmed days have nothing to land on.
        var canPick: Bool { entries > 0 && !isFuture }
    }

    /// The first of the month, local midnight.
    let month: Date
    /// "November 2026".
    let title: String
    /// One or two letters per weekday, starting on the calendar's first weekday.
    let weekdays: [String]
    /// Empty slots before the 1st, so it sits under its weekday.
    let leadingBlanks: Int
    let cells: [Cell]
    /// An earlier month has something logged.
    let hasEarlier: Bool
    /// This isn't the current month yet.
    let hasLater: Bool

    /// Entries per local day.
    static func counts(_ timestamps: [Date], calendar: Calendar = .autoupdatingCurrent) -> [Date: Int] {
        var out: [Date: Int] = [:]
        for t in timestamps { out[calendar.startOfDay(for: t), default: 0] += 1 }
        return out
    }

    /// The newest day with something logged, where Today in the calendar lands.
    static func latestDay(_ counts: [Date: Int]) -> Date? {
        counts.filter { $0.value > 0 }.keys.max()
    }

    static func monthStart(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? calendar.startOfDay(for: date)
    }

    /// The first of the month `by` months on (negative is earlier).
    static func shifted(_ month: Date, by: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let start = monthStart(of: month, calendar: calendar)
        return calendar.date(byAdding: .month, value: by, to: start) ?? start
    }

    /// The month holding `date`, with each day's count, today ringed and later days dimmed.
    static func month(_ date: Date, counts: [Date: Int], now: Date, calendar: Calendar = .autoupdatingCurrent,
                      locale: Locale = .autoupdatingCurrent) -> LogbookCalendar {
        let start = monthStart(of: date, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let length = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        var cells: [Cell] = []
        for i in 0..<length {
            guard let d = calendar.date(byAdding: .day, value: i, to: start) else { continue }
            let day = calendar.startOfDay(for: d)
            cells.append(Cell(day: day, number: i + 1, entries: counts[day] ?? 0,
                              isToday: day == today, isFuture: day > today))
        }
        let weekday = calendar.component(.weekday, from: start)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        let logged = counts.filter { $0.value > 0 }.keys
        let earliest = logged.min().map { monthStart(of: $0, calendar: calendar) }
        let current = monthStart(of: now, calendar: calendar)
        return LogbookCalendar(
            month: start,
            title: start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.wide).year()),
            weekdays: weekdaySymbols(calendar: calendar, locale: locale),
            leadingBlanks: blanks,
            cells: cells,
            hasEarlier: earliest.map { $0 < start } ?? false,
            hasLater: start < current)
    }

    /// "M T W T F S S" for a Monday-first calendar.
    static func weekdaySymbols(calendar: Calendar, locale: Locale) -> [String] {
        // Setting the locale resets firstWeekday to the locale's, so keep the grid's own.
        var c = calendar
        c.locale = locale
        let symbols = c.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let first = max(0, min(6, calendar.firstWeekday - 1))
        return Array(symbols[first...] + symbols[..<first])
    }
}

/// What picking a day does to the Logbook list.
enum LogbookJump {
    enum Plan: Equatable {
        /// The day is listed: spring to its header.
        case scroll(Date)
        /// Its entries are hidden by the search or a chip: clear those, then spring to it.
        case clearFiltersThenScroll(Date)
        /// Nothing logged that day (a dimmed day can't be picked, but say so anyway).
        case none
    }

    static func plan(day: Date, shownDays: Set<Date>, counts: [Date: Int],
                     calendar: Calendar = .autoupdatingCurrent) -> Plan {
        let d = calendar.startOfDay(for: day)
        if shownDays.contains(d) { return .scroll(d) }
        if (counts[d] ?? 0) > 0 { return .clearFiltersThenScroll(d) }
        return .none
    }

    /// The iPhone Logbook's id for a day's section, the same key `PhoneLogbookDay` uses.
    static func sectionID(_ day: Date) -> String { "\(Int(day.timeIntervalSince1970))" }

    /// A day in the calendar as VoiceOver says it: "Tuesday 12 November, 3 entries", or "nothing
    /// logged" for a dimmed day.
    static func spoken(_ cell: LogbookCalendar.Cell, now: Date, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let name = DayInRangeText.spokenDay(ClockLabel.day(of: cell.day, now: now, calendar: calendar),
                                            calendar: calendar, locale: locale)
        if cell.isFuture { return name }
        switch cell.entries {
        case 0: return "\(name), nothing logged"
        case 1: return "\(name), 1 entry"
        default: return "\(name), \(cell.entries) entries"
        }
    }

    /// Said once the list lands: "Showing Tuesday 12 November".
    static func announcement(_ day: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                             locale: Locale = .autoupdatingCurrent) -> String {
        "Showing " + DayInRangeText.spokenDay(ClockLabel.day(of: day, now: now, calendar: calendar),
                                              calendar: calendar, locale: locale)
    }
}

/// A day picked in the jump-to-a-date calendar. A fresh token each pick, so picking the same day
/// again still moves the list.
struct LogbookJumpRequest: Equatable {
    let day: Date
    let token = UUID()
}
