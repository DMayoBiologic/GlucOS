import Foundation

// A small line under an Insights card's figure: the same figure worked out for each calendar day
// of the card's period, oldest on the left (docs/Redesign.md §7.2, Insights). The Lows card draws
// lows a day, Highs the share of each day above range, Overnight each night's time in range, and
// the iPhone At a glance card each of the last 14 days' time in range.
//
// The direction ("rising", "falling", "steady") is a least-squares line through the days that
// have a value, read as the change it makes across the whole period. It needs
// `minimumPoints` days and has to move more than the figure's `threshold` to count as rising or
// falling, so a day or two of noise reads as steady.
//
// Observational only: it describes what happened and never suggests a change to insulin, food or
// settings. Plain Foundation, so it's unit-tested.

struct InsightsSparkline: Hashable, Sendable {
    enum Direction: String, Hashable, Sendable {
        case rising, falling, steady
    }

    /// One value per calendar day, oldest first, ending on the day of the newest reading. nil: no
    /// readings worth counting that day.
    let values: [Double?]
    /// How far the line has to move across the period to be rising or falling, in the figure's
    /// own units (a share for time in range, a count for lows).
    let threshold: Double
    /// The smallest spread the line is drawn over, so 71% against 73% doesn't fill the height.
    let minimumSpan: Double

    static let minimumPoints = 4
    /// What the iPhone At a glance card's sparkline shows (`timeInRange`).
    static let timeInRangeLabel = "In range each day"

    var days: Int { values.count }
    /// The days that have a value.
    var known: [Double] { values.compactMap { $0 } }
    /// Enough days to draw a line.
    var drawable: Bool { known.count >= 2 }

