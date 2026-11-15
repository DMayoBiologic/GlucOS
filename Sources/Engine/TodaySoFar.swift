import Foundation

// Today so far: time in range, the average and lows from midnight to the newest reading, beside the
// same hours on your usual day (the last 14 or 30 days, the window "Your usual day" uses).
//
// Method:
// 1. Readings are averaged into 5-minute buckets, so a stretch of 1-minute Bluetooth readings
//    counts the same as LibreLinkUp's 15-minute history (as in `DayPattern`).
// 2. Today runs from local midnight to the newest reading today. It needs an hour of day gone and
//    readings in half of its 15-minute slots, otherwise there's nothing to say yet.
// 3. Each earlier day in the window is cut at the same clock time and counts only when half of its
//    15-minute slots up to then have readings. Usual time in range and average are the median of
//    those days, so one bad day doesn't move "usual"; lows are the number of those days that had
//    one by this time.
//    It needs `DayPattern.minimumDays` such days, otherwise today shows on its own.
// 4. A low is a run below the low threshold lasting 15 minutes or more; a gap of over 30 minutes
//    ends a run (the rule the dashboard's Days page uses).
//
// Observational only, like Insights: it says how today compares and never suggests a change to
// insulin or settings. Plain Foundation, so it's unit-tested. Worked out off the main thread once
// per data change (see `TodaySoFarCache`), never per frame, and the card it feeds doesn't animate.

struct TodaySoFar: Hashable {
    struct Figures: Hashable {
        /// Share of 5-minute buckets inside the target, 0...1.
        var timeInRange: Double
        var meanMgdl: Double
        /// Runs below range of 15 minutes or more.
        var lows: Int
    }

    struct Usual: Hashable {
        /// The median day's time in range and average over the same hours.
        var timeInRange: Double
        var meanMgdl: Double
        /// Days that had at least one low by this time, out of `days`.
        var daysWithLows: Int
        /// Earlier days with enough readings over these hours.
        var days: Int
    }

    let window: DayPattern.Window
    /// Minutes after midnight the figures run to (the newest reading's clock time).
    let minute: Int
    let today: Figures
    /// Nil until there are enough earlier days to compare with.
    let usual: Usual?

    static let bucketMinutes = 5
    static let coverageMinutes = 15
    /// Today needs this much of the day gone before it says anything.
    static let minimumMinutes = 60
    /// Share of buckets up to now a day needs (today and each usual day).
    static let minimumCoverage = 0.5
    static let lowMinimum: TimeInterval = 15 * 60
    static let lowMaxGap: TimeInterval = 30 * 60

    // MARK: Compute

