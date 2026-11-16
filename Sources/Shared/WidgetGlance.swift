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

// MARK: - Your usual, for the widget

/// A "Your usual" entry (`UsualEntry`, Sources/Engine/UsualEntries.swift) as the Your usual widget
/// draws it. The app works the entries out and writes them into `GlucoseSnapshot.usuals`, words and
/// all, because the widget extension doesn't compile Sources/Engine. The widget's buttons only open
/// the log sheet on that entry (`OpenUsualIntent`): nothing is ever logged from the widget.
struct UsualGlance: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable { case meal, correction, low }

    /// `UsualEntry.id`: "meal-breakfast", "correction", "low". What the log sheet looks up on open.
    var id: String
    var kind: Kind
    /// "Usual breakfast", "Usual correction", "Treat a low".
    var title: String
    /// "Toast and banana · 45 g", "2 u NovoRapid", "Jelly beans · 15 g".
    var detail: String
    var systemImage: String
    /// "Usual breakfast: toast and banana, 45 grams of carbs".
    var spoken: String
    /// A meal is only offered in its part of the day: the end of that part (11:00 for breakfast).
    /// Nil for the others.
    var until: Date? = nil

    /// The most the widget shows, the same as the Mac popover's row.
    static let limit = 3

    /// The Mac widget's button for this entry: `glucos://log/usual/<id>`. The Mac widget extension
    /// is sandboxed with read-only access to the app's folder and no app group, so an App Intent
    /// run there has no way to hand the entry to the app. A link opens GlucOS, which opens the log
    /// window on it (AppDelegate). The iPhone widget uses `OpenUsualIntent` instead.
    var openURL: URL {
        var c = URLComponents()
        c.scheme = "glucos"
        c.host = "log"
        c.path = "/usual/" + id
        return c.url ?? URL(string: "glucos://log")!
    }

    /// The entry id in a `openURL` link, or nil for any other link.
    static func usualID(from url: URL) -> String? {
        guard url.scheme == "glucos", url.host == "log" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "usual", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// The entries to draw at `now`. The widget runs no code between timeline entries, so it drops
    /// what the app would no longer offer: a correction once the reading it was worked out from goes
    /// stale (it's only offered on a fresh high), and a meal once its part of the day is over. The
    /// sheet works them out again on open anyway.
    static func visible(_ usuals: [UsualGlance], readingFresh: Bool, at now: Date) -> [UsualGlance] {
        Array(usuals.filter { u in
            if u.kind == .correction && !readingFresh { return false }
            if let until = u.until, until <= now { return false }
            return true
        }.prefix(limit))
    }

    /// When what `visible` shows next changes on its own: a meal's part of the day ending, the
    /// reading going stale while a correction shows. The widget's timeline has an entry at each.
    static func changeDates(_ usuals: [UsualGlance], staleAt: Date?, after now: Date) -> [Date] {
        var dates = usuals.compactMap(\.until)
        if let staleAt, usuals.contains(where: { $0.kind == .correction }) { dates.append(staleAt) }
        return Array(Set(dates.filter { $0 > now })).sorted()
    }
}

// MARK: - Spoken reading

/// The reading as VoiceOver says it on a widget, matched to what's drawn: a stale reading is never
/// read with its range or trend (neither is shown), and a withdrawn one says when the last was.
enum WidgetSpeech {
    enum State: Hashable { case fresh, stale, expired, none }

    /// After this long the widgets withdraw the number (`ReadingFreshness.expired`).
    static let expiredAfter: TimeInterval = 30 * 60

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
            var out = parts.joined(separator: ", ") + "."
            if let back = s.backInRange(at: now) { out += " " + BackInRangeText.spoken(minutes: back.minutes) + "." }
            return out
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

// MARK: - Lock Screen accessories

/// The words the Lock Screen accessories draw, worked out here so they can be tested. The
/// accessories are monochrome and tiny, so every freshness state says itself in text or a symbol,
/// never only by tint: a stale figure is struck through and names its age, and a withdrawn one
/// (`expired`) shows no number at all, only how long there's been none.
enum AccessoryGlance {
    /// The freshness state at `now`, with the same edges as the Home Screen widget
    /// (`ReadingFreshness`): stale after `GlucoseSnapshot.staleAfter`, withdrawn after
    /// `expiredAfter`.
    static func state(_ s: GlucoseSnapshot, at now: Date) -> WidgetSpeech.State {
        guard let cur = s.current else { return .none }
        let age = cur.age(at: now)
        if age > WidgetSpeech.expiredAfter { return .expired }
        return age > GlucoseSnapshot.staleAfter ? .stale : .fresh
    }

    /// "now", "4m", "1h 5m", "3h", "2d". `compact` drops the minutes after the first hour, for the
    /// circular accessory, which has room for about four characters.
    static func age(_ interval: TimeInterval, compact: Bool = false) -> String {
        let m = max(0, Int(interval / 60))
        if m == 0 { return "now" }
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h >= 24 { return "\(h / 24)d" }
        return compact || m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m"
    }

    /// The inline accessory (one line above the clock): "6.1 ↗ · 2m", "Stale 6.1 · 12m",
    /// "No reading for 45m". The trend is only drawn while the reading is fresh.
    static func inline(_ s: GlucoseSnapshot, at now: Date) -> String {
        guard let cur = s.current else { return s.lastError == nil ? "No reading yet" : "Can't connect" }
        let value = s.unit.format(mgdl: cur.mgdl)
        let age = age(cur.age(at: now))
        switch state(s, at: now) {
        case .fresh:
            return cur.trend == .unknown ? "\(value) · \(age)" : "\(value) \(cur.trend.arrow) · \(age)"
        case .stale:
            return "Stale \(value) · \(age)"
        case .expired, .none:
            return s.lastError == nil ? "No reading for \(age)" : "Can't connect · \(age)"
        }
    }

