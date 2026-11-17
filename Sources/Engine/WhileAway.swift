import Foundation

// "While you were away": one quiet line under the reading on iPhone Today and in the Mac popover,
// shown when the screen opens after 2 hours or more unseen (docs/WhileAway.md). It gives the lowest
// and highest readings, the time in range and the low and high alerts that went off since the
// screen was last looked at. Tapping it opens the Logbook on that span. It slides in once and fades
// after 10 seconds.
//
// Observational only, like Insights: it repeats readings and alerts, and never suggests a dose or
// a change. Never for followers: only the person wearing the sensor has a "last looked".
// Plain Foundation, so `swift test` covers it.

/// When this screen was last looked at, kept per device, and the span an opening has been away.
///
/// The screen counts as looked at when it opens and again when it closes (the popover closing,
/// the iPhone app leaving the screen). So an app left open on the desk for 3 hours and then put
/// away doesn't greet the next opening with "away 3 h".
struct LastLookedClock {
    /// Unseen this long or longer, and the next opening shows the line.
    static let threshold: TimeInterval = 2 * 3600
    /// The longest span the line covers: away for days, it sums up the last 24 hours.
    static let longest: TimeInterval = 24 * 3600
    /// The stored key in UserDefaults.
    static let defaultsKey = "whileAway.lastLooked"

    private let load: () -> Date?
    private let save: (Date) -> Void

    init(load: @escaping () -> Date?, save: @escaping (Date) -> Void) {
        self.load = load
        self.save = save
    }

    /// Kept in UserDefaults as seconds since 1970.
    static func defaults(_ defaults: UserDefaults = .standard, key: String = defaultsKey) -> LastLookedClock {
        LastLookedClock(
            load: { defaults.object(forKey: key) == nil ? nil : Date(timeIntervalSince1970: defaults.double(forKey: key)) },
            save: { defaults.set($0.timeIntervalSince1970, forKey: key) })
    }

    var lastLooked: Date? { load() }

    /// The screen opened at `now`: the span it was away, if it's worth a line, and `now` kept as
    /// the last look. Nil on the very first launch (nothing to compare with), for a follower, after
    /// less than 2 hours, or when the stored time is after `now` (the clock was set back).
    @discardableResult
    func open(now: Date, isFollower: Bool = false) -> DateInterval? {
        guard !isFollower else { return nil }
        let previous = load()
        save(now)
        return Self.awaySpan(since: previous, now: now)
    }

    /// The screen closed (or stopped being looked at) at `now`.
    func close(now: Date, isFollower: Bool = false) {
        guard !isFollower else { return }
        save(now)
    }

    /// The span between the last look and `now`, cut to the last 24 hours, when it's 2 hours or
    /// more. Nil otherwise.
    static func awaySpan(since previous: Date?, now: Date) -> DateInterval? {
        guard let previous, previous <= now else { return nil }
        let away = now.timeIntervalSince(previous)
        guard away >= threshold else { return nil }
        let start = max(previous, now.addingTimeInterval(-longest))
        return DateInterval(start: start, end: now)
    }
}

/// What happened over the span: the lowest and highest readings, the time in range and the alerts.
struct WhileAway: Equatable {
    struct Point: Equatable {
        let mgdl: Double
        let at: Date
    }

    let span: DateInterval
    let lowest: Point
    let highest: Point
    /// Share of the span's 5-minute buckets inside the target, 0...1.
    let timeInRange: Double
    /// Low and high alert rows, folded as the Logbook folds them (`AlertLog.rows`).
    let lowAlerts: Int
    let highAlerts: Int

    /// Readings in fewer 5-minute buckets than this (half an hour) and there's nothing to say.
    static let minimumBuckets = 6
    /// How long the line stays before fading.
    static let shownFor: TimeInterval = 10

    var alerts: Int { lowAlerts + highAlerts }
    /// Cut to the last 24 hours (`LastLookedClock.longest`).
    var isCapped: Bool { span.duration >= LastLookedClock.longest }

