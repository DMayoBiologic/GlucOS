import Foundation
import AppKit

// Derived values the popover and the status item show. Pure functions of the snapshot and the
// on-disk archive, so they're cheap to recompute on every render.

/// How long the reading has stayed in its current range, e.g. "In range for 2h 10m".
struct RangeStreak: Equatable {
    let range: GlucoseRange
    let duration: TimeInterval
    /// True when the streak reaches back to the oldest reading available, so the real duration
    /// could be longer.
    let isOpenEnded: Bool
}

extension GlucoseSnapshot {
    /// The current range's streak, walking back through history until the range changes or the
    /// data has a gap (sensor warm-up, phone out of signal). Nil when stale or unknown, since a
    /// streak ending at an old reading would mislead.
    func rangeStreak(at now: Date = Date()) -> RangeStreak? {
        guard let current, let range, !isStale(at: now) else { return nil }
        var points = history.filter { $0.timestamp < current.timestamp }
        points.append(current)
        points.sort { $0.timestamp < $1.timestamp }

        let maxGap: TimeInterval = 20 * 60
        var start = current.timestamp
        var newer = current.timestamp
        var reachedOldest = true
        for r in points.reversed().dropFirst() {
            if newer.timeIntervalSince(r.timestamp) > maxGap { reachedOldest = false; break }
            if GlucoseRange.classify(mgdl: r.mgdl, low: lowMgdl, high: highMgdl) != range { reachedOldest = false; break }
            start = r.timestamp
            newer = r.timestamp
        }
        return RangeStreak(range: range, duration: current.timestamp.timeIntervalSince(start),
                           isOpenEnded: reachedOldest && points.count > 1)
    }

    /// Plain-text summary for the clipboard, e.g. "6.1 mmol/L, Rising (+0.3) at 3:41 pm".
    func clipboardSummary(at now: Date = Date()) -> String? {
        guard let current else { return nil }
        var text = unit.format(mgdl: current.mgdl, withUnit: true)
        var trendPart = current.trend == .unknown ? "" : current.trend.description
        if let d = deltaMgdl { trendPart += trendPart.isEmpty ? unit.formatDelta(mgdl: d) : " (\(unit.formatDelta(mgdl: d)))" }
        if !trendPart.isEmpty { text += ", \(trendPart)" }
        text += " at \(current.timestamp.formatted(date: .omitted, time: .shortened))"
        if isStale(at: now) { text += " (stale, \(PopoverFormat.age(current.age(at: now))) old)" }
        return text
    }
}

enum PopoverFormat {
    /// Live age with seconds under a minute: "12s ago", "4m ago", "1h 5m ago".
    static func ageAgo(_ interval: TimeInterval) -> String {
        if interval < 5 { return "just now" }
        return "\(age(interval)) ago"
    }

    /// "12s", "4m", "1h 5m", "2d".
    static func age(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return "\(h / 24)d"
    }

    /// "25m", "2h 10m". Minutes are exact (no 5-minute rounding) so a fresh low reads "for 3m".
    static func streak(_ interval: TimeInterval) -> String {
        let m = Int(interval / 60)
        if m < 60 { return "\(max(1, m))m" }
        let h = m / 60
        return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m"
    }

    /// Spoken form of `streak`, for VoiceOver.
    static func spokenStreak(_ interval: TimeInterval) -> String {
        let m = Int(interval / 60)
        if m < 60 { return "\(max(1, m)) minutes" }
        let h = m / 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        return m % 60 == 0 ? hours : "\(hours) \(m % 60) minutes"
    }
}

// MARK: - Stats windows

/// The period the popover's "At a glance" card summarises. Uses the on-disk archive, so 7 and 14
/// days are available even though LibreLinkUp itself only returns 12 hours.
enum GlanceWindow: Int, CaseIterable, Identifiable {
    case day = 24
    case week = 168
    case fortnight = 336

    var id: Int { rawValue }
    var hours: Double { Double(rawValue) }

    var shortLabel: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .fortnight: return "14d"
        }
    }

    var spokenLabel: String {
        switch self {
        case .day: return "last 24 hours"
        case .week: return "last 7 days"
        case .fortnight: return "last 14 days"
        }
    }

    var menuLabel: String {
        switch self {
        case .day: return "Last 24 Hours"
        case .week: return "Last 7 Days"
        case .fortnight: return "Last 14 Days"
        }
    }
}

extension GlucoseStore {
    /// Readings from the archive (plus anything newer in the live snapshot) within `hours`.
    func readings(lastHours hours: Double, now: Date = Date()) -> [GlucoseReading] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        var out = archive.filter { $0.timestamp >= cutoff }
        let newest = out.last?.timestamp ?? .distantPast
        var live = snapshot.history
        if let c = snapshot.current { live.append(c) }
        out.append(contentsOf: live.filter { $0.timestamp > newest && $0.timestamp >= cutoff })
        return out
    }

    func glanceStats(_ window: GlanceWindow, now: Date = Date()) -> GlucoseStats? {
        GlucoseStats.compute(readings(lastHours: window.hours, now: now),
                             low: snapshot.lowMgdl, high: snapshot.highMgdl)
    }

    // MARK: Status item

    /// Text next to the menu bar icon. A stale reading swaps its trend arrow for its age, so an old
    /// value can't be mistaken for a live one at a glance.
    func statusItemText(at now: Date = Date()) -> String {
        guard let current = snapshot.current else { return "––" }
        let value = snapshot.unit.format(mgdl: current.mgdl)
        if snapshot.isStale(at: now) {
            return "\(value) · \(PopoverFormat.age(current.age(at: now)))"
        }
        var t = "\(value) \(current.trend.arrow)"
        if settings.showDeltaInMenuBar, let d = snapshot.deltaMgdl {
            t += " " + snapshot.unit.formatDelta(mgdl: d)
        }
        return t
    }

    /// Copies the current reading to the clipboard. Returns false when there's nothing to copy.
    @discardableResult
    func copyReadingToClipboard() -> Bool {
        guard let text = snapshot.clipboardSummary() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }
}

// MARK: - Recent log activity

extension LogbookStore {
    /// The most recent insulin dose and meal within `hours`, for the popover's "Recent" row.
    func recentActivity(withinHours hours: Double = 12, now: Date = Date()) -> (dose: InsulinDose?, meal: MealEntry?) {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let dose = doses.last { $0.timestamp >= cutoff && $0.timestamp <= now }
        let meal = meals.last { $0.timestamp >= cutoff && $0.timestamp <= now }
        return (dose, meal)
    }
}
