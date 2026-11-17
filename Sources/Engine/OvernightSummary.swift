import Foundation

// Insights "Overnight": over the last 7, 14 or 30 days, how the nights went from midnight to 6 am.
// Time in range, lows that started overnight, and how far glucose usually moved across the night.
//
// Method:
// 1. The night is midnight to 6 am local time, the "Overnight" part Week in review uses. GlucOS has
//    no sleep window setting, and bedtimes and wake-ups are logged too rarely to stand in for one.
//    6 am is also about where Mornings (docs/Mornings.md) takes over, so the two don't overlap.
// 2. Readings are averaged into 5-minute buckets, as for Lows, Highs and time in range. A night
//    counts when half its 15-minute slots have readings. The card needs 3 counted nights.
// 3. Nights run inside the period: the `days` up to the newest reading. A night still under way
//    (it's 3 am now) isn't counted until 6 am.
// 4. Time in range is the share of counted nights' buckets at or between the low and high lines,
//    the same split as the time-in-range bars.
// 5. A low is `TodaySoFar.lowSpans` over the whole period, so one starting at 11:50 pm keeps its
//    shape; it's an overnight low when it started between midnight and 6 am on a counted night.
// 6. A night's change is the average of its last half hour (5:30 to 6 am) less the average of its
//    first (midnight to 12:30), each needing two buckets. The card shows the mean over the nights
//    that have one, and how many rose or fell by more than 1 mmol/L (18 mg/dL).
//
// Observational only: it describes what happened and never suggests a change to basal insulin, a
// bedtime snack or any setting. Plain Foundation, so it's unit-tested. Worked out off the main
// thread once per data change (`OvernightSummaryCache`).

struct OvernightSummary: Hashable {
    /// The same 7, 14 and 30 days as the Lows and Highs cards.
    typealias Period = LowsSummary.Period

    /// Local hours the night covers: midnight up to 6 am.
    static let startHour = 0
    static let endHour = 6
    static let minimumNights = 3
    /// A night needs this share of its 15-minute slots with readings.
    static let minimumNightCoverage = 0.5
    /// The stretch at each end of the night averaged for its change.
    static let edgeMinutes = 30
    static let minimumEdgeBuckets = 2
    /// A rise or fall bigger than this (1 mmol/L) is a night that "rose" or "fell".
    static let movedMgdl = 18.0

    struct Night: Hashable {
        /// Local midnight the night starts at.
        let start: Date
        let timeInRange: Double
        let lows: Int
        /// Last half hour less the first, mg/dL; nil without readings at both ends.
        let changeMgdl: Double?
    }

    let period: Period
    /// The newest reading: the period runs the `period.days` up to it.
    let end: Date
    /// Counted nights, oldest first.
    let nights: [Night]
    /// The share of counted nights' 5-minute buckets in range, 0...1.
    let timeInRange: Double
    /// The share below the low line, 0...1.
    let timeBelow: Double

    var count: Int { nights.count }
    var lows: Int { nights.reduce(0) { $0 + $1.lows } }
    var nightsWithLows: Int { nights.filter { $0.lows > 0 }.count }
    var changes: [Double] { nights.compactMap(\.changeMgdl) }

    /// The mean change across the night, mg/dL; nil when no night had readings at both ends.
    var averageChangeMgdl: Double? {
        let c = changes
        return c.isEmpty ? nil : c.reduce(0, +) / Double(c.count)
    }

    var rose: Int { changes.filter { $0 > Self.movedMgdl }.count }
    var fell: Int { changes.filter { $0 < -Self.movedMgdl }.count }

    // MARK: Compute

    /// Whether a moment falls in the night (midnight to 6 am local), as the Logbook's Overnight
    /// chip reads it.
    static func isOvernight(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let h = calendar.component(.hour, from: date)
        return h >= startHour && h < endHour
    }

