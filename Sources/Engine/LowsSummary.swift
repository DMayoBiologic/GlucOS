import Foundation

// Insights "Lows": the lows over the last 7, 14 or 30 days, how long they usually lasted, whether
// they were treated, and the time of day they tend to start.
//
// Method:
// 1. Readings are averaged into 5-minute buckets, and a low is a run below the low line lasting
//    15 minutes or more, a gap of over 30 minutes ending one (`TodaySoFar.lowSpans`, the same rule
//    as Week in review and the dashboard Days, so the 7-day count matches Week in review's).
// 2. The period is the `days` up to the newest reading. It needs one day's worth of 15-minute
//    slots with readings before the card says anything.
// 3. A low's length runs from its first low bucket to the first bucket back at or above the line.
//    The typical length is the median.
// 4. Treated: food or a hypo treatment tag logged from 20 minutes before the low to 10 minutes
//    after it (`LowTreatmentCheck.isTreated`, the "Did you treat this low?" rule). Otherwise a
//    "No" to that question (`LowAnswer.notTreated`) reads as "came up by itself", and anything
//    else (dismissed, never asked, before the question shipped) as "nothing logged".
// 5. Time of day is the local hour the low started, in the four parts Week in review uses. With
//    3 lows or more, a part that holds at least half of them, and more than any other, is where
//    they cluster; otherwise they're spread out.
//
// Observational only: it counts what happened and never suggests a change to insulin, food or
// settings. Plain Foundation, so it's unit-tested. Worked out off the main thread once per data
// change (`LowsSummaryCache`).

struct LowsSummary: Hashable {
    enum Period: Int, CaseIterable, Identifiable, Hashable {
        case week = 7
        case fortnight = 14
        case month = 30

        var id: Int { rawValue }
        var days: Int { rawValue }
        /// "7 days", the picker's label.
        var label: String { "\(rawValue) days" }
        /// "the last 7 days".
        var spoken: String { "the last \(rawValue) days" }
    }

    enum Status: Hashable {
        /// Food or a hypo treatment was logged around it.
        case treated
        /// The user said it came back up by itself.
        case notTreated
        /// Nothing logged and no answer.
        case unknown
    }

    struct Low: Hashable {
        let start: Date
        let end: Date
        let status: Status
        let part: WeekInReview.Part

        var minutes: Double { end.timeIntervalSince(start) / 60 }
    }

    let period: Period
    /// The newest reading: the period runs the `period.days` up to it.
    let end: Date
    /// Oldest first.
    let lows: [Low]
    /// Days (24-hour stretches) of the period with readings in half their 15-minute slots.
    let days: Int

    static let bucketMinutes = TodaySoFar.bucketMinutes
    static let coverageMinutes = 15
    /// The period needs this many 15-minute slots with readings: a day's worth.
    static let minimumSlots = 96
    static let minimumDayCoverage = 0.5
    /// Lows needed before saying where in the day they cluster.
    static let minimumForCluster = 3

    var count: Int { lows.count }
    var treated: Int { lows.filter { $0.status == .treated }.count }
    var notTreated: Int { lows.filter { $0.status == .notTreated }.count }
    var unknown: Int { lows.filter { $0.status == .unknown }.count }

    /// The middle low's length in minutes, nil with no lows.
    var medianMinutes: Double? {
        lows.isEmpty ? nil : TodaySoFar.median(lows.map(\.minutes))
    }

    /// Lows starting in each part of the day, overnight first.
    var byPart: [Int] {
        WeekInReview.Part.allCases.map { p in lows.filter { $0.part == p }.count }
    }

    /// The part of the day most lows start in, when there are enough of them and one part holds at
    /// least half and more than any other.
    var cluster: WeekInReview.Part? {
        guard count >= Self.minimumForCluster else { return nil }
        let counts = byPart
        guard let top = counts.max(), let i = counts.firstIndex(of: top),
              Double(top) >= Double(count) / 2,
              counts.filter({ $0 == top }).count == 1 else { return nil }
        return WeekInReview.Part(rawValue: i)
    }

    // MARK: Compute

