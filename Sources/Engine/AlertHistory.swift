import Foundation

// Settings › Alerts › History (docs/AlertHistory.md): every low and high alert of the last 7 days,
// one row each, grouped by day. When it went off, which alert, the reading at the time, and what
// happened to it: snoozed, "Log treatment" tapped, dismissed, or nothing. Tapping a row opens the
// Logbook around that time.
//
// Built only from what the device already keeps: the alert records (`AlertLog`, synced between the
// Mac and the iPhone) and the stored readings. Test alerts (docs/TestAlert.md) are never recorded,
// so they never show here. Plain Foundation so it's unit-tested.

enum AlertHistory {
    /// Today and the 6 days before it, by the device's calendar.
    static let days = 7
    /// The reading an alert was about: the last one at or before it within this long...
    static let readingBefore: TimeInterval = 10 * 60
    /// ...or, failing that, the first one just after (a push can be stamped a little before the
    /// reading reaches this device).
    static let readingAfter: TimeInterval = 5 * 60
    /// The Mac and the iPhone each record an alert they both showed: one row, not two.
    static let sameAlert: TimeInterval = AlertLog.sameAlert * 2
    /// The Logbook a row opens: from a little before the alert's spell to two hours after the
    /// alert, so what was logged about it (food for a low, a correction for a high) is there.
    static let linkBefore: TimeInterval = 15 * 60
    static let linkAfter: TimeInterval = 2 * 3600

    /// What happened to an alert.
    enum Outcome: Hashable {
        case snoozed(minutes: Int?)
        /// "Log treatment" was tapped. Only what was then logged is a treatment (docs/AlertLog.md).
        case treating
        case dismissed
        case noResponse

        /// A button beats a dismissal: the banner goes away after its button too.
        fileprivate var rank: Int {
            switch self {
            case .treating: return 0
            case .snoozed: return 1
            case .dismissed: return 2
            case .noResponse: return 3
            }
        }

        fileprivate init(_ r: AlertRecord) {
            switch r.response {
            case .snoozed: self = .snoozed(minutes: r.snoozeMinutes)
            case .treating: self = .treating
            case .dismissed: self = .dismissed
            case .other, nil: self = .noResponse
            }
        }

        /// "Snoozed 30 min", "Tapped Log treatment", "Dismissed", "No response".
        var text: String {
            switch self {
            case .snoozed(let m): return AlertLog.responseText(.snoozed, snoozeMinutes: m)
            case .treating: return AlertLog.responseText(.treating, snoozeMinutes: nil)
            case .dismissed: return AlertLog.responseText(.dismissed, snoozeMinutes: nil)
            case .noResponse: return AlertLog.responseText(nil, snoozeMinutes: nil)
            }
        }

        /// The SF Symbol beside it.
        var symbol: String {
            switch self {
            case .snoozed: return "zzz"
            case .treating: return "cross.case"
            case .dismissed: return "xmark.circle"
            case .noResponse: return "minus.circle"
            }
        }
    }

    /// One alert.
    struct Item: Identifiable, Hashable {
        /// The (first) record's id.
        let id: UUID
        let kind: AlertNotice.Kind
        let firedAt: Date
        /// The reading at the time, when one was stored close enough.
        let readingMgdl: Double?
        let outcome: Outcome
        /// When the button was tapped or the alert dismissed.
        let respondedAt: Date?

        var title: String { AlertLog.title(kind) }
        var isLow: Bool { kind.treatment == .low }
    }

    /// One day's alerts, newest first.
    struct Day: Identifiable, Hashable {
        /// Local midnight.
        let start: Date
        let items: [Item]
        var id: Date { start }
    }

    /// Where the history starts: midnight 6 days before today.
    static func start(now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today.addingTimeInterval(-Double(days - 1) * 86_400)
    }

    /// The last 7 days' low and high alerts, newest first. `readings` in any order.
    static func items(records: [AlertRecord], readings: [GlucoseReading], now: Date,
                      calendar: Calendar = .autoupdatingCurrent) -> [Item] {
        let from = start(now: now, calendar: calendar)
        let known = records
            .compactMap { r -> (AlertRecord, AlertNotice.Kind)? in
                guard let k = r.alertKind, AlertLog.isLogged(k), r.firedAt >= from, r.firedAt <= now else { return nil }
                return (r, k)
            }
            .sorted { $0.0.firedAt < $1.0.firedAt }
        // Fold the Mac's and the iPhone's copies of one alert together, keeping the best outcome.
        var merged: [(first: AlertRecord, kind: AlertNotice.Kind, outcome: Outcome, respondedAt: Date?)] = []
        for (r, k) in known {
            let o = Outcome(r)
            if let i = merged.lastIndex(where: { $0.kind == k && r.firedAt.timeIntervalSince($0.first.firedAt) <= sameAlert }) {
                if o.rank < merged[i].outcome.rank {
                    merged[i].outcome = o
                    merged[i].respondedAt = r.respondedAt
                }
            } else {
                merged.append((first: r, kind: k, outcome: o, respondedAt: r.respondedAt))
            }
        }
        let sortedReadings = readings.sorted { $0.timestamp < $1.timestamp }
        return merged
            .map { m in
                Item(id: m.first.id, kind: m.kind, firedAt: m.first.firedAt,
                     readingMgdl: reading(at: m.first.firedAt, in: sortedReadings)?.mgdl,
                     outcome: m.outcome, respondedAt: m.outcome == .noResponse ? nil : m.respondedAt)
            }
            .sorted { $0.firedAt > $1.firedAt }
    }

