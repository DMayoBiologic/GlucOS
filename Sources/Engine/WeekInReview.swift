import Foundation

// Week in review: the last 7 days against the 7 before them, for time in range, the average and
// lows, and which part of the day went best and which was hardest this week.
//
// Method:
// 1. Readings are averaged into 5-minute buckets (as `DayPattern` and `TodaySoFar` do), so a
//    stretch of 1-minute Bluetooth readings counts the same as LibreLinkUp's 15-minute history.
// 2. "This week" is the 7 days up to the newest reading and "last week" the 7 days before that, so
//    both are full weeks whatever day it is. A week counts only when 4 of its 7 days (24-hour
//    stretches) have readings in half of their 15-minute slots. Without that this week has nothing
//    to say yet, and without a last week the card shows this week on its own.
// 3. Lows are runs below the low threshold lasting 15 minutes or more, a gap of over 30 minutes
//    ending one (`TodaySoFar.lowRuns`, the dashboard Days rule).
// 4. The day is split into four parts (overnight, morning, afternoon, evening, by local clock).
//    Each part needs `minimumPartBuckets` buckets this week. Best is the part with the most time in
//    range, hardest the one with the least; when they're within 5 points the day reads as steady.
//
// Observational only, like Insights: it says how the week went and never suggests a change to
// insulin or settings. Plain Foundation, so it's unit-tested. Worked out off the main thread once
// per data change (see `WeekInReviewCache`), never per frame, and the card it feeds doesn't animate.

struct WeekInReview: Hashable {
    struct Week: Hashable {
        /// Shares of 5-minute buckets in, below and above the target, 0...1.
        var timeInRange: Double
        var below: Double
        var above: Double
        var meanMgdl: Double
        /// Runs below range of 15 minutes or more.
        var lows: Int
        /// Days (24-hour stretches) of the 7 with enough readings.
        var days: Int
    }

    enum Part: Int, CaseIterable, Hashable {
        case overnight, morning, afternoon, evening

        /// Hours 0-6, 6-12, 12-18, 18-24.
        static func of(hour: Int) -> Part { Part(rawValue: min(3, max(0, hour / 6))) ?? .overnight }

        /// "Overnight", "Mornings": the tile and line label.
        var name: String {
            switch self {
            case .overnight: return "Overnight"
            case .morning: return "Mornings"
            case .afternoon: return "Afternoons"
            case .evening: return "Evenings"
            }
        }

        /// "midnight to 6 am", spoken after the name.
        var hours: String {
            let start = rawValue * 360
            return "\(DayPatternText.clock(start)) to \(DayPatternText.clock(start + 360))"
        }
    }

    struct PartFigures: Hashable {
        var part: Part
        var timeInRange: Double
        var below: Double
        var above: Double
        var meanMgdl: Double
        var buckets: Int
    }

    /// The newest reading: this week runs the 7 days up to it.
    let end: Date
    let thisWeek: Week
    /// Nil until the week before has enough readings to compare with.
    let lastWeek: Week?
    /// This week's parts of the day that had enough readings, in clock order.
    let parts: [PartFigures]

    static let bucketMinutes = 5
    static let coverageMinutes = 15
    static let weekDays = 7
    /// Days of the 7 a week needs, each with readings in half its 15-minute slots.
    static let minimumDays = 4
    static let minimumDayCoverage = 0.5
    /// Buckets a part of the day needs this week: two days of LibreLinkUp's 15-minute history.
    static let minimumPartBuckets = 48

    // MARK: Compute

