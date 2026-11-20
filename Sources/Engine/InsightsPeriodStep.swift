import Foundation

// Stepping Insights back through earlier periods (docs/InsightsPeriodStep.md). Swipe on iPhone
// Insights, or ⌘[ / ⌘] and the toolbar arrows on the Mac, and every card with a period moves to
// the period of the same length just before (or after) the one it shows. A 7-day card moves 7 days,
// a 30-day card 30 days, At a glance on 24h one day.
//
// Rules:
// - `back` counts periods before the latest: 0 is the latest, and it never goes below 0, so
//   Insights never steps past today.
// - A period of whole days steps by calendar days, so it ends at the same clock time across a
//   daylight-saving change, and the dates roll over month and year ends the way the calendar does.
//   A period of hours that isn't whole days steps by exactly that many hours.
// - A card's period ends `back` steps before its latest (its newest reading, or now for At a
//   glance). The card is then worked out on the readings up to that end, so its own rules (the
//   days up to its newest reading, the period before it for Compare) apply unchanged.
// - The screen can step earlier while a 7-day period that far back still ends after the first
//   stored reading. Cards with longer periods may run out sooner; they show their own empty state.
// - Cards without a period of their own (Days, Week in review, In-range streaks, Mornings,
//   Forecast accuracy) keep showing the latest.
//
// Plain Foundation, so it's unit-tested. No dosing maths: it only picks which readings a card sees.

enum InsightsPeriodStep {
    /// The shortest card period on either screen, which decides how far back the screen can go.
    static let shortestDays = 7
    /// A ceiling well past the 90 days GlucOS keeps, so a clock change can never step forever.
    static let maximumBack = 60

    /// Where a period of `days` days ends `back` periods before `latest`.
    static func end(latest: Date, days: Int, back: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let back = max(0, back)
        guard back > 0, days > 0 else { return latest }
        return calendar.date(byAdding: .day, value: -days * back, to: latest)
            ?? latest.addingTimeInterval(-Double(days * back) * 86_400)
    }

    /// Where a period of `hours` hours ends `back` periods before `latest`. Whole days step by
    /// calendar days (24h on a clock-change day keeps the clock time), anything else by the hour.
    static func end(latest: Date, hours: Int, back: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        if hours > 0, hours % 24 == 0 {
            return end(latest: latest, days: hours / 24, back: back, calendar: calendar)
        }
        let back = max(0, back)
        return latest.addingTimeInterval(-Double(max(0, hours) * back) * 3_600)
    }

    /// Where a card's period starts, given where it ends: the card's own span, in calendar days
    /// for whole days.
    static func start(end: Date, days: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(byAdding: .day, value: -days, to: end) ?? end.addingTimeInterval(-Double(days) * 86_400)
    }

    /// The readings (oldest first) up to and including `end`. The same array when nothing is cut.
    static func readings(_ readings: [GlucoseReading], through end: Date) -> [GlucoseReading] {
        guard let last = readings.last, last.timestamp > end else { return readings }
        var lo = 0, hi = readings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if readings[mid].timestamp <= end { lo = mid + 1 } else { hi = mid }
        }
        return Array(readings[..<lo])
    }

    /// The readings a card of `days` days sees `back` periods before its newest reading.
    static func readings(_ readings: [GlucoseReading], days: Int, back: Int,
                         calendar: Calendar = .autoupdatingCurrent) -> [GlucoseReading] {
        guard back > 0, let newest = readings.last?.timestamp else { return readings }
        return self.readings(readings, through: end(latest: newest, days: days, back: back, calendar: calendar))
    }

    /// The readings from `hours` before `end` up to `end`: At a glance's window once stepped back.
    static func window(_ readings: [GlucoseReading], end: Date, hours: Double) -> [GlucoseReading] {
        let upTo = self.readings(readings, through: end)
        let cutoff = end.addingTimeInterval(-hours * 3_600)
        return Array(upTo[ChartSpan.firstIndex(in: upTo, atOrAfter: cutoff)...])
    }

    /// Whether the screen can step one period further back.
    static func canGoEarlier(back: Int, firstReading: Date?, latest: Date?,
                             calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard let firstReading, let latest, back < maximumBack else { return false }
        return end(latest: latest, days: shortestDays, back: back + 1, calendar: calendar) > firstReading
    }

    /// One step earlier (-1) or later (+1), never past the latest and never past the readings.
    static func step(_ back: Int, by direction: Int, firstReading: Date?, latest: Date?,
                     calendar: Calendar = .autoupdatingCurrent) -> Int {
        if direction > 0 { return max(0, back - 1) }
        if direction < 0, canGoEarlier(back: back, firstReading: firstReading, latest: latest, calendar: calendar) {
            return back + 1
        }
        return back
    }

    /// The horizontal swipe that steps: far enough, and clearly more sideways than up or down.
    /// A swipe to the right goes earlier (-1), to the left later (+1); nil for anything else.
    static func swipeDirection(dx: Double, dy: Double, minimum: Double = 60) -> Int? {
        guard abs(dx) >= minimum, abs(dx) > abs(dy) * 2 else { return nil }
        return dx > 0 ? -1 : 1
    }

    /// The step control's value: "Latest", "1 period earlier", "3 periods earlier".
    static func label(back: Int) -> String {
        switch back {
        case ..<1: return "Latest"
        case 1: return "1 period earlier"
        default: return "\(back) periods earlier"
        }
    }

    /// A card's caption while it shows an earlier period: "7 days · 27 Oct – 2 Nov 2026". Nil on
    /// the latest, where the picker already says it.
    static func caption(days: Int, end: Date, back: Int, calendar: Calendar = .autoupdatingCurrent,
                        locale: Locale = .autoupdatingCurrent) -> String? {
        guard back > 0 else { return nil }
        // The first whole day is the one after the start, so a 7-day period names 7 dates.
        let start = self.start(end: end, days: days, calendar: calendar)
        let firstDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let span = days == 1 ? "24 hours" : "\(days) days"
        return "\(span) · \(InsightsShare.dateRange(from: days == 1 ? end : firstDay, to: end, calendar: calendar, locale: locale))"
    }

    /// VoiceOver's reading of the caption: "Showing the 7 days to 2 Nov 2026".
    static func spokenCaption(days: Int, end: Date, back: Int, calendar: Calendar = .autoupdatingCurrent,
                              locale: Locale = .autoupdatingCurrent) -> String? {
        guard back > 0 else { return nil }
        let span = days == 1 ? "24 hours" : "\(days) days"
        return "Showing the \(span) to \(InsightsShare.dateRange(from: end, to: end, calendar: calendar, locale: locale))"
    }

    /// The days a card's period covers, for cards that step; nil for cards that keep the latest.
    static func days(for period: InsightsSharePeriod) -> Int? {
        switch period {
        case .days(let d): return d
        case .hours(let h): return h % 24 == 0 ? h / 24 : nil
        case .twoWeeks, .allStored: return nil
        }
    }
}

extension InsightsCard {
    /// Whether the card moves with the screen's period step (docs/InsightsPeriodStep.md).
    var stepsWithPeriod: Bool {
        switch self {
        case .glance, .lows, .highs, .alerts, .overnight, .weekdayWeekend, .bestDays, .tags, .dayPattern, .hourlyInRange, .sensorCoverage, .longestInRange:
            return true
        case .days, .weekInReview, .streaks, .mornings, .forecastAccuracy:
            return false
        }
    }
}
