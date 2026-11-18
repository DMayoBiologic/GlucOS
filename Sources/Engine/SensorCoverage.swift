import Foundation

// Insights "Sensor coverage" (docs/SensorCoverage.md): over the last 7, 14 or 30 days, how much of
// the time GlucOS has readings for, and the longest stretches it doesn't, each with its reason from
// the gaps on the chart (`ReadingGaps`, docs/ReadingGaps.md).
//
// Method:
// 1. A gap is what the chart marks: readings 10 minutes or more apart, except LibreLinkUp's 15-minute
//    history fill (`ReadingGaps.isGap`). Everything else counts as covered, so a stretch filled at
//    one reading every 15 minutes while the app slept is covered, as the chart draws it.
// 2. The period is the `days` up to the newest reading, as for Lows, Highs and Overnight. Where the
//    stored readings start inside the period (a new install), it starts at the first reading
//    instead, so time before GlucOS kept anything isn't counted as missing.
// 3. A gap that crosses the period's start counts only from the start.
// 4. Coverage is the share of the period not inside a gap. The card needs a day of period.
// 5. Each gap's reason is the chart's: warm-up and sensor ended from the current sensor, no signal
//    or asleep from the record of checks (48 hours), otherwise "No readings".
// 6. The card stays out of Insights while coverage is `hiddenFrom` (99%) or more: nothing to say.
//
// Observational only: it says where readings are missing and never suggests a change to insulin,
// food or any setting. Plain Foundation, so it's unit-tested.

struct SensorCoverage: Hashable, Sendable {
    /// The same 7, 14 and 30 days as the Lows and Highs cards.
    typealias Period = LowsSummary.Period
    typealias Gap = ReadingGaps.Gap
    typealias Reason = ReadingGaps.Reason

    /// At this share covered or more, the card stays off the Insights screen.
    static let hiddenFrom = 0.99
    /// The card says nothing over less than this much period.
    static let minimumSpan: TimeInterval = 86_400
    /// How many of the longest gaps the card lists.
    static let longestShown = 3
    /// The Logbook a gap opens takes in this much either side of it.
    static let linkMargin: TimeInterval = 60 * 60

    let period: Period
    /// Where the counted stretch starts: the period's start, or the first stored reading after it.
    let start: Date
    /// The newest reading.
    let end: Date
    /// The gaps that reach into the stretch, oldest first.
    let gaps: [Gap]
    /// Seconds of the stretch inside a gap.
    let missing: TimeInterval

    var span: TimeInterval { end.timeIntervalSince(start) }
    /// The share of the stretch with readings, 0...1.
    var coverage: Double { span > 0 ? max(0, min(1, 1 - missing / span)) : 1 }
    /// Whether the stored readings started inside the period (by more than an hour).
    var isPartial: Bool { span < Double(period.days) * 86_400 - 3_600 }
    /// Whether the card shows on the Insights screen.
    var shows: Bool { coverage < Self.hiddenFrom }

    /// The longest gaps, longest first (ties: newest first).
    var longest: [Gap] {
        Array(gaps.sorted { a, b in
            counted(a) != counted(b) ? counted(a) > counted(b) : a.start > b.start
        }.prefix(Self.longestShown))
    }

    /// A gap's seconds inside the stretch.
    func counted(_ gap: Gap) -> TimeInterval {
        max(0, gap.end.timeIntervalSince(max(gap.start, start)))
    }

    /// Missing time by reason, most first. Reasons that tie keep the order they first appeared.
    var byReason: [(reason: Reason, seconds: TimeInterval)] {
        var order: [Reason] = []
        var sums: [Reason: TimeInterval] = [:]
        for g in gaps {
            if sums[g.reason] == nil { order.append(g.reason) }
            sums[g.reason, default: 0] += counted(g)
        }
        return order.enumerated()
            .sorted { a, b in
                let x = sums[a.element]!, y = sums[b.element]!
                return x != y ? x > y : a.offset < b.offset
            }
            .map { ($0.element, sums[$0.element]!) }
    }

    // MARK: Compute