    var direction: Direction? {
        let pts = values.enumerated().compactMap { i, v in v.map { (x: Double(i), y: $0) } }
        guard pts.count >= Self.minimumPoints else { return nil }
        let n = Double(pts.count)
        let mx = pts.reduce(0) { $0 + $1.x } / n
        let my = pts.reduce(0) { $0 + $1.y } / n
        let sxx = pts.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        guard sxx > 0 else { return nil }
        let sxy = pts.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) }
        let change = sxy / sxx * Double(max(1, days - 1))
        if change > threshold { return .rising }
        if change < -threshold { return .falling }
        return .steady
    }

    /// "rising over 14 days", for the caption and VoiceOver. nil with too few days.
    var summary: String? {
        direction.map { "\($0.rawValue) over \(days) days" }
    }

    /// "Lows each day: rising over 14 days.", for a card that VoiceOver reads as one element.
    func spokenLine(label: String) -> String? {
        summary.map { "\(label): \($0)." }
    }

    /// The line's heights from 0 (bottom) to 1, at `count` evenly spaced points left to right, so
    /// a 7-day line can morph into a 30-day one. Missing days are filled from their neighbours.
    /// Empty when there's nothing to draw.
    func heights(count: Int) -> [Double] {
        guard drawable, count >= 2 else { return [] }
        let filled = Self.fill(values)
        let lo0 = known.min() ?? 0, hi0 = known.max() ?? 0
        var lo = lo0, hi = hi0
        if hi - lo < minimumSpan {
            let mid = (lo + hi) / 2
            lo = mid - minimumSpan / 2
            hi = mid + minimumSpan / 2
            // Every figure here is zero or more: keep the floor at zero rather than float a line of
            // zeros in the middle.
            if lo < 0 { hi -= lo; lo = 0 }
        }
        let span = max(hi - lo, .ulpOfOne)
        let last = Double(filled.count - 1)
        return (0..<count).map { k in
            let x = Double(k) / Double(count - 1) * last
            let i = min(Int(x.rounded(.down)), filled.count - 1)
            let j = min(i + 1, filled.count - 1)
            let v = filled[i] + (filled[j] - filled[i]) * (x - Double(i))
            return min(1, max(0, (v - lo) / span))
        }
    }

    /// Interior gaps joined straight across; leading and trailing gaps held at the nearest day.
    static func fill(_ values: [Double?]) -> [Double] {
        let idx = values.indices.filter { values[$0] != nil }
        guard let first = idx.first, let lastIdx = idx.last else { return [] }
        return values.indices.map { i in
            if let v = values[i] { return v }
            if i < first { return values[first]! }
            if i > lastIdx { return values[lastIdx]! }
            let a = idx.last { $0 < i }!, b = idx.first { $0 > i }!
            let t = Double(i - a) / Double(b - a)
            return values[a]! + (values[b]! - values[a]!) * t
        }
    }

    // MARK: Days

    /// Which of `days` calendar days ending on `end`'s day `date` falls on, 0 the oldest; nil
    /// outside them.
    static func dayIndex(_ date: Date, end: Date, days: Int, calendar: Calendar) -> Int? {
        guard let back = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                 to: calendar.startOfDay(for: end)).day,
              back >= 0, back < days else { return nil }
        return days - 1 - back
    }

    // MARK: Builders

    /// Lows starting each day of the Lows card's period.
    static func lows(_ s: LowsSummary, calendar: Calendar = .autoupdatingCurrent) -> InsightsSparkline {
        var v = [Double?](repeating: 0, count: s.period.days)
        for low in s.lows {
            if let i = dayIndex(low.start, end: s.end, days: s.period.days, calendar: calendar) {
                v[i] = (v[i] ?? 0) + 1
            }
        }
        return InsightsSparkline(values: v, threshold: 0.5, minimumSpan: 2)
    }

    /// Each day's share above range, from the Highs card's own count (`HighsSummary.daily`).
    static func highs(_ s: HighsSummary) -> InsightsSparkline {
        InsightsSparkline(values: s.daily, threshold: 0.05, minimumSpan: 0.2)
    }

    /// Each night's time in range; nights the Overnight card didn't count are gaps.
    static func overnight(_ s: OvernightSummary, calendar: Calendar = .autoupdatingCurrent) -> InsightsSparkline {
        var v = [Double?](repeating: nil, count: s.period.days)
        for night in s.nights {
            if let i = dayIndex(night.start, end: s.end, days: s.period.days, calendar: calendar) {
                v[i] = night.timeInRange
            }
        }
        return InsightsSparkline(values: v, threshold: 0.05, minimumSpan: 0.2)
    }

    /// Time in range for each of the last `days` calendar days up to the newest reading, split the
    /// way `GlucoseStats` splits it. A day with under two hours of readings (gaps over 30 minutes
    /// don't count) is a gap, as on the Day by day card.
    static func timeInRange(readings: [GlucoseReading], low: Double, high: Double, days: Int = 14,
                            calendar: Calendar = .autoupdatingCurrent) -> InsightsSparkline {
        let empty = InsightsSparkline(values: [Double?](repeating: nil, count: days), threshold: 0.05, minimumSpan: 0.2)
        guard let end = readings.last(where: { $0.mgdl > 0 })?.timestamp else { return empty }
        var byDay = [[GlucoseReading]](repeating: [], count: days)
        for r in readings where r.mgdl > 0 {
            if let i = dayIndex(r.timestamp, end: end, days: days, calendar: calendar) { byDay[i].append(r) }
        }
        let values: [Double?] = byDay.map { rs in
            guard coveredHours(rs) >= 2 else { return nil }
            let n = Double(rs.count)
            let below = Double(rs.filter { $0.mgdl < low }.count) / n
            let above = Double(rs.filter { $0.mgdl > high }.count) / n
            return max(0, 1 - below - above)
        }
        return InsightsSparkline(values: values, threshold: empty.threshold, minimumSpan: empty.minimumSpan)
    }

    /// Hours covered by readings, skipping any gap over 30 minutes.
    static func coveredHours(_ readings: [GlucoseReading]) -> Double {
        let times = readings.map(\.timestamp).sorted()
        guard times.count > 1 else { return 0 }
        var covered: TimeInterval = 0
        for (a, b) in zip(times, times.dropFirst()) where b.timeIntervalSince(a) <= 30 * 60 {
            covered += b.timeIntervalSince(a)
        }
        return covered / 3600
    }
}
