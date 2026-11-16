import Foundation

// The buttons on a low or high alert (docs/AlertActions.md): "Log treatment" and "Snooze 30 min".
// (Round 31 renamed "I'm treating it" to "Log treatment"; the action identifiers and categories are
// unchanged, so the relay's pushes and older builds keep working.)
// Plain Foundation so the rules are unit-tested, and the relay's copy (snoozeLevel and friends in
// supabase/functions/relay/core.ts) follows the same table.
//
// - Urgent lows (a reading under 54, or one forecast) are never snoozed, by either button, on any
//   device or by the relay. Their notifications only offer "Log treatment".
// - A snooze only quiets the owner's own alerts. Followers' alerts, check-ins and their reminders
//   and the Lock Screen card carry on exactly as before.
// - Snoozing a very high quiets highs too; snoozing a high lets a very high through. Escalation
//   always gets through.
// - When a snooze ends and the alert is still due, it fires on the next reading rather than
//   waiting out its repeat timer (`AlertPlanner.release`).

/// How serious a snoozable alert is. Each level has its own snooze.
enum AlertSnoozeLevel: String, Codable, CaseIterable, Hashable {
    case low, high, veryHigh

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// What "Log treatment" opens the log sheet on.
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

    /// What "Log treatment" opens the log sheet on for this alert. Nil: no button.
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
    /// "Log treatment" quiets the same alert while the treatment works: 15 minutes for a low
    /// (the usual time to recheck after fast carbs), 30 for a high. Never an urgent low.
    static func treatingMinutes(_ t: AlertTreatment) -> Int { t == .low ? 15 : 30 }
    /// The relay refuses anything longer.
    static let maximumMinutes = 60

    static let snoozeAndTreatCategory = "glucos.alert"
    static let treatOnlyCategory = "glucos.alert.urgent"
    static let snoozeAction = "alert.snooze"
    static let treatAction = "alert.treat"
    /// The button titles. "Log treatment" only opens the log sheet: nothing is logged until Log.
    static let treatTitle = "Log treatment"
    static var snoozeTitle: String { "Snooze \(snoozeMinutes) min" }

    /// The buttons an alert's notification shows, in order. Urgent lows: Log treatment only.
    static func buttonTitles(for kind: AlertNotice.Kind) -> [String] {
        guard kind.treatment != nil else { return [] }
        return kind.snoozeLevel == nil ? [treatTitle] : [treatTitle, snoozeTitle]
    }

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

    /// Ends every snooze now: the snoozed alerts fire on the next reading if they're still due
    /// (they were let go of while snoozed). Urgent lows were never snoozed, so nothing changes for
    /// them. The relay's copy is `POST /v1/alerts/resume`.
    mutating func resumeAll() { self = AlertSnoozes() }

    /// The levels snoozed at `now`, soonest end first, with when each ends.
    func active(at now: Date) -> [(level: AlertSnoozeLevel, until: Date)] {
        let t = now.timeIntervalSince1970
        return AlertSnoozeLevel.allCases.compactMap { level -> (level: AlertSnoozeLevel, until: Date)? in
            guard let end = self[level], end > t else { return nil }
            return (level, Date(timeIntervalSince1970: end))
        }
        .sorted { ($0.until, $0.level.order) < ($1.until, $1.level.order) }
    }

    /// When the soonest running snooze ends. Nil: nothing is snoozed.
    func nextEnd(after now: Date) -> Date? { active(at: now).first?.until }

