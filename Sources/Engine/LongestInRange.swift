import Foundation

// Insights "Longest in range" (docs/LongestInRange.md): over the last 7, 14 or 30 days, the longest
// unbroken stretch spent in range, how long it lasted and when it happened.
//
// Method:
// 1. Readings are averaged into 5-minute buckets, as for time in range, Lows and Highs.
// 2. A stretch is a run of buckets at or above the low line and at or below the high line, the
//    same split as the time-in-range bars. It ends at the first bucket out of range, or, after a
//    gap of over 30 minutes with no readings, five minutes after its last in-range bucket (the low
//    and high rule, `TodaySoFar.spans`). Short gaps (LibreLinkUp's 15-minute history) don't break it.
// 3. A stretch counts from its first in-range bucket inside the period; one that started earlier
//    counts from the period's start. One still going at the newest reading is marked `ongoing`.
// 4. The period is the `days` up to the newest reading, and the card says nothing while under half
//    of its 15-minute slots have readings: a long stretch found in a mostly empty period would
//    read as more than it is. The Insights screen leaves the card out then (`LongestInRangeCache.shows`).
//
// Observational only: it measures what happened and never suggests a dose, a correction or a
// change to settings. Plain Foundation, so it's unit-tested.

struct LongestInRange: Hashable {
    /// The same 7, 14 and 30 days as the Lows and Highs cards.
    typealias Period = LowsSummary.Period

    struct Stretch: Hashable {
        let start: Date
        let end: Date
        /// Still in range at the newest reading.
        var ongoing: Bool = false

        var minutes: Double { end.timeIntervalSince(start) / 60 }
        var interval: DateInterval { DateInterval(start: start, end: end) }
    }

    let period: Period
    /// The newest reading: the period runs the `period.days` up to it.
    let end: Date
    /// The longest stretch; the later one when two tie, so the more recent one is shown.
    let longest: Stretch
    /// Stretches of `longMinutes` or more in the period.
    let longCount: Int
    /// The share of the period's 15-minute slots with readings, 0...1.
    let coverage: Double

    /// The card's "4 h+" tile.
    static let longMinutes: Double = 240
    /// Below this share of 15-minute slots with readings, the card stays out.
    static let minimumCoverage = 0.5
    /// A stretch shorter than this isn't worth a card: 15 minutes, as for a low or a high.
    static let minimumStretch: TimeInterval = 15 * 60
    static let maxGap: TimeInterval = 30 * 60

    // MARK: Compute

    /// `readings` oldest → newest. Nil under half coverage, or with no stretch of 15 minutes or more.
    static func compute(readings: [GlucoseReading], low: Double, high: Double, period: Period) -> LongestInRange? {
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
        let buckets = sums.keys.sorted().map { (Date(timeIntervalSince1970: Double($0) * size),
                                                sums[$0]!.sum / Double(sums[$0]!.n)) }

        // Coverage in 15-minute slots, so LibreLinkUp's 15-minute history counts as complete.
        let slot = Double(TodaySoFar.coverageMinutes) * 60
        let possible = Int((Double(period.days) * 86_400 / slot).rounded())
        let filled = Set(buckets.map { Int(($0.0.timeIntervalSince(start) / slot).rounded(.down)) }).count
        let coverage = min(1, Double(filled) / Double(max(1, possible)))
        guard coverage >= minimumCoverage else { return nil }

        let all = stretches(buckets, low: low, high: high, periodStart: start, newest: end)
        guard let longest = all.reduce(nil as Stretch?, { best, s in
            (best.map { s.minutes >= $0.minutes } ?? true) ? s : best
        }) else { return nil }
        return LongestInRange(period: period, end: end, longest: longest,
                              longCount: all.filter { $0.minutes >= longMinutes }.count,
                              coverage: coverage)
    }

    /// Every stretch in range of 15 minutes or more, oldest first. `points` are 5-minute buckets in
    /// time order. `newest` is the newest reading, where a stretch still going is cut off.
    static func stretches(_ points: [(Date, Double)], low: Double, high: Double,
                          periodStart: Date, newest: Date) -> [Stretch] {
        let size = Double(TodaySoFar.bucketMinutes) * 60
        var out: [Stretch] = []
        var start: Date?
        var last: Date?
        func close(_ end: Date, ongoing: Bool = false) {
            if let s = start {
                let from = max(s, periodStart)
                if end.timeIntervalSince(from) >= minimumStretch {
                    out.append(Stretch(start: from, end: end, ongoing: ongoing))
                }
            }
            start = nil; last = nil
        }
        for (t, mgdl) in points {
            if let l = last, t.timeIntervalSince(l) > maxGap { close(l.addingTimeInterval(size)) }
            if mgdl >= low && mgdl <= high {
                if start == nil { start = t }
                last = t
            } else if start != nil {
                close(t)
            }
        }
        // Still in range at the newest reading: it lasts to that reading's bucket end, no further.
        if let l = last { close(min(l.addingTimeInterval(size), max(newest, l)), ongoing: true) }
        return out
    }