    static func compute(readings: [GlucoseReading], low: Double, high: Double,
                        calendar: Calendar = .autoupdatingCurrent) -> WeekInReview? {
        guard let newest = readings.last(where: { $0.mgdl > 0 }) else { return nil }
        let end = newest.timestamp
        let week = Double(weekDays) * 86_400
        let thisStart = end.addingTimeInterval(-week)
        let lastStart = thisStart.addingTimeInterval(-week)

        let size = Double(bucketMinutes) * 60
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for r in readings where r.mgdl > 0 && r.timestamp > lastStart && r.timestamp <= end {
            let key = Int((r.timestamp.timeIntervalSince1970 / size).rounded(.down))
            let old = sums[key] ?? (0, 0)
            sums[key] = (old.sum + r.mgdl, old.n + 1)
        }
        let buckets = sums.keys.sorted().map { (time: Date(timeIntervalSince1970: Double($0) * size),
                                                mgdl: sums[$0]!.sum / Double(sums[$0]!.n)) }
        // Bucket times are floored, so a week starts at the bucket holding its first moment.
        let thisFrom = floor(thisStart.timeIntervalSince1970 / size) * size
        let thisBuckets = buckets.filter { $0.time.timeIntervalSince1970 >= thisFrom }
        let lastBuckets = buckets.filter { $0.time.timeIntervalSince1970 < thisFrom }

        guard let this = figures(thisBuckets, from: thisStart, low: low, high: high) else { return nil }
        let last = figures(lastBuckets, from: lastStart, low: low, high: high)

        var byPart: [Part: [Double]] = [:]
        for b in thisBuckets {
            byPart[Part.of(hour: calendar.component(.hour, from: b.time)), default: []].append(b.mgdl)
        }
        let parts: [PartFigures] = Part.allCases.compactMap { part in
            guard let values = byPart[part], values.count >= minimumPartBuckets else { return nil }
            let n = Double(values.count)
            return PartFigures(part: part,
                               timeInRange: Double(values.filter { $0 >= low && $0 <= high }.count) / n,
                               below: Double(values.filter { $0 < low }.count) / n,
                               above: Double(values.filter { $0 > high }.count) / n,
                               meanMgdl: values.reduce(0, +) / n, buckets: values.count)
        }
        return WeekInReview(end: end, thisWeek: this, lastWeek: last, parts: parts)
    }

    /// One week's figures from `start` over 7 days, or nil when under 4 of its days have readings.
    static func figures(_ buckets: [(time: Date, mgdl: Double)], from start: Date,
                        low: Double, high: Double) -> Week? {
        guard !buckets.isEmpty else { return nil }
        // Coverage per 24-hour stretch, counted in 15-minute slots so LibreLinkUp's 15-minute
        // history counts as complete.
        let slot = Double(coverageMinutes) * 60
        let slotsPerDay = Int(86_400 / slot)
        var filled: [Int: Set<Int>] = [:]
        for b in buckets {
            let s = max(0, Int((b.time.timeIntervalSince(start) / slot).rounded(.down)))
            filled[s / slotsPerDay, default: []].insert(s % slotsPerDay)
        }
        let days = filled.values.filter { Double($0.count) >= minimumDayCoverage * Double(slotsPerDay) }.count
        guard days >= minimumDays else { return nil }

        let n = Double(buckets.count)
        let inRange = buckets.filter { $0.mgdl >= low && $0.mgdl <= high }.count
        let below = buckets.filter { $0.mgdl < low }.count
        return Week(timeInRange: Double(inRange) / n,
                    below: Double(below) / n,
                    above: Double(buckets.count - inRange - below) / n,
                    meanMgdl: buckets.reduce(0) { $0 + $1.mgdl } / n,
                    lows: TodaySoFar.lowRuns(buckets.map { ($0.time, $0.mgdl) }, low: low),
                    days: min(weekDays, days))
    }

    // MARK: Comparison

    typealias Change = TodaySoFar.Change

    var rangeChange: Change? {
        guard let lastWeek else { return nil }
        let d = thisWeek.timeInRange - lastWeek.timeInRange
        return abs(d) < TodaySoFar.rangeStep ? .same : (d > 0 ? .better : .worse)
    }

    /// The part with the most time in range; ties go to the one with fewer lows.
    var best: PartFigures? {
        parts.min { ($0.timeInRange, -$0.below) > ($1.timeInRange, -$1.below) }
    }

    /// The part with the least time in range; ties go to the one with more time low.
    var worst: PartFigures? {
        parts.min { ($0.timeInRange, -$0.below) < ($1.timeInRange, -$1.below) }
    }

    /// Fewer than two parts to compare, or best and hardest within 5 points of each other.
    var steadyAcrossDay: Bool {
        guard parts.count >= 2, let b = best, let w = worst else { return true }
        return b.timeInRange - w.timeInRange < TodaySoFar.rangeStep
    }
}

// MARK: - Words

/// The card's words, shown and spoken. Values use the person's unit without the unit name, like the
/// rest of Insights.
enum WeekInReviewText {
    static let title = "Week in review"
    static let period = "Last 7 days"

    static var emptyLine: String {
        "Week in review shows here once GlucOS has readings on \(WeekInReview.minimumDays) of the last \(WeekInReview.weekDays) days."
    }

    /// The one-sentence answer at the top of the card.
    static func headline(_ w: WeekInReview) -> String {
        switch w.rangeChange {
        case .better: return "More time in range than last week."
        case .worse: return "Less time in range than last week."
        case .same: return "About the same time in range as last week."
        case nil: return "\(Format.percent(w.thisWeek.timeInRange)) in range over the last 7 days."
        }
    }