    static func compute(readings: [GlucoseReading], window: DayPattern.Window, low: Double, high: Double,
                        now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> TodaySoFar? {
        let todayStart = calendar.startOfDay(for: now)
        guard let newest = readings.last(where: { $0.timestamp <= now && $0.mgdl > 0 }),
              newest.timestamp >= todayStart else { return nil }
        let elapsed = newest.timestamp.timeIntervalSince(todayStart)
        guard elapsed >= Double(minimumMinutes) * 60 else { return nil }

        guard let windowStart = calendar.date(byAdding: .day, value: -window.days, to: todayStart) else { return nil }
        let recent = readings.filter { $0.timestamp >= windowStart && $0.timestamp <= newest.timestamp && $0.mgdl > 0 }

        guard let today = figures(recent, from: todayStart, span: elapsed, low: low, high: high) else { return nil }

        var dayFigures: [Figures] = []
        for k in 1...window.days {
            guard let start = calendar.date(byAdding: .day, value: -k, to: todayStart),
                  let f = figures(recent, from: start, span: elapsed, low: low, high: high) else { continue }
            dayFigures.append(f)
        }
        var usual: Usual?
        if dayFigures.count >= DayPattern.minimumDays {
            usual = Usual(timeInRange: median(dayFigures.map(\.timeInRange)),
                          meanMgdl: median(dayFigures.map(\.meanMgdl)),
                          daysWithLows: dayFigures.filter { $0.lows > 0 }.count,
                          days: dayFigures.count)
        }
        let minute = Int(elapsed / 60)
        return TodaySoFar(window: window, minute: minute, today: today, usual: usual)
    }

    /// One day's figures from `start` over `span` seconds, or nil when under half of it has readings.
    static func figures(_ readings: [GlucoseReading], from start: Date, span: TimeInterval,
                        low: Double, high: Double) -> Figures? {
        let end = start.addingTimeInterval(span)
        let size = Double(bucketMinutes) * 60
        var buckets: [Int: (sum: Double, n: Int)] = [:]
        for r in readings where r.timestamp >= start && r.timestamp <= end {
            let key = Int((r.timestamp.timeIntervalSince(start) / size).rounded(.down))
            let old = buckets[key] ?? (0, 0)
            buckets[key] = (old.sum + r.mgdl, old.n + 1)
        }
        // Coverage is counted in 15-minute slots, so LibreLinkUp's 15-minute history (one reading
        // in three 5-minute buckets) counts as complete.
        let slot = Double(coverageMinutes) * 60
        let possible = max(1, Int((span / slot).rounded(.up)))
        let filled = Set(buckets.keys.map { $0 * bucketMinutes / coverageMinutes }).count
        guard !buckets.isEmpty, Double(filled) >= minimumCoverage * Double(possible) else { return nil }
        let ordered = buckets.keys.sorted().map { (key: $0, mgdl: buckets[$0]!.sum / Double(buckets[$0]!.n)) }
        let inRange = ordered.filter { $0.mgdl >= low && $0.mgdl <= high }.count
        let mean = ordered.reduce(0) { $0 + $1.mgdl } / Double(ordered.count)
        let times = ordered.map { (start.addingTimeInterval(Double($0.key) * size), $0.mgdl) }
        return Figures(timeInRange: Double(inRange) / Double(ordered.count), meanMgdl: mean,
                       lows: lowRuns(times, low: low))
    }

    /// Runs below `low` lasting 15 minutes or more, from the first low bucket until glucose is back
    /// at or above `low`. A gap of over 30 minutes ends a run at its last low bucket; a run still going
    /// at the end counts once it has lasted 15 minutes. `points` must be in time order.
    static func lowRuns(_ points: [(Date, Double)], low: Double) -> Int {
        var count = 0
        var start: Date?
        var lastLow: Date?
        let size = Double(bucketMinutes) * 60
        func close(_ end: Date) {
            if let s = start, end.timeIntervalSince(s) >= lowMinimum { count += 1 }
            start = nil; lastLow = nil
        }
        for (t, mgdl) in points {
            if let l = lastLow, t.timeIntervalSince(l) > lowMaxGap { close(l.addingTimeInterval(size)) }
            if mgdl < low {
                if start == nil { start = t }
                lastLow = t
            } else if start != nil {
                close(t)
            }
        }
        // A bucket covers five minutes, so a run's last low bucket lasts to its end.
        if let l = lastLow { close(l.addingTimeInterval(size)) }
        return count
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // MARK: Comparison

    enum Change: Hashable { case better, same, worse }

    /// Time in range that differs by less than this (5 percentage points) reads as usual.
    static let rangeStep = 0.05
    /// An average that differs by less than this (0.5 mmol/L) reads as usual.
    static let meanStepMgdl = 9.0

    var rangeChange: Change? {
        guard let usual else { return nil }
        let d = today.timeInRange - usual.timeInRange
        return abs(d) < Self.rangeStep ? .same : (d > 0 ? .better : .worse)
    }

    /// Today's average minus the usual one. The words only say "higher" or "lower": whether that's
    /// good depends on where the average sits, so the card doesn't judge it.
    var meanDifferenceMgdl: Double? { usual.map { today.meanMgdl - $0.meanMgdl } }
}

// MARK: - Words

/// The card's words, shown and spoken. Values use the person's unit without the unit name, like the
/// rest of Insights; times read as people say them ("2:30 pm").
enum TodaySoFarText {
    static let title = "Today so far"

    /// "Midnight to 2:30 pm".
    static func period(_ t: TodaySoFar) -> String {
        "Midnight to \(DayPatternText.clock(t.minute / 5 * 5))"
    }

    /// The one-sentence answer at the top of the card.
    static func headline(_ t: TodaySoFar) -> String {
        switch t.rangeChange {
        case .better: return "More time in range than your usual day by now."
        case .worse: return "Less time in range than your usual day by now."
        case .same: return "About your usual day by now."
        case nil: return "\(Format.percent(t.today.timeInRange)) of today in range so far."
        }
    }

    static func lowsValue(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }

    static func rangeCaption(_ t: TodaySoFar) -> String? {
        t.usual.map { "Usually \(Format.percent($0.timeInRange))" }
    }

    static func meanCaption(_ t: TodaySoFar, unit: GlucoseUnit) -> String? {
        t.usual.map { "Usually \(unit.format(mgdl: $0.meanMgdl))" }
    }

    static func lowsCaption(_ t: TodaySoFar) -> String? {
        guard let u = t.usual else { return nil }
        if u.daysWithLows == 0 { return "Usually none by now" }
        return "\(u.daysWithLows) of \(u.days) days by now"
    }

    /// The line under the figures: what today is compared with, or why it isn't yet.
    static func footnote(_ t: TodaySoFar) -> String {
        if let u = t.usual {
            return "Compared with the same hours on \(u.days) of the last \(t.window.days) days. Observations, not advice."
        }
        return "Your usual day joins in once GlucOS has \(DayPattern.minimumDays) days with readings over these hours."
    }

    /// The whole card for VoiceOver, in a few sentences.
    static func spoken(_ t: TodaySoFar, unit: GlucoseUnit) -> String {
        var parts = ["Today so far, \(period(t).lowercased())", String(headline(t).dropLast())]
        let rangeNow = "\(Int((t.today.timeInRange * 100).rounded())) percent in range"
        if let u = t.usual {
            parts.append("\(rangeNow), usually \(Int((u.timeInRange * 100).rounded())) percent")
            parts.append("Average \(unit.format(mgdl: t.today.meanMgdl)) \(unit.label), usually \(unit.format(mgdl: u.meanMgdl))")
        } else {
            parts.append(rangeNow)
            parts.append("Average \(unit.format(mgdl: t.today.meanMgdl)) \(unit.label)")
        }
        let lows = t.today.lows
        var lowLine = lows == 0 ? "No lows" : (lows == 1 ? "1 low" : "\(lows) lows")
        if let u = t.usual {
            lowLine += u.daysWithLows == 0 ? ", and usually none by now"
                                           : ". \(u.daysWithLows) of the last \(u.days) days had one by this time"
        }
        parts.append(lowLine)
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - Cache

/// Keeps the last result for each window, so the card works it out once per data change rather than
/// on every redraw. The key moves with each 5 minutes of new readings, a backfill, a new day or a
/// change of target.
@MainActor
final class TodaySoFarCache {
    static let shared = TodaySoFarCache()

    struct Key: Hashable {
        var window: DayPattern.Window
        var day: Date
        /// The newest reading, rounded down to 5 minutes.
        var newest: Date?
        var count15: Int
        var low: Double
        var high: Double
    }

    private var stored: [DayPattern.Window: (key: Key, value: TodaySoFar?)] = [:]

    nonisolated static func key(readings: [GlucoseReading], window: DayPattern.Window, low: Double, high: Double,
                                now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 300).rounded(.down) * 300) }
        return Key(window: window, day: calendar.startOfDay(for: now), newest: newest,
                   count15: readings.count / 15, low: low, high: high)
    }

    func cached(_ key: Key) -> TodaySoFar?? {
        guard let s = stored[key.window], s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading]) async -> TodaySoFar? {
        if let hit = cached(key) { return hit }
        let window = key.window, low = key.low, high = key.high
        let v = await Task.detached(priority: .utility) {
            TodaySoFar.compute(readings: readings, window: window, low: low, high: high)
        }.value
        stored[window] = (key, v)
        return v
    }
}
