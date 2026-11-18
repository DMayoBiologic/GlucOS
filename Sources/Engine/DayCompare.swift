import Foundation

// Two Logbook days side by side: pick a second day from the jump-to-a-date calendar or a day's
// menu, and both days' readings are drawn over one midnight-to-midnight chart, with each day's time
// in range, average and number of lows and highs beside each other (docs/LogbookSearch.md,
// "Comparing two days").
//
// Method:
// 1. Each day's trace is its 5-minute means (`DayChart.segments`), placed by wall-clock time of
//    day, so 6 pm sits over 6 pm even when one of the days had a clock change. On a 25-hour day the
//    repeated hour draws over itself as its own run; on a 23-hour day the skipped hour is a gap.
// 2. Time in range is the day bar's figure (`DayInRange.figures`, today up to now, with the same
//    coverage rule), so the comparison never disagrees with the bars in the list.
// 3. The average is the mean of the day's 5-minute means. Lows and highs are runs of 15 minutes or
//    more outside the target lines (`TodaySoFar.lowSpans` / `highSpans`, the Insights rules).
//
// Observational only: it shows what happened on each day and never says which day was better or
// what to change. Worked out when the comparison opens or its second day moves, never per frame.

/// A point on the comparison chart: minutes since local midnight by the wall clock (0..<1440).
struct DayComparePoint: Hashable {
    let minute: Double
    let mgdl: Double
}

/// One day's side of the comparison.
struct DayCompareDay: Hashable {
    /// The day's local midnight.
    let start: Date
    /// Runs of the trace by time of day, each drawn as its own line.
    let runs: [[DayComparePoint]]
    /// The day bar's split, nil when the day has too few readings for one.
    let inRange: DayInRange?
    let averageMgdl: Double?
    let lows: Int
    let highs: Int

    var hasReadings: Bool { !runs.isEmpty }
}

enum DayCompare {
    static let minutesPerDay = 1_440.0
    /// The hours labelled along the bottom of the chart: midnight, 6 am, noon, 6 pm, midnight.
    static let tickMinutes: [Double] = [0, 360, 720, 1_080, 1_440]
    /// A day needs at least this many readings to be offered in the calendar's compare mode.
    static let minimumReadings = 12

