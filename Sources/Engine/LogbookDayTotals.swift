import Foundation

/// What a Logbook day holds, for its header: insulin logged (units), carbs logged (grams) and how
/// many entries. Kept free of SwiftUI and of the Logbook's own models so it can be unit-tested; the
/// app fills it from the day's entries (`LogbookDayTotals(_:)` in DayTotalsLabel.swift).
///
/// Display only. These are the same sums the header already showed as text: nothing here works
/// out a dose, and nothing feeds any calculation.
struct LogbookDayTotals: Hashable, Sendable {
    var units: Double = 0
    var carbs: Double = 0
    var entries: Int = 0

    /// Whether the header's figures should roll downward going from `old` to this: the day lost
    /// an entry, or (with the same count) holds fewer carbs, or the same carbs and fewer units.
    func countsDown(from old: LogbookDayTotals) -> Bool {
        if entries != old.entries { return entries < old.entries }
        if carbs != old.carbs { return carbs < old.carbs }
        return units < old.units
    }
}

/// How a day header's totals change on screen when an entry is added, edited, deleted or undone.
enum DayTotalsRoll: Equatable, Sendable {
    /// Nothing to move: the totals are the same, or this is the first time the day is seen.
    case none
    /// The digits roll to the new totals on the `.arrival` spring; `countsDown` when the day
    /// holds less than it did.
    case roll(countsDown: Bool)
    /// Reduce Motion: the new totals replace the old at once.
    case instant

    static func between(_ old: LogbookDayTotals?, _ new: LogbookDayTotals, reduceMotion: Bool) -> DayTotalsRoll {
        guard let old, old != new else { return .none }
        if reduceMotion { return .instant }
        return .roll(countsDown: new.countsDown(from: old))
    }

    var announces: Bool { self != .none }
}

enum DayTotalsText {
    /// "4", "4.5", "0.35": up to two decimals, no trailing zeros, whatever the locale.
    static func number(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    /// "14 units, 120 grams of carbs, 4 entries": only what was logged, and always the count.
    static func summary(_ t: LogbookDayTotals) -> String {
        var parts: [String] = []
        if t.units > 0 { parts.append("\(number(t.units)) \(t.units == 1 ? "unit" : "units")") }
        if t.carbs > 0 { parts.append("\(number(t.carbs)) \(t.carbs == 1 ? "gram" : "grams") of carbs") }
        switch t.entries {
        case 0: parts.append("no entries")
        case 1: parts.append("1 entry")
        default: parts.append("\(t.entries) entries")
        }
        return parts.joined(separator: ", ")
    }

    /// Said once when a day's totals change: "Today now 14 units, 120 grams of carbs, 4 entries".
    static func announcement(day: String, _ t: LogbookDayTotals) -> String {
        "\(day) now \(summary(t))"
    }
}

/// Remembers, per day, the totals (and the text) its header last showed, so a header the list
/// rebuilt (the Mac's day cell moves to a new first row when a newer entry joins the day; the
/// iPhone's pinned headers are rebuilt as they scroll) starts from the old figures and rolls to the
/// new ones, rather than jumping. It also spaces VoiceOver announcements out, so one change says
/// its new totals once, however many copies of the header see it.
///
/// Held by the Logbook screen for as long as it's open, like `DrawnOnce`: the first time a day is
/// seen there is nothing to roll from, so opening the Logbook never rolls or speaks.
final class DayTotalsMemory {
    private var shown: [String: (totals: LogbookDayTotals, text: String)] = [:]
    private var lastAnnounced: Date?

    /// How long after one announcement another one is held back: a sync or an undo that touches
    /// several days at once says only the first.
    static let announceGap: TimeInterval = 1.5

    func lastText(_ id: String) -> String? { shown[id]?.text }
    func lastTotals(_ id: String) -> LogbookDayTotals? { shown[id]?.totals }

    /// Records what the header shows now and gives back the totals it showed before (nil the
    /// first time this day is seen).
    @discardableResult
    func record(_ id: String, totals: LogbookDayTotals, text: String) -> LogbookDayTotals? {
        let old = shown[id]?.totals
        shown[id] = (totals, text)
        return old
    }

    /// True if nothing was announced in the last `announceGap` seconds, and counts this one.
    func mayAnnounce(at now: Date) -> Bool {
        if let last = lastAnnounced, now.timeIntervalSince(last) < Self.announceGap, now >= last { return false }
        lastAnnounced = now
        return true
    }
}