    /// `readings` oldest → newest. Nil without a day of readings to count over.
    static func compute(readings: [GlucoseReading], context: ReadingGaps.Context,
                        period: Period) -> SensorCoverage? {
        let valid = readings.filter { $0.mgdl > 0 }
        guard let first = valid.first, let newest = valid.last else { return nil }
        let end = newest.timestamp
        let periodStart = end.addingTimeInterval(-Double(period.days) * 86_400)
        let start = max(periodStart, first.timestamp)
        guard end.timeIntervalSince(start) >= minimumSpan else { return nil }

        // From the last reading at or before the start, so a gap crossing it is found.
        let from = valid.lastIndex { $0.timestamp <= start } ?? 0
        let gaps = ReadingGaps.find(in: Array(valid[from...]), context: context)
            .filter { $0.end > start }
        let missing = gaps.reduce(0) { $0 + max(0, $1.end.timeIntervalSince(max($1.start, start))) }
        return SensorCoverage(period: period, start: start, end: end, gaps: gaps, missing: missing)
    }

    /// The Logbook around a gap: an hour either side of it, so what was logged as it began and
    /// ended shows (`LogbookFilter.aroundGap`).
    static func link(for gap: Gap, now: Date, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> LogbookLink {
        let when = ClockLabel.dayTime(gap.start, now: now, calendar: calendar, locale: locale)
        return LogbookLink(filter: .aroundGap,
                           period: .init(label: "Around \(when)", phrase: "around the gap at \(when)",
                                         interval: DateInterval(start: gap.start.addingTimeInterval(-linkMargin),
                                                                end: gap.end.addingTimeInterval(linkMargin))))
    }
}

// MARK: - Compare

extension InsightsCompare {
    /// The period before for the Sensor coverage card: the same length, ending within a day of
    /// where this one starts, and with stored readings over 4 of every 7 of its days (time GlucOS
    /// wasn't keeping readings yet isn't a gap to compare with).
    static func previousCoverage(readings: [GlucoseReading], context: ReadingGaps.Context,
                                 current: SensorCoverage) -> SensorCoverage? {
        guard !current.isPartial else { return nil }
        let length = Double(current.period.days) * 86_400
        let slice = previousSlice(readings, end: current.end, seconds: length)
        // The reading before the slice too, so a gap reaching into it counts.
        let anchor = readings.last { $0.mgdl > 0 && $0.timestamp <= current.end.addingTimeInterval(-2 * length) }
        guard let prev = SensorCoverage.compute(readings: (anchor.map { [$0] } ?? []) + slice,
                                                context: context, period: current.period),
              isAligned(previousEnd: prev.end, currentEnd: current.end, seconds: length),
              prev.span * 7 >= length * 4 else { return nil }
        return prev
    }

    /// Coverage against the period before: more is better.
    static func coverage(_ s: SensorCoverage, _ previous: SensorCoverage?) -> InsightsDelta? {
        previous.map { InsightsDelta.timeInRange(s.coverage, $0.coverage) }
    }

