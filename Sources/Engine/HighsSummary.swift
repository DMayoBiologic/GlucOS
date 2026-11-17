import Foundation

// Insights "Highs", the counterpart to Lows: over the last 7, 14 or 30 days, how much of the time
// glucose sat above the high line, how many highs there were, and the longest one.
//
// Method:
// 1. Readings are averaged into 5-minute buckets, as for Lows and time in range.
// 2. Time above range is the share of those buckets over the high line, the same split as the
//    time-in-range bars (above means over `high`, not at it). The "a day" figure is that share of
//    24 hours.
// 3. A high is a run over the line lasting 15 minutes or more, a gap of over 30 minutes ending one
//    (`TodaySoFar.highSpans`, the low rule turned the other way up). Its length runs from its first
//    high bucket to the first bucket back at or below the line; its peak is its highest bucket.
// 4. The period is the `days` up to the newest reading, and the card needs a day's worth of
//    15-minute slots with readings before it says anything (`LowsSummary.minimumSlots`).
//
// Observational only: it counts what happened and never suggests a dose, a correction or a change
// to settings. Plain Foundation, so it's unit-tested. Worked out off the main thread once per data
// change (`HighsSummaryCache`).

struct HighsSummary: Hashable {
    /// The same 7, 14 and 30 days as the Lows card.
    typealias Period = LowsSummary.Period

    struct High: Hashable {
        let start: Date
        let end: Date
        /// The highest 5-minute average in it.
        let peakMgdl: Double

        var minutes: Double { end.timeIntervalSince(start) / 60 }
    }

    let period: Period
    /// The newest reading: the period runs the `period.days` up to it.
    let end: Date
    /// Oldest first.
    let highs: [High]
    /// The share of 5-minute buckets with readings that sat over the high line, 0...1.
    let timeAbove: Double
    /// Days (24-hour stretches) of the period with readings in half their 15-minute slots.
    let days: Int
    /// The share above range on each calendar day of the period, oldest first, ending on the
    /// newest reading's day; nil for a day with under two hours of readings. Drawn as the card's sparkline
    /// (`InsightsSparkline.highs`).
    var daily: [Double?] = []

    var count: Int { highs.count }

    /// The longest high; the earlier one when two tie.
    var longest: High? {
        highs.reduce(nil as High?) { best, h in (best.map { h.minutes > $0.minutes } ?? true) ? h : best }
    }

    /// Time above range as minutes of a 24-hour day.
    var minutesAbovePerDay: Double { timeAbove * 1_440 }

    // MARK: Compute

