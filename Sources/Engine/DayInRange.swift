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
    /// How long the day ran, in minutes: 1440 for a past day (1380 or 1500 across a clock change),
    /// midnight to now for today. The breakdown spreads it by the shares to say how long each
    /// lasted (`parts`). 0 when only the shares are known.
    var spanMinutes: Int = 0

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
        return DayInRange(below: Double(below) / n, inRange: Double(inside) / n, above: Double(above) / n,
                          spanMinutes: Int((span / 60).rounded(.down)))
    }

    /// The three shares in the bar's order, each with how long it lasted: its share of the day's
    /// span, to the nearest 5 minutes (the bucket size), so a day of 15-minute LinkUp history reads
    /// the same as one of 1-minute readings. A share that happened never rounds away to nothing,
    /// one that didn't stays at zero, and any rounding left over goes to the largest share, so the
    /// three always add up to the span.
    var parts: [DayInRangePart] {
        let step = Self.bucketMinutes
        let shares = [below, inRange, above]
        var mins = shares.map { share -> Int in
            guard share > 0, spanMinutes > 0 else { return 0 }
            let m = Int((share * Double(spanMinutes) / Double(step)).rounded()) * step
            return max(step, m)
        }
        // Below and above as rounded; in range takes the rest (at least 5 minutes if it happened).
        if inRange > 0 { mins[1] = max(step, spanMinutes - mins[0] - mins[2]) }
        let diff = spanMinutes - mins.reduce(0, +)
        if diff != 0, let top = shares.indices.max(by: { shares[$0] < shares[$1] }) {
            mins[top] = max(0, mins[top] + diff)
        }
        return [DayInRangePart(band: .below, share: below, minutes: mins[0]),
                DayInRangePart(band: .inRange, share: inRange, minutes: mins[1]),
                DayInRangePart(band: .above, share: above, minutes: mins[2])]
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

/// One share of a day's time in range, for the breakdown shown when the day is opened.
struct DayInRangePart: Hashable {
    enum Band: Hashable { case below, inRange, above }
    let band: Band
    let share: Double
    let minutes: Int
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

// MARK: - Breakdown

/// The words for a day's breakdown: each share as a percent and the time it lasted, shown under an
/// opened day on iPhone, in the Mac popover and in the Mac Day cell's tooltip
/// (docs/LogbookSearch.md, "Day breakdown").
enum DayInRangeBreakdownText {
    static func label(_ band: DayInRangePart.Band) -> String {
        switch band {
        case .below: return "Below"
        case .inRange: return "In range"
        case .above: return "Above"
        }
    }

    /// "25 min", "1 h", "18 h 40 min". "0 min" for a share that never happened.
    static func duration(_ minutes: Int) -> String {
        let m = max(0, minutes)
        guard m >= 60 else { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// "1 minute", "1 hour", "18 hours 40 minutes", as VoiceOver should say it.
    static func spokenDuration(_ minutes: Int) -> String {
        let m = max(0, minutes)
        let mins = { (n: Int) in n == 1 ? "1 minute" : "\(n) minutes" }
        guard m >= 60 else { return mins(m) }
        let h = m / 60 == 1 ? "1 hour" : "\(m / 60) hours"
        return m % 60 == 0 ? h : "\(h) \(mins(m % 60))"
    }

    /// "4% · 1 h", the figure under a share's name. Without bucket counts just the percent.
    static func figure(_ part: DayInRangePart, hasTimes: Bool) -> String {
        hasTimes ? "\(Format.percent(part.share)) · \(duration(part.minutes))" : Format.percent(part.share)
    }

    /// The Mac Day cell's tooltip: "In range 78% · 18 h 40 min, below 4% · 1 h, above 18% · 4 h 20 min.
    /// Click to show the day's chart."
    static func help(_ f: DayInRange) -> String {
        let has = f.spanMinutes > 0
        let order: [DayInRangePart.Band] = [.inRange, .below, .above]
        let parts = order.compactMap { band in f.parts.first { $0.band == band } }
        let lines = parts.enumerated().map { i, p in
            let name = i == 0 ? label(p.band) : label(p.band).lowercased()
            return "\(name) \(figure(p, hasTimes: has))"
        }
        return lines.joined(separator: ", ") + ". Click to show the day's chart."
    }

    /// The shares for VoiceOver, in range first: "78% in range, 18 hours 40 minutes. 4% below, 1
    /// hour. 18% above, 4 hours 20 minutes". Below and above are left out when they never happened.
    static func spoken(_ f: DayInRange) -> String {
        let has = f.spanMinutes > 0
        func one(_ p: DayInRangePart, _ name: String) -> String {
            has ? "\(Format.percent(p.share)) \(name), \(spokenDuration(p.minutes))" : "\(Format.percent(p.share)) \(name)"
        }
        let parts = f.parts
        var out = [one(parts[1], "in range")]
        // With times, any share that happened is said, as the row shows it ("0% · 5 min").
        let floor = has ? 0 : 0.005
        if f.below > 0, f.below >= floor { out.append(one(parts[0], "below")) }
        if f.above > 0, f.above >= floor { out.append(one(parts[2], "above")) }
        return out.joined(separator: ". ")
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

    private var figures: [String: DayInRange] = [:]

    /// The split `id`'s bar last showed, so a copy the list rebuilt (after an entry is added,
    /// edited, deleted or undone) starts there and glides to the new split rather than jumping.
    func lastFigures(_ id: String) -> DayInRange? { figures[id] }

    func remember(_ id: String, _ f: DayInRange) { figures[id] = f }
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
