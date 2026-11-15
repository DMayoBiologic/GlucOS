import Foundation

// Low and high alerts in the logbook (docs/AlertLog.md). Each time one goes off, the device that
// showed it keeps a small record: when, which alert, and what was tapped on it ("Snooze 30 min",
// "I'm treating it", or nothing). The records sync between the Mac and the iPhone with the rest of
// the logbook, and the Logbook shows them as quiet rows between the entries.
//
// They are a record of what the phone or Mac said, never something the user did, so they live
// apart from doses, food, site changes and moments (`LogEntry`). Nothing that reads the logbook's
// entries (the forecast, insulin on board, the double-dose check, "Did you treat this low?", the
// insights, the follower page) ever sees them. Plain Foundation so it's unit-tested.

/// One low or high alert that went off on this device.
struct AlertRecord: Codable, Identifiable, Hashable {
    /// What was tapped on the alert.
    enum Response: String, Codable, Hashable {
        /// "Snooze 30 min".
        case snoozed
        /// "I'm treating it". Opens the log sheet; only what the user then logs is a treatment.
        case treating
        /// Written by a newer version in a way this one doesn't know: shown as no response.
        case other

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Response(rawValue: raw) ?? .other
        }
    }

    var id = UUID()
    /// `AlertNotice.Kind.rawValue`. Kept as text so a kind a newer version adds still decodes.
    var kind: String
    /// When the alert went off (the notification's time).
    var firedAt: Date
    var response: Response?
    /// When the button was tapped.
    var respondedAt: Date?
    /// How long it quieted the alert for. Nil for an urgent low, which is never quieted.
    var snoozeMinutes: Int?

    init(id: UUID = UUID(), kind: AlertNotice.Kind, firedAt: Date, response: Response? = nil,
         respondedAt: Date? = nil, snoozeMinutes: Int? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.firedAt = firedAt
        self.response = response
        self.respondedAt = respondedAt
        self.snoozeMinutes = snoozeMinutes
    }

    var alertKind: AlertNotice.Kind? { AlertNotice.Kind(rawValue: kind) }
}

enum AlertLog {
    /// How long records are kept, like the readings.
    static let keptFor: TimeInterval = 90 * 86_400
    /// The same notification seen twice (shown while open, then found again in Notification
    /// Center, or tapped) is one alert.
    static let sameAlert: TimeInterval = 90
    /// Alerts of the same kind of excursion this close together are one row: the repeats of a
    /// low every 15 minutes, a forecast low that then arrives, or the Mac and iPhone both alerting.
    static let rowGap: TimeInterval = 45 * 60

    /// Only low and high alerts are kept: the ones with buttons. Rapid change, no data, the sensor
    /// and the connection aren't about glucose the user can act on.
    static func isLogged(_ kind: AlertNotice.Kind) -> Bool { kind.treatment != nil }

    /// Adds a record for an alert that just went off. Nothing changes (nil) for an alert that isn't
    /// logged or one already recorded.
    static func fired(_ kind: AlertNotice.Kind, at time: Date, in records: [AlertRecord]) -> AlertRecord? {
        guard isLogged(kind), match(kind, at: time, in: records) == nil else { return nil }
        return AlertRecord(kind: kind, firedAt: time)
    }

    /// The record a tap on the alert that went off at `time` answers, updated with the tap. A new
    /// record when this device hadn't seen it yet (a push that arrived while the app was closed).
    /// `snoozeMinutes` is how long the tap quieted the alert (nil for an urgent low).
    static func responded(_ kind: AlertNotice.Kind, _ response: AlertRecord.Response, snoozeMinutes: Int?,
                          firedAt time: Date, at now: Date, in records: [AlertRecord]) -> AlertRecord? {
        guard isLogged(kind) else { return nil }
        var r = match(kind, at: time, in: records).map { records[$0] }
            ?? AlertRecord(kind: kind, firedAt: min(time, now))
        r.response = response
        r.respondedAt = now
        r.snoozeMinutes = snoozeMinutes
        return r
    }

    /// The records older than `keptFor`.
    static func expired(_ records: [AlertRecord], now: Date) -> [AlertRecord] {
        records.filter { now.timeIntervalSince($0.firedAt) > keptFor }
    }

