import Foundation

// Insights "Weekdays and weekends": over the last 7, 14 or 30 days, time in range, lows and the
// average on weekdays set against the same on weekend days.
//
// Method:
// 1. Which days are the weekend comes from the calendar (`Calendar.isDateInWeekend`), so it follows
//    the region set on the device rather than assuming Saturday and Sunday everywhere.
// 2. Readings are averaged into 5-minute buckets, as for Lows, Highs, Overnight and time in range.
//    The period is the `days` × 24 hours up to the newest reading, as on those cards.
// 3. A local day counts when half of its 15-minute slots (12 hours) have readings inside the period.
//    That drops a sliver of a day at either end of the period, and a day the sensor was off for.
//    Each side needs 2 counted days, or the card waits.
// 4. Time in range, time below and the average are over the counted days' buckets, so a side with
//    more days doesn't weigh more in its own figures. Lows are `TodaySoFar.lowSpans` over the whole
//    period, each counted on the day it started.
// 5. The two sides are "about the same" for time in range within 5 points (as Week in review's parts
//    of the day). Lows compare as a rate per day, because a fortnight has five weekdays to every two
//    weekend days.
//
// Observational only: it describes what happened and never suggests a change to insulin, food or
// any setting. Plain Foundation, so it's unit-tested. Worked out off the main thread once per data
// change (`WeekdayWeekendCache`).

struct WeekdayWeekend: Hashable {
    /// The same 7, 14 and 30 days as the Lows, Highs and Overnight cards.
    typealias Period = LowsSummary.Period

    static let minimumDays = 2
    /// A day needs this share of its 15-minute slots with readings.
    static let minimumDayCoverage = 0.5
    /// Within this many points of time in range the two sides read as about the same.
    static let samePoints = 5.0
    /// Lows compare only when the busier side had at least this many, and this much more a day.
    static let minimumLowsToCompare = 2
    static let lowsPerDayGap = 0.25

    enum Side: String, CaseIterable, Hashable, Identifiable {
        case weekdays, weekends
        var id: String { rawValue }

        var title: String { self == .weekdays ? "Weekdays" : "Weekends" }
        /// "weekdays", "weekend days".
        var phrase: String { self == .weekdays ? "weekdays" : "weekend days" }
        /// The Logbook chip the side opens on (`LogbookLink.weekPart`).
        var filter: LogbookFilter { self == .weekdays ? .weekdays : .weekends }
        var other: Side { self == .weekdays ? .weekends : .weekdays }
    }

    struct Stats: Hashable {
        /// Counted days.
        let days: Int
        /// The share of counted days' 5-minute buckets in range, 0...1.
        let timeInRange: Double
        /// The share below the low line, 0...1.
        let timeBelow: Double
        let averageMgdl: Double
        let lows: Int

        var lowsPerDay: Double { days == 0 ? 0 : Double(lows) / Double(days) }
    }

    let period: Period
    /// The newest reading: the period runs the `period.days` up to it.
    let end: Date
    let weekdays: Stats
    let weekends: Stats

    func stats(_ side: Side) -> Stats { side == .weekdays ? weekdays : weekends }

    /// Weekends less weekdays in time in range, in points (−8 means weekends ran 8 points lower).
    var rangeGapPoints: Double { (weekends.timeInRange - weekdays.timeInRange) * 100 }

    /// The side with clearly more time in range; nil when they're within `samePoints`.
    var betterInRange: Side? {
        let gap = rangeGapPoints
        guard abs(gap) >= Self.samePoints else { return nil }
        return gap > 0 ? .weekends : .weekdays
    }

    /// The side with clearly more lows a day; nil when they're close or there were few.
    var moreLows: Side? {
        let a = weekdays, b = weekends
        guard max(a.lows, b.lows) >= Self.minimumLowsToCompare,
              abs(a.lowsPerDay - b.lowsPerDay) >= Self.lowsPerDayGap else { return nil }
        return b.lowsPerDay > a.lowsPerDay ? .weekends : .weekdays
    }

    // MARK: Compute

