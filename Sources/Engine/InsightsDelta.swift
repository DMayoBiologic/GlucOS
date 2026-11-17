import Foundation

// Insights "Compare to previous period": an optional switch on iPhone and Mac Insights. When it's
// on, the cards with a period (At a glance, Lows, Highs, Overnight, Weekdays and weekends) put a
// small up or down figure beside their headline numbers: the change from the period of the same
// length just before.
//
// Method:
// 1. The previous period is the same card worked out again on the readings from 2 periods back to
//    1 period back from the card's own end (`previousSlice`). Its newest reading has to sit within
//    a day of where the current period starts (`maximumDriftDays`), so a gap in the sensor can't
//    pull in an older stretch.
// 2. It needs readings on 4 of every 7 of its days, as Week in review asks of last week
//    (`hasEnough`). Short of that the card shows nothing extra, rather than comparing with a scrap.
// 3. Shares (time in range, time above) change in points and are "the same" when they round to the
//    same whole percent. Counts (lows, highs) are the same when equal. The average is the same within
//    the step it's written in (0.1 mmol/L or 1 mg/dL).
// 4. Colour says better or worse: more time in range, less time above, fewer lows and fewer highs
//    are better. The average is better when it moved closer to the middle of the target range and
//    worse when it moved away; within one step of that it stays uncoloured.
//
// Week in review isn't touched: it already sets this week against last week (`WeekInReview`).
//
// Observational only: it says how a figure moved and never suggests a change to insulin, food or
// any setting. Plain Foundation, so the maths is unit-tested. The views work the previous period
// out off the main thread once per data change, and only while the switch is on.

struct InsightsDelta: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A share of time, 0...1, shown in points.
        case share(higherIsBetter: Bool)
        /// A whole count (lows, highs). Fewer is better.
        case count
        /// An average in mg/dL, written in `unit`; better when closer to `targetMidMgdl`.
        case average(unit: GlucoseUnit, targetMidMgdl: Double)
    }

    enum Direction: Hashable, Sendable { case up, down, same }
    enum Verdict: Hashable, Sendable { case better, worse, neutral }

    let kind: Kind
    let current: Double
    let previous: Double

    /// Current less previous, in the figure's own units (a share, a count, mg/dL).
    var change: Double { current - previous }

    /// The step under which a change reads as no change, in the figure's own units.
    var sameWithin: Double {
        switch kind {
        case .share: return 0.005
        case .count: return 0.5
        case .average(let unit, _): return unit == .mmol ? 0.05 * GlucoseUnit.mgdlPerMmol : 0.5
        }
    }

    var direction: Direction {
        let d = change
        guard abs(d) >= sameWithin else { return .same }
        return d > 0 ? .up : .down
    }

    var verdict: Verdict {
        switch kind {
        case .share(let higherIsBetter):
            switch direction {
            case .same: return .neutral
            case .up: return higherIsBetter ? .better : .worse
            case .down: return higherIsBetter ? .worse : .better
            }
        case .count:
            switch direction {
            case .same: return .neutral
            case .up: return .worse
            case .down: return .better
            }
        case .average(_, let mid):
            // Moved closer to (or further from) the middle of the range by more than one step.
            let closer = abs(previous - mid) - abs(current - mid)
            guard direction != .same, abs(closer) >= sameWithin * 2 else { return .neutral }
            return closer > 0 ? .better : .worse
        }
    }

    // MARK: Words

    /// The size of the change without its sign: "4 pts", "2", "0.4".
    var magnitude: String {
        switch kind {
        case .share: return "\(points) pts"
        case .count: return "\(Int(abs(change).rounded()))"
        case .average(let unit, _): return unit.format(mgdl: abs(change))
        }
    }

    /// The change in whole points, without its sign.
    var points: Int { Int((abs(change) * 100).rounded()) }

    /// What the badge shows: "4 pts", "2", "0.4", or "Same".
    var badge: String { direction == .same ? "Same" : magnitude }

    /// For VoiceOver: "Time in range up 4 points on the previous 14 days, better." or "Lows the same
    /// as the previous 7 days."
    func spoken(label: String, previous phrase: String) -> String {
        let size: String
        switch kind {
        case .share: size = points == 1 ? "1 point" : "\(points) points"
        case .count: size = "\(Int(abs(change).rounded()))"
        case .average(let unit, _): size = unit.format(mgdl: abs(change), withUnit: true)
        }
        let head: String
        switch direction {
        case .same: return "\(label) the same as \(phrase)."
        case .up: head = "\(label) up \(size) on \(phrase)"
        case .down: head = "\(label) down \(size) on \(phrase)"
        }
        switch verdict {
        case .better: return head + ", better."
        case .worse: return head + ", worse."
        case .neutral: return head + "."
        }
    }

    // MARK: Builders

    static func timeInRange(_ current: Double, _ previous: Double) -> InsightsDelta {
        InsightsDelta(kind: .share(higherIsBetter: true), current: current, previous: previous)
    }

    static func timeAbove(_ current: Double, _ previous: Double) -> InsightsDelta {
        InsightsDelta(kind: .share(higherIsBetter: false), current: current, previous: previous)
    }

    static func count(_ current: Int, _ previous: Int) -> InsightsDelta {
        InsightsDelta(kind: .count, current: Double(current), previous: Double(previous))
    }

    static func average(_ current: Double, _ previous: Double, unit: GlucoseUnit,
                        low: Double, high: Double) -> InsightsDelta {
        InsightsDelta(kind: .average(unit: unit, targetMidMgdl: (low + high) / 2),
                      current: current, previous: previous)
    }
}