    /// When the "snoozed" chip needs drawing again: each whole minute until the last snooze ends
    /// (for its minutes left) and each snooze's own end (so it never says snoozed after it isn't).
    /// Empty: nothing is snoozed. Never more often than once a minute, plus the ends.
    func redrawDates(from now: Date) -> [Date] {
        let ends = active(at: now).map { $0.until }
        guard let last = ends.max() else { return [] }
        let firstMinute = (now.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60
        let minutes = stride(from: firstMinute, to: last.timeIntervalSince1970, by: 60)
            .map { Date(timeIntervalSince1970: $0) }
        return Array(Set(minutes + ends)).sorted()
    }
}

// MARK: - The Lock Screen and menu bar badge

extension AlertSnoozes {
    /// What the Live Activity and the Mac menu bar item show while anything is snoozed (nil when
    /// nothing is): one bell-slash "until" the last snooze ends. The relay's copy is `cardSnooze`
    /// in core.ts. A very-high snooze covers highs, so a high snooze that ends no later isn't named.
    func badge(at now: Date) -> SnoozeBadge? {
        var active = self.active(at: now)
        if let vh = active.first(where: { $0.level == .veryHigh }) {
            active.removeAll { $0.level == .high && $0.until <= vh.until }
        }
        guard let last = active.map({ $0.until }).max() else { return nil }
        return SnoozeBadge(until: last.timeIntervalSince1970, levels: active.map { $0.level.rawValue })
    }
}

// MARK: - The "snoozed" chip (docs/AlertActions.md, "Snoozed chip")

/// What iPhone Today and the Mac popover show while alerts are snoozed: "Low alerts snoozed until
/// 2:30 pm · 12 min". Tapping it resumes them. Plain Foundation so the wording is unit-tested.
struct AlertSnoozeChip: Equatable {
    /// "Low alerts snoozed until 2:30 pm".
    var title: String
    /// "12 min" left on the snooze that ends last. Redrawn at most once a minute.
    var remaining: String
    /// For VoiceOver: the title and remaining time in words.
    var accessibilityLabel: String
    static let accessibilityHint = "Turns these alerts back on now."
    static let resumeTitle = "Resume"

    /// The level's name in the chip. A very-high snooze also quiets highs, so it reads "High and
    /// very high"; a high snooze lets very highs through, so it reads "High".
    static func name(_ level: AlertSnoozeLevel) -> String {
        switch level {
        case .low: return "Low"
        case .high: return "High"
        case .veryHigh: return "High and very high"
        }
    }

    /// Nil when nothing is snoozed at `now`. Several levels snoozed to the same minute share one
    /// time; otherwise each says its own ("Low alerts snoozed until 2:30 pm, high until 2:45 pm").
    init?(_ snoozes: AlertSnoozes, now: Date, calendar: Calendar = .autoupdatingCurrent,
          locale: Locale = .autoupdatingCurrent) {
        var active = snoozes.active(at: now)
        // A very-high snooze covers highs: a high snooze that ends no later says nothing new.
        if let vh = active.first(where: { $0.level == .veryHigh }) {
            active.removeAll { $0.level == .high && $0.until <= vh.until }
        }
        guard let last = active.map({ $0.until }).max() else { return nil }
        func time(_ d: Date) -> String { ClockLabel.time(d, calendar: calendar, locale: locale) }
        let times = Set(active.map { time($0.until) })
        if times.count == 1 {
            // "Low", "High and very high", "Low, high and very high".
            let words = active.flatMap { $0.level == .veryHigh ? ["high", "very high"] : [Self.name($0.level).lowercased()] }
            let joined = words.count == 1 ? words[0]
                : words.dropLast().joined(separator: ", ") + " and " + words.last!
            title = "\(Self.capitalisedFirst(joined)) alerts snoozed until \(time(last))"
        } else {
            let parts = active.enumerated().map { i, a in
                i == 0 ? "\(Self.name(a.level)) alerts snoozed until \(time(a.until))"
                    : "\(Self.name(a.level).lowercased()) until \(time(a.until))"
            }
            title = parts.joined(separator: ", ")
        }
        let minutes = Self.minutesLeft(until: last, now: now)
        remaining = "\(minutes) min"
        accessibilityLabel = "\(title), \(minutes) \(minutes == 1 ? "minute" : "minutes") left"
    }

    /// Whole minutes left, rounded up, so the chip never says "0 min" while still snoozed.
    static func minutesLeft(until end: Date, now: Date) -> Int {
        max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    private static func capitalisedFirst(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// `POST /v1/alerts/snooze`: quiet the relay's pushes of this alert for a while. (`POST
/// /v1/alerts/resume`, relay 2.15.0, takes an empty body and ends every snooze.)
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
