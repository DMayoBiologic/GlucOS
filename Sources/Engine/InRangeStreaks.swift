import Foundation

// Insights "In-range streaks": the run of days in a row with time in range at 70% or more that's
// going now, the longest run in the readings kept on this device (up to 90 days), and the last
// 14 days as a row of dots.
//
// Method:
// 1. Readings are averaged into 5-minute buckets, as for time in range, Lows, Highs and the other
//    Insights cards, and each bucket belongs to the local day it starts in.
// 2. A day counts when half of its 15-minute slots (12 hours) have readings, as on the Overnight
//    and Weekdays and weekends cards. A counted day "meets the goal" when 70% or more of its
//    buckets are in range (the international consensus target for time in range).
// 3. A run is days in a row that met the goal. A day that didn't, or that had too few readings,
//    ends it: the card can't say a day it barely saw was in range.
// 4. Today is still under way. It joins the current run once it has enough readings and is at
//    70% or more so far, and until then it doesn't break the run either, so the run shown in the
//    morning is the one that ended last night.
// 5. The best run is the longest; on a tie, the latest, so the one you remember is the one shown.
//    The card needs 3 counted days before it shows anything.
//
// Observational only: it describes what happened and never suggests a change to insulin, food or
// any setting. Plain Foundation, so it's unit-tested. Worked out off the main thread once per data
// change (`InRangeStreaksCache`).

struct InRangeStreaks: Hashable {
    /// A day meets the goal at this share of its buckets in range.
    static let goal = 0.70
    /// A day needs this share of its 15-minute slots with readings.
    static let minimumDayCoverage = 0.5
    /// Counted days before the card shows.
    static let minimumDays = 3
    /// Days in the row of dots, today last.
    static let dotDays = 14

    /// One day in the row of dots.
    struct Day: Hashable, Identifiable {
        enum Mark: Hashable {
            /// 70% or more in range.
            case met
            /// Counted, under 70%.
            case missed
            /// Too few readings to count.
            case noData
            /// Today, not yet at the goal with enough readings. Doesn't break the run.
            case underWay
        }

        /// Local midnight.
        let start: Date
        let mark: Mark
        /// Time in range over the day's buckets, 0...1; nil with no readings.
        let timeInRange: Double?

        var id: Date { start }
    }

    /// Days in a row that met the goal.
    struct Run: Hashable {
        /// Local midnight of the first day.
        let start: Date
        /// Local midnight after the last day.
        let end: Date
        let days: Int

        var interval: DateInterval { DateInterval(start: start, end: end) }
    }

    /// The newest reading.
    let end: Date
    /// The run going now: up to yesterday, or today once it has met the goal. Nil when the last
    /// finished day missed (a "0 days" figure).
    let current: Run?
    /// The longest run in the readings kept, the latest on a tie.
    let best: Run
    /// The last `dotDays` days, oldest first, today last.
    let recent: [Day]
    /// Days with enough readings to count, over everything kept.
    let countedDays: Int

    var currentDays: Int { current?.days ?? 0 }
    /// Whether the run going now is the best one (it's the same run, not just as long).
    var currentIsBest: Bool { current == best }
    /// Days the current run is short of the best; 0 when it is the best.
    var daysToBest: Int { max(0, best.days - currentDays) }

    // MARK: Compute

