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
    /// With `figures`, the day's time in range follows, so the cell's tint is said in words too:
    /// "Tuesday 12 November, 3 entries, 78% in range".
    static func spoken(_ cell: LogbookCalendar.Cell, now: Date, figures: DayInRange? = nil,
                       calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let name = DayInRangeText.spokenDay(ClockLabel.day(of: cell.day, now: now, calendar: calendar),
                                            calendar: calendar, locale: locale)
        if cell.isFuture { return name }
        let entries: String
        switch cell.entries {
        case 0: entries = "\(name), nothing logged"
        case 1: entries = "\(name), 1 entry"
        default: entries = "\(name), \(cell.entries) entries"
        }
        guard let figures else { return entries }
        return entries + ", \(DayInRangeText.percent(figures)) in range"
    }

    /// Said once the list lands: "Showing Tuesday 12 November".
    static func announcement(_ day: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                             locale: Locale = .autoupdatingCurrent) -> String {
        "Showing " + DayInRangeText.spokenDay(ClockLabel.day(of: day, now: now, calendar: calendar),
                                              calendar: calendar, locale: locale)
    }
}

/// How the jump-to-a-date calendar moves and colours its days (round 86): a sideways swipe steps the
/// month, each day's circle washes in tinted by its time in range (`DayInRange`, the Logbook day
/// bars' figures and colours), one after another along the grid. Plain numbers so the rules are
/// tested; the view only animates them. docs/LogbookSearch.md "Jump to a date".
enum LogbookCalendarMotion {
    /// Which range colour a day's circle takes.
    enum Band: Equatable {
        case below, inRange, above
    }

    struct Tint: Equatable {
        let band: Band
        /// The circle's fill opacity, 0.12...0.32: stronger the more of the day sat in that band.
        let strength: Double
    }

    /// The in-range share at or above which a day reads as in range (the usual 70% goal).
    static let inRangeGoal = 0.7
    static let weakest = 0.12
    static let strongest = 0.32

    /// A day with enough readings is tinted in range when at least 70% of it was; otherwise by
    /// whichever of below or above it spent longer in (below on a tie, the one that matters more).
    /// A day without enough readings has no tint and keeps the plain circle.
    static func tint(_ figures: DayInRange?) -> Tint? {
        guard let f = figures else { return nil }
        let band: Band
        let share: Double
        if f.inRange >= inRangeGoal {
            band = .inRange; share = f.inRange
        } else if f.below >= f.above {
            band = .below; share = f.below
        } else {
            band = .above; share = f.above
        }
        let strength = weakest + (strongest - weakest) * min(1, max(0, share))
        return Tint(band: band, strength: (strength * 1000).rounded() / 1000)
    }

    /// How far a drag must travel sideways before letting go steps the month.
    static let swipeDistance: Double = 44

    /// The month step a drag ends in: a swipe left goes to the later month, right to the earlier
    /// one, only when it travelled far enough, mostly sideways, and that month can be shown.
    static func swipeStep(width: Double, height: Double, hasEarlier: Bool, hasLater: Bool) -> Int {
        guard abs(width) >= swipeDistance, abs(width) > abs(height) * 1.5 else { return 0 }
        if width < 0 { return hasLater ? 1 : 0 }
        return hasEarlier ? -1 : 0
    }

    /// Where the grid sits while dragging: with the finger, or a fifth as far (a rubber band)
    /// towards a month that can't be shown.
    static func dragOffset(width: Double, hasEarlier: Bool, hasLater: Bool) -> Double {
        let blocked = width < 0 ? !hasLater : !hasEarlier
        return blocked ? width * 0.2 : width * 0.6
    }

    /// Each tint's wait, by the day's place in the month: a quick wave from the 1st, capped so the
    /// whole month is in within half a second.
    static func revealDelay(index: Int) -> Double {
        let i = min(max(0, index), 30)
        return (Double(i) * 0.012 * 1000).rounded() / 1000
    }
}

/// A day picked in the jump-to-a-date calendar. A fresh token each pick, so picking the same day
/// again still moves the list.
struct LogbookJumpRequest: Equatable {
    let day: Date
    /// Back to the top (`LogbookToday`): the Today pill or ⌘T, not a day picked in the calendar.
    /// Lands on the newest listed row, and moves instantly under Reduce Motion.
    var toTop = false
    let token = UUID()
}