    static func compute(readings: [GlucoseReading], low: Double, high: Double, period: Period,
                        calendar: Calendar = .autoupdatingCurrent) -> OvernightSummary? {
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

        let slot = Double(LowsSummary.coverageMinutes) * 60
        let edge = Double(edgeMinutes) * 60
        var nights: [Night] = []
        var inRange = 0, below = 0, total = 0
        var midnight = calendar.startOfDay(for: start)
        while midnight < end {
            defer { midnight = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400) }
            guard let from = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: midnight),
                  let to = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: midnight),
                  from >= start, to <= end else { continue }
            let night = buckets.filter { $0.0 >= from && $0.0 < to }
            let possible = Int((to.timeIntervalSince(from) / slot).rounded(.up))
            let filled = Set(night.map { Int(($0.0.timeIntervalSince(from) / slot).rounded(.down)) }).count
            guard !night.isEmpty, Double(filled) >= minimumNightCoverage * Double(possible) else { continue }

            let nightInRange = night.filter { $0.1 >= low && $0.1 <= high }.count
            inRange += nightInRange
            below += night.filter { $0.1 < low }.count
            total += night.count

            let first = night.filter { $0.0 < from.addingTimeInterval(edge) }.map(\.1)
            let last = night.filter { $0.0 >= to.addingTimeInterval(-edge) }.map(\.1)
            var change: Double?
            if first.count >= minimumEdgeBuckets, last.count >= minimumEdgeBuckets {
                change = last.reduce(0, +) / Double(last.count) - first.reduce(0, +) / Double(first.count)
            }
            nights.append(Night(start: from,
                                timeInRange: Double(nightInRange) / Double(night.count),
                                lows: lowStarts.filter { $0 >= from && $0 < to }.count,
                                changeMgdl: change))
        }
        guard nights.count >= minimumNights, total > 0 else { return nil }
        return OvernightSummary(period: period, end: end, nights: nights,
                                timeInRange: Double(inRange) / Double(total),
                                timeBelow: Double(below) / Double(total))
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum OvernightSummaryText {
    static let title = "Overnight"
    static let hours = "Midnight to 6 am"
    /// What the card's sparkline shows (`InsightsSparkline.overnight`).
    static let sparklineLabel = "In range each night"

    /// The row at the foot of the card that opens the Logbook (`LogbookLink.overnight`).
    static let logbookLine = "See these nights in the Logbook"

    static let logbookHint = "Opens the Logbook on what was logged between midnight and 6 am over the same days"

    static func emptyLine(_ period: OvernightSummary.Period) -> String {
        "Nights over \(period.spoken) show here once GlucOS has readings from \(OvernightSummary.minimumNights) of them."
    }

    static func nights(_ n: Int) -> String { n == 1 ? "1 night" : "\(n) nights" }

    static func percent(_ share: Double) -> String { HighsSummaryText.percent(share) }

    static func headline(_ s: OvernightSummary) -> String {
        "\(percent(s.timeInRange)) in range overnight, over \(nights(s.count))."
    }

    /// Under the Lows figure: "On 2 nights". Nil with none.
    static func lowsCaption(_ s: OvernightSummary) -> String? {
        s.lows == 0 ? nil : "On \(nights(s.nightsWithLows))"
    }

    /// Under the In range figure: "3% below". Nil with none.
    static func rangeCaption(_ s: OvernightSummary) -> String? {
        s.timeBelow > 0 ? "\(percent(s.timeBelow)) below" : nil
    }

    /// The change figure in the user's unit: "+1.2", "−0.4". "—" with none.
    static func changeValue(_ mgdl: Double?, unit: GlucoseUnit) -> String {
        guard let mgdl else { return "—" }
        return unit.formatDelta(mgdl: mgdl)
    }

    /// "Rose more than 1.0 mmol/L on 4 of 12 nights and fell as much on 2." Nil when every night
    /// held steady or none had readings at both ends.
    static func movementLine(_ s: OvernightSummary, unit: GlucoseUnit) -> String? {
        let n = s.changes.count
        guard n > 0, s.rose + s.fell > 0 else { return nil }
        let by = unit.format(mgdl: OvernightSummary.movedMgdl, withUnit: true)
        if s.fell == 0 { return "Rose more than \(by) on \(s.rose) of \(n) nights." }
        if s.rose == 0 { return "Fell more than \(by) on \(s.fell) of \(n) nights." }
        return "Rose more than \(by) on \(s.rose) of \(n) nights and fell as much on \(s.fell)."
    }

    static func footnote(_ s: OvernightSummary, lowLine: String) -> String {
        var t = "Counts nights with readings for at least half of midnight to 6 am. A low is 15 minutes or more below \(lowLine). Change is the last half hour against the first."
        if s.count < s.period.days {
            t += " Based on \(nights(s.count)) with readings."
        }
        return t + " Observations, not advice."
    }

    /// The whole card for VoiceOver, in a few sentences.
    static func spoken(_ s: OvernightSummary, lowLine: String, unit: GlucoseUnit) -> String {
        var parts = ["Overnight, midnight to 6 am, \(s.period.spoken)"]
        parts.append("\(HighsSummaryText.spokenPercent(s.timeInRange)) in range over \(nights(s.count))")
        if s.timeBelow > 0 { parts.append("\(HighsSummaryText.spokenPercent(s.timeBelow)) below \(lowLine)") }
        parts.append(s.lows == 0 ? "No lows" : "\(LowsSummaryText.lows(s.lows)) on \(nights(s.nightsWithLows))")
        if let avg = s.averageChangeMgdl {
            let size = unit.format(mgdl: abs(avg), withUnit: true)
            parts.append(unit.format(mgdl: abs(avg)) == unit.format(mgdl: 0)
                         ? "Usually steady across the night"
                         : "On average \(avg > 0 ? "rose" : "fell") \(size) across the night")
        }
        if let line = movementLine(s, unit: unit) { parts.append(String(line.dropLast())) }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill, a change of either line,
/// or a new period.
@MainActor
final class OvernightSummaryCache {
    static let shared = OvernightSummaryCache()

    struct Key: Hashable {
        var newest: Date?
        var count15: Int
        var low: Double
        var high: Double
        var period: OvernightSummary.Period
    }

    private var stored: (key: Key, value: OvernightSummary?)?

    nonisolated static func key(readings: [GlucoseReading], low: Double, high: Double,
                                period: OvernightSummary.Period) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count15: readings.count / 15, low: low, high: high, period: period)
    }

    func cached(_ key: Key) -> OvernightSummary?? {
        guard let s = stored, s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading]) async -> OvernightSummary? {
        if let hit = cached(key) { return hit }
        let low = key.low, high = key.high, period = key.period
        let v = await Task.detached(priority: .utility) {
            OvernightSummary.compute(readings: readings, low: low, high: high, period: period)
        }.value
        stored = (key, v)
        return v
    }
}