    static func compute(readings: [GlucoseReading], low: Double, high: Double,
                        calendar: Calendar = .autoupdatingCurrent) -> InRangeStreaks? {
        guard let newest = readings.last(where: { $0.mgdl > 0 }) else { return nil }
        let end = newest.timestamp

        // 5-minute buckets.
        let size = Double(TodaySoFar.bucketMinutes) * 60
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for r in readings where r.mgdl > 0 && r.timestamp <= end {
            let key = Int((r.timestamp.timeIntervalSince1970 / size).rounded(.down))
            let old = sums[key] ?? (0, 0)
            sums[key] = (old.sum + r.mgdl, old.n + 1)
        }
        guard let firstKey = sums.keys.min() else { return nil }

        // Each day's buckets in range, buckets in all, and 15-minute slots filled.
        struct Tally { var inRange = 0, total = 0, slots = Set<Int>() }
        let slot = Double(LowsSummary.coverageMinutes) * 60
        let slotsPerDay = Int((86_400 / slot).rounded())
        var tally: [Date: Tally] = [:]
        for (key, s) in sums {
            let t = Date(timeIntervalSince1970: Double(key) * size)
            let day = calendar.startOfDay(for: t)
            var d = tally[day] ?? Tally()
            let mean = s.sum / Double(s.n)
            d.total += 1
            if mean >= low && mean <= high { d.inRange += 1 }
            d.slots.insert(Int((t.timeIntervalSince(day) / slot).rounded(.down)))
            tally[day] = d
        }

        // Every day from the first reading's to today's, in order.
        let today = calendar.startOfDay(for: end)
        var days: [Day] = []
        var counted = 0
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(firstKey) * size))
        while day <= today {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            defer { day = next }
            let t = tally[day]
            let share: Double? = t.flatMap { (x: Tally) -> Double? in
                x.total > 0 ? Double(x.inRange) / Double(x.total) : nil
            }
            let covered = Double(t?.slots.count ?? 0) >= minimumDayCoverage * Double(slotsPerDay)
            let mark: Day.Mark
            if covered, let share {
                counted += 1
                mark = share >= goal ? .met : (day == today ? .underWay : .missed)
            } else {
                mark = day == today ? .underWay : .noData
            }
            days.append(Day(start: day, mark: mark, timeInRange: share))
        }
        guard counted >= minimumDays else { return nil }

        // Runs of met days. Today under way neither adds nor ends one.
        var runs: [Run] = []
        var runStart: Date?
        var runDays = 0
        func close(at end: Date) {
            if let s = runStart, runDays > 0 { runs.append(Run(start: s, end: end, days: runDays)) }
            runStart = nil
            runDays = 0
        }
        for d in days {
            switch d.mark {
            case .met:
                if runStart == nil { runStart = d.start }
                runDays += 1
            case .missed, .noData:
                close(at: d.start)
            case .underWay:
                break
            }
        }
        // A run still going at the end: it ends after its last met day.
        if let last = days.last(where: { $0.mark == .met }), runStart != nil {
            close(at: calendar.date(byAdding: .day, value: 1, to: last.start) ?? last.start.addingTimeInterval(86_400))
        }

        // The current run is one that reaches yesterday (ending at today's midnight) or today, once
        // it's met (ending at tomorrow's).
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        let current = runs.last.flatMap { r -> Run? in
            r.end == today || r.end == tomorrow ? r : nil
        }
        // Longest, the latest on a tie. With no run at all, an empty one at today.
        let best = runs.reduce(nil as Run?) { b, r in
            guard let b else { return r }
            return r.days >= b.days ? r : b
        } ?? Run(start: today, end: today, days: 0)

        let recent = Array(days.suffix(dotDays))
        // Pad the front with no-data days when fewer days are kept than the row holds.
        var padded: [Day] = []
        if recent.count < dotDays, let first = recent.first {
            for i in stride(from: dotDays - recent.count, to: 0, by: -1) {
                let d = calendar.date(byAdding: .day, value: -i, to: first.start) ?? first.start.addingTimeInterval(-Double(i) * 86_400)
                padded.append(Day(start: d, mark: .noData, timeInRange: nil))
            }
        }
        return InRangeStreaks(end: end, current: current, best: best, recent: padded + recent, countedDays: counted)
    }
}

// MARK: - Words

/// The card's words, shown and spoken.
enum InRangeStreaksText {
    static let title = "In-range streaks"

    static var emptyLine: String {
        "Streaks show here once GlucOS has readings from \(InRangeStreaks.minimumDays) days."
    }

    /// "1 day", "12 days".
    static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    /// The rolling figure's words for a value on its way: "7 days".
    static func figure(_ value: Double) -> String { days(Int(value.rounded())) }

    /// "70%".
    static var goalPercent: String { "\(Int((InRangeStreaks.goal * 100).rounded()))%" }

