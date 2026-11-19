import Foundation

/// Panning the Today chart (iPhone) and the popover chart (Mac) back to earlier hours, and back to
/// now. Plain Foundation so it can be unit-tested; `GlucoseChart` draws from it.
///
/// While panned, the chart shows the same span (3h / 6h / 12h / 24h) ending at an earlier moment
/// (`end`). It never pans into the future, never further back than `maxBackHours` before the
/// newest reading, and never past the oldest reading it has. The forecast is hidden while panned,
/// since it belongs to now, not to the moment on the right edge. `nil` for `end` means live: the
/// chart follows the newest reading as it always has.
///
/// The end is a fixed moment rather than an offset from the newest reading, so a reading arriving
/// while you look back doesn't slide what you're looking at.
enum ChartPan {
    /// How far back the right edge can go, before the newest reading. A day, so the whole of
    /// yesterday can be looked at on the 24-hour span.
    static let maxBackHours: Double = 24

    /// How much each chart is handed: the longest span, its lead, and how far it can pan back.
    static let hoursHanded: Double = ChartHours.longestPlotted + maxBackHours

    /// Let go within this of now, and the chart springs the rest of the way back to now, so a
    /// small nudge never leaves it a few minutes behind with the forecast hidden.
    static let snapToNow: TimeInterval = 5 * 60

    /// The earliest the right edge may go, or nil when there's nothing earlier to see (a short
    /// history no longer than the span itself).
    static func earliestEnd(newest: Date, oldest: Date, hours: Double) -> Date? {
        let byLimit = newest.addingTimeInterval(-maxBackHours * 3600)
        let byData = oldest.addingTimeInterval(hours * 3600)
        let earliest = max(byLimit, byData)
        return earliest < newest ? earliest : nil
    }

    /// `end` kept within bounds. Nil (live) at or after the newest reading, or when there's
    /// nothing earlier to see.
    static func clamped(_ end: Date?, newest: Date, oldest: Date, hours: Double) -> Date? {
        guard let end, let earliest = earliestEnd(newest: newest, oldest: oldest, hours: hours) else { return nil }
        let e = min(max(end, earliest), newest)
        return newest.timeIntervalSince(e) < 1 ? nil : e
    }

    /// Where the right edge is after the content has been moved `points` to the right (a finger
    /// dragging right along the time axis, or two fingers swiping right on a trackpad), from where
    /// it was when the movement began. The trace follows the fingers: moving right shows earlier.
    static func moved(from start: Date?, points: Double, secondsPerPoint: Double,
                      newest: Date, oldest: Date, hours: Double) -> Date? {
        guard points.isFinite, secondsPerPoint.isFinite, secondsPerPoint > 0 else { return start }
        let from = start ?? newest
        return clamped(from.addingTimeInterval(-points * secondsPerPoint), newest: newest, oldest: oldest, hours: hours)
    }

    /// Where it settles once the fingers lift: back to now if it was left close to it.
    static func released(_ end: Date?, newest: Date) -> Date? {
        guard let end else { return nil }
        return newest.timeIntervalSince(end) <= snapToNow ? nil : end
    }

    /// How far one VoiceOver swipe moves: a quarter of the span, so four swipes move one whole
    /// screen, and never less than an hour.
    static func stepSeconds(hours: Double) -> TimeInterval {
        max(3600, hours * 3600 / 4)
    }

    /// One VoiceOver swipe: down for earlier, up for later (and back to now).
    static func stepped(_ end: Date?, earlier: Bool, newest: Date, oldest: Date, hours: Double) -> Date? {
        let step = stepSeconds(hours: hours)
        let from = end ?? newest
        return clamped(from.addingTimeInterval(earlier ? -step : step), newest: newest, oldest: oldest, hours: hours)
    }

    /// Whether VoiceOver can swipe any further back.
    static func canGoEarlier(_ end: Date?, newest: Date, oldest: Date, hours: Double) -> Bool {
        guard let earliest = earliestEnd(newest: newest, oldest: oldest, hours: hours) else { return false }
        return (end ?? newest) > earliest
    }

    /// How far behind the newest reading the right edge is, in whole minutes rounded to five, for
    /// what's said and shown: "3 h 15 min earlier".
    static func behindLabel(_ end: Date, newest: Date) -> String {
        let minutes = Int((newest.timeIntervalSince(end) / 60 / 5).rounded()) * 5
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(max(5, m)) min earlier"
        case (_, 0): return "\(h) h earlier"
        default: return "\(h) h \(m) min earlier"
        }
    }

    /// What VoiceOver says for the pan: "Now", or "2:15 to 5:15 pm, 3 h earlier". `clock` names a
    /// time of day (`ClockLabel.time` in the app), passed in so tests don't depend on the locale.
    static func spoken(end: Date?, newest: Date, hours: Double, clock: (Date) -> String) -> String {
        guard let end else { return "Now" }
        let start = end.addingTimeInterval(-hours * 3600)
        return "\(clock(start)) to \(clock(end)), \(behindLabel(end, newest: newest))"
    }
}
