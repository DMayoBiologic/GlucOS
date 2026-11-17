import Foundation

// "Last 7 days: this would have alerted 3 times (was 5)" under the low and high limits in Settings
// (round 66, docs/AlertCountPreview.md). The stored readings are replayed through the real alert
// rules (`AlertPlanner.evaluate`, then `unsnoozed`), so the count follows the same repeat timer,
// the same reset when glucose comes back into range, the same fixed urgent-low and very-high lines
// and the same snoozes: each "Snooze 30 min" or "Log treatment" tap in the alert log quiets its
// level from when it was tapped, exactly as it did at the time. Forecast heads-ups are left out:
// they depend on the forecast as it was then, which isn't stored. Plain Foundation, unit-tested.

/// How often low and high alerts would have gone off over the last few days with a given range.
struct AlertCountPreview: Equatable {
    /// How far back the preview looks.
    static let window: TimeInterval = 7 * 86_400
    /// Less than this much of the window with readings is too little to count over.
    static let minimumCovered: TimeInterval = 6 * 3600
    /// The kinds each line counts. The urgent-low and very-high lines are fixed, so they only add
    /// a constant to either side of the comparison, but they are alerts all the same.
    static let lowKinds: Set<AlertNotice.Kind> = [.low, .urgentLow]
    static let highKinds: Set<AlertNotice.Kind> = [.high, .veryHigh]

    /// The readings in the window, oldest first, one per timestamp.
    let readings: [GlucoseReading]
    /// The snoozes tapped in the window (and just before it, in case one ran into it), oldest first.
    let snoozes: [Snooze]
    /// The window's start: `window` before now, or the first reading if that is later.
    let start: Date
    let end: Date

    /// One tap that quieted a level: when, which alert it was tapped on, and for how long.
    struct Snooze: Equatable {
        let at: Date
        let kind: AlertNotice.Kind
        let minutes: Int
    }

    /// How many times each side would have alerted.
    struct Counts: Equatable {
        var low = 0
        var high = 0
    }

    /// The preview over the last `window` of `readings` (any order) and the alert log's `records`.
    /// Nil until there are `minimumCovered` hours of readings in the window.
    static func make(readings: [GlucoseReading], records: [AlertRecord], now: Date = Date()) -> AlertCountPreview? {
        let from = now.addingTimeInterval(-window)
        var seen = Set<Date>()
        let recent = readings
            .filter { $0.timestamp >= from && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
            .filter { seen.insert($0.timestamp).inserted }
        guard let first = recent.first, let last = recent.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumCovered else { return nil }
        let earliest = from.addingTimeInterval(-Double(AlertSnoozes.maximumMinutes * 60))
        let taps = records.compactMap { r -> Snooze? in
            guard r.response == .snoozed || r.response == .treating,
                  let kind = r.alertKind, kind.snoozeLevel != nil,
                  let at = r.respondedAt, let minutes = r.snoozeMinutes, minutes > 0,
                  at >= earliest, at <= now else { return nil }
            return Snooze(at: at, kind: kind, minutes: minutes)
        }
        .sorted { $0.at < $1.at }
        return AlertCountPreview(readings: recent, snoozes: taps, start: max(from, first.timestamp), end: now)
    }

    /// Whole days the window covers, 1–7, for "Last 7 days" / "Last 3 days" / "Last day".
    var days: Int {
        let span = end.timeIntervalSince(start)
        return min(Int(Self.window / 86_400), max(1, Int((span / 86_400).rounded(.up))))
    }

    /// The low and high alerts the readings would have set off with `low`/`high` as the range and
    /// `prefs` as the alert switches, replayed one reading at a time at the reading's own time.
    func counts(lowMgdl: Double, highMgdl: Double, prefs: AlertPreferences) -> Counts {
        guard prefs.enabled else { return Counts() }
        // Only the alerts on the reading itself: the rest don't depend on the range.
        var p = prefs
        p.rapidChange = false
        p.stale = false
        p.sensorExpiry = false
        var planner = AlertPlanner()
        var quiet = AlertSnoozes()
        var next = 0
        var out = Counts()
        var snapshot = GlucoseSnapshot()
        snapshot.lowMgdl = lowMgdl
        snapshot.highMgdl = highMgdl
        snapshot.unit = .mgdl
        for r in readings {
            let now = r.timestamp
            while next < snoozes.count, snoozes[next].at <= now {
                quiet.snooze(snoozes[next].kind, minutes: snoozes[next].minutes, now: snoozes[next].at)
                next += 1
            }
            snapshot.current = r
            snapshot.fetchedAt = now
            let due = planner.evaluate(snapshot, prefs: p, now: now)
            for n in planner.unsnoozed(due, snoozes: quiet, now: now) {
                if Self.lowKinds.contains(n.kind) { out.low += 1 }
                if Self.highKinds.contains(n.kind) { out.high += 1 }
            }
        }
        return out
    }
}

/// The words for one side's line.
enum AlertCountLine {
    enum Side: String { case low, high }

    /// "Last 7 days", "Last 3 days", "Last day".
    static func period(days: Int) -> String { days <= 1 ? "Last day" : "Last \(days) days" }

    /// "would have alerted 3 times", "would have alerted once", "would not have alerted".
    static func alerted(_ n: Int) -> String {
        switch n {
        case 0: return "would not have alerted"
        case 1: return "would have alerted once"
        default: return "would have alerted \(n) times"
        }
    }

    /// "this would have alerted 3 times (was 5)". The "(was …)" only while the count differs from
    /// the one for the limit as it was when Settings opened.
    static func phrase(count: Int, was: Int?) -> String {
        var s = "this \(alerted(count))"
        if let was, was != count { s += " (was \(was))" }
        return s
    }

    /// "Last 7 days: this would have alerted 3 times (was 5)".
    static func text(days: Int, count: Int, was: Int?) -> String {
        "\(period(days: days)): \(phrase(count: count, was: was))"
    }

    /// What VoiceOver says: "Low alerts, last 7 days: this limit would have alerted 3 times, down
    /// from 5".
    static func spoken(_ side: Side, days: Int, count: Int, was: Int?) -> String {
        let name = side == .low ? "Low" : "High"
        var s = "\(name) alerts, \(period(days: days).lowercased()): this limit \(alerted(count))"
        if let was, was != count { s += ", \(count < was ? "down" : "up") from \(was)" }
        return s
    }
}
