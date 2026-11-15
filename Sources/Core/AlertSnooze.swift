import Foundation

// The buttons on a low or high alert (docs/AlertActions.md): "Snooze 30 min" and "I'm treating it".
// Plain Foundation so the rules are unit-tested, and the relay's copy (snoozeLevel and friends in
// supabase/functions/relay/core.ts) follows the same table.
//
// - Urgent lows (a reading under 54, or one forecast) are never snoozed, by either button, on any
//   device or by the relay. Their notifications only offer "I'm treating it".
// - A snooze only quiets the owner's own alerts. Followers' alerts, check-ins and their reminders
//   and the Lock Screen card carry on exactly as before.
// - Snoozing a very high quiets highs too; snoozing a high lets a very high through. Escalation
//   always gets through.
// - When a snooze ends and the alert is still due, it fires on the next reading rather than
//   waiting out its repeat timer (`AlertPlanner.release`).

/// How serious a snoozable alert is. Each level has its own snooze.
enum AlertSnoozeLevel: String, Codable, CaseIterable, Hashable {
    case low, high, veryHigh
}

/// What "I'm treating it" opens the log sheet on.
enum AlertTreatment: String, Codable, Hashable {
    /// Food tagged as a hypo treatment (the "Treat a low" usual entry when there is one).
    case low
    /// A correction dose.
    case high
}

extension AlertNotice.Kind {
    /// The snooze this alert can be quieted by. Nil: never snoozable (urgent lows) or no buttons.
    var snoozeLevel: AlertSnoozeLevel? {
        switch self {
        case .low, .predictedLow: return .low
        case .high, .predictedHigh: return .high
        case .veryHigh, .predictedVeryHigh: return .veryHigh
        case .urgentLow, .predictedUrgentLow, .rapidChange, .stale, .sensorExpiring, .apiBroken: return nil
        }
    }

    /// What "I'm treating it" logs for this alert. Nil: no button.
    var treatment: AlertTreatment? {
        switch self {
        case .urgentLow, .predictedUrgentLow, .low, .predictedLow: return .low
        case .high, .predictedHigh, .veryHigh, .predictedVeryHigh: return .high
        case .rapidChange, .stale, .sensorExpiring, .apiBroken: return nil
        }
    }

    /// The notification category with this alert's buttons, registered by both apps and named by
    /// the relay in its pushes (`alertCategory` in core.ts). Nil: no buttons.
    var actionCategory: String? {
        guard treatment != nil else { return nil }
        return snoozeLevel == nil ? AlertSnoozes.treatOnlyCategory : AlertSnoozes.snoozeAndTreatCategory
    }
}

/// Until when each level is snoozed. Persisted by each app and, for push alerts, by the relay.
struct AlertSnoozes: Codable, Hashable {
    /// When each level's snooze ends, in seconds since 1970. Nil: not snoozed. (Fields rather than
    /// a dictionary so the JSON matches the relay's `{low, high, veryHigh}`.)
    var low: Double?
    var high: Double?
    var veryHigh: Double?

    subscript(level: AlertSnoozeLevel) -> Double? {
        get {
            switch level {
            case .low: return low
            case .high: return high
            case .veryHigh: return veryHigh
            }
        }
        set {
            switch level {
            case .low: low = newValue
            case .high: high = newValue
            case .veryHigh: veryHigh = newValue
            }
        }
    }

    static let snoozeMinutes = 30
    /// "I'm treating it" quiets the same alert while the treatment works: 15 minutes for a low
    /// (the usual time to recheck after fast carbs), 30 for a high. Never an urgent low.
    static func treatingMinutes(_ t: AlertTreatment) -> Int { t == .low ? 15 : 30 }
    /// The relay refuses anything longer.
    static let maximumMinutes = 60

    static let snoozeAndTreatCategory = "glucos.alert"
    static let treatOnlyCategory = "glucos.alert.urgent"
    static let snoozeAction = "alert.snooze"
    static let treatAction = "alert.treat"

    init() {}

    /// Whether `kind` is quieted at `now`. Urgent lows never are.
    func silences(_ kind: AlertNotice.Kind, at now: Date) -> Bool {
        guard let level = kind.snoozeLevel else { return false }
        let t = now.timeIntervalSince1970
        let covering: [AlertSnoozeLevel] = level == .high ? [.high, .veryHigh] : [level]
        return covering.contains { (self[$0] ?? 0) > t }
    }

    /// Snoozes `kind`'s level for `minutes` (at most `maximumMinutes`). An existing longer snooze is
    /// kept. False, and nothing changes, for an alert that can't be snoozed.
    @discardableResult
    mutating func snooze(_ kind: AlertNotice.Kind, minutes: Int, now: Date) -> Bool {
        guard let level = kind.snoozeLevel, minutes > 0 else { return false }
        let end = now.timeIntervalSince1970 + Double(min(minutes, Self.maximumMinutes) * 60)
        self[level] = max(self[level] ?? 0, end)
        return true
    }

    /// Drops snoozes that have ended.
    mutating func prune(now: Date) {
        let t = now.timeIntervalSince1970
        for level in AlertSnoozeLevel.allCases where (self[level] ?? 0) <= t { self[level] = nil }
    }
}

/// `POST /v1/alerts/snooze`: quiet the relay's pushes of this alert for a while.
struct AlertSnoozeRequest: Codable, Hashable {
    /// `AlertNotice.Kind.rawValue` of the alert whose button was tapped.
    var kind: String
    var minutes: Int
}

extension AlertPlanner {
    /// Alerts that are due, minus the snoozed ones. A snoozed alert is let go of (its repeat timer
    /// cleared), so it fires on the first reading after the snooze ends if it's still due.
    mutating func unsnoozed(_ notices: [AlertNotice], snoozes: AlertSnoozes, now: Date) -> [AlertNotice] {
        notices.filter { n in
            guard snoozes.silences(n.kind, at: now) else { return true }
            release(n.kind)
            return false
        }
    }
}
