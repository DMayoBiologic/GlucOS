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
        case .stale, .expired, .none:
            let time = cur.timestamp.formatted(date: .omitted, time: .shortened)
            // Ten minutes on, the calm no-readings words, the same as the chart's gaps.
            if let gap = WidgetGap.state(s, at: now) {
                return WidgetGap.spoken(gap, last: "The last reading was \(value) at \(time).")
            }
            if state == .stale {
                return "Stale. The last reading was \(value), \(age(cur.age(at: now))). Waiting for a new reading."
            }
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
        Int(max(0, interval) / 60) == 0 ? "just now" : duration(interval) + " ago"
    }

    /// "1 minute", "12 minutes", "2 hours 5 minutes": a length of time in whole words.
    static func duration(_ interval: TimeInterval) -> String {
        let m = max(0, Int(interval / 60))
        func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        if m < 60 { return plural(m, "minute") }
        let h = m / 60, rest = m % 60
        return rest == 0 ? plural(h, "hour") : plural(h, "hour") + " " + plural(rest, "minute")
    }
}

// MARK: - No readings

/// The calm "No readings for 12 min" state on the widgets, StandBy, the Lock Screen accessories
/// and the Glucose control, in the same words as the gaps in readings on iPhone Today and the Mac
/// popover (`ReadingGaps`, #388). It starts where a gap does, 10 minutes after the last reading;
/// before that a late reading is only stale. Where GlucOS can tell why, it says so:
///
/// - *Sensor warming up* / *Sensor ended*, from the sensor, as in the chart,
/// - *Can't connect to LibreLinkUp*, when the app's last check failed,
/// - *No signal from LibreLinkUp*, when the app checked for at least half the stretch and
///   LibreLinkUp had nothing newer. A successful check is enough on its own: LibreLinkUp would
///   have handed back any readings in between, so it had none up to then,
/// - *Not checked since 2:40 pm*, when the app hasn't checked for most of it (in the background
///   iOS lets it check about every 15 minutes at best). Readings may be waiting in LibreLinkUp.
///
/// Worked out from the snapshot alone at each timeline entry: no new data, no extra reloads or
/// wakes (§80, docs/ForecastAccuracy.md). Nothing in it moves, so Reduce Motion changes nothing.
enum WidgetGap {
    enum Reason: Hashable, Sendable {
        case warmUp
        case sensorEnded
        case cantConnect
        case noSignal
        /// The app's last successful check, after which nobody has asked LibreLinkUp.
        case notChecked(since: Date)

        /// The full line, where there's room: the chart card's own titles where they apply.
        func title(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
            switch self {
            case .warmUp: return ReadingGaps.Reason.warmUp.title
            case .sensorEnded: return ReadingGaps.Reason.sensorEnded.title
            case .noSignal: return ReadingGaps.Reason.noSignal.title
            case .cantConnect: return "Can't connect to LibreLinkUp"
            case .notChecked(let since):
                return "Not checked since \(ClockLabel.time(since, calendar: calendar, locale: locale))"
            }
        }

        /// A word or two, for the status pill and the Lock Screen.
        var short: String {
            switch self {
            case .warmUp: return "Warming up"
            case .sensorEnded: return "Sensor ended"
            case .noSignal: return "No signal"
            case .cantConnect: return "Can't connect"
            case .notChecked: return "Not checked"
            }
        }

        var systemImage: String {
            switch self {
            case .warmUp: return ReadingGaps.Reason.warmUp.systemImage
            case .sensorEnded: return ReadingGaps.Reason.sensorEnded.systemImage
            case .noSignal: return ReadingGaps.Reason.noSignal.systemImage
            case .cantConnect: return "wifi.exclamationmark"
            case .notChecked: return "arrow.clockwise"
            }
        }

        /// What to do about it, for VoiceOver, where there's something to do.
        var spokenHint: String? {
            switch self {
            case .cantConnect: return "Open GlucOS to reconnect."
            case .notChecked: return "Open GlucOS to check."
            case .warmUp, .sensorEnded, .noSignal: return nil
            }
        }
    }

    struct State: Hashable, Sendable {
        /// The last reading.
        let since: Date
        /// How long there's been none.
        let length: TimeInterval
        /// Nil when GlucOS can't tell: the words just say there are no readings.
        let reason: Reason?
    }