    private static func match(_ kind: AlertNotice.Kind, at time: Date, in records: [AlertRecord]) -> Int? {
        records.firstIndex { $0.kind == kind.rawValue && abs($0.firedAt.timeIntervalSince(time)) <= sameAlert }
    }

    // MARK: Rows

    /// The Logbook's alert rows, newest first: each low or high spell's alerts folded into one.
    static func rows(_ records: [AlertRecord]) -> [AlertLogRow] {
        let known = records.compactMap { r in r.alertKind.flatMap { k in k.treatment.map { (r, k, $0) } } }
            .sorted { $0.0.firedAt < $1.0.firedAt }
        var open: [AlertTreatment: [(AlertRecord, AlertNotice.Kind)]] = [:]
        var out: [AlertLogRow] = []
        for (r, kind, side) in known {
            if let group = open[side], let last = group.last, r.firedAt.timeIntervalSince(last.0.firedAt) > rowGap {
                out.append(AlertLogRow(group))
                open[side] = nil
            }
            open[side, default: []].append((r, kind))
        }
        out += open.values.map { AlertLogRow($0) }
        return out.sorted { $0.timestamp > $1.timestamp }
    }
}

/// One row in the Logbook: a low or high spell's alerts, from the first to the last, and what was
/// tapped on them.
struct AlertLogRow: Identifiable, Hashable {
    /// The first record's id, so the row keeps its identity as repeats are added.
    let id: UUID
    /// The most serious alert in the row: a real reading over a forecast, urgent over plain.
    let kind: AlertNotice.Kind
    let first: Date
    let last: Date
    /// How many times it went off (across devices, the same alert counts once per device).
    let count: Int
    /// What was tapped: "I'm treating it" if it ever was, else a snooze, else nothing.
    let response: AlertRecord.Response?
    let respondedAt: Date?
    let snoozeMinutes: Int?

    /// Where the row sits in time: when it first went off.
    var timestamp: Date { first }

    fileprivate init(_ group: [(AlertRecord, AlertNotice.Kind)]) {
        let records = group.map { $0.0 }
        id = records[0].id
        kind = group.map { $0.1 }.min { Self.rank($0) < Self.rank($1) } ?? group[0].1
        first = records[0].firedAt
        last = records[records.count - 1].firedAt
        // The Mac and the iPhone each record the alert they showed: one alert, not two. A forecast
        // low and the real low moments later are two alerts, so the kind is part of the match.
        var seen: [(String, Date)] = []
        for r in records where !seen.contains(where: { $0.0 == r.kind && abs($0.1.timeIntervalSince(r.firedAt)) <= AlertLog.sameAlert * 2 }) {
            seen.append((r.kind, r.firedAt))
        }
        count = seen.count
        let tapped = records.filter { $0.response == .treating }.last ?? records.filter { $0.response == .snoozed }.last
        response = tapped?.response
        respondedAt = tapped?.respondedAt
        snoozeMinutes = tapped?.snoozeMinutes
    }

    /// Lower is more serious.
    private static func rank(_ k: AlertNotice.Kind) -> Int {
        switch k {
        case .urgentLow, .veryHigh: return 0
        case .low, .high: return 1
        case .predictedUrgentLow, .predictedVeryHigh: return 2
        case .predictedLow, .predictedHigh: return 3
        default: return 4
        }
    }

    var isLow: Bool { kind.treatment == .low }

    /// "Urgent low alert", "Predicted high alert".
    var title: String {
        switch kind {
        case .urgentLow: return "Urgent low alert"
        case .low: return "Low alert"
        case .predictedUrgentLow: return "Predicted urgent low alert"
        case .predictedLow: return "Predicted low alert"
        case .veryHigh: return "Very high alert"
        case .high: return "High alert"
        case .predictedVeryHigh: return "Predicted very high alert"
        case .predictedHigh: return "Predicted high alert"
        default: return "Alert"
        }
    }

    /// "Snoozed 30 min", "I'm treating it", "No response".
    var responseText: String {
        switch response {
        case .snoozed: return snoozeMinutes.map { "Snoozed \($0) min" } ?? "Snoozed"
        case .treating: return "I'm treating it"
        case .other, nil: return "No response"
        }
    }

    /// "Went off 3 times" when it repeated. Nil for one alert.
    var repeatText: String? {
        count > 1 ? "Went off \(count) times" : nil
    }

    /// What a search matches.
    var searchText: String { "\(title) alert \(responseText)" }
}