    /// What sits under the figure on the circular accessory instead of the trend arrow, once the
    /// reading isn't fresh: its age, "12m". Nil while fresh (the arrow shows, and the ring around
    /// it empties over the reading's life) and when there has never been a reading.
    static func circularCaption(_ s: GlucoseSnapshot, at now: Date) -> String? {
        guard let cur = s.current, state(s, at: now) != .fresh else { return nil }
        return age(cur.age(at: now), compact: true)
    }

    /// The rectangular accessory's bottom line once the number is withdrawn or was never there.
    /// Nil while there's a reading to show (fresh or stale), which draws a ticking age instead.
    static func withdrawnLine(_ s: GlucoseSnapshot, at now: Date) -> String? {
        guard let cur = s.current else { return s.lastError == nil ? "Waiting for GlucOS" : "Open GlucOS to reconnect" }
        guard state(s, at: now) == .expired else { return nil }
        let age = age(cur.age(at: now))
        return s.lastError == nil ? "No reading for \(age)" : "Can't connect · \(age)"
    }
}

// MARK: - Control Center controls

/// The words the iPhone's Glucose control draws in Control Center and on the Lock Screen
/// (`GlucoseControl`, iOS 18). A control is one short line beside a symbol, drawn by the system,
/// so freshness has to be in the words: a stale reading says "Stale" and its age and drops the
/// trend, a withdrawn one shows no number at all. A control only redraws when the app reloads it
/// (`WidgetReload.Group.controlKinds`), so the age is as of that reload.
enum ControlGlance {
    /// "6.1 ↗ · 2m", "Stale 6.1 · 12m", "No reading for 45m": the same line as the inline
    /// Lock Screen accessory.
    static func title(_ s: GlucoseSnapshot, at now: Date) -> String {
        AccessoryGlance.inline(s, at: now)
    }

    /// The control's symbol: a drop while fresh, a clock once stale, a slashed drop once the number
    /// is withdrawn or there's never been one. Never a colour alone.
    static func symbol(_ s: GlucoseSnapshot, at now: Date) -> String {
        switch AccessoryGlance.state(s, at: now) {
        case .fresh: return "drop.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .expired, .none: return "drop.degreesign.slash"
        }
    }

    /// What VoiceOver reads for the control: the widgets' words (`WidgetSpeech.reading`), then what
    /// a tap does.
    static func spoken(_ s: GlucoseSnapshot, at now: Date) -> String {
        WidgetSpeech.reading(s, state: AccessoryGlance.state(s, at: now), at: now) + " Opens Today in GlucOS."
    }

    /// VoiceOver for the Log treatment control, which never logs by itself.
    static let treatmentSpoken = "Log treatment. Opens the GlucOS log sheet for treating a low. Nothing is logged until you tap Log."
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
        /// Your usual (iPhone and Mac), which changes only with the logbook, the time of day and a high.
        case usual

        var kinds: [String] {
            switch self {
            case .glucose: return ["au.com.declanmayo.glucos.glucose", "au.com.declanmayo.glucos.accessory"]
            case .insights: return ["au.com.declanmayo.glucos.time-in-range", "au.com.declanmayo.glucos.sensor"]
            case .usual: return ["au.com.declanmayo.glucos.usual"]
            }
        }

        /// The iPhone's Control Center and Lock Screen controls this group redraws
        /// (`ControlCenter.reloadControls(ofKind:)`). Only the Glucose control reads the snapshot;
        /// the Log treatment control is a fixed button and never needs a reload.
        var controlKinds: [String] {
            switch self {
            case .glucose: return [ControlKind.glucose]
            case .insights, .usual: return []
            }
        }
    }

    /// The control kinds, shared by the widget extension that draws them and the app that reloads
    /// them.
    enum ControlKind {
        static let glucose = "au.com.declanmayo.glucos.control.glucose"
        static let lowTreatment = "au.com.declanmayo.glucos.control.low-treatment"
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
        // Your usual.
        var usuals: [UsualGlance]?
        /// The reading went stale, which hides a usual correction (`UsualGlance.visible`).
        var readingStaleAt: Date?
    }

    /// The forecast as the widget shows it: the headline value to 1 mg/dL, the low warning to the
    /// minute, insulin to 0.1 U, carbs to the gram.
    struct OutlookKey: Hashable {
        var issuedAt: Date
        var headline: Int?
        var lowAt: Int?
        /// "Back in range ≈ X min", to the minute: its appearing, moving or going reloads.
        var backAt: Int?
        var insulin: Int?
        var carbs: Int?
        var caveat: ForecastCaveat?
    }

    static func signature(_ s: GlucoseSnapshot) -> Signature {
        let outlook = s.outlook.map { o in
            OutlookKey(issuedAt: o.issuedAt,
                       headline: o.forecast.last.map { Int($0.mgdl.rounded()) },
                       lowAt: o.lowExpectedAt.map { Int($0.timeIntervalSince1970 / 60) },
                       backAt: o.backInRangeAt.map { Int($0.timeIntervalSince1970 / 60) },
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
                         sensorSerial: s.sensor?.serial, sensorActivated: s.sensor?.activated,
                         usuals: s.usuals,
                         readingStaleAt: s.current.map { $0.timestamp.addingTimeInterval(GlucoseSnapshot.staleAfter) })
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
        // A new reading only matters to Your usual when a correction is showing: it moves the time
        // the widget hides it. Otherwise only the entries themselves reload it.
        let showsCorrection = (new.usuals ?? []).contains { $0.kind == .correction }
        if old.usuals != new.usuals || (showsCorrection && old.readingStaleAt != new.readingStaleAt) {
            out.insert(.usual)
        }
        return out
    }
}