    /// The state starts this long after the last reading: the chart's own gap.
    static var after: TimeInterval { ReadingGaps.minimum }

    /// The state at `now`, or nil while the reading is under 10 minutes old (or there's never been one).
    static func state(_ s: GlucoseSnapshot, at now: Date) -> State? {
        guard let cur = s.current else { return nil }
        let length = now.timeIntervalSince(cur.timestamp)
        guard length >= after else { return nil }
        return State(since: cur.timestamp, length: length, reason: reason(s, from: cur.timestamp, to: now))
    }

    static func reason(_ s: GlucoseSnapshot, from start: Date, to now: Date) -> Reason? {
        // The sensor first, by the chart's rules (an empty record of checks gives nothing else).
        let context = ReadingGaps.Context(sensor: s.sensor, polls: PollLog(), device: .iPhone)
        switch ReadingGaps.reason(from: start, to: now, context: context) {
        case .warmUp: return .warmUp
        case .sensorEnded: return .sensorEnded
        default: break
        }
        if s.lastError != nil { return .cantConnect }
        guard s.fetchedAt > .distantPast else { return nil }
        // The last good check found nothing after `start`, so up to it there was nothing to find.
        let checked = s.fetchedAt.timeIntervalSince(start)
        if checked > 0, checked / now.timeIntervalSince(start) >= ReadingGaps.checkedShare { return .noSignal }
        return .notChecked(since: s.fetchedAt)
    }

    /// "No readings for 12 min", "No readings for 1 hr 5 min".
    static func headline(_ state: State) -> String {
        "No readings for \(ReadingGaps.length(state.length))"
    }

    /// "No readings for 12m", for the Lock Screen's few characters.
    static func compactHeadline(_ state: State) -> String {
        "No readings for \(AccessoryGlance.age(state.length))"
    }

    /// The headline and the reason: "No readings for 12 min · No signal from LibreLinkUp".
    static func line(_ state: State, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        guard let reason = state.reason else { return headline(state) }
        return "\(headline(state)) · \(reason.title(calendar: calendar, locale: locale))"
    }

    /// What VoiceOver hears, the chart's sentence shape: "No readings for 12 minutes: No signal
    /// from LibreLinkUp." (just "No readings for 12 minutes." when the reason isn't known), then
    /// what to do where there's something to do.
    /// `last`, a sentence about the last reading, goes before the hint.
    static func spoken(_ state: State, last: String? = nil, calendar: Calendar = .autoupdatingCurrent,
                       locale: Locale = .autoupdatingCurrent) -> String {
        var out = "No readings for \(WidgetSpeech.duration(state.length))"
        if let reason = state.reason { out += ": " + reason.title(calendar: calendar, locale: locale) }
        out += "."
        if let last { out += " " + last }
        if let hint = state.reason?.spokenHint { out += " " + hint }
        return out
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

    /// The inline accessory (one line above the clock): "6.1 ↗ · 2m", "Stale 6.1 · 8m", then from
    /// 10 minutes "No readings for 12m" (`WidgetGap`). The trend is only drawn while the reading is
    /// fresh.
    static func inline(_ s: GlucoseSnapshot, at now: Date) -> String {
        guard let cur = s.current else { return s.lastError == nil ? "No reading yet" : "Can't connect" }
        let value = s.unit.format(mgdl: cur.mgdl)
        let age = age(cur.age(at: now))
        switch state(s, at: now) {
        case .fresh:
            return cur.trend == .unknown ? "\(value) · \(age)" : "\(value) \(cur.trend.arrow) · \(age)"
        case .stale, .expired, .none:
            if let gap = WidgetGap.state(s, at: now) {
                return s.lastError == nil ? WidgetGap.compactHeadline(gap) : "Can't connect · \(age)"
            }
            return "Stale \(value) · \(age)"
        }
    }

    /// The rectangular accessory's middle line once there have been no readings for 10 minutes:
    /// why, in a word or two ("No signal"), or "No readings" while the number still shows and
    /// the reason isn't known. Nil otherwise (and once withdrawn with no reason, when the bottom
    /// line already says "No readings for 45m").
    static func gapCaption(_ s: GlucoseSnapshot, at now: Date) -> String? {
        guard let gap = WidgetGap.state(s, at: now) else { return nil }
        if let reason = gap.reason { return reason.short }
        return state(s, at: now) == .stale ? "No readings" : nil
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
        return s.lastError == nil ? "No readings for \(age)" : "Can't connect · \(age)"
    }
}

// MARK: - Control Center controls

/// The words the iPhone's Glucose control draws in Control Center and on the Lock Screen
/// (`GlucoseControl`, iOS 18). A control is one short line beside a symbol, drawn by the system,
/// so freshness has to be in the words: a stale reading says "Stale" and its age and drops the
/// trend, a withdrawn one shows no number at all. A control only redraws when the app reloads it
/// (`WidgetReload.Group.controlKinds`), so the age is as of that reload.
enum ControlGlance {
    /// "6.1 ↗ · 2m", "Stale 6.1 · 8m", "No readings for 12m": the same line as the inline
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

// MARK: - StandBy

/// What the Glucose widget draws in StandBy (iPhone charging on its side), where the system shows
/// the small widget large across half the screen with its container background removed. A bedside
/// view: the reading as big as it will go, the trend, a thin range band and one line of words.
/// At night StandBy renders widgets in the vibrant mode and tints them red; `Style.night` keeps
/// every element in one ink and turns its brightness down, so nothing glares in a dark room.
///
/// Every timeline entry draws the same views in the same places, whatever the freshness, and only
/// their contents change, so the per-minute entries roll the figure and words instead of
/// replacing the layout (which is what flickers).
enum StandByGlance {
    enum Style: Equatable {
        /// Full colour, or the tinted rendering if someone has StandBy set that way.
        case day
        /// Night Mode: the system's red, dimmed by us.
        case night
    }