    /// Minutes since local midnight by the wall clock, so 6 pm is 1,080 on any day, a clock change
    /// or not.
    static func minuteOfDay(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0) + Double(c.second ?? 0) / 60
    }

    /// A day's trace placed by time of day. A run is split wherever the clock goes backwards (the
    /// repeated hour) or jumps more than the chart's gap (the skipped hour), so no line ever doubles
    /// back or bridges an hour the day never had.
    static func overlay(_ segments: [[DayChartPoint]], calendar: Calendar = .autoupdatingCurrent) -> [[DayComparePoint]] {
        var out: [[DayComparePoint]] = []
        let gap = Double(DayChart.gapMinutes)
        for run in segments {
            var current: [DayComparePoint] = []
            for p in run {
                let point = DayComparePoint(minute: minuteOfDay(p.date, calendar: calendar), mgdl: p.mgdl)
                if let last = current.last, point.minute < last.minute || point.minute - last.minute > gap {
                    out.append(current)
                    current = []
                }
                current.append(point)
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    /// Everything one side of the comparison shows, for the day containing `day`.
    static func day(_ day: Date, readings: [GlucoseReading], low: Double, high: Double, now: Date = Date(),
                    calendar: Calendar = .autoupdatingCurrent) -> DayCompareDay {
        let start = calendar.startOfDay(for: day)
        let end = min(DayChart.end(of: start, calendar: calendar), max(now, start))
        let sorted = zip(readings, readings.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
            ? readings : readings.sorted { $0.timestamp < $1.timestamp }
        let segments = DayChart.segments(sorted, from: start, to: end)
        // Lows and highs are counted on bucket starts, as `TodaySoFar` counts them; the chart keeps
        // each point at its readings' mean time.
        let size = Double(DayChart.bucketMinutes) * 60
        let points = segments.joined().map { p -> (Date, Double) in
            let k = (p.date.timeIntervalSince(start) / size).rounded(.down)
            return (start.addingTimeInterval(k * size), p.mgdl)
        }
        let average = points.isEmpty ? nil : points.map { $0.1 }.reduce(0, +) / Double(points.count)
        return DayCompareDay(
            start: start,
            runs: overlay(segments, calendar: calendar),
            inRange: DayInRange.figures(sorted, from: start, to: end, low: low, high: high),
            averageMgdl: average,
            lows: TodaySoFar.lowSpans(points, low: low).count,
            highs: TodaySoFar.highSpans(points, high: high).count
        )
    }

    /// Days with enough readings to compare, by local midnight, for the calendar's compare mode.
    /// One `startOfDay` per day rather than per reading, so a 90-day archive of 1-minute readings
    /// stays quick. Readings may be in any order.
    static func readingDays(_ readings: [GlucoseReading], calendar: Calendar = .autoupdatingCurrent) -> [Date: Int] {
        let sorted = zip(readings, readings.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
            ? readings : readings.sorted { $0.timestamp < $1.timestamp }
        var counts: [Date: Int] = [:]
        var dayStart: Date?
        var dayEnd: Date?
        for r in sorted where r.mgdl > 0 {
            if dayEnd == nil || r.timestamp >= dayEnd! || r.timestamp < dayStart! {
                let s = calendar.startOfDay(for: r.timestamp)
                dayStart = s
                dayEnd = DayChart.end(of: s, calendar: calendar)
            }
            counts[dayStart!, default: 0] += 1
        }
        return counts.filter { $0.value >= minimumReadings }
    }

    /// The second day after stepping it by `by` days, skipping over the first day so the two are
    /// never the same, or nil when that would pass today or leave the days that have readings.
    static func stepped(_ second: Date, by: Int, first: Date, days: Set<Date>, now: Date = Date(),
                        calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard by != 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.startOfDay(for: first)
        let earliest = days.min() ?? today
        var d = calendar.startOfDay(for: second)
        repeat {
            guard let next = calendar.date(byAdding: .day, value: by > 0 ? 1 : -1, to: d) else { return nil }
            d = next
            if d > today || d < earliest { return nil }
        } while d == firstDay || !days.contains(d)
        return d
    }
}

// MARK: - Words

enum DayCompareText {
    static let menuName = "Compare with Another Day"
    static let calendarButton = "Compare"
    static let title = "Compare Days"

    /// "Pick a day to compare with Today", above the calendar in compare mode.
    static func prompt(spokenDay: String) -> String { "Pick a day to compare with \(spokenDay)" }

    static let calendarFootnote = "Dimmed days have too few readings"

    /// "Average 7.2" (the unit is shown once, beside the title).
    static func average(_ d: DayCompareDay, unit: GlucoseUnit) -> String {
        d.averageMgdl.map { unit.format(mgdl: $0) } ?? "–"
    }

    static func inRange(_ d: DayCompareDay) -> String {
        d.inRange.map { Format.percent($0.inRange) } ?? "–"
    }

    static func count(_ n: Int) -> String { "\(n)" }

    static func lows(_ n: Int) -> String { n == 0 ? "no lows" : n == 1 ? "1 low" : "\(n) lows" }
    static func highs(_ n: Int) -> String { n == 0 ? "no highs" : n == 1 ? "1 high" : "\(n) highs" }

    /// What VoiceOver says for one day: "Today: 78% in range, average 7.2 mmol/L, 1 low, 2 highs."
    /// A day with too few readings for time in range says so; one with none says "No readings."
    static func spoken(_ d: DayCompareDay, spokenDay: String, unit: GlucoseUnit) -> String {
        guard d.hasReadings, let avg = d.averageMgdl else { return "\(spokenDay): no readings." }
        var parts: [String] = []
        if let f = d.inRange {
            parts.append("\(Format.percent(f.inRange)) in range")
        } else {
            parts.append("too few readings for time in range")
        }
        parts.append("average \(unit.format(mgdl: avg, withUnit: true))")
        parts.append(lows(d.lows))
        parts.append(highs(d.highs))
        return "\(spokenDay): " + parts.joined(separator: ", ") + "."
    }

    /// The chart's VoiceOver label: "Chart of Today and Monday 11 November, overlaid by time of day,
    /// midnight to midnight. Target 3.9 to 10.0."
    static func chartSpoken(first: String, second: String, unit: GlucoseUnit, low: Double, high: Double) -> String {
        "Chart of \(first) and \(second), overlaid by time of day, midnight to midnight. "
            + "Target \(unit.format(mgdl: low)) to \(unit.format(mgdl: high))."
    }

    /// Said once when the comparison opens or its second day changes: "Comparing Today with Monday
    /// 11 November."
    static func announcement(first: String, second: String) -> String { "Comparing \(first) with \(second)." }

    /// A calendar day in compare mode as VoiceOver says it: "Tuesday 12 November, has readings", or
    /// "too few readings" for a dimmed day, or "the day being compared" for the one it opened from.
    static func calendarSpoken(_ cell: LogbookCalendar.Cell, isFrom: Bool, now: Date,
                               calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        let name = DayInRangeText.spokenDay(ClockLabel.day(of: cell.day, now: now, calendar: calendar),
                                            calendar: calendar, locale: locale)
        if isFrom { return "\(name), the day being compared" }
        if cell.isFuture { return name }
        return cell.entries > 0 ? "\(name), has readings" : "\(name), too few readings"
    }

    /// The hour labels along the bottom: "midnight", "6 am", "noon", "6 pm".
    static func tick(_ minute: Double) -> String { DayPatternText.clock(Int(minute)) }
}

/// The two days on screen in a comparison, and the days its second day can step through.
struct DayComparePair: Identifiable, Hashable {
    let first: Date
    let second: Date
    let days: Set<Date>

    var id: String { "\(Int(first.timeIntervalSince1970))-\(Int(second.timeIntervalSince1970))" }
}
