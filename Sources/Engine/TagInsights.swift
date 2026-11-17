import Foundation

// Insights "Tags": for each tag used over the last 7, 14 or 30 days (`LogbookTags`), time in range
// and the average in the 4 hours after the entries carrying it, beside the same over the whole
// period.
//
// Method:
// 1. Readings are averaged into 5-minute buckets, as for Lows, Highs, Overnight and time in range.
//    The period is the `days` × 24 hours up to the newest reading, as on those cards.
// 2. The tags are the ones on entries inside the period, read the way the Logbook's tag chip reads
//    them (`LogEntry.filterTags`, so an Exercise moment counts as Exercise), most used first.
// 3. Each tagged entry opens a window from its time to 4 hours later. A bucket is "after the tag"
//    when it overlaps any of that tag's windows, so two entries an hour apart count the hours they
//    share once rather than twice.
// 4. Time in range and the average after a tag are over those buckets; the period's are over every
//    bucket. A tag needs an hour of buckets after it (`minimumBuckets`), or its row says it's waiting
//    for readings.
// 5. Within 5 points of the period's time in range reads as about the same (as Weekdays and
//    weekends).
//
// Observational only: it describes what happened after entries the person tagged and never suggests
// a change to insulin, food or any setting. Plain Foundation, so it's unit-tested. Worked out off
// the main thread once per data change (`TagInsightsCache`).

struct TagInsights: Hashable {
    /// The same 7, 14 and 30 days as the Lows, Highs and Overnight cards.
    typealias Period = LowsSummary.Period

    /// How long after a tagged entry counts as "after" it.
    static let windowHours = 4.0
    /// An hour of 5-minute buckets after a tag before its figures show.
    static let minimumBuckets = 12
    /// Within this many points of the period's time in range a tag reads as about the same.
    static let samePoints = 5.0
    /// Most tags the card lists; the rest are a tap away in the Logbook's chips.
    static let maxTags = 6

    struct Stats: Hashable {
        /// 5-minute buckets with readings.
        let buckets: Int
        /// The share of buckets in range, 0...1.
        let timeInRange: Double
        let averageMgdl: Double
    }

    struct Row: Hashable, Identifiable {
        /// The tag's spelling as the Logbook's chip shows it.
        let tag: String
        /// Entries carrying it inside the period.
        let entries: Int
        /// The 4 hours after those entries; nil until there's `minimumBuckets` of readings.
        let after: Stats?

        var id: String { LogbookTags.key(tag) }
    }

    let period: Period
    /// The newest reading: the period runs the `period.days` up to it.
    let end: Date
    let overall: Stats
    /// Most used first. Empty when nothing in the period carries a tag.
    let rows: [Row]

    /// The tag's time in range less the period's, in points (−8 means 8 points lower after it).
    func gapPoints(_ row: Row) -> Double? {
        row.after.map { ($0.timeInRange - overall.timeInRange) * 100 }
    }

    /// Whether the hours after a tag ran clearly higher (+1) or lower (−1) in range than the period,
    /// or about the same (0). Nil while the tag is waiting for readings.
    func direction(_ row: Row) -> Int? {
        guard let gap = gapPoints(row) else { return nil }
        guard abs(gap) >= Self.samePoints else { return 0 }
        return gap > 0 ? 1 : -1
    }

    // MARK: Compute

    static func compute(readings: [GlucoseReading], entries: [LogEntry], low: Double, high: Double,
                        period: Period) -> TagInsights? {
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
        let buckets: [Int: Double] = sums.mapValues { $0.sum / Double($0.n) }
        guard let overall = stats(Array(buckets.values), low: low, high: high) else { return nil }

        let inPeriod = entries.filter { $0.timestamp > start && $0.timestamp <= end }
        let tags = Array(LogbookTags.used(inPeriod).prefix(maxTags))
        let rows: [Row] = tags.map { tag in
            let tagged = inPeriod.filter { LogbookTags.matches($0, tag: tag) }
            let keys = afterKeys(tagged.map(\.timestamp), bucketSeconds: size)
            let values = keys.compactMap { buckets[$0] }
            let after = values.count >= minimumBuckets ? stats(values, low: low, high: high) : nil
            return Row(tag: tag, entries: tagged.count, after: after)
        }
        return TagInsights(period: period, end: end, overall: overall, rows: rows)
    }

    /// The 5-minute bucket keys (seconds since 1970 ÷ `bucketSeconds`, rounded down) that overlap
    /// the `windowHours` after any of `times`. Each key once, however many windows cover it.
    static func afterKeys(_ times: [Date], bucketSeconds size: Double) -> Set<Int> {
        let window = windowHours * 3600
        var keys = Set<Int>()
        for t in times {
            let from = t.timeIntervalSince1970
            let to = from + window
            // The bucket holding the entry, through the last one that starts before the window ends.
            var k = Int((from / size).rounded(.down))
            while Double(k) * size < to {
                keys.insert(k)
                k += 1
            }
        }
        return keys
    }

