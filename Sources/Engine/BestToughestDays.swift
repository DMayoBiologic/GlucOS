import Foundation

// Insights "Best and toughest days": over the last 7, 14 or 30 days, the day with the most time in
// range and the day with the least, each drawn as a small day chart.
//
// Method:
// 1. The period is whole local days counted back from the latest reading. A day still under way
//    (today, while readings are coming in) is left out, since its share would change by tonight;
//    so the 7 days are yesterday and the 6 before it. When readings stop, the days count back from
//    the last day with a reading, and the card describes the period up to then.
// 2. Each day's time in range is the Logbook day bar's (`DayInRange.figures`): 5-minute buckets,
//    midnight to midnight, and readings in at least half of the day's 15-minute slots, so a day with
//    a long sensor gap never counts as a best or toughest day on a few good hours.
// 3. The best day has the largest share in range; on a tie, the one with less time below, then the
//    latest. The toughest is picked from the other days: the smallest share in range; on a tie, the
//    one with more time below, then the latest. The card needs 2 counted days.
// 4. When the two are within 5 points of each other, the card says the days were much alike rather
//    than calling one of them tough.
//
// Observational only: it describes what happened and never suggests a change to insulin, food or
// any setting. Plain Foundation, so it's unit-tested. Worked out off the main thread once per data
// change (`BestToughestDaysCache`).

struct BestToughestDays: Hashable {
    typealias Period = LowsSummary.Period

    /// Counted days before the card shows.
    static let minimumDays = 2
    /// Within this many points of each other, the two days read as much alike.
    static let alikeGap = 0.05

    enum Which: String, CaseIterable, Identifiable, Hashable {
        case best, toughest

        var id: String { rawValue }
        /// "Best day", "Toughest day".
        var title: String { self == .best ? "Best day" : "Toughest day" }
        var filter: LogbookFilter { self == .best ? .bestDay : .toughestDay }
    }

    struct Day: Hashable {
        /// Local midnight.
        let start: Date
        /// The next local midnight (23 or 25 hours on across a clock change).
        let end: Date
        let figures: DayInRange
        /// The day's trace for its chart (`DayChart.segments`).
        let segments: [[DayChartPoint]]

        var interval: DateInterval { DateInterval(start: start, end: end) }
    }

    let period: Period
    /// The newest reading.
    let end: Date
    let best: Day
    let toughest: Day
    /// Days in the period with enough readings to count.
    let countedDays: Int
    /// Whole days in the period: `period.days`.
    var periodDays: Int { period.days }

    func day(_ which: Which) -> Day { which == .best ? best : toughest }

    /// Points of time in range between the two days, 0...1.
    var gap: Double { best.figures.inRange - toughest.figures.inRange }
    var muchAlike: Bool { gap < Self.alikeGap }

    // MARK: Compute