    /// StandBy signals Night Mode only through the rendering mode: vibrant there means night.
    static func style(vibrant: Bool) -> Style { vibrant ? .night : .day }

    /// How bright the main ink is: the figure and the trend.
    static func primaryOpacity(_ style: Style) -> Double { style == .night ? 0.78 : 1 }

    /// How bright the words and the band are, under the figure.
    static func secondaryOpacity(_ style: Style) -> Double { style == .night ? 0.5 : 1 }

    /// The figure: the reading while it can be trusted (fresh or stale), dashes once withdrawn.
    static func value(_ s: GlucoseSnapshot, at now: Date) -> String {
        guard let cur = s.current, showsBand(s, at: now) else { return "––" }
        return s.unit.format(mgdl: cur.mgdl)
    }

    /// The arrow only for a fresh reading with a known trend: an old arrow describes the past.
    static func showsTrend(_ s: GlucoseSnapshot, at now: Date) -> Bool {
        guard let cur = s.current else { return false }
        return AccessoryGlance.state(s, at: now) == .fresh && cur.trend != .unknown
    }

    /// The band under the figure, drawn while there's a value. Grey (stale) unless fresh.
    static func showsBand(_ s: GlucoseSnapshot, at now: Date) -> Bool {
        let state = AccessoryGlance.state(s, at: now)
        return state == .fresh || state == .stale
    }

    /// The one line under the figure: "Rising · 2m", "Stale · 8m", "No readings for 12 min · No
    /// signal" (`WidgetGap`). Ages are
    /// in whole minutes at the entry's date, never a ticking seconds timer, which would be the only
    /// thing moving on a bedside screen.
    static func caption(_ s: GlucoseSnapshot, at now: Date) -> String {
        guard let cur = s.current else { return s.lastError == nil ? "Waiting for GlucOS" : "Open GlucOS to reconnect" }
        let age = AccessoryGlance.age(cur.age(at: now))
        switch AccessoryGlance.state(s, at: now) {
        case .fresh:
            return cur.trend == .unknown ? age : "\(cur.trend.description) · \(age)"
        case .stale, .expired, .none:
            // Ten minutes on: "No readings for 12 min · No signal", the reason in a word or two
            // so the line still fits across the bedside view.
            if let gap = WidgetGap.state(s, at: now) {
                if gap.reason == .cantConnect { return "Can't connect · \(ReadingGaps.length(gap.length))" }
                return gap.reason.map { "\(WidgetGap.headline(gap)) · \($0.short)" } ?? WidgetGap.headline(gap)
            }
            return "Stale · \(age)"
        }
    }
}