    /// The items by local day, newest day first. Days with no alerts are left out.
    static func days(_ items: [Item], calendar: Calendar = .autoupdatingCurrent) -> [Day] {
        let byDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.firedAt) }
        return byDay.keys.sorted(by: >).map { d in
            Day(start: d, items: byDay[d]!.sorted { $0.firedAt > $1.firedAt })
        }
    }

    /// The reading an alert went off on. `readings` oldest first.
    static func reading(at time: Date, in readings: [GlucoseReading]) -> GlucoseReading? {
        if let before = readings.last(where: { $0.timestamp <= time }),
           time.timeIntervalSince(before.timestamp) <= readingBefore {
            return before
        }
        return readings.first { $0.timestamp > time && $0.timestamp.timeIntervalSince(time) <= readingAfter }
    }

    /// The Logbook a row opens: everything around the alert, from the start of the Logbook row it
    /// folds into (so that row is listed) to two hours after it.
    static func link(for item: Item, records: [AlertRecord], now: Date,
                     calendar: Calendar = .autoupdatingCurrent) -> LogbookLink {
        let row = AlertLog.rows(records).first { r in
            r.kind.treatment == item.kind.treatment && r.first <= item.firedAt && item.firedAt <= r.last
        }
        let from = min(row?.first ?? item.firedAt, item.firedAt).addingTimeInterval(-linkBefore)
        let to = max(item.firedAt.addingTimeInterval(linkAfter), from)
        let when = ClockLabel.dayTime(item.firedAt, now: now, calendar: calendar)
        return LogbookLink(filter: .aroundAlert,
                           period: .init(label: "Around \(when)", phrase: "around \(when)",
                                         interval: DateInterval(start: from, end: to)))
    }
}

// MARK: - Words

enum AlertHistoryText {
    static let title = "Alert history"
    static let rowTitle = "Alert History"
    static let footer = "Low and high alerts from the last 7 days, with what was done about each. Tap one to see the Logbook around it."
    static let macFooter = "Low and high alerts from the last 7 days, with what was done about each. Click one to see the Logbook around it."

    static let emptyTitle = "No alerts in the last 7 days"
    /// Why there's nothing, and what would put something here.
    static func emptyMessage(alertsOn: Bool) -> String {
        alertsOn
            ? "Low and high alerts will be listed here as they go off. Test alerts aren't included."
            : "Glucose alerts are off, so nothing has gone off. Turn them on to be told about lows and highs."
    }

    /// "3.4 mmol/L", or "No reading" when none was stored close enough.
    static func reading(_ mgdl: Double?, unit: GlucoseUnit) -> String {
        mgdl.map { unit.format(mgdl: $0, withUnit: true) } ?? "No reading"
    }

    /// "Snoozed 30 min at 2:16 pm", "No response".
    static func outcome(_ item: AlertHistory.Item, calendar: Calendar = .autoupdatingCurrent) -> String {
        guard let at = item.respondedAt else { return item.outcome.text }
        return "\(item.outcome.text) at \(ClockLabel.time(at, calendar: calendar))"
    }

    /// One VoiceOver element per row: "Low alert, 2:14 pm, 3.4 mmol/L, Snoozed 30 min at 2:16 pm".
    static func spoken(_ item: AlertHistory.Item, unit: GlucoseUnit, calendar: Calendar = .autoupdatingCurrent) -> String {
        let reading = item.readingMgdl.map { "reading \(unit.format(mgdl: $0, withUnit: true))" } ?? "no reading stored"
        return "\(item.title), \(ClockLabel.time(item.firedAt, calendar: calendar)), \(reading), \(outcome(item, calendar: calendar))"
    }

    static let hint = "Opens the Logbook around this alert."

    /// "3 alerts" for a day's header.
    static func count(_ n: Int) -> String { n == 1 ? "1 alert" : "\(n) alerts" }
}