    /// "3 Nov", or "3 Nov 2025" when the year isn't this one.
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return LogbookExport.dateFormatter(sameYear ? "d MMM" : "d MMM yyyy", calendar: calendar).string(from: date)
    }

    /// A run's days: "3 Nov – 14 Nov", or "14 Nov" for one day.
    static func span(_ run: InRangeStreaks.Run, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: run.end) ?? run.end.addingTimeInterval(-86_400)
        let a = day(run.start, now: now, calendar: calendar), b = day(last, now: now, calendar: calendar)
        return a == b ? b : "\(a) – \(b)"
    }

    /// How the run reads in a sentence: "from 3 Nov to 14 Nov", or "on 14 Nov" for one day.
    static func phrase(_ run: InRangeStreaks.Run, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: run.end) ?? run.end.addingTimeInterval(-86_400)
        let a = day(run.start, now: now, calendar: calendar), b = day(last, now: now, calendar: calendar)
        return a == b ? "on \(b)" : "from \(a) to \(b)"
    }

    /// Under the current figure: "since 3 Nov", "today" or "none going".
    static func currentCaption(_ s: InRangeStreaks, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        guard let c = s.current else { return "none going" }
        if calendar.isDate(c.start, inSameDayAs: s.end) { return "today" }
        return "since \(day(c.start, now: now, calendar: calendar))"
    }

    /// Under the best figure: "3 Nov – 14 Nov", or "this one" when it's the current run.
    static func bestCaption(_ s: InRangeStreaks, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        guard s.best.days > 0 else { return "none yet" }
        return s.currentIsBest ? "the one going now" : span(s.best, now: now, calendar: calendar)
    }

    /// The sentence under the figures.
    static func line(_ s: InRangeStreaks) -> String {
        if s.best.days == 0 {
            return "No day has reached \(goalPercent) in range yet in the readings kept."
        }
        if s.currentIsBest {
            return "The run going now is the longest in the readings kept."
        }
        if s.currentDays == 0 {
            return "The last full day was under \(goalPercent) in range, so a new run starts with the next one that gets there."
        }
        return "\(days(s.daysToBest)) more would match the longest run."
    }

    /// "10 of the last 14 days at 70% or more."
    static func dotsLine(_ s: InRangeStreaks) -> String {
        let met = s.recent.filter { $0.mark == .met }.count
        return "\(met) of the last \(InRangeStreaks.dotDays) days at \(goalPercent) or more."
    }

    /// One dot for VoiceOver: "3 Nov, 82 percent in range".
    static func spokenDay(_ d: InRangeStreaks.Day, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let name = day(d.start, now: now, calendar: calendar)
        switch d.mark {
        case .met, .missed:
            return "\(name), \(HighsSummaryText.spokenPercent(d.timeInRange ?? 0)) in range"
        case .noData: return "\(name), not enough readings"
        case .underWay:
            if let t = d.timeInRange { return "Today so far, \(HighsSummaryText.spokenPercent(t)) in range" }
            return "Today, no readings yet"
        }
    }

    static var logbookHint: String { "Opens the Logbook on what was logged over the longest run" }

    static func footnote(rangeLine: String) -> String {
        "A day counts at \(goalPercent) or more in range (\(rangeLine)) with readings for at least half the day. Today joins once it gets there. Observations, not advice."
    }

    /// VoiceOver for the figures: "Current streak 5 days, since 3 Nov. Longest 12 days, 3 Oct – 14 Oct."
    static func spoken(_ s: InRangeStreaks, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        var out = "Current streak \(days(s.currentDays))"
        if s.current != nil { out += ", \(currentCaption(s, now: now, calendar: calendar))" }
        out += ". Longest \(days(s.best.days))"
        if s.best.days > 0 { out += ", \(bestCaption(s, now: now, calendar: calendar))" }
        return out + "."
    }
}

// MARK: - Cache

/// Keeps the last result, so the card works it out once per data change rather than on every
/// redraw. The key moves with each 15 minutes of new readings, a backfill, or a change of either
/// line.
@MainActor
final class InRangeStreaksCache {
    static let shared = InRangeStreaksCache()

    struct Key: Hashable {
        var newest: Date?
        var count15: Int
        var low: Double
        var high: Double
    }

    private var stored: (key: Key, value: InRangeStreaks?)?

    nonisolated static func key(readings: [GlucoseReading], low: Double, high: Double) -> Key {
        let newest = readings.last.map { Date(timeIntervalSince1970: ($0.timestamp.timeIntervalSince1970 / 900).rounded(.down) * 900) }
        return Key(newest: newest, count15: readings.count / 15, low: low, high: high)
    }

    func cached(_ key: Key) -> InRangeStreaks?? {
        guard let s = stored, s.key == key else { return nil }
        return .some(s.value)
    }

    func value(for key: Key, readings: [GlucoseReading]) async -> InRangeStreaks? {
        if let hit = cached(key) { return hit }
        let low = key.low, high = key.high
        let v = await Task.detached(priority: .utility) {
            InRangeStreaks.compute(readings: readings, low: low, high: high)
        }.value
        stored = (key, v)
        return v
    }
}