    static func compute(readings: [GlucoseReading], meals: [MealEntry], contexts: [ContextEvent],
                        answers: [LowAnswer], low: Double, period: Period,
                        calendar: Calendar = .autoupdatingCurrent) -> LowsSummary? {
        guard let newest = readings.last(where: { $0.mgdl > 0 }) else { return nil }
        let end = newest.timestamp
        let start = end.addingTimeInterval(-Double(period.days) * 86_400)

        let size = Double(bucketMinutes) * 60
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
        let slot = Double(coverageMinutes) * 60
        let slotsPerDay = Int(86_400 / slot)
        var filled: [Int: Set<Int>] = [:]
        for (t, _) in buckets {
            let s = max(0, Int((t.timeIntervalSince(start) / slot).rounded(.down)))
            filled[s / slotsPerDay, default: []].insert(s % slotsPerDay)
        }
        let slots = filled.values.reduce(0) { $0 + $1.count }
        guard slots >= minimumSlots else { return nil }
        let days = filled.values.filter { Double($0.count) >= minimumDayCoverage * Double(slotsPerDay) }.count

        let lows = TodaySoFar.lowSpans(buckets, low: low).map { span -> Low in
            let episode = LowEpisode(start: span.start, end: span.end, nadirAt: span.start, nadirMgdl: low)
            let status: Status
            if LowTreatmentCheck.isTreated(episode, meals: meals, contexts: contexts) {
                status = .treated
            } else if answers.contains(where: { $0.answer == .notTreated && $0.covers(episode) }) {
                status = .notTreated
            } else {
                status = .unknown
            }
            return Low(start: span.start, end: span.end, status: status,
                       part: WeekInReview.Part.of(hour: calendar.component(.hour, from: span.start)))
        }
        return LowsSummary(period: period, end: end, lows: lows, days: min(days, period.days))
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum LowsSummaryText {
    static let title = "Lows"

    /// The row at the foot of the card that opens the Logbook (`LogbookLink.lows`).
    static func logbookLine(_ period: LowsSummary.Period) -> String {
        "See the last \(period.days) days in the Logbook"
    }

    static let logbookHint = "Opens the Logbook on Lows over the same days"

    static func emptyLine(_ period: LowsSummary.Period) -> String {
        "Lows over \(period.spoken) show here once GlucOS has a day of readings."
    }

    /// What the card's sparkline shows (`InsightsSparkline.lows`).
    static let sparklineLabel = "Lows each day"

    static func countValue(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }

    static func lows(_ n: Int) -> String { n == 1 ? "1 low" : "\(n) lows" }

    /// "25 min", "1 h 10 min".
    static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        guard m >= 60 else { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func spokenDuration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        let mins = { (n: Int) in n == 1 ? "1 minute" : "\(n) minutes" }
        guard m >= 60 else { return mins(m) }
        let h = m / 60 == 1 ? "1 hour" : "\(m / 60) hours"
        return m % 60 == 0 ? h : "\(h) \(mins(m % 60))"
    }

    static func headline(_ s: LowsSummary) -> String {
        s.count == 0 ? "No lows in \(s.period.spoken)." : "\(lows(s.count)) in \(s.period.spoken)."
    }

    /// "2 of 3": treated out of all.
    static func treatedValue(_ treated: Int, of count: Int) -> String { "\(treated) of \(count)" }

    /// Under the Treated figure: what the rest were.
    static func treatedCaption(_ s: LowsSummary) -> String? {
        var bits: [String] = []
        if s.notTreated > 0 { bits.append("\(s.notTreated) came up by itself") }
        if s.unknown > 0 { bits.append("\(s.unknown) not logged") }
        return bits.isEmpty ? nil : bits.joined(separator: ", ")
    }

    /// Short labels for the four time-of-day columns.
    static func partLabel(_ p: WeekInReview.Part) -> String {
        switch p {
        case .overnight: return "Night"
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        }
    }

    /// Where in the day they start, or nil with too few to say.
    static func clusterLine(_ s: LowsSummary) -> String? {
        guard s.count >= LowsSummary.minimumForCluster else { return nil }
        guard let p = s.cluster else { return "Spread across the day." }
        let n = s.byPart[p.rawValue]
        return "\(n) of \(s.count) started \(p == .overnight ? "overnight" : "in the \(partLabel(p).lowercased())"), \(p.hours)."
    }

    static func footnote(_ s: LowsSummary, lowLine: String) -> String {
        var t = "A low is 15 minutes or more below \(lowLine). Treated means food or a hypo treatment was logged around it."
        if s.days < s.period.days {
            t += " Based on \(s.days == 1 ? "1 day" : "\(s.days) days") with readings."
        }
        return t + " Observations, not advice."
    }

    /// The whole card for VoiceOver, in a few sentences.
    static func spoken(_ s: LowsSummary, lowLine: String) -> String {
        var parts = ["Lows below \(lowLine), \(s.period.spoken)"]
        guard s.count > 0, let median = s.medianMinutes else {
            parts.append("No lows")
            return parts.joined(separator: ". ") + "."
        }
        parts.append(lows(s.count))
        parts.append("Typical length \(spokenDuration(median))")
        var treated = "\(s.treated) of \(s.count) treated"
        if s.notTreated > 0 { treated += ", \(s.notTreated) came up by itself" }
        if s.unknown > 0 { treated += ", \(s.unknown) with nothing logged" }
        parts.append(treated)
        if let line = clusterLine(s) { parts.append(String(line.dropLast())) }
        if s.days < s.period.days { parts.append("Based on \(s.days == 1 ? "1 day" : "\(s.days) days") with readings") }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill, a new log entry or
/// answer, a change of low line, or a new period.
@MainActor
final class LowsSummaryCache {
    static let shared = LowsSummaryCache()

    struct Key: Hashable {
        var newest: Date?
        var count15: Int
        var low: Double
        var period: LowsSummary.Period
        /// The log entries that can mark a low treated, hashed.
        var logs: Int
    }

    private var stored: (key: Key, value: LowsSummary?)?

    nonisolated static func key(readings: [GlucoseReading], meals: [MealEntry], contexts: [ContextEvent],
                                answers: [LowAnswer], low: Double, period: LowsSummary.Period) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        var h = Hasher()
        for m in meals { h.combine(m.timestamp) }
        for c in contexts where c.tags.contains(.hypoTreatment) { h.combine(c.timestamp) }
        for a in answers { h.combine(a.id); h.combine(a.answer) }
        return Key(newest: newest, count15: readings.count / 15, low: low, period: period, logs: h.finalize())
    }

    func cached(_ key: Key) -> LowsSummary?? {
        guard let s = stored, s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading], meals: [MealEntry], contexts: [ContextEvent],
               answers: [LowAnswer]) async -> LowsSummary? {
        if let hit = cached(key) { return hit }
        let low = key.low, period = key.period
        let v = await Task.detached(priority: .utility) {
            LowsSummary.compute(readings: readings, meals: meals, contexts: contexts, answers: answers,
                                low: low, period: period)
        }.value
        stored = (key, v)
        return v
    }
}