// MARK: - The previous period

enum InsightsCompare {
    /// The AppStorage key for the switch, shared by iPhone and Mac Insights.
    static let storageKey = "insights.comparePrevious"
    static let toggleTitle = "Compare to previous period"
    static let toggleHint = "Shows how each card's figures changed from the period of the same length before it"

    /// The previous period's newest reading may sit this far before the current period's start.
    static let maximumDriftDays = 1.0

    /// "the previous 14 days", "the previous 24 hours".
    static func previousPhrase(days: Int) -> String {
        days == 1 ? "the previous 24 hours" : "the previous \(days) days"
    }

    static func previousPhrase(hours: Double) -> String {
        hours <= 24 ? "the previous 24 hours" : previousPhrase(days: Int((hours / 24).rounded()))
    }

    /// Readings after `end − 2 × length` and at or before `end − length`.
    static func previousSlice(_ readings: [GlucoseReading], end: Date, seconds length: TimeInterval) -> [GlucoseReading] {
        let to = end.addingTimeInterval(-length)
        let from = to.addingTimeInterval(-length)
        return readings.filter { $0.timestamp > from && $0.timestamp <= to }
    }

    /// Whether a previous period with `covered` usable days of `expected` is enough to compare
    /// with: 4 of every 7, rounded up.
    static func hasEnough(covered: Int, of expected: Int) -> Bool {
        guard expected > 0 else { return false }
        return covered * 7 >= expected * 4
    }

    /// Whether the previous period ended close enough to where the current one starts.
    static func isAligned(previousEnd: Date, currentEnd: Date, seconds length: TimeInterval) -> Bool {
        let start = currentEnd.addingTimeInterval(-length)
        return previousEnd <= start && start.timeIntervalSince(previousEnd) <= maximumDriftDays * 86_400
    }

    // MARK: Per card

    static func previousLows(readings: [GlucoseReading], meals: [MealEntry], contexts: [ContextEvent],
                             answers: [LowAnswer], low: Double, current: LowsSummary,
                             calendar: Calendar = .autoupdatingCurrent) -> LowsSummary? {
        let length = Double(current.period.days) * 86_400
        let slice = previousSlice(readings, end: current.end, seconds: length)
        guard let prev = LowsSummary.compute(readings: slice, meals: meals, contexts: contexts, answers: answers,
                                             low: low, period: current.period, calendar: calendar),
              isAligned(previousEnd: prev.end, currentEnd: current.end, seconds: length),
              hasEnough(covered: prev.days, of: current.period.days) else { return nil }
        return prev
    }

    static func previousHighs(readings: [GlucoseReading], high: Double, current: HighsSummary,
                              calendar: Calendar = .autoupdatingCurrent) -> HighsSummary? {
        let length = Double(current.period.days) * 86_400
        let slice = previousSlice(readings, end: current.end, seconds: length)
        guard let prev = HighsSummary.compute(readings: slice, high: high, period: current.period, calendar: calendar),
              isAligned(previousEnd: prev.end, currentEnd: current.end, seconds: length),
              hasEnough(covered: prev.days, of: current.period.days) else { return nil }
        return prev
    }