    static func lowsValue(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }

    static func rangeCaption(_ w: WeekInReview) -> String? {
        w.lastWeek.map { "Last week \(Format.percent($0.timeInRange))" }
    }

    static func meanCaption(_ w: WeekInReview, unit: GlucoseUnit) -> String? {
        w.lastWeek.map { "Last week \(unit.format(mgdl: $0.meanMgdl))" }
    }

    static func lowsCaption(_ w: WeekInReview) -> String? {
        w.lastWeek.map { $0.lows == 0 ? "None last week" : "Last week \($0.lows)" }
    }

    /// "mostly above range" or "mostly below range", for the hardest part of the day.
    static func lean(_ p: WeekInReview.PartFigures) -> String {
        p.below > p.above ? "mostly below range" : "mostly above range"
    }

    /// The best and hardest parts of the day, as lines under the figures.
    static func lines(_ w: WeekInReview) -> [String] {
        guard !w.parts.isEmpty else { return [] }
        if w.steadyAcrossDay {
            guard w.parts.count >= 2 else { return [] }
            return ["About the same at every time of day."]
        }
        guard let b = w.best, let h = w.worst else { return [] }
        return [
            "Best: \(b.part.name.lowercased()), \(Format.percent(b.timeInRange)) in range.",
            "Hardest: \(h.part.name.lowercased()), \(Format.percent(h.timeInRange)) in range, \(lean(h)).",
        ]
    }

    /// The line under the figures: what this week is compared with, or why it isn't yet.
    static func footnote(_ w: WeekInReview) -> String {
        if w.lastWeek != nil {
            return "The last 7 days against the 7 before them. Observations, not advice."
        }
        return "Last week joins in once GlucOS has readings on \(WeekInReview.minimumDays) of its \(WeekInReview.weekDays) days."
    }

    /// The whole card for VoiceOver, in a few sentences.
    static func spoken(_ w: WeekInReview, unit: GlucoseUnit) -> String {
        var parts = ["Week in review, the last 7 days", String(headline(w).dropLast())]
        let percent = { (v: Double) in "\(Int((v * 100).rounded())) percent" }
        let t = w.thisWeek
        if let l = w.lastWeek {
            parts.append("\(percent(t.timeInRange)) in range, last week \(percent(l.timeInRange))")
            parts.append("Average \(unit.format(mgdl: t.meanMgdl)) \(unit.label), last week \(unit.format(mgdl: l.meanMgdl))")
        } else {
            parts.append("\(percent(t.timeInRange)) in range")
            parts.append("Average \(unit.format(mgdl: t.meanMgdl)) \(unit.label)")
        }
        var lowLine = t.lows == 0 ? "No lows" : (t.lows == 1 ? "1 low" : "\(t.lows) lows")
        if let l = w.lastWeek {
            lowLine += l.lows == 0 ? ", none last week" : (l.lows == 1 ? ", 1 last week" : ", \(l.lows) last week")
        }
        parts.append(lowLine)
        if !w.steadyAcrossDay, let b = w.best, let h = w.worst {
            parts.append("Best \(b.part.name.lowercased()), \(b.part.hours), \(percent(b.timeInRange)) in range")
            parts.append("Hardest \(h.part.name.lowercased()), \(h.part.hours), \(percent(h.timeInRange)) in range, \(lean(h))")
        } else if w.parts.count >= 2 {
            parts.append("About the same at every time of day")
        }
        if w.lastWeek == nil { parts.append(String(footnote(w).dropLast())) }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill or a change of target.
@MainActor
final class WeekInReviewCache {
    static let shared = WeekInReviewCache()

    struct Key: Hashable {
        /// The newest reading, rounded down to 15 minutes.
        var newest: Date?
        var count15: Int
        var low: Double
        var high: Double
    }

    private var stored: (key: Key, value: WeekInReview?)?

    nonisolated static func key(readings: [GlucoseReading], low: Double, high: Double) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count15: readings.count / 15, low: low, high: high)
    }

    func cached(_ key: Key) -> WeekInReview?? {
        guard let s = stored, s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading]) async -> WeekInReview? {
        if let hit = cached(key) { return hit }
        let low = key.low, high = key.high
        let v = await Task.detached(priority: .utility) {
            WeekInReview.compute(readings: readings, low: low, high: high)
        }.value
        stored = (key, v)
        return v
    }
}
