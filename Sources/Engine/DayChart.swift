import Foundation

// A Logbook day opened into its mini glucose chart: tap a day's time-in-range bar (`DayInRange`)
// and it grows into that day's trace, on its target band, with what was logged marked along the
// bottom (docs/LogbookSearch.md, "Day charts").
//
// Method:
// 1. The chart always spans the whole day, midnight to midnight (23 or 25 hours across a clock
//    change), so today's trace stops where "now" is rather than stretching to fill the width.
// 2. Readings are averaged into 5-minute buckets, the same as the day's bar, so a stretch of
//    1-minute Bluetooth readings draws no heavier than LibreLinkUp's 15-minute history and a day
//    never plots more than 288 points.
// 3. The line breaks where readings stop for more than 20 minutes (a sensor change, a phone left
//    behind), so a gap reads as a gap rather than a straight line across it.
//
// Observational only. Worked out when a day is opened and when its readings change
// (`DayChartCache`), never per frame.

struct DayChartPoint: Hashable {
    let date: Date
    let mgdl: Double
}

enum DayChart {
    static let bucketMinutes = DayInRange.bucketMinutes
    /// A longer silence than this breaks the line.
    static let gapMinutes = 20

    /// Where the day's chart ends: the next local midnight.
    static func end(of start: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? start.addingTimeInterval(86_400)
    }

    /// The day's trace from `start` up to (not including) `end`, as runs of 5-minute means, oldest
    /// first. Each run is drawn as its own line. Readings may be in any order.
    static func segments(_ readings: [GlucoseReading], from start: Date, to end: Date) -> [[DayChartPoint]] {
        guard end > start, !readings.isEmpty else { return [] }
        let sorted = zip(readings, readings.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
            ? readings : readings.sorted { $0.timestamp < $1.timestamp }
        let size = Double(bucketMinutes) * 60
        // Bucket index → (sum, count, sum of offsets), so each point sits at its readings' mean time.
        var buckets: [Int: (sum: Double, n: Int, t: Double)] = [:]
        var i = firstIndex(in: sorted, atOrAfter: start)
        while i < sorted.count, sorted[i].timestamp < end {
            let r = sorted[i]
            i += 1
            guard r.mgdl > 0 else { continue }
            let offset = r.timestamp.timeIntervalSince(start)
            let key = Int((offset / size).rounded(.down))
            let old = buckets[key] ?? (0, 0, 0)
            buckets[key] = (old.sum + r.mgdl, old.n + 1, old.t + offset)
        }
        let points = buckets.keys.sorted().map { k -> DayChartPoint in
            let b = buckets[k]!
            return DayChartPoint(date: start.addingTimeInterval(b.t / Double(b.n)), mgdl: b.sum / Double(b.n))
        }
        var out: [[DayChartPoint]] = []
        for p in points {
            if let last = out.last?.last, p.date.timeIntervalSince(last.date) <= Double(gapMinutes) * 60 {
                out[out.count - 1].append(p)
            } else {
                out.append([p])
            }
        }
        return out
    }

    /// The day's lowest and highest points, earliest first on a tie.
    static func extremes(_ segments: [[DayChartPoint]]) -> (lowest: DayChartPoint, highest: DayChartPoint)? {
        let all = segments.joined()
        guard let lo = all.min(by: { $0.mgdl < $1.mgdl }), let hi = all.max(by: { $0.mgdl < $1.mgdl }) else { return nil }
        return (lo, hi)
    }

    /// Which day is open after a tap on `tapped`: the same day closes, another day opens in its
    /// place. One open at a time, so the pinned headers never stack two charts.
    static func toggled(open: String?, tapped: String) -> String? {
        open == tapped ? nil : tapped
    }

    /// The open day, unless it is no longer listed (searched or filtered away, or gone past the
    /// period): then nothing is open.
    static func stillOpen(_ open: String?, among days: [String]) -> String? {
        guard let open, days.contains(open) else { return nil }
        return open
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

enum DayChartText {
    /// "Lowest 3.9 at 4:10 am · Highest 12.1 at 1:30 pm", the caption under an open chart.
    static func caption(_ segments: [[DayChartPoint]], unit: GlucoseUnit, calendar: Calendar = .autoupdatingCurrent,
                        locale: Locale = .autoupdatingCurrent) -> String? {
        guard let e = DayChart.extremes(segments) else { return nil }
        return "Lowest \(unit.format(mgdl: e.lowest.mgdl)) at \(ClockLabel.time(e.lowest.date, calendar: calendar, locale: locale))"
            + " · Highest \(unit.format(mgdl: e.highest.mgdl)) at \(ClockLabel.time(e.highest.date, calendar: calendar, locale: locale))"
    }

    /// What VoiceOver says for an open day: "Tuesday 12 November, chart. 78% in range, 4% below.
    /// Lowest 3.9 mmol/L at 4:10 am, highest 12.1 mmol/L at 1:30 pm. Target 3.9 to 10.0. 3 entries
    /// logged."
    static func spoken(day: ClockLabel.Day, figures: DayInRange?, segments: [[DayChartPoint]], unit: GlucoseUnit,
                       low: Double, high: Double, logged: Int, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["\(DayInRangeText.spokenDay(day, calendar: calendar, locale: locale)), chart"]
        if let f = figures {
            var share = ["\(Format.percent(f.inRange)) in range"]
            if f.below >= 0.005 { share.append("\(Format.percent(f.below)) below") }
            if f.above >= 0.005 { share.append("\(Format.percent(f.above)) above") }
            parts.append(share.joined(separator: ", "))
        }
        if let e = DayChart.extremes(segments) {
            let lo = "\(unit.format(mgdl: e.lowest.mgdl, withUnit: true)) at \(ClockLabel.time(e.lowest.date, calendar: calendar, locale: locale))"
            let hi = "\(unit.format(mgdl: e.highest.mgdl, withUnit: true)) at \(ClockLabel.time(e.highest.date, calendar: calendar, locale: locale))"
            parts.append("Lowest \(lo), highest \(hi)")
        } else {
            parts.append("No readings")
        }
        parts.append("Target \(unit.format(mgdl: low)) to \(unit.format(mgdl: high))")
        if segments.count > 1 { parts.append(segments.count == 2 ? "1 gap in readings" : "\(segments.count - 1) gaps in readings") }
        if logged > 0 { parts.append(logged == 1 ? "1 entry logged" : "\(logged) entries logged") }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Holds the open day's segments, so a Logbook redraw (a search keystroke, a row lighting up) only
/// works them out again when the day or its readings have changed. A plain class, so filling it
/// never redraws anything.
final class DayChartCache {
    private struct Key: Equatable {
        let start: Date
        let end: Date
        let count: Int
        let last: Date?
    }

    private var key: Key?
    private var value: [[DayChartPoint]] = []
    private(set) var computeCount = 0

    func segments(readings: [GlucoseReading], from start: Date, to end: Date) -> [[DayChartPoint]] {
        let k = Key(start: start, end: end, count: readings.count, last: readings.last?.timestamp)
        if k == key { return value }
        key = k
        value = DayChart.segments(readings, from: start, to: end)
        computeCount += 1
        return value
    }
}