    static func previousOvernight(readings: [GlucoseReading], low: Double, high: Double, current: OvernightSummary,
                                  calendar: Calendar = .autoupdatingCurrent) -> OvernightSummary? {
        let length = Double(current.period.days) * 86_400
        let slice = previousSlice(readings, end: current.end, seconds: length)
        guard let prev = OvernightSummary.compute(readings: slice, low: low, high: high, period: current.period,
                                                  calendar: calendar),
              isAligned(previousEnd: prev.end, currentEnd: current.end, seconds: length),
              hasEnough(covered: prev.count, of: current.period.days) else { return nil }
        return prev
    }

    static func previousWeekPart(readings: [GlucoseReading], low: Double, high: Double, current: WeekdayWeekend,
                                 calendar: Calendar = .autoupdatingCurrent) -> WeekdayWeekend? {
        let length = Double(current.period.days) * 86_400
        let slice = previousSlice(readings, end: current.end, seconds: length)
        guard let prev = WeekdayWeekend.compute(readings: slice, low: low, high: high, period: current.period,
                                                calendar: calendar),
              isAligned(previousEnd: prev.end, currentEnd: current.end, seconds: length) else { return nil }
        return prev
    }

    /// At a glance's previous window: the `hours` before the `hours` up to `now`. It needs readings
    /// spanning 4 of every 7 of its hours, at two or more an hour on average.
    static func previousGlance(readings: [GlucoseReading], hours: Double, now: Date,
                               low: Double, high: Double) -> GlucoseStats? {
        let slice = previousSlice(readings, end: now, seconds: hours * 3600).filter { $0.mgdl > 0 }
        guard let stats = GlucoseStats.compute(slice, low: low, high: high),
              stats.spanHours * 7 >= hours * 4,
              Double(stats.count) >= hours * 4 / 7 * 2 else { return nil }
        return stats
    }

    // MARK: Deltas per card

    /// Lows: the count.
    static func lows(_ current: LowsSummary, _ previous: LowsSummary?) -> InsightsDelta? {
        previous.map { .count(current.count, $0.count) }
    }

    /// Highs: time above and the count.
    static func timeAbove(_ current: HighsSummary, _ previous: HighsSummary?) -> InsightsDelta? {
        previous.map { .timeAbove(current.timeAbove, $0.timeAbove) }
    }

    static func highs(_ current: HighsSummary, _ previous: HighsSummary?) -> InsightsDelta? {
        previous.map { .count(current.count, $0.count) }
    }

    /// Overnight: time in range and lows.
    static func overnightRange(_ current: OvernightSummary, _ previous: OvernightSummary?) -> InsightsDelta? {
        previous.map { .timeInRange(current.timeInRange, $0.timeInRange) }
    }

    static func overnightLows(_ current: OvernightSummary, _ previous: OvernightSummary?) -> InsightsDelta? {
        previous.map { .count(current.lows, $0.lows) }
    }

    /// One side of Weekdays and weekends: its time in range, when that side had enough days before.
    static func weekPartRange(_ side: WeekdayWeekend.Side, _ current: WeekdayWeekend,
                              _ previous: WeekdayWeekend?) -> InsightsDelta? {
        guard let previous else { return nil }
        let now = current.stats(side), before = previous.stats(side)
        guard hasEnough(covered: before.days, of: now.days) else { return nil }
        return .timeInRange(now.timeInRange, before.timeInRange)
    }

    /// At a glance: time in range and the average.
    static func glanceRange(_ current: GlucoseStats, _ previous: GlucoseStats?) -> InsightsDelta? {
        previous.map { .timeInRange(current.timeInRange, $0.timeInRange) }
    }

    static func glanceAverage(_ current: GlucoseStats, _ previous: GlucoseStats?, unit: GlucoseUnit,
                              low: Double, high: Double) -> InsightsDelta? {
        previous.map { .average(current.meanMgdl, $0.meanMgdl, unit: unit, low: low, high: high) }
    }

    /// The spoken lines for a card's deltas, nil ones left out, joined into one string (nil when
    /// there are none).
    static func spoken(_ items: [(label: String, delta: InsightsDelta?)], previous phrase: String) -> String? {
        let lines = items.compactMap { item in item.delta?.spoken(label: item.label, previous: phrase) }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