    /// Whether a moment falls on a weekend day where the device is set, as the Logbook's Weekends
    /// chip reads it (and Weekdays reads the rest).
    static func side(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> Side {
        calendar.isDateInWeekend(date) ? .weekends : .weekdays
    }

    static func compute(readings: [GlucoseReading], low: Double, high: Double, period: Period,
                        calendar: Calendar = .autoupdatingCurrent) -> WeekdayWeekend? {
        guard let newest = readings.last(where: { $0.mgdl > 0 }) else { return nil }
        let end = newest.timestamp
        let start = end.addingTimeInterval(-Double(period.days) * 86_400)

        let size = Double(TodaySoFar.bucketMinutes) * 60
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for r in readings where r.mgdl > 0 && r.timestamp > start && r.timestamp <= end {
            let key = Int((r.timestamp.timeIntervalSince1970 / size).rounded(.down))
            let old = sums[key] ?? (0, 0)
            sums[key] = (old.sum + r.mgdl, old.n + 1)
        }
        guard !sums.isEmpty else { return nil }
        let buckets: [(Date, Double)] = sums.keys.sorted().map {
            (Date(timeIntervalSince1970: Double($0) * size), sums[$0]!.sum / Double(sums[$0]!.n))
        }
        let lowStarts = TodaySoFar.lowSpans(buckets, low: low).map(\.start)

        struct Tally { var days = 0, inRange = 0, below = 0, total = 0, sum = 0.0, lows = 0 }
        var tally: [Side: Tally] = [.weekdays: Tally(), .weekends: Tally()]
        let slot = Double(LowsSummary.coverageMinutes) * 60
        let slotsPerDay = Int((86_400 / slot).rounded())
        var day = calendar.startOfDay(for: start)
        while day < end {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            defer { day = next }
            let inDay = buckets.filter { $0.0 >= day && $0.0 < next }
            let filled = Set(inDay.map { Int(($0.0.timeIntervalSince(day) / slot).rounded(.down)) }).count
            guard !inDay.isEmpty, Double(filled) >= minimumDayCoverage * Double(slotsPerDay) else { continue }

            let s = side(of: day, calendar: calendar)
            var t = tally[s]!
            t.days += 1
            t.inRange += inDay.filter { $0.1 >= low && $0.1 <= high }.count
            t.below += inDay.filter { $0.1 < low }.count
            t.total += inDay.count
            t.sum += inDay.reduce(0) { $0 + $1.1 }
            t.lows += lowStarts.filter { $0 >= day && $0 < next }.count
            tally[s] = t
        }

        func stats(_ s: Side) -> Stats? {
            guard let t = tally[s], t.days >= minimumDays, t.total > 0 else { return nil }
            let n = Double(t.total)
            return Stats(days: t.days, timeInRange: Double(t.inRange) / n, timeBelow: Double(t.below) / n,
                         averageMgdl: t.sum / n, lows: t.lows)
        }
        guard let weekdays = stats(.weekdays), let weekends = stats(.weekends) else { return nil }
        return WeekdayWeekend(period: period, end: end, weekdays: weekdays, weekends: weekends)
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum WeekdayWeekendText {
    static let title = "Weekdays and weekends"

    static func emptyLine(_ period: WeekdayWeekend.Period) -> String {
        "Weekdays and weekends over \(period.spoken) show here once GlucOS has readings from \(WeekdayWeekend.minimumDays) days of each."
    }

    static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    static func percent(_ share: Double) -> String { HighsSummaryText.percent(share) }

    /// Under a side's figure: "in range · 10 days".
    static func caption(_ s: WeekdayWeekend.Stats) -> String { "in range · \(days(s.days))" }

    /// A side's average: "7.2 mmol/L".
    static func average(_ s: WeekdayWeekend.Stats, unit: GlucoseUnit) -> String {
        unit.format(mgdl: s.averageMgdl, withUnit: true)
    }

    /// A side's lows: "No lows", "1 low", "3 lows".
    static func lows(_ s: WeekdayWeekend.Stats) -> String {
        s.lows == 0 ? "No lows" : LowsSummaryText.lows(s.lows)
    }

    /// "Weekends ran 8 points lower in range than weekdays." or "about the same".
    static func rangeLine(_ w: WeekdayWeekend) -> String {
        guard let better = w.betterInRange else {
            return "Time in range was about the same on weekdays and weekends."
        }
        let points = Int(abs(w.rangeGapPoints).rounded())
        let worse = better.other
        return "\(worse.title) ran \(points) points lower in range than \(better.phrase)."
    }

    /// "Lows were more frequent at weekends: 0.5 a day against 0.2." Nil when close or few.
    static func lowsLine(_ w: WeekdayWeekend) -> String? {
        guard let more = w.moreLows else { return nil }
        let at = more == .weekends ? "at weekends" : "on weekdays"
        return "Lows were more frequent \(at): \(rate(w.stats(more).lowsPerDay)) a day against \(rate(w.stats(more.other).lowsPerDay))."
    }

    /// "0.5", "1.2", "0".
    static func rate(_ perDay: Double) -> String {
        let r = (perDay * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r)
    }

    static func logbookHint(_ side: WeekdayWeekend.Side) -> String {
        "Opens the Logbook on what was logged on \(side.phrase) over the same days"
    }

    static func footnote(lowLine: String) -> String {
        "Counts days with readings for at least half the day. Weekend days follow your region's calendar. A low is 15 minutes or more below \(lowLine). Observations, not advice."
    }

    /// One side for VoiceOver: "Weekdays, 10 days. 78 percent in range, 2 percent below 3.9 mmol/L. Average 7.2 mmol/L. 3 lows."
    static func spoken(_ side: WeekdayWeekend.Side, _ w: WeekdayWeekend, lowLine: String, unit: GlucoseUnit) -> String {
        let s = w.stats(side)
        var parts = ["\(days(s.days))", "\(HighsSummaryText.spokenPercent(s.timeInRange)) in range"]
        if s.timeBelow > 0 { parts[1] += ", \(HighsSummaryText.spokenPercent(s.timeBelow)) below \(lowLine)" }
        parts.append("Average \(average(s, unit: unit))")
        parts.append(lows(s))
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill, a change of either line,
/// or a new period.
@MainActor
final class WeekdayWeekendCache {
    static let shared = WeekdayWeekendCache()

    struct Key: Hashable {
        var newest: Date?
        var count15: Int
        var low: Double
        var high: Double
        var period: WeekdayWeekend.Period
    }

    private var stored: (key: Key, value: WeekdayWeekend?)?

    nonisolated static func key(readings: [GlucoseReading], low: Double, high: Double,
                                period: WeekdayWeekend.Period) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count15: readings.count / 15, low: low, high: high, period: period)
    }

    func cached(_ key: Key) -> WeekdayWeekend?? {
        guard let s = stored, s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading]) async -> WeekdayWeekend? {
        if let hit = cached(key) { return hit }
        let low = key.low, high = key.high, period = key.period
        let v = await Task.detached(priority: .utility) {
            WeekdayWeekend.compute(readings: readings, low: low, high: high, period: period)
        }.value
        stored = (key, v)
        return v
    }
}