    static func compute(readings: [GlucoseReading], low: Double, high: Double, period: Period,
                        now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> BestToughestDays? {
        let sorted = zip(readings, readings.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }
            ? readings : readings.sorted { $0.timestamp < $1.timestamp }
        guard let newest = sorted.last(where: { $0.mgdl > 0 }) else { return nil }
        let end = newest.timestamp

        // The last whole day: the newest reading's, unless that day is still under way.
        var last = calendar.startOfDay(for: end)
        if calendar.isDate(last, inSameDayAs: now) || last > now {
            guard let prev = calendar.date(byAdding: .day, value: -1, to: last) else { return nil }
            last = prev
        }

        var days: [Day] = []
        for i in 0..<period.days {
            guard let start = calendar.date(byAdding: .day, value: -i, to: last),
                  let next = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            guard let f = DayInRange.figures(sorted, from: start, to: next, low: low, high: high) else { continue }
            days.append(Day(start: start, end: next, figures: f, segments: []))
        }
        guard days.count >= minimumDays else { return nil }

        // Best: most in range, then less below, then latest.
        func better(_ a: Day, _ b: Day) -> Bool {
            if a.figures.inRange != b.figures.inRange { return a.figures.inRange > b.figures.inRange }
            if a.figures.below != b.figures.below { return a.figures.below < b.figures.below }
            return a.start > b.start
        }
        // Toughest: least in range, then more below, then latest.
        func tougher(_ a: Day, _ b: Day) -> Bool {
            if a.figures.inRange != b.figures.inRange { return a.figures.inRange < b.figures.inRange }
            if a.figures.below != b.figures.below { return a.figures.below > b.figures.below }
            return a.start > b.start
        }
        guard let best = days.min(by: better),
              let toughest = days.filter({ $0.start != best.start }).min(by: tougher) else { return nil }

        func charted(_ d: Day) -> Day {
            Day(start: d.start, end: d.end, figures: d.figures,
                segments: DayChart.segments(sorted, from: d.start, to: d.end))
        }
        return BestToughestDays(period: period, end: end, best: charted(best), toughest: charted(toughest),
                                countedDays: days.count)
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum BestToughestDaysText {
    static let title = "Best and toughest days"

    static func emptyLine(_ period: BestToughestDays.Period) -> String {
        "Best and toughest days show here once GlucOS has readings for \(BestToughestDays.minimumDays) full days in \(period.spoken)."
    }

    /// "96%".
    static func percent(_ share: Double) -> String { HighsSummaryText.percent(share) }

    /// "Yesterday", or "Tue 10 Nov".
    static func dayTitle(_ day: BestToughestDays.Day, now: Date, calendar: Calendar = .autoupdatingCurrent,
                         locale: Locale = .autoupdatingCurrent) -> String {
        ClockLabel.dayTitle(ClockLabel.day(of: day.start, now: now, calendar: calendar), calendar: calendar, locale: locale)
    }

    /// Under the figure: "4% below · 18% above", or "all in range". Shares under half a percent
    /// aren't named.
    static func caption(_ day: BestToughestDays.Day) -> String {
        var parts: [String] = []
        if day.figures.below >= 0.005 { parts.append("\(percent(day.figures.below)) below") }
        if day.figures.above >= 0.005 { parts.append("\(percent(day.figures.above)) above") }
        return parts.isEmpty ? "all in range" : parts.joined(separator: " · ")
    }

    /// The sentence under the two days.
    static func line(_ s: BestToughestDays) -> String {
        if s.muchAlike {
            let gapPoints = Int((BestToughestDays.alikeGap * 100).rounded())
            return "The best and toughest days were within \(gapPoints) points of each other in range, so the \(s.countedDays) days were much alike."
        }
        let points = Int((s.gap * 100).rounded())
        return "The best day had \(points) \(points == 1 ? "point" : "points") more time in range than the toughest."
    }

    /// Where the toughest day's time out of range went, when there's enough of it to say:
    /// "Most of the toughest day's time out of range was above 10.0 mmol/L."
    static func toughLine(_ s: BestToughestDays, lowLine: String, highLine: String) -> String? {
        guard !s.muchAlike else { return nil }
        let f = s.toughest.figures
        guard f.below + f.above >= 0.005 else { return nil }
        if f.above >= f.below {
            return "Most of the toughest day's time out of range was above \(highLine)."
        }
        return "Most of the toughest day's time out of range was below \(lowLine)."
    }

    /// "12 of the last 14 days had enough readings to count.", or nil when every day did.
    static func countedLine(_ s: BestToughestDays) -> String? {
        guard s.countedDays < s.periodDays else { return nil }
        return "\(s.countedDays) of \(s.period.spoken) had enough readings to count."
    }

    static func logbookHint(_ which: BestToughestDays.Which) -> String {
        which == .best ? "Opens the Logbook on the best day" : "Opens the Logbook on the toughest day"
    }

    static func footnote(rangeLine: String) -> String {
        "Time in range (\(rangeLine)) over whole days, midnight to midnight, with readings for at least half the day. Today joins once it's over. Observations, not advice."
    }

    /// The sentence a day reads in: "yesterday", "on Tue 10 Nov".
    static func phrase(_ day: BestToughestDays.Day, now: Date, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        switch ClockLabel.day(of: day.start, now: now, calendar: calendar) {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .other: return "on \(dayTitle(day, now: now, calendar: calendar, locale: locale))"
        }
    }

    /// VoiceOver for one day: "Best day. Tuesday 10 November, chart. 96% in range, 4% above. Lowest
    /// 4.2 mmol/L at 3:10 am, highest 10.8 mmol/L at 1:30 pm. Target 3.9 to 10.0. 3 entries logged."
    static func spoken(_ which: BestToughestDays.Which, _ s: BestToughestDays, unit: GlucoseUnit, low: Double,
                       high: Double, logged: Int, now: Date, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        let d = s.day(which)
        let day = ClockLabel.day(of: d.start, now: now, calendar: calendar)
        return "\(which.title). " + DayChartText.spoken(day: day, figures: d.figures, segments: d.segments, unit: unit,
                                                        low: low, high: high, logged: logged, calendar: calendar,
                                                        locale: locale)
    }
}

// MARK: - Logbook

extension LogbookLink {
    /// One day of the Best and toughest days card, on the Best day or Toughest day chip: everything
    /// logged that day, local midnight to midnight ("Tue 10 Nov").
    static func bestDay(_ which: BestToughestDays.Which, _ s: BestToughestDays, now: Date,
                        calendar: Calendar = .autoupdatingCurrent) -> LogbookLink {
        let d = s.day(which)
        return LogbookLink(filter: which.filter,
                           period: .init(label: BestToughestDaysText.dayTitle(d, now: now, calendar: calendar),
                                         phrase: BestToughestDaysText.phrase(d, now: now, calendar: calendar),
                                         interval: d.interval))
    }
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill, a change of either line
/// or the period, and the day turning over.
@MainActor
final class BestToughestDaysCache {
    static let shared = BestToughestDaysCache()

    struct Key: Hashable {
        var newest: Date?
        var count15: Int
        var low: Double
        var high: Double
        var period: BestToughestDays.Period
        var today: Date
    }

    private var stored: [Key: BestToughestDays?] = [:]

    nonisolated static func key(readings: [GlucoseReading], low: Double, high: Double,
                                period: BestToughestDays.Period, now: Date = Date(),
                                calendar: Calendar = .autoupdatingCurrent) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count15: readings.count / 15, low: low, high: high, period: period,
                   today: calendar.startOfDay(for: now))
    }

    func cached(_ key: Key) -> BestToughestDays?? {
        guard let hit = stored[key] else { return nil }
        return .some(hit)
    }

    func value(for key: Key, readings: [GlucoseReading]) async -> BestToughestDays? {
        if let hit = cached(key) { return hit }
        let low = key.low, high = key.high, period = key.period
        let v = await Task.detached(priority: .utility) {
            BestToughestDays.compute(readings: readings, low: low, high: high, period: period)
        }.value
        // One entry per period for the same readings, so flipping the picker back and forth doesn't
        // work it out again; anything older goes.
        stored = stored.filter { k, _ in
            k.newest == key.newest && k.count15 == key.count15 && k.low == key.low && k.high == key.high
                && k.today == key.today
        }
        stored[key] = .some(v)
        return v
    }
}
