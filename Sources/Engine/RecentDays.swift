import Foundation

// The last 7 days card behind the time-in-range figure (docs/RecentDays.md): a long-press on
// iPhone Today's Insights row, or a click on the Mac popover's time-in-range bar, opens a small card
// with each of the last seven days' time in range as a mini bar, today last. Picking a bar opens
// the Logbook on that day.
//
// Each day's share is the Logbook's own day bar (`DayInRange`): 5-minute buckets, midnight to
// midnight, today midnight to now, and no bar for a day with readings in under half its
// 15-minute slots. So a day reads the same here as under its Logbook header.
//
// Observational only: shares of time, nothing about what to do.

struct RecentDays: Hashable {
    struct Day: Hashable, Identifiable {
        /// Local midnight the day starts at.
        let start: Date
        /// The day's shares, nil when it has too few readings for a bar.
        let figures: DayInRange?

        var id: Date { start }
    }

    /// How many days the card shows.
    static let count = 7

    /// Oldest first, today last: always `count` days, those without a figure included, so the
    /// bars keep their places.
    let days: [Day]

    /// Whether any day has a bar to draw.
    var hasFigures: Bool { days.contains { $0.figures != nil } }

    static func compute(readings: [GlucoseReading], low: Double, high: Double, now: Date = Date(),
                        calendar: Calendar = .autoupdatingCurrent) -> RecentDays {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let figures = DayInRange.compute(readings: readings, days: starts, low: low, high: high,
                                         now: now, calendar: calendar)
        return RecentDays(days: starts.map { Day(start: $0, figures: figures[$0]) })
    }
}

// MARK: - Motion

extension RecentDays {
    /// Bars grow up one after another, oldest first, so today's lands last.
    static let barStagger = 0.04
    /// The first bar waits for the card to finish opening.
    static let barDelay = 0.12

    /// When bar `index` starts growing, in seconds after the card opens.
    static func growDelay(_ index: Int) -> Double { barDelay + Double(max(0, index)) * barStagger }
}

// MARK: - Logbook

extension LogbookLink {
    /// One bar of the last 7 days card: everything logged that day, local midnight to midnight,
    /// alerts and all. No kind chip; the period chip names the day ("Yesterday", "Mon 16 Nov").
    static func recentDay(_ start: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                          locale: Locale = .autoupdatingCurrent) -> LogbookLink {
        let begin = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: 1, to: begin) ?? begin.addingTimeInterval(86_400)
        let day = ClockLabel.day(of: begin, now: now, calendar: calendar)
        let label = ClockLabel.dayTitle(day, calendar: calendar, locale: locale)
        let phrase: String
        switch day {
        case .today: phrase = "today"
        case .yesterday: phrase = "yesterday"
        case .other: phrase = "on " + label
        }
        return LogbookLink(filter: .recentDay,
                           period: .init(label: label, phrase: phrase, interval: DateInterval(start: begin, end: end)))
    }
}

// MARK: - Words

enum RecentDaysText {
    static let title = "Last 7 days"
    static let caption = "Time in range each day"
    static let empty = "Each day's time in range shows here once GlucOS has a day of readings."
    static let showAction = "Show last 7 days"
    static let barHint = "Opens the Logbook on this day"

    /// Under each bar: "Today", or the weekday ("Mon").
    static func barLabel(_ day: RecentDays.Day, now: Date, calendar: Calendar = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent) -> String {
        if calendar.isDate(day.start, inSameDayAs: now) { return "Today" }
        return day.start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated))
    }

    /// Over each bar: "78%", or "–" for a day without enough readings.
    static func barFigure(_ day: RecentDays.Day) -> String {
        day.figures.map(DayInRangeText.percent) ?? "–"
    }

    /// What VoiceOver reads for one bar, one line per day: "Today so far, 78% in range, 4% below",
    /// "Monday 16 November, 70% in range", "Saturday 14 November, not enough readings".
    static func spoken(_ day: RecentDays.Day, now: Date, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let which = ClockLabel.day(of: day.start, now: now, calendar: calendar)
        var line = DayInRangeText.spoken(which, day.figures, calendar: calendar, locale: locale)
        if which == .today, line.hasPrefix("Today") { line = "Today so far" + line.dropFirst("Today".count) }
        return day.figures == nil ? line + ", not enough readings" : line
    }
}
