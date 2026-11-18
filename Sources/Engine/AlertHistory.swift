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

    /// The last 7 days' low and high alerts, newest first. `readings` in any order. `since`
    /// starts the list somewhere else (the Insights Alerts card's period, docs/InsightsAlerts.md).
    static func items(records: [AlertRecord], readings: [GlucoseReading], now: Date, since: Date? = nil,
                      calendar: Calendar = .autoupdatingCurrent) -> [Item] {
        let from = since ?? start(now: now, calendar: calendar)
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

    // MARK: Live changes

    /// An alert new enough to be announced as it arrives while the list is open. Anything older
    /// that turns up (records syncing in from the other device after a while) is listed quietly.
    static let freshArrival: TimeInterval = 15 * 60

    /// Something that changed in the list while it was open, for its one VoiceOver announcement.
    enum Change: Hashable {
        /// A new alert went off.
        case arrived(Item)
        /// An alert's outcome moved on: snoozed, "Log treatment" tapped, dismissed.
        case outcome(Item)

        var item: Item {
            switch self {
            case .arrived(let i), .outcome(let i): return i
            }
        }
    }

    /// What changed between two lists, newest first. An item is matched by id, or failing that as
    /// the same alert (the other device's copy turned up first and moved the row's id), so a copy
    /// syncing in never reads as a new alert. Items that left (aged out of the 7 days) are ignored.
    static func changes(from old: [Item], to new: [Item], now: Date) -> [Change] {
        new.compactMap { item in
            let before = old.first { $0.id == item.id }
                ?? old.first { $0.kind == item.kind && abs($0.firedAt.timeIntervalSince(item.firedAt)) <= sameAlert }
            guard let before else {
                return now.timeIntervalSince(item.firedAt) <= freshArrival ? .arrived(item) : nil
            }
            return before.outcome != item.outcome ? .outcome(item) : nil
        }
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

// MARK: - Filters

extension AlertHistory {
    /// Which alerts the history shows (docs/AlertHistory.md, "Filters"). The kind chips split the
    /// alerts with no overlap: Lows and Highs are the alerts about a reading, Predicted the ones
    /// about the forecast (low or high).
    enum KindFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
        case lows, highs, predicted

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lows: return "Lows"
            case .highs: return "Highs"
            case .predicted: return "Predicted"
            }
        }

        var symbol: String {
            switch self {
            case .lows: return "arrow.down"
            case .highs: return "arrow.up"
            case .predicted: return "chart.line.uptrend.xyaxis"
            }
        }

        func matches(_ kind: AlertNotice.Kind) -> Bool {
            let predicted = AlertNotice.Kind.predicted.contains(kind)
            switch self {
            case .lows: return !predicted && kind.treatment == .low
            case .highs: return !predicted && kind.treatment == .high
            case .predicted: return predicted
            }
        }
    }

    /// What was done about an alert, as a chip. Any snooze length counts as snoozed.
    enum OutcomeFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
        case treated, snoozed, dismissed, noResponse

        var id: String { rawValue }

        var title: String {
            switch self {
            case .treated: return "Treated"
            case .snoozed: return "Snoozed"
            case .dismissed: return "Dismissed"
            case .noResponse: return "No response"
            }
        }

        /// What VoiceOver says for the chip: "Treated" only ever means the button was tapped.
        var spoken: String {
            switch self {
            case .treated: return "Tapped Log treatment"
            default: return title
            }
        }

        var symbol: String {
            switch self {
            case .treated: return Outcome.treating.symbol
            case .snoozed: return Outcome.snoozed(minutes: nil).symbol
            case .dismissed: return Outcome.dismissed.symbol
            case .noResponse: return Outcome.noResponse.symbol
            }
        }

        func matches(_ outcome: Outcome) -> Bool {
            switch (self, outcome) {
            case (.treated, .treating), (.snoozed, .snoozed), (.dismissed, .dismissed), (.noResponse, .noResponse):
                return true
            default:
                return false
            }
        }
    }

    /// The chips picked: a kind (All when nil) and an outcome (any when nil), which AND together.
    /// The list follows a pick a moment behind the highlight so it can fade over to its new rows,
    /// as the Logbook's chips do (`LogbookFilterPick`, whose fade timings it shares).
    struct FilterPick: Hashable, Sendable {
        var kind: KindFilter?
        var outcome: OutcomeFilter?

        init(kind: KindFilter? = nil, outcome: OutcomeFilter? = nil) {
            self.kind = kind
            self.outcome = outcome
        }

        static let all = FilterPick()

        var isFiltered: Bool { kind != nil || outcome != nil }

        func matches(_ item: Item) -> Bool {
            (kind?.matches(item.kind) ?? true) && (outcome?.matches(item.outcome) ?? true)
        }

        func apply(_ items: [Item]) -> [Item] {
            isFiltered ? items.filter(matches) : items
        }

        static let fadeOut = LogbookFilterPick.fadeOut
        static let fadeIn = LogbookFilterPick.fadeIn
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

    /// The one VoiceOver announcement for what changed while the list was open, or nil when nothing
    /// did. One change says what it was: "New low alert, 2:14 pm, reading 3.4 mmol/L", "Low alert
    /// at 2:14 pm: Snoozed 30 min". Several are counted: "Alert history: 1 new alert, 2 updated".
    static func announcement(_ changes: [AlertHistory.Change], unit: GlucoseUnit,
                             calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let first = changes.first else { return nil }
        if changes.count == 1 {
            let item = first.item
            let time = ClockLabel.time(item.firedAt, calendar: calendar)
            switch first {
            case .arrived:
                let reading = item.readingMgdl.map { "reading \(unit.format(mgdl: $0, withUnit: true))" } ?? "no reading stored"
                return "New \(item.title.lowercasedFirst), \(time), \(reading)"
            case .outcome:
                return "\(item.title) at \(time): \(item.outcome.text)"
            }
        }
        let arrived = changes.filter { if case .arrived = $0 { return true } else { return false } }.count
        let updated = changes.count - arrived
        var parts: [String] = []
        if arrived > 0 { parts.append(arrived == 1 ? "1 new alert" : "\(arrived) new alerts") }
        if updated > 0 { parts.append("\(updated) updated") }
        return "Alert history: " + parts.joined(separator: ", ")
    }

    /// What VoiceOver says once the list has switched to a new pick of chips: how many alerts it
    /// leaves showing.
    static func filterAnnouncement(count: Int) -> String {
        count == 0 ? "No matching alerts" : self.count(count)
    }

    static let filteredEmptyTitle = "No matching alerts"
    /// Why a filtered list is empty, by what the chips ask for: "No snoozed low alerts in the
    /// last 7 days.", "No unanswered predicted alerts in the last 7 days."
    static func filteredEmptyMessage(_ pick: AlertHistory.FilterPick) -> String {
        "No " + pickPhrase(pick) + " in the last 7 days."
    }

    /// What a pick of chips lets through, mid-sentence: "alerts", "snoozed low alerts",
    /// "unanswered predicted alerts". Also the export's filter line (`AlertHistoryExport`).
    static func pickPhrase(_ pick: AlertHistory.FilterPick) -> String {
        let noun: String
        switch pick.kind {
        case .lows: noun = "low alerts"
        case .highs: noun = "high alerts"
        case .predicted: noun = "predicted alerts"
        case nil: noun = "alerts"
        }
        let adjective: String?
        switch pick.outcome {
        case .treated: adjective = "treated"
        case .snoozed: adjective = "snoozed"
        case .dismissed: adjective = "dismissed"
        case .noResponse: adjective = "unanswered"
        case nil: adjective = nil
        }
        return [adjective, noun].compactMap { $0 }.joined(separator: " ")
    }
    static let showAllButton = "Show All Alerts"
    static let kindChipsLabel = "Alert type"
    static let outcomeChipsLabel = "Outcome"
    static let allChip = "All"

    /// "3 alerts" for a day's header.
    static func count(_ n: Int) -> String { n == 1 ? "1 alert" : "\(n) alerts" }
}

private extension String {
    /// "Low alert" → "low alert", for the middle of a sentence.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