    private static func stats(_ values: [Double], low: Double, high: Double) -> Stats? {
        guard !values.isEmpty else { return nil }
        let inRange = values.filter { $0 >= low && $0 <= high }.count
        return Stats(buckets: values.count, timeInRange: Double(inRange) / Double(values.count),
                     averageMgdl: values.reduce(0, +) / Double(values.count))
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum TagInsightsText {
    static let title = "Tags"

    static func emptyLine(_ period: TagInsights.Period) -> String {
        "Nothing tagged in \(period.spoken). Tag an entry in the log sheet and it shows here."
    }

    static func entries(_ n: Int) -> String { n == 1 ? "1 entry" : "\(n) entries" }

    static func percent(_ share: Double) -> String { HighsSummaryText.percent(share) }

    /// The period's line above the tags: "All readings · 74% in range · average 7.4 mmol/L".
    static func overall(_ s: TagInsights.Stats, unit: GlucoseUnit) -> String {
        "All readings · \(percent(s.timeInRange)) in range · average \(unit.format(mgdl: s.averageMgdl, withUnit: true))"
    }

    /// Under a tag's name: "5 entries · average 6.8 mmol/L", or "2 entries · waiting for readings".
    static func detail(_ row: TagInsights.Row, unit: GlucoseUnit) -> String {
        guard let a = row.after else { return "\(entries(row.entries)) · waiting for readings" }
        return "\(entries(row.entries)) · average \(unit.format(mgdl: a.averageMgdl, withUnit: true))"
    }

    /// Beside the figure: "+8 vs all", "−6 vs all", "about the same". Nil while waiting.
    static func gap(_ row: TagInsights.Row, in t: TagInsights) -> String? {
        guard let direction = t.direction(row), let points = t.gapPoints(row) else { return nil }
        if direction == 0 { return "about the same" }
        let n = Int(abs(points).rounded())
        return direction > 0 ? "+\(n) vs all" : "−\(n) vs all"
    }

    /// One tag for VoiceOver: "Exercise, 5 entries. In the 4 hours after: 82 percent in range,
    /// average 6.8 mmol/L. 8 points more than all readings."
    static func spoken(_ row: TagInsights.Row, in t: TagInsights, unit: GlucoseUnit) -> String {
        guard let a = row.after, let direction = t.direction(row), let points = t.gapPoints(row) else {
            return "\(entries(row.entries)). Waiting for readings in the 4 hours after."
        }
        let n = Int(abs(points).rounded())
        let compare: String
        switch direction {
        case 0: compare = "About the same as all readings."
        case 1: compare = "\(n) points more than all readings."
        default: compare = "\(n) points less than all readings."
        }
        return "\(entries(row.entries)). In the 4 hours after: \(HighsSummaryText.spokenPercent(a.timeInRange)) in range, average \(unit.format(mgdl: a.averageMgdl, withUnit: true)). \(compare)"
    }

    static func logbookHint(_ tag: String) -> String {
        "Opens the Logbook on entries tagged \(tag) over the same days"
    }

    static let footnote = "Time in range in the 4 hours after each tagged entry, against every reading over the same days. Hours two entries share count once. Observations, not advice."
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill, a tagged entry added,
/// moved or retagged, a change of either line, or a new period.
@MainActor
final class TagInsightsCache {
    static let shared = TagInsightsCache()

    struct Key: Hashable {
        var newest: Date?
        var count15: Int
        var tagged: Int
        var low: Double
        var high: Double
        var period: TagInsights.Period
    }

    private var stored: (key: Key, value: TagInsights?)?

    nonisolated static func key(readings: [GlucoseReading], entries: [LogEntry], low: Double, high: Double,
                                period: TagInsights.Period) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        var h = Hasher()
        for e in entries {
            let tags = e.filterTags
            guard !tags.isEmpty else { continue }
            h.combine(e.id)
            h.combine(e.timestamp)
            h.combine(tags.map(LogbookTags.key))
        }
        return Key(newest: newest, count15: readings.count / 15, tagged: h.finalize(), low: low, high: high,
                   period: period)
    }

    func cached(_ key: Key) -> TagInsights?? {
        guard let s = stored, s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading], entries: [LogEntry]) async -> TagInsights? {
        if let hit = cached(key) { return hit }
        let low = key.low, high = key.high, period = key.period
        let v = await Task.detached(priority: .utility) {
            TagInsights.compute(readings: readings, entries: entries, low: low, high: high, period: period)
        }.value
        stored = (key, v)
        return v
    }
}