    /// Gaps against the period before: fewer is better.
    static func coverageGaps(_ s: SensorCoverage, _ previous: SensorCoverage?) -> InsightsDelta? {
        previous.map { InsightsDelta.count(s.gaps.count, $0.gaps.count) }
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum SensorCoverageText {
    static let title = "Sensor coverage"
    static let systemImage = "dot.radiowaves.left.and.right"

    /// The row at the foot of the card that opens the Logbook around the longest gap.
    static let logbookLine = "See the longest gap in the Logbook"
    static let logbookHint = "Opens the Logbook on what was logged around the longest gap in readings"

    static func emptyLine(_ period: SensorCoverage.Period) -> String {
        "Coverage over \(period.spoken) shows here once GlucOS has a day of readings."
    }

    static func percent(_ share: Double) -> String {
        // Never says 100% while anything is missing.
        let p = Int((share * 100).rounded())
        return p == 100 && share < 1 ? "99%" : HighsSummaryText.percent(share)
    }

    static func gaps(_ n: Int) -> String { n == 1 ? "1 gap" : "\(n) gaps" }

    /// "Readings for 96% of the last 14 days." or "Readings for 96% of the 5 days stored so far."
    static func headline(_ s: SensorCoverage) -> String {
        "Readings for \(percent(s.coverage)) of \(stretch(s))."
    }

    /// "the last 14 days", or "the 5 days stored so far" when the readings start inside the period.
    static func stretch(_ s: SensorCoverage) -> String {
        guard s.isPartial else { return s.period.spoken }
        let days = max(1, Int((s.span / 86_400).rounded()))
        return days == 1 ? "the day stored so far" : "the \(days) days stored so far"
    }

    /// The Missing tile: "3 hr 20 min", or "None".
    static func missingValue(_ s: SensorCoverage) -> String {
        s.missing < 60 ? "None" : ReadingGaps.length(s.missing)
    }

    /// One row of the longest gaps: "Yesterday 2:10 am · 3 hr 5 min".
    static func row(_ gap: SensorCoverage.Gap, in s: SensorCoverage, now: Date,
                    calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        "\(ClockLabel.dayTime(max(gap.start, s.start), now: now, calendar: calendar, locale: locale)) · "
            + ReadingGaps.length(s.counted(gap))
    }

    /// "Most of the missing time: Mac was asleep (6 hr)." Nil without gaps, or when most of it has
    /// no known reason.
    static func reasonLine(_ s: SensorCoverage) -> String? {
        guard let top = s.byReason.first, top.reason != .unknown, top.seconds > 0 else { return nil }
        return "Most of the missing time: \(top.reason.title) (\(ReadingGaps.length(top.seconds)))."
    }

    static let noGapsLine = "No gaps of 10 minutes or more."

    static func footnote(_ s: SensorCoverage) -> String {
        "A gap is 10 minutes or more without a reading; LibreLinkUp's 15-minute history counts as readings. "
            + "Reasons are known for the last 2 days and the current sensor. Observations, not advice."
    }

    /// The whole card for VoiceOver, in a few sentences.
    static func spoken(_ s: SensorCoverage, now: Date, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["Sensor coverage, \(stretch(s))"]
        parts.append("Readings for \(HighsSummaryText.spokenPercent(min(s.coverage, s.missing > 0 ? 0.99 : 1))) of the time")
        if s.gaps.isEmpty {
            parts.append("No gaps")
        } else {
            parts.append("\(gaps(s.gaps.count)), \(ReadingGaps.length(s.missing)) missing")
            if let g = s.longest.first {
                let when = ClockLabel.dayTime(max(g.start, s.start), now: now, calendar: calendar, locale: locale)
                parts.append("The longest, \(ReadingGaps.length(s.counted(g))) from \(when): \(g.reason.title)")
            }
            if let line = reasonLine(s) { parts.append(String(line.dropLast())) }
        }
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last result for each period, so the card and the screen's "does it show" check work it
/// out once per data change rather than on every redraw. The key moves with each 15 minutes of new
/// readings, a backfill, a new sensor, or a new period or step.
@MainActor
final class SensorCoverageCache {
    static let shared = SensorCoverageCache()

    struct Key: Hashable {
        var newest: Date?
        var count: Int
        var sensor: Date?
        var period: SensorCoverage.Period
        var back: Int
    }

    private var stored: [Key: SensorCoverage?] = [:]

    nonisolated static func key(readings: [GlucoseReading], context: ReadingGaps.Context,
                                period: SensorCoverage.Period, back: Int) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count: readings.count / 15, sensor: context.sensor?.activated,
                   period: period, back: back)
    }

    func cached(_ key: Key) -> SensorCoverage?? {
        guard let hit = stored[key] else { return nil }
        return .some(hit)
    }

    /// Worked out here and now: the screen's check whether the card shows. Cheap (one pass), and
    /// once per key.
    func valueNow(for key: Key, readings: [GlucoseReading], context: ReadingGaps.Context) -> SensorCoverage? {
        if let hit = cached(key) { return hit }
        let shown = InsightsPeriodStep.readings(readings, days: key.period.days, back: key.back)
        let v = SensorCoverage.compute(readings: shown, context: context, period: key.period)
        remember(key, v)
        return v
    }

    /// Off the main thread, for the card itself.
    func value(for key: Key, readings: [GlucoseReading], context: ReadingGaps.Context) async -> SensorCoverage? {
        if let hit = cached(key) { return hit }
        let period = key.period, back = key.back
        let v = await Task.detached(priority: .utility) {
            SensorCoverage.compute(readings: InsightsPeriodStep.readings(readings, days: period.days, back: back),
                                   context: context, period: period)
        }.value
        remember(key, v)
        return v
    }

    /// Whether the card shows on the Insights screen for the picked period (read from
    /// `InsightsShare.Key.coverage`) and step.
    func shows(readings: [GlucoseReading], context: ReadingGaps.Context, back: Int,
               defaults: UserDefaults = .standard) -> Bool {
        let period = SensorCoverage.Period(rawValue: defaults.integer(forKey: InsightsShare.Key.coverage)) ?? .fortnight
        let key = Self.key(readings: readings, context: context, period: period, back: back)
        return valueNow(for: key, readings: readings, context: context)?.shows ?? false
    }

    private func remember(_ key: Key, _ value: SensorCoverage?) {
        // A handful of keys at most: the three periods, a step or two back.
        if stored.count > 12 { stored.removeAll() }
        stored[key] = value
    }
}
