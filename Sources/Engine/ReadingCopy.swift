import Foundation

// Copy or share the current reading (round 84, docs/iOS.md "Copy or share the reading"). Long-press
// the big reading on iPhone Today (or a followed person's reading) for Copy and Share, or press ⌘C
// in the Mac popover. One plain line, the same everywhere, worked out here so it can be tested:
//
//   "6.1 mmol/L, steady, 2 min ago"                       a reading under 10 minutes old
//   "6.1 mmol/L, 8 min ago"                               stale: no trend, as on screen
//   "No readings for 12 min · last 6.1 mmol/L at 2:40 pm" a gap, in the chart's words (#388)
//   "Sam: 6.1 mmol/L, steady, 2 min ago"                  a followed person's, with their name
//
// It only ever says what's on screen: no forecast, no advice, and no name other than the one the
// follower already sees on the card.

enum ReadingCopy {
    /// "6.1 mmol/L, steady, 2 min ago", or the gap line once there's been no reading for
    /// `ReadingGaps.minimum`. `name`, for a followed person, goes in front ("Sam: …").
    static func text(mgdl: Double, trend: Trend, at timestamp: Date, unit: GlucoseUnit, now: Date,
                     name: String? = nil, calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> String {
        let age = max(0, now.timeIntervalSince(timestamp))
        let value = unit.format(mgdl: mgdl, withUnit: true)
        let body: String
        if age >= ReadingGaps.minimum {
            body = "No readings for \(ReadingGaps.length(age)) · last \(value) at "
                + ClockLabel.time(timestamp, calendar: calendar, locale: locale)
        } else {
            var parts = [value]
            // A stale reading's trend isn't shown on screen, so it isn't copied either.
            if age <= GlucoseSnapshot.staleAfter, trend != .unknown { parts.append(trend.description.lowercased()) }
            parts.append(ago(age))
            body = parts.joined(separator: ", ")
        }
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? body : "\(label): \(body)"
    }

    /// The owner's reading in `unit` (the unit on screen). Nil with no reading to copy.
    static func text(_ s: GlucoseSnapshot, unit: GlucoseUnit? = nil, at now: Date,
                     calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let cur = s.current else { return nil }
        return text(mgdl: cur.mgdl, trend: cur.trend, at: cur.timestamp, unit: unit ?? s.unit, now: now,
                    calendar: calendar, locale: locale)
    }

    /// A followed person's reading from their Lock Screen card, labelled with their name.
    static func text(_ card: GlucoseActivityState, name: String, at now: Date,
                     calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        text(mgdl: card.mgdl, trend: card.glucoseTrend, at: card.readingDate, unit: card.glucoseUnit, now: now,
             name: name, calendar: calendar, locale: locale)
    }

    /// "just now", "1 min ago", "8 min ago": under 10 minutes, so always minutes.
    static func ago(_ interval: TimeInterval) -> String {
        let m = Int(max(0, interval) / 60)
        return m == 0 ? "just now" : "\(m) min ago"
    }

    /// What the toast says, and VoiceOver hears, after a copy.
    static let copiedToast = "Copied"
    /// How long the toast stays up.
    static let toastSeconds: TimeInterval = 1.4
}