    static func compute(readings: [GlucoseReading], high: Double, period: Period,
                        calendar: Calendar = .autoupdatingCurrent) -> HighsSummary? {
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

        // Coverage in 15-minute slots, exactly as the Lows card counts it.
        let slot = Double(LowsSummary.coverageMinutes) * 60
        let slotsPerDay = Int(86_400 / slot)
        var filled: [Int: Set<Int>] = [:]
        for (t, _) in buckets {
            let s = max(0, Int((t.timeIntervalSince(start) / slot).rounded(.down)))
            filled[s / slotsPerDay, default: []].insert(s % slotsPerDay)
        }
        let slots = filled.values.reduce(0) { $0 + $1.count }
        guard slots >= LowsSummary.minimumSlots else { return nil }
        let days = filled.values.filter { Double($0.count) >= LowsSummary.minimumDayCoverage * Double(slotsPerDay) }.count

        let above = Double(buckets.filter { $0.1 > high }.count) / Double(buckets.count)
        let highs = TodaySoFar.highSpans(buckets, high: high).map { span -> High in
            let peak = buckets.filter { $0.0 >= span.start && $0.0 < span.end }.map(\.1).max() ?? high
            return High(start: span.start, end: span.end, peakMgdl: peak)
        }
        var dayAbove = [Int](repeating: 0, count: period.days)
        var dayTotal = [Int](repeating: 0, count: period.days)
        for (t, v) in buckets {
            guard let i = InsightsSparkline.dayIndex(t, end: end, days: period.days, calendar: calendar) else { continue }
            dayTotal[i] += 1
            if v > high { dayAbove[i] += 1 }
        }
        let daily: [Double?] = zip(dayAbove, dayTotal).map { a, n in
            // Two hours of 5-minute buckets, as a day needs on the Day by day card.
            n < 24 ? nil : Double(a) / Double(n)
        }
        return HighsSummary(period: period, end: end, highs: highs, timeAbove: above,
                            days: min(days, period.days), daily: daily)
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum HighsSummaryText {
    static let title = "Highs"

    /// The row at the foot of the card that opens the Logbook (`LogbookLink.highs`).
    static func logbookLine(_ period: HighsSummary.Period) -> String {
        "See the last \(period.days) days in the Logbook"
    }

    static let logbookHint = "Opens the Logbook on Highs over the same days"

    /// What the card's sparkline shows (`InsightsSparkline.highs`).
    static let sparklineLabel = "Time above each day"

    static func emptyLine(_ period: HighsSummary.Period) -> String {
        "Highs over \(period.spoken) show here once GlucOS has a day of readings."
    }

    static func countValue(_ n: Int) -> String { LowsSummaryText.countValue(n) }

    static func highs(_ n: Int) -> String { n == 1 ? "1 high" : "\(n) highs" }

    /// "18%". Under 1% but not none reads "<1%", so a short high never shows as 0%.
    static func percent(_ share: Double) -> String {
        let p = share * 100
        if p > 0 && p < 0.5 { return "<1%" }
        return "\(Int(p.rounded()))%"
    }

    static func spokenPercent(_ share: Double) -> String {
        let p = share * 100
        if p > 0 && p < 0.5 { return "under 1 percent" }
        return "\(Int(p.rounded())) percent"
    }

    /// Under the Time above figure: "About 4 h 20 min a day". Nil with none.
    static func perDayCaption(_ s: HighsSummary) -> String? {
        guard s.timeAbove > 0 else { return nil }
        return "About \(LowsSummaryText.duration(roundedToFive(s.minutesAbovePerDay))) a day"
    }

    /// To the nearest 5 minutes, at least 5: "about" a day shouldn't read as precise to the minute.
    static func roundedToFive(_ minutes: Double) -> Double {
        max(5, (minutes / 5).rounded() * 5)
    }

    static func headline(_ s: HighsSummary) -> String {
        s.count == 0 ? "No highs in \(s.period.spoken)." : "\(highs(s.count)) in \(s.period.spoken)."
    }

    /// "Today at 7:40 pm", "yesterday at 7:40 pm", "Mon 9 Nov at 7:40 pm", lowercased in a sentence.
    static func when(_ date: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        let day = ClockLabel.day(of: date, now: now, calendar: calendar)
        var title = ClockLabel.dayTitle(day, calendar: calendar, locale: locale)
        if day == .today || day == .yesterday { title = title.lowercased() }
        return "\(title) at \(ClockLabel.time(date, calendar: calendar, locale: locale))"
    }

    /// "The longest began yesterday at 7:40 pm and peaked at 14.2 mmol/L." Nil with no highs.
    /// `peak` formats a glucose value in the user's unit, with the unit.
    static func longestLine(_ s: HighsSummary, peak: (Double) -> String,
                            calendar: Calendar = .autoupdatingCurrent,
                            locale: Locale = .autoupdatingCurrent) -> String? {
        guard let l = s.longest else { return nil }
        return "The longest began \(when(l.start, now: s.end, calendar: calendar, locale: locale)) and peaked at \(peak(l.peakMgdl))."
    }

    static func footnote(_ s: HighsSummary, highLine: String) -> String {
        var t = "Time above counts every reading over \(highLine). A high is 15 minutes or more above it."
        if s.days < s.period.days {
            t += " Based on \(s.days == 1 ? "1 day" : "\(s.days) days") with readings."
        }
        return t + " Observations, not advice."
    }

    /// The whole card for VoiceOver, in a few sentences.
    static func spoken(_ s: HighsSummary, highLine: String, peak: (Double) -> String,
                       calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["Highs above \(highLine), \(s.period.spoken)"]
        parts.append("Time above range \(spokenPercent(s.timeAbove))"
                     + (s.timeAbove > 0 ? ", about \(LowsSummaryText.spokenDuration(roundedToFive(s.minutesAbovePerDay))) a day" : ""))
        if let l = s.longest {
            parts.append(highs(s.count))
            parts.append("Longest \(LowsSummaryText.spokenDuration(l.minutes))")
            if let line = longestLine(s, peak: peak, calendar: calendar, locale: locale) {
                parts.append(String(line.dropLast()))
            }
        } else {
            parts.append("No highs")
        }
        if s.days < s.period.days { parts.append("Based on \(s.days == 1 ? "1 day" : "\(s.days) days") with readings") }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill, a change of high line,
/// or a new period.
@MainActor
final class HighsSummaryCache {
    static let shared = HighsSummaryCache()

    struct Key: Hashable {
        var newest: Date?
        var count15: Int
        var high: Double
        var period: HighsSummary.Period
    }

    private var stored: (key: Key, value: HighsSummary?)?

    nonisolated static func key(readings: [GlucoseReading], high: Double, period: HighsSummary.Period) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count15: readings.count / 15, high: high, period: period)
    }

    func cached(_ key: Key) -> HighsSummary?? {
        guard let s = stored, s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading]) async -> HighsSummary? {
        if let hit = cached(key) { return hit }
        let high = key.high, period = key.period
        let v = await Task.detached(priority: .utility) {
            HighsSummary.compute(readings: readings, high: high, period: period)
        }.value
        stored = (key, v)
        return v
    }
}