    /// The figures over `span`, or nil when the sensor sent too little in it.
    static func compute(span: DateInterval, readings: [GlucoseReading], alerts: [AlertRecord],
                        low: Double, high: Double) -> WhileAway? {
        let inSpan = readings.filter { $0.mgdl > 0 && span.contains($0.timestamp) }
        let buckets = EveningRecap.buckets(inSpan, from: span.start)
        guard buckets.count >= minimumBuckets,
              let lo = inSpan.min(by: { $0.mgdl < $1.mgdl }),
              let hi = inSpan.max(by: { $0.mgdl < $1.mgdl }) else { return nil }
        let inRange = buckets.filter { $0.1 >= low && $0.1 <= high }.count
        let rows = AlertLog.rows(alerts.filter { span.contains($0.firedAt) })
        return WhileAway(span: span,
                         lowest: Point(mgdl: lo.mgdl, at: lo.timestamp),
                         highest: Point(mgdl: hi.mgdl, at: hi.timestamp),
                         timeInRange: Double(inRange) / Double(buckets.count),
                         lowAlerts: rows.filter(\.isLow).count,
                         highAlerts: rows.filter(\.isHigh).count)
    }
}

// MARK: - Logbook

extension LogbookLink {
    /// Everything logged while away, alerts and all: no kind chip, the period chip reads
    /// "While you were away".
    static func whileAway(_ span: DateInterval) -> LogbookLink {
        LogbookLink(filter: .whileAway,
                    period: .init(label: WhileAwayText.title, phrase: "while you were away", interval: span))
    }
}

// MARK: - Words

enum WhileAwayText {
    static let title = "While you were away"

    /// "Away 5 h 20 m · 3.9–11.2 · 84% in range · 1 low alert". The unit is left off to keep it
    /// to one line: it's the unit of the reading just above.
    static func line(_ w: WhileAway, unit: GlucoseUnit) -> String {
        [head(w), "\(unit.format(mgdl: w.lowest.mgdl))–\(unit.format(mgdl: w.highest.mgdl))",
         "\(Format.percent(w.timeInRange)) in range", alerts(w)]
            .joined(separator: " · ")
    }

    /// "Away 5 h 20 m", or "Last 24 h" when away longer.
    static func head(_ w: WhileAway) -> String {
        w.isCapped ? "Last 24 h" : "Away \(duration(w.span.duration))"
    }

    /// "2 h", "5 h 20 m". Whole minutes, rounded down.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) m" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    /// "no alerts", "1 low alert", "2 high alerts", "3 alerts" (both kinds).
    static func alerts(_ w: WhileAway) -> String {
        switch (w.lowAlerts, w.highAlerts) {
        case (0, 0): return "no alerts"
        case (let n, 0): return n == 1 ? "1 low alert" : "\(n) low alerts"
        case (0, let n): return n == 1 ? "1 high alert" : "\(n) high alerts"
        default: return "\(w.alerts) alerts"
        }
    }

    /// For VoiceOver: "While you were away, 5 hours 20 minutes: lowest 3.9 mmol/L at 2:10 am,
    /// highest 11.2 mmol/L at 7:40 am, 84 percent in range, 1 low alert."
    static func spoken(_ w: WhileAway, unit: GlucoseUnit, calendar: Calendar = .autoupdatingCurrent) -> String {
        let span = w.isCapped ? "in the last 24 hours" : spokenDuration(w.span.duration)
        let alertWords = w.lowAlerts > 0 && w.highAlerts > 0
            ? "\(count(w.lowAlerts, "low alert")) and \(count(w.highAlerts, "high alert"))"
            : alerts(w)
        return "\(title), \(span): lowest \(unit.format(mgdl: w.lowest.mgdl)) \(unit.label) at \(clock(w.lowest.at, calendar: calendar)), "
            + "highest \(unit.format(mgdl: w.highest.mgdl)) \(unit.label) at \(clock(w.highest.at, calendar: calendar)), "
            + "\(Int((w.timeInRange * 100).rounded())) percent in range, \(alertWords)."
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return count(m, "minute") }
        return m == 0 ? count(h, "hour") : "\(count(h, "hour")) \(count(m, "minute"))"
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "2:10 am", as the rest of the app says a time of day.
    static func clock(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return DayPatternText.clock((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}
