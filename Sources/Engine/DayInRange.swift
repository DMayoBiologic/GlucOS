import Foundation

// Each Logbook day's time in range: the thin bar under every day header on the iPhone Logbook and
// beside each day in the Mac Logbook table (docs/LogbookSearch.md, "Day bars").
//
// Method, the same as "Today so far" (`TodaySoFar.figures`):
// 1. Readings are averaged into 5-minute buckets, so a stretch of 1-minute Bluetooth readings
//    counts the same as LibreLinkUp's 15-minute history.
// 2. A past day runs midnight to midnight (23 or 25 hours across a clock change). Today runs from
//    midnight to now and needs an hour gone.
// 3. A day needs readings in half of its 15-minute slots, otherwise it gets no bar: a day with a
//    sensor gap shows nothing rather than a share of a few hours dressed up as the day.
// 4. Each bucket counts as below (under the low threshold), in range, or above (over the high one),
//    the classification the popover and Insights use.
//
// Observational only. Worked out once per data change through `DayInRangeCache`, never per frame.

struct DayInRange: Hashable {
    /// Shares of the day's 5-minute buckets, 0...1, adding up to 1.
    var below: Double
    var inRange: Double
    var above: Double

    static let bucketMinutes = TodaySoFar.bucketMinutes
    static let coverageMinutes = TodaySoFar.coverageMinutes
    static let minimumMinutes = TodaySoFar.minimumMinutes
    static let minimumCoverage = TodaySoFar.minimumCoverage

    /// The figures for each of `days` (local midnights) that has enough readings. Readings may be
    /// in any order.
    static func compute(readings: [GlucoseReading], days: [Date], low: Double, high: Double,
                        now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [Date: DayInRange] {
        guard !readings.isEmpty, !days.isEmpty else { return [:] }
        let sorted = isSorted(readings) ? readings : readings.sorted { $0.timestamp < $1.timestamp }
        var out: [Date: DayInRange] = [:]
        for start in Set(days.map { calendar.startOfDay(for: $0) }) {
            guard start <= now, let next = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let end = min(next, now)
            if let f = figures(sorted, from: start, to: end, low: low, high: high) { out[start] = f }
        }
        return out
    }

    /// One day's figures from `start` up to (not including) `end`. `readings` must be oldest first.
    static func figures(_ readings: [GlucoseReading], from start: Date, to end: Date,
                        low: Double, high: Double) -> DayInRange? {
        let span = end.timeIntervalSince(start)
        guard span >= Double(minimumMinutes) * 60 else { return nil }
        let size = Double(bucketMinutes) * 60
        var buckets: [Int: (sum: Double, n: Int)] = [:]
        var i = firstIndex(in: readings, atOrAfter: start)
        while i < readings.count, readings[i].timestamp < end {
            let r = readings[i]
            i += 1
            guard r.mgdl > 0 else { continue }
            let key = Int((r.timestamp.timeIntervalSince(start) / size).rounded(.down))
            let old = buckets[key] ?? (0, 0)
            buckets[key] = (old.sum + r.mgdl, old.n + 1)
        }
        let slot = Double(coverageMinutes) * 60
        let possible = max(1, Int((span / slot).rounded(.up)))
        let filled = Set(buckets.keys.map { $0 * bucketMinutes / coverageMinutes }).count
        guard !buckets.isEmpty, Double(filled) >= minimumCoverage * Double(possible) else { return nil }
        var below = 0, inside = 0, above = 0
        for b in buckets.values {
            let mgdl = b.sum / Double(b.n)
            if mgdl < low { below += 1 } else if mgdl > high { above += 1 } else { inside += 1 }
        }
        let n = Double(buckets.count)
        return DayInRange(below: Double(below) / n, inRange: Double(inside) / n, above: Double(above) / n)
    }

    private static func isSorted(_ readings: [GlucoseReading]) -> Bool {
        zip(readings, readings.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
    }

    /// The first reading at or after `date`, by binary search.
    private static func firstIndex(in readings: [GlucoseReading], atOrAfter date: Date) -> Int {
        var lo = 0, hi = readings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if readings[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - Words

enum DayInRangeText {
    /// "78%", the in-range share beside the bar.
    static func percent(_ d: DayInRange) -> String { Format.percent(d.inRange) }

    /// "Today", "Yesterday", or the weekday and date in full ("Tuesday 12 November"), as VoiceOver
    /// should say a day title rather than "Tue 12 Nov".
    static func spokenDay(_ day: ClockLabel.Day, calendar: Calendar = .autoupdatingCurrent,
                          locale: Locale = .autoupdatingCurrent) -> String {
        switch day {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .other(let d):
            return d.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.wide).day().month(.wide))
        }
    }

    /// The day header's VoiceOver label: "Tuesday 12 November, 78% in range, 4% below, 18% above".
    /// Below and above are only said when the bar shows them; a day without enough readings is
    /// just its name.
    static func spoken(_ day: ClockLabel.Day, _ figures: DayInRange?, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let name = spokenDay(day, calendar: calendar, locale: locale)
        guard let f = figures else { return name }
        var parts = [name, "\(Format.percent(f.inRange)) in range"]
        if f.below >= 0.005 { parts.append("\(Format.percent(f.below)) below") }
        if f.above >= 0.005 { parts.append("\(Format.percent(f.above)) above") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Cache and draw-in

/// Holds the last `DayInRange.compute` result, so a Logbook redraw (a new reading, a search
/// keystroke) only works the figures out again when the readings, thresholds, days or 5-minute
/// clock have changed. A plain class, so filling it never redraws anything.
final class DayInRangeCache {
    private struct Key: Equatable {
        let count: Int
        let first: Date?
        let last: Date?
        let low: Double
        let high: Double
        let days: [Date]
        let clock: Int
    }

    private var key: Key?
    private var value: [Date: DayInRange] = [:]
    private(set) var computeCount = 0

    func figures(readings: [GlucoseReading], days: [Date], low: Double, high: Double,
                 now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [Date: DayInRange] {
        let k = Key(count: readings.count, first: readings.first?.timestamp, last: readings.last?.timestamp,
                    low: low, high: high, days: days,
                    clock: Int(now.timeIntervalSince1970 / (Double(DayInRange.bucketMinutes) * 60)))
        if k == key { return value }
        key = k
        value = DayInRange.compute(readings: readings, days: days, low: low, high: high, now: now, calendar: calendar)
        computeCount += 1
        return value
    }
}

/// Which day bars have already drawn in. A bar grows from the left the first time its day comes on
/// screen and is simply there after that, when it scrolls back into view or the list rebuilds, so
/// nothing plays twice and nothing loops (docs/Redesign.md §4.6). A plain class, so marking a day
/// never redraws the list.
final class DrawnOnce {
    private var drawn: Set<String> = []

    /// Whether `id` has already drawn.
    func has(_ id: String) -> Bool { drawn.contains(id) }

    /// True the first time it's asked about `id`, false every time after.
    func first(_ id: String) -> Bool { drawn.insert(id).inserted }
}

// MARK: - Days in a list

enum LogbookDays {
    /// For rows listed newest first, the first row of each calendar day mapped to that day's local
    /// midnight: the row the Mac Logbook puts the day's name and bar on.
    static func firstRows<ID: Hashable>(_ rows: [(id: ID, timestamp: Date)],
                                        calendar: Calendar = .autoupdatingCurrent) -> [ID: Date] {
        var out: [ID: Date] = [:]
        var current: Date?
        for row in rows {
            let start = calendar.startOfDay(for: row.timestamp)
            if start != current {
                out[row.id] = start
                current = start
            }
        }
        return out
    }
}
