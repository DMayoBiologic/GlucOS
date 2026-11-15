import Foundation

// What the Home Screen widgets need beyond the reading itself, worked out by the app so the widget
// extension stays small: the Today so far figures, the words VoiceOver reads for each freshness
// state, and which widget timelines a new snapshot actually changes. Plain Foundation, unit-tested.

// MARK: - Today so far, for the widget

/// `TodaySoFar` as the large widget shows it. The app works it out (Sources/Engine is not in the
/// widget extension) and writes it into `GlucoseSnapshot.today`; the words are filled in by the
/// app too, so the widget and the iPhone card say exactly the same thing.
struct TodayGlance: Codable, Hashable {
    /// Local midnight of the day the figures are for. The widget hides them once that day is over.
    var day: Date
    /// "Midnight to 2:30 pm".
    var period: String
    /// "More time in range than your usual day by now."
    var headline: String
    var timeInRange: Double
    var meanMgdl: Double
    var lows: Int
    /// "Usually 72%", nil until there are enough earlier days to compare with.
    var rangeCaption: String?
    var meanCaption: String?
    var lowsCaption: String?
    /// The whole strip in a few sentences, for VoiceOver.
    var spoken: String

    func isCurrent(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }
}

// MARK: - Spoken reading

/// The reading as VoiceOver says it on a widget, matched to what's drawn: a stale reading is never
/// read with its range or trend (neither is shown), and a withdrawn one says when the last was.
enum WidgetSpeech {
    enum State: Hashable { case fresh, stale, expired, none }

    static func reading(_ s: GlucoseSnapshot, state: State, at now: Date) -> String {
        let unit = s.unit
        guard let cur = s.current else {
            return s.lastError == nil ? "No glucose reading yet. Waiting for GlucOS."
                                      : "Can't connect. Open GlucOS to reconnect."
        }
        let value = "\(unit.format(mgdl: cur.mgdl)) \(unitWords(unit))"
        switch state {
        case .fresh:
            var parts = ["Glucose \(value)"]
            if let range = s.range { parts.append(range.spokenLabel) }
            if cur.trend != .unknown { parts.append(cur.trend.description.lowercased()) }
            if let d = s.deltaMgdl {
                parts.append("change \(unit.formatDelta(mgdl: d).replacingOccurrences(of: "−", with: "minus "))")
            }
            parts.append(age(cur.age(at: now)))
            return parts.joined(separator: ", ") + "."
        case .stale:
            return "Stale. The last reading was \(value), \(age(cur.age(at: now))). Waiting for a new reading."
        case .expired, .none:
            let time = cur.timestamp.formatted(date: .omitted, time: .shortened)
            let tail = s.lastError == nil ? "" : " Can't connect. Open GlucOS to reconnect."
            return "No recent reading. The last was \(value) at \(time).\(tail)"
        }
    }

    /// The same words as `GlucoseUnit.spokenLabel`, which lives with the SwiftUI styling.
    static func unitWords(_ unit: GlucoseUnit) -> String {
        unit == .mmol ? "millimoles per litre" : "milligrams per decilitre"
    }

    /// "just now", "1 minute ago", "12 minutes ago", "2 hours 5 minutes ago": whole words, because
    /// VoiceOver reads the drawn "12m" as metres.
    static func age(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval / 60))
        if m == 0 { return "just now" }
        func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        if m < 60 { return plural(m, "minute") + " ago" }
        let h = m / 60, rest = m % 60
        return (rest == 0 ? plural(h, "hour") : plural(h, "hour") + " " + plural(rest, "minute")) + " ago"
    }
}

// MARK: - Reload planning

/// Which widget timelines a new snapshot changes, so the app reloads only those (power audit, #94).
/// The app publishes on every fetch, logbook edit, forecast relearn and settings change; most of
/// those leave every widget exactly as it was, and each reload wakes the widget extension, and in
/// the background spends WidgetKit's daily budget.
enum WidgetReload {
    enum Group: Hashable, CaseIterable {
        /// The Glucose widget (every Home Screen size) and the Lock Screen accessories.
        case glucose
        /// Time in Range and Sensor, which summarise hours or days and read the 90-day archive.
        case insights