    /// The Logbook over the stretch itself (`LogbookFilter.inRangeStretch`). One still going runs
    /// on to now, so something logged after the last reading still shows.
    static func link(_ stretch: Stretch, now: Date, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> LogbookLink {
        let end = stretch.ongoing ? max(stretch.end, now) : stretch.end
        return LogbookLink(filter: .inRangeStretch,
                           period: .init(label: LongestInRangeText.span(stretch, now: now, calendar: calendar, locale: locale),
                                         phrase: "during your longest time in range",
                                         interval: DateInterval(start: stretch.start, end: end)))
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum LongestInRangeText {
    static let title = "Longest in range"
    static let systemImage = "timer"

    static let logbookLine = "See this stretch in the Logbook"
    static let logbookHint = "Opens the Logbook on what you logged during it"

    /// "9 h 40 min".
    static func length(_ s: LongestInRange.Stretch) -> String { LowsSummaryText.duration(s.minutes) }

    static func headline(_ r: LongestInRange) -> String {
        "\(length(r.longest)) in range in one go\(r.longest.ongoing ? ", and counting" : "")."
    }

    /// The Logbook's period chip: "10:15 am – 2:40 pm" today, "Yesterday 1:05 pm – 6:40 pm", or
    /// "Yesterday 10:15 pm – 7:55 am" across midnight. The end names its day only when it differs
    /// from the start's.
    static func span(_ s: LongestInRange.Stretch, now: Date, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        let from = ClockLabel.dayTime(s.start, now: now, calendar: calendar, locale: locale)
        let to = calendar.isDate(s.start, inSameDayAs: s.end)
            ? ClockLabel.time(s.end, calendar: calendar, locale: locale)
            : ClockLabel.dayTime(s.end, now: now, calendar: calendar, locale: locale)
        return "\(from) – \(to)"
    }

    /// "From yesterday at 10:15 pm to 7:55 am." / "Since today at 6:05 am." for one still going.
    static func whenLine(_ r: LongestInRange, now: Date, calendar: Calendar = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent) -> String {
        let s = r.longest
        let from = HighsSummaryText.when(s.start, now: now, calendar: calendar, locale: locale)
        if s.ongoing { return "Since \(from)." }
        let to: String
        if calendar.isDate(s.start, inSameDayAs: s.end) {
            to = ClockLabel.time(s.end, calendar: calendar, locale: locale)
        } else {
            to = HighsSummaryText.when(s.end, now: now, calendar: calendar, locale: locale)
        }
        return "From \(from) to \(to)."
    }

    static func longCountValue(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }

    static func footnote(_ r: LongestInRange, rangeLine: String) -> String {
        var t = "In range is \(rangeLine). A reading out of range, or more than 30 minutes without one, ends a stretch."
        if r.coverage < 0.9 {
            t += " Readings cover \(HighsSummaryText.percent(r.coverage)) of these days, so a longer stretch may have gone unseen."
        }
        return t + " Observations, not advice."
    }

    /// The whole card for VoiceOver, in a few sentences.
    static func spoken(_ r: LongestInRange, rangeLine: String, now: Date,
                       calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["Longest time in range, \(r.period.spoken)"]
        parts.append("\(LowsSummaryText.spokenDuration(r.longest.minutes)) in one go\(r.longest.ongoing ? ", still going" : "")")
        parts.append(String(whenLine(r, now: now, calendar: calendar, locale: locale).dropLast()))
        parts.append(r.longCount == 0 ? "No stretches of 4 hours or more"
                     : r.longCount == 1 ? "1 stretch of 4 hours or more" : "\(r.longCount) stretches of 4 hours or more")
        parts.append("In range is \(rangeLine)")
        if r.coverage < 0.9 { parts.append("Readings cover \(HighsSummaryText.spokenPercent(r.coverage)) of these days") }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last results, so the card and the screen's "does it show" check work it out once per
/// data change. The key moves with each 15 minutes of new readings, a backfill, a new range, or a
/// new period or step.
@MainActor
final class LongestInRangeCache {
    static let shared = LongestInRangeCache()

    struct Key: Hashable {
        var newest: Date?
        var count: Int
        var low: Double
        var high: Double
        var period: LongestInRange.Period
        var back: Int
    }

    private var stored: [Key: LongestInRange?] = [:]

    nonisolated static func key(readings: [GlucoseReading], low: Double, high: Double,
                                period: LongestInRange.Period, back: Int) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count: readings.count / 15, low: low, high: high, period: period, back: back)
    }

    func cached(_ key: Key) -> LongestInRange?? {
        guard let hit = stored[key] else { return nil }
        return .some(hit)
    }

    /// Worked out here and now, for the screen's check whether the card shows. One pass, once per key.
    func valueNow(for key: Key, readings: [GlucoseReading]) -> LongestInRange? {
        if let hit = cached(key) { return hit }
        let shown = InsightsPeriodStep.readings(readings, days: key.period.days, back: key.back)
        let v = LongestInRange.compute(readings: shown, low: key.low, high: key.high, period: key.period)
        remember(key, v)
        return v
    }

    /// Off the main thread, for the card itself.
    func value(for key: Key, readings: [GlucoseReading]) async -> LongestInRange? {
        if let hit = cached(key) { return hit }
        let k = key
        let v = await Task.detached(priority: .utility) {
            LongestInRange.compute(readings: InsightsPeriodStep.readings(readings, days: k.period.days, back: k.back),
                                   low: k.low, high: k.high, period: k.period)
        }.value
        remember(key, v)
        return v
    }

    /// Whether the card shows on the Insights screen for the picked period and step: only with
    /// readings over half the period.
    func shows(readings: [GlucoseReading], low: Double, high: Double, back: Int,
               defaults: UserDefaults = .standard) -> Bool {
        let period = LongestInRange.Period(rawValue: defaults.integer(forKey: InsightsShare.Key.longestInRange)) ?? .fortnight
        let key = Self.key(readings: readings, low: low, high: high, period: period, back: back)
        return valueNow(for: key, readings: readings) != nil
    }

    private func remember(_ key: Key, _ value: LongestInRange?) {
        if stored.count > 12 { stored.removeAll() }
        stored[key] = value
    }
}
