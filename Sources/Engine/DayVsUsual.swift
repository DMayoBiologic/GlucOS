import Foundation

// "vs your usual" on Logbook days (improvement round 103, docs/LogbookSearch.md, "Compared with
// your usual"): a small note under a day header on the iPhone Logbook and beside the Day cell on the
// Mac when that day's time in range was clearly above or below the person's own usual.
//
// Method:
// 1. The day's time in range is the bar's figure (`DayInRange`), from 5-minute buckets.
// 2. "Your usual" is the median time in range of the 14 days before it that have a figure of their
//    own. Days with readings over less than half their 15-minute slots have no figure, so a sensor
//    gap never drags the usual down. At least 7 of the 14 must have one, or nothing is compared.
// 3. The note shows when the day's rounded percent is 10 or more points from the usual's rounded
//    percent, so it agrees with the figures on screen, and only when the day itself is covered over
//    at least half its slots.
// 4. Today isn't compared until it's over: midnight to now against whole days would mostly measure
//    the time of day.
//
// Observational only: it describes the day and never suggests what to do about it. Worked out once
// per data change through `DayInRangeCache`, never per frame.

struct DayVsUsual: Hashable {
    enum Direction: Hashable { case above, below }

    /// The day's local midnight.
    let day: Date
    /// The day's in-range share, 0...1.
    let inRange: Double
    /// The median in-range share of the days it was compared with, 0...1.
    let usual: Double
    /// How many of the 14 days before it had a figure.
    let days: Int

    /// How many days back the usual looks.
    static let lookbackDays = 14
    /// How many of those need a figure before anything is compared.
    static let minimumDays = 7
    /// How far from the usual, in percentage points, before the note shows.
    static let thresholdPoints = 10
    /// The share of the day's 15-minute slots that need a reading (the bars' own floor).
    static let minimumCoverage = 0.5

    /// The day's percent minus the usual's, each rounded as shown ("80%" vs "68%" is 12).
    var points: Int { Self.percent(inRange) - Self.percent(usual) }

    var direction: Direction { points >= 0 ? .above : .below }

    /// Whether the difference is big enough to say anything.
    var isNotable: Bool { abs(points) >= Self.thresholdPoints }

    static func percent(_ share: Double) -> Int { Int((share * 100).rounded(.toNearestOrEven)) }

    /// The 14 local midnights before `day`, newest first.
    static func priorDays(_ day: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        let start = calendar.startOfDay(for: day)
        return (1...lookbackDays).compactMap { calendar.date(byAdding: .day, value: -$0, to: start) }
    }

    /// Every day whose figure is needed to compare `days`: the days themselves and the 14 before
    /// each, oldest first, so one `DayInRangeCache` call covers the lot.
    static func daysNeeded(for days: [Date], calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        var out = Set<Date>()
        for d in days {
            let start = calendar.startOfDay(for: d)
            out.insert(start)
            out.formUnion(priorDays(start, calendar: calendar))
        }
        return out.sorted()
    }

    /// The comparison for one day, nil when it can't be made (today, too few readings that day, or
    /// fewer than 7 of the 14 days before it with a figure). Whether it is worth showing is
    /// `isNotable`.
    static func compare(_ day: Date, figures: [Date: DayInRange], now: Date = Date(),
                        calendar: Calendar = .autoupdatingCurrent) -> DayVsUsual? {
        let start = calendar.startOfDay(for: day)
        guard start < calendar.startOfDay(for: now),
              let f = figures[start], f.coverage >= minimumCoverage else { return nil }
        let prior = priorDays(start, calendar: calendar).compactMap { d -> Double? in
            guard let p = figures[d], p.coverage >= minimumCoverage else { return nil }
            return p.inRange
        }
        guard prior.count >= minimumDays else { return nil }
        return DayVsUsual(day: start, inRange: f.inRange, usual: median(prior), days: prior.count)
    }

    /// The notable comparisons for `days`, keyed by local midnight. Days that aren't far enough from
    /// their usual, or can't be compared, are left out.
    static func notable(_ days: [Date], figures: [Date: DayInRange], now: Date = Date(),
                        calendar: Calendar = .autoupdatingCurrent) -> [Date: DayVsUsual] {
        var out: [Date: DayVsUsual] = [:]
        for d in days {
            if let c = compare(d, figures: figures, now: now, calendar: calendar), c.isNotable { out[c.day] = c }
        }
        return out
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }
}

// MARK: - Words

enum DayVsUsualText {
    /// "+12 vs your usual", "−15 vs your usual": the note itself.
    static func short(_ c: DayVsUsual) -> String {
        let n = abs(c.points)
        return (c.direction == .above ? "+\(n)" : "\u{2212}\(n)") + " vs your usual"
    }

    /// The arrow beside the note.
    static func symbol(_ c: DayVsUsual) -> String {
        c.direction == .above ? "arrow.up.right" : "arrow.down.right"
    }

    /// "12 points above your usual time in range of 68%", said once with the day header.
    static func spoken(_ c: DayVsUsual) -> String {
        "\(points(c)) \(c.direction == .above ? "above" : "below") your usual time in range of \(c.usual.formattedPercent)"
    }

    /// The Mac note's tooltip: "12 points above your usual time in range of 68%. Click to see how
    /// it's worked out."
    static func help(_ c: DayVsUsual) -> String {
        spoken(c) + ". Click to see how it's worked out."
    }

    /// "1 point", "12 points".
    static func points(_ c: DayVsUsual) -> String {
        let n = abs(c.points)
        return n == 1 ? "1 point" : "\(n) points"
    }

    static let title = "Compared with your usual"
    /// The VoiceOver action and the Mac tooltip that open the explanation.
    static let actionName = "How Your Usual Is Worked Out"

    /// The explanation a tap opens: what the usual is, this day against it, and when a note shows.
    /// `spokenDay` is the day as said in full ("Tuesday 12 November", "Yesterday").
    static func explanation(_ c: DayVsUsual, spokenDay: String) -> [String] {
        let usual = c.usual.formattedPercent
        let day = c.inRange.formattedPercent
        let side = c.direction == .above ? "above" : "below"
        return [
            "Your usual is the middle time in range of the \(DayVsUsual.lookbackDays) days before this one, "
                + "counting the \(c.days) that had enough readings: \(usual).",
            "\(spokenDay) was \(day) in range, \(points(c)) \(side) it.",
            "A note shows when a day is \(DayVsUsual.thresholdPoints) or more points above or below its usual, "
                + "and only on days with readings over at least half the day. Today is compared once it's over.",
        ]
    }
}

private extension Double {
    var formattedPercent: String { "\(DayVsUsual.percent(self))%" }
}