        var kinds: [String] {
            switch self {
            case .glucose: return ["au.com.declanmayo.glucos.glucose", "au.com.declanmayo.glucos.accessory"]
            case .insights: return ["au.com.declanmayo.glucos.time-in-range", "au.com.declanmayo.glucos.sensor"]
            }
        }
    }

    /// Everything a widget draws from the snapshot, rounded to what's visible.
    struct Signature: Hashable {
        // Shared by both groups.
        var unit: GlucoseUnit
        var lowMgdl: Double
        var highMgdl: Double
        // Glucose.
        var readingAt: Date?
        var mgdl: Double?
        var trend: Trend?
        var historyCount: Int
        var historyNewest: Date?
        var failing: Bool
        /// "Updated 4m ago" on the extra large size, to the nearest 10 minutes.
        var fetchedSlot: Int
        var outlook: OutlookKey?
        var today: TodayGlance?
        // Insights.
        /// The newest reading's 15-minute slot: the summaries move by a reading at most per slot.
        var readingSlot: Int?
        var sensorSerial: String?
        var sensorActivated: Date?
    }

    /// The forecast as the widget shows it: the headline value to 1 mg/dL, the low warning to the
    /// minute, insulin to 0.1 U, carbs to the gram.
    struct OutlookKey: Hashable {
        var issuedAt: Date
        var headline: Int?
        var lowAt: Int?
        var insulin: Int?
        var carbs: Int?
        var caveat: ForecastCaveat?
    }

    static func signature(_ s: GlucoseSnapshot) -> Signature {
        let outlook = s.outlook.map { o in
            OutlookKey(issuedAt: o.issuedAt,
                       headline: o.forecast.last.map { Int($0.mgdl.rounded()) },
                       lowAt: o.lowExpectedAt.map { Int($0.timeIntervalSince1970 / 60) },
                       insulin: o.insulinOnBoard.map { Int(($0 * 10).rounded()) },
                       carbs: o.carbsOnBoard.map { Int($0.rounded()) },
                       caveat: o.caveat)
        }
        return Signature(unit: s.unit, lowMgdl: s.lowMgdl, highMgdl: s.highMgdl,
                         readingAt: s.current?.timestamp, mgdl: s.current?.mgdl, trend: s.current?.trend,
                         historyCount: s.history.count, historyNewest: s.history.last?.timestamp,
                         failing: s.lastError != nil,
                         fetchedSlot: Int(s.fetchedAt.timeIntervalSince1970 / 600),
                         outlook: outlook, today: s.today,
                         readingSlot: s.current.map { Int($0.timestamp.timeIntervalSince1970 / 900) },
                         sensorSerial: s.sensor?.serial, sensorActivated: s.sensor?.activated)
    }

    /// The groups to reload going from `old` to `new`. Everything on the first publish.
    static func groups(from old: Signature?, to new: Signature) -> Set<Group> {
        guard let old else { return Set(Group.allCases) }
        var out = Set<Group>()
        let settings = old.unit != new.unit || old.lowMgdl != new.lowMgdl || old.highMgdl != new.highMgdl
        if settings || old.readingAt != new.readingAt || old.mgdl != new.mgdl || old.trend != new.trend
            || old.historyCount != new.historyCount || old.historyNewest != new.historyNewest
            || old.failing != new.failing || old.fetchedSlot != new.fetchedSlot
            || old.outlook != new.outlook || old.today != new.today {
            out.insert(.glucose)
        }
        if settings || old.readingSlot != new.readingSlot
            || old.sensorSerial != new.sensorSerial || old.sensorActivated != new.sensorActivated {
            out.insert(.insights)
        }
        return out
    }
}
